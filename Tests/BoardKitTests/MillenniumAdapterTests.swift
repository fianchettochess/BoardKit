// MillenniumAdapterTests.swift
// Golden fixture tests for the Millennium ChessLink protocol.
// Every fixture is labelled MF1–MF7 matching the pinned spec.
// MF1+MF3–MF4 are host→board wire-encode tests.
// MF2+MF5 are board→host wire-decode tests.
// MF6 is the LED corner-grid encode test (seam-degradation showcase).
// MF7 is the E2ROM write/read encode test.

import Testing
import Foundation
import ChessCore
@testable import MillenniumAdapter
import BoardKit
import BoardKitTestSupport

// MARK: - Helpers

private func firstIdentitySnapshot(from events: [BoardEvent]) -> [Piece?]? {
    events.compactMap { if case .identitySnapshot(let id) = $0 { return id }; return nil }.first
}

private func piece(at algebraic: String, in identity: [Piece?]) -> Piece? {
    guard let sq = Square(algebraic: algebraic) else { return nil }
    return identity[sq.file * 8 + sq.rank]
}

// MARK: - MF1: V command (host→board)
// Fixture 1: ASCII "V56" → wire D6 B5 B6 (byte-identical to chess_link.py log).

@Test func mf1VCommandEncode() {
    let encoded = MillenniumAdapter.encodeVersionRequest()
    #expect(encoded == Data([0xD6, 0xB5, 0xB6]))
}

@Test func mf1StartSessionEncodeMatchesV() {
    let adapter = MillenniumAdapter()
    let encoded = adapter.encode(.startSession)
    #expect(encoded == Data([0xD6, 0xB5, 0xB6]))
}

// MARK: - MF2: v version reply (board→host, 7 chars)
// Fixture 2: ASCII "v010374" → wire 76 B0 31 B0 B3 37 34 (byte-identical to log).
// Decoded firmware version "01.03".

@Test func mf2VersionReplyDecode() {
    let wireBytes = Data([0x76, 0xB0, 0x31, 0xB0, 0xB3, 0x37, 0x34])
    var adapter = MillenniumAdapter()
    let events = adapter.feed(bytes: wireBytes)
    // v-frame → .raw (no dedicated version event in BoardEvent vocabulary).
    #expect(events.count == 1)
    guard case .raw(let d) = events[0] else {
        Issue.record("Expected .raw for v-frame"); return
    }
    // Raw data is the parity-stripped frame: "v010374" as ASCII bytes.
    #expect(d == Data([0x76, 0x30, 0x31, 0x30, 0x33, 0x37, 0x34]))
}

// MARK: - MF3: S command (host→board)
// Fixture 3: ASCII "S53" → wire D3 B5 B3.

@Test func mf3SCommandEncode() {
    let encoded = MillenniumAdapter.encodeStateRequest()
    #expect(encoded == Data([0xD3, 0xB5, 0xB3]))
}

@Test func mf3RequestStateEncodeMatchesS() {
    let adapter = MillenniumAdapter()
    let encoded = adapter.encode(.requestState)
    #expect(encoded == Data([0xD3, 0xB5, 0xB3]))
}

// MARK: - MF4: X and T commands (host→board)
// Fixture 4: X → wire 58 B5 38; T → wire 54 B5 34 (NO reply for T).

@Test func mf4XCommandEncode() {
    let encoded = MillenniumAdapter.encodeLEDOff()
    #expect(encoded == Data([0x58, 0xB5, 0x38]))
}

@Test func mf4TCommandEncode() {
    let encoded = MillenniumAdapter.encodeReset()
    #expect(encoded == Data([0x54, 0xB5, 0x34]))
}

@Test func mf4EmptyIndicateSquaresEncodesX() {
    let adapter = MillenniumAdapter()
    let encoded = adapter.encode(.indicateSquares([], style: .highlight))
    #expect(encoded == Data([0x58, 0xB5, 0x38]))
}

// MARK: - MF5: s start position (board→host, 67 chars)
// Fixture 5: "srnbqkbnrpppppppp................................PPPPPPPPRNBQKBNR73"
// Wire is verified byte-for-byte against the spec's wire table.

private let f5WireBytes = Data([
    0x73,                                                               // 's'
    0xF2, 0x6E, 0x62, 0xF1, 0x6B, 0x62, 0x6E, 0xF2,                  // rnbqkbnr (rank 8)
    0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70,                   // pppppppp (rank 7)
    0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE,                  // ........ (rank 6)
    0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE,                  // ........ (rank 5)
    0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE,                  // ........ (rank 4)
    0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE,                  // ........ (rank 3)
    0xD0, 0xD0, 0xD0, 0xD0, 0xD0, 0xD0, 0xD0, 0xD0,                  // PPPPPPPP (rank 2)
    0x52, 0xCE, 0xC2, 0x51, 0xCB, 0xC2, 0xCE, 0x52,                  // RNBQKBNR (rank 1)
    0x37, 0xB3,                                                        // Chk "73"
])

@Test func mf5StartPositionDecode() throws {
    var adapter = MillenniumAdapter()
    let events = adapter.feed(bytes: f5WireBytes)
    let identity = try #require(firstIdentitySnapshot(from: events))
    #expect(identity.count == 64)

    // Rank 8 black pieces.
    #expect(piece(at: "a8", in: identity) == Piece(type: .rook,   color: .black))
    #expect(piece(at: "d8", in: identity) == Piece(type: .queen,  color: .black))
    #expect(piece(at: "e8", in: identity) == Piece(type: .king,   color: .black))
    #expect(piece(at: "h8", in: identity) == Piece(type: .rook,   color: .black))

    // Rank 7 black pawns.
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(piece(at: "\(file)7", in: identity) == Piece(type: .pawn, color: .black))
    }

    // Ranks 3–6 empty.
    for rank in 3...6 {
        for file in ["a","b","c","d","e","f","g","h"] {
            #expect(piece(at: "\(file)\(rank)", in: identity) == nil)
        }
    }

    // Rank 2 white pawns.
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(piece(at: "\(file)2", in: identity) == Piece(type: .pawn, color: .white))
    }

    // Rank 1 white pieces.
    #expect(piece(at: "a1", in: identity) == Piece(type: .rook,   color: .white))
    #expect(piece(at: "d1", in: identity) == Piece(type: .queen,  color: .white))
    #expect(piece(at: "e1", in: identity) == Piece(type: .king,   color: .white))
    #expect(piece(at: "h1", in: identity) == Piece(type: .rook,   color: .white))

    // Ready emitted on first frame.
    #expect(events.contains { if case .ready = $0 { return true }; return false })

    // No squareSensed deltas on first frame.
    #expect(!events.contains { if case .squareSensed = $0 { return true }; return false })
}

@Test func mf5StartPositionEncodeRoundTrip() throws {
    // encodeFrame of the start position must reproduce the fixture 5 wire bytes.
    var identity = [Piece?](repeating: nil, count: 64)
    let initial = Position.initial()
    for file in 0..<8 {
        for rank in 0..<8 {
            identity[file * 8 + rank] = initial.board[rank * 8 + file]
        }
    }
    let encoded = MillenniumAdapter.encodeFrame(identity: identity)
    #expect(encoded == f5WireBytes)
}

@Test func mf5DeltaEventsAfterE4() throws {
    // Feed start position, then a position with e4 pawn (e2 empty).
    var adapter = MillenniumAdapter()
    _ = adapter.feed(bytes: f5WireBytes)   // prime previousIdentity

    guard let pos = Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1") else {
        Issue.record("FEN parse failed"); return
    }
    var identity2 = [Piece?](repeating: nil, count: 64)
    for file in 0..<8 {
        for rank in 0..<8 { identity2[file * 8 + rank] = pos.board[rank * 8 + file] }
    }
    let frame2 = MillenniumAdapter.encodeFrame(identity: identity2)
    let events2 = adapter.feed(bytes: frame2)

    let deltas = events2.compactMap { e -> (sq: String, isLift: Bool)? in
        if case .squareSensed(let sq, let lift, _) = e { return (sq, lift) }; return nil
    }
    #expect(deltas.count == 2)
    #expect(deltas.contains { $0.sq == "e2" && $0.isLift })
    #expect(deltas.contains { $0.sq == "e4" && !$0.isLift })
}

// MARK: - MF6: L LED frame for e2 (host→board, 167 bytes)
// Fixture 6: e2 corner LEDs 43,44,53,54 solid on, slot time 0x0F.
// Wire verified byte-for-byte against the spec's fixture 6 wire table.

@Test func mf6SquareToCornerLEDs() {
    // Formula: square (file f, rank r) → i∈{f, f+1}, j∈{8-r, 9-r}, N=9i+j+1.
    // e2: f=4, r=2 → i∈{4,5}, j∈{6,7}.
    //   9×4+6+1=43, 9×4+7+1=44, 9×5+6+1=52, 9×5+7+1=53.
    // NOTE: The spec fixture example text says "53,54" but that is a calculation
    // error (9×5+6+1=52, not 53). The formula and anchors are authoritative.
    let leds = millenniumSquareToCornerLEDs(file: 4, rank: 2)
    #expect(Set(leds) == Set([43, 44, 52, 53]))
}

@Test func mf6LEDSpecAnchors() {
    // Spec anchors: N=1→A8 corner [i=0,j=0]; N=9→A1; N=73→H8; N=81→H1.
    #expect(millenniumSquareToCornerLEDs(file: 0, rank: 8).contains(1))   // A8 has LED 1
    #expect(millenniumSquareToCornerLEDs(file: 0, rank: 1).contains(9))   // A1 has LED 9
    #expect(millenniumSquareToCornerLEDs(file: 7, rank: 8).contains(73))  // H8 has LED 73
    #expect(millenniumSquareToCornerLEDs(file: 7, rank: 1).contains(81))  // H1 has LED 81
}

@Test func mf6LEDRotation() {
    // 180° rotation: N → 82-N. LED 43 → 39, LED 1 → 81.
    #expect(millenniumRotateLED(43) == 39)
    #expect(millenniumRotateLED(1)  == 81)
    #expect(millenniumRotateLED(81) == 1)
}

@Test func mf6E2LEDFrameWireBytes() {
    // encode(.indicateSquares(["e2"], .highlight)) with frameSlotTime=0x0F,
    // ledPattern=0xFF, lighting the 4 corner LEDs of e2.
    //
    // Corner LEDs of e2 (formula-derived): 43,44,52,53.
    // Wire structure: L(4C) + 0F(B0 46) + LEDs 1-42(84×B0) + LEDs 43-44(4×46)
    //   + LEDs 45-51(14×B0) + LEDs 52-53(4×46) + LEDs 54-81(56×B0) + Chk(B3 C1)
    // Total = 3+84+4+14+4+56+2 = 167 bytes. Chk "3A" = same as spec fixture
    // (XOR depends only on count of each char type, not which LEDs are lit).
    let adapter = MillenniumAdapter()
    let encoded = adapter.encode(.indicateSquares(["e2"], style: .highlight))
    guard let encoded else { Issue.record("Expected non-nil for e2 LED frame"); return }
    #expect(encoded.count == 167)

    #expect(encoded[0] == 0x4C)   // 'L' parity
    #expect(encoded[1] == 0xB0)   // '0' parity (slot time '0F')
    #expect(encoded[2] == 0x46)   // 'F' parity
    // LEDs 1-42 (chars 3-86): all "00" → 0xB0
    for i in 3..<87 { #expect(encoded[i] == 0xB0, "LED byte \(i) should be 0xB0") }
    // LEDs 43-44 (chars 87-90): "FF" → 4 × 0x46
    for i in 87..<91 { #expect(encoded[i] == 0x46, "LED byte \(i) should be 0x46") }
    // LEDs 45-51 (chars 91-104): 14 × 0xB0
    for i in 91..<105 { #expect(encoded[i] == 0xB0, "LED byte \(i) should be 0xB0") }
    // LEDs 52-53 (chars 105-108): "FF" → 4 × 0x46
    for i in 105..<109 { #expect(encoded[i] == 0x46, "LED byte \(i) should be 0x46") }
    // LEDs 54-81 (chars 109-164): 56 × 0xB0
    for i in 109..<165 { #expect(encoded[i] == 0xB0, "LED byte \(i) should be 0xB0") }
    // Chk "3A": '3'=0xB3, 'A'=0xC1
    #expect(encoded[165] == 0xB3)
    #expect(encoded[166] == 0xC1)
}

// MARK: - MF7: E2ROM write/read (host→board)
// Fixture 7: W0204 → 57 B0 32 B0 34 B5 31; R02 → 52 B0 32 B5 B0.

@Test func mf7WriteRegister() {
    // W0204: reg 0x02 := 4 (auto-report on change with 2-scan debounce).
    let encoded = MillenniumAdapter.encodeWriteRegister(addr: 0x02, data: 0x04)
    #expect(encoded == Data([0x57, 0xB0, 0x32, 0xB0, 0x34, 0xB5, 0x31]))
}

@Test func mf7ReadRegister() {
    // R02: read reg 0x02.
    let encoded = MillenniumAdapter.encodeReadRegister(addr: 0x02)
    #expect(encoded == Data([0x52, 0xB0, 0x32, 0xB5, 0xB0]))
}

// MARK: - Malformed frame rejection

@Test func malformedChecksumDropped() {
    // Feed a valid v-frame with the checksum byte corrupted. No events.
    var wireBytes = Data([0x76, 0xB0, 0x31, 0xB0, 0xB3, 0x37, 0x34])
    wireBytes[6] = 0x35   // corrupt last Chk byte ('4' → '5', mask to '5')
    var adapter = MillenniumAdapter()
    let events = adapter.feed(bytes: wireBytes)
    #expect(events.isEmpty, "Corrupted checksum must be silently dropped")
}

@Test func unknownFrameTypeByteDiscard() {
    // Unknown type bytes should be discarded (resync), not crash or block.
    let junk = Data([0xFF, 0xAA, 0x00])   // no known frame types
    var adapter = MillenniumAdapter()
    let events = adapter.feed(bytes: junk)
    // Junk bytes are discarded; no events expected.
    #expect(events.isEmpty)
}

@Test func partialFrameAccumulates() {
    // Split fixture 5 (67 bytes) at byte 30; events only after second delivery.
    var adapter = MillenniumAdapter()
    let part1 = f5WireBytes.prefix(30)
    let part2 = f5WireBytes.dropFirst(30)
    let events1 = adapter.feed(bytes: part1)
    #expect(events1.isEmpty, "Partial frame must buffer silently")
    let events2 = adapter.feed(bytes: part2)
    #expect(firstIdentitySnapshot(from: events2) != nil)
}

// MARK: - Orientation detection

@Test func orientationDetectionNativeStart() throws {
    // Feed the native start position; adapter should detect isRotated = false.
    var adapter = MillenniumAdapter()
    _ = adapter.feed(bytes: f5WireBytes)
    #expect(adapter.isRotated == false)
}

@Test func orientationDetectionRotatedStart() throws {
    // Build the rotated start position s-frame.
    // Rotated: k=0 maps to h1, k=63 maps to a8.
    // Payload begins "RNBKQBNR..." (K/Q transposed relative to native rank-1 order).
    //
    // Native payload:  "rnbqkbnr pppppppp ....x32 PPPPPPPP RNBQKBNR"
    // Rotated payload: "RNBKQBNR PPPPPPPP ....x32 pppppppp rnbkqbnr" (exact reversal)
    //
    // The adapter detects orientation by exact-matching the full 64-char payload
    // against the two canonical start-position signatures, per [MCHESS] chess_link.py:360.
    let nativePayload  = Array("rnbqkbnrpppppppp................................PPPPPPPPRNBQKBNR".utf8)
    let rotatedPayload = Array(nativePayload.reversed())
    var ascii: [UInt8] = [UInt8(ascii: "s")]
    ascii += rotatedPayload
    let rotatedWire = millenniumBuildFrame(ascii)

    var adapter = MillenniumAdapter()
    _ = adapter.feed(bytes: rotatedWire)
    #expect(adapter.isRotated == true,
            "Full 64-char rotated start payload must set isRotated=true")
}

@Test func orientationFalsePositiveKQEndgameSafe() {
    // A position with white K on D8 (payload[3]='K') and white Q on E8
    // (payload[4]='Q') must NOT flip isRotated under the full-match algorithm.
    // The old 2-char heuristic would erroneously treat this as a rotated start
    // position — reachable in K+Q endgames or after a promotion to queen on D8/E8.
    var adapter = MillenniumAdapter()
    _ = adapter.feed(bytes: f5WireBytes)   // prime as native orientation
    #expect(adapter.isRotated == false)

    // Build a 64-char payload: K on d8 (payload[3]), Q on e8 (payload[4]), rest '.'.
    // This is NOT the full rotated start position so must leave isRotated unchanged.
    var payload = [UInt8](repeating: UInt8(ascii: "."), count: 64)
    payload[3] = UInt8(ascii: "K")   // d8 = white king
    payload[4] = UInt8(ascii: "Q")   // e8 = white queen
    var ascii: [UInt8] = [UInt8(ascii: "s")]
    ascii += payload
    let endgameFrame = millenniumBuildFrame(ascii)
    _ = adapter.feed(bytes: endgameFrame)

    #expect(adapter.isRotated == false,
            "K+Q endgame with K on D8 + Q on E8 must not trigger orientation flip")
}

@Test func readyEmittedExactlyOnceAcrossRepeats() {
    // Feed the same frame twice; .ready fires only on the first.
    var adapter = MillenniumAdapter()
    let first  = adapter.feed(bytes: f5WireBytes)
    let second = adapter.feed(bytes: f5WireBytes)
    let readyCount = (first + second).filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "Expected exactly one .ready across two feeds; got \(readyCount)")
}

@Test func resetFramingClearsAndReArmsReady() throws {
    // Feed a partial frame, resetFraming, then full frame → clean decode + .ready.
    var adapter = MillenniumAdapter()
    let partial = adapter.feed(bytes: f5WireBytes.prefix(20))
    #expect(partial.isEmpty)
    adapter.resetFraming()
    let events = adapter.feed(bytes: f5WireBytes)
    #expect(firstIdentitySnapshot(from: events) != nil)
    #expect(events.contains { if case .ready = $0 { return true }; return false })
    let deltas = events.filter { if case .squareSensed = $0 { return true }; return false }
    #expect(deltas.isEmpty, "No deltas after resetFraming (first-frame path)")
}

// MARK: - Square index math sentinels

@Test func millenniumSquareIndexMathSentinels() {
    // k=0 → a8 → fileMajor = 0*8+7 = 7
    #expect(millenniumSquareToFileMajor(0) == 7)
    // k=7 → h8 → fileMajor = 7*8+7 = 63
    #expect(millenniumSquareToFileMajor(7) == 63)
    // k=56 → a1 → fileMajor = 0*8+0 = 0
    #expect(millenniumSquareToFileMajor(56) == 0)
    // k=63 → h1 → fileMajor = 7*8+0 = 56
    #expect(millenniumSquareToFileMajor(63) == 56)
    // Round-trip: fileMajorToK is the inverse.
    for fm in 0..<64 {
        #expect(millenniumSquareToFileMajor(millenniumFileMajorToK(fm)) == fm)
    }
}

// MARK: - SimulatedBoard round-trip (identity game incl. capture)

private func encodeMillenniumPosition(_ pos: Position) -> Data {
    var identity = [Piece?](repeating: nil, count: 64)
    for file in 0..<8 {
        for rank in 0..<8 { identity[file * 8 + rank] = pos.board[rank * 8 + file] }
    }
    return MillenniumAdapter.encodeFrame(identity: identity)
}

@Test func millenniumShortGameWithCapture() async throws {
    // Play a short game through SimulatedBoard, encode each position as a
    // Millennium s-frame, decode through MillenniumAdapter, verify deltas.
    let moves = ["e2e4", "e7e5", "g1f3", "b8c6", "f3e5"]  // Nxe5 capture
    var adapter = MillenniumAdapter()
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])

    // Prime adapter with initial position.
    _ = adapter.feed(bytes: encodeMillenniumPosition(Position.initial()))

    for uci in moves {
        _ = try await sim.executeMove(uci: uci)
        let pos = await sim.position
        let frameBytes = encodeMillenniumPosition(pos)
        let events = adapter.feed(bytes: frameBytes)

        // Every frame must produce an identitySnapshot.
        #expect(events.contains { if case .identitySnapshot = $0 { return true }; return false },
                "Expected identitySnapshot for move \(uci)")

        // Every frame must produce at least one squareSensed delta.
        let deltas = events.filter { if case .squareSensed = $0 { return true }; return false }
        #expect(!deltas.isEmpty, "Expected deltas for move \(uci)")
    }
}

@Test func millenniumCaptureDeltaDetail() async throws {
    // After 1.e4 e5 2.Nf3 Nc6, simulate Nxe5 as THREE s-frames (the physical
    // board emits one frame per sensor scan, so a capture produces an intermediate
    // frame with both squares empty before the attacker is placed).
    //
    // The adapter's delta logic fires on nil↔occupied transitions only. A single
    // final-state frame (pawn→knight on e5) shows only f3 empty; to get all three
    // lift/place events the test feeds each physical step separately.
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])
    var adapter = MillenniumAdapter()
    _ = adapter.feed(bytes: encodeMillenniumPosition(Position.initial()))

    for uci in ["e2e4", "e7e5", "g1f3", "b8c6"] {
        _ = try await sim.executeMove(uci: uci)
        _ = adapter.feed(bytes: encodeMillenniumPosition(await sim.position))
    }
    // Position before capture: f3=white knight, e5=black pawn.
    let preCapturePos = await sim.position

    // Step 1: attacker lifts from f3 → f3 empty, e5 still has black pawn.
    var step1 = preCapturePos
    step1.board[Square(algebraic: "f3")!.index] = nil
    let e1 = adapter.feed(bytes: encodeMillenniumPosition(step1))
    let lift_f3 = e1.compactMap { if case .squareSensed(let s, let l, let p) = $0 { return (s,l,p) }; return nil }
    #expect(lift_f3.contains { $0.0 == "f3" && $0.1 == true && $0.2 == Piece(type: .knight, color: .white) })

    // Step 2: captured piece lifted from e5 → both f3 and e5 empty.
    var step2 = step1
    step2.board[Square(algebraic: "e5")!.index] = nil
    let e2 = adapter.feed(bytes: encodeMillenniumPosition(step2))
    let lift_e5 = e2.compactMap { if case .squareSensed(let s, let l, let p) = $0 { return (s,l,p) }; return nil }
    #expect(lift_e5.contains { $0.0 == "e5" && $0.1 == true && $0.2 == Piece(type: .pawn, color: .black) })

    // Step 3: attacker placed on e5 → f3 empty, e5 has white knight.
    var step3 = step2
    step3.board[Square(algebraic: "e5")!.index] = Piece(type: .knight, color: .white)
    let e3 = adapter.feed(bytes: encodeMillenniumPosition(step3))
    let place_e5 = e3.compactMap { if case .squareSensed(let s, let l, let p) = $0 { return (s,l,p) }; return nil }
    #expect(place_e5.contains { $0.0 == "e5" && $0.1 == false && $0.2 == Piece(type: .knight, color: .white) })
}

@Test func millenniumCapabilitiesProfile() {
    let adapter = MillenniumAdapter()
    #expect(adapter.capabilities.contains(.occupancySensing))
    #expect(adapter.capabilities.contains(.pieceIdentity))
    #expect(adapter.capabilities.contains(.moveIndication))
    #expect(!adapter.capabilities.contains(.perSquareLEDs))
    #expect(!adapter.capabilities.contains(.motorised))
    #expect(!adapter.capabilities.contains(.batteryReporting))
}



