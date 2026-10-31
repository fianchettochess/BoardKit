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
    personality: inout ChessnutPersonality,
    observe: (ChessnutStoredGameImportProgress) -> Void = { _ in }
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
                observe(adapter.storedGameImportProgress)
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

@Test func notificationEndpointsKeepIndependentPartialFrames() {
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x01]), from: .commandResponse)
    _ = adapter.takePendingResponses()
    _ = adapter.feed(bytes: Data([0x37, 0x01, 0xBE]), from: .file)
    let line = ["e4", "e5", "Nf3"]
    let frames = StoredGameFixture.snapshots(line).map { ChessnutAdapter.encodeFrame(identity: $0) }
    _ = adapter.feed(bytes: Data(frames[0].prefix(10)), from: .file)
    // Leave the command stream partial too, then finish the file snapshot
    // before completing the control reply. Both accumulators must survive.
    #expect(adapter.feed(bytes: Data([0x2A, 0x02]), from: .commandResponse).isEmpty)
    #expect(adapter.feed(bytes: Data(frames[0].dropFirst(10)), from: .file).isEmpty)
    let control = adapter.feed(bytes: Data([77, 0]), from: .commandResponse)
    #expect(control.contains { if case .battery(percent: 77) = $0 { true } else { false } })
    for frame in frames.dropFirst() { _ = adapter.feed(bytes: frame, from: .file) }
    let games = importedGames(adapter.feed(bytes: Data([0x37, 0x01, 0xED]), from: .file))
    #expect(games.map(\.sans) == [line])
    #expect(games.first?.complete == true)
    #expect(adapter.storedGameImportProgress.isFinished)
}

@Test func resetClearsEveryEndpointAndLegacyAccumulator() {
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: Data([0x2A, 0x02]))
    _ = adapter.feed(bytes: Data([0x2A, 0x02]), from: .commandResponse)
    _ = adapter.feed(bytes: Data([0x37, 0x01]), from: .file)
    _ = adapter.feed(bytes: Data([0x01, 0x22]), from: .boardState)
    adapter.resetFraming()
    for endpoint in [ChessnutAdapter.NotificationEndpoint.commandResponse, .file, .boardState] {
        let events = adapter.feed(bytes: Data([0x2A, 0x02, 61, 0]), from: endpoint)
        #expect(events.contains { if case .battery(percent: 61) = $0 { true } else { false } })
    }
    let legacy = adapter.feed(bytes: Data([0x2A, 0x02, 42, 0]))
    #expect(legacy.contains { if case .battery(percent: 42) = $0 { true } else { false } })
}

@Test func duplicateCatalogCannotRestartAnActiveOrBetweenFilesDownload() {
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x02]), from: .commandResponse)
    #expect(adapter.takePendingResponses().count == 3)
    _ = adapter.feed(bytes: Data([0x37, 0x01, 0xBE]), from: .file)
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x09]), from: .commandResponse)
    #expect(adapter.storedGameImportProgress.expectedFileCount == 2)
    #expect(adapter.storedGameImportProgress.isReceivingFile)
    #expect(adapter.takePendingResponses().isEmpty)
    _ = adapter.feed(bytes: Data([0x37, 0x01, 0xED]), from: .file)
    #expect(adapter.takePendingResponses().count == 2)
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x09]), from: .commandResponse)
    #expect(adapter.storedGameImportProgress.expectedFileCount == 2)
    #expect(adapter.storedGameImportProgress.completedFileCount == 1)
    #expect(adapter.takePendingResponses().isEmpty)
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

@Test func progressTracksCatalogAndEachRealFileBoundary() {
    var adapter = ChessnutAdapter()
    #expect(adapter.storedGameImportProgress.expectedFileCount == nil)
    #expect(!adapter.storedGameImportProgress.isFinished)
    var personality = ChessnutPersonality(storedGames: [
        StoredGameFixture.snapshots(["e4", "e5"]),
        StoredGameFixture.snapshots(["d4", "d5", "c4"]),
    ])
    var progress: [ChessnutStoredGameImportProgress] = []
    let events = runStoredGameImport(adapter: &adapter, personality: &personality) { progress.append($0) }
    #expect(importedGames(events).map(\.sans) == [["e4", "e5"], ["d4", "d5", "c4"]])
    #expect(progress.contains { $0.expectedFileCount == 2 && $0.completedFileCount == 0 && !$0.isReceivingFile })
    #expect(progress.contains { $0.completedFileCount == 0 && $0.isReceivingFile })
    #expect(progress.contains { $0.completedFileCount == 1 && $0.isReceivingFile })
    #expect(progress.filter(\.isFinished).allSatisfy { $0.completedFileCount == 2 })
    #expect(adapter.storedGameImportProgress.expectedFileCount == 2)
    #expect(adapter.storedGameImportProgress.completedFileCount == 2)
    #expect(adapter.storedGameImportProgress.isFinished)
}

@Test func emptyCatalogFinishesWithoutAReconstructedGame() {
    var adapter = ChessnutAdapter()
    var personality = ChessnutPersonality(storedGames: [])
    let events = runStoredGameImport(adapter: &adapter, personality: &personality)
    // Only the live frame from returning to realtime mode; no imported game.
    #expect(importedGames(events).isEmpty)
    #expect(adapter.storedGameImportProgress.expectedFileCount == 0)
    #expect(adapter.storedGameImportProgress.completedFileCount == 0)
    #expect(adapter.storedGameImportProgress.isFinished)
}

@Test func unreadableAndEmptyFilesStillCountTowardCompletion() {
    var adapter = ChessnutAdapter()
    var personality = ChessnutPersonality(storedGames: [
        [],
        [StoredGameFixture.snapshots(["e4"]).last!],
        StoredGameFixture.snapshots([]),
    ])
    let games = importedGames(runStoredGameImport(adapter: &adapter, personality: &personality))
    #expect(games.allSatisfy { $0.sans.isEmpty })
    #expect(adapter.storedGameImportProgress.expectedFileCount == 3)
    #expect(adapter.storedGameImportProgress.completedFileCount == 3)
    #expect(adapter.storedGameImportProgress.isFinished)
}

@Test func repeatedEndCannotAdvanceTheCatalogOrRequestAnotherFile() {
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x02]))
    #expect(adapter.takePendingResponses().count == 3)
    _ = adapter.feed(bytes: Data([0x37, 0x01, 0xBE, 0x37, 0x01, 0xED]))
    #expect(adapter.storedGameImportProgress.completedFileCount == 1)
    #expect(adapter.takePendingResponses().count == 2)
    #expect(adapter.feed(bytes: Data([0x37, 0x01, 0xED])).isEmpty)
    #expect(adapter.storedGameImportProgress.completedFileCount == 1)
    #expect(!adapter.storedGameImportProgress.isFinished)
    #expect(adapter.takePendingResponses().isEmpty)
    _ = adapter.feed(bytes: Data([0x37, 0x01, 0xBE, 0x37, 0x01, 0xED]))
    #expect(adapter.storedGameImportProgress.completedFileCount == 2)
    #expect(adapter.storedGameImportProgress.isFinished)
}

@Test func framingResetClearsPartialDownloadAndProgressBeforeReconnect() {
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x03, 0x37, 0x01, 0xBE, 0x01, 0x22]))
    #expect(adapter.storedGameImportProgress.isReceivingFile)
    adapter.resetFraming()
    #expect(adapter.storedGameImportProgress.expectedFileCount == nil)
    #expect(adapter.storedGameImportProgress.completedFileCount == 0)
    #expect(!adapter.storedGameImportProgress.isReceivingFile)
    #expect(!adapter.storedGameImportProgress.isFinished)
    #expect(adapter.takePendingResponses().isEmpty)
    var personality = ChessnutPersonality(storedGames: [StoredGameFixture.snapshots(["Nf3", "d5"])])
    let games = importedGames(runStoredGameImport(adapter: &adapter, personality: &personality))
    #expect(games.map(\.sans) == [["Nf3", "d5"]])
    #expect(adapter.storedGameImportProgress.expectedFileCount == 1)
    #expect(adapter.storedGameImportProgress.isFinished)
}

@Test func importReturnsTheBoardToRealtimeSoLiveFramesResume() {
    var personality = ChessnutPersonality(storedGames: [StoredGameFixture.snapshots(["e4", "e5"])])
    var adapter = ChessnutAdapter()
    // The download's own handshake switches the board into upload mode, where
    // it streams no live frames.
    _ = personality.handleHostWrite(Data([0x21, 0x01, 0x01]))
    #expect(personality.frames(for: .squareSensed(square: "e2", isLift: true, piece: nil)).isEmpty)
    _ = personality.handleHostWrite(Data([0x21, 0x01, 0x00]))
    _ = personality.frames(for: .squareSensed(square: "e2", isLift: false, piece: nil))

    _ = runStoredGameImport(adapter: &adapter, personality: &personality)

    // After the import completes, a move on the board must reach the host.
    let live = personality.frames(for: .squareSensed(square: "d2", isLift: true, piece: nil))
    #expect(!live.isEmpty)
}

@Test func finalGameEndQueuesRealtimeModeLast() {
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x02]))
    _ = adapter.takePendingResponses()
    _ = adapter.feed(bytes: Data([0x37, 0x01, 0xBE, 0x37, 0x01, 0xED]))
    #expect(adapter.takePendingResponses().last != Data([0x21, 0x01, 0x00]))
    _ = adapter.feed(bytes: Data([0x37, 0x01, 0xBE, 0x37, 0x01, 0xED]))
    #expect(adapter.takePendingResponses() == [Data([0x21, 0x01, 0x00])])
}

@Test func emptyListingReturnsTheBoardToRealtime() {
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: Data([0x32, 0x01, 0x00]))
    #expect(adapter.takePendingResponses() == [Data([0x21, 0x01, 0x00])])
}
