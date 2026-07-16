// Stored-game import round-trip: the ChessnutPersonality's on-flash archive,
// streamed over the file characteristic through the real download handshake,
// must reconstruct back to the games that were stored — end to end, with no
// physical board. This exercises ChessnutAdapter's file-transfer state machine
// (0x31 → 0x32 → mode/0x33/0x34 → 0x37 BE/ED) against the emulator peripheral.

import Testing
import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter
import BoardKitEmulator

private enum StoredGameFixture {
    /// File-major identity snapshots for a legal SAN line (anchor + one per move).
    static func snapshots(_ sans: [String]) -> [[Piece?]] {
        var position = Position.initial()
        var snaps: [[Piece?]] = [fileMajor(position)]
        for san in sans {
            let legal = MoveGenerator.legalMoves(for: position)
            guard let uci = UCIParser.sanToUCI(san, in: position),
                  let move = legal.first(where: { $0.uci == uci }) else {
                Issue.record("illegal fixture move \(san)")
                return snaps
            }
            MoveGenerator.applyMoveUnchecked(&position, move)
            snaps.append(fileMajor(position))
        }
        return snaps
    }

    static func fileMajor(_ position: Position) -> [Piece?] {
        var identity = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {
                identity[file * 8 + rank] = position.board[rank * 8 + file]
            }
        }
        return identity
    }
}

/// Drive the full download handshake between a host adapter and an emulator
/// peripheral until it converges, returning every event the adapter emitted.
private func runStoredGameImport(
    adapter: inout ChessnutAdapter,
    personality: inout ChessnutPersonality
) -> [BoardEvent] {
    var events: [BoardEvent] = []
    var hostWrites: [Data] = [adapter.encode(.requestStoredGames)!]
    var iterations = 0
    while !hostWrites.isEmpty {
        iterations += 1
        precondition(iterations < 1000, "handshake did not converge")
        var next: [Data] = []
        for write in hostWrites {
            for action in personality.handleHostWrite(write) {
                guard case .notify(let frame) = action else { continue }
                events += adapter.feed(bytes: frame.data)
                next += adapter.takePendingResponses()
            }
        }
        hostWrites = next
    }
    return events
}

private func importedGames(_ events: [BoardEvent]) -> [(sans: [String], complete: Bool)] {
    events.compactMap { event in
        if case .storedGameImported(_, let sanMoves, let isComplete) = event {
            return (sanMoves, isComplete)
        }
        return nil
    }
}

@Test func importsSingleSeededGame() {
    let sans = ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"]
    var personality = ChessnutPersonality(storedGames: [StoredGameFixture.snapshots(sans)])
    var adapter = ChessnutAdapter()

    let games = importedGames(runStoredGameImport(adapter: &adapter, personality: &personality))
    #expect(games.count == 1)
    #expect(games.first?.complete == true)
    #expect(games.first?.sans == sans)
}

@Test func importsMultipleSeededGamesInOrder() {
    let g1 = ["e4", "e5", "Nf3"]
    let g2 = ["d4", "d5", "c4", "e6"]
    var personality = ChessnutPersonality(storedGames: [
        StoredGameFixture.snapshots(g1),
        StoredGameFixture.snapshots(g2),
    ])
    var adapter = ChessnutAdapter()

    let games = importedGames(runStoredGameImport(adapter: &adapter, personality: &personality))
    #expect(games.count == 2)
    #expect(games.map(\.sans) == [g1, g2])
}

@Test func emptyArchiveImportsNothing() {
    var personality = ChessnutPersonality(storedGames: [])
    var adapter = ChessnutAdapter()
    let games = importedGames(runStoredGameImport(adapter: &adapter, personality: &personality))
    #expect(games.isEmpty)
}

@Test func liveplayIsRecordedThenImported() {
    // Drive the board by feeding successive full-board identity snapshots (a
    // legitimate way to move the emulator's mirror). The personality records
    // each settled position; a later import must replay the game back.
    let sans = ["e4", "c5", "Nf3", "d6"]
    let snaps = StoredGameFixture.snapshots(sans)
    var personality = ChessnutPersonality()
    for snapshot in snaps {
        _ = personality.frames(for: .identitySnapshot(snapshot))
    }

    var adapter = ChessnutAdapter()
    let games = importedGames(runStoredGameImport(adapter: &adapter, personality: &personality))
    #expect(games.count == 1)
    #expect(games.first?.sans == sans)
}

@Test func adapterAdvertisesGameArchiveCapability() {
    #expect(ChessnutAdapter().capabilities.contains(.gameArchive))
}
