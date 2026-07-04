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
        let truth = sensedTuples(groundTruth)
        #expect(decoded.count == truth.count)
        for (decodedEvent, truthEvent) in zip(decoded, truth) {
            #expect(decodedEvent.square == truthEvent.square)
            #expect(decodedEvent.isLift == truthEvent.isLift)
            #expect(decodedEvent.piece == truthEvent.piece)
        }
    }

    // Promotion (the placed piece must decode as a queen, not a pawn).
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
        #expect(decoded.count == 2)
        #expect(decoded[1].square == "e8")
        #expect(decoded[1].piece == Piece(type: .queen, color: .white))
    }
}

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
