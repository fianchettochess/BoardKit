// ChessnutMovePersonalityTests.swift
// The Chessnut Move personality and ChessnutMoveAdapter agree in both
// directions. (Fianchetto-b32.57)

import Testing
import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport
import BoardKitEmulator

private func notified(_ actions: [PeripheralAction]) -> [PersonalityFrame] {
    actions.compactMap { if case .notify(let frame) = $0 { return frame }; return nil }
}

private func feed(_ adapter: inout ChessnutMoveAdapter, _ frame: PersonalityFrame) -> [BoardEvent] {
    let endpoint: ChessnutNotificationEndpoint =
        frame.characteristicUUID == ChessnutGATT.commandResponseChar ? .commandResponse : .boardState
    return adapter.feed(bytes: frame.data, from: endpoint)
}

/// Gates: what the host adapter encodes for the Move's motor and LEDs is what
/// the emulated board executes, and the board's answer decodes to that result.
/// Breaks if: the auto-move target or LED nibble layout drifts on either side.
/// User loses: on a real Move a dictated move lands on the wrong square (the
/// robot moves pieces the player did not expect) or the wrong squares light.
@Test func moveMotorAndLEDCommandsRoundTrip() async throws {
    var personality = ChessnutMovePersonality()
    var adapter = ChessnutMoveAdapter()
    // Realtime mode: the board answers with its state, which the adapter
    // needs before it can encode an auto-move target.
    for frame in notified(personality.handleHostWrite(try #require(adapter.encode(.startSession)))) {
        _ = feed(&adapter, frame)
    }

    let move = try #require(adapter.encode(.executeMove(uci: "g1f3")))
    var after: [Piece?]?
    for frame in notified(personality.handleHostWrite(move)) {
        for event in feed(&adapter, frame) {
            if case .identitySnapshot(let identity) = event { after = identity }
        }
    }
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])
    _ = try await sim.executeMove(uci: "g1f3")
    guard case .identitySnapshot(let expected) = await sim.boardSnapshot() else {
        Issue.record("identity board produced no identity snapshot")
        return
    }
    #expect(after == expected)

    let leds = try #require(adapter.encode(.indicateSquares(["e2", "e4"], style: .moveTo)))
    #expect(personality.handleHostWrite(leds) == [.setLEDs(["e2", "e4"])])
}

/// Gates: the Move's command-response replies (battery, 139-byte piece
/// status, sent in 20-byte notifications) decode on their own endpoint while
/// board frames keep streaming on theirs.
/// Breaks if: the reply or board-frame shapes drift from what a Move sends, or
/// the adapter's endpoints share a framing buffer again.
/// User loses: battery never shows, or polling piece positions freezes the
/// live board.
@Test func moveRepliesDecodeBesideTheBoardStream() async throws {
    var personality = ChessnutMovePersonality(batteryPercent: 64, isCharging: true)
    var adapter = ChessnutMoveAdapter()
    var events: [BoardEvent] = []
    for frame in notified(personality.handleHostWrite(Data([0x21, 0x01, 0x00]))) { events += feed(&adapter, frame) }

    let replies = notified(personality.handleHostWrite(ChessnutMoveAdapter.pieceStatusRequestData()))
        + notified(personality.handleHostWrite(ChessnutMoveAdapter.batteryRequestData()))
    let board = personality.frames(for: .squareSensed(square: "e2", isLift: true, piece: nil))
        + personality.frames(for: .squareSensed(square: "e4", isLift: false, piece: nil))
    // The Move's own 38-byte layout, not the Air's 36 (both decode on the host).
    #expect(board.allSatisfy { $0.data.count == 38 && $0.data.prefix(2) == Data([0x01, 0x24]) })
    // Interleave the reply notifications with the board frames.
    for i in 0..<max(replies.count, board.count) {
        if i < replies.count { events += feed(&adapter, replies[i]) }
        if i < board.count { events += feed(&adapter, board[i]) }
    }

    let raws = events.compactMap { event -> Data? in if case .raw(let d) = event { return d }; return nil }
    #expect(raws.count == 1)
    #expect(raws.first?.prefix(3) == Data([0x41, 0x89, 0x0B]))
    #expect(raws.first?.count == 139)
    // The white king is the 17th record: identity 6 (white king).
    #expect(raws.first.map { $0[3 + 16 * 4] } == 6)
    #expect(events.contains { if case .battery(64, _) = $0 { return true }; return false })
    let sensed = events.compactMap { event -> String? in
        if case .squareSensed(let square, let isLift, _) = event { return "\(isLift ? "lift" : "place") \(square)" }
        return nil
    }
    #expect(sensed == ["lift e2", "place e4"])
}
