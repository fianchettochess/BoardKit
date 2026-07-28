// Seam tests — capability degradation, event-stream ordering, BoardCapabilities.

import Testing
import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter
import SquareOffAdapter

// MARK: - BoardCapabilities

@Test func capabilitiesOptionSet() {
    let caps = BoardCapabilities.chessnutAirFamily
    #expect(caps.contains(.occupancySensing))
    #expect(caps.contains(.pieceIdentity))
    #expect(caps.contains(.perSquareLEDs))
    #expect(caps.contains(.moveIndication))
    #expect(caps.contains(.batteryReporting))
    // Not included in air family:
    #expect(!caps.contains(.motorised))
    #expect(!caps.contains(.perPieceTracking))
}

@Test func squareOffCapabilities() {
    let caps = BoardCapabilities.squareOff
    #expect(caps.contains(.occupancySensing))
    #expect(caps.contains(.perSquareLEDs))
    #expect(caps.contains(.moveIndication))
    #expect(!caps.contains(.pieceIdentity))
    #expect(!caps.contains(.batteryReporting))
    #expect(!caps.contains(.motorised))
}

@Test func capabilityDegradation() {
    // An occupancy-only caller uses .pieceIdentity as a predicate to decide
    // whether to run the identity path. Verify the bit is off for squareOff.
    let squareOff = BoardCapabilities.squareOff
    let chessnut  = BoardCapabilities.chessnutAirFamily

    // Identity-aware path is only activated when .pieceIdentity is set.
    #expect(!squareOff.contains(.pieceIdentity))
    #expect(chessnut.contains(.pieceIdentity))

    // An occupancy caller can safely use both adapters by checking first:
    let runIdentityPath = chessnut.contains(.pieceIdentity)
    #expect(runIdentityPath == true)

    let runOccupancyOnlyPath = squareOff.contains(.pieceIdentity)
    #expect(runOccupancyOnlyPath == false)
}

@Test func capabilityRawValueStability() {
    // Raw values are persisted in capability sets; they must not change.
    #expect(BoardCapabilities.occupancySensing.rawValue == 1 << 0)
    #expect(BoardCapabilities.pieceIdentity.rawValue    == 1 << 1)
    #expect(BoardCapabilities.perSquareLEDs.rawValue    == 1 << 2)
    #expect(BoardCapabilities.moveIndication.rawValue   == 1 << 3)
    #expect(BoardCapabilities.motorised.rawValue        == 1 << 4)
    #expect(BoardCapabilities.batteryReporting.rawValue == 1 << 5)
    #expect(BoardCapabilities.perPieceTracking.rawValue == 1 << 6)
}

// MARK: - Outbound write pacing

@Test func chessnutClassicDeclaresItsDocumentedWritePacingFloor() {
    let adapter: any BoardAdapter = ChessnutAdapter()
    #expect(adapter.minimumWriteInterval == 0.2)
}

@Test func adaptersWithoutAKnownPacingRequirementDefaultToZero() {
    let adapter: any BoardAdapter = SquareOffAdapter()
    #expect(adapter.minimumWriteInterval == 0)
}

// MARK: - ChessnutGATT profile matching

@Test func chessnutGATTProfileMatching() {
    // Air family matches.
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Air"))
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Air+"))
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Pro"))
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Go"))
    // Move is excluded (extended profile).
    #expect(!ChessnutGATT.isClassicProfile(name: "Chessnut Move"))
    // Non-Chessnut boards don't match.
    #expect(!ChessnutGATT.isClassicProfile(name: "Square Off"))
    #expect(!ChessnutGATT.isClassicProfile(name: "DGT Pegasus"))
}

// MARK: - BoardEvent ordering

@Test func boardEventOrderingFirstFrame() throws {
    // On the very first board-state frame the adapter should emit:
    //   1. .identitySnapshot
    //   2. .ready   (board is confirmed streaming)
    // No squareSensed deltas (no previous state to compare against).
    let emptyFrame = Data([
        0x01, 0x22,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    ])
    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: emptyFrame)
    // Must start with identitySnapshot.
    guard case .identitySnapshot = events.first else {
        Issue.record("First event must be .identitySnapshot; got \(String(describing: events.first))")
        return
    }
    // Second event must be .ready (first frame, no deltas).
    #expect(events.count == 2)
    guard case .ready = events[1] else {
        Issue.record("Second event must be .ready; got \(events[1])")
        return
    }
}

@Test func boardEventOrderingSubsequentFrameWithDelta() throws {
    // On the second frame with one change, event order must be:
    //   1. .identitySnapshot (updated state)
    //   2. .squareSensed (lift or place)
    let emptyFrame = Data([
        0x01, 0x22,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    ])
    // Frame with a single white pawn on e4 (s=35: byte[19] high nibble = 7).
    var secondFrame = [UInt8](repeating: 0, count: 36)
    secondFrame[0] = 0x01; secondFrame[1] = 0x22
    secondFrame[19] = 0x70   // e4 high nibble = P (0x7), f4 low nibble stays 0
    let secondData = Data(secondFrame)

    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: emptyFrame)       // prime state
    let events = adapter.feed(bytes: secondData)

    guard case .identitySnapshot = events.first else {
        Issue.record("First event must be .identitySnapshot")
        return
    }
    #expect(events.count >= 2)
    let sensed = events.compactMap { (event: BoardEvent) -> Bool? in
        if case .squareSensed = event { return true }
        return nil
    }
    #expect(sensed.count == 1)
}

// MARK: - BoardTransportState equality

@Test func boardTransportStateEquality() {
    #expect(BoardTransportState.idle == .idle)
    #expect(BoardTransportState.connected == .connected)
    #expect(BoardTransportState.reconnecting(attempt: 1) == .reconnecting(attempt: 1))
    #expect(BoardTransportState.reconnecting(attempt: 1) != .reconnecting(attempt: 2))
}

// MARK: - DiscoveredBoardDevice

@Test func discoveredBoardDeviceEquality() {
    let id = UUID()
    let d1 = DiscoveredBoardDevice(id: id, name: "Chessnut Air", rssi: -65, token: "tok")
    let d2 = DiscoveredBoardDevice(id: id, name: "Chessnut Air", rssi: -65, token: "tok")
    #expect(d1 == d2)
    let d3 = DiscoveredBoardDevice(id: UUID(), name: "Chessnut Air", rssi: -65, token: "tok")
    #expect(d1 != d3)
}

// MARK: - LEDStyle

@Test func ledStyleCustomValue() {
    if case .custom(let v) = LEDStyle.custom(42) {
        #expect(v == 42)
    } else {
        Issue.record("LEDStyle.custom should carry its raw value")
    }
}

// MARK: - BoardEvent raw passthrough

@Test func rawEventPassthrough() throws {
    // An unknown opcode (e.g. 0xFF) should surface as .raw.
    let unknownFrame = Data([0xFF, 0x02, 0xAB, 0xCD])
    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: unknownFrame)
    #expect(events.count == 1)
    guard case .raw(let d) = events[0] else {
        Issue.record("Unknown opcode must produce .raw event")
        return
    }
    #expect(d == unknownFrame)
}
