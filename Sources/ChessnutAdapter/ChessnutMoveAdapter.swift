import Foundation
import ChessCore
import BoardKit

// ── Chessnut Move BLE adapter ─────────────────────────────────────────────────
//
// HARDWARE STATUS: protocol-verified against chessnutech/chess_move_api
// @ c9b1dc6b (2025-08-08, latest official Move doc), cross-checked against
// NSStudent/EasyLinkSwiftSDK @ 1b971059 (MIT).  Awaiting physical-board or
// BLE capture-log validation.
//
// Sources used (MIT-licensed unless noted):
//   [MOVE-API]   github.com/chessnutech/chess_move_api README (official; no
//                license — facts only; re-derived independently)
//   [SWIFT-REF]  github.com/NSStudent/EasyLinkSwiftSDK (MIT, © 2026 Omar)
//   [CLASSIC-DOC] github.com/chessnutech/Chessnut_eBoards (official; no license
//                — facts only; classical profile context)
//   [C-REF]      github.com/chessnutech/EasyLinkSDK (MIT, © 2022 chessnutech)
//
// Discrepancy ledger entries cited below follow the spec's numbering (D1–D9).

// MARK: - Move-specific opcodes

private enum MoveOpcode {
    /// Board-state notification (notify on 1b7e8262, same as classic).
    static let boardState:    UInt8 = 0x01
    /// Enter realtime streaming mode (write to 1b7e8272, same as classic).
    static let realtimeMode:  UInt8 = 0x21
    /// Auto-move target-position command (write to 1b7e8272, Move-only).
    static let autoMove:      UInt8 = 0x42
    /// Per-square 4-colour LED command (write to 1b7e8272, Move-only).
    static let led:           UInt8 = 0x43
    /// Extended query/response opcode (write/notify on 1b7e8272/73, Move).
    /// Dispatches on sub-opcode byte[2].
    static let extended:      UInt8 = 0x41
}

private enum MoveSubOpcode {
    /// Battery sub-opcode: request `41 01 0C`; response `41 03 0C ch lvl`.
    static let battery:     UInt8 = 0x0C
    /// Piece-status sub-opcode: request `41 01 0B`; response 139 bytes.
    static let pieceStatus: UInt8 = 0x0B
}

// MARK: - Piece-identity table (§8 per-piece tracking)
//
// Maps the identity byte in each 4-byte piece-status record to a Piece.
// This table is COMPLETELY DIFFERENT from the FEN nibble table in
// `chessnutFENPieceByCode` (ChessnutShared.swift).
//
// [DISCREPANCY D6]: both tables are official, but they apply in different
// contexts.  Never share or conflate them.
//
// Source: chess_move_api README §piece-status response (official; facts only;
// re-derived independently).  Record order in the 139-byte response (0-based):
//   White: P×8(0–7), R×2(8–9), N×2(10–11), B×2(12–13), Q×2(14–15), K(16)
//   Black: p×8(17–24), r×2(25–26), n×2(27–28), b×2(29–30), q×2(31–32), k(33)
// Spare queens: white = record 15, black = record 32 (the second of each Q×2).
// Session code MUST key on the per-record identity byte, not record position:
// record 13 is a bishop, not a queen — positional off-by-one mis-identifies
// pieces during promotion handling. [RISK §c]
// x/y are normalised 0–255; axis orientation is undocumented — use for
// presence/off-board heuristics only until hardware-calibrated.

private let moveIdentityByCode: [UInt8: Piece] = [
    1:  Piece(type: .pawn,   color: .white),
    2:  Piece(type: .rook,   color: .white),
    3:  Piece(type: .knight, color: .white),
    4:  Piece(type: .bishop, color: .white),
    5:  Piece(type: .queen,  color: .white),
    6:  Piece(type: .king,   color: .white),
    7:  Piece(type: .pawn,   color: .black),
    8:  Piece(type: .rook,   color: .black),
    9:  Piece(type: .knight, color: .black),
    10: Piece(type: .bishop, color: .black),
    11: Piece(type: .queen,  color: .black),
    12: Piece(type: .king,   color: .black),
]

// MARK: - LED nibble value for LEDStyle

/// Map the advisory `LEDStyle` to a 2-bit LED nibble value.
/// Nibble values: 0=off, 1=red, 2=green, 3=blue.
/// Source: chess_move_api README §LED command (facts only).
private func moveNibble(for style: LEDStyle) -> UInt8 {
    switch style {
    case .highlight:       return 2   // green
    case .moveFrom:        return 2   // green (source square)
    case .moveTo:          return 3   // blue  (destination square)
    case .danger:          return 1   // red   (check / threat)
    case .custom(let v):   return v & 0x3
    }
}

// MARK: - ChessnutMoveAdapter

/// BLE board adapter for the Chessnut Move robotics board.
///
/// The Move shares all GATT UUIDs with the classic Chessnut Air family but
/// adds colour LEDs, a motorised auto-move mechanism (34 micro-robot pieces),
/// and per-piece tracking.  Detection MUST use an exact name match:
/// `ChessnutGATT.isMoveProfile(name:)`.
///
/// ## Capabilities
///
/// `.occupancySensing` + `.pieceIdentity` + `.perPieceTracking` +
/// `.perSquareLEDs` + `.moveIndication` + `.motorised` + `.batteryReporting`
///
/// ## Frame formats
///
/// Board-state (notify on 1b7e8262), 38 bytes:
/// ```
/// [0x01, 0x24, board[0..31], tail[0..3]]
/// ```
/// The 32 board bytes use the same h8-first nibble packing as the classic
/// profile; the 4 tail bytes are an opaque LE u32 (assumed timestamp, UNVERIFIED
/// on Move). [D1]: Move officially = 38 bytes (corrected in c9b1dc6b).
///
/// Auto-move command (write to 1b7e8272), 35 bytes:
/// ```
/// [0x42, 0x21, board[0..31], forceFlag]
/// ```
/// The board payload is the TARGET position — the robot plans piece paths.
/// `forceFlag = 0` → force (override user interaction); `= 1` → non-force.
/// [D2]: forceFlag inverted vs. a naive bool; "34 zeros" README typo = 33.
///
/// LED command (write to 1b7e8272), 34 bytes:
/// ```
/// [0x43, 0x20, led[0..31]]
/// ```
/// Same square order and nibble packing as board frames; nibble 0=off,
/// 1=red, 2=green, 3=blue.  [DISCREPANCY vs classic]: classic uses rank
/// bitmaps (8 bytes), monochrome; Move uses nibbles (32 bytes), 4-colour.
///
/// ## auto-move completion risk
///
/// No ack/progress/completion frame is documented for `0x42 0x21`.  FEN
/// notifications on 8262 are suppressed during execution.  Session code
/// MUST implement an external completion strategy: poll `41 01 0B` piece
/// positions and/or wait for FEN stream to resume; apply a timeout. [RISK §a]
///
/// ## MTU
///
/// The 139-byte piece-status notification will be truncated at default ATT
/// MTU 23.  On Android request MTU ≥ 247 before subscribing. [RISK §g]
///
/// ## Hardware status
///
/// Protocol-verified against [MOVE-API] and [SWIFT-REF]; golden fixtures
/// machine-verified.  Awaiting physical-board or BLE capture-log validation.
public struct ChessnutMoveAdapter: BoardAdapter {

    // MARK: - State

    /// Raw byte accumulator — holds bytes that arrived mid-frame.
    private var buffer: [UInt8] = []

    /// Identity snapshot from the previous board frame.  Nil on startup /
    /// after `resetFraming()`.  Used to compute lift/place deltas.
    private var previousIdentity: [Piece?]? = nil

    /// Identity snapshot from the last board frame received.  Read by
    /// `encode(.executeMove(uci:))` to compute the auto-move target position.
    /// Updated by `feed(bytes:)` via `processBoardStateFrame`.
    private var currentIdentity: [Piece?]? = nil

    // MARK: - BoardAdapter conformance

    /// The full Move capability set.
    ///
    /// The `.perPieceTracking` bit reflects the 34 micro-robot pieces; it
    /// implies `.pieceIdentity`.  `.motorised` reflects the auto-move
    /// mechanism.  All other bits are shared with the classic profile.
    public var capabilities: BoardCapabilities {
        [.occupancySensing, .pieceIdentity, .perPieceTracking,
         .perSquareLEDs, .moveIndication, .motorised, .batteryReporting]
    }

    public init() {}

    // MARK: - feed

    /// Decode raw BLE notification bytes and return semantic events.
    ///
    /// Frame format: `[opcode, payloadLength, payload…]`.
    /// Length rule: `real_size = buf[1] + 2` ([C-REF]).
    ///
    /// Dispatch table (notify channels):
    /// - `0x01` on 1b7e8262 → board-state → `identitySnapshot` + deltas + `.ready`
    /// - `0x41` on 1b7e8273 → extended response → dispatch on sub-opcode:
    ///   - `0x0C` battery → `.battery(percent:)`
    ///   - `0x0B` piece-status → `.raw(data)` (no dedicated `BoardEvent` case yet)
    ///   - other → `.raw(data)`
    /// - anything else → `.raw(data)`
    public mutating func feed(bytes: Data) -> [BoardEvent] {
        buffer.append(contentsOf: bytes)
        var events: [BoardEvent] = []
        while buffer.count >= 2 {
            let payloadLen = Int(buffer[1])
            let frameLen   = payloadLen + 2
            guard buffer.count >= frameLen else { break }
            let frame = Array(buffer.prefix(frameLen))
            buffer.removeFirst(frameLen)
            events += processFrame(frame)
        }
        return events
    }

    // MARK: - encode

    /// Encode a `BoardCommand` to its Move-profile wire representation.
    ///
    /// Command mapping:
    /// ```
    /// .startSession       → 21 01 00 (enter realtime mode)
    /// .requestState       → 21 01 00 (re-enter realtime → fresh frame)
    /// .indicateSquares    → 43 20 + 32 LED nibble bytes (4-colour)
    /// .executeMove(uci)   → 42 21 + 32 target-board bytes + forceFlag 0x00
    /// .custom(data)       → data verbatim
    /// ```
    ///
    /// `executeMove` returns `nil` when no board frame has been received yet
    /// (`currentIdentity == nil`) or the UCI string cannot be applied to the
    /// current identity.
    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession, .requestState:
            return Data([0x21, 0x01, 0x00])
        case .indicateSquares(let squares, let style):
            return encodeLED(squares: squares, style: style)
        case .executeMove(let uci):
            return encodeExecuteMove(uci: uci)
        case .custom(let data):
            return data
        }
    }

    // MARK: - handshakeCommands

    /// Move handshake sequence.
    ///
    /// Identical to the classic profile: send `21 01 00` to enter realtime
    /// mode.  On reconnect, allow 250 ms for the BLE link to stabilise.
    ///
    /// [MOVE-API] does NOT document a confirmation echo or heartbeat on 8273
    /// (unlike classic boards which emit `21 01 00` + `23 01 00`).  Do NOT
    /// gate the handshake on receiving any response. [RISK §i]
    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)] {
        if isReconnect {
            return [(.startSession, 0.25)] // 250ms
        }
        return [(.startSession, 0)]
    }

    // MARK: - resetFraming

    /// Reset frame buffer, identity history, and the current-identity cache.
    ///
    /// Call this when the BLE link drops and is about to be re-established,
    /// before `handshakeCommands(isReconnect: true)` runs.
    ///
    /// - `buffer`: clears any mid-frame bytes.  The Move's 38-byte frames
    ///   split across BLE's 23-byte default ATT MTU, making mid-frame
    ///   disconnects realistic.
    /// - `previousIdentity`: cleared so the next frame re-triggers `.ready`
    ///   and produces no spurious lift/place deltas.
    /// - `currentIdentity`: cleared so `encode(.executeMove)` does not act
    ///   on a stale position from before the disconnect.
    public mutating func resetFraming() {
        buffer          = []
        previousIdentity = nil
        currentIdentity  = nil
    }

    // MARK: - Static command builders

    /// Battery request command: write `41 01 0C` to characteristic 1b7e8272.
    /// Response arrives on notify char 1b7e8273: `41 03 0C <charging> <level>`.
    ///
    /// charging byte: 1=charging, 0=not charging.  level byte: 0–100.
    ///
    /// [DISCREPANCY vs classic]: classic uses `29 01 00` / `2A 02 <level|0x80>`;
    /// Move uses `41 01 0C` / `41 03 0C` with a dedicated charging byte.
    public static func batteryRequestData() -> Data {
        Data([0x41, 0x01, 0x0C])
    }

    /// Per-piece tracking request: write `41 01 0B` to characteristic 1b7e8272.
    ///
    /// Response on notify char 1b7e8273: `[0x41, 0x89, 0x0B] + 34 × 4 bytes`
    /// = 139 bytes total.  Each 4-byte record: `[identity, x, y, bat]`.
    ///
    /// Record order (positional, 0-based): white P×8(0–7), R×2(8–9),
    /// N×2(10–11), B×2(12–13), Q×2(14–15), K(16); black mirrors at 17–33.
    /// Spare queens: white = record 15, black = record 32.
    /// Key on the per-record identity byte rather than record position to
    /// avoid off-by-one mis-identification (record 13 = bishop, not queen).
    ///
    /// [D6]: the `identity` byte uses `moveIdentityByCode` — NOT the FEN
    /// nibble table.
    /// [RISK §g]: MTU — 139-byte notification will be fragmented at ATT MTU 23.
    /// Android must request MTU ≥ 247 before subscribing.
    public static func pieceStatusRequestData() -> Data {
        Data([0x41, 0x01, 0x0B])
    }

    /// Stop auto-move: all-zero target board, forceFlag = 0 (35 bytes).
    ///
    /// Sends a target position with no pieces, which cancels any in-progress
    /// auto-move motion.
    ///
    /// [D2]: the README text says "34 zeros" — this is a typo.  The len byte
    /// `0x21 = 33` mandates exactly 33 payload bytes (2+33=35 total).  Pinned
    /// by EasyLinkSwiftSDK `testMoveStopAutoMoveCommand`.
    public static func stopAutoMoveData() -> Data {
        var frame = [UInt8](repeating: 0, count: 35)
        frame[0] = MoveOpcode.autoMove
        frame[1] = 0x21   // len = 33 (32 board + 1 force flag)
        return Data(frame)
    }

    /// Encode a 38-byte Move board-state frame from a file-major identity
    /// array.  Used by test harnesses and capture-log tooling; NOT sent over
    /// the wire by the host (the board pushes these on 1b7e8262).
    ///
    /// Frame layout: `[0x01, 0x24, board[0..31], 0x00, 0x00, 0x00, 0x00]`
    ///
    /// The 4-byte tail is zeroed (opaque; assumed LE u32 timestamp by analogy
    /// with classic hardware, UNVERIFIED on Move).
    ///
    /// [D1]: Move officially = 38 bytes; classic = 36.  Header byte[1] = 0x24
    /// (Move) vs 0x22 (classic), per the `real_size = buf[1]+2` rule.
    public static func encodeFrame(identity: [Piece?]) -> Data {
        precondition(identity.count == 64, "ChessnutMoveAdapter.encodeFrame: identity must be 64 elements")
        var frame = [UInt8](repeating: 0, count: 38)
        frame[0] = MoveOpcode.boardState
        frame[1] = 0x24   // payload = 36 (32 board + 4 tail)
        let board = chessnutEncodeBoard(identity: identity)
        frame.replaceSubrange(2..<34, with: board)
        // bytes[34..37] remain 0x00 (opaque tail; LE u32 timestamp on classic)
        return Data(frame)
    }

    /// Encode a 35-byte auto-move command targeting a specific board layout.
    ///
    /// - Parameters:
    ///   - identity: The TARGET 64-element file-major identity (a1=0…h8=63).
    ///     The robot plans piece paths autonomously from the current physical
    ///     position to this target.
    ///   - force: `true` → forceFlag byte = 0 (robot overrides user touching
    ///     pieces).  `false` → forceFlag byte = 1 (user contact halts arm).
    ///
    /// [SWIFT-REF] `setAutoMove(fen:force:)` maps `force ? 0 : 1` — the flag
    /// byte is INVERTED relative to a naive bool cast.
    ///
    /// Captures, castling, and promotion are expressed only as the target
    /// position; the robot handles piece logistics (capture parking, spare
    /// queens for promotion). [RISK §f]
    public static func encodeAutoMove(identity: [Piece?], force: Bool) -> Data {
        precondition(identity.count == 64, "ChessnutMoveAdapter.encodeAutoMove: identity must be 64 elements")
        var frame = [UInt8](repeating: 0, count: 35)
        frame[0] = MoveOpcode.autoMove
        frame[1] = 0x21   // len = 33 (32 board + 1 force flag)
        let board = chessnutEncodeBoard(identity: identity)
        frame.replaceSubrange(2..<34, with: board)
        frame[34] = force ? 0 : 1   // inverted: force==true → byte 0
        return Data(frame)
    }

    // MARK: - Frame processing (private)

    private mutating func processFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard !frame.isEmpty else { return [] }
        switch frame[0] {
        case MoveOpcode.boardState:
            return processBoardStateFrame(frame)
        case MoveOpcode.extended:
            return processExtendedFrame(frame)
        default:
            return [.raw(Data(frame))]
        }
    }

    /// Decode a Move board-state frame (notify on 1b7e8262).
    ///
    /// Acceptance rule (spec §4, D4):
    ///   `byte[0] == 0x01` AND `length >= 34`
    ///
    /// Tolerates any `byte[1]` value ≥ 32 — the header byte is validated as
    /// the start-of-frame opcode, not as a fixed payload-size sentinel, per
    /// the `real_size = buf[1]+2` rule and D4 ruling.  Logs-and-tolerates
    /// `byte[1] != 0x24`; do not hard-assert 0x24 before hardware capture.
    ///
    /// The 4-byte tail (bytes[34..37]) is treated as opaque. [RISK §b]
    private mutating func processBoardStateFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame[0] == MoveOpcode.boardState, frame.count >= 34 else {
            return [.raw(Data(frame))]
        }
        let isFirstFrame = (previousIdentity == nil)

        // Decode via shared codec; 0xD–0xF nibbles flagged but not fatal.
        let (identity, hasInvalidNibble) = chessnutDecodeBoard(from: frame, start: 2)

        var events: [BoardEvent] = []
        events.append(.identitySnapshot(identity))

        if let prev = previousIdentity {
            events += chessnutDeltaEvents(prev: prev, curr: identity)
        }

        if hasInvalidNibble {
            events.append(.raw(Data(frame)))
        }

        previousIdentity = identity
        currentIdentity  = identity

        if isFirstFrame {
            events.append(.ready)
        }
        return events
    }

    /// Decode extended response frames (notify on 1b7e8273).
    ///
    /// Dispatch on `frame[2]` (sub-opcode):
    ///
    /// **Battery (0x0C)**: `41 03 0C <charging> <level>`
    ///   - Emits `.battery(percent: Int(frame[4]))`.
    ///   - The charging byte (`frame[3]`) is not currently forwarded
    ///     (surfacing it requires a new `BoardEvent` payload — tracked for a
    ///     future minor version).
    ///   - [DISCREPANCY vs classic]: classic battery decodes a bitmask
    ///     `level & 0x7F`; Move has a dedicated charging byte, no mask needed.
    ///
    /// **Piece-status (0x0B)**: `41 89 0B <34×4 records>` (139 bytes total)
    ///   - Emitted as `.raw(data)` — no dedicated `BoardEvent` case exists yet.
    ///   - Session code may parse records using `moveIdentityByCode` (§8 table).
    ///   - [D6]: identity byte in records uses a DIFFERENT table from board
    ///     nibbles — see `moveIdentityByCode` above.
    ///   - [RISK §g]: MTU — will be fragmented at ATT MTU 23; a length-based
    ///     reassembler is advisable before parsing.
    ///
    /// **All other sub-opcodes**: emitted as `.raw(data)`.
    private func processExtendedFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count >= 3 else { return [.raw(Data(frame))] }
        switch frame[2] {
        case MoveSubOpcode.battery:
            // Battery response: 41 03 0C <charging> <level>
            // frame[3] = charging (1=yes, 0=no); frame[4] = level 0–100.
            guard frame.count >= 5 else { return [.raw(Data(frame))] }
            return [.battery(percent: Int(frame[4]))]
        case MoveSubOpcode.pieceStatus:
            // Piece-status response: 139-byte frame; raw passthrough.
            // No BoardEvent case for per-piece data yet; session may parse.
            return [.raw(Data(frame))]
        default:
            return [.raw(Data(frame))]
        }
    }

    // MARK: - LED encoding (4-colour, 34 bytes)

    /// Encode a 4-colour LED command for the Chessnut Move (34 bytes).
    ///
    /// Format: `43 20 led[0..31]` on write char 1b7e8272.
    /// Packing is identical to board frames — same h8-first scan order, same
    /// LOW-nibble-first convention.  Nibble values: 0=off, 1=red, 2=green, 3=blue.
    ///
    /// `LEDStyle` → nibble mapping:
    ///   `.highlight` / `.moveFrom` → 2 (green)
    ///   `.moveTo`                   → 3 (blue)
    ///   `.danger`                   → 1 (red)
    ///   `.custom(v)`                → v & 0x3
    ///
    /// [DISCREPANCY vs classic]: classic uses `0A 08` + 8 rank-bitmap bytes,
    /// monochrome, one bit per square; Move uses `43 20` + 32 nibble bytes,
    /// 4-colour, one nibble per square.
    ///
    /// F7 canary: h8=red, g8=green → byte[2] = 0x21 (low nibble=1=red,
    /// high nibble=2=green).  Any nibble-order inversion yields 0x12.
    private func encodeLED(squares: [String], style: LEDStyle) -> Data {
        let nibble = moveNibble(for: style)
        var bytes = [UInt8](repeating: 0, count: 34)
        bytes[0] = MoveOpcode.led
        bytes[1] = 0x20   // len = 32 (one nibble per square, packed two-per-byte)
        for square in squares {
            guard let sq = Square(algebraic: square) else { continue }
            // Convert algebraic → protocol square index s (0=h8…63=a1).
            // row = 7 − rank (0-indexed, 0=rank-8); pc = 7 − file (0=h-file).
            let row = 7 - sq.rank
            let pc  = 7 - sq.file
            let s   = row * 8 + pc
            let byteIndex = 2 + s / 2
            if s % 2 == 0 {
                // s even → LOW nibble
                bytes[byteIndex] = (bytes[byteIndex] & 0xF0) | (nibble & 0x0F)
            } else {
                // s odd  → HIGH nibble
                bytes[byteIndex] = (bytes[byteIndex] & 0x0F) | ((nibble & 0x0F) << 4)
            }
        }
        return Data(bytes)
    }

    // MARK: - Auto-move (executeMove) encoding

    /// Encode `.executeMove(uci:)` as a 35-byte auto-move command.
    ///
    /// Applies the UCI move to `currentIdentity` to obtain the target board,
    /// then encodes it with `force = true` (forceFlag = 0).
    ///
    /// Returns `nil` when:
    /// - `currentIdentity == nil` (no board frame received yet)
    /// - `uci` is not an exact 4/5-character UCI move
    /// - No piece occupies the UCI from-square
    /// - The sensed identity contradicts a special move (missing castle rook,
    ///   missing en-passant pawn, invalid promotion, or occupied own target)
    ///
    /// [RISK §a]: no ack/completion frame; FEN suppressed during execution.
    /// [RISK §e]: if `currentIdentity` drifted from the physical board,
    ///   the robot may move many pieces at once — prefer `force = false`
    ///   (non-force mode, forceFlag = 1) in user-facing contexts.
    private func encodeExecuteMove(uci: String) -> Data? {
        guard let identity = currentIdentity,
              let target   = applyUCI(uci, to: identity)
        else { return nil }
        return Self.encodeAutoMove(identity: target, force: true)
    }

    /// Apply a UCI move string to a 64-element file-major identity array.
    ///
    /// Returns the resulting identity after the move, or `nil` if the move
    /// string cannot be applied (bad algebraic notation or empty from-square).
    ///
    /// Handles:
    /// - Simple moves and captures (normal remove-from, place-to)
    /// - Kingside / queenside castling (king moves exactly 2 files)
    /// - En passant (pawn moves diagonally to an EMPTY square → captured pawn
    ///   at `(to.file, from.rank)`)
    /// - Promotions (5th UCI character: q/r/b/n)
    ///
    /// En passant detection is reliable for a codec: a pawn moving diagonally
    /// to an empty square has no other legal interpretation in standard chess.
    private func applyUCI(_ uci: String, to identity: [Piece?]) -> [Piece?]? {
        let characters = Array(uci)
        guard identity.count == 64,
              characters.count == 4 || characters.count == 5,
              let fromSq = Square(algebraic: String(characters[0...1])),
              let toSq   = Square(algebraic: String(characters[2...3])),
              fromSq != toSq
        else { return nil }

        let fromIdx = fromSq.file * 8 + fromSq.rank   // file-major
        let toIdx   = toSq.file   * 8 + toSq.rank
        guard let movingPiece = identity[fromIdx] else { return nil }

        // A stale identity snapshot must never make the motor overwrite one of
        // the mover's own pieces. Full legality belongs to ChessCore/session
        // state, which carries side-to-move and rights; this is the fail-safe
        // consistency check available at the wire-codec boundary.
        if identity[toIdx]?.color == movingPiece.color { return nil }

        let promotionPiece: Piece?
        if characters.count == 5 {
            let expectedFromRank = movingPiece.color == .white ? 6 : 1
            let expectedRankDelta = movingPiece.color == .white ? 1 : -1
            let fileDelta = abs(toSq.file - fromSq.file)
            guard movingPiece.type == .pawn,
                  fromSq.rank == expectedFromRank,
                  toSq.rank - fromSq.rank == expectedRankDelta,
                  fileDelta <= 1,
                  (movingPiece.color == .white ? toSq.rank == 7 : toSq.rank == 0),
                  let promoted = promotedPiece(from: characters[4], color: movingPiece.color)
            else { return nil }
            // A forward promotion must land on an empty square; a diagonal
            // promotion must capture an opposing piece. The codec does not own
            // full move legality, but it must never command the motor to invent
            // or erase a physically impossible last-rank capture.
            if fileDelta == 0 {
                guard identity[toIdx] == nil else { return nil }
            } else {
                guard identity[toIdx]?.color == movingPiece.color.opposite else { return nil }
            }
            promotionPiece = promoted
        } else {
            // A pawn may not be left as a pawn on the back rank. Require the
            // promotion suffix rather than silently emitting an impossible
            // target board.
            if movingPiece.type == .pawn && (toSq.rank == 0 || toSq.rank == 7) {
                return nil
            }
            promotionPiece = nil
        }

        var target = identity

        // Castling: king moves exactly 2 files.
        if movingPiece.type == .king && abs(fromSq.file - toSq.file) == 2 {
            let rank = fromSq.rank
            let homeRank = movingPiece.color == .white ? 0 : 7
            let isKingside          = toSq.file > fromSq.file
            let (rookFrom, rookTo)  = isKingside ? (7, 5) : (0, 3)
            let rookFromIdx = rookFrom * 8 + rank
            let rookToIdx = rookTo * 8 + rank
            let pathFiles = isKingside ? [5, 6] : [1, 2, 3]
            guard fromSq.file == 4,
                  rank == homeRank,
                  toSq.rank == homeRank,
                  (toSq.file == 2 || toSq.file == 6),
                  pathFiles.allSatisfy({ identity[$0 * 8 + rank] == nil }),
                  let rook = identity[rookFromIdx],
                  rook == Piece(type: .rook, color: movingPiece.color),
                  identity[rookToIdx] == nil
            else { return nil }
            target[fromIdx]          = nil
            target[toIdx]            = movingPiece
            target[rookFromIdx]       = nil
            target[rookToIdx]         = rook
            return target
        }

        // En passant: pawn moves diagonally to an empty square.
        if movingPiece.type == .pawn,
           fromSq.file != toSq.file,
           identity[toIdx] == nil
        {
            let capturedIdx = toSq.file * 8 + fromSq.rank
            let expectedRankDelta = movingPiece.color == .white ? 1 : -1
            let expectedFromRank = movingPiece.color == .white ? 4 : 3
            guard fromSq.rank == expectedFromRank,
                  toSq.rank - fromSq.rank == expectedRankDelta,
                  identity[capturedIdx] == Piece(type: .pawn, color: movingPiece.color.opposite)
            else { return nil }
            target[fromIdx]    = nil
            target[toIdx]      = movingPiece
            target[capturedIdx] = nil
            return target
        }

        if let promotionPiece {
            target[fromIdx] = nil
            target[toIdx] = promotionPiece
            return target
        }

        // Normal move / capture (capture: overwrite the to-square).
        target[fromIdx] = nil
        target[toIdx]   = movingPiece
        return target
    }

    /// Map a UCI promotion character to a `Piece`.
    private func promotedPiece(from c: Character, color: PieceColor) -> Piece? {
        switch c {
        case "q": return Piece(type: .queen,  color: color)
        case "r": return Piece(type: .rook,   color: color)
        case "b": return Piece(type: .bishop, color: color)
        case "n": return Piece(type: .knight, color: color)
        default:  return nil
        }
    }
}
