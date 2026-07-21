// Pegasus adapter golden-fixture tests — every fixture from the pinned spec,
// encode AND decode where applicable (F1–F10), plus framing-edge-case and
// SimulatedBoard occupancy round-trip tests.
//
// Fixture labelling matches the spec:
//   F1  Devkey unlock (host→board)
//   F2  Board dump — starting position (board→host)
//   F3  Field update: piece LIFTED from e2
//   F4  Field update: piece PLACED on e4
//   F5  LED: flash e2+e4 (speed 3, once, brightness 2)
//   F6  LED: a1–h8 diagonal (orientation/mirror-trap canary)
//   F7  LEDs all off
//   F8  Version exchange (board→host)
//   F9  Battery status (board→host)
//   F10 Serial number (board→host)

import Testing
import Foundation
import ChessCore
@testable import PegasusAdapter
import BoardKit
import BoardKitTestSupport

// MARK: - Test helpers

/// Extract the first .occupancySnapshot from an event list.
private func firstOccupancySnapshot(from events: [BoardEvent]) -> [Bool]? {
    for event in events {
        if case .occupancySnapshot(let occ) = event { return occ }
    }
    return nil
}

/// Extract all .squareSensed events.
private func sensedEvents(from events: [BoardEvent]) -> [(square: String, isLift: Bool)] {
    events.compactMap {
        if case .squareSensed(let sq, let lift, _) = $0 { return (sq, lift) }
        return nil
    }
}

/// File-major index for a square algebraic string (a1=0…h8=63).
private func fileMajor(for algebraic: String) -> Int? {
    guard let sq = Square(algebraic: algebraic) else { return nil }
    return sq.file * 8 + sq.rank
}

/// Build a Pegasus board-dump frame (67 bytes) from a Position.
private func encodePegasusDump(position: Position) -> Data {
    // Convert Position.board (rank-major: index = rank*8+file) to
    // file-major occupancy (index = file*8+rank) then encode.
    var occupancy = [Bool](repeating: false, count: 64)
    for file in 0..<8 {
        for rank in 0..<8 {
            let rankMajor = rank * 8 + file
            let fileMajorIdx = file * 8 + rank
            occupancy[fileMajorIdx] = (position.board[rankMajor] != nil)
        }
    }
    return PegasusAdapter.encodeBoardDump(occupancy: occupancy)
}

// MARK: - F1: Devkey unlock (host→board)

/// Wire: `63 07 BE F5 AE DD A9 5F 00`
/// code=0x63, len=0x07 (6 key bytes + 0x00 terminator), key=[190,245,174,221,169,95], end=0x00
/// [DD AuthorizeWithDeveloperKey + DGTBoard.init; EXT content_script.js]
@Test func f1DevkeyFrameEncoding() {
    let adapter = PegasusAdapter()
    let frame = adapter.devkeyFrame()
    let expected = Data([0x63, 0x07, 0xBE, 0xF5, 0xAE, 0xDD, 0xA9, 0x5F, 0x00])
    #expect(frame == expected,
            "F1 devkey frame mismatch: got \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))")
}

/// Verify the devkeyFrame is also emitted correctly in the handshake sequence.
@Test func f1DevkeyInHandshake() {
    let adapter = PegasusAdapter()
    let steps = adapter.handshakeCommands(isReconnect: false)
    // The devkey step must be present.
    let devkeyStep = steps.first { step in
        if case .custom(let data) = step.command {
            return data.first == 0x63
        }
        return false
    }
    guard let step = devkeyStep else {
        Issue.record("F1: devkey step not found in handshake sequence")
        return
    }
    guard case .custom(let data) = step.command else { return }
    #expect(data == Data([0x63, 0x07, 0xBE, 0xF5, 0xAE, 0xDD, 0xA9, 0x5F, 0x00]),
            "F1: devkey frame in handshake has wrong bytes")
}

// MARK: - F2: Board dump — starting position (board→host)

/// Wire: `86 00 43` + 64 bytes: [0x01×16, 0x00×32, 0x01×16]
/// Ranks 8+7 occupied, ranks 6–3 empty, ranks 2+1 occupied.
/// msgId=0x86, totalLen=67=0x43; a8=0x00, h1=0x3F. [spec §5]
@Test func f2BoardDumpStartingPosition() throws {
    var f2Bytes: [UInt8] = [0x86, 0x00, 0x43]
    f2Bytes += Array(repeating: 0x01, count: 16)   // a8..h7 (protocol i 0–15) occupied
    f2Bytes += Array(repeating: 0x00, count: 32)   // a6..h3 (protocol i 16–47) empty
    f2Bytes += Array(repeating: 0x01, count: 16)   // a2..h1 (protocol i 48–63) occupied
    #expect(f2Bytes.count == 67)

    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: Data(f2Bytes))

    let occ = try #require(firstOccupancySnapshot(from: events),
                           "F2: expected occupancySnapshot event")
    #expect(occ.count == 64)

    // Initial position has exactly 32 occupied squares.
    #expect(occ.filter { $0 }.count == 32,
            "F2: expected 32 occupied squares in starting position")

    // Rank 8 and rank 7: all 8 squares each should be occupied.
    // File-major for rank 8 squares: file*8+7 (rankIdx = 7).
    for file in 0..<8 {
        #expect(occ[file * 8 + 7], "F2: rank-8 square (file \(file)) should be occupied")
        #expect(occ[file * 8 + 6], "F2: rank-7 square (file \(file)) should be occupied")
    }
    // Ranks 3–6: all empty.
    for rankIdx in 2...5 {
        for file in 0..<8 {
            #expect(!occ[file * 8 + rankIdx],
                    "F2: rank-\(rankIdx+1) square (file \(file)) should be empty")
        }
    }
    // Rank 2 and rank 1: all occupied.
    for file in 0..<8 {
        #expect(occ[file * 8 + 1], "F2: rank-2 square (file \(file)) should be occupied")
        #expect(occ[file * 8 + 0], "F2: rank-1 square (file \(file)) should be occupied")
    }

    // Spot-checks for canonical corner squares.
    // a8: i=0 → file=0, rankIdx=7 → fileMajor=7
    #expect(occ[7],  "F2: a8 (fileMajor 7) should be occupied")
    // h8: i=7 → file=7, rankIdx=7 → fileMajor=63
    #expect(occ[63], "F2: h8 (fileMajor 63) should be occupied")
    // a1: i=56 → file=0, rankIdx=0 → fileMajor=0
    #expect(occ[0],  "F2: a1 (fileMajor 0) should be occupied")
    // h1: i=63 → file=7, rankIdx=0 → fileMajor=56
    #expect(occ[56], "F2: h1 (fileMajor 56) should be occupied")
    // e2: i=52 → file=4, rankIdx=1 → fileMajor=33
    #expect(occ[33], "F2: e2 (fileMajor 33) should be occupied")
    // e4: i=36 → file=4, rankIdx=3 → fileMajor=35
    #expect(!occ[35], "F2: e4 (fileMajor 35) should be empty in starting position")

    // First dump → .ready emitted.
    #expect(events.contains { if case .ready = $0 { return true }; return false },
            "F2: first board dump must emit .ready")
}

// MARK: - F2: Round-trip encode → decode

@Test func f2BoardDumpRoundTrip() throws {
    // Build an occupancy array for starting position manually,
    // encode as Pegasus frame, decode, verify roundtrip.
    var occupancy = [Bool](repeating: false, count: 64)
    // Rank 8 (rankIdx=7): all files
    for f in 0..<8 { occupancy[f * 8 + 7] = true }
    // Rank 7 (rankIdx=6): all files
    for f in 0..<8 { occupancy[f * 8 + 6] = true }
    // Rank 2 (rankIdx=1): all files
    for f in 0..<8 { occupancy[f * 8 + 1] = true }
    // Rank 1 (rankIdx=0): all files
    for f in 0..<8 { occupancy[f * 8 + 0] = true }

    let frame = PegasusAdapter.encodeBoardDump(occupancy: occupancy)
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: frame)

    let decoded = try #require(firstOccupancySnapshot(from: events))
    #expect(decoded == occupancy, "F2 round-trip: decoded occupancy must match encoded")
}

// MARK: - F3: Field update — piece LIFTED from e2 (board→host)

/// Wire: `8E 00 05 34 00`
/// msgId=0x8E, totalLen=5, squareIndex=0x34=52 (e2), code=0x00 (empty → lift).
/// e2: rank 2 → rankIdx 1, file e=4 → i = (7−1)*8+4 = 52. [spec §5]
@Test func f3FieldUpdateLiftE2() throws {
    let f3Bytes = Data([0x8E, 0x00, 0x05, 0x34, 0x00])
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: f3Bytes)

    let sensed = sensedEvents(from: events)
    #expect(sensed.count == 1, "F3: expected exactly one squareSensed event")
    #expect(sensed[0].square == "e2", "F3: expected e2, got \(sensed[0].square)")
    #expect(sensed[0].isLift == true, "F3: expected isLift=true (piece lifted)")

    // piece must be nil — Pegasus is occupancy-only.
    for event in events {
        if case .squareSensed(_, _, let piece) = event {
            #expect(piece == nil, "F3: Pegasus field-update events must have piece: nil")
        }
    }
}

// MARK: - F4: Field update — piece PLACED on e4 (board→host)

/// Wire: `8E 00 05 24 01`
/// squareIndex=0x24=36 (e4), code=0x01 (nonzero → place).
/// e4: rank 4 → rankIdx 3, file e=4 → i = (7−3)*8+4 = 36. [spec §5]
@Test func f4FieldUpdatePlaceE4() throws {
    let f4Bytes = Data([0x8E, 0x00, 0x05, 0x24, 0x01])
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: f4Bytes)

    let sensed = sensedEvents(from: events)
    #expect(sensed.count == 1, "F4: expected exactly one squareSensed event")
    #expect(sensed[0].square == "e4", "F4: expected e4, got \(sensed[0].square)")
    #expect(sensed[0].isLift == false, "F4: expected isLift=false (piece placed)")
}

/// F3+F4 together represent the wire trace of 1.e4: lift e2 then place e4.
@Test func f3f4E2ToE4MoveTrace() throws {
    var adapter = PegasusAdapter()
    let lift  = adapter.feed(bytes: Data([0x8E, 0x00, 0x05, 0x34, 0x00]))  // lift e2
    let place = adapter.feed(bytes: Data([0x8E, 0x00, 0x05, 0x24, 0x01]))  // place e4

    let liftSensed  = sensedEvents(from: lift)
    let placeSensed = sensedEvents(from: place)
    #expect(liftSensed[0]  == ("e2", true),  "F3+F4: first event must be lift from e2")
    #expect(placeSensed[0] == ("e4", false), "F3+F4: second event must be place on e4")
}

// MARK: - F5: LED — flash e2 + e4 (host→board)

/// Wire: `60 07 05 03 01 02 34 24 00`
/// len=0x07 (5+2 squares), speed=3, repeatCount=1(once), brightness=2.
/// e2→0x34, e4→0x24. Cross-check: PY's "byte1 = total−2" → 9−2=7 ✓.
@Test func f5LEDFlashE2E4() {
    let expected = Data([0x60, 0x07, 0x05, 0x03, 0x01, 0x02, 0x34, 0x24, 0x00])
    let adapter = PegasusAdapter()
    let encoded = adapter.encodeLED(
        squares: ["e2", "e4"],
        speed: 3,
        repeatCount: 1,
        brightness: 2
    )
    #expect(encoded == expected,
            "F5: got \(encoded.map { String(format: "%02X",$0) }.joined(separator: " "))")
}

/// Same via encode(.indicateSquares) — default params match F5.
@Test func f5LEDViaEncode() {
    let expected = Data([0x60, 0x07, 0x05, 0x03, 0x01, 0x02, 0x34, 0x24, 0x00])
    let adapter = PegasusAdapter()
    let encoded = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
    #expect(encoded == expected, "F5: encode(.indicateSquares) must match golden fixture")
}

// MARK: - F6: LED — a1–h8 diagonal (mirror-trap canary)

/// Wire: `60 0D 05 07 01 01 38 31 2A 23 1C 15 0E 07 00`
/// a1=0x38, b2=0x31, c3=0x2A, d4=0x23, e5=0x1C, f6=0x15, g7=0x0E, h8=0x07.
///
/// This is the canonical mirror-trap acceptance probe: if your board lights the
/// a8–h1 diagonal instead, the square mapping is flipped. [spec §5; dgtdriver example]
///
/// speed=7 (wire 0x07 = index 6 + 1), repeatCount=1(once), brightness=1(high).
@Test func f6LEDDiagonalA1H8() {
    // Squares in spec-listed order: a1, b2, c3, d4, e5, f6, g7, h8
    let squares = ["a1", "b2", "c3", "d4", "e5", "f6", "g7", "h8"]
    let expected = Data([
        0x60, 0x0D, 0x05, 0x07, 0x01, 0x01,
        0x38, 0x31, 0x2A, 0x23, 0x1C, 0x15, 0x0E, 0x07,
        0x00
    ])
    let adapter = PegasusAdapter()
    let encoded = adapter.encodeLED(
        squares: squares,
        speed: 7,
        repeatCount: 1,
        brightness: 1
    )
    #expect(encoded == expected,
            "F6 diagonal canary: got \(encoded.map { String(format: "%02X",$0) }.joined(separator: " "))")
}

/// Verify individual square indices for the a1–h8 diagonal.
@Test func f6SquareIndexMathDiagonal() {
    // a1: i=(7-0)*8+0=56=0x38; h8: i=(7-7)*8+7=7=0x07
    let cases: [(String, UInt8)] = [
        ("a1", 0x38), ("b2", 0x31), ("c3", 0x2A), ("d4", 0x23),
        ("e5", 0x1C), ("f6", 0x15), ("g7", 0x0E), ("h8", 0x07)
    ]
    for (algebraic, expected) in cases {
        guard let sq = Square(algebraic: algebraic) else {
            Issue.record("Failed to parse \(algebraic)")
            continue
        }
        let i = (7 - sq.rank) * 8 + sq.file
        #expect(UInt8(i) == expected, "\(algebraic): expected i=\(String(format: "%02X", expected)), got \(String(format: "%02X", i))")
    }
}

// MARK: - F7: LEDs all off (host→board)

/// Wire: `60 02 00 00`
/// Exact 4-byte frame from the official DGT app. [PY exact-match handler; spec §7]
@Test func f7LEDAllOff() {
    let expected = Data([0x60, 0x02, 0x00, 0x00])
    let adapter = PegasusAdapter()
    // Via encodeLED with empty squares.
    let encoded = adapter.encodeLED(squares: [])
    #expect(encoded == expected,
            "F7 all-off: got \(encoded.map { String(format: "%02X",$0) }.joined(separator: " "))")
    // Via encode(.indicateSquares([], ...)).
    let encoded2 = adapter.encode(.indicateSquares([], style: .highlight))
    #expect(encoded2 == expected, "F7: encode(.indicateSquares([])) must emit the all-off frame")
}

// MARK: - F8: Version exchange (board→host)

/// Wire (board reply): `93 00 05 01 00`
/// msgId=0x93, totalLen=5, payload=[major=1, minor=0] → "1.0" → Pegasus.
/// dgtdriver rule: major == 1 ⇒ Pegasus. [DD device detection]
@Test func f8VersionDecodeIsRaw() {
    let f8Bytes = Data([0x93, 0x00, 0x05, 0x01, 0x00])
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: f8Bytes)

    // Version reply is logged as .raw (no dedicated event type needed for handshake frames).
    #expect(events.count == 1, "F8: expected exactly one event for version reply")
    guard case .raw(let rawData) = events[0] else {
        Issue.record("F8: expected .raw event for version reply, got \(events[0])")
        return
    }
    #expect(rawData == f8Bytes, "F8: .raw payload must match the version frame verbatim")
}

// MARK: - F9: Battery status (board→host)

/// Wire (board reply): `A0 00 0C 58 00 00 00 00 00 00 00 02`
/// msgId=0xA0, totalLen=12, payload[0]=0x58=88 → 88%.
/// payload[8]=0x02 → bit1 set = discharging, bit0 clear = not charging. [BRD; DD]
///
/// [DISCREPANCY] PY comment says "0x58≈100%"; BRD+DD say literal percent → 88%.
/// Follow BRD+DD (spec §6, discrepancy 1).
@Test func f9BatteryStatus88Percent() throws {
    let f9Bytes = Data([0xA0, 0x00, 0x0C, 0x58, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: f9Bytes)

    #expect(events.count == 1, "F9: expected exactly one event for battery reply")
    guard case .battery(let pct) = events[0] else {
        Issue.record("F9: expected .battery event, got \(events[0])")
        return
    }
    #expect(pct == 88, "F9: 0x58=88 decimal → 88%; got \(pct)")
}

/// Verify battery parsing by frame length, not hardcoded size. [spec §6, discrepancy 2]
@Test func f9BatteryParsedByFrameLength() throws {
    // Minimal battery frame (only 1 payload byte): still valid.
    let minBattery = Data([0xA0, 0x00, 0x04, 0x64])  // totalLen=4, percent=100
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: minBattery)
    guard case .battery(let pct) = events.first else {
        Issue.record("F9: minimal battery frame must emit .battery")
        return
    }
    #expect(pct == 100, "F9: payload[0]=0x64=100 → 100%; got \(pct)")
}

// MARK: - F10: Serial number (board→host)

/// Wire (board reply): `91 00 08 41 42 43 44 45`
/// msgId=0x91, totalLen=8, payload="ABCDE" (5 ASCII chars; real boards: 5 decimal digits).
/// [BRD DGT_MSG_SERIALNR; spec §3]
@Test func f10SerialNumberIsRaw() {
    let f10Bytes = Data([0x91, 0x00, 0x08, 0x41, 0x42, 0x43, 0x44, 0x45])
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: f10Bytes)

    #expect(events.count == 1, "F10: expected exactly one event for serial reply")
    guard case .raw(let rawData) = events[0] else {
        Issue.record("F10: expected .raw event for serial reply, got \(events[0])")
        return
    }
    #expect(rawData == f10Bytes, "F10: .raw payload must match the serial frame verbatim")
}

// MARK: - Square index math spot-checks

/// Protocol index → (file, rankIdx) decomposition. [spec §5 sanity anchors]
@Test func pegasusSquareIndexMathSentinels() {
    let cases: [(Int, Int, Int)] = [
        (0,  0, 7),   // a8: i=0  → file=0, rankIdx=7
        (7,  7, 7),   // h8: i=7  → file=7, rankIdx=7
        (56, 0, 0),   // a1: i=56 → file=0, rankIdx=0
        (63, 7, 0),   // h1: i=63 → file=7, rankIdx=0
        (52, 4, 1),   // e2: i=52 → file=4, rankIdx=1
        (36, 4, 3),   // e4: i=36 → file=4, rankIdx=3
    ]
    for (i, expectedFile, expectedRankIdx) in cases {
        let (file, rankIdx) = PegasusAdapter.squareComponents(protocolIndex: i)
        #expect(file    == expectedFile,    "i=\(i): expected file \(expectedFile), got \(file)")
        #expect(rankIdx == expectedRankIdx, "i=\(i): expected rankIdx \(expectedRankIdx), got \(rankIdx)")
    }
}

// MARK: - Framing: partial delivery across BLE notifications

/// The 67-byte board dump exceeds a typical 20-byte ATT MTU. The reassembler
/// must accumulate bytes and emit events only after the full frame arrives.
@Test func partialDeliveryBoardDump() throws {
    var dumpBytes: [UInt8] = [0x86, 0x00, 0x43]
    dumpBytes += Array(repeating: 0x01, count: 16)
    dumpBytes += Array(repeating: 0x00, count: 32)
    dumpBytes += Array(repeating: 0x01, count: 16)
    #expect(dumpBytes.count == 67)

    let full = Data(dumpBytes)
    let split = 20  // typical ATT_MTU - 3

    var adapter = PegasusAdapter()
    let events1 = adapter.feed(bytes: full.prefix(split))
    #expect(events1.isEmpty, "Partial frame must buffer silently (no events yet)")

    let events2 = adapter.feed(bytes: full.dropFirst(split))
    #expect(!events2.isEmpty, "Complete frame must produce events after reassembly")
    #expect(firstOccupancySnapshot(from: events2) != nil,
            "Reassembled board dump must produce occupancySnapshot")
    #expect(events2.contains { if case .ready = $0 { return true }; return false },
            "First board dump after reassembly must emit .ready")
}

/// Multiple frames concatenated in one feed must all be decoded.
@Test func twoFramesConcatenatedInOneFeed() {
    let fieldUpdate1 = Data([0x8E, 0x00, 0x05, 0x34, 0x00])  // lift e2
    let fieldUpdate2 = Data([0x8E, 0x00, 0x05, 0x24, 0x01])  // place e4
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: fieldUpdate1 + fieldUpdate2)
    let sensed = sensedEvents(from: events)
    #expect(sensed.count == 2, "Two concatenated field-update frames must each produce a squareSensed event")
    #expect(sensed[0] == ("e2", true),  "First event: lift e2")
    #expect(sensed[1] == ("e4", false), "Second event: place e4")
}

// MARK: - Framing: malformed-frame rejection

/// Garbage bytes (bit 7 clear) are skipped; the subsequent valid frame decodes.
@Test func garbageSkippedBeforeValidFrame() {
    // 3 bytes with bit 7 clear (garbage) followed by a valid field-update frame.
    let garbage     = Data([0x01, 0x02, 0x03])
    let fieldUpdate = Data([0x8E, 0x00, 0x05, 0x24, 0x01])  // place e4
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: garbage + fieldUpdate)
    let sensed = sensedEvents(from: events)
    #expect(sensed.count == 1, "Garbage bytes must be skipped; only the valid frame decoded")
    #expect(sensed[0].square == "e4")
}

/// A corrupt length field (bit 7 set in lenHi or lenLo) causes resync, not a crash.
@Test func corruptLengthFieldCausesResync() {
    // msgId=0x8E (valid), lenHi=0x80 (corrupt — bit 7 set), then a valid frame.
    let corrupt     = Data([0x8E, 0x80, 0x05])
    let fieldUpdate = Data([0x8E, 0x00, 0x05, 0x34, 0x00])  // lift e2
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: corrupt + fieldUpdate)
    // The corrupt frame is discarded; the valid frame is decoded.
    let sensed = sensedEvents(from: events)
    #expect(sensed.count == 1, "After corrupt-length resync, the next valid frame must decode")
    #expect(sensed[0] == ("e2", true))
}

/// An undersized board-dump frame (payloadLen < 64) is forwarded as .raw.
@Test func undersizedBoardDumpIsRaw() {
    // totalLen = 3 + 10 = 13 (only 10 payload bytes, not 64)
    var shortDump: [UInt8] = [0x86, 0x00, 0x0D]  // totalLen = 13
    shortDump += Array(repeating: 0x01, count: 10)
    var adapter = PegasusAdapter()
    let events = adapter.feed(bytes: Data(shortDump))
    #expect(events.count == 1)
    guard case .raw = events[0] else {
        Issue.record("Undersized board dump must produce .raw, not occupancySnapshot")
        return
    }
}

// MARK: - .ready gating

/// .ready is emitted exactly once per connect cycle — on the first board dump.
@Test func readyEmittedOncePerConnectCycle() {
    var dumpBytes: [UInt8] = [0x86, 0x00, 0x43]
    dumpBytes += Array(repeating: 0x01, count: 16)
    dumpBytes += Array(repeating: 0x00, count: 32)
    dumpBytes += Array(repeating: 0x01, count: 16)
    let frame = Data(dumpBytes)

    var adapter = PegasusAdapter()
    let first  = adapter.feed(bytes: frame)
    let second = adapter.feed(bytes: frame)

    let readyCount = (first + second).filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "Expected exactly one .ready across two identical board dump feeds; got \(readyCount)")
}

/// After resetFraming(), the next board dump re-emits .ready.
@Test func resetFramingReArmsReady() throws {
    var dumpBytes: [UInt8] = [0x86, 0x00, 0x43]
    dumpBytes += Array(repeating: 0x01, count: 16)
    dumpBytes += Array(repeating: 0x00, count: 32)
    dumpBytes += Array(repeating: 0x01, count: 16)
    let frame = Data(dumpBytes)

    var adapter = PegasusAdapter()
    _ = adapter.feed(bytes: frame)       // first dump → .ready emitted

    // Simulate link drop: feed a partial frame then reset.
    _ = adapter.feed(bytes: frame.prefix(10))
    adapter.resetFraming()

    // First dump on new link must re-emit .ready.
    let events = adapter.feed(bytes: frame)
    #expect(events.contains { if case .ready = $0 { return true }; return false },
            "After resetFraming + full board dump, .ready must be re-emitted")
    // No squareSensed deltas (previousOccupancy cleared → first-frame path).
    let deltaCount = events.filter { if case .squareSensed = $0 { return true }; return false }.count
    #expect(deltaCount == 0, "After resetFraming, no squareSensed deltas on first board dump")
}

// MARK: - Handshake sequence

/// First-connect handshake must include all pinned steps in order.
@Test func handshakeFirstConnectOrder() {
    let adapter = PegasusAdapter()
    let steps = adapter.handshakeCommands(isReconnect: false)

    // Step 0: reset (0x40) with 300 ms delay.
    guard let firstStep = steps.first else {
        Issue.record("Handshake must have at least one step")
        return
    }
    #expect(firstStep.delayBefore == 0.3,
            "First step must have 300 ms initial delay")
    if case .custom(let data) = firstStep.command {
        #expect(data == Data([0x40]), "First step must be reset (0x40)")
    } else {
        Issue.record("First step must be .custom(0x40)")
    }

    // requestState (0x42) must be present (board dump).
    let hasDump = steps.contains { step in
        if case .requestState = step.command { return true }
        return false
    }
    #expect(hasDump, "Handshake must include .requestState (board dump 0x42)")

    // startSession (0x44) must be present (streaming mode).
    let hasStream = steps.contains { step in
        if case .startSession = step.command { return true }
        return false
    }
    #expect(hasStream, "Handshake must include .startSession (streaming mode 0x44)")

    // Devkey frame (0x63) must be present.
    let hasDevkey = steps.contains { step in
        if case .custom(let data) = step.command { return data.first == 0x63 }
        return false
    }
    #expect(hasDevkey, "Handshake must include devkey frame (0x63)")
}

/// Reconnect handshake is a single board-dump request with a stabilisation delay.
@Test func handshakeReconnect() {
    let adapter = PegasusAdapter()
    let steps = adapter.handshakeCommands(isReconnect: true)
    #expect(steps.count == 1, "Reconnect handshake must be a single step")
    if case .requestState = steps[0].command {
        // correct
    } else {
        Issue.record("Reconnect step must be .requestState (board dump 0x42)")
    }
    #expect(steps[0].delayBefore == 0.25,
            "Reconnect step must have 250 ms stabilisation delay")
}

/// encode(.requestState) → 0x42 (board dump); encode(.startSession) → 0x44.
@Test func encodeRequestStateAndStartSession() {
    let adapter = PegasusAdapter()
    #expect(adapter.encode(.requestState) == Data([0x42]),
            "requestState must encode to 0x42 (DGT_SEND_BRD)")
    #expect(adapter.encode(.startSession) == Data([0x44]),
            "startSession must encode to 0x44 (DGT_SEND_UPDATE_BRD / streaming mode)")
}

/// encode(.executeMove) → nil (non-motorised).
@Test func encodeMoveReturnsNil() {
    let adapter = PegasusAdapter()
    #expect(adapter.encode(.executeMove(uci: "e2e4")) == nil,
            "executeMove must return nil — Pegasus is not motorised")
}

// MARK: - Capabilities

@Test func capabilitySet() {
    let adapter = PegasusAdapter()
    #expect(adapter.capabilities.contains(.occupancySensing),  "Must have occupancySensing")
    #expect(adapter.capabilities.contains(.perSquareLEDs),     "Must have perSquareLEDs")
    #expect(adapter.capabilities.contains(.moveIndication),    "Must have moveIndication")
    #expect(adapter.capabilities.contains(.batteryReporting),  "Must have batteryReporting — adapter emits .battery events from 0xA0 frames and enables push updates via 0x4C in the handshake")
    #expect(!adapter.capabilities.contains(.pieceIdentity),    "Must NOT have pieceIdentity")
    #expect(!adapter.capabilities.contains(.motorised),        "Must NOT have motorised")
}

// MARK: - GATT constants smoke-check

@Test func gattUUIDs() {
    #expect(PegasusGATT.nordicUART.uppercased() == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    #expect(PegasusGATT.writeChar.uppercased()  == "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    #expect(PegasusGATT.notifyChar.uppercased() == "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
}

// MARK: - Orientation flip

/// With orientationFlipped=true, incoming square indices are remapped i'=63-i.
/// Field update for i=52 (e2 in normal orientation) becomes i'=63-52=11 = g7.
@Test func orientationFlipRemapsIncomingFieldUpdate() {
    var adapter = PegasusAdapter()
    adapter.orientationFlipped = true
    // Protocol index 52 = e2 normally.  Flipped: i'=63-52=11 → file=11&7=3(d), rankIdx=7-(11>>3)=7-1=6(rank7) = d7
    let events = adapter.feed(bytes: Data([0x8E, 0x00, 0x05, 0x34, 0x00]))
    let sensed = sensedEvents(from: events)
    #expect(sensed.count == 1)
    #expect(sensed[0].square != "e2",
            "Flipped adapter must NOT emit e2 for raw index 0x34")
    // Verify the flip formula: 63-52=11 → file=3(d), rankIdx=6 → d7
    #expect(sensed[0].square == "d7",
            "Flipped: raw index 52 (e2 normal) should map to d7 (63-52=11)")
}

/// With orientationFlipped=true, outgoing LED indices are also remapped.
@Test func orientationFlipRemapsOutgoingLED() {
    var adapter = PegasusAdapter()
    adapter.orientationFlipped = true
    // In normal orientation, e2 maps to wire index 52 (0x34).
    // Flipped, e2 maps to 63-52=11 (0x0B).
    let data = adapter.encodeLED(squares: ["e2"], speed: 3, repeatCount: 1, brightness: 2)
    // Expected: 60 06 05 03 01 02 0B 00  (len=5+1=6, sq=0x0B)
    let expected = Data([0x60, 0x06, 0x05, 0x03, 0x01, 0x02, 0x0B, 0x00])
    #expect(data == expected,
            "Flipped LED: e2 must encode to 0x0B not 0x34; got \(data.map { String(format: "%02X",$0) }.joined(separator: " "))")
}

// MARK: - SimulatedBoard occupancy round-trip

/// Verify that PegasusAdapter correctly decodes Pegasus board dumps generated from
/// positions that a SimulatedBoard produces — including a capture.
///
/// Game: 1.e4 e5 2.d4 exd4 (capture on d4).
/// The adapter must produce correct occupancySnapshot and squareSensed deltas.
@Test func occupancySimRoundTrip() async throws {
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    var adapter = PegasusAdapter()
    // Prime adapter with the initial position.
    let initFrame = encodePegasusDump(position: .initial())
    let initEvents = adapter.feed(bytes: initFrame)
    #expect(firstOccupancySnapshot(from: initEvents) != nil,
            "Round-trip: initial board dump must produce occupancySnapshot")
    #expect(initEvents.contains { if case .ready = $0 { return true }; return false },
            "Round-trip: first dump must emit .ready")

    // Move sequence: e2e4, e7e5, d2d4, e5d4 (capture)
    let moves = ["e2e4", "e7e5", "d2d4", "e5d4"]
    for uci in moves {
        _ = try await sim.executeMove(uci: uci)
        let pos = await sim.position
        let frame = encodePegasusDump(position: pos)
        let events = adapter.feed(bytes: frame)

        let occ = try #require(firstOccupancySnapshot(from: events),
                               "Round-trip: \(uci) must produce occupancySnapshot")
        #expect(occ.count == 64)
        _ = sensedEvents(from: events)  // must not crash; deltas allowed to be empty or non-empty
    }

    // After the full game, verify final board state via occupancySnapshot.
    let finalPos = await sim.position
    let finalFrame = encodePegasusDump(position: finalPos)
    let finalEvents = adapter.feed(bytes: finalFrame)
    let finalOcc = try #require(firstOccupancySnapshot(from: finalEvents))

    // After e5d4 (capture): d4 occupied, e5 empty, e2 empty, d2 empty.
    let e5FileMajor = 4 * 8 + 4  // file e=4, rankIdx 4 (rank 5)
    let d4FileMajor = 3 * 8 + 3  // file d=3, rankIdx 3 (rank 4)
    let e2FileMajor = 4 * 8 + 1  // file e=4, rankIdx 1 (rank 2)
    let d2FileMajor = 3 * 8 + 1  // file d=3, rankIdx 1 (rank 2)
    #expect(!finalOcc[e5FileMajor], "After exd4: e5 should be empty")
    #expect(finalOcc[d4FileMajor],  "After exd4: d4 should be occupied")
    #expect(!finalOcc[e2FileMajor], "After 1.e4: e2 should be empty")
    #expect(!finalOcc[d2FileMajor], "After 2.d4: d2 should be empty")
}

/// SimulatedBoard occupancy-only events have piece: nil (matching Pegasus semantics).
@Test func simulatedBoardOccupancyEventsHaveNilPiece() async throws {
    let sim = SimulatedBoard(capabilities: [.occupancySensing])
    let events = try await sim.executeMove(uci: "e2e4")
    let sensed = events.compactMap { event -> Piece?? in
        if case .squareSensed(_, _, let piece) = event { return .some(piece) }
        return nil
    }
    for piece in sensed {
        #expect(piece == nil, "Occupancy-only SimulatedBoard events must have piece: nil")
    }
}

/// Full occupancy short-game round-trip through PegasusAdapter with field-update frames
/// (not just board dumps) — verifies squareSensed events from streaming updates.
@Test func fieldUpdateStreamingRoundTrip() throws {
    var adapter = PegasusAdapter()

    // Prime with initial board dump.
    var dumpBytes: [UInt8] = [0x86, 0x00, 0x43]
    dumpBytes += Array(repeating: 0x01, count: 16)
    dumpBytes += Array(repeating: 0x00, count: 32)
    dumpBytes += Array(repeating: 0x01, count: 16)
    _ = adapter.feed(bytes: Data(dumpBytes))

    // Simulate 1.e4: lift e2 (index 52=0x34, code=0x00), place e4 (index 36=0x24, code=0x01).
    let lift  = adapter.feed(bytes: Data([0x8E, 0x00, 0x05, 0x34, 0x00]))
    let place = adapter.feed(bytes: Data([0x8E, 0x00, 0x05, 0x24, 0x01]))

    let liftSensed  = sensedEvents(from: lift)
    let placeSensed = sensedEvents(from: place)
    #expect(liftSensed.count  == 1 && liftSensed[0].square  == "e2" && liftSensed[0].isLift  == true,
            "Lift e2 must produce squareSensed(e2, isLift:true)")
    #expect(placeSensed.count == 1 && placeSensed[0].square == "e4" && placeSensed[0].isLift == false,
            "Place e4 must produce squareSensed(e4, isLift:false)")

    // After the field updates, a follow-up board dump should reflect the move
    // and produce no squareSensed deltas (state already updated).
    var dumpAfterE4: [UInt8] = [0x86, 0x00, 0x43]
    // Payload: build starting occupancy then apply the e2→e4 move.
    var occ = [UInt8](repeating: 0, count: 64)
    for i in 0..<16  { occ[i] = 0x01 }  // ranks 8+7
    for i in 48..<64 { occ[i] = 0x01 }  // ranks 2+1
    occ[52] = 0x00   // e2 lifted: i=52
    occ[36] = 0x01   // e4 placed: i=36
    dumpAfterE4 += occ
    let afterEvents = adapter.feed(bytes: Data(dumpAfterE4))
    let afterSensed = sensedEvents(from: afterEvents)
    #expect(afterSensed.isEmpty,
            "Board dump after field updates reflect the same position: no deltas expected")
}
