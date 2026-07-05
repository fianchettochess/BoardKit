// Golden-frame tests — every fixture from the pinned spec, encode AND decode.
//
// Each fixture is labelled G1–G9 matching the spec.  G7 is the orientation
// canary (doubly source-confirmed LED bit order); G2's two-byte diff is the
// nibble-parity canary for board-frame decode.

import Testing
import Foundation
import ChessCore
@testable import ChessnutAdapter
import BoardKit

// MARK: - Helpers

/// Unwrap an identitySnapshot from a list of events.
private func firstIdentitySnapshot(from events: [BoardEvent]) -> [Piece?]? {
    for event in events {
        if case .identitySnapshot(let id) = event { return id }
    }
    return nil
}

/// File-major index: file * 8 + rank (0-indexed).
private func fileMajorIndex(file: Int, rank: Int) -> Int { file * 8 + rank }

/// Piece at an algebraic square in a file-major identity array.
private func piece(at algebraic: String, in identity: [Piece?]) -> Piece? {
    guard let sq = Square(algebraic: algebraic) else { return nil }
    return identity[fileMajorIndex(file: sq.file, rank: sq.rank)]
}

// MARK: - G1: Initial position (decode)

@Test func g1DecodeInitialPosition() throws {
    let g1Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x77, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])
    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: g1Bytes)
    let identity = try #require(firstIdentitySnapshot(from: events))
    #expect(identity.count == 64)

    // Rank 8 (black pieces): a8..h8
    #expect(piece(at: "a8", in: identity) == Piece(type: .rook,   color: .black))
    #expect(piece(at: "b8", in: identity) == Piece(type: .knight, color: .black))
    #expect(piece(at: "c8", in: identity) == Piece(type: .bishop, color: .black))
    #expect(piece(at: "d8", in: identity) == Piece(type: .queen,  color: .black))
    #expect(piece(at: "e8", in: identity) == Piece(type: .king,   color: .black))
    #expect(piece(at: "f8", in: identity) == Piece(type: .bishop, color: .black))
    #expect(piece(at: "g8", in: identity) == Piece(type: .knight, color: .black))
    #expect(piece(at: "h8", in: identity) == Piece(type: .rook,   color: .black))

    // Rank 7 (black pawns)
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(piece(at: "\(file)7", in: identity) == Piece(type: .pawn, color: .black))
    }

    // Ranks 3–6 empty
    for rank in 3...6 {
        for file in ["a","b","c","d","e","f","g","h"] {
            #expect(piece(at: "\(file)\(rank)", in: identity) == nil)
        }
    }

    // Rank 2 (white pawns)
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(piece(at: "\(file)2", in: identity) == Piece(type: .pawn, color: .white))
    }

    // Rank 1 (white pieces): a1..h1
    #expect(piece(at: "a1", in: identity) == Piece(type: .rook,   color: .white))
    #expect(piece(at: "b1", in: identity) == Piece(type: .knight, color: .white))
    #expect(piece(at: "c1", in: identity) == Piece(type: .bishop, color: .white))
    #expect(piece(at: "d1", in: identity) == Piece(type: .queen,  color: .white))
    #expect(piece(at: "e1", in: identity) == Piece(type: .king,   color: .white))
    #expect(piece(at: "f1", in: identity) == Piece(type: .bishop, color: .white))
    #expect(piece(at: "g1", in: identity) == Piece(type: .knight, color: .white))
    #expect(piece(at: "h1", in: identity) == Piece(type: .rook,   color: .white))

    // Spec sentinels:
    // low nibble byte[2] = 8 = black rook on h8
    #expect(piece(at: "h8", in: identity) == Piece(type: .rook, color: .black))
    // high nibble byte[31] = 0xC = white king on e1
    #expect(piece(at: "e1", in: identity) == Piece(type: .king, color: .white))
    // high nibble byte[33] = 6 = white rook on a1
    #expect(piece(at: "a1", in: identity) == Piece(type: .rook, color: .white))
}

// MARK: - G1: Encode round-trip

@Test func g1EncodeRoundTrip() throws {
    // Build a file-major identity array for the initial position and
    // encode it; the result must match the G1 bytes byte-for-byte.
    let g1Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x77, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])

    // Decode to identity snapshot.
    var adapter = ChessnutAdapter()
    let decodeEvents = adapter.feed(bytes: g1Bytes)
    let identity = try #require(firstIdentitySnapshot(from: decodeEvents))

    // Re-encode.
    let encoded = ChessnutAdapter.encodeFrame(identity: identity)
    #expect(encoded == g1Bytes)
}

// MARK: - G2: After 1.e4 (nibble-parity canary)

@Test func g2DecodeAfterE4() throws {
    let g2Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x07, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])
    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: g2Bytes)
    let identity = try #require(firstIdentitySnapshot(from: events))

    // Nibble-parity canary: e4 occupied (white pawn), e2 empty.
    #expect(piece(at: "e4", in: identity) == Piece(type: .pawn, color: .white))
    #expect(piece(at: "e2", in: identity) == nil)
    // f4 and f2 unchanged from initial position (empty / white pawn).
    #expect(piece(at: "f4", in: identity) == nil)
    #expect(piece(at: "f2", in: identity) == Piece(type: .pawn, color: .white))
}

@Test func g2DeltaEventsFromG1() throws {
    // Feed G1 first, then G2; expect exactly two squareSensed deltas.
    let g1Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x77, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])
    let g2Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x07, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: g1Bytes)    // prime the previous-state
    let events = adapter.feed(bytes: g2Bytes)

    let sensed = events.compactMap { event -> (square: String, isLift: Bool, piece: Piece?)? in
        if case .squareSensed(let sq, let isLift, let piece) = event {
            return (sq, isLift, piece)
        }
        return nil
    }
    // Exactly two delta events: lift e2, place e4.
    #expect(sensed.count == 2)
    let liftEvent  = sensed.first { $0.isLift }
    let placeEvent = sensed.first { !$0.isLift }
    #expect(liftEvent?.square  == "e2")
    #expect(placeEvent?.square == "e4")
    #expect(liftEvent?.piece   == Piece(type: .pawn, color: .white))
    #expect(placeEvent?.piece  == Piece(type: .pawn, color: .white))
}

// MARK: - G3: Empty board

@Test func g3DecodeEmptyBoard() throws {
    let g3Bytes = Data([
        0x01, 0x22,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    ])
    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: g3Bytes)
    let identity = try #require(firstIdentitySnapshot(from: events))
    #expect(identity.allSatisfy { $0 == nil })
}

// MARK: - G4: LED command e2 + e4

@Test func g4LEDEncodeE2PlusE4() throws {
    let expected = Data([0x0A, 0x08, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00])
    let adapter = ChessnutAdapter()
    let encoded = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
    #expect(encoded == expected)
}

// MARK: - G5: Realtime-mode handshake

@Test func g5RealtimeModeHandshake() throws {
    let adapter = ChessnutAdapter()
    let firstConnect = adapter.handshakeCommands(isReconnect: false)
    #expect(firstConnect.count == 1)
    let cmd = firstConnect[0].command
    let data = adapter.encode(cmd)
    #expect(data == Data([0x21, 0x01, 0x00]))
    #expect(firstConnect[0].delayBefore == .zero)
}

@Test func g5ReconnectHandshake() throws {
    let adapter = ChessnutAdapter()
    let reconnect = adapter.handshakeCommands(isReconnect: true)
    #expect(reconnect.count == 1)
    let data = adapter.encode(reconnect[0].command)
    #expect(data == Data([0x21, 0x01, 0x00]))
    #expect(reconnect[0].delayBefore == 0.25)
}

// MARK: - G6: Battery request/response

@Test func g6BatteryRequest() {
    let data = ChessnutAdapter.batteryRequestData()
    #expect(data == Data([0x29, 0x01, 0x00]))
}

@Test func g6BatteryResponseCharging67() throws {
    // 0xC3 = 0x80 | 67 → charging = true, 67 %
    let frame = Data([0x2A, 0x02, 0xC3, 0x00])
    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: frame)
    #expect(events.count == 1)
    guard case .battery(let pct) = events[0] else {
        Issue.record("Expected .battery event, got \(events[0])")
        return
    }
    #expect(pct == 67)
}

@Test func g6BatteryResponseNotCharging67() throws {
    // 0x43 = 67 (no charging flag)
    let frame = Data([0x2A, 0x02, 0x43, 0x00])
    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: frame)
    #expect(events.count == 1)
    guard case .battery(let pct) = events[0] else {
        Issue.record("Expected .battery event, got \(events[0])")
        return
    }
    #expect(pct == 67)
}

// MARK: - G7: LED c4 only (doubly source-confirmed canary)

/// This exact byte string is independently derivable from:
///   [C-REF] README c4 example: leds[4]="00100000", leftmost=a-file=MSB → 0x20
///   [SWIFT-REF] testClassicLEDCommandUsesEightBitRows: fileIndex=2, rankIndex=4
///     → [0x0A, 0x08, 0,0,0,0, 0x20, 0,0,0]
/// Any deviation from this exact output is a bit-order regression.
@Test func g7LEDC4OrientationCanary() throws {
    let expected = Data([0x0A, 0x08, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00])
    let adapter = ChessnutAdapter()
    let encoded = adapter.encode(.indicateSquares(["c4"], style: .highlight))
    #expect(encoded == expected)
}

// MARK: - G8: Beep 1000 Hz / 200 ms

@Test func g8BeepEncode() {
    // freq 1000 = 0x03E8, duration 200 = 0x00C8
    let expected = Data([0x0B, 0x04, 0x03, 0xE8, 0x00, 0xC8])
    let data = ChessnutAdapter.beepData(frequency: 1000, duration: 200)
    #expect(data == expected)
}

// MARK: - G9: OTB file-transfer flags

@Test func g9FileFlagsPassThroughAsRaw() throws {
    // 37 01 BE = file transmission starting; 37 01 ED = finished.
    // The adapter doesn't model OTB import yet; unknown opcodes pass through
    // as .raw for callers to handle.
    var adapter = ChessnutAdapter()
    let startFlag = Data([0x37, 0x01, 0xBE])
    let endFlag   = Data([0x37, 0x01, 0xED])
    let startEvents = adapter.feed(bytes: startFlag)
    let endEvents   = adapter.feed(bytes: endFlag)

    guard case .raw(let rawData) = startEvents.first else {
        Issue.record("Expected .raw for file-start flag")
        return
    }
    #expect(rawData == startFlag)

    guard case .raw(let rawData2) = endEvents.first else {
        Issue.record("Expected .raw for file-end flag")
        return
    }
    #expect(rawData2 == endFlag)
}

// MARK: - Square-index math spot checks

/// Verify the protocolSquareToFileMajor conversion against the spec's
/// named sentinels.
@Test func squareIndexMathSentinels() {
    // s=0  → h8 → file=7, rank=7 → fileMajor=63
    #expect(ChessnutAdapter.protocolSquareToFileMajor(0) == 63)
    // s=63 → a1 → file=0, rank=0 → fileMajor=0
    #expect(ChessnutAdapter.protocolSquareToFileMajor(63) == 0)
    // s=35 → e4 → file=4, rank=3 → fileMajor=35
    #expect(ChessnutAdapter.protocolSquareToFileMajor(35) == 35)
    // s=51 → e2 → file=4, rank=1 → fileMajor=33
    #expect(ChessnutAdapter.protocolSquareToFileMajor(51) == 33)
    // s=59 → e1 → file=4, rank=0 → fileMajor=32
    #expect(ChessnutAdapter.protocolSquareToFileMajor(59) == 32)
}

// MARK: - Framing: partial delivery

@Test func partialFrameAccumulation() throws {
    // Split G3 (empty board, 36 bytes) across two deliveries; should
    // emit events only after the second delivery completes the frame.
    let full = Data([
        0x01, 0x22,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    ])
    let part1 = full.prefix(10)
    let part2 = full.dropFirst(10)

    var adapter = ChessnutAdapter()
    let events1 = adapter.feed(bytes: part1)
    #expect(events1.isEmpty)
    let events2 = adapter.feed(bytes: part2)
    #expect(!events2.isEmpty)
    #expect(firstIdentitySnapshot(from: events2) != nil)
}

// MARK: - Regression: .ready gating (findings 1+3)

/// Finding 3 regression: feeding the same frame twice must yield exactly
/// one .ready (the first feed), not two (the duplicate-fire bug).
/// This is the heartbeat / no-delta repeat path.
@Test func readyEmittedExactlyOnceAcrossTwoIdenticalFrames() {
    let g1Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x77, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])
    var adapter = ChessnutAdapter()
    let first  = adapter.feed(bytes: g1Bytes)
    let second = adapter.feed(bytes: g1Bytes)   // identical repeat / heartbeat

    let readyCount = (first + second).filter {
        if case .ready = $0 { return true }; return false
    }.count
    #expect(readyCount == 1, "Expected exactly one .ready across both feeds; got \(readyCount)")
}

/// Finding 1 regression: a first frame that contains an invalid nibble
/// (0xD–0xF) must still emit .ready.  The .raw flag appended for the
/// invalid nibble must not prevent .ready from being emitted.
@Test func readyEmittedOnFirstFrameWithInvalidNibble() {
    // Build an otherwise-valid 36-byte board-state frame but corrupt
    // the HIGH nibble of byte[2] to 0xD (invalid per spec).
    // byte[2] low nibble = h8, high nibble = g8.
    // Setting high nibble to 0xD leaves h8 as 0x8 (black rook, valid).
    var frame = [UInt8](repeating: 0, count: 36)
    frame[0] = 0x01; frame[1] = 0x22
    frame[2] = 0xD8   // high nibble = 0xD (invalid), low nibble = 8 (black rook)

    var adapter = ChessnutAdapter()
    let events = adapter.feed(bytes: Data(frame))

    // Must contain .identitySnapshot.
    #expect(events.contains { if case .identitySnapshot = $0 { return true }; return false },
            "Expected .identitySnapshot even on a frame with an invalid nibble")

    // Must contain .raw (the corruption flag).
    #expect(events.contains { if case .raw = $0 { return true }; return false },
            "Expected .raw event for the invalid nibble")

    // Must still contain .ready (finding 1: .raw must not suppress .ready).
    let readyCount = events.filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "Expected .ready on first frame even when an invalid nibble appends .raw; got \(readyCount)")
}

// MARK: - Regression: resetFraming (finding 2)

/// Finding 2 regression: after feeding a partial frame and calling
/// resetFraming(), feeding a complete G1 frame produces a clean decode
/// and emits .ready (previousIdentity cleared → re-armed).
@Test func resetFramingClearsBufferAndReArmsReady() throws {
    let g1Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x77, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])

    var adapter = ChessnutAdapter()

    // Feed a partial frame (simulates a mid-frame disconnect).
    let partialEvents = adapter.feed(bytes: g1Bytes.prefix(10))
    #expect(partialEvents.isEmpty, "Partial frame must buffer silently")

    // Simulate link drop + reconnect: reset the framing state.
    adapter.resetFraming()

    // Feed a full G1 frame on the new link.
    let events = adapter.feed(bytes: g1Bytes)

    // Must decode cleanly to identitySnapshot.
    let snapshot = firstIdentitySnapshot(from: events)
    #expect(snapshot != nil, "Expected identitySnapshot after resetFraming + full frame")

    // Must re-emit .ready (previousIdentity was cleared by resetFraming).
    #expect(events.contains { if case .ready = $0 { return true }; return false },
            "Expected .ready after resetFraming (previousIdentity re-armed)")

    // No squareSensed deltas (previousIdentity was nil → first-frame path).
    let deltaCount = events.filter {
        if case .squareSensed = $0 { return true }; return false
    }.count
    #expect(deltaCount == 0, "Expected no squareSensed deltas after resetFraming (clean first-frame path)")
}
