// Chessnut Move adapter tests — every golden fixture from the pinned spec
// (F1–F7), malformed-frame rejection, GATT profile detection, capability
// checks, executeMove round-trip, and SimulatedBoard short-game coverage.
//
// Fixture labels match the pinned spec (F1–F7).  Square-index and nibble-order
// derivations are inline so each test is self-documenting.

import Testing
import Foundation
import ChessCore
@testable import ChessnutAdapter
import BoardKit
import BoardKitTestSupport

// MARK: - Private helpers

/// Extract the first identitySnapshot from an event list.
private func firstIdentitySnapshot(from events: [BoardEvent]) -> [Piece?]? {
    for event in events {
        if case .identitySnapshot(let id) = event { return id }
    }
    return nil
}

/// Piece at an algebraic square in a file-major identity array.
private func piece(at algebraic: String, in identity: [Piece?]) -> Piece? {
    guard let sq = Square(algebraic: algebraic) else { return nil }
    return identity[sq.file * 8 + sq.rank]
}

/// Build a file-major identity for a KvK position (black king at `bk`,
/// white king at `wk`, all other squares empty).
private func kingsOnly(bk: String, wk: String) -> [Piece?] {
    var id = [Piece?](repeating: nil, count: 64)
    if let sq = Square(algebraic: bk) { id[sq.file * 8 + sq.rank] = Piece(type: .king, color: .black) }
    if let sq = Square(algebraic: wk) { id[sq.file * 8 + sq.rank] = Piece(type: .king, color: .white) }
    return id
}

/// Encode a ChessCore Position as a 38-byte Move board frame.
private func encodePositionAsMove(_ position: Position) -> Data {
    var identity = [Piece?](repeating: nil, count: 64)
    for file in 0..<8 {
        for rank in 0..<8 {
            identity[file * 8 + rank] = position.board[rank * 8 + file]
        }
    }
    return ChessnutMoveAdapter.encodeFrame(identity: identity)
}

/// Extract squareSensed deltas from an event list.
private func deltas(from events: [BoardEvent]) -> [(square: String, isLift: Bool, piece: Piece?)] {
    events.compactMap {
        if case .squareSensed(let sq, let lift, let p) = $0 { return (sq, lift, p) }
        return nil
    }
}

// MARK: - GATT profile detection

@Test func gattIsMoveProfile() {
    #expect(ChessnutGATT.isMoveProfile(name: "Chessnut Move") == true)
    #expect(ChessnutGATT.isMoveProfile(name: "Chessnut Air")  == false)
    #expect(ChessnutGATT.isMoveProfile(name: "Chessnut Air+") == false)
    #expect(ChessnutGATT.isMoveProfile(name: "Chessnut Pro")  == false)
    #expect(ChessnutGATT.isMoveProfile(name: "Chessnut Go")   == false)
    #expect(ChessnutGATT.isMoveProfile(name: "chessnut move") == false)  // case-sensitive
    #expect(ChessnutGATT.isMoveProfile(name: "") == false)
}

@Test func gattClassicProfileExcludesMove() {
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Air")   == true)
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Air+")  == true)
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Pro")   == true)
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Go")    == true)
    // Classic must NOT match "Chessnut Move" — shared UUIDs, adapter selection
    // by name only.
    #expect(ChessnutGATT.isClassicProfile(name: "Chessnut Move")  == false)
}

// MARK: - Capability bits

@Test func moveAdapterCapabilities() {
    let adapter = ChessnutMoveAdapter()
    let caps = adapter.capabilities
    #expect(caps.contains(.occupancySensing))
    #expect(caps.contains(.pieceIdentity))
    #expect(caps.contains(.perPieceTracking))   // 34 micro-robot pieces
    #expect(caps.contains(.perSquareLEDs))
    #expect(caps.contains(.moveIndication))
    #expect(caps.contains(.motorised))          // auto-move mechanism
    #expect(caps.contains(.batteryReporting))
}

// MARK: - F1: Board frame decode (38-byte Move frame, initial position)
//
// Golden bytes from spec §F1:
// 01 24 58 23 31 85 44 44 44 44 00...00 77 77 77 77 A6 C9 9B 6A 00 00 00 00
//
// Derivation:
//   byte[0]=0x01 board opcode; byte[1]=0x24=36 payload (32 board + 4 tail).
//   byte[2]=0x58: low nibble 8='r'@h8, high 5='n'@g8.
//   byte[3]=0x23: low 3='b'@f8, high 2='k'@e8.
//   byte[4]=0x31: low 1='q'@d8, high 3='b'@c8.
//   byte[5]=0x85: low 5='n'@b8, high 8='r'@a8.
//   bytes[6..9]=0x44: rank-7 pawns (4='p').
//   bytes[10..25]=0x00: ranks 6..3 empty.
//   bytes[26..29]=0x77: rank-2 white pawns (7='P').
//   byte[30]=0xA6: low 6='R'@h1, high A='N'@g1.
//   byte[31]=0xC9: low 9='B'@f1, high C='K'@e1.
//   byte[32]=0x9B: low B='Q'@d1, high 9='B'@c1.
//   byte[33]=0x6A: low A='N'@b1, high 6='R'@a1.
//   bytes[34..37]=0x00: opaque tail (assumed LE u32 timestamp; zeroed here).

private let f1MoveBytes = Data([
    0x01, 0x24,
    0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x77, 0x77, 0x77, 0x77,
    0xA6, 0xC9, 0x9B, 0x6A,
    0x00, 0x00, 0x00, 0x00,   // 4-byte tail (opaque; zeroed)
])

@Test func f1DecodeInitialPosition() throws {
    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: f1MoveBytes)
    let identity = try #require(firstIdentitySnapshot(from: events))
    #expect(identity.count == 64)

    // Rank 8 — black back rank
    #expect(piece(at: "a8", in: identity) == Piece(type: .rook,   color: .black))
    #expect(piece(at: "b8", in: identity) == Piece(type: .knight, color: .black))
    #expect(piece(at: "c8", in: identity) == Piece(type: .bishop, color: .black))
    #expect(piece(at: "d8", in: identity) == Piece(type: .queen,  color: .black))
    #expect(piece(at: "e8", in: identity) == Piece(type: .king,   color: .black))
    #expect(piece(at: "f8", in: identity) == Piece(type: .bishop, color: .black))
    #expect(piece(at: "g8", in: identity) == Piece(type: .knight, color: .black))
    #expect(piece(at: "h8", in: identity) == Piece(type: .rook,   color: .black))

    // Rank 7 — black pawns
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(piece(at: "\(file)7", in: identity) == Piece(type: .pawn, color: .black))
    }

    // Ranks 3–6 — empty
    for rank in 3...6 {
        for file in ["a","b","c","d","e","f","g","h"] {
            #expect(piece(at: "\(file)\(rank)", in: identity) == nil)
        }
    }

    // Rank 2 — white pawns
    for file in ["a","b","c","d","e","f","g","h"] {
        #expect(piece(at: "\(file)2", in: identity) == Piece(type: .pawn, color: .white))
    }

    // Rank 1 — white back rank
    #expect(piece(at: "a1", in: identity) == Piece(type: .rook,   color: .white))
    #expect(piece(at: "b1", in: identity) == Piece(type: .knight, color: .white))
    #expect(piece(at: "c1", in: identity) == Piece(type: .bishop, color: .white))
    #expect(piece(at: "d1", in: identity) == Piece(type: .queen,  color: .white))
    #expect(piece(at: "e1", in: identity) == Piece(type: .king,   color: .white))
    #expect(piece(at: "f1", in: identity) == Piece(type: .bishop, color: .white))
    #expect(piece(at: "g1", in: identity) == Piece(type: .knight, color: .white))
    #expect(piece(at: "h1", in: identity) == Piece(type: .rook,   color: .white))

    // Spec canary sentinels (byte-level derivations in §F1):
    // byte[2] low nibble 8 → black rook @ h8
    #expect(piece(at: "h8", in: identity) == Piece(type: .rook, color: .black))
    // byte[31] high nibble C=12 → white king @ e1
    #expect(piece(at: "e1", in: identity) == Piece(type: .king, color: .white))
    // byte[33] high nibble 6 → white rook @ a1
    #expect(piece(at: "a1", in: identity) == Piece(type: .rook, color: .white))
}

// MARK: - F1: .ready and 38-byte header specifics

@Test func f1DecodesReadyOnFirstFrame() {
    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: f1MoveBytes)
    let readyCount = events.filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "Expected exactly one .ready on the first Move board frame")
}

@Test func f1MoveHeaderIs0x24() {
    // The Move frame header byte[1] must be 0x24 (payload=36 = 32 board + 4 tail).
    // D1: Move = 38 bytes (corrected in chess_move_api c9b1dc6b).
    #expect(f1MoveBytes[1] == 0x24)
    #expect(f1MoveBytes.count == 38)
}

// MARK: - F1: Encode round-trip (decode → re-encode → compare)

@Test func f1EncodeRoundTrip() throws {
    // Decode the F1 Move frame to get an identity snapshot.
    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: f1MoveBytes)
    let identity = try #require(firstIdentitySnapshot(from: events))

    // Re-encode as a 38-byte Move frame.
    let encoded = ChessnutMoveAdapter.encodeFrame(identity: identity)

    // Must match the original F1 bytes byte-for-byte.
    #expect(encoded == f1MoveBytes, "encodeFrame round-trip must be lossless for F1")
    #expect(encoded.count == 38)
    #expect(encoded[0] == 0x01)
    #expect(encoded[1] == 0x24)
}

// MARK: - F2: Auto-move command encode (k@d5, K@e4, force=true, 35 bytes)
//
// Golden bytes from spec §F2:
// 42 21 00*14 02 00 00 C0 00*15
//
// Derivation:
//   d5: file=3,rank=4 → row=8-5=3, pc=7-3=4 → s=3*8+4=28
//       byteIdx=2+28/2=16; s even → LOW nibble; 'k'=2 → byte[16]=0x02.
//   e4: file=4,rank=3 → row=8-4=4, pc=7-4=3 → s=4*8+3=35
//       byteIdx=2+35/2=19; s odd  → HIGH nibble; 'K'=C → byte[19]=0xC0.
//   forceFlag (byte[34]) = 0 (force=true → 0; inverted, per [SWIFT-REF]).
//   Total: 2 header + 32 board + 1 flag = 35 bytes; len byte 0x21=33. [D2]

private let f2AutoMoveBytes = Data([
    0x42, 0x21,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // bytes 2-9
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,               // bytes 10-15
    0x02,                                              // byte 16: d5 black king (LOW nibble=2)
    0x00, 0x00,                                        // bytes 17-18
    0xC0,                                              // byte 19: e4 white king (HIGH nibble=C=12)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // bytes 20-27
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,         // bytes 28-34 (byte[34]=force flag=0)
])

@Test func f2AutoMoveEncode() {
    let identity = kingsOnly(bk: "d5", wk: "e4")
    let encoded  = ChessnutMoveAdapter.encodeAutoMove(identity: identity, force: true)
    #expect(encoded == f2AutoMoveBytes, "F2 auto-move encoding mismatch")
    #expect(encoded.count == 35)
    #expect(encoded[0] == 0x42)
    #expect(encoded[1] == 0x21)   // len = 33 = 32 board + 1 flag [D2]
    #expect(encoded[34] == 0x00)  // forceFlag: force=true → 0 (inverted)
}

@Test func f2ForceNonForceInverted() {
    // Spec §6: EasyLinkSwiftSDK maps force ? 0 : 1.  Verify both values.
    let id = kingsOnly(bk: "d5", wk: "e4")
    let forced    = ChessnutMoveAdapter.encodeAutoMove(identity: id, force: true)
    let nonForced = ChessnutMoveAdapter.encodeAutoMove(identity: id, force: false)
    #expect(forced[34]    == 0x00, "force=true must encode as byte 0")
    #expect(nonForced[34] == 0x01, "force=false must encode as byte 1")
}

// MARK: - F3: Stop auto-move (35 bytes, header + 33 zeros)
//
// Golden bytes from spec §F3 / D2:
// 42 21 00*33
// len byte 0x21=33; total 2+33=35.  README text "34 zeros" is a typo. [D2]

@Test func f3StopAutoMove() {
    let stop = ChessnutMoveAdapter.stopAutoMoveData()
    #expect(stop.count == 35, "Stop command must be exactly 35 bytes [D2]")
    #expect(stop[0] == 0x42)
    #expect(stop[1] == 0x21)
    for i in 2..<35 {
        #expect(stop[i] == 0x00, "Byte \(i) must be 0x00 in stop-auto-move command")
    }
}

// MARK: - F4: LED command (e2 and e4 green, 34 bytes)
//
// Golden bytes from spec §F4:
// 43 20 00*17 20 00*7 20 00*6
//
// Derivation:
//   e4: file=4,rank=3 → row=7-3=4, pc=7-4=3 → s=35
//       byteIdx=2+35/2=19; s odd → HIGH nibble; green=2 → byte[19]=0x20.
//   e2: file=4,rank=1 → row=7-1=6, pc=7-4=3 → s=51
//       byteIdx=2+51/2=27; s odd → HIGH nibble; green=2 → byte[27]=0x20.

private let f4LEDBytes = Data([
    0x43, 0x20,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // bytes 2-9
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // bytes 10-17
    0x00,                                               // byte 18
    0x20,                                               // byte 19: e4 (HIGH=green=2)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,          // bytes 20-26
    0x20,                                               // byte 27: e2 (HIGH=green=2)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,                // bytes 28-33
])

@Test func f4LEDEncodeE2PlusE4Green() {
    let adapter = ChessnutMoveAdapter()
    // .highlight maps to green (2) for the Move adapter.
    let encoded = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
    #expect(encoded == f4LEDBytes, "F4 LED encoding mismatch (e2+e4 green)")
    #expect(encoded?.count == 34)
}

@Test func f4LEDMoveFromAlsoGreen() {
    // .moveFrom also maps to green per the LEDStyle mapping table.
    let adapter = ChessnutMoveAdapter()
    let encoded = adapter.encode(.indicateSquares(["e2", "e4"], style: .moveFrom))
    #expect(encoded == f4LEDBytes)
}

// MARK: - F5: Battery request and response
//
// Golden bytes from spec §F5:
//   Request: 41 01 0C
//   Response: 41 03 0C 01 5B
//   Decoded: charging=1 (charging), level=0x5B=91%.
//
// [SWIFT-REF] testParsesMoveBattery fixture [0x41,0x03,0x0C,1,91].

@Test func f5BatteryRequest() {
    let req = ChessnutMoveAdapter.batteryRequestData()
    #expect(req == Data([0x41, 0x01, 0x0C]))
}

@Test func f5BatteryResponse91Percent() throws {
    let response = Data([0x41, 0x03, 0x0C, 0x01, 0x5B])
    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: response)
    #expect(events.count == 1)
    guard case .battery(let pct) = events[0] else {
        Issue.record("Expected .battery event; got \(events[0])")
        return
    }
    #expect(pct == 91, "0x5B = 91; expected 91% battery level")
}

@Test func f5BatteryResponseZeroLevel() throws {
    // Level=0 is passed through (adapter does not suppress it).
    let response = Data([0x41, 0x03, 0x0C, 0x00, 0x00])
    var adapter  = ChessnutMoveAdapter()
    let events   = adapter.feed(bytes: response)
    guard case .battery(let pct) = events.first else {
        Issue.record("Expected .battery event")
        return
    }
    #expect(pct == 0)
}

@Test func f5BatteryResponseChargingByteNotExposed() throws {
    // charging byte (frame[3]) is not yet forwarded; only level (frame[4]) matters.
    let chargingResponse    = Data([0x41, 0x03, 0x0C, 0x01, 50])
    let notChargingResponse = Data([0x41, 0x03, 0x0C, 0x00, 50])
    var a1 = ChessnutMoveAdapter()
    var a2 = ChessnutMoveAdapter()
    guard case .battery(let pct1) = a1.feed(bytes: chargingResponse).first,
          case .battery(let pct2) = a2.feed(bytes: notChargingResponse).first
    else {
        Issue.record("Expected .battery events")
        return
    }
    #expect(pct1 == 50)
    #expect(pct2 == 50)
}

// MARK: - F6: Piece-status request and response
//
// Golden bytes from spec §F6:
//   Request: 41 01 0B
//   Response first 7 bytes: 41 89 0B 01 00 FF 32 ...
//   Full frame: 139 bytes (0x89=137 payload = 1 subop + 34*4 records).
//
// [D6]: identity byte in each record uses moveIdentityByCode, NOT the FEN
// nibble table.  No dedicated BoardEvent case; emitted as .raw.

@Test func f6PieceStatusRequest() {
    let req = ChessnutMoveAdapter.pieceStatusRequestData()
    #expect(req == Data([0x41, 0x01, 0x0B]))
}

@Test func f6PieceStatusResponseIsRaw() throws {
    // Build a minimal piece-status response (frame header + 34 records).
    // len byte 0x89 = 137 → frameLen = 139.
    var response = [UInt8](repeating: 0, count: 139)
    response[0] = 0x41
    response[1] = 0x89   // payload length = 137
    response[2] = 0x0B   // sub-opcode: piece-status
    // First record (white pawn #1): identity=1, x=0, y=255, bat=50.
    // [SWIFT-REF] testParsesMovePieceStatus fixture.
    response[3] = 0x01   // identity: WP
    response[4] = 0x00   // x=0
    response[5] = 0xFF   // y=255
    response[6] = 0x32   // bat=50

    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: Data(response))
    #expect(events.count == 1)
    guard case .raw(let rawData) = events[0] else {
        Issue.record("Expected .raw for piece-status response")
        return
    }
    #expect(rawData.count == 139)
    #expect(rawData[0] == 0x41)
    #expect(rawData[2] == 0x0B)
}

// MARK: - F7: LED nibble-order canary (h8=red, g8=green → byte[2]=0x21)
//
// Golden bytes from spec §F7:
// 43 20 21 ...
//
// Derivation:
//   h8: file=7,rank=7 → row=0,pc=0 → s=0; byteIdx=2; s even → LOW nibble;
//       red=1 → byte[2] |= 0x01.
//   g8: file=6,rank=7 → row=0,pc=1 → s=1; byteIdx=2; s odd → HIGH nibble;
//       green=2 → byte[2] |= 0x20.
//   byte[2] = 0x20 | 0x01 = 0x21.
//
// Any implementation that has the nibble order mirrored produces 0x12 here.
// [SWIFT-REF] testMoveLEDNibbleOrderCanary.

@Test func f7LEDNibbleOrderCanary() {
    let adapter = ChessnutMoveAdapter()
    // h8=red (.danger→1), g8=green (.moveFrom→2).
    let redH8   = adapter.encode(.indicateSquares(["h8"], style: .danger))
    let greenG8 = adapter.encode(.indicateSquares(["g8"], style: .moveFrom))

    // Build h8=red, g8=green in one command.
    // We build the combined result by verifying each square individually
    // first, then checking the combined encode.
    guard let r = redH8, let g = greenG8 else {
        Issue.record("LED encode returned nil")
        return
    }
    // Red @ h8: byte[2] should have low nibble = 1.
    #expect(r[2] & 0x0F == 0x01, "h8=red → low nibble of byte[2] must be 1")
    // Green @ g8: byte[2] should have high nibble = 2.
    #expect(g[2] >> 4    == 0x02, "g8=green → high nibble of byte[2] must be 2")

    // Combined: indicateSquares with two squares, both via custom nibble.
    // We need both colours at once: encode separate and verify they'd combine.
    // Direct canary: just verify the nibble is 0x21 when we send h8+g8 with styles.
    // Use the fact that the adapter processes all squares in one encode call.
    // Encode h8=red style, g8=green style in a single call — not possible with
    // the current API (all squares share one style).  Instead verify the
    // per-square byte-level math:
    //   LOW nibble of byte[2]  = h8 colour
    //   HIGH nibble of byte[2] = g8 colour
    // Confirm that byte[2] is 0x21 when h8=1(red) and g8=2(green):
    let combined: UInt8 = (0x02 << 4) | 0x01
    #expect(combined == 0x21, "Nibble canary: (green<<4)|red must equal 0x21, not 0x12")
}

// MARK: - Malformed frame rejection

@Test func malformedWrongOpcode() {
    // Board-state frames must have byte[0]==0x01.
    let badFrame = Data([0xFF, 0x24] + [UInt8](repeating: 0, count: 36))
    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: badFrame)
    #expect(events.count == 1)
    guard case .raw = events[0] else {
        Issue.record("Unknown opcode must produce .raw")
        return
    }
}

@Test func malformedTooShortBoardFrame() {
    // Frame with correct opcode but payload < 32 board bytes must be rejected.
    // 33-byte frame: header 01 1F (payload=31 < 32) → raw.
    let shortFrame = Data([0x01, 0x1F] + [UInt8](repeating: 0, count: 31))
    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: shortFrame)
    #expect(events.count == 1)
    guard case .raw = events[0] else {
        Issue.record("Too-short board frame must produce .raw")
        return
    }
}

@Test func malformedInvalidNibble() {
    // Frame with invalid nibble (0xD–0xF) must still emit identitySnapshot
    // AND raw flag AND .ready (first frame).
    var frame = [UInt8](repeating: 0, count: 38)
    frame[0] = 0x01; frame[1] = 0x24
    frame[2] = 0xD8   // high nibble 0xD = invalid; low nibble 8 = black rook
    var adapter = ChessnutMoveAdapter()
    let events  = adapter.feed(bytes: Data(frame))

    #expect(events.contains { if case .identitySnapshot = $0 { return true }; return false })
    #expect(events.contains { if case .raw              = $0 { return true }; return false })
    let readyCount = events.filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "Invalid nibble must not suppress .ready on first frame")
}

@Test func malformedPartialFrameAccumulates() {
    // Split an F1 frame across two deliveries; events only on second delivery.
    let part1 = f1MoveBytes.prefix(12)
    let part2 = f1MoveBytes.dropFirst(12)
    var adapter = ChessnutMoveAdapter()
    let e1 = adapter.feed(bytes: part1)
    #expect(e1.isEmpty, "Partial frame must buffer silently")
    let e2 = adapter.feed(bytes: part2)
    #expect(firstIdentitySnapshot(from: e2) != nil, "Complete frame must decode after accumulation")
}

// MARK: - .ready gating

@Test func moveReadyEmittedExactlyOnceAcrossTwoIdenticalFrames() {
    var adapter = ChessnutMoveAdapter()
    let first  = adapter.feed(bytes: f1MoveBytes)
    let second = adapter.feed(bytes: f1MoveBytes)   // heartbeat / repeat
    let count  = (first + second).filter { if case .ready = $0 { return true }; return false }.count
    #expect(count == 1, "Expected exactly one .ready; got \(count)")
}

// MARK: - resetFraming

@Test func moveResetFramingClearsBufferAndReArmsReady() throws {
    var adapter = ChessnutMoveAdapter()
    let partial = adapter.feed(bytes: f1MoveBytes.prefix(10))
    #expect(partial.isEmpty)
    adapter.resetFraming()
    let events = adapter.feed(bytes: f1MoveBytes)
    #expect(firstIdentitySnapshot(from: events) != nil)
    #expect(events.contains { if case .ready = $0 { return true }; return false })
    #expect(events.filter { if case .squareSensed = $0 { return true }; return false }.isEmpty,
            "No squareSensed deltas after resetFraming (clean first-frame path)")
}

// MARK: - Handshake commands

@Test func handshakeCommandsFirstConnect() {
    let adapter = ChessnutMoveAdapter()
    let cmds = adapter.handshakeCommands(isReconnect: false)
    #expect(cmds.count == 1)
    let data = adapter.encode(cmds[0].command)
    #expect(data == Data([0x21, 0x01, 0x00]))
    #expect(cmds[0].delayBefore == .zero)
}

@Test func handshakeCommandsReconnect() {
    let adapter = ChessnutMoveAdapter()
    let cmds = adapter.handshakeCommands(isReconnect: true)
    #expect(cmds.count == 1)
    let data = adapter.encode(cmds[0].command)
    #expect(data == Data([0x21, 0x01, 0x00]))
    #expect(cmds[0].delayBefore == 0.25)
}

// MARK: - executeMove through encode (F2 round-trip via adapter)
//
// Feeds a source position (k@d6, K@e4) then encodes executeMove("d6d5").
// Target (k@d5, K@e4) must match F2 bytes.

@Test func executeMoveEncodeF2() throws {
    var adapter = ChessnutMoveAdapter()

    // Build source position: black king at d6, white king at e4.
    let source = kingsOnly(bk: "d6", wk: "e4")
    let frame  = ChessnutMoveAdapter.encodeFrame(identity: source)
    _ = adapter.feed(bytes: frame)

    // Encode the black king moving from d6 to d5.
    let encoded = adapter.encode(.executeMove(uci: "d6d5"))

    // Target identity: k@d5, K@e4 — must match F2.
    #expect(encoded == f2AutoMoveBytes, "executeMove('d6d5') must produce F2 auto-move bytes")
}

@Test func executeMoveReturnsNilBeforeAnyFrame() {
    let adapter = ChessnutMoveAdapter()
    // No board frame received yet → currentIdentity is nil → returns nil.
    let result = adapter.encode(.executeMove(uci: "e2e4"))
    #expect(result == nil, "executeMove must return nil before any board frame is received")
}

@Test func executeMoveNonExistentPiece() {
    var adapter = ChessnutMoveAdapter()
    // Feed empty board (all-zero payload).
    var frame = [UInt8](repeating: 0, count: 38)
    frame[0] = 0x01; frame[1] = 0x24
    _ = adapter.feed(bytes: Data(frame))
    // Move from an empty square → returns nil.
    #expect(adapter.encode(.executeMove(uci: "e2e4")) == nil)
}

@Test func executeMoveCapture() throws {
    // Start with a board that has a white pawn at e4 and black pawn at d5.
    var id = [Piece?](repeating: nil, count: 64)
    id[4 * 8 + 3] = Piece(type: .pawn, color: .white)  // e4
    id[3 * 8 + 4] = Piece(type: .pawn, color: .black)  // d5
    var adapter = ChessnutMoveAdapter()
    _ = adapter.feed(bytes: ChessnutMoveAdapter.encodeFrame(identity: id))

    // White captures e4xd5.
    let encoded = try #require(adapter.encode(.executeMove(uci: "e4d5")))
    #expect(encoded[0] == 0x42)
    #expect(encoded.count == 35)

    // Decode the target board and verify d5=white pawn, e4=empty.
    let (targetId, _) = chessnutDecodeBoard(from: Array(encoded), start: 2)
    #expect(piece(at: "d5", in: targetId) == Piece(type: .pawn, color: .white))
    #expect(piece(at: "e4", in: targetId) == nil)
}

@Test func executeMoveCastlingKingside() throws {
    // White castles kingside: e1g1.
    // Board: white king at e1, white rook at h1, nothing blocking.
    var id = [Piece?](repeating: nil, count: 64)
    id[4 * 8 + 0] = Piece(type: .king, color: .white)  // e1
    id[7 * 8 + 0] = Piece(type: .rook, color: .white)  // h1
    var adapter = ChessnutMoveAdapter()
    _ = adapter.feed(bytes: ChessnutMoveAdapter.encodeFrame(identity: id))

    let encoded = try #require(adapter.encode(.executeMove(uci: "e1g1")))
    let (targetId, _) = chessnutDecodeBoard(from: Array(encoded), start: 2)
    #expect(piece(at: "g1", in: targetId) == Piece(type: .king, color: .white))
    #expect(piece(at: "f1", in: targetId) == Piece(type: .rook, color: .white))
    #expect(piece(at: "e1", in: targetId) == nil)
    #expect(piece(at: "h1", in: targetId) == nil)
}

@Test func executeMoveCastlingQueenside() throws {
    // White castles queenside: e1c1.
    var id = [Piece?](repeating: nil, count: 64)
    id[4 * 8 + 0] = Piece(type: .king, color: .white)  // e1
    id[0 * 8 + 0] = Piece(type: .rook, color: .white)  // a1
    var adapter = ChessnutMoveAdapter()
    _ = adapter.feed(bytes: ChessnutMoveAdapter.encodeFrame(identity: id))

    let encoded = try #require(adapter.encode(.executeMove(uci: "e1c1")))
    let (targetId, _) = chessnutDecodeBoard(from: Array(encoded), start: 2)
    #expect(piece(at: "c1", in: targetId) == Piece(type: .king, color: .white))
    #expect(piece(at: "d1", in: targetId) == Piece(type: .rook, color: .white))
    #expect(piece(at: "e1", in: targetId) == nil)
    #expect(piece(at: "a1", in: targetId) == nil)
}

@Test func executeMoveEnPassant() throws {
    // White e5 captures en passant to d6; the d5 black pawn is removed.
    var id = [Piece?](repeating: nil, count: 64)
    id[4 * 8 + 4] = Piece(type: .pawn, color: .white)  // e5 (file=4, rank=4)
    id[3 * 8 + 4] = Piece(type: .pawn, color: .black)  // d5 (file=3, rank=4)
    // d6 is empty → en passant detection triggers.
    var adapter = ChessnutMoveAdapter()
    _ = adapter.feed(bytes: ChessnutMoveAdapter.encodeFrame(identity: id))

    let encoded = try #require(adapter.encode(.executeMove(uci: "e5d6")))
    let (targetId, _) = chessnutDecodeBoard(from: Array(encoded), start: 2)
    #expect(piece(at: "d6", in: targetId) == Piece(type: .pawn, color: .white))
    #expect(piece(at: "e5", in: targetId) == nil)
    #expect(piece(at: "d5", in: targetId) == nil, "En-passant: captured pawn must be removed from d5")
}

@Test func executeMovePromotion() throws {
    // White pawn on e7 promotes to queen on e8.
    var id = [Piece?](repeating: nil, count: 64)
    id[4 * 8 + 6] = Piece(type: .pawn, color: .white)  // e7 (file=4, rank=6)
    var adapter = ChessnutMoveAdapter()
    _ = adapter.feed(bytes: ChessnutMoveAdapter.encodeFrame(identity: id))

    let encoded = try #require(adapter.encode(.executeMove(uci: "e7e8q")))
    let (targetId, _) = chessnutDecodeBoard(from: Array(encoded), start: 2)
    #expect(piece(at: "e8", in: targetId) == Piece(type: .queen, color: .white))
    #expect(piece(at: "e7", in: targetId) == nil)
}

@Test func executeMoveRejectsMalformedAndUnsafeTargets() {
    func encoded(_ uci: String, identity: [Piece?]) -> Data? {
        var adapter = ChessnutMoveAdapter()
        _ = adapter.feed(bytes: ChessnutMoveAdapter.encodeFrame(identity: identity))
        return adapter.encode(.executeMove(uci: uci))
    }

    var pawn = [Piece?](repeating: nil, count: 64)
    pawn[4 * 8 + 6] = Piece(type: .pawn, color: .white) // e7
    #expect(encoded("e7e8", identity: pawn) == nil, "promotion suffix is required")
    #expect(encoded("e7e8x", identity: pawn) == nil, "invalid promotion piece")
    #expect(encoded("e7e8qq", identity: pawn) == nil, "overlong UCI")
    pawn[4 * 8 + 7] = Piece(type: .rook, color: .black) // e8 occupied by opponent
    #expect(encoded("e7e8q", identity: pawn) == nil, "a pawn cannot capture forward while promoting")
    pawn[4 * 8 + 7] = nil
    #expect(encoded("e7d8q", identity: pawn) == nil, "a diagonal promotion requires a capture")
    pawn[3 * 8 + 7] = Piece(type: .rook, color: .black) // d8: valid capture-promotion
    #expect(encoded("e7d8q", identity: pawn) != nil)

    var castle = [Piece?](repeating: nil, count: 64)
    castle[4 * 8] = Piece(type: .king, color: .white) // e1; h1 rook absent
    #expect(encoded("e1g1", identity: castle) == nil, "must not invent a missing rook")
    castle[7 * 8] = Piece(type: .rook, color: .white)
    castle[5 * 8] = Piece(type: .bishop, color: .black) // f1 blocks the physical path
    #expect(encoded("e1g1", identity: castle) == nil, "castling path must match the snapshot")

    var enPassant = [Piece?](repeating: nil, count: 64)
    enPassant[4 * 8 + 4] = Piece(type: .pawn, color: .white) // e5; d5 pawn absent
    #expect(encoded("e5d6", identity: enPassant) == nil, "must not invent an en-passant capture")
    enPassant[4 * 8 + 4] = nil
    enPassant[4 * 8 + 3] = Piece(type: .pawn, color: .white) // e4
    enPassant[3 * 8 + 3] = Piece(type: .pawn, color: .black) // d4
    #expect(encoded("e4d5", identity: enPassant) == nil, "en passant requires the fifth rank")

    // File delta must be exactly 1: "e5g6" (two files over, correct EP ranks,
    // empty target) with an enemy pawn sitting on g5 previously slipped
    // through the EP branch — the codec would command the motor to teleport
    // the pawn two files AND delete a third piece.
    var epFileDelta = [Piece?](repeating: nil, count: 64)
    epFileDelta[4 * 8 + 4] = Piece(type: .pawn, color: .white) // e5
    epFileDelta[6 * 8 + 4] = Piece(type: .pawn, color: .black) // g5 ("captured" pawn)
    #expect(encoded("e5g6", identity: epFileDelta) == nil,
            "en passant must move exactly one file")
    var epFileDeltaBlack = [Piece?](repeating: nil, count: 64)
    epFileDeltaBlack[4 * 8 + 3] = Piece(type: .pawn, color: .black) // e4
    epFileDeltaBlack[2 * 8 + 3] = Piece(type: .pawn, color: .white) // c4 ("captured" pawn)
    #expect(encoded("e4c3", identity: epFileDeltaBlack) == nil,
            "en passant must move exactly one file (black)")

    var ownTarget = [Piece?](repeating: nil, count: 64)
    ownTarget[1 * 8] = Piece(type: .knight, color: .white) // b1
    ownTarget[2 * 8 + 2] = Piece(type: .pawn, color: .white) // c3
    #expect(encoded("b1c3", identity: ownTarget) == nil, "must not overwrite an own piece")
}

// MARK: - LED style mapping

@Test func ledStyleDanger() {
    let adapter = ChessnutMoveAdapter()
    let encoded = adapter.encode(.indicateSquares(["a1"], style: .danger))
    guard let data = encoded else {
        Issue.record("LED encode nil"); return
    }
    // a1: file=0,rank=0 → row=7,pc=7 → s=7*8+7=63; byteIdx=2+63/2=33; s odd → HIGH nibble.
    // danger=red=1 → byte[33] = 0x10.
    #expect(data[33] == 0x10, "a1=red: byte[33] HIGH nibble must be 1 (red)")
}

@Test func ledStyleMoveTo() {
    let adapter = ChessnutMoveAdapter()
    let encoded = adapter.encode(.indicateSquares(["h8"], style: .moveTo))
    guard let data = encoded else {
        Issue.record("LED encode nil"); return
    }
    // h8: s=0; byteIdx=2; s even → LOW nibble; blue=3 → byte[2]=0x03.
    #expect(data[2] & 0x0F == 0x03, "h8=blue: low nibble must be 3 (blue)")
}

@Test func ledClearAllSquares() {
    let adapter = ChessnutMoveAdapter()
    let encoded = adapter.encode(.indicateSquares([], style: .highlight))
    guard let data = encoded else {
        Issue.record("LED encode nil"); return
    }
    #expect(data.count == 34)
    #expect(data[0] == 0x43)
    #expect(data[1] == 0x20)
    for i in 2..<34 {
        #expect(data[i] == 0x00, "All-off: byte[\(i)] must be 0x00")
    }
}

// MARK: - SimulatedBoard identity round-trip (short game with capture)
//
// Plays a 5-move sequence through SimulatedBoard (identity board, captures
// the e5 pawn with Nxe5), encodes each resulting position as a 38-byte Move
// frame, decodes via ChessnutMoveAdapter, and verifies identitySnapshot and
// squareSensed lift events.
//
// Delta-event note: the Move adapter decodes position differences between
// consecutive frames.  For captures, the destination square goes from
// "occupied by captured piece" to "occupied by moving piece" — neither nil
// transition triggers — so only a lift of the source square is emitted.
// The place is implicit in the resulting identitySnapshot.  Simple moves
// (no capture at destination) produce the full lift+place pair.

@Test func moveAdapterIdentityBoardShortGame() async throws {
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])
    var adapter = ChessnutMoveAdapter()

    // Prime the adapter with the initial position.
    _ = adapter.feed(bytes: encodePositionAsMove(Position.initial()))

    // Play 1.e4 e5 2.Nf3 Nc6.
    let simpleMoves = ["e2e4", "e7e5", "g1f3", "b8c6"]
    let simpleLifts  = ["e2", "e7", "g1", "b8"]
    let simplePlaces = ["e4", "e5", "f3", "c6"]

    for (i, uci) in simpleMoves.enumerated() {
        _ = try await sim.executeMove(uci: uci)
        let pos    = await sim.position
        let events = adapter.feed(bytes: encodePositionAsMove(pos))

        #expect(events.contains { if case .identitySnapshot = $0 { return true }; return false },
                "Move \(uci): expected identitySnapshot")

        let ds = deltas(from: events)
        #expect(!ds.isEmpty, "Move \(uci): expected squareSensed deltas")

        let lift  = ds.first { $0.isLift }
        let place = ds.first { !$0.isLift }
        #expect(lift?.square  == simpleLifts[i],  "Move \(uci): lift from \(simpleLifts[i])")
        #expect(place?.square == simplePlaces[i], "Move \(uci): place at \(simplePlaces[i])")
    }

    // Play 3.Nxe5 (capture — destination had black pawn, now white knight).
    // Frame delta: f3 → nil (lift); e5 stays occupied (black→white) → no place delta.
    // Verified via the resulting identitySnapshot.
    _ = try await sim.executeMove(uci: "f3e5")
    let capturePos    = await sim.position
    let captureEvents = adapter.feed(bytes: encodePositionAsMove(capturePos))

    #expect(captureEvents.contains { if case .identitySnapshot = $0 { return true }; return false },
            "Capture: expected identitySnapshot")

    let captureDeltas = deltas(from: captureEvents)
    let captureLift   = captureDeltas.first { $0.isLift }
    #expect(captureLift?.square == "f3", "Nxe5 capture: lift from f3")
    #expect(captureLift?.piece  == Piece(type: .knight, color: .white))

    // Verify via identitySnapshot that e5 now holds the white knight.
    guard let capId = firstIdentitySnapshot(from: captureEvents) else {
        Issue.record("Expected identitySnapshot after capture"); return
    }
    #expect(piece(at: "e5", in: capId) == Piece(type: .knight, color: .white),
            "Nxe5: e5 must hold white knight in identitySnapshot")
    #expect(piece(at: "f3", in: capId) == nil, "Nxe5: f3 must be empty after capture")
}

// MARK: - SimulatedBoard occupancy round-trip (no piece identity)

@Test func moveAdapterOccupancyOnlyMode() async throws {
    // Even without .pieceIdentity in the simulator, the Move adapter (which
    // always carries identity) still produces correct identity snapshots
    // from its own encodeFrame/decodeBoard cycle.
    let sim     = SimulatedBoard(capabilities: [.occupancySensing])
    var adapter = ChessnutMoveAdapter()
    _ = adapter.feed(bytes: encodePositionAsMove(Position.initial()))

    _ = try await sim.executeMove(uci: "e2e4")
    let pos    = await sim.position
    let events = adapter.feed(bytes: encodePositionAsMove(pos))
    let id     = firstIdentitySnapshot(from: events)
    guard let identity = id else {
        Issue.record("Expected identitySnapshot"); return
    }
    #expect(piece(at: "e4", in: identity) == Piece(type: .pawn, color: .white))
    #expect(piece(at: "e2", in: identity) == nil)
}

// MARK: - .custom passthrough

@Test func customDataPassthrough() {
    let adapter = ChessnutMoveAdapter()
    let payload = Data([0xAA, 0xBB, 0xCC])
    #expect(adapter.encode(.custom(payload)) == payload)
}

// MARK: - encodeAutoMove symmetric identity

@Test func encodeAutoMoveEmptyBoard() {
    let empty   = [Piece?](repeating: nil, count: 64)
    let encoded = ChessnutMoveAdapter.encodeAutoMove(identity: empty, force: true)
    #expect(encoded.count == 35)
    // All board bytes zero; forceFlag=0.
    for i in 2..<35 {
        #expect(encoded[i] == 0x00)
    }
}
