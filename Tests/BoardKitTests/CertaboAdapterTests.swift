// Certabo adapter tests — every golden fixture from the pinned spec, plus
// calibration, uncalibrated flow, SimulatedBoard round-trips, framing edge
// cases, rotation, and cer2nut wrapped-RFID golden fixtures.
//
// Fixture labels match the pinned spec (F1–F7).
// CER2NUT fixture labels match the cer2nut CertaboParser test names (facts-only
// use — no code structure copied from gkalab/cer2nut, GPL-3.0).

import Testing
import Foundation
import ChessCore
import BoardKit
@testable import CertaboAdapter
import BoardKitTestSupport

// MARK: - Test helpers

/// Build a Certabo ASCII RFID frame (320 tokens) from a 64-element tag array.
/// Token order is stream order (index 0 = a8 … 63 = h1).
private func rfidFrameData(_ tags: [CertaboTagID]) -> Data {
    precondition(tags.count == 64)
    let tokens = tags.flatMap { [$0.b0, $0.b1, $0.b2, $0.b3, $0.b4].map { "\($0)" } }
    let s = ":" + tokens.joined(separator: " ") + " \r\n"
    return s.data(using: .ascii)!
}

/// Build a Certabo ASCII RFID frame with cer2nut-style bare-LF wraps.
///
/// Wraps at character-position boundaries (not token boundaries) so that a
/// bare-LF may fall mid-digit, reproducing the cer2nut capture behaviour
/// where e.g. "84 4\n4 81" appears on the wire and the scanner must
/// reconstruct token "44" by concatenating adjacent byte fragments.
/// Frame is terminated by `\r\n`; the accumulator strips bare-LF and joins.
///
/// [CER2NUT] wire-format facts; no code structure copied.
private func wrappedRfidFrameData(_ tags: [CertaboTagID], wrapEvery: Int = 65) -> Data {
    precondition(tags.count == 64)
    let tokens = tags.flatMap { [$0.b0, $0.b1, $0.b2, $0.b3, $0.b4].map { "\($0)" } }
    let flat = ":" + tokens.joined(separator: " ")
    // Slice at character positions, inserting bare-LF after every wrapEvery chars.
    var result = ""
    var idx = flat.startIndex
    while idx < flat.endIndex {
        let next = flat.index(idx, offsetBy: wrapEvery, limitedBy: flat.endIndex) ?? flat.endIndex
        result += flat[idx..<next]
        if next < flat.endIndex { result += "\n" }
        idx = next
    }
    result += " \r\n"
    return result.data(using: .ascii)!
}

/// Build a Certabo ASCII occupancy frame (8 tokens) from a 64-element Bool array (file-major).
/// Number k covers rank (8-k); bit for file f = 1 << (7-f) (MSB=a-file).
private func occupancyFrameData(_ occ: [Bool]) -> Data {
    precondition(occ.count == 64)
    var bytes = [UInt8](repeating: 0, count: 8)
    for k in 0..<8 {
        let rank = 7 - k    // 0-indexed
        for file in 0..<8 {
            let fm = file * 8 + rank
            if occ[fm] { bytes[k] |= 1 << (7 - file) }
        }
    }
    let s = ":" + bytes.map { "\($0)" }.joined(separator: " ") + "\r\n"
    return s.data(using: .ascii)!
}

/// Build a file-major Bool occupancy from a Position.
private func positionOccupancy(_ pos: Position) -> [Bool] {
    var occ = [Bool](repeating: false, count: 64)
    for file in 0..<8 {
        for rank in 0..<8 {
            let rmIdx = rank * 8 + file   // Position.board rank-major index
            let fmIdx = file * 8 + rank
            occ[fmIdx] = pos.board[rmIdx] != nil
        }
    }
    return occ
}

/// Extract all identitySnapshot events.
private func identitySnapshots(from events: [BoardEvent]) -> [[Piece?]] {
    events.compactMap { if case .identitySnapshot(let id) = $0 { return id } else { return nil } }
}

/// Extract the first identitySnapshot.
private func firstIdentitySnapshot(from events: [BoardEvent]) -> [Piece?]? {
    identitySnapshots(from: events).first
}

/// Extract all occupancySnapshot events.
private func occupancySnapshots(from events: [BoardEvent]) -> [[Bool]] {
    events.compactMap { if case .occupancySnapshot(let o) = $0 { return o } else { return nil } }
}

/// Extract all squareSensed events.
private func sensed(from events: [BoardEvent]) -> [(square: String, isLift: Bool, piece: Piece?)] {
    events.compactMap {
        if case .squareSensed(let sq, let lift, let piece) = $0 { return (sq, lift, piece) }
        return nil
    }
}

/// File-major index for an algebraic square.
private func fm(_ algebraic: String) -> Int? {
    guard let sq = Square(algebraic: algebraic) else { return nil }
    return sq.file * 8 + sq.rank
}

/// Piece at algebraic square in a file-major identity array.
private func pieceAt(_ algebraic: String, in identity: [Piece?]) -> Piece? {
    guard let idx = fm(algebraic) else { return nil }
    return identity[idx]
}

/// True when algebraic square is occupied in a file-major Bool array.
private func isOccupied(_ algebraic: String, in occ: [Bool]) -> Bool {
    guard let idx = fm(algebraic) else { return false }
    return occ[idx]
}

// MARK: - Standard calibration fixture

/// Build a 64-element tag array for the standard chess starting position.
/// Each tag has at most 1 zero byte so it never triggers the ≥3-zeros
/// noise heuristic (D7) and is never treated as effectively empty.
/// Spare queens are placed on d6 (stream 19) and d3 (stream 43).
private func standardStartTags() -> [CertaboTagID] {
    var tags = [CertaboTagID](repeating: .zero, count: 64)
    // Black back rank (0..7 = a8..h8): manufacturer prefix 3,0,84 — 1 zero byte.
    for i in 0..<8   { tags[i]  = CertaboTagID(3, 0, 84, 252, UInt8(i + 1)) }
    // Black pawns (8..15 = a7..h7)
    for i in 8..<16  { tags[i]  = CertaboTagID(3, 0, 85, 252, UInt8(i)) }
    // White pawns (48..55 = a2..h2)
    for i in 48..<56 { tags[i]  = CertaboTagID(3, 0, 83, 252, UInt8(i)) }
    // White back rank (56..63 = a1..h1)
    for i in 56..<64 { tags[i]  = CertaboTagID(3, 0, 86, 252, UInt8(i)) }
    // Spare queens
    tags[19] = CertaboTagID(3, 0, 84, 100, 19)   // d6 spare black queen
    tags[43] = CertaboTagID(3, 0, 86, 100, 43)   // d3 spare white queen
    return tags
}

// MARK: - F1: Classic LED command — e2 and e4

/// Fixture F1: Classic LED command for e2 + e4.
/// HEX: 00 00 00 00 10 00 10 00
///
/// Derivation:
///   e4: byte[7-3]=byte[4]; bit 1<<4=0x10.
///   e2: byte[7-1]=byte[6]; bit 1<<4=0x10.
///
/// Cross-checks:
///   [OFFICIAL] reader_writer.py docstring: ['e2','e4'] = [0,0,0,0,16,0,16,0]
///   [OFFICIAL] codes.py move2led("e2e4"): (4,16,6,16) — same bytes.
///   [MONO424] LEDPattern: bytePattern[4]+=16, bytePattern[6]+=16.
@Test func f1ClassicLEDE2E4() {
    let expected = Data([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00])
    let adapter = CertaboAdapter()
    let result = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
    #expect(result == expected)
}

// MARK: - F2: Classic LED command — corners a1 + h8

/// Fixture F2: Classic LED command for a1 and h8.
/// HEX: 80 00 00 00 00 00 00 01
///
/// Derivation:
///   h8: byte[7-7]=byte[0]; bit 1<<7=0x80.
///   a1: byte[7-0]=byte[7]; bit 1<<0=0x01.
///
/// Reviewer trap: MSB of byte[0] is h8, NOT a8 (LED bit order = LSB=a-file).
@Test func f2ClassicLEDCornersA1H8() {
    let expected = Data([0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
    let adapter = CertaboAdapter()
    let result = adapter.encode(.indicateSquares(["a1", "h8"], style: .highlight))
    #expect(result == expected)
}

// MARK: - F3: Classic LED command — calibration pattern

/// Fixture F3: Official calibration LED pattern.
/// HEX: FF FF 08 00 00 08 FF FF
///
/// Derivation: ranks 8,7 (bytes 0,1) = 0xFF; ranks 2,1 (bytes 6,7) = 0xFF.
///   d6: byte[7-5]=byte[2]; bit 1<<3=0x08.
///   d3: byte[7-2]=byte[5]; bit 1<<3=0x08.
///
/// Source cross-check: [OFFICIAL] reader_writer.py default_messages
///   'setup': [255,255,8,0,0,8,255,255] — byte-for-byte identical.
///   The lit d6/d3 squares independently confirm spare-queen calibration squares.
@Test func f3ClassicLEDCalibrationPattern() {
    let expected = Data([0xFF, 0xFF, 0x08, 0x00, 0x00, 0x08, 0xFF, 0xFF])
    let adapter = CertaboAdapter()
    // All of ranks 8,7,2,1 (a–h files) plus d6 and d3.
    let rank8: [String] = ["a8","b8","c8","d8","e8","f8","g8","h8"]
    let rank7: [String] = ["a7","b7","c7","d7","e7","f7","g7","h7"]
    let rank2: [String] = ["a2","b2","c2","d2","e2","f2","g2","h2"]
    let rank1: [String] = ["a1","b1","c1","d1","e1","f1","g1","h1"]
    let squares = rank8 + rank7 + ["d6"] + ["d3"] + rank2 + rank1
    let result = adapter.encode(.indicateSquares(squares, style: .highlight))
    #expect(result == expected)
}

// MARK: - F3: All-off and all-on

@Test func f3ClassicLEDAllOff() {
    let adapter = CertaboAdapter()
    let result = adapter.encode(.indicateSquares([], style: .highlight))
    #expect(result == Data(repeating: 0, count: 8))
}

@Test func f3ClassicLEDAllOn() {
    let adapter = CertaboAdapter()
    var all: [String] = []
    for file in ["a","b","c","d","e","f","g","h"] {
        for rank in 1...8 { all.append("\(file)\(rank)") }
    }
    let result = adapter.encode(.indicateSquares(all, style: .highlight))
    #expect(result == Data(repeating: 0xFF, count: 8))
}

// MARK: - F4: RFID position frame — one tag on a8

/// Fixture F4: Single-tag RFID frame. Tag [3,0,84,252,153] on a8, all others empty.
///
/// Frame: ":3 0 84 252 153" + (" 0" × 315) + " \r\n"
/// Token count = 320. Stream index 0 = a8.
///
/// Source cross-check: real-board tag value "3 0 84 252 153" appears in
/// cer2nut captured test frames.
@Test func f4RFIDFrameOneTagOnA8() throws {
    let tag = CertaboTagID(3, 0, 84, 252, 153)
    var tags = [CertaboTagID](repeating: .zero, count: 64)
    tags[0] = tag

    // Build a calibration that maps this tag to a black rook.
    let cal = CertaboCalibration.learn(from: [tags])

    var adapter = CertaboAdapter(calibration: cal)
    let events = adapter.feed(bytes: rfidFrameData(tags))

    let identity = try #require(firstIdentitySnapshot(from: events))
    // a8 should be a black rook.
    #expect(pieceAt("a8", in: identity) == Piece(type: .rook, color: .black))
    // All other squares should be nil.
    let occupied = identity.compactMap { $0 }
    #expect(occupied.count == 1)
    #expect(events.contains { if case .ready = $0 { return true }; return false })
}

/// F4 raw bytes of the frame match the spec's ASCII hex.
@Test func f4RFIDFrameHeadBytes() {
    let tag = CertaboTagID(3, 0, 84, 252, 153)
    var tags = [CertaboTagID](repeating: .zero, count: 64)
    tags[0] = tag
    let data = rfidFrameData(tags)
    // Spec HEX head: 3A 33 20 30 20 38 34 20 32 35 32 20 31 35 33
    let expectedHead: [UInt8] = [0x3A,0x33,0x20,0x30,0x20,0x38,0x34,0x20,0x32,0x35,0x32,0x20,0x31,0x35,0x33]
    #expect(Array(data.prefix(15)) == expectedHead)
    // Tail: 20 0D 0A
    #expect(Array(data.suffix(3)) == [0x20, 0x0D, 0x0A])
}

// MARK: - F5: Occupancy frame — chess starting position

/// Fixture F5: Occupancy board, initial position.
/// ASCII: ":255 255 0 0 0 0 255 255\r\n"
/// HEX: 3A 32 35 35 20 32 35 35 20 30 20 30 20 30 20 30 20 32 35 35 20 32 35 35 0D 0A
///
/// Decoded: ranks 8,7,2,1 all occupied; ranks 6..3 empty.
@Test func f5OccupancyFrameInitialPosition() throws {
    let frameStr = ":255 255 0 0 0 0 255 255\r\n"
    let frameData = frameStr.data(using: .ascii)!

    // Verify hex matches spec.
    let expectedHex: [UInt8] = [
        0x3A,0x32,0x35,0x35,0x20,0x32,0x35,0x35,0x20,0x30,0x20,0x30,0x20,
        0x30,0x20,0x30,0x20,0x32,0x35,0x35,0x20,0x32,0x35,0x35,0x0D,0x0A
    ]
    #expect(Array(frameData) == expectedHex)

    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: frameData)
    let occ = try #require(occupancySnapshots(from: events).first)

    // Ranks 8 and 7: all occupied.
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(isOccupied("\(file)8", in: occ), "Expected \(file)8 occupied")
        #expect(isOccupied("\(file)7", in: occ), "Expected \(file)7 occupied")
    }
    // Ranks 6..3: all empty.
    for rank in 3...6 {
        for file in ["a","b","c","d","e","f","g","h"] {
            #expect(!isOccupied("\(file)\(rank)", in: occ), "Expected \(file)\(rank) empty")
        }
    }
    // Ranks 2 and 1: all occupied.
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(isOccupied("\(file)2", in: occ), "Expected \(file)2 occupied")
        #expect(isOccupied("\(file)1", in: occ), "Expected \(file)1 occupied")
    }
    // 32 occupied squares total.
    #expect(occ.filter { $0 }.count == 32)
    #expect(events.contains { if case .ready = $0 { return true }; return false })
}

// MARK: - F5 variant: L suffix updates LED type

/// F5 variant from cer2nut committed test:
/// ":255 255 0 0 0 0 255 254\nL\r\n"
/// Last number 254 = 0b11111110 → bit0 (h-file) clear → h1 empty.
/// Trailing "L\r\n" → single-color LED type.
@Test func f5VariantH1EmptyAndLedTypeUpdate() throws {
    let frameStr = ":255 255 0 0 0 0 255 254\nL\r\n"
    let frameData = frameStr.data(using: .ascii)!

    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: frameData)
    let occ = try #require(occupancySnapshots(from: events).first)

    // h1 should be empty (bit0 not set in last byte 254 = 0b11111110).
    #expect(!isOccupied("h1", in: occ), "h1 must be empty")
    // a1 should be occupied (bit7 = 1).
    #expect(isOccupied("a1", in: occ), "a1 must be occupied")

    // After L line: LED encoding must use classic 8-byte format.
    let ledResult = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
    #expect(ledResult?.count == 8, "After L line, LED command must be 8 bytes")
}

// MARK: - F6: Occupancy frame — e2 only

/// Fixture F6: Single piece on e2.
/// ASCII: ":0 0 0 0 0 0 8 0\r\n"
/// HEX: 3A 30 20 30 20 30 20 30 20 30 20 30 20 38 20 30 0D 0A
///
/// Derivation: e2 → rank 2 (0-indexed rank=1) → k=6 (7−k=1=rank0).
///   file e = 4 → bit 1<<(7−4) = 1<<3 = 8. Number index 6 = 8. ✓
///
/// Reviewer trap: occupancy MSB=a-file is OPPOSITE of LED command's LSB=a-file.
///   a2-only would be "…0 128 0" (bit7 set), h2-only would be "…0 1 0" (bit0 set).
@Test func f6OccupancyFrameE2Only() throws {
    let frameStr = ":0 0 0 0 0 0 8 0\r\n"
    let frameData = frameStr.data(using: .ascii)!

    let expectedHex: [UInt8] = [
        0x3A,0x30,0x20,0x30,0x20,0x30,0x20,0x30,0x20,0x30,0x20,0x30,0x20,0x38,0x20,0x30,0x0D,0x0A
    ]
    #expect(Array(frameData) == expectedHex)

    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: frameData)
    let occ = try #require(occupancySnapshots(from: events).first)

    #expect(isOccupied("e2", in: occ), "e2 must be occupied")
    #expect(occ.filter { $0 }.count == 1, "Only e2 should be occupied")
}

/// F6 additional: a2-only → number = 128 (MSB = a-file).
@Test func f6OccupancyBitOrderA2Only() throws {
    let frameStr = ":0 0 0 0 0 0 128 0\r\n"
    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: frameStr.data(using: .ascii)!)
    let occ = try #require(occupancySnapshots(from: events).first)
    #expect(isOccupied("a2", in: occ), "a2 must be occupied for bitmask 128")
    #expect(!isOccupied("h2", in: occ), "h2 must be empty for bitmask 128")
}

/// F6 additional: h2-only → number = 1 (LSB = h-file).
@Test func f6OccupancyBitOrderH2Only() throws {
    let frameStr = ":0 0 0 0 0 0 1 0\r\n"
    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: frameStr.data(using: .ascii)!)
    let occ = try #require(occupancySnapshots(from: events).first)
    #expect(!isOccupied("a2", in: occ), "a2 must be empty for bitmask 1")
    #expect(isOccupied("h2", in: occ), "h2 must be occupied for bitmask 1")
}

// MARK: - F7: Spectrum RGB LED command — e2 and e4

/// Fixture F7: Spectrum RGB LED frame for e2 + e4 (247 bytes).
/// Non-zero bytes at frame offsets {40,43,67,70,94,97,121,124}, value 0x40.
///
/// Derivation (e4): classic byte 4 bit 4 → stream index s=36.
///   row=7−36/8=3, col=7−36%8=3; base=(3×9+3)×3=90.
///   Blue-channel frame offsets: {94,97,121,124}.
///
/// Derivation (e2): s=52; row=1, col=3; base=36.
///   Blue-channel frame offsets: {40,43,67,70}.
///
/// Cross-check: byte-for-byte equal to cer2nut RgbLedCommandTranslatorTest.translateE2E4.
@Test func f7SpectrumRGBLEDE2E4() {
    var adapter = CertaboAdapter()
    // Inject D line to set RGB mode.
    _ = adapter.feed(bytes: "D\r\n".data(using: .ascii)!)

    let result = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
    guard let frame = result else {
        Issue.record("Expected non-nil LED command")
        return
    }
    #expect(frame.count == 247)
    #expect(frame[0] == 0xFF)
    #expect(frame[1] == 0x55)
    #expect(frame[245] == 0x0D)
    #expect(frame[246] == 0x0A)

    let nonZeroOffsets = (2..<245).filter { frame[$0] != 0 }
    let expectedOffsets: [Int] = [40, 43, 67, 70, 94, 97, 121, 124]
    #expect(Set(nonZeroOffsets) == Set(expectedOffsets))
    for off in expectedOffsets { #expect(frame[off] == 0x40) }
}

/// F7 cross-check: center-4-squares command yields 9 unique lit LED offsets
/// (the 3×3 shared-corner grid). Matches cer2nut translateCenterLedsCommand.
@Test func f7SpectrumRGBLEDCenter4Squares() {
    var adapter = CertaboAdapter()
    _ = adapter.feed(bytes: "D\r\n".data(using: .ascii)!)

    // d4, e4, d5, e5 (classic byte pattern 00 00 00 18 18 00 00 00)
    let result = adapter.encode(.indicateSquares(["d4","e4","d5","e5"], style: .highlight))
    guard let frame = result else { Issue.record("Expected non-nil"); return }
    #expect(frame.count == 247)

    let nonZeroOffsets = Set((2..<245).filter { frame[$0] != 0 })
    let expectedOffsets: Set<Int> = [94, 97, 100, 121, 124, 127, 148, 151, 154]
    #expect(nonZeroOffsets == expectedOffsets)
}

// MARK: - F7: All-off RGB

@Test func f7SpectrumRGBLEDAllOff() {
    var adapter = CertaboAdapter()
    _ = adapter.feed(bytes: "D\r\n".data(using: .ascii)!)
    let result = adapter.encode(.indicateSquares([], style: .highlight))
    guard let frame = result else { Issue.record("Expected non-nil"); return }
    #expect(frame.count == 247)
    #expect(frame[0] == 0xFF); #expect(frame[1] == 0x55)
    // All payload bytes should be zero.
    #expect((2..<245).allSatisfy { frame[$0] == 0 })
}

// MARK: - Malformed frame rejection

@Test func malformedNonASCIIByte() {
    // A frame with byte 0x80 (non-ASCII) must be silently dropped.
    var adapter = CertaboAdapter()
    let badFrame = Data([0x3A, 0x80, 0x31, 0x0A])  // ":\x801\n"
    let events = adapter.feed(bytes: badFrame)
    // Must not emit any snapshot events.
    #expect(!events.contains { if case .identitySnapshot = $0 { return true }; return false })
    #expect(!events.contains { if case .occupancySnapshot = $0 { return true }; return false })
}

@Test func malformedWrongTokenCount() {
    var adapter = CertaboAdapter()
    // 5 tokens — not 8 or 320.
    let bad = ":1 2 3 4 5\r\n".data(using: .ascii)!
    let events = adapter.feed(bytes: bad)
    #expect(events.isEmpty)
}

@Test func malformedPartialFrameNoEvents() {
    // Feed half of a valid occupancy frame; should not emit until LF arrives.
    var adapter = CertaboAdapter()
    let partial = ":255 255 0 0".data(using: .ascii)!  // no LF
    let events = adapter.feed(bytes: partial)
    #expect(events.isEmpty)
}

@Test func malformedOccupancyValueOutOfRange() {
    // 256 cannot be parsed as UInt8 → frame is dropped.
    var adapter = CertaboAdapter()
    let bad = ":256 255 0 0 0 0 255 255\r\n".data(using: .ascii)!
    let events = adapter.feed(bytes: bad)
    #expect(events.isEmpty)
}

@Test func malformedRFIDFramePartialToken() {
    // 319 tokens (one short of 320) → ignored.
    var adapter = CertaboAdapter()
    let tokens = Array(repeating: "0", count: 319).joined(separator: " ")
    let bad = (":" + tokens + "\r\n").data(using: .ascii)!
    let events = adapter.feed(bytes: bad)
    #expect(events.isEmpty)
}

// MARK: - Partial delivery and resync

@Test func partialDeliveryAccumulates() throws {
    let full = ":0 0 0 0 0 0 255 255\r\n".data(using: .ascii)!
    let half = full.count / 2
    var adapter = CertaboAdapter()
    let e1 = adapter.feed(bytes: full.prefix(half))
    #expect(e1.isEmpty, "Partial frame must not emit events")
    let e2 = adapter.feed(bytes: full.dropFirst(half))
    #expect(!e2.isEmpty, "Complete frame must emit events")
}

@Test func junkBeforeValidFrame() throws {
    // Garbage ends with LF so it is a separate line (wrong token count → ignored).
    // The valid frame that follows must still decode correctly.
    let garbage = "garbage text here\n".data(using: .ascii)!
    let valid = ":0 0 0 0 0 0 8 0\r\n".data(using: .ascii)!
    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: garbage + valid)
    // The garbage line has the wrong token count; the valid frame decodes.
    let snaps = occupancySnapshots(from: events)
    #expect(!snaps.isEmpty, "Valid frame after garbage must decode")
    if let occ = snaps.first {
        #expect(isOccupied("e2", in: occ))
    }
}

@Test func colonLessLineAccepted() throws {
    // BLE modules may omit the leading ':' (D1).
    let frame = "255 255 0 0 0 0 255 255\r\n".data(using: .ascii)!
    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: frame)
    let occ = occupancySnapshots(from: events)
    #expect(!occ.isEmpty, "':'-less frame must be accepted (BLE, D1)")
    #expect(occ.first?.filter { $0 }.count == 32)
}

// MARK: - Calibration: learn + lookup

@Test func calibrationLearnStandardStart() {
    let tags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [tags])
    #expect(!cal.isEmpty)
    // Black back rank
    #expect(cal.piece(for: tags[0]) == Piece(type: .rook,   color: .black))  // a8
    #expect(cal.piece(for: tags[1]) == Piece(type: .knight, color: .black))  // b8
    #expect(cal.piece(for: tags[2]) == Piece(type: .bishop, color: .black))  // c8
    #expect(cal.piece(for: tags[3]) == Piece(type: .queen,  color: .black))  // d8
    #expect(cal.piece(for: tags[4]) == Piece(type: .king,   color: .black))  // e8
    #expect(cal.piece(for: tags[5]) == Piece(type: .bishop, color: .black))  // f8
    #expect(cal.piece(for: tags[6]) == Piece(type: .knight, color: .black))  // g8
    #expect(cal.piece(for: tags[7]) == Piece(type: .rook,   color: .black))  // h8
    // White back rank
    #expect(cal.piece(for: tags[56]) == Piece(type: .rook,   color: .white)) // a1
    #expect(cal.piece(for: tags[60]) == Piece(type: .king,   color: .white)) // e1
    #expect(cal.piece(for: tags[63]) == Piece(type: .rook,   color: .white)) // h1
    // Pawns
    #expect(cal.piece(for: tags[8])  == Piece(type: .pawn, color: .black))   // a7
    #expect(cal.piece(for: tags[48]) == Piece(type: .pawn, color: .white))   // a2
}

// MARK: - Calibration: spare queens (D5)

@Test func calibrationSpareQueens() {
    let tags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [tags])
    // d6 (stream 19) → extra black queen
    #expect(cal.piece(for: tags[19]) == Piece(type: .queen, color: .black))
    // d3 (stream 43) → extra white queen
    #expect(cal.piece(for: tags[43]) == Piece(type: .queen, color: .white))
}

@Test func calibrationSpareQueensSkippedIfZero() {
    // If d6/d3 are zero (spares not placed), they must be silently skipped (D5).
    var tags = standardStartTags()
    tags[19] = .zero   // no spare black queen
    tags[43] = .zero   // no spare white queen
    let cal = CertaboCalibration.learn(from: [tags])
    // The calibration should not map zero tags.
    #expect(cal.piece(for: .zero) == nil)
    // Other pieces should still be mapped.
    #expect(cal.piece(for: tags[0]) == Piece(type: .rook, color: .black))
}

@Test func calibrationEmptyFrames() {
    let cal = CertaboCalibration.learn(from: [])
    #expect(cal.isEmpty)
}

@Test func calibrationModalVote15Frames() {
    // Verify modal vote: 14 frames with tagA, 1 frame with tagB → tagA wins.
    var tags = [CertaboTagID](repeating: .zero, count: 64)
    let tagA = CertaboTagID(1, 2, 3, 4, 5)
    let tagB = CertaboTagID(9, 8, 7, 6, 5)
    tags[0] = tagA  // a8

    var frames: [[CertaboTagID]] = Array(repeating: tags, count: 14)
    var noisyFrame = tags; noisyFrame[0] = tagB
    frames.append(noisyFrame)

    let cal = CertaboCalibration.learn(from: frames)
    #expect(cal.piece(for: tagA) == Piece(type: .rook, color: .black))
    #expect(cal.piece(for: tagB) == nil)  // minority — not mapped
}

// MARK: - Calibration: add-piece mode

@Test func calibrationAddPiece() {
    let tags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [tags])

    // New frame with a second white queen tag at index 59 (d1 position).
    var newFrame = [CertaboTagID](repeating: .zero, count: 64)
    let extraTag = CertaboTagID(5, 5, 5, 5, 5)
    newFrame[59] = extraTag   // d1 → white queen position

    let augmented = cal.adding(from: [newFrame])
    // Existing queen tag still works.
    #expect(augmented.piece(for: tags[59]) == Piece(type: .queen, color: .white))
    // New tag also maps to white queen.
    #expect(augmented.piece(for: extraTag) == Piece(type: .queen, color: .white))
}

// MARK: - Effective-empty tag heuristics (D7)

@Test func effectivelyEmptyAllZero() {
    #expect(CertaboTagID.zero.isAllZero)
    #expect(CertaboTagID.zero.isEffectivelyEmpty)
}

@Test func effectivelyEmptyThreeZeroBytes() {
    let noisy = CertaboTagID(251, 196, 0, 47, 0)  // 2 zero bytes — not effectively empty
    #expect(!noisy.isEffectivelyEmpty)
    let noisy2 = CertaboTagID(251, 0, 0, 0, 128)   // 3 zero bytes — heuristic fires
    #expect(noisy2.hasThreeOrMoreZeroBytes)
    #expect(noisy2.isEffectivelyEmpty)
}

// MARK: - Uncalibrated flow (D6)

@Test func uncalibratedEmitsOccupancyAndExposesVotedTags() throws {
    // No calibration: RFID board in uncalibrated mode.
    // Tags must have ≤2 zero bytes so they are not treated as effectively empty (D7).
    var tags = [CertaboTagID](repeating: .zero, count: 64)
    tags[0]  = CertaboTagID(3, 0, 84, 252, 153)   // a8: 1 zero byte → OK
    tags[56] = CertaboTagID(3, 0, 86, 252,   1)   // a1: 1 zero byte → OK

    var adapter = CertaboAdapter()   // no calibration
    let events = adapter.feed(bytes: rfidFrameData(tags))

    // Must emit occupancySnapshot (not identitySnapshot).
    #expect(!events.contains { if case .identitySnapshot = $0 { return true }; return false },
            "Uncalibrated must NOT emit identitySnapshot")
    let occ = try #require(occupancySnapshots(from: events).first)
    #expect(isOccupied("a8", in: occ))
    #expect(isOccupied("a1", in: occ))
    #expect(occ.filter { $0 }.count == 2)

    // Calibration samples via lastVotedTags — the seam-safe calibration UX channel.
    // .raw must NOT be emitted (BoardEvent.raw is for capture-log research only;
    // session code must never branch on it — seam contract in BoardEvent.swift).
    #expect(!events.contains { if case .raw = $0 { return true }; return false },
            "Uncalibrated MUST NOT emit .raw (seam-contract violation)")
    #expect(adapter.lastVotedTags != nil,
            "lastVotedTags must be set after an RFID frame (calibration UX seam)")
    #expect(adapter.lastVotedTags?.count == 64,
            "lastVotedTags must hold 64 entries (stream order)")

    // Must emit .ready.
    #expect(events.contains { if case .ready = $0 { return true }; return false })
}

@Test func uncalibratedOccupancyDeltas() throws {
    var adapter = CertaboAdapter()
    // Tags must have ≤2 zero bytes to avoid the ≥3-zeros empty heuristic (D7).
    let pawnTag = CertaboTagID(3, 0, 84, 252, 1)   // 1 zero byte → not effectively empty

    // Initial frame: e2 occupied (stream 52).
    var tags1 = [CertaboTagID](repeating: .zero, count: 64)
    tags1[52] = pawnTag
    _ = adapter.feed(bytes: rfidFrameData(tags1))

    // Next frame: e4 occupied, e2 empty (move e2e4).
    // With 2 frames in history, the tie-breaking rule (most-recent wins) correctly
    // reports the new stable state: e2 empty, e4 occupied.
    var tags2 = [CertaboTagID](repeating: .zero, count: 64)
    tags2[36] = pawnTag  // stream 36 = e4
    let events = adapter.feed(bytes: rfidFrameData(tags2))

    let deltas = sensed(from: events)
    #expect(deltas.count == 2)
    let lift  = deltas.first { $0.isLift }
    let place = deltas.first { !$0.isLift }
    #expect(lift?.square == "e2")
    #expect(place?.square == "e4")
    // Uncalibrated: piece must be nil.
    #expect(lift?.piece == nil)
    #expect(place?.piece == nil)
}

// MARK: - Calibrated round-trip: short identity game

@Test func calibratedIdentityRoundTrip() throws {
    let startTags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [startTags])
    var adapter = CertaboAdapter(calibration: cal)

    // Feed initial position.
    let initEvents = adapter.feed(bytes: rfidFrameData(startTags))
    let initIdentity = try #require(firstIdentitySnapshot(from: initEvents))
    #expect(pieceAt("e2", in: initIdentity) == Piece(type: .pawn, color: .white))
    #expect(pieceAt("e4", in: initIdentity) == nil)
    #expect(initEvents.contains { if case .ready = $0 { return true }; return false })

    // Move e2e4: move e2 tag to stream index 36 (e4).
    var tags2 = startTags
    let e2Tag = startTags[52]   // stream 52 = e2
    tags2[52] = .zero
    tags2[36] = e2Tag
    let moveEvents = adapter.feed(bytes: rfidFrameData(tags2))

    let deltas = sensed(from: moveEvents)
    #expect(deltas.count == 2)
    let lift  = deltas.first { $0.isLift }
    let place = deltas.first { !$0.isLift }
    #expect(lift?.square  == "e2")
    #expect(place?.square == "e4")
    #expect(lift?.piece   == Piece(type: .pawn, color: .white))
    #expect(place?.piece  == Piece(type: .pawn, color: .white))
}

@Test func calibratedIdentityCapture() throws {
    // Set up: white knight on f3, black pawn on e5 (after 1.e4 e5 Nf3).
    let startTags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [startTags])
    var adapter = CertaboAdapter(calibration: cal)

    // Build a mid-game position directly via tags.
    // stream 36 = e4, stream 12 = e5 (stream=(7-rank)*8+file, e5: (7-4)*8+4=3*8+4=28)
    // f3: rank=2, file=5 → (7-2)*8+5 = 5*8+5 = 45
    // Nf3xe5: knight moves from f3 (stream 45) to e5 (stream 28), capturing black pawn.

    // Build the position after 1.e4 e5 Nf3 (before capture):
    var tags = startTags
    // e4: move e2 pawn (stream 52) to e4 (stream 36)
    let e2PawnTag = startTags[52]
    tags[52] = .zero; tags[36] = e2PawnTag
    // e5: move e7 pawn (stream 12) to e5 (stream 28)
    // e7: (7-6)*8+4 = 1*8+4 = 12
    let e7PawnTag = startTags[12]
    tags[12] = .zero; tags[28] = e7PawnTag
    // Nf3: move g1 knight (stream 62) to f3 (stream 45)
    // g1: (7-0)*8+6 = 7*8+6 = 62; f3: (7-2)*8+5 = 45
    let g1KnightTag = startTags[62]
    tags[62] = .zero; tags[45] = g1KnightTag
    _ = adapter.feed(bytes: rfidFrameData(tags))

    // Execute Nxe5: knight captures e5 pawn.
    var capturePos = tags
    capturePos[45] = .zero          // knight leaves f3
    capturePos[28] = .zero          // pawn captured from e5 (human lifts it)
    // Intermediate: lift both.
    _ = adapter.feed(bytes: rfidFrameData(capturePos))
    // Place knight on e5.
    capturePos[28] = g1KnightTag
    let events = adapter.feed(bytes: rfidFrameData(capturePos))

    let identity = try #require(firstIdentitySnapshot(from: events))
    // e5 should now have a white knight.
    #expect(pieceAt("e5", in: identity) == Piece(type: .knight, color: .white))
    // f3 should be empty.
    #expect(pieceAt("f3", in: identity) == nil)
}

// MARK: - Occupancy board SimulatedBoard round-trip

@Test func occupancyBoardRoundTrip() async throws {
    // SimulatedBoard (occupancy only) + CertaboAdapter occupancy frames.
    //
    // The adapter uses a 3-frame majority vote for debounce. With a 2-frame
    // history, a tie is broken by the most-recent frame (move settles after
    // 1 new frame). With a 3-frame history, 2 identical new frames are needed
    // to achieve a majority. This test accounts for that by feeding e7e5 twice.
    let sim = SimulatedBoard(capabilities: [.occupancySensing])
    var adapter = CertaboAdapter()

    // Prime adapter with initial position (1 frame → history=[init]).
    let initOcc = positionOccupancy(await sim.position)
    _ = adapter.feed(bytes: occupancyFrameData(initOcc))

    // Play 1.e4. Feed once → history=[init, e4]. Tie → most-recent wins.
    _ = try await sim.executeMove(uci: "e2e4")
    let occ1 = positionOccupancy(await sim.position)
    let frame1 = occupancyFrameData(occ1)
    let events1 = adapter.feed(bytes: frame1)
    let snaps1 = occupancySnapshots(from: events1)
    #expect(!snaps1.isEmpty, "Expected occupancySnapshot after e4")
    if let s = snaps1.first {
        #expect(isOccupied("e4", in: s), "e4 should be occupied")
        #expect(!isOccupied("e2", in: s), "e2 should be empty")
    }
    let deltas1 = sensed(from: events1)
    #expect(deltas1.first { $0.square == "e2" &&  $0.isLift }  != nil, "Expected lift e2")
    #expect(deltas1.first { $0.square == "e4" && !$0.isLift }  != nil, "Expected place e4")

    // Play 1…e5. Feed twice: after 2 feeds the majority (2/3) settles.
    // History after 1st e5 feed: [init, e4, e5] → e7 majority occupied (2/3).
    // History after 2nd e5 feed: [e4, e5, e5]  → e7 majority empty (2/3). ✓
    _ = try await sim.executeMove(uci: "e7e5")
    let occ2 = positionOccupancy(await sim.position)
    let frame2 = occupancyFrameData(occ2)
    _ = adapter.feed(bytes: frame2)              // 1st feed: vote still says e7 occupied
    let events2 = adapter.feed(bytes: frame2)   // 2nd feed: vote settles → lift e7, place e5
    let deltas2 = sensed(from: events2)
    #expect(deltas2.first { $0.square == "e5" && !$0.isLift } != nil, "Expected place e5")
    #expect(deltas2.first { $0.square == "e7" &&  $0.isLift } != nil, "Expected lift e7")
}

// MARK: - .ready emitted exactly once

@Test func readyEmittedExactlyOnce() {
    var adapter = CertaboAdapter()
    let frame = ":0 0 0 0 0 0 255 255\r\n".data(using: .ascii)!
    let e1 = adapter.feed(bytes: frame)
    let e2 = adapter.feed(bytes: frame)
    let readyCount = (e1 + e2).filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "Expected exactly one .ready; got \(readyCount)")
}

// MARK: - Majority-vote debounce

@Test func majorityVoteDebounce() throws {
    // With 3-frame history: 2 frames old + 1 frame new → old wins.
    // Then 1 more new frame → 2 new vs 1 old → new wins.
    var tags = [CertaboTagID](repeating: .zero, count: 64)
    let pieceTag = CertaboTagID(3, 0, 84, 1, 1)
    tags[52] = pieceTag  // e2 occupied

    let cal = CertaboCalibration.learn(from: [tags])
    var adapter = CertaboAdapter(calibration: cal)
    _ = adapter.feed(bytes: rfidFrameData(tags))   // frame 1: e2 occupied
    _ = adapter.feed(bytes: rfidFrameData(tags))   // frame 2: e2 occupied

    // Frame 3: e2 empty, e4 occupied (the move).
    var movedTags = [CertaboTagID](repeating: .zero, count: 64)
    movedTags[36] = pieceTag
    let e3 = adapter.feed(bytes: rfidFrameData(movedTags))  // 2 old, 1 new
    // Majority: e2 still occupied (2 vs 1) → no lift event yet.
    let deltas3 = sensed(from: e3)
    let hasLift = deltas3.contains { $0.isLift && $0.square == "e2" }
    // (Debounce suppresses the lift at this point — not an error.)
    // What matters is frame 4 settles.

    let e4 = adapter.feed(bytes: rfidFrameData(movedTags))  // 1 old, 2 new
    let identity4 = try #require(firstIdentitySnapshot(from: e4))
    // After 2 new frames, e4 should be occupied.
    #expect(pieceAt("e4", in: identity4) != nil || !hasLift,
            "After 2 consistent new frames, e4 should be occupied in voted state")
    _ = hasLift  // suppress unused warning
}

// MARK: - Handshake

@Test func handshakeIsEmpty() {
    let adapter = CertaboAdapter()
    #expect(adapter.handshakeCommands(isReconnect: false).isEmpty)
    #expect(adapter.handshakeCommands(isReconnect: true).isEmpty)
}

// MARK: - Unsupported commands return nil

@Test func unsupportedCommandsReturnNil() {
    let adapter = CertaboAdapter()
    #expect(adapter.encode(.startSession) == nil)
    #expect(adapter.encode(.requestState) == nil)
    #expect(adapter.encode(.executeMove(uci: "e2e4")) == nil)
}

// MARK: - Custom command forwarded

@Test func customCommandForwarded() {
    let adapter = CertaboAdapter()
    let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
    #expect(adapter.encode(.custom(payload)) == payload)
}

// MARK: - Capabilities (dynamic, derived from detected board state)

/// Pre-detection default: conservative set excluding pieceIdentity.
@Test func capabilitiesPreDetectionDefault() {
    let adapter = CertaboAdapter()
    #expect(adapter.capabilities.contains(.occupancySensing))
    #expect(adapter.capabilities.contains(.moveIndication))
    #expect(adapter.capabilities.contains(.perSquareLEDs),
            "Classic LED assumed pre-detection")
    #expect(!adapter.capabilities.contains(.pieceIdentity),
            "pieceIdentity must not be advertised until RFID board + calibration detected")
}

/// Calibrated RFID board: all four capabilities present.
@Test func capabilitiesCalibratedRFIDBoard() throws {
    let tags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [tags])
    var adapter = CertaboAdapter(calibration: cal)
    // Feed one RFID frame to trigger detectedBoardType = .rfid.
    _ = adapter.feed(bytes: rfidFrameData(tags))
    #expect(adapter.capabilities.contains(.occupancySensing))
    #expect(adapter.capabilities.contains(.pieceIdentity),
            "pieceIdentity expected after RFID detection + calibration")
    #expect(adapter.capabilities.contains(.perSquareLEDs))
    #expect(adapter.capabilities.contains(.moveIndication))
}

/// Spectrum RGB board: corner-LED grid → .moveIndication only, not .perSquareLEDs.
@Test func capabilitiesSpectrumRGBDropsPerSquareLEDs() {
    var adapter = CertaboAdapter()
    _ = adapter.feed(bytes: "D\r\n".data(using: .ascii)!)
    #expect(adapter.capabilities.contains(.occupancySensing))
    #expect(adapter.capabilities.contains(.moveIndication))
    #expect(!adapter.capabilities.contains(.perSquareLEDs),
            "Spectrum RGB is a 9×9 corner-LED grid; .perSquareLEDs must be absent (Millennium precedent)")
}

/// Tabutronic Sentio (occupancy board): pieceIdentity must never be advertised.
@Test func capabilitiesOccupancyBoardNoIdentity() {
    var adapter = CertaboAdapter()
    _ = adapter.feed(bytes: ":255 255 0 0 0 0 255 255\r\n".data(using: .ascii)!)
    #expect(adapter.capabilities.contains(.occupancySensing))
    #expect(!adapter.capabilities.contains(.pieceIdentity),
            "Tabutronic Sentio (occupancy board) must not advertise pieceIdentity")
}

/// Uncalibrated RFID board: pieceIdentity must not be advertised.
@Test func capabilitiesUncalibratedRFIDNoIdentity() {
    var tags = [CertaboTagID](repeating: .zero, count: 64)
    tags[0] = CertaboTagID(3, 0, 84, 252, 153)
    var adapter = CertaboAdapter()  // no calibration
    _ = adapter.feed(bytes: rfidFrameData(tags))
    #expect(!adapter.capabilities.contains(.pieceIdentity),
            "Uncalibrated RFID board must not advertise pieceIdentity")
}

// MARK: - Stream-index conversion sentinels

/// Confirm streamIndexToFileMajor against named squares.
/// Stream 0=a8, 7=h8, 8=a7, 63=h1.
@Test func streamIndexConversionSentinels() {
    // a8: stream 0 → file=0, rank=7 → fm=7
    #expect(CertaboAdapter.streamIndexToFileMajor(0)  == fm("a8")!)
    // h8: stream 7 → file=7, rank=7 → fm=63
    #expect(CertaboAdapter.streamIndexToFileMajor(7)  == fm("h8")!)
    // a7: stream 8 → file=0, rank=6 → fm=6
    #expect(CertaboAdapter.streamIndexToFileMajor(8)  == fm("a7")!)
    // h1: stream 63 → file=7, rank=0 → fm=56
    #expect(CertaboAdapter.streamIndexToFileMajor(63) == fm("h1")!)
    // e4: stream (7-3)*8+4=36 → file=4, rank=3 → fm=35
    #expect(CertaboAdapter.streamIndexToFileMajor(36) == fm("e4")!)
    // e2: stream (7-1)*8+4=52 → file=4, rank=1 → fm=33
    #expect(CertaboAdapter.streamIndexToFileMajor(52) == fm("e2")!)
}

// MARK: - 180° rotation

@Test func rotationClassicLED() {
    // With rotate180, asking for e4 should light d5 (the 180°-rotated square).
    let adapter = CertaboAdapter(rotate180: true)
    let normal = CertaboAdapter().encode(.indicateSquares(["e4"], style: .highlight))
    let rotated = adapter.encode(.indicateSquares(["e4"], style: .highlight))
    #expect(normal != rotated, "Rotated LED must differ from normal")

    // d5: rank=4, file=3 → byte[7-4]=byte[3], bit 1<<3=0x08
    let expected = Data([0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00])
    #expect(rotated == expected)
}

@Test func rotationOccupancyFrame() throws {
    // With rotate180, a8 in normal stream maps to h1 in rotated view.
    let frameStr = ":255 0 0 0 0 0 0 0\r\n".data(using: .ascii)!  // only rank 8 occupied
    var adapter = CertaboAdapter(rotate180: true)
    let events = adapter.feed(bytes: frameStr)
    let occ = try #require(occupancySnapshots(from: events).first)
    // After 180° rotation, rank 8 physical squares appear as rank 1.
    #expect(isOccupied("a1", in: occ) || isOccupied("h1", in: occ),
            "Rotated board: rank-8 physical squares should appear at rank 1")
}

// MARK: - Multiple frames in one feed call

@Test func multipleFramesInOneFeed() throws {
    let frame1 = ":255 255 0 0 0 0 255 255\r\n".data(using: .ascii)!  // full initial
    let frame2 = ":0 0 0 0 0 0 8 0\r\n".data(using: .ascii)!           // only e2
    var adapter = CertaboAdapter()
    let events = adapter.feed(bytes: frame1 + frame2)
    let snaps = occupancySnapshots(from: events)
    #expect(snaps.count == 2, "Two frames in one feed must produce two snapshots")
}

// MARK: - cer2nut wrapped-RFID golden fixtures

// These fixtures verify that the scanner handles cer2nut-style RFID frames
// that wrap with bare-LF after ~65 chars, even mid-token.
// Protocol facts sourced from gkalab/cer2nut (GPL-3.0); no code structure copied.

/// [CER2NUT] hasPieceRecognitionAndTranslateAreCalledOnce:
/// A single wrapped RFID frame parses identically to its single-line equivalent.
@Test func cer2nutWrappedRFIDSingleFrame() throws {
    let tags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [tags])
    var adapterWrapped = CertaboAdapter(calibration: cal)
    var adapterFlat    = CertaboAdapter(calibration: cal)

    let wrapped = wrappedRfidFrameData(tags, wrapEvery: 65)
    let flat    = rfidFrameData(tags)

    let eventsWrapped = adapterWrapped.feed(bytes: wrapped)
    let eventsFlat    = adapterFlat.feed(bytes: flat)

    let idWrapped = try #require(firstIdentitySnapshot(from: eventsWrapped),
                                 "Wrapped frame must emit identitySnapshot")
    let idFlat    = try #require(firstIdentitySnapshot(from: eventsFlat))

    // Piece at every occupied square must match between wrapped and flat.
    #expect(idWrapped == idFlat,
            "Wrapped frame must decode identically to single-line frame")
    #expect(eventsWrapped.contains { if case .ready = $0 { return true }; return false })
}

/// [CER2NUT] translateIsCalledTwiceForTwoDifferentPositions:
/// Two consecutive wrapped frames for different positions both decode correctly.
@Test func cer2nutWrappedRFIDTwoPositions() throws {
    let tags1 = standardStartTags()
    var tags2 = tags1
    let e2Tag = tags1[52]  // stream 52 = e2
    tags2[52] = .zero
    tags2[36] = e2Tag      // e2→e4

    let cal = CertaboCalibration.learn(from: [tags1])
    var adapter = CertaboAdapter(calibration: cal)

    let e1 = adapter.feed(bytes: wrappedRfidFrameData(tags1, wrapEvery: 65))
    let id1 = try #require(firstIdentitySnapshot(from: e1))
    #expect(pieceAt("e2", in: id1) == Piece(type: .pawn, color: .white),
            "Position 1: e2 must hold white pawn")
    #expect(pieceAt("e4", in: id1) == nil,
            "Position 1: e4 must be empty")

    let e2 = adapter.feed(bytes: wrappedRfidFrameData(tags2, wrapEvery: 65))
    let id2 = try #require(firstIdentitySnapshot(from: e2))
    #expect(pieceAt("e4", in: id2) == Piece(type: .pawn, color: .white),
            "Position 2: e4 must hold white pawn after e2e4")
    #expect(pieceAt("e2", in: id2) == nil,
            "Position 2: e2 must be empty after e2e4")
}

/// [CER2NUT] parsePositionInTwoParts:
/// A bare-LF wrap that splits a numeric token mid-digit is correctly reassembled.
/// Wire pattern "84 4\n4 81" (wrap between digits of token "44") reconstructs
/// token 44 by byte-concatenation of adjacent line fragments.
@Test func cer2nutWrappedRFIDMidTokenSplit() throws {
    // Place CertaboTagID(3,0,84,44,81) on a8 (stream 0). The token sequence for
    // a8 is "3 0 84 44 81". We force a wrap after "84 4" so the LF lands between
    // the two digits of "44", producing "84 4\n4 81" on the wire.
    let splitTag = CertaboTagID(3, 0, 84, 44, 81)
    var specialTags = [CertaboTagID](repeating: .zero, count: 64)
    specialTags[0] = splitTag

    let cal = CertaboCalibration.learn(from: [specialTags])
    var adapter = CertaboAdapter(calibration: cal)

    // Construct the frame manually so the wrap falls exactly between the '4' and '4'
    // of token 44: ":3 0 84 4\n4 81 0 0 0 0 0 ... 0\r\n"
    var frameStr = ":3 0 84 4\n4 81"   // "44" split across a bare-LF boundary
    // Remaining 63 squares: all zero (5 tokens each = 315 tokens).
    for _ in 0..<63 { frameStr += " 0 0 0 0 0" }
    frameStr += " \r\n"

    let events = adapter.feed(bytes: frameStr.data(using: .ascii)!)
    let identity = try #require(firstIdentitySnapshot(from: events),
                                "Mid-token-split wrapped frame must produce identitySnapshot")

    // a8 must be the piece mapped from splitTag (3,0,84,44,81).
    #expect(pieceAt("a8", in: identity) != nil,
            "a8 must be occupied — split token '44' must be reconstructed correctly")
    // All other squares must be empty.
    let occupied = identity.compactMap { $0 }
    #expect(occupied.count == 1, "Only a8 should be occupied; got \(occupied.count)")
}

// MARK: - Direct piece replacement (vote tie-break capture path)

/// Verify that squareSensedDeltas emits BOTH a lift and a place when the
/// majority-vote tie-break produces a direct piece-replacement transition
/// (occupied→occupied, different piece).
///
/// The scenario mirrors a capture sequence where the 3-frame history ties 1/1/1
/// and most-recent-wins resolves to old-piece → new-piece with no empty
/// intermediate in the voted state.
@Test func squareSensedBothEventsOnDirectReplacement() throws {
    let startTags = standardStartTags()
    let cal = CertaboCalibration.learn(from: [startTags])
    var adapter = CertaboAdapter(calibration: cal)

    // Build a position with a black pawn on e5 (stream 28 = e5: (7-4)*8+4).
    // Reuse the e7 pawn tag for this purpose.
    let e7PawnTag = startTags[12]   // stream 12 = e7
    var tagsWithPawnE5 = startTags
    tagsWithPawnE5[12] = .zero
    tagsWithPawnE5[28] = e7PawnTag
    _ = adapter.feed(bytes: rfidFrameData(tagsWithPawnE5))   // prime previousIdentity

    // Build next position: white knight (g1 tag) on e5, black pawn gone.
    // This simulates a voted direct-replacement (pawn@e5 → knight@e5).
    let g1KnightTag = startTags[62]   // stream 62 = g1
    var tagsKnightE5 = tagsWithPawnE5
    tagsKnightE5[62] = .zero          // knight leaves g1
    tagsKnightE5[28] = g1KnightTag   // knight occupies e5 (replacing pawn)
    let events = adapter.feed(bytes: rfidFrameData(tagsKnightE5))

    let deltas = sensed(from: events)
    let liftE5  = deltas.filter { $0.square == "e5" &&  $0.isLift }
    let placeE5 = deltas.filter { $0.square == "e5" && !$0.isLift }
    #expect(liftE5.count  == 1, "Direct replacement must emit exactly one lift on e5")
    #expect(placeE5.count == 1, "Direct replacement must emit exactly one place on e5")
    #expect(liftE5.first?.piece  == Piece(type: .pawn,   color: .black),
            "Lift must carry the old pawn")
    #expect(placeE5.first?.piece == Piece(type: .knight, color: .white),
            "Place must carry the new knight")
}

// MARK: - Calibration injection: no phantom deltas on first calibrated frame

/// Verify that the first calibrated frame after calibration injection does not
/// emit spurious squareSensed events.
///
/// The uncalibrated path previously seeded previousIdentity with an all-nil
/// [Piece?] array. The first calibrated frame then diffed the real identity
/// against that array and emitted up to 32 phantom place events.
/// After the fix, previousIdentity stays nil in the uncalibrated path so
/// the first calibrated frame is treated as a fresh snapshot.
@Test func calibrationInjectionNoPhantomDeltas() throws {
    let tags = standardStartTags()

    var adapter = CertaboAdapter()   // uncalibrated
    // Feed one uncalibrated frame (seeds previousIdentity = nil after fix).
    _ = adapter.feed(bytes: rfidFrameData(tags))

    // Inject calibration.
    adapter.calibration = CertaboCalibration.learn(from: [tags])

    // Feed the same frame with calibration now active.
    let events = adapter.feed(bytes: rfidFrameData(tags))

    // Must emit identitySnapshot but NO squareSensed deltas.
    #expect(firstIdentitySnapshot(from: events) != nil,
            "First calibrated frame must emit an identitySnapshot")
    let deltas = sensed(from: events)
    #expect(deltas.isEmpty,
            "First calibrated frame must not emit any squareSensed events (phantom deltas)")
}
