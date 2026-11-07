import Foundation
import ChessCore
import BoardKit

// ── Shared internal helpers — ChessnutAdapter module ─────────────────────────
//
// Extracted here so ChessnutAdapter (classic profile) and ChessnutMoveAdapter
// (Move profile) share one copy of the bit-math and piece tables.  Kit-first
// rule: extract on second use, never copy-paste (drift risk proven by the
// probeCP mate-sentinel divergence).
//
// Access level: internal (default).  All symbols are module-private — not
// exported through the ChessnutAdapter library product.
//
// Sources informing this file (all MIT-licensed):
//   [SWIFT-REF] github.com/NSStudent/EasyLinkSwiftSDK
//               @ 1b9710593b192ae102f8a1fd695467c9eb990535 (MIT, © 2026 Omar)
//   [C-REF]     github.com/chessnutech/EasyLinkSDK
//               @ 4554d17be976f746b8b1139a3b9a025e2b54c8ba (MIT, © 2022 chessnutech)
//   [OFFICIAL-DOC] github.com/chessnutech/Chessnut_eBoards README (facts only)

// MARK: - FEN/board-state piece-code table
//
// Maps a 4-bit nibble → Piece for board frames (§4), auto-move target (§6),
// and LED data (§7 — colour nibbles use the same square packing but different
// nibble meanings).
//
// [DISCREPANCY D6]: This table is NOT the piece-identity table used in §8
// per-piece-tracking frames.  Do NOT reuse it for piece-status decoding.
//
// Layout is intentionally asymmetric (white rook = 6, black rook = 8):
//   [C-REF] CHESS_PIECES[]; [SWIFT-REF] pieceByCode; [OFFICIAL-DOC] §piece
//   All three sources are byte-for-byte identical.

let chessnutFENPieceByCode: [UInt8: Piece] = [
    0x1: Piece(type: .queen,  color: .black),
    0x2: Piece(type: .king,   color: .black),
    0x3: Piece(type: .bishop, color: .black),
    0x4: Piece(type: .pawn,   color: .black),
    0x5: Piece(type: .knight, color: .black),
    0x6: Piece(type: .rook,   color: .white),  // white rook at 6, NOT 8
    0x7: Piece(type: .pawn,   color: .white),
    0x8: Piece(type: .rook,   color: .black),  // black rook at 8, NOT 6
    0x9: Piece(type: .bishop, color: .white),
    0xA: Piece(type: .knight, color: .white),
    0xB: Piece(type: .queen,  color: .white),
    0xC: Piece(type: .king,   color: .white),
    // 0x0 = empty; 0xD–0xF = invalid (caller must flag and skip)
]

/// Reverse lookup: Piece? → 4-bit nibble code for board/auto-move/LED encoding.
func chessnutFENCodeForPiece(_ piece: Piece?) -> UInt8 {
    guard let piece else { return 0x0 }
    switch (piece.type, piece.color) {
    case (.queen,  .black): return 0x1
    case (.king,   .black): return 0x2
    case (.bishop, .black): return 0x3
    case (.pawn,   .black): return 0x4
    case (.knight, .black): return 0x5
    case (.rook,   .white): return 0x6
    case (.pawn,   .white): return 0x7
    case (.rook,   .black): return 0x8
    case (.bishop, .white): return 0x9
    case (.knight, .white): return 0xA
    case (.queen,  .white): return 0xB
    case (.king,   .white): return 0xC
    }
}

// MARK: - Square index conversion
//
// Protocol scan order: h8, g8 … a8, h7 … a1  (h8-first, not a1-first).
// Two squares per byte; FIRST square of the pair in the LOW nibble.
//
// Protocol square index s (0=h8 … 63=a1):
//   s = (8 − rank) × 8 + (7 − file)   (rank 1-indexed, file a=0…h=7)
//
// Inverse (file, rank both 0-indexed):
//   file = 7 − (s % 8)
//   rank = 7 − (s / 8)
//
// File-major index (BoardEvent convention, a1=0…h8=63):
//   fileMajor = file × 8 + rank

/// Convert Chessnut protocol square index `s` (0=h8 … 63=a1) to file-major
/// index (a1=0 … h8=63).  Used for board frames, auto-move, and LED data —
/// the square encoding is identical across all three.
///
/// Sentinels from spec:
///   s=0  → h8 → fileMajor=63
///   s=63 → a1 → fileMajor=0
///   s=35 → e4 → fileMajor=35
func chessnutProtocolSquareToFileMajor(_ s: Int) -> Int {
    let file = 7 - (s % 8)
    let rank = 7 - (s / 8)   // 0-indexed
    return file * 8 + rank
}

// MARK: - Board-byte codec (32 bytes ↔ 64-element file-major identity)
//
// Used by both classic (36-byte frame, header 01 22) and Move (38-byte frame,
// header 01 24) adapters.  The 32 board bytes themselves are identical; only
// the header and tail differ between profiles.

/// Decode 32 packed board bytes (starting at `start` in `bytes`) into a
/// 64-element file-major piece-identity array.
///
/// Returns `(identity, hasInvalidNibble)`.  `hasInvalidNibble` is `true` when
/// a nibble value 0xD–0xF was encountered; callers should flag the frame but
/// still use the decoded data for everything that decoded cleanly.
///
/// Caller precondition: `bytes.count >= start + 32`.
func chessnutDecodeBoard(from bytes: [UInt8], start: Int) -> (identity: [Piece?], hasInvalidNibble: Bool) {
    var identity = [Piece?](repeating: nil, count: 64)
    var hasInvalidNibble = false
    for s in 0..<64 {
        let byteIndex = start + s / 2
        let nibble: UInt8 = s % 2 == 0
            ? bytes[byteIndex] & 0x0F     // protocol-square even → LOW nibble
            : bytes[byteIndex] >> 4       // protocol-square odd  → HIGH nibble
        if nibble > 0xC {
            hasInvalidNibble = true
            continue
        }
        identity[chessnutProtocolSquareToFileMajor(s)] = chessnutFENPieceByCode[nibble]
    }
    return (identity, hasInvalidNibble)
}

/// Encode a 64-element file-major piece-identity array into exactly 32 packed
/// board bytes.  The returned `[UInt8]` is the board payload only — callers
/// prepend the adapter-specific header (01 22 for classic, 01 24 for Move) and
/// append the tail (2 trailing zeros for classic, 4-byte LE timestamp for Move).
///
/// Caller precondition: `identity.count == 64`.
func chessnutEncodeBoard(identity: [Piece?]) -> [UInt8] {
    precondition(identity.count == 64, "chessnutEncodeBoard: identity must be 64 elements")
    var board = [UInt8](repeating: 0, count: 32)
    for s in 0..<64 {
        let code = chessnutFENCodeForPiece(identity[chessnutProtocolSquareToFileMajor(s)])
        let byteIndex = s / 2
        if s % 2 == 0 {
            board[byteIndex] |= code & 0x0F           // LOW nibble
        } else {
            board[byteIndex] |= (code & 0x0F) << 4   // HIGH nibble
        }
    }
    return board
}

// MARK: - Lift/place delta events
//
// Computes squareSensed events between two consecutive identity snapshots.
// Extracted to avoid duplication between classic and Move board-state parsers
// (both use file-major arrays with the same a1=0 convention).

/// Compute `squareSensed` lift/place events by diffing `prev` and `curr`.
///
/// - Parameter prev: Identity snapshot from the previous board frame.
/// - Parameter curr: Identity snapshot from the current board frame.
/// - Returns: The frame's lifts, then its places, each in file-major order
///   (a-file first, rank 1 first within each file). A square where one piece
///   replaced another contributes one of each.
func chessnutDeltaEvents(prev: [Piece?], curr: [Piece?]) -> [BoardEvent] {
    // Every lift in the frame before any place, as a hand moves pieces: a
    // capture that lands inside one frame reads lift, lift, place instead of
    // the mover arriving before it left. (Fianchetto-0yp)
    var lifts: [BoardEvent] = []
    var places: [BoardEvent] = []
    let files = Array("abcdefgh")
    for file in 0..<8 {
        for rank in 0..<8 {
            let idx = file * 8 + rank   // file-major: a1=0…h8=63
            guard prev[idx] != curr[idx] else { continue }
            let square = "\(files[file])\(rank + 1)"
            // An occupied square whose piece changed is both: a capture fast
            // enough that the board never reported the square empty
            // (Kxa1 on a Chessnut Go, 2026-10-29).
            if let lifted = prev[idx] {
                lifts.append(.squareSensed(square: square, isLift: true, piece: lifted))
            }
            if let placed = curr[idx] {
                places.append(.squareSensed(square: square, isLift: false, piece: placed))
            }
        }
    }
    return lifts + places
}

// MARK: - Notification endpoints

/// The Chessnut notify characteristics. Both profiles share every GATT UUID,
/// and each characteristic splits frames at its own boundaries, so its bytes
/// must never share a framing accumulator with another's.
///
/// - `boardState`: `ChessnutGATT.boardStateChar` (`…8262`).
/// - `commandResponse`: `ChessnutGATT.commandResponseChar` (`…8273`); on the
///   Move this carries the `0x41` battery and 139-byte piece-status replies.
/// - `file`: `ChessnutGATT.fileChar` (`…8283`), stored-game frames.
public enum ChessnutNotificationEndpoint: Hashable, Sendable {
    case boardState
    case commandResponse
    case file
}

// MARK: - Frame extraction (both profiles, every notification endpoint)
//
// Wire format: `[opcode, payloadLength, payload…]`, no checksum. [C-REF]
// `real_size = buf[1] + 2`. Trusting `buf[1]` for any opcode let one junk byte
// misalign every later frame until reconnect (Fianchetto-b32.158), so a header
// is accepted only when its opcode is one the boards send and its length is
// one that opcode can have. Anything else drops ONE byte and rescans, the same
// resync rule PegasusAdapter uses. Dropped bytes are handed back so the
// adapter can still surface them as `.raw` for debug logging.

/// One item produced by `chessnutExtractFrames`, in wire order.
enum ChessnutFramedChunk: Equatable {
    /// A complete frame with an accepted header.
    case frame([UInt8])
    /// A run of consecutive bytes that could not start a frame.
    case discarded([UInt8])
}

/// The longest frame either profile accepts: the Move's 139-byte piece-status
/// reply (`41 89 0B` + 34 × 4). Because every accepted header is bounded by
/// this, the framing buffer never holds more than `chessnutMaxFrameLength - 1`
/// bytes between calls.
let chessnutMaxFrameLength = 2 + 0x89

/// Whether `[opcode, payloadLength]` (and, for `0x41`, the sub-opcode once it
/// has arrived) can begin a frame a Chessnut board sends.
///
/// - `0x01` board state: classic `0x22`, Move `0x24`. Both adapters accept any
///   frame of ≥ 34 bytes and the Move tail is unverified, so the length is a
///   range with headroom rather than an exact value; it still rejects a length
///   that would swallow the next frame.
/// - `0x21` / `0x23`: the one-byte mode echo and heartbeat classic boards emit.
/// - `0x27`: BLE/MCU version text, length undocumented; bounded generously.
/// - `0x2A` battery: `2A 02 <level|charging> 00`.
/// - `0x32` file count, `0x37` file flag: one byte each.
/// - `0x41` Move extended reply: battery `41 03 0C`, piece status `41 89 0B`;
///   other sub-opcodes are passed through when the length fits the range.
func chessnutAcceptsHeader(opcode: UInt8, payloadLength: Int, subOpcode: UInt8?) -> Bool {
    switch opcode {
    case 0x01: return (32...40).contains(payloadLength)
    case 0x21, 0x23: return payloadLength == 1
    case 0x27: return (1...32).contains(payloadLength)
    case 0x2A: return payloadLength == 2
    case 0x32, 0x37: return payloadLength == 1
    case 0x41:
        switch subOpcode {
        case 0x0C: return payloadLength == 3
        case 0x0B: return payloadLength == 0x89
        default: return (1...0x89).contains(payloadLength)
        }
    default: return false
    }
}

/// Append `bytes` to `buffer` and cut every complete frame it now holds.
///
/// A header that is valid but still waiting for payload bytes stays buffered;
/// only an unknown opcode or an impossible length is skipped, one byte at a
/// time. Consecutive skipped bytes are coalesced into one `.discarded` chunk.
func chessnutExtractFrames(appending bytes: Data, to buffer: inout [UInt8]) -> [ChessnutFramedChunk] {
    buffer.append(contentsOf: bytes)
    var chunks: [ChessnutFramedChunk] = []
    var skipped: [UInt8] = []
    var start = 0
    while start < buffer.count {
        let opcode = buffer[start]
        guard start + 1 < buffer.count else {
            // A lone byte: wait if it can start a frame, otherwise skip it now.
            if chessnutIsKnownOpcode(opcode) { break }
            skipped.append(opcode); start += 1
            continue
        }
        let payloadLength = Int(buffer[start + 1])
        let subOpcode: UInt8? = start + 2 < buffer.count ? buffer[start + 2] : nil
        guard chessnutAcceptsHeader(opcode: opcode, payloadLength: payloadLength, subOpcode: subOpcode) else {
            skipped.append(opcode); start += 1
            continue
        }
        let frameLength = payloadLength + 2
        guard buffer.count - start >= frameLength else { break }
        if !skipped.isEmpty { chunks.append(.discarded(skipped)); skipped = [] }
        chunks.append(.frame(Array(buffer[start..<(start + frameLength)])))
        start += frameLength
    }
    if !skipped.isEmpty { chunks.append(.discarded(skipped)) }
    buffer.removeFirst(start)
    return chunks
}

private func chessnutIsKnownOpcode(_ opcode: UInt8) -> Bool {
    switch opcode {
    case 0x01, 0x21, 0x23, 0x27, 0x2A, 0x32, 0x37, 0x41: return true
    default: return false
    }
}
