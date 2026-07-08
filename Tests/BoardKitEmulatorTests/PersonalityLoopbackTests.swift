// LOOP-BACK SELF-CONSISTENCY — the anti-asymmetric-codec harness.
//
// Personality frames (board-side encode) fed through the matching host-side
// adapter's `feed(bytes:)` must reproduce the SimulatedBoard's ground-truth
// events. A one-directional golden fixture can silently agree with a bug in
// both directions; this closes the loop.

import Testing
import Foundation
import ChessCore
import BoardKit
import SquareOffAdapter
import ChessnutAdapter
import PegasusAdapter
import MillenniumAdapter
import CertaboAdapter
import ChessUpAdapter
import BoardKitTestSupport
import BoardKitEmulator

// A short but eventful line: captures, castle, en passant is covered in the
// dedicated test below.
private let loopbackMoves = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "e1g1", "f6e4", "f3e5", "c6e5"]

// MARK: - Square Off loop-back

@Test func squareOffLoopbackReproducesGroundTruth() async throws {
    var personality = SquareOffPersonality()
    var hostAdapter = SquareOffAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    for uci in loopbackMoves {
        let groundTruth = try await sim.executeMove(uci: uci)

        // Board side: events → notification frames → one BLE byte stream.
        var wire = Data()
        for event in groundTruth {
            for frame in personality.frames(for: event) {
                #expect(frame.characteristicUUID == SquareOffPersonality.txCharUUID)
                wire.append(frame.data)
            }
        }

        // Host side: bytes → events.
        let decoded = hostAdapter.feed(bytes: wire)
        let decodedTuples = sensedTuples(decoded)
        let truthTuples = sensedTuples(groundTruth)

        #expect(decodedTuples.count == truthTuples.count, "move \(uci)")
        for (decodedEvent, truth) in zip(decodedTuples, truthTuples) {
            #expect(decodedEvent.square == truth.square, "move \(uci)")
            #expect(decodedEvent.isLift == truth.isLift, "move \(uci)")
            #expect(decodedEvent.piece == nil, "Square Off must not invent piece identity")
        }
    }
}

@Test func squareOffLoopbackFragmentedDelivery() async throws {
    // Same loop but the wire stream is delivered one byte at a time —
    // the emulator chunks frames to the ATT budget, so the host framer
    // must survive arbitrary fragmentation.
    var personality = SquareOffPersonality()
    var hostAdapter = SquareOffAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    let groundTruth = try await sim.executeMove(uci: "e2e4")
    var wire = Data()
    for event in groundTruth {
        for frame in personality.frames(for: event) {
            wire.append(frame.data)
        }
    }
    var decoded: [BoardEvent] = []
    for byte in wire {
        decoded += hostAdapter.feed(bytes: Data([byte]))
    }
    let tuples = sensedTuples(decoded)
    #expect(tuples.count == 2)
    #expect(tuples[0].square == "e2" && tuples[0].isLift)
    #expect(tuples[1].square == "e4" && !tuples[1].isLift)
}

@Test func squareOffSnapshotAndReadyLoopback() async throws {
    var personality = SquareOffPersonality()
    var hostAdapter = SquareOffAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])
    _ = try await sim.executeMove(uci: "e2e4")

    // Snapshot: board occupancy → "30#…*" → host .occupancySnapshot.
    let snapshot = await sim.boardSnapshot()
    guard case .occupancySnapshot(let truth) = snapshot else {
        Issue.record("expected occupancySnapshot from occupancy-only board")
        return
    }
    var wire = Data()
    for frame in personality.frames(for: snapshot) { wire.append(frame.data) }
    // Ready: "14#GO*" → host .ready.
    for frame in personality.frames(for: .ready) { wire.append(frame.data) }

    let decoded = hostAdapter.feed(bytes: wire)
    #expect(decoded.count == 2)
    guard case .occupancySnapshot(let decodedOccupancy) = decoded[0] else {
        Issue.record("expected occupancySnapshot, got \(decoded[0])")
        return
    }
    #expect(decodedOccupancy == truth)
    guard case .ready = decoded[1] else {
        Issue.record("expected .ready, got \(decoded[1])")
        return
    }
}

// MARK: - Chessnut loop-back

@Test func chessnutLoopbackReproducesGroundTruth() async throws {
    var personality = ChessnutPersonality()
    var hostAdapter = ChessnutAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])

    // Prime the host adapter with the initial position (first frame emits
    // snapshot + .ready, no deltas) — mirrors the real connect sequence.
    let initialSnapshot = await sim.boardSnapshot()
    var primeWire = Data()
    for frame in personality.frames(for: initialSnapshot) { primeWire.append(frame.data) }
    let primeEvents = hostAdapter.feed(bytes: primeWire)
    #expect(primeEvents.contains { if case .ready = $0 { return true }; return false })

    for uci in loopbackMoves {
        let groundTruth = try await sim.executeMove(uci: uci)

        var decodedTuples: [(square: String, isLift: Bool, piece: Piece?)] = []
        for event in groundTruth {
            // One board-state frame per sensor event, as real hardware streams.
            for frame in personality.frames(for: event) {
                #expect(frame.characteristicUUID == ChessnutGATT.boardStateChar)
                decodedTuples += sensedTuples(hostAdapter.feed(bytes: frame.data))
            }
        }

        let truthTuples = sensedTuples(groundTruth)
        #expect(decodedTuples.count == truthTuples.count, "move \(uci)")
        for (decodedEvent, truth) in zip(decodedTuples, truthTuples) {
            #expect(decodedEvent.square == truth.square, "move \(uci)")
            #expect(decodedEvent.isLift == truth.isLift, "move \(uci)")
            #expect(decodedEvent.piece == truth.piece,
                    "move \(uci) @ \(truth.square): identity diverged (\(String(describing: decodedEvent.piece)) vs \(String(describing: truth.piece)))")
        }

        // Mirror integrity: the personality's identity mirror must match the
        // simulated board exactly after every move.
        let simPosition = await sim.position
        var expectedIdentity = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {
                expectedIdentity[file * 8 + rank] = simPosition.board[rank * 8 + file]
            }
        }
        #expect(personality.identityMirror == expectedIdentity, "mirror drifted after \(uci)")
    }
}

@Test func chessnutLoopbackEnPassantAndPromotion() async throws {
    // En passant.
    do {
        let fen = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2"
        let sim = SimulatedBoard(position: Position(fen: fen)!,
                                 capabilities: [.occupancySensing, .pieceIdentity])
        var personality = ChessnutPersonality()
        var hostAdapter = ChessnutAdapter()
        // Re-seed the personality mirror + prime the adapter from the FEN.
        let snapshot = await sim.boardSnapshot()
        for frame in personality.frames(for: snapshot) {
            _ = hostAdapter.feed(bytes: frame.data)
        }

        let groundTruth = try await sim.executeMove(uci: "e5d6")
        var decoded: [(square: String, isLift: Bool, piece: Piece?)] = []
        for event in groundTruth {
            for frame in personality.frames(for: event) {
                decoded += sensedTuples(hostAdapter.feed(bytes: frame.data))
            }
        }
        // groundTruth has 3 squareSensed events (en-passant) — no .promotionPick.
        let truth = sensedTuples(groundTruth)
        #expect(decoded.count == truth.count)
        for (decodedEvent, truthEvent) in zip(decoded, truth) {
            #expect(decodedEvent.square == truthEvent.square)
            #expect(decodedEvent.isLift == truthEvent.isLift)
            #expect(decodedEvent.piece == truthEvent.piece)
        }
    }

    // Plain promotion (the placed piece must decode as a queen, not a pawn).
    // After the fix, groundTruth has a trailing .promotionPick(.queen) that
    // ChessnutPersonality ignores (returns []) — decoded.count stays 2.
    do {
        let sim = SimulatedBoard(position: Position(fen: "8/4P3/8/8/8/8/8/4K2k w - - 0 1")!,
                                 capabilities: [.occupancySensing, .pieceIdentity])
        var personality = ChessnutPersonality()
        var hostAdapter = ChessnutAdapter()
        let snapshot = await sim.boardSnapshot()
        for frame in personality.frames(for: snapshot) {
            _ = hostAdapter.feed(bytes: frame.data)
        }

        let groundTruth = try await sim.executeMove(uci: "e7e8q")
        var decoded: [(square: String, isLift: Bool, piece: Piece?)] = []
        for event in groundTruth {
            for frame in personality.frames(for: event) {
                decoded += sensedTuples(hostAdapter.feed(bytes: frame.data))
            }
        }
        // 2 squareSensed events: lift(e7) + place(e8, queen).
        // .promotionPick is in groundTruth but Chessnut returns [] for it.
        #expect(decoded.count == 2)
        #expect(decoded[1].square == "e8")
        #expect(decoded[1].piece == Piece(type: .queen, color: .white))
    }
}

/// Capture-promotion identity check: for identity-sensing boards, the PLACE
/// event of a capture-promotion must carry the PROMOTED piece, not the pawn.
///
/// This was the bug that the fix closes: SimulatedBoard's capture branch
/// always placed `moverPiece` (the pawn) regardless of promotion.  After the
/// fix, the capture branch handles promotion correctly and the Chessnut adapter
/// decodes the promoted piece from the board-state frame.
@Test func chessnutLoopbackCapturePromotionPlacedPieceIsPromoted() async throws {
    // White pawn b7 captures black rook a8 and promotes to queen (b7a8q).
    // (White pawns promote on rank 8, not rank 1.)
    let sim = SimulatedBoard(
        position: Position(fen: "r7/1P6/8/8/8/8/8/4K2k w - - 0 1")!,
        capabilities: [.occupancySensing, .pieceIdentity]
    )
    var personality = ChessnutPersonality()
    var hostAdapter = ChessnutAdapter()
    let snapshot = await sim.boardSnapshot()
    for frame in personality.frames(for: snapshot) {
        _ = hostAdapter.feed(bytes: frame.data)
    }

    let groundTruth = try await sim.executeMove(uci: "b7a8q")
    var decoded: [(square: String, isLift: Bool, piece: Piece?)] = []
    for event in groundTruth {
        for frame in personality.frames(for: event) {
            decoded += sensedTuples(hostAdapter.feed(bytes: frame.data))
        }
    }
    // Capture-promotion: lift(b7, pawn) + lift(a8, rook) + place(a8, queen).
    // .promotionPick(.queen) produces no Chessnut frames → not in decoded.
    #expect(decoded.count == 3,
            "Capture-promotion: must have 3 squareSensed events (lift×2 + place)")
    #expect(decoded[0].square == "b7" && decoded[0].isLift,
            "First event: lift pawn from b7")
    #expect(decoded[1].square == "a8" && decoded[1].isLift,
            "Second event: lift captured rook from a8")
    #expect(decoded[2].square == "a8" && !decoded[2].isLift,
            "Third event: place promoted piece on a8")
    // The placed piece MUST be the queen (promoted), NOT the pawn (the old bug).
    #expect(decoded[2].piece == Piece(type: .queen, color: .white),
            "Capture-promotion placed piece must be the promoted queen, not the pawn (fixed bug)")
}

// MARK: - Pegasus loop-back

/// Simple non-capture moves: one field-update frame per squareSensed event.
private let pegasusSimpleMoves = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "e1g1"]

@Test func pegasusLoopbackReproducesGroundTruth() async throws {
    var personality = PegasusPersonality()
    var hostAdapter = PegasusAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    // Prime the host adapter with the initial board dump (seeds previousOccupancy).
    let initialSnapshot = await sim.boardSnapshot()
    var primeWire = Data()
    for frame in personality.frames(for: initialSnapshot) { primeWire.append(frame.data) }
    let primeEvents = hostAdapter.feed(bytes: primeWire)
    #expect(primeEvents.contains { if case .ready = $0 { return true }; return false })

    for uci in pegasusSimpleMoves {
        let groundTruth = try await sim.executeMove(uci: uci)
        var wire = Data()
        for event in groundTruth {
            for frame in personality.frames(for: event) {
                #expect(frame.characteristicUUID == PegasusPersonality.notifyCharUUID)
                wire.append(frame.data)
            }
        }
        let decoded = hostAdapter.feed(bytes: wire)
        let decodedTuples = sensedTuples(decoded)
        let truthTuples   = sensedTuples(groundTruth)
        #expect(decodedTuples.count == truthTuples.count, "move \(uci)")
        for (d, t) in zip(decodedTuples, truthTuples) {
            #expect(d.square == t.square, "move \(uci)")
            #expect(d.isLift == t.isLift,  "move \(uci)")
            #expect(d.piece  == nil, "Pegasus must not invent piece identity")
        }
    }
}

@Test func pegasusLoopbackCaptureViaFieldUpdates() async throws {
    // Capture: ground truth has 3 events (lift captured, lift attacker, place).
    // Pegasus emits one field-update per event; host adapter decodes each one.
    let fen = "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    let sim = SimulatedBoard(position: Position(fen: fen)!, capabilities: [.occupancySensing])
    var personality = PegasusPersonality()
    var hostAdapter = PegasusAdapter()

    // Prime.
    let snapshot = await sim.boardSnapshot()
    _ = hostAdapter.feed(bytes: personality.frames(for: snapshot).reduce(Data()) { $0 + $1.data })

    let groundTruth = try await sim.executeMove(uci: "e4d5")
    var wire = Data()
    for event in groundTruth { for frame in personality.frames(for: event) { wire.append(frame.data) } }
    let decoded = hostAdapter.feed(bytes: wire)
    let decodedTuples = sensedTuples(decoded)
    let truthTuples   = sensedTuples(groundTruth)
    #expect(decodedTuples.count == truthTuples.count, "capture event count mismatch")
    for (d, t) in zip(decodedTuples, truthTuples) {
        #expect(d.square == t.square)
        #expect(d.isLift == t.isLift)
    }
}

// MARK: - Millennium loop-back

@Test func millenniumLoopbackReproducesGroundTruth() async throws {
    var personality = MillenniumPersonality()
    var hostAdapter = MillenniumAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])

    // Prime the host adapter with the initial s-frame (seeds previousIdentity + .ready).
    let initialSnapshot = await sim.boardSnapshot()
    var primeWire = Data()
    for frame in personality.frames(for: initialSnapshot) { primeWire.append(frame.data) }
    let primeEvents = hostAdapter.feed(bytes: primeWire)
    #expect(primeEvents.contains { if case .ready = $0 { return true }; return false })

    for uci in loopbackMoves {
        let groundTruth = try await sim.executeMove(uci: uci)
        var decodedTuples: [(square: String, isLift: Bool, piece: Piece?)] = []
        for event in groundTruth {
            for frame in personality.frames(for: event) {
                #expect(frame.characteristicUUID == MillenniumPersonality.notifyCharUUID)
                decodedTuples += sensedTuples(hostAdapter.feed(bytes: frame.data))
            }
        }
        let truthTuples = sensedTuples(groundTruth)
        #expect(decodedTuples.count == truthTuples.count, "move \(uci)")
        for (d, t) in zip(decodedTuples, truthTuples) {
            #expect(d.square == t.square, "move \(uci)")
            #expect(d.isLift == t.isLift,  "move \(uci)")
            #expect(d.piece  == t.piece,   "move \(uci)")
        }
    }
}

@Test func millenniumMirrorSurvivesChaosStreams() async throws {
    var personality = MillenniumPersonality()
    let cases = try await generateGameCases(seed: 22, maxPlies: 30)
    let engine = ChaosEngine(profile: .clumsy)
    var rng = SeededRNG(seed: 22)
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        for event in perturbation.events {
            _ = personality.frames(for: .squareSensed(square: event.square,
                                                      isLift: event.isLift,
                                                      piece: event.piece))
        }
        var after = corpusCase.positionBefore
        MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
        let expected = BoardDiffResolver.occupancyArray(for: after)
        let mirrored = personality.identityMirror.map { $0 != nil }
        #expect(mirrored == expected,
                "millennium mirror drifted after \(corpusCase.uci): \(perturbation.appliedPatterns)")
    }
}

// MARK: - Certabo loop-back

/// Build a canonical test calibration: deterministic tag IDs for all 32 start-position pieces.
///
/// Tag format: (pieceKind, color, 1, 0, 0) — unique per (kind, color) pair.
func makeTestCalibration() -> CertaboCalibration {
    let allPieces: [Piece] = [
        Piece(type: .king,   color: .white), Piece(type: .queen,  color: .white),
        Piece(type: .rook,   color: .white), Piece(type: .knight, color: .white),
        Piece(type: .bishop, color: .white), Piece(type: .pawn,   color: .white),
        Piece(type: .king,   color: .black), Piece(type: .queen,  color: .black),
        Piece(type: .rook,   color: .black), Piece(type: .knight, color: .black),
        Piece(type: .bishop, color: .black), Piece(type: .pawn,   color: .black),
    ]
    var map: [CertaboTagID: Piece] = [:]
    for (i, piece) in allPieces.enumerated() {
        // b1=1 for white, b1=2 for black. Never use 0 for b1 — combined with
        // b3=0 and b4=0 that would give ≥3 zero bytes, triggering the
        // CertaboTagID.isEffectivelyEmpty heuristic and silently dropping all
        // black-piece events (D7 secondary heuristic: ≥3 zeros → treat as empty).
        let b1: UInt8 = piece.color == .white ? 1 : 2
        map[CertaboTagID(UInt8(i + 1), b1, 84, 0, 0)] = piece
    }
    return CertaboCalibration(tagToPieceMap: map)
}

@Test func certaboLoopbackReproducesGroundTruth() async throws {
    let cal = makeTestCalibration()
    var personality = CertaboPersonality(calibration: cal)
    var hostAdapter = CertaboAdapter(calibration: cal)
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])

    // Prime the host adapter with the initial RFID frame.
    let initialSnapshot = await sim.boardSnapshot()
    var primeWire = Data()
    for frame in personality.frames(for: initialSnapshot) { primeWire.append(frame.data) }
    let primeEvents = hostAdapter.feed(bytes: primeWire)
    #expect(primeEvents.contains { if case .ready = $0 { return true }; return false })

    for uci in loopbackMoves {
        let groundTruth = try await sim.executeMove(uci: uci)
        var decodedTuples: [(square: String, isLift: Bool, piece: Piece?)] = []
        for event in groundTruth {
            for frame in personality.frames(for: event) {
                #expect(frame.characteristicUUID == CertaboPersonality.notifyCharUUID)
                decodedTuples += sensedTuples(hostAdapter.feed(bytes: frame.data))
            }
        }
        let truthTuples = sensedTuples(groundTruth)
        #expect(decodedTuples.count == truthTuples.count, "move \(uci)")
        for (d, t) in zip(decodedTuples, truthTuples) {
            #expect(d.square == t.square, "move \(uci)")
            #expect(d.isLift == t.isLift,  "move \(uci)")
            #expect(d.piece  == t.piece,   "move \(uci)")
        }
    }
}

@Test func certaboUncalibratedLoopbackOccupancy() async throws {
    // Without calibration: Tabutronic 8-token frames → occupancy snapshots.
    var personality = CertaboPersonality(calibration: nil)
    var hostAdapter = CertaboAdapter(calibration: nil)
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    // Prime.
    let initial = await sim.boardSnapshot()
    _ = hostAdapter.feed(bytes: personality.frames(for: initial).reduce(Data()) { $0 + $1.data })

    for uci in ["e2e4", "e7e5", "g1f3"] {
        let groundTruth = try await sim.executeMove(uci: uci)
        var wire = Data()
        for event in groundTruth { for frame in personality.frames(for: event) { wire.append(frame.data) } }
        let decoded = hostAdapter.feed(bytes: wire)
        // Certabo occupancy frames emit squareSensed deltas after first frame.
        let decodedTuples = sensedTuples(decoded)
        let truthTuples   = sensedTuples(groundTruth)
        #expect(decodedTuples.count == truthTuples.count, "uncalibrated move \(uci)")
        for (d, t) in zip(decodedTuples, truthTuples) {
            #expect(d.square == t.square)
            #expect(d.isLift == t.isLift)
        }
    }
}

@Test func certaboRGBLEDDecodeFiltersSpillovere2e4() {
    // Regression: e2 + e4 must decode to exactly those two squares.
    // Before the fix, the shared corners between e2 and e4 made e3's
    // four blue-channel indices all nonzero, producing a spurious e3.
    var personality = CertaboPersonality()

    // Build a 247-byte RGB LED frame encoding e2 and e4 only,
    // using the same formula as CertaboAdapter.encodeRGBLED (MIT source).
    var payload = [UInt8](repeating: 0, count: 243)
    for algebraic in ["e2", "e4"] {
        guard let sq = Square(algebraic: algebraic) else { continue }
        let streamIdx = (7 - sq.rank) * 8 + sq.file
        let row = 7 - streamIdx / 8
        let col = 7 - streamIdx % 8
        let base = (row * 9 + col) * 3
        for cornerBase in [base, base + 3, base + 27, base + 30] {
            let blueOff = cornerBase + 2
            if blueOff < payload.count { payload[blueOff] = 0x40 }
        }
    }
    var frame = Data([0xFF, 0x55])
    frame.append(contentsOf: payload)
    frame.append(contentsOf: [0x0D, 0x0A])

    let actions = personality.handleHostWrite(frame)
    guard case .setLEDs(let squares) = actions.first else {
        Issue.record("expected .setLEDs, got \(actions)")
        return
    }
    let sorted = squares.sorted()
    #expect(sorted == ["e2", "e4"], "spillover filter failed: got \(sorted)")
}

// MARK: - ChessUp loop-back

@Test func chessUpLoopbackOccupancySnapshots() async throws {
    // ChessUp emits 0x67 board-state frames; host adapter decodes as occupancy snapshots.
    // We verify that after each move the final occupancy matches the expected position.
    var personality = ChessUpPersonality()
    var hostAdapter = ChessUpAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    // Prime via GET_STATE response (seeds .ready in host adapter).
    let getState = Data([0x67])
    let primeActions = personality.handleHostWrite(getState)
    if case .notify(let frame) = primeActions.first {
        let primeEvents = hostAdapter.feed(bytes: frame.data)
        #expect(primeEvents.contains { if case .ready = $0 { return true }; return false })
    }

    // Note: castling (e1g1) requires f1 to be clear; f1c4 opens that path.
    for uci in ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4"] {
        let groundTruth = try await sim.executeMove(uci: uci)
        // Feed all events through personality to update its occupancy mirror.
        var lastOccupancy: [Bool]? = nil
        for event in groundTruth {
            for frame in personality.frames(for: event) {
                #expect(frame.characteristicUUID == ChessUpPersonality.notifyCharUUID)
                let decoded = hostAdapter.feed(bytes: frame.data)
                for decodedEvent in decoded {
                    if case .occupancySnapshot(let occ) = decodedEvent { lastOccupancy = occ }
                }
            }
        }
        // After all events for this move, occupancy must match the post-move position.
        let afterPos = await sim.position
        let expectedOcc = BoardDiffResolver.occupancyArray(for: afterPos)
        if let occ = lastOccupancy {
            #expect(occ == expectedOcc, "ChessUp occupancy mismatch after \(uci)")
        } else {
            Issue.record("ChessUp: no occupancy snapshot decoded after \(uci)")
        }
    }
}

@Test func chessUpLoopbackChaosKernelSurvival() async throws {
    // Feed chaos-perturbed streams through ChessUp personality and verify the
    // occupancy mirror lands on the expected position after each move — matching
    // the pattern of chessnutMirrorSurvivesChaosStreams / millenniumMirrorSurvivesChaosStreams.
    var personality = ChessUpPersonality()
    let cases = try await generateGameCases(seed: 23, maxPlies: 30)
    let engine = ChaosEngine(profile: .casual)
    var rng = SeededRNG(seed: 23)
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        for event in perturbation.events {
            _ = personality.frames(for: .squareSensed(square: event.square,
                                                      isLift: event.isLift, piece: nil))
        }
        var after = corpusCase.positionBefore
        MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
        let expected = BoardDiffResolver.occupancyArray(for: after)
        #expect(personality.occupancyMirror == expected,
                "chessup occupancy mirror drifted after \(corpusCase.uci): \(perturbation.appliedPatterns)")
    }
}

// MARK: - Pegasus chaos-corpus

@Test func pegasusMirrorSurvivesChaosStreams() async throws {
    // Occupancy-only board: mirror must track the net occupancy state through
    // all tolerated chaos patterns (lift-and-return, order swaps, etc.).
    var personality = PegasusPersonality()
    let cases = try await generateGameCases(seed: 24, maxPlies: 30)
    let engine = ChaosEngine(profile: .clumsy)
    var rng = SeededRNG(seed: 24)
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        for event in perturbation.events {
            _ = personality.frames(for: .squareSensed(square: event.square,
                                                      isLift: event.isLift, piece: nil))
        }
        var after = corpusCase.positionBefore
        MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
        let expected = BoardDiffResolver.occupancyArray(for: after)
        #expect(personality.occupancyMirror == expected,
                "pegasus occupancy mirror drifted after \(corpusCase.uci): \(perturbation.appliedPatterns)")
    }
}

// MARK: - Certabo chaos-corpus

@Test func certaboRFIDMirrorSurvivesChaosStreams() async throws {
    // Calibrated (RFID) mode: identity mirror must track piece occupancy through
    // all tolerated chaos patterns — same guarantee as Chessnut/Millennium.
    let cal = makeTestCalibration()
    var personality = CertaboPersonality(calibration: cal)
    let cases = try await generateGameCases(seed: 25, maxPlies: 30)
    let engine = ChaosEngine(profile: .clumsy)
    var rng = SeededRNG(seed: 25)
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        for event in perturbation.events {
            _ = personality.frames(for: .squareSensed(square: event.square,
                                                      isLift: event.isLift,
                                                      piece: event.piece))
        }
        var after = corpusCase.positionBefore
        MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
        let expected = BoardDiffResolver.occupancyArray(for: after)
        let mirrored = personality.identityMirror.map { $0 != nil }
        #expect(mirrored == expected,
                "certabo identity mirror drifted after \(corpusCase.uci): \(perturbation.appliedPatterns)")
    }
}

@Test func certaboOccupancyMirrorSurvivesChaosStreams() async throws {
    // Uncalibrated (Tabutronic-style) mode: occupancy mirror must track the
    // net occupancy state through all tolerated chaos patterns.
    var personality = CertaboPersonality(calibration: nil)
    let cases = try await generateGameCases(seed: 26, maxPlies: 30)
    let engine = ChaosEngine(profile: .clumsy)
    var rng = SeededRNG(seed: 26)
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        for event in perturbation.events {
            _ = personality.frames(for: .squareSensed(square: event.square,
                                                      isLift: event.isLift, piece: nil))
        }
        var after = corpusCase.positionBefore
        MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
        let expected = BoardDiffResolver.occupancyArray(for: after)
        #expect(personality.occupancyMirror == expected,
                "certabo occupancy mirror drifted after \(corpusCase.uci): \(perturbation.appliedPatterns)")
    }
}

// MARK: - Chessnut chaos-corpus

@Test func chessnutMirrorSurvivesChaosStreams() async throws {
    // Feed chaos-perturbed (tolerated-profile) event streams through the
    // personality and assert its occupancy mirror still lands on the ground
    // truth after every move — the airborne-ledger heuristic must not drift.
    var personality = ChessnutPersonality()
    let cases = try await generateGameCases(seed: 21, maxPlies: 30)
    let engine = ChaosEngine(profile: .clumsy)
    var rng = SeededRNG(seed: 21)

    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        for event in perturbation.events {
            _ = personality.frames(for: .squareSensed(square: event.square,
                                                      isLift: event.isLift,
                                                      piece: event.piece))
        }
        var after = corpusCase.positionBefore
        MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
        let expected = BoardDiffResolver.occupancyArray(for: after)
        let mirrored = personality.identityMirror.map { $0 != nil }
        #expect(mirrored == expected,
                "occupancy mirror drifted after \(corpusCase.uci) with \(perturbation.appliedPatterns)")
    }
}
