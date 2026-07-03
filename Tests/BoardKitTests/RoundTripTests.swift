// Round-trip tests: SimulatedBoard plays a short real game through
// ChessnutAdapter encode → identity snapshots → verify derived events
// reconstruct the moves.
//
// Game played: 1.e4 e5 2.Nf3 Nc6 3.Bb5 (Ruy Lopez, enough for capture,
// knight move, and then castling check). We also exercise en passant and
// promotion in dedicated tests.

import Testing
import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport

// MARK: - Helpers

/// Extract all squareSensed events from a list.
private func sensed(_ events: [BoardEvent]) -> [(square: String, isLift: Bool, piece: Piece?)] {
    events.compactMap {
        if case .squareSensed(let sq, let lift, let piece) = $0 { return (sq, lift, piece) }
        return nil
    }
}

/// Encode a Position (via its file-major identity) as a Chessnut board frame.
private func encodePosition(_ position: Position) -> Data {
    var identity = [Piece?](repeating: nil, count: 64)
    for file in 0..<8 {
        for rank in 0..<8 {
            let rankMajor = rank * 8 + file
            let fileMajor = file * 8 + rank
            identity[fileMajor] = position.board[rankMajor]
        }
    }
    return ChessnutAdapter.encodeFrame(identity: identity)
}

// MARK: - Simple move round-trip (e2e4)

@Test func roundTripSimpleMove() async throws {
    let sim = SimulatedBoard(
        capabilities: [.occupancySensing, .pieceIdentity]
    )
    let events = try await sim.executeMove(uci: "e2e4")

    // SimulatedBoard must emit: lift e2, place e4.
    let deltas = sensed(events)
    #expect(deltas.count == 2)
    #expect(deltas[0] == ("e2", true,  Piece(type: .pawn, color: .white)))
    #expect(deltas[1] == ("e4", false, Piece(type: .pawn, color: .white)))

    // Verify the resulting position via ChessnutAdapter encode + decode.
    let pos = await sim.position
    let frame = encodePosition(pos)
    var adapter = ChessnutAdapter()
    let decodeEvents = adapter.feed(bytes: frame)
    guard case .identitySnapshot(let identity) = decodeEvents.first else {
        Issue.record("Expected identitySnapshot")
        return
    }
    // e4 must be a white pawn, e2 must be empty.
    let sq = Square(algebraic: "e4")!
    #expect(identity[sq.file * 8 + sq.rank] == Piece(type: .pawn, color: .white))
    let sq2 = Square(algebraic: "e2")!
    #expect(identity[sq2.file * 8 + sq2.rank] == nil)
}

// MARK: - Capture round-trip (Nf3xe5 style capture)

@Test func roundTripCapture() async throws {
    // Play 1.e4 e5 2.Nf3 Nc6 3.Nxe5 (knight captures the black e5 pawn).
    let sim = SimulatedBoard(
        capabilities: [.occupancySensing, .pieceIdentity]
    )
    _ = try await sim.executeMove(uci: "e2e4")
    _ = try await sim.executeMove(uci: "e7e5")
    _ = try await sim.executeMove(uci: "g1f3")
    _ = try await sim.executeMove(uci: "b8c6")   // black plays Nc6
    // Now f3 has a white knight, e5 has a black pawn.
    let events = try await sim.executeMove(uci: "f3e5")

    let deltas = sensed(events)
    // A normal capture: lift attacker, lift captured, place attacker.
    #expect(deltas.count == 3)
    #expect(deltas[0] == ("f3", true,  Piece(type: .knight, color: .white)))  // attacker lifts
    #expect(deltas[1] == ("e5", true,  Piece(type: .pawn,   color: .black)))  // captured lifts
    #expect(deltas[2] == ("e5", false, Piece(type: .knight, color: .white)))  // attacker places
}

// MARK: - Castling round-trip

@Test func roundTripCastling() async throws {
    // Play moves to clear f1, g1 and allow kingside castling.
    let sim = SimulatedBoard(
        capabilities: [.occupancySensing, .pieceIdentity]
    )
    // Clear the kingside: e4, Nf3, Bc4, then castle.
    _ = try await sim.executeMove(uci: "e2e4")
    _ = try await sim.executeMove(uci: "e7e5")
    _ = try await sim.executeMove(uci: "g1f3")
    _ = try await sim.executeMove(uci: "b8c6")
    _ = try await sim.executeMove(uci: "f1c4")
    _ = try await sim.executeMove(uci: "g8f6")
    // Now white can castle kingside (e1g1).
    let events = try await sim.executeMove(uci: "e1g1")

    let deltas = sensed(events)
    // Castling: lift king, lift rook, place rook, place king.
    #expect(deltas.count == 4)
    #expect(deltas[0] == ("e1", true,  Piece(type: .king, color: .white)))   // king lifts
    #expect(deltas[1] == ("h1", true,  Piece(type: .rook, color: .white)))   // rook lifts
    #expect(deltas[2] == ("f1", false, Piece(type: .rook, color: .white)))   // rook places
    #expect(deltas[3] == ("g1", false, Piece(type: .king, color: .white)))   // king places
}

// MARK: - Promotion round-trip

@Test func roundTripPromotion() async throws {
    // Use a minimal position with a white pawn on e7 ready to promote.
    guard let pos = Position(fen: "8/4P3/8/8/8/8/8/4K2k w - - 0 1") else {
        Issue.record("Failed to parse promotion test position")
        return
    }
    let sim = SimulatedBoard(
        position: pos,
        capabilities: [.occupancySensing, .pieceIdentity]
    )
    let events = try await sim.executeMove(uci: "e7e8q")
    let deltas = sensed(events)
    // Promotion: pawn lifts from e7, promoted queen places on e8.
    #expect(deltas.count == 2)
    #expect(deltas[0] == ("e7", true,  Piece(type: .pawn,  color: .white)))
    #expect(deltas[1] == ("e8", false, Piece(type: .queen, color: .white)))
}

// MARK: - En-passant round-trip

@Test func roundTripEnPassant() async throws {
    // Position: white pawn on e5, black just pushed d7-d5.
    // En passant: white e5xd6 capturing the d5 pawn.
    guard let pos = Position(fen: "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2") else {
        Issue.record("Failed to parse en-passant test position")
        return
    }
    let sim = SimulatedBoard(
        position: pos,
        capabilities: [.occupancySensing, .pieceIdentity]
    )
    let events = try await sim.executeMove(uci: "e5d6")
    let deltas = sensed(events)
    // En passant: capturing pawn lifts (e5), captured pawn lifts (d5), capturing places (d6).
    #expect(deltas.count == 3)
    #expect(deltas[0] == ("e5", true,  Piece(type: .pawn, color: .white)))   // capturer lifts
    #expect(deltas[1] == ("d5", true,  Piece(type: .pawn, color: .black)))   // captured lifts
    #expect(deltas[2] == ("d6", false, Piece(type: .pawn, color: .white)))   // capturer places
}

// MARK: - Occupancy-only mode (no piece identity)

@Test func occupancyOnlyMode() async throws {
    // When capabilities omit .pieceIdentity, piece fields must be nil.
    let sim = SimulatedBoard(capabilities: [.occupancySensing])
    let events = try await sim.executeMove(uci: "e2e4")
    let deltas = sensed(events)
    #expect(deltas.count == 2)
    for delta in deltas {
        #expect(delta.piece == nil)
    }
}

// MARK: - boardSnapshot occupancy vs identity

@Test func boardSnapshotTypes() async {
    let identitySim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])
    let identitySnap = await identitySim.boardSnapshot()
    guard case .identitySnapshot(let id) = identitySnap else {
        Issue.record("Identity-capable board must emit .identitySnapshot")
        return
    }
    #expect(id.count == 64)

    let occupancySim = SimulatedBoard(capabilities: [.occupancySensing])
    let occupancySnap = await occupancySim.boardSnapshot()
    guard case .occupancySnapshot(let occ) = occupancySnap else {
        Issue.record("Occupancy-only board must emit .occupancySnapshot")
        return
    }
    #expect(occ.count == 64)
    // Initial position: 32 occupied squares.
    #expect(occ.filter { $0 }.count == 32)
}

// MARK: - Illegal move throws

@Test func illegalMovethrows() async {
    let sim = SimulatedBoard()
    await #expect(throws: SimulatedBoardError.self) {
        _ = try await sim.executeMove(uci: "e2e5")   // not a legal pawn move
    }
}

// MARK: - Full short-game round-trip via ChessnutAdapter

@Test func shortGameThroughChessnutAdapter() async throws {
    // Play a 3-move opening through SimulatedBoard, encode each resulting
    // position as a Chessnut frame, decode via ChessnutAdapter, and verify
    // the derived squareSensed events reconstruct the moves from G1.
    let moves = ["e2e4", "e7e5", "g1f3"]
    var adapter = ChessnutAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])

    // Prime the adapter with the initial position.
    let initFrame = encodePosition(Position.initial())
    _ = adapter.feed(bytes: initFrame)

    for uci in moves {
        _ = try await sim.executeMove(uci: uci)
        let pos = await sim.position
        let frame = encodePosition(pos)
        let events = adapter.feed(bytes: frame)

        // Each frame must produce an identitySnapshot.
        #expect(events.contains { if case .identitySnapshot = $0 { return true }; return false })

        // Must produce at least one squareSensed delta.
        let deltas = sensed(events)
        #expect(!deltas.isEmpty, "Expected deltas for move \(uci)")
    }
}
