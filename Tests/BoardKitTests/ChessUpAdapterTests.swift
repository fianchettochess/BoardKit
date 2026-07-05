// ChessUp adapter golden-fixture tests.
//
// Fixture labels F1–F9 match the pinned spec exactly.  Both directions are
// tested where applicable: HOST→BOARD (encode) and BOARD→HOST (decode).
// Malformed-frame rejection, A3 dedup, ready emission, GATT name matching,
// and SimulatedBoard round-trips are also covered.

import Testing
import Foundation
import ChessCore
import BoardKit
import ChessUpAdapter
import BoardKitTestSupport

// MARK: - Helpers

/// Extract all squareSensed events from a list.
private func sensed(_ events: [BoardEvent]) -> [(square: String, isLift: Bool, piece: Piece?)] {
    events.compactMap {
        if case .squareSensed(let sq, let lift, let piece) = $0 { return (sq, lift, piece) }
        return nil
    }
}

/// Extract the first occupancySnapshot from a list.
private func firstOccupancy(from events: [BoardEvent]) -> [Bool]? {
    for e in events {
        if case .occupancySnapshot(let occ) = e { return occ }
    }
    return nil
}

/// Occupancy of a named square in a file-major bool array.
private func isOccupied(_ square: String, in occ: [Bool]) -> Bool {
    guard let sq = Square(algebraic: square) else { return false }
    return occ[sq.file * 8 + sq.rank]
}

/// Build a file-major occupancy array from a Position.
private func fileMajorOccupancy(from position: Position) -> [Bool] {
    var occ = [Bool](repeating: false, count: 64)
    for file in 0..<8 {
        for rank in 0..<8 {
            let rankMajor = rank * 8 + file
            let fileMajor = file * 8 + rank
            occ[fileMajor] = position.board[rankMajor] != nil
        }
    }
    return occ
}

// MARK: - F1: RGB assistance frame (HOST→BOARD, opcode 0x10)
// [FACTS-ONLY: bluecheese sendAssistance, GPL-3.0/LGPL-3.0 — re-expressed from facts]
// Golden fixture from the pinned spec.

@Test func f1RgbAssistanceFrameEncode() {
    // 5 legal moves, colours: Green(2), Blue(1), Red(0), Blue(1), Green(2).
    // Packed MSB-pair first: byte0 = (2<<6)|(1<<4)|(0<<2)|(1<<0) = 0x91
    //                        byte1 = (2<<6) = 0x80
    let expected = Data([0x10, 0x05, 0x91, 0x80])
    let result = ChessUpAdapter.rgbAssistanceData(colours: [2, 1, 0, 1, 2])
    #expect(result == expected)
}

@Test func f1RgbAssistanceFrameZeroMoves() {
    // Zero legal moves → count byte 0, no payload bytes.
    let result = ChessUpAdapter.rgbAssistanceData(colours: [])
    #expect(result == Data([0x10, 0x00]))
}

@Test func f1RgbAssistanceFrameSingleMove() {
    // One move, Red(0): packs to 0x00 in the MSB pair of byte 2.
    let result = ChessUpAdapter.rgbAssistanceData(colours: [0])
    #expect(result == Data([0x10, 0x01, 0x00]))
}

@Test func f1RgbAssistanceFrameFourMoves() {
    // Exactly 4 moves → one payload byte, no partial second byte.
    // Green(2), Green(2), Green(2), Green(2) → (2<<6)|(2<<4)|(2<<2)|(2<<0) = 0xAA
    let result = ChessUpAdapter.rgbAssistanceData(colours: [2, 2, 2, 2])
    #expect(result == Data([0x10, 0x04, 0xAA]))
}

// MARK: - F2: Show move e2→e4 on LEDs (HOST→BOARD, opcode 0x99)
// [PRIMARY] chessupdriver MoveToBoardMessage; [FACTS-ONLY] bluecheese requestMove.
// Canonical idx formula: rank0indexed*8 + file (file a=0...h=7).
// e2: rank=1, file=4 → 1*8+4 = 12 = 0x0C. e4: rank=3, file=4 → 3*8+4 = 28 = 0x1C.

@Test func f2ShowMoveE2E4Encode() {
    // Spec fixture F2: [99, 0x0C, 0x1C]
    let expected = Data([0x99, 0x0C, 0x1C])
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight)) == expected)
    // LEDStyle is advisory on 0x99; all styles produce identical bytes.
    #expect(adapter.encode(.indicateSquares(["e2", "e4"], style: .moveFrom)) == expected)
    #expect(adapter.encode(.indicateSquares(["e2", "e4"], style: .moveTo))   == expected)
    #expect(adapter.encode(.indicateSquares(["e2", "e4"], style: .danger))   == expected)
}

@Test func f2ShowMoveA1H8Encode() {
    // Corner-to-corner: a1=idx0, h8=idx63.
    let expected = Data([0x99, 0x00, 0x3F])
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.indicateSquares(["a1", "h8"], style: .highlight)) == expected)
}

@Test func f2IndicateSquaresRejectsNonTwo() {
    // Non-2-square calls return nil (unsupported for ChessUp LED model).
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.indicateSquares([], style: .highlight))           == nil)
    #expect(adapter.encode(.indicateSquares(["e2"], style: .highlight))       == nil)
    #expect(adapter.encode(.indicateSquares(["e2","e4","e6"], style: .highlight)) == nil)
}

@Test func f2ExecuteMoveReturnsNil() {
    // ChessUp is not motorised.
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.executeMove(uci: "e2e4")) == nil)
}

// MARK: - F3: Move on board g8→f6 (BOARD→HOST, opcode 0xA3)
// [PRIMARY] chessupdriver MoveFromBoardMessage; [FACTS-ONLY] bluecheese RESP_MOVE.
// Frame: [A3, sub=0x35, fromCol=6, fromRow=7, toCol=5, toRow=5]
// g8: col g=6, row 7 (rank8 0-indexed). f6: col f=5, row 5 (rank6 0-indexed).
// Ack: host MUST send 0x21 after receiving A3. Board retransmits until acked.

@Test func f3MoveFromBoardDecode() throws {
    let frame = Data([0xA3, 0x35, 0x06, 0x07, 0x05, 0x05])
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: frame)
    let s = sensed(events)
    #expect(s.count == 2)
    #expect(s[0] == ("g8", true,  nil))   // lift from g8
    #expect(s[1] == ("f6", false, nil))   // place on f6
    // Piece is always nil (no .pieceIdentity capability)
    for e in s { #expect(e.piece == nil) }
}

@Test func f3A3AckEncoding() {
    // Board retransmits A3 until host sends 0x21.
    let ack = ChessUpAdapter.ackMoveData()
    #expect(ack == Data([0x21]))
    // Also reachable via .custom
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.custom(Data([0x21]))) == Data([0x21]))
}

@Test func f3A3DeduplicateConsecutiveIdenticalFrames() {
    // [DISCREPANCY D7] Board retransmits until acked — adapter must dedup.
    let frame = Data([0xA3, 0x35, 0x06, 0x07, 0x05, 0x05])
    var adapter = ChessUpAdapter()
    let first  = adapter.feed(bytes: frame)
    let second = adapter.feed(bytes: frame)   // identical retransmit
    // First: two squareSensed events.
    #expect(sensed(first).count == 2)
    // Second: deduped — no events emitted.
    #expect(second.isEmpty)
}

@Test func f3A3NonIdenticalConsecutiveNotDeduped() {
    // Different A3 frames (different moves) must NOT be deduped.
    let a3e4 = Data([0xA3, 0x35, 0x04, 0x01, 0x04, 0x03])  // e2→e4 in col/row
    let a3e5 = Data([0xA3, 0x35, 0x04, 0x06, 0x04, 0x04])  // e7→e5 in col/row
    var adapter = ChessUpAdapter()
    let ev1 = adapter.feed(bytes: a3e4)
    let ev2 = adapter.feed(bytes: a3e5)
    #expect(sensed(ev1).count == 2)
    #expect(sensed(ev2).count == 2)
}

// MARK: - F4: Piece touched / released (BOARD→HOST, opcodes 0xB8, 0xBB)
// [PRIMARY] chessupdriver PieceTouchedMessage / PieceReleasedMessage;
// [FACTS-ONLY] bluecheese RESP_TOUCH=0xB8.
// B8 = capacitive touch, B8 = [B8, squareIdx=0x0C (e2), pieceCode=0x00 (P)].
// BB = all touches released, 1 byte.
// These are touch events, not occupancy events; forwarded as raw.

@Test func f4PieceTouchedForwardsAsRaw() throws {
    // e2 (squareIdx=0x0C), white pawn (pieceCode=0x00)
    let b8 = Data([0xB8, 0x0C, 0x00])
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: b8)
    #expect(events.count == 1)
    guard case .raw(let d) = events[0] else {
        Issue.record("Expected .raw for B8 touch event"); return
    }
    #expect(d == b8)
}

@Test func f4PieceReleasedForwardsAsRaw() throws {
    let bb = Data([0xBB])
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: bb)
    #expect(events.count == 1)
    guard case .raw(let d) = events[0] else {
        Issue.record("Expected .raw for BB release event"); return
    }
    #expect(d == bb)
}

// MARK: - F5: Occupancy bitmap — startpos with e2 pawn lifted (BOARD→HOST, 0xFD 0xFD)
// [PRIMARY] RawBoardStateMessage; enable stream first with H→B 0x50.
// Rank-REVERSED: frame[2]=rank8, frame[9]=rank1; LSB=a-file.
// Encode is also tested (H→B direction for testing and tooling).

@Test func f5OccupancyBitmapDecode() throws {
    // FD FD FF FF 00 00 00 00 EF FF
    // rank8=0xFF (all black pieces), rank7=0xFF, ranks3-6=0x00,
    // rank2=0xEF (0b11101111, e-file bit4=0 → e2 empty), rank1=0xFF.
    let frame = Data([0xFD, 0xFD, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xEF, 0xFF])
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: frame)
    let occ = try #require(firstOccupancy(from: events))
    #expect(occ.count == 64)
    // e2 must be unoccupied (pawn lifted)
    #expect(!isOccupied("e2", in: occ))
    // All other rank-1 and rank-2 squares must be occupied
    for file in ["a","b","c","d","f","g","h"] {
        #expect(isOccupied("\(file)1", in: occ), "Expected \(file)1 occupied")
        #expect(isOccupied("\(file)2", in: occ), "Expected \(file)2 occupied")
    }
    #expect(isOccupied("e1", in: occ))
    // rank-3 through rank-6: empty
    for rank in 3...6 {
        for file in ["a","b","c","d","e","f","g","h"] {
            #expect(!isOccupied("\(file)\(rank)", in: occ), "Expected \(file)\(rank) empty")
        }
    }
    // Black pieces (ranks 7-8): all occupied
    for rank in 7...8 {
        for file in ["a","b","c","d","e","f","g","h"] {
            #expect(isOccupied("\(file)\(rank)", in: occ), "Expected \(file)\(rank) occupied")
        }
    }
    // 31 occupied squares (32 startpos − 1 lifted)
    #expect(occ.filter { $0 }.count == 31)
}

@Test func f5OccupancyBitmapRoundTrip() {
    // Encode startpos-minus-e2 and verify it matches the spec F5 bytes exactly.
    var occ = [Bool](repeating: false, count: 64)
    for file in 0..<8 {
        occ[file * 8 + 0] = true   // rank 1 (0-indexed = 0)
        occ[file * 8 + 6] = true   // rank 7
        occ[file * 8 + 7] = true   // rank 8
    }
    for file in 0..<8 where file != 4 {
        occ[file * 8 + 1] = true   // rank 2, all except e (file=4)
    }
    // e2 (file=4, rank0=1) stays false — pawn in hand.
    let f5 = Data([0xFD, 0xFD, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xEF, 0xFF])
    #expect(ChessUpAdapter.encodeOccupancyFrame(occupied: occ) == f5)
}

@Test func f5StartposOccupancy() {
    // Full startpos: 32 squares occupied.
    var occ = [Bool](repeating: false, count: 64)
    for file in 0..<8 {
        occ[file * 8 + 0] = true   // rank 1
        occ[file * 8 + 1] = true   // rank 2
        occ[file * 8 + 6] = true   // rank 7
        occ[file * 8 + 7] = true   // rank 8
    }
    let frame = ChessUpAdapter.encodeOccupancyFrame(occupied: occ)
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: frame)
    guard case .occupancySnapshot(let snap) = events.first else {
        Issue.record("Expected occupancySnapshot"); return
    }
    #expect(snap.filter { $0 }.count == 32)
}

// MARK: - F6: Full board state after 1.e4 e5 (BOARD→HOST, opcode 0x67)
// [PRIMARY+FACTS-ONLY] Both sources confirm 73-byte layout.
// Offsets 1-64: piece codes a1-first (canonical order). 0x40 = empty.
// ep byte (offset 70) = 0x2C = 44 → e6 per bluecheese decode (D3).

@Test func f6BoardStateDecode() throws {
    // Golden fixture F6 from pinned spec (73 bytes).
    let f6: [UInt8] = [
        0x67,
        // Rank 1: a1..h1 (white pieces)
        0x01, 0x02, 0x03, 0x04, 0x05, 0x03, 0x02, 0x01,
        // Rank 2: a2..h2 (white pawns, e2 empty)
        0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
        // Rank 3: empty
        0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
        // Rank 4: a4..h4 (e4 has white pawn)
        0x40, 0x40, 0x40, 0x40, 0x00, 0x40, 0x40, 0x40,
        // Rank 5: a5..h5 (e5 has black pawn)
        0x40, 0x40, 0x40, 0x40, 0x08, 0x40, 0x40, 0x40,
        // Rank 6: empty
        0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
        // Rank 7: a7..h7 (black pawns, e7 empty)
        0x08, 0x08, 0x08, 0x08, 0x40, 0x08, 0x08, 0x08,
        // Rank 8: a8..h8 (black pieces)
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0B, 0x0A, 0x09,
        // Tail: turn=white(0), castling KQkq=0101 0101, ep=0x2C(e6), half=0, full=2
        0x00, 0x01, 0x01, 0x01, 0x01, 0x2C, 0x00, 0x02,
    ]
    #expect(f6.count == 73)
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: Data(f6))
    let occ = try #require(firstOccupancy(from: events))
    #expect(occ.count == 64)
    // e2 empty (white pawn advanced)
    #expect(!isOccupied("e2", in: occ))
    // e4 occupied (white pawn)
    #expect(isOccupied("e4", in: occ))
    // e7 empty (black pawn advanced)
    #expect(!isOccupied("e7", in: occ))
    // e5 occupied (black pawn)
    #expect(isOccupied("e5", in: occ))
    // Other startpos squares remain
    #expect(isOccupied("a1", in: occ))
    #expect(isOccupied("h8", in: occ))
    #expect(isOccupied("a7", in: occ))
    #expect(!isOccupied("e6", in: occ))  // ep target square — empty
    // 32 occupied squares — pieces MOVED, not removed; count unchanged from startpos.
    // e2→e4 and e7→e5: two squares emptied, two new squares filled.
    #expect(occ.filter { $0 }.count == 32)
}

@Test func f6BoardStateRequires73Bytes() {
    // [DISCREPANCY D1] Primary declared length 72 (off-by-one bug); we follow 73.
    // Verify that 72 bytes buffer silently and the 73rd byte completes the frame.
    var frame73 = [UInt8](repeating: 0x40, count: 73)
    frame73[0] = 0x67
    var adapter = ChessUpAdapter()
    // 72 bytes → must buffer without producing events.
    let events72 = adapter.feed(bytes: Data(frame73.prefix(72)))
    #expect(events72.isEmpty, "72 bytes of 0x67 must buffer silently (requires 73)")
    // 73rd byte → completes the frame, produces occupancySnapshot.
    let events73 = adapter.feed(bytes: Data([frame73[72]]))
    #expect(firstOccupancy(from: events73) != nil,
            "73rd byte must complete the 0x67 frame and emit occupancySnapshot")
}

// MARK: - F7: Load FEN (HOST→BOARD, opcode 0x66)
// [PRIMARY] chessupdriver LoadFenMessage — PRIMARY framing.
// [DISCREPANCY D4] bluecheese uses different tail; see spec.
// Format: [66] + ASCII("/" + fen4 + " ") + [halfmove, fullmove]

@Test func f7LoadFENStartpos() throws {
    let startposFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    // Spec fixture F7 (57 bytes).
    let expected = Data([
        0x66,
        0x2F, 0x72, 0x6E, 0x62, 0x71, 0x6B, 0x62, 0x6E, 0x72, // /rnbqkbnr
        0x2F, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, // /pppppppp
        0x2F, 0x38,                                             // /8
        0x2F, 0x38,                                             // /8
        0x2F, 0x38,                                             // /8
        0x2F, 0x38,                                             // /8
        0x2F, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, // /PPPPPPPP
        0x2F, 0x52, 0x4E, 0x42, 0x51, 0x4B, 0x42, 0x4E, 0x52, // /RNBQKBNR
        0x20, 0x77,                                             // ' w'
        0x20, 0x4B, 0x51, 0x6B, 0x71,                          // ' KQkq'
        0x20, 0x2D,                                             // ' -'
        0x20,                                                   // ' ' (trailing)
        0x00, 0x01,                                             // halfmove=0, fullmove=1
    ])
    #expect(expected.count == 57)
    let result = try #require(ChessUpAdapter.loadFENData(fen: startposFEN))
    #expect(result == expected)
}

@Test func f7LoadFENAfterE4E5() throws {
    // 1.e4 e5: halfmove=0, fullmove=2, ep target e6, castling KQkq.
    let fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"
    let result = try #require(ChessUpAdapter.loadFENData(fen: fen))
    // Verify opcode, trailing space, and binary tail.
    #expect(result[0] == 0x66)                 // opcode
    #expect(result[1] == 0x2F)                 // leading '/'
    let last2 = Array(result.suffix(2))
    #expect(last2 == [0x00, 0x02])             // halfmove=0, fullmove=2
    // The byte before the binary tail must be 0x20 (trailing space).
    #expect(result[result.count - 3] == 0x20)
}

@Test func f7LoadFENRejectsMissingFields() {
    // Fewer than 6 FEN fields → nil.
    #expect(ChessUpAdapter.loadFENData(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -") == nil)
}

// MARK: - F8: Game settings for phone-assisted OTB (HOST→BOARD, opcode 0xB9)
// [PRIMARY] GameSettings.toBytes() + newOTBGame() example; [FACTS-ONLY] bluecheese.
// [DISCREPANCY D6] deviceUser always sent. [PRIMARY] always sends it.

@Test func f8GameSettingsEncode() {
    // Spec fixture F8: B9 05 00 02 00 00 02 01 00 00 01 00
    let expected = Data([0xB9, 0x05, 0x00, 0x02, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00, 0x01, 0x00])
    let result = ChessUpAdapter.gameSettingsData(
        mode: 5,          // phoneOTB (GameType+1)
        whiteType: 0,     // human
        whiteLevel: 2,    // assistance level 2
        whiteLock: 0,     // button-lock off
        blackType: 0,     // human
        blackLevel: 2,    // assistance level 2
        blackLock: 1,     // button-lock on
        hintLimit: 0,
        whiteRemote: 0,   // white uses physical board
        blackRemote: 1,   // black's moves arrive via 0x99
        deviceUser: 0     // white holds the phone
    )
    #expect(result == expected)
}

@Test func f8GameSettingsLength() {
    // Frame must always be exactly 12 bytes.
    let data = ChessUpAdapter.gameSettingsData(
        mode: 1, whiteType: 0, whiteLevel: 1, whiteLock: 0,
        blackType: 0, blackLevel: 1, blackLock: 0,
        hintLimit: 0xFF, whiteRemote: 0, blackRemote: 0, deviceUser: 0
    )
    #expect(data.count == 12)
    #expect(data[0] == 0xB9)
}

// MARK: - F9: Promotion handshakes (BOARD↔HOST, opcode 0x97/0x23)
// [PRIMARY] PawnPromotionMessage; [FACTS-ONLY] bluecheese requestPromotion.
// Piece scale: 1=R, 2=N, 3=B, 4=Q.
// [DISCREPANCY D2] Board promotion via 0x97 (not 0xA3-based dead code in primary).

@Test func f9HostPromotionToQueenEncode() {
    // Host promotes to queen: [97, 04].
    let expected = Data([0x97, 0x04])
    #expect(ChessUpAdapter.promotionData(piece: 4) == expected)
}

@Test func f9HostPromotionToKnightEncode() {
    // Host promotes to knight: [97, 02].
    #expect(ChessUpAdapter.promotionData(piece: 2) == Data([0x97, 0x02]))
}

@Test func f9BoardSidePromotionDecode() throws {
    // Board-side player picks knight: B→H [97, 02]. Host MUST ack [23].
    // Forwarded as raw (session handles promotion UI).
    let frame = Data([0x97, 0x02])
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: frame)
    #expect(events.count == 1)
    guard case .raw(let d) = events[0] else {
        Issue.record("Board-side promotion [97] should forward as .raw"); return
    }
    #expect(d == frame)
}

@Test func f9PromotionAckEncode() {
    // Ack for promotion (both host ack→board and board ack→host) is 0x23.
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.custom(Data([0x23]))) == Data([0x23]))
}

@Test func f9AckBoardPromotionData() {
    // ackBoardPromotionData() is the API the transport calls after receiving a
    // board-side 0x97 promotion frame. Must be Data([0x23]).
    let ack = ChessUpAdapter.ackBoardPromotionData()
    #expect(ack == Data([0x23]))
    // Also reachable via .custom (for transports that route through encode).
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.custom(ack)) == Data([0x23]))
}

// MARK: - Malformed-frame rejection

@Test func malformedFrameTooShortUnknownOpcode() {
    // A lone unknown byte must be skipped (resync), not crash.
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: Data([0xFF]))
    // Unknown byte is skipped; nothing emitted.
    #expect(events.isEmpty)
}

@Test func malformedA3TooShortBuffers() {
    // An A3 frame truncated to 3 bytes: must buffer without emitting.
    let partial = Data([0xA3, 0x35, 0x06])
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: partial)
    #expect(events.isEmpty, "Partial A3 frame must buffer silently")
}

@Test func malformedFDSingleByteSkipped() {
    // A single 0xFD byte (no second byte) must buffer and wait.
    // When followed by a non-0xFD byte, the 0xFD is skipped (resync).
    var adapter = ChessUpAdapter()
    let e1 = adapter.feed(bytes: Data([0xFD]))
    #expect(e1.isEmpty, "Single 0xFD must buffer (waiting for second byte)")
    // Feed 0x01 (not 0xFD) after the 0xFD — adapter should skip 0xFD.
    let e2 = adapter.feed(bytes: Data([0x01]))
    // 0xFD 0x01 is not a FD FD frame; 0xFD is skipped, 0x01 is unknown → also skipped.
    #expect(e2.isEmpty)
}

@Test func malformedFDFDFrameTooShort() {
    // FD FD with only 3 bytes total: must buffer, no events.
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: Data([0xFD, 0xFD, 0xFF]))
    #expect(events.isEmpty, "Incomplete FD FD frame must buffer silently")
}

@Test func malformedUnknownBytesSkippedBeforeValidFrame() throws {
    // A run of unknown bytes before a valid A3 frame.
    var adapter = ChessUpAdapter()
    let junk    = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let a3valid = Data([0xA3, 0x35, 0x06, 0x07, 0x05, 0x05])
    var events = adapter.feed(bytes: junk)
    events += adapter.feed(bytes: a3valid)
    // Junk bytes skipped; valid A3 decoded.
    let s = sensed(events)
    #expect(s.count == 2)
    #expect(s[0].square == "g8")
    #expect(s[1].square == "f6")
}

// MARK: - Ready emission

@Test func readyEmittedOnFirstBoardStateFrame() throws {
    // First 0x67 frame → occupancySnapshot + .ready (in that order).
    var frame67 = [UInt8](repeating: 0x40, count: 73)
    frame67[0] = 0x67
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: Data(frame67))
    guard case .occupancySnapshot = events.first else {
        Issue.record("First event on 0x67 must be .occupancySnapshot"); return
    }
    let readyCount = events.filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "Expected exactly one .ready on first 0x67 frame")
}

@Test func readyNotReemittedOnSubsequentFrames() {
    // Second 0x67 frame must NOT re-emit .ready.
    var frame67 = [UInt8](repeating: 0x40, count: 73)
    frame67[0] = 0x67
    var adapter = ChessUpAdapter()
    _ = adapter.feed(bytes: Data(frame67))          // primes isFirstStateFrame
    let second = adapter.feed(bytes: Data(frame67)) // identical; must not re-emit
    let readyCount = second.filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 0, "Second 0x67 frame must not emit .ready")
}

@Test func readyReArmedByResetFraming() throws {
    // resetFraming() clears isFirstStateFrame → .ready fires again on next 0x67.
    var frame67 = [UInt8](repeating: 0x40, count: 73)
    frame67[0] = 0x67
    var adapter = ChessUpAdapter()
    _ = adapter.feed(bytes: Data(frame67))
    adapter.resetFraming()
    let events = adapter.feed(bytes: Data(frame67))
    let readyCount = events.filter { if case .ready = $0 { return true }; return false }.count
    #expect(readyCount == 1, "resetFraming() must re-arm .ready for the next 0x67")
}

// MARK: - Partial frame accumulation

@Test func partialFrameAccumulatesAcrossFeeds() throws {
    // Split an A3 frame across two feeds; events emitted only on second.
    let a3 = Data([0xA3, 0x35, 0x06, 0x07, 0x05, 0x05])
    var adapter = ChessUpAdapter()
    let first  = adapter.feed(bytes: a3.prefix(3))
    #expect(first.isEmpty, "Partial A3 must buffer silently")
    let second = adapter.feed(bytes: a3.dropFirst(3))
    #expect(sensed(second).count == 2, "Complete A3 must emit events after second feed")
}

@Test func partialFDFrameAccumulatesAcrossFeeds() throws {
    // Split an FD FD occupancy frame across two feeds.
    let full = Data([0xFD, 0xFD, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
    var adapter = ChessUpAdapter()
    let first  = adapter.feed(bytes: full.prefix(5))
    #expect(first.isEmpty, "Partial FD FD must buffer silently")
    let second = adapter.feed(bytes: full.dropFirst(5))
    #expect(firstOccupancy(from: second) != nil, "Complete FD FD must emit occupancySnapshot")
}

// MARK: - Handshake commands

@Test func handshakeFirstConnectIsGetState() {
    let adapter = ChessUpAdapter()
    let cmds = adapter.handshakeCommands(isReconnect: false)
    #expect(cmds.count == 1)
    #expect(adapter.encode(cmds[0].command) == Data([0x67]))
    #expect(cmds[0].delayBefore == .zero)
}

@Test func handshakeReconnectHasDelay() {
    let adapter = ChessUpAdapter()
    let cmds = adapter.handshakeCommands(isReconnect: true)
    #expect(cmds.count == 1)
    #expect(adapter.encode(cmds[0].command) == Data([0x67]))
    #expect(cmds[0].delayBefore == 0.25)
}

// MARK: - GATT / capabilities

@Test func gattNameMatching() {
    // Prefix match: any name starting with "ChessUp" is a match.
    #expect(ChessUpGATT.isChessUp(name: "ChessUp"))
    #expect(ChessUpGATT.isChessUp(name: "ChessUp "))
    #expect(ChessUpGATT.isChessUp(name: "ChessUp 1.0"))
    #expect(!ChessUpGATT.isChessUp(name: "Chess"))
    #expect(!ChessUpGATT.isChessUp(name: "Chessnut Air"))
    #expect(!ChessUpGATT.isChessUp(name: ""))
}

@Test func capabilitiesChessUp() {
    let caps = BoardCapabilities.chessUp
    #expect(caps.contains(.occupancySensing))
    #expect(caps.contains(.moveIndication))
    // .perSquareLEDs is NOT declared: 0x99 only accepts exactly 2 squares,
    // the empty-array clear-LEDs call is unsupported, and 0x99 is a
    // remote-move injection command rather than a pure LED command.
    // A caller checking .perSquareLEDs before sending a 3-square highlight
    // or a clear-LEDs call must not reach the ChessUp path.
    #expect(!caps.contains(.perSquareLEDs))
    // Not declared:
    #expect(!caps.contains(.pieceIdentity))
    #expect(!caps.contains(.batteryReporting))
    #expect(!caps.contains(.motorised))
    #expect(!caps.contains(.perPieceTracking))
}

@Test func adapterCapabilitiesMatchPreset() {
    let adapter = ChessUpAdapter()
    #expect(adapter.capabilities == .chessUp)
}

// MARK: - Square index math

@Test func squareToCanonicalIdxSentinels() {
    // a1: rank0=0, file=0 → idx=0
    #expect(ChessUpAdapter.squareToCanonicalIdx("a1") == 0)
    // e2: rank0=1, file=4 → idx=12=0x0C (spec fixture F2, F4)
    #expect(ChessUpAdapter.squareToCanonicalIdx("e2") == 0x0C)
    // e4: rank0=3, file=4 → idx=28=0x1C (spec fixture F2)
    #expect(ChessUpAdapter.squareToCanonicalIdx("e4") == 0x1C)
    // h8: rank0=7, file=7 → idx=63=0x3F
    #expect(ChessUpAdapter.squareToCanonicalIdx("h8") == 0x3F)
    // g8: rank0=7, file=6 → idx=62=0x3E (spec fixture F3 check)
    #expect(ChessUpAdapter.squareToCanonicalIdx("g8") == 62)
    // Invalid: nil
    #expect(ChessUpAdapter.squareToCanonicalIdx("z9") == nil)
}

@Test func colRowToAlgebraicSentinels() {
    // g8: col=6, row=7 (0-indexed rank8) → "g8" (spec fixture F3)
    #expect(ChessUpAdapter.colRowToAlgebraic(col: 6, row: 7) == "g8")
    // f6: col=5, row=5 → "f6" (spec fixture F3)
    #expect(ChessUpAdapter.colRowToAlgebraic(col: 5, row: 5) == "f6")
    // a1: col=0, row=0 → "a1"
    #expect(ChessUpAdapter.colRowToAlgebraic(col: 0, row: 0) == "a1")
    // h8: col=7, row=7 → "h8"
    #expect(ChessUpAdapter.colRowToAlgebraic(col: 7, row: 7) == "h8")
}

// MARK: - SimulatedBoard round-trip (occupancy-delta game)

@Test func occupancyDeltaGameThroughSimulatedBoard() async throws {
    // Play a short game via SimulatedBoard (occupancy-only) and verify:
    // (a) squareSensed events have nil piece (no .pieceIdentity capability)
    // (b) from/to squares are correct
    // Then round-trip the resulting position through ChessUpAdapter via FD FD frame.
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    // 1. e2e4
    let e4ev = try await sim.executeMove(uci: "e2e4")
    let e4s = sensed(e4ev)
    #expect(e4s.count == 2)
    #expect(e4s[0] == ("e2", true,  nil))
    #expect(e4s[1] == ("e4", false, nil))

    // 2. e7e5
    let e5ev = try await sim.executeMove(uci: "e7e5")
    let e5s = sensed(e5ev)
    #expect(e5s.count == 2)
    #expect(e5s[0] == ("e7", true,  nil))
    #expect(e5s[1] == ("e5", false, nil))

    // Round-trip the resulting position through ChessUpAdapter via FD FD frame.
    let pos = await sim.position
    let occ = fileMajorOccupancy(from: pos)
    let frame = ChessUpAdapter.encodeOccupancyFrame(occupied: occ)
    var adapter = ChessUpAdapter()
    let snapEvents = adapter.feed(bytes: frame)
    let snap = try #require(firstOccupancy(from: snapEvents))
    // Verify key squares
    #expect(!isOccupied("e2", in: snap))   // e2 now empty
    #expect(isOccupied("e4",  in: snap))   // white pawn on e4
    #expect(!isOccupied("e7", in: snap))   // e7 now empty
    #expect(isOccupied("e5",  in: snap))   // black pawn on e5
}

@Test func occupancyDeltaGameWithCapture() async throws {
    // Play e4, e5, Nf3, Nc6, Nxe5 (knight captures pawn) via SimulatedBoard.
    let sim = SimulatedBoard(capabilities: [.occupancySensing])
    _ = try await sim.executeMove(uci: "e2e4")
    _ = try await sim.executeMove(uci: "e7e5")
    _ = try await sim.executeMove(uci: "g1f3")
    _ = try await sim.executeMove(uci: "b8c6")
    // Knight captures on e5
    let capEv = try await sim.executeMove(uci: "f3e5")
    let capS  = sensed(capEv)
    // Normal capture: attacker lifts, captured piece lifts, attacker places.
    #expect(capS.count == 3)
    #expect(capS[0] == ("f3", true,  nil))  // knight lifts
    #expect(capS[1] == ("e5", true,  nil))  // captured pawn lifts
    #expect(capS[2] == ("e5", false, nil))  // knight places

    // Round-trip post-capture position through ChessUpAdapter.
    let pos = await sim.position
    let occ = fileMajorOccupancy(from: pos)
    let frame = ChessUpAdapter.encodeOccupancyFrame(occupied: occ)
    var adapter = ChessUpAdapter()
    let snap = try #require(firstOccupancy(from: adapter.feed(bytes: frame)))
    #expect(!isOccupied("f3", in: snap))   // knight moved
    #expect(isOccupied("e5",  in: snap))   // knight on e5
    #expect(!isOccupied("e7", in: snap))   // black pawn moved
}

@Test func shortGameViaA3Events() {
    // Play a 3-move game by feeding A3 frames and verify squareSensed events.
    // A3 frame: [A3, sub, fromCol, fromRow, toCol, toRow] (col/row 0-indexed).
    var adapter = ChessUpAdapter()

    // Prime with a 0x67 frame so .ready fires.
    var frame67 = [UInt8](repeating: 0x40, count: 73)
    frame67[0] = 0x67
    _ = adapter.feed(bytes: Data(frame67))

    // e2→e4: col=4(e), fromRow=1(rank2), toRow=3(rank4)
    let a3e4 = Data([0xA3, 0x35, 0x04, 0x01, 0x04, 0x03])
    let evE4  = sensed(adapter.feed(bytes: a3e4))
    #expect(evE4.count == 2)
    #expect(evE4[0] == ("e2", true,  nil))
    #expect(evE4[1] == ("e4", false, nil))

    // e7→e5: col=4(e), fromRow=6(rank7), toRow=4(rank5)
    let a3e5 = Data([0xA3, 0x35, 0x04, 0x06, 0x04, 0x04])
    let evE5  = sensed(adapter.feed(bytes: a3e5))
    #expect(evE5.count == 2)
    #expect(evE5[0] == ("e7", true,  nil))
    #expect(evE5[1] == ("e5", false, nil))

    // g1→f3: knight. col=6(g), fromRow=0(rank1), toCol=5(f), toRow=2(rank3)
    let a3nf3 = Data([0xA3, 0x35, 0x06, 0x00, 0x05, 0x02])
    let evNf3  = sensed(adapter.feed(bytes: a3nf3))
    #expect(evNf3.count == 2)
    #expect(evNf3[0] == ("g1", true,  nil))
    #expect(evNf3[1] == ("f3", false, nil))
}

// MARK: - In-band state-reset clears A3 dedup (Finding 2)
//
// After a board-side undo (0xBD), FEN reload (0xB1), or board-state snapshot
// (0x67) the player can legitimately replay the identical move. The dedup guard
// must be cleared by those events so the next identical 0xA3 is not suppressed.

@Test func bdUndoThenIdenticalA3EmitsEvents() {
    // Simulate: move g8→f6, board acks, player undoes via 0xBD, replays g8→f6.
    let a3 = Data([0xA3, 0x35, 0x06, 0x07, 0x05, 0x05])  // g8→f6
    let bd = Data([0xBD])                                  // board-side undo
    var adapter = ChessUpAdapter()

    let first = adapter.feed(bytes: a3)                    // move registered
    #expect(sensed(first).count == 2, "First A3 must emit events")

    let deduped = adapter.feed(bytes: a3)                  // retransmit → suppressed
    #expect(deduped.isEmpty, "Identical A3 retransmit must be deduped")

    _ = adapter.feed(bytes: bd)                            // undo: clears dedup guard

    let replayed = adapter.feed(bytes: a3)                 // same move again after undo
    let s = sensed(replayed)
    #expect(s.count == 2, "After 0xBD undo, identical A3 must emit events (not deduped)")
    #expect(s[0] == ("g8", true,  nil))
    #expect(s[1] == ("f6", false, nil))
}

@Test func b1FenLoadThenIdenticalA3EmitsEvents() {
    // Simulate: move e2→e4, FEN reload (0xB1 complete), replay e2→e4.
    let a3 = Data([0xA3, 0x35, 0x04, 0x01, 0x04, 0x03])  // e2→e4 in col/row
    let b1 = Data([0xB1])                                  // FEN load complete
    var adapter = ChessUpAdapter()

    let first = adapter.feed(bytes: a3)
    #expect(sensed(first).count == 2, "First A3 must emit events")

    let deduped = adapter.feed(bytes: a3)
    #expect(deduped.isEmpty, "Identical A3 retransmit must be deduped")

    _ = adapter.feed(bytes: b1)                            // FEN reload: clears dedup guard

    let replayed = adapter.feed(bytes: a3)
    let s = sensed(replayed)
    #expect(s.count == 2, "After 0xB1 FEN-load, identical A3 must emit events (not deduped)")
    #expect(s[0] == ("e2", true,  nil))
    #expect(s[1] == ("e4", false, nil))
}

@Test func boardStateThenIdenticalA3EmitsEvents() {
    // A 0x67 snapshot (e.g. mid-session resync) must also clear the dedup guard.
    let a3 = Data([0xA3, 0x35, 0x04, 0x01, 0x04, 0x03])  // e2→e4
    var frame67 = [UInt8](repeating: 0x40, count: 73)
    frame67[0] = 0x67
    var adapter = ChessUpAdapter()

    let first = adapter.feed(bytes: a3)
    #expect(sensed(first).count == 2)

    _ = adapter.feed(bytes: a3)                            // deduped

    _ = adapter.feed(bytes: Data(frame67))                 // 0x67 snapshot: clears dedup

    let replayed = adapter.feed(bytes: a3)
    #expect(sensed(replayed).count == 2,
            "After 0x67 board-state snapshot, identical A3 must emit events (not deduped)")
}

// MARK: - resetFraming clears A3 dedup

@Test func resetFramingClearsA3DeduplicationGuard() {
    let a3 = Data([0xA3, 0x35, 0x06, 0x07, 0x05, 0x05])
    var adapter = ChessUpAdapter()
    _ = adapter.feed(bytes: a3)         // first: events emitted, dedup set
    let second = adapter.feed(bytes: a3) // second: deduped
    #expect(second.isEmpty)
    adapter.resetFraming()
    let afterReset = adapter.feed(bytes: a3)  // after reset: dedup cleared → events again
    #expect(sensed(afterReset).count == 2, "A3 dedup must be cleared by resetFraming()")
}

// MARK: - Misc acks and commands

@Test func startSessionAndRequestStateEncode() {
    let adapter = ChessUpAdapter()
    #expect(adapter.encode(.startSession) == Data([0x67]))
    #expect(adapter.encode(.requestState) == Data([0x67]))
}

@Test func enableRawStreamData() {
    #expect(ChessUpAdapter.enableRawStreamData == Data([0x50]))
}

@Test func resetGameData() {
    #expect(ChessUpAdapter.resetGameData == Data([0x64]))
}

@Test func resultDataEncode() {
    #expect(ChessUpAdapter.resultData(winnerColour: 0) == Data([0xB6, 0x00]))
    #expect(ChessUpAdapter.resultData(winnerColour: 1) == Data([0xB6, 0x01]))
}

@Test func gameEndDataEncode() {
    // Stalemate = reason 11.
    #expect(ChessUpAdapter.gameEndData(reason: 11) == Data([0x52, 0x0B]))
}

@Test func batteryChargingFrameForwardsAsRaw() throws {
    // 0x33 carries only a charging flag, not a percentage; forwarded as raw.
    let frame = Data([0x33, 0x01])   // charging = true
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: frame)
    guard case .raw(let d) = events.first else {
        Issue.record("0x33 frame should forward as .raw"); return
    }
    #expect(d == frame)
}

@Test func boardInfoFrameForwardsAsRaw() throws {
    // 0xB2 board-info (16-char ASCII model string): forward as raw for CU2 diagnosis.
    var b2 = [UInt8](repeating: 0x20, count: 17)  // 1 + 16 spaces
    b2[0] = 0xB2
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: Data(b2))
    guard case .raw = events.first else {
        Issue.record("0xB2 board-info should forward as .raw"); return
    }
}

@Test func fenLoadCompleteForwardsAsRaw() throws {
    let b1 = Data([0xB1])
    var adapter = ChessUpAdapter()
    let events = adapter.feed(bytes: b1)
    guard case .raw(let d) = events.first else {
        Issue.record("0xB1 FEN-load-complete should forward as .raw"); return
    }
    #expect(d == b1)
}
