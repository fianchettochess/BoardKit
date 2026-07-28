import Foundation
import ChessCore
import BoardKit

// ── Chessnut Air-family BLE adapter ──────────────────────────────────────────
//
// Implements `BoardAdapter` for the Chessnut Air, Air+, Pro, and Go (the
// "classic profile" boards). The Chessnut Move ("extended profile") shares
// most of this framing but adds colour LEDs, auto-move, and per-piece
// tracking; those extensions are NOT implemented here.
//
// HARDWARE STATUS: Protocol-verified against three authoritative sources;
// awaiting physical-board or capture-log validation. See README.
//
// Sources used (all MIT-licensed or official documentation):
//   [OFFICIAL-DOC] github.com/chessnutech/Chessnut_eBoards README.md
//   [SWIFT-REF]    github.com/NSStudent/EasyLinkSwiftSDK
//                  @ 1b9710593b192ae102f8a1fd695467c9eb990535 (MIT)
//   [C-REF]        github.com/chessnutech/EasyLinkSDK
//                  @ 4554d17be976f746b8b1139a3b9a025e2b54c8ba (official, MIT)
//
// Where sources disagreed, the REFERENCE implementations are followed and
// each choice is recorded in a comment citing the discrepancy.

// MARK: - GATT constants

/// UUIDs for the Chessnut Air-family classic profile.
///
/// Device name filter: name has prefix "Chessnut" AND is not exactly
/// "Chessnut Move". Matches "Chessnut Air", "Chessnut Air+", "Chessnut
/// Pro", "Chessnut Go".
///
/// Source: OFFICIAL-DOC + SWIFT-REF `CoreBluetoothEasyLinkTransport`.
public enum ChessnutGATT {
    /// Board-state (FEN) notification service.
    public static let boardStateService   = "1b7e8261-2877-41c3-b46e-cf057c562023"
    /// Board-state notification characteristic (notify).
    public static let boardStateChar      = "1b7e8262-2877-41c3-b46e-cf057c562023"
    /// Command write + response service.
    public static let commandService      = "1b7e8271-2877-41c3-b46e-cf057c562023"
    /// Command write characteristic (write / writeWithoutResponse).
    public static let commandWriteChar    = "1b7e8272-2877-41c3-b46e-cf057c562023"
    /// Command response characteristic (notify; SWIFT-REF also reads it
    /// during OTB import).
    public static let commandResponseChar = "1b7e8273-2877-41c3-b46e-cf057c562023"
    /// File/OTB notification service (SWIFT-REF only; not in OFFICIAL-DOC).
    public static let fileService         = "1b7e8281-2877-41c3-b46e-cf057c562023"
    /// File notification characteristic (notify).
    public static let fileChar            = "1b7e8283-2877-41c3-b46e-cf057c562023"

    /// Returns `true` when `name` belongs to the Air-family classic profile.
    ///
    /// Classic boards advertise names with a "Chessnut" prefix:
    /// "Chessnut Air", "Chessnut Air+", "Chessnut Pro", "Chessnut Go".
    /// Profile selection MUST use exact-name or prefix logic; all UUIDs are
    /// shared with the Move profile so UUID inspection cannot distinguish them.
    public static func isClassicProfile(name: String) -> Bool {
        name.hasPrefix("Chessnut") && name != "Chessnut Move"
    }

    /// Returns `true` when `name` is the Chessnut Move profile.
    ///
    /// The Move advertises exactly `"Chessnut Move"`.  Because it shares all
    /// GATT UUIDs with the classic profile, name-based detection is the only
    /// way to select the correct adapter.
    ///
    /// Source: chess_move_api README (official); cross-checked against
    /// EasyLinkSwiftSDK `CoreBluetoothEasyLinkTransport` name filter.
    public static func isMoveProfile(name: String) -> Bool {
        name == "Chessnut Move"
    }
}

// MARK: - Opcodes (internal constants)

private enum Opcode {
    static let boardState:     UInt8 = 0x01
    static let beep:           UInt8 = 0x0B
    static let led:            UInt8 = 0x0A
    static let mode:           UInt8 = 0x21
    static let bleVersion:     UInt8 = 0x27
    static let batteryRequest: UInt8 = 0x29
    static let batteryReply:   UInt8 = 0x2A
    static let fileCount:      UInt8 = 0x31
    static let fileCountReply: UInt8 = 0x32
    static let readyForImport: UInt8 = 0x33
    static let startImport:    UInt8 = 0x34
    static let metadata:       UInt8 = 0x36
    static let fileFlag:       UInt8 = 0x37
    static let deleteFile:     UInt8 = 0x39
}

// MARK: - Piece-code table
//
// Delegated to ChessnutShared.swift (`chessnutFENPieceByCode` /
// `chessnutFENCodeForPiece`).  Kept here only as a comment so the file
// structure remains legible.
//
// Nibble → Piece mapping, verified byte-for-byte against all three sources:
//   [OFFICIAL-DOC] §piece encoding; [C-REF] CHESS_PIECES[]; [SWIFT-REF] pieceByCode.
// Layout is deliberately irregular (white R=6 at index 6, black r=8 at index 8).
// Do not normalise.  See ChessnutShared.swift for the shared implementation.

// MARK: - ChessnutAdapter

/// BLE board adapter for the Chessnut Air family (Air, Air+, Pro, Go).
///
/// Conforms to `BoardAdapter` as a mutable struct so the transport can
/// hold `var adapter: ChessnutAdapter` without heap allocation.
///
/// ## Square indexing (the mirror trap)
///
/// The protocol's linear square index `s` runs h8→g8→…→a8→h7→…→a1:
///
/// ```
/// s = (8 − rank) × 8 + (7 − file)   // file: a=0…h=7, rank: 1…8
/// byteIndex = 2 + s/2
/// s even  → LOW  nibble (byte & 0x0F)
/// s odd   → HIGH nibble (byte >> 4)
/// ```
///
/// This adapter converts every protocol square index to the file-major
/// index used by `BoardEvent` (`file × 8 + (rank − 1)`, 0-indexed rank).
///
/// Mnemonic that holds for frames AND LED bytes: rank 8 is always first,
/// and the h-file always sits at the least-significant end of each byte.
///
/// ## Write pacing
///
/// [C-REF] enforces `WRITE_INTERVAL = 200` ms between consecutive writes.
/// [SWIFT-REF] enforces `minimumWriteInterval = 0.2` s. The adapter
/// documents this requirement in `handshakeCommands`'s `delayBefore`
/// fields; the transport is responsible for enforcing the gap. LED spam
/// without pacing is the known failure mode.
///
/// ## Hardware status
///
/// Protocol-verified against OFFICIAL-DOC, SWIFT-REF, and C-REF. Three
/// golden fixtures are doubly source-confirmed (G1 initial position, G7
/// c4 LED). Awaiting physical board or BLE capture log for runtime
/// verification.
public struct ChessnutAdapter: BoardAdapter {

    // MARK: - State

    /// Raw byte accumulator. Holds bytes that arrived mid-frame.
    private var buffer: [UInt8] = []

    /// Last decoded 64-element identity array (file-major, a1=0…h8=63).
    /// `nil` on startup — used to compute lift/place deltas on each new
    /// board-state frame.
    private var previousIdentity: [Piece?]? = nil

    // MARK: - Stored-game import state
    //
    // A `.requestStoredGames` import drives a short handshake the adapter
    // sequences from the board's replies (via `takePendingResponses()`):
    //
    //   host → 0x31 01 00                    (file-count query; from encode)
    //   board→ 0x32 01 <count>               (→ queue upload-mode + 0x33 + 0x34)
    //   host → 0x21 01 01                    (enter upload mode)
    //   host → 0x33 01 00                    (ready for import)
    //   host → 0x34 01 01                    (start import)
    //   board→ 0x37 01 BE                    (file begin)
    //   board→ 0x01 …  × N                   (one board-identity snapshot/move)
    //   board→ 0x37 01 ED                    (file end → reconstruct + emit)
    //
    // Per [C-REF] `getFile`, each game is one BE…ED cycle requested by its own
    // 0x33/0x34 pair, repeated up to `<count>` times. We never send the 0x39
    // delete — the user's on-board games are preserved.

    /// `true` between a `0x37 01 BE` and its `0x37 01 ED`: `0x01` frames are
    /// buffered as stored-game snapshots instead of streamed as live state.
    private var fileTransferActive = false

    /// Board-identity snapshots accumulated for the game currently streaming.
    private var fileSnapshots: [[Piece?]] = []

    /// Stored games not yet requested. Set from the `0x32` count reply and
    /// decremented per completed game; while > 0 the adapter re-requests the
    /// next game after each `0x37 01 ED`.
    private var filesRemaining = 0

    /// Out-of-band wire responses queued while parsing the last `feed(bytes:)`
    /// — the transport drains these via `takePendingResponses()` and writes
    /// each back to the board. Drives the download handshake above.
    private var pendingResponses: [Data] = []

    // MARK: - BoardAdapter conformance

    public var capabilities: BoardCapabilities { .chessnutAirFamily }

    /// Both reference clients enforce a 200 ms floor between every pair of
    /// writes to the classic Chessnut command characteristic. The transport
    /// applies this to normal commands and adapter-queued stored-game
    /// handshake responses alike.
    public var minimumWriteInterval: TimeInterval { 0.2 }

    public init() {}

    /// Feed raw BLE notification bytes through the frame parser.
    ///
    /// Frame format: `[opcode, payloadLength, payload…]`. No checksum, no
    /// CRC, no multi-packet reassembly.
    /// [C-REF]: `real_size = buf[1] + 2`, dispatch on `buf[0]`.
    ///
    /// Dispatch table:
    /// - `0x01` → board-state frame → `identitySnapshot` + `squareSensed` deltas
    /// - `0x2A` → battery response → `battery(percent:)`
    /// - `0x27` → BLE/MCU version → `raw(data)`
    /// - `0x37` → file-transfer flags → `raw(data)`
    /// - everything else → `raw(data)` for debug logging
    public mutating func feed(bytes: Data) -> [BoardEvent] {
        buffer.append(contentsOf: bytes)
        var events: [BoardEvent] = []
        while buffer.count >= 2 {
            let payloadLen = Int(buffer[1])
            let frameLen = payloadLen + 2
            guard buffer.count >= frameLen else { break }
            let frame = Array(buffer.prefix(frameLen))
            buffer.removeFirst(frameLen)
            events += processFrame(frame)
        }
        return events
    }

    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession:
            // Enter realtime mode. All three sources agree: 0x21 0x01 0x00.
            return Data([0x21, 0x01, 0x00])
        case .requestState:
            // Chessnut has no explicit "give me the board state" command; the
            // board streams continuously in realtime mode. Re-entering realtime
            // mode causes an immediate fresh frame. [SWIFT-REF] follows this
            // pattern; [C-REF] does the same on auto-reconnect.
            return Data([0x21, 0x01, 0x00])
        case .indicateSquares(let squares, _):
            // [DISCREPANCY] OFFICIAL-DOC describes "index from 8 to 1, h to a"
            // which is ambiguous about bit order. [SWIFT-REF] test
            // testClassicLEDCommandUsesEightBitRows and [C-REF] README c4
            // example independently confirm: bit 7 (MSB) = a-file, bit 0 (LSB)
            // = h-file, bytes ordered rank 8→1 in positions [2..9].
            return encodeLED(squares: squares)
        case .executeMove:
            // Chessnut Air family has no motorised mechanism; the command is
            // unsupported. Return nil so the transport silently skips it —
            // consistent with the documented unsupported-command contract.
            return nil
        case .requestStoredGames:
            // First step of the stored-game download handshake: query how many
            // games are on flash. The board replies with 0x32 01 <count>, which
            // `processFrame` turns into the mode-switch + 0x33 + 0x34 sequence
            // queued through `takePendingResponses()`. [C-REF] getFileCount.
            return Data([Opcode.fileCount, 0x01, 0x00])
        case .custom(let data):
            return data
        }
    }

    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)] {
        if isReconnect {
            // Reconnect: allow 250 ms for the link to stabilise before re-entering
            // realtime mode. [C-REF] re-sends switchMode(0x00) on auto-reconnect;
            // [SWIFT-REF] uses the same approach. The 250 ms matches the
            // SWIFT-REF minimumWriteInterval × 1.25 safety margin.
            //
            // **Transport contract**: the transport MUST call `resetFraming()`
            // (or recreate the adapter) when the BLE link drops — before
            // executing this reconnect sequence. Mid-frame disconnects are
            // realistic because Chessnut uses 36-byte frames that split across
            // BLE's 23-byte default ATT MTU. Without `resetFraming()`, a
            // half-frame remnant in `buffer` will desynchronise the parser on
            // the first post-reconnect notification.
            return [(.startSession, 0.25)] // 250ms
        }
        // First connect: send realtime-mode command immediately.
        // [OFFICIAL-DOC] Step 4; [SWIFT-REF] enableRealtimeMode; [C-REF] switchMode(0x00).
        return [(.startSession, 0)]
    }

    /// Reset the framing buffer and board-state history.
    ///
    /// Call this when the physical BLE link drops and is about to be
    /// re-established — before the `handshakeCommands(isReconnect: true)`
    /// sequence runs. It clears two pieces of mutable state:
    ///
    /// - `buffer`: any partial-frame bytes from the dropped link that would
    ///   desynchronise the parser on the first post-reconnect notification.
    ///   (Chessnut uses 36-byte frames that commonly split across BLE's
    ///   23-byte default ATT MTU, so mid-frame disconnects are realistic.)
    ///
    /// - `previousIdentity`: re-arming this to `nil` re-triggers the
    ///   first-frame `.ready` emission after the board re-enters realtime
    ///   mode, so the session receives a clean "connected and streaming"
    ///   signal on the new link without having to recreate the adapter.
    public mutating func resetFraming() {
        buffer = []
        previousIdentity = nil
        // Abandon any in-flight stored-game download; a dropped link invalidates
        // the handshake and the partial snapshot buffer.
        fileTransferActive = false
        fileSnapshots.removeAll()
        filesRemaining = 0
        pendingResponses.removeAll()
    }

    // MARK: - Command encoding helpers

    /// Encode a battery-request command (not a `BoardCommand` case;
    /// callers use `.custom` or this helper directly for Chessnut-specific
    /// housekeeping).
    public static func batteryRequestData() -> Data {
        Data([0x29, 0x01, 0x00])
    }

    /// Encode a beep command.
    ///
    /// - Parameters:
    ///   - frequency: Hz, big-endian UInt16.
    ///   - duration: Milliseconds, big-endian UInt16.
    ///
    /// Example: 1000 Hz for 200 ms → `0x0B 0x04 0x03 0xE8 0x00 0xC8`
    /// [C-REF] `cl_beep(freq, duration)`.
    public static func beepData(frequency: UInt16, duration: UInt16) -> Data {
        Data([
            0x0B, 0x04,
            UInt8(frequency >> 8), UInt8(frequency & 0xFF),
            UInt8(duration >> 8),  UInt8(duration & 0xFF),
        ])
    }

    /// Encode a position as a 36-byte Chessnut classic board-state frame.
    ///
    /// The inverse of the frame decoder. Used by test harnesses and
    /// capture-log tooling — not normally sent over the wire (the board
    /// pushes these, not the host).
    ///
    /// `identity` must be 64 elements in file-major order (a1=0…h8=63).
    ///
    /// Frame layout: `[0x01, 0x22, board[0..31], 0x00, 0x00]`
    /// The 32 board bytes use the shared `chessnutEncodeBoard` codec.
    /// For the Move profile's 38-byte frame, use `ChessnutMoveAdapter.encodeFrame`.
    public static func encodeFrame(identity: [Piece?]) -> Data {
        precondition(identity.count == 64, "identity must be 64 elements")
        var frame = [UInt8](repeating: 0, count: 36)
        frame[0] = Opcode.boardState
        frame[1] = 0x22  // payload length = 34 (32 board + 2 trailing zeros)
        let board = chessnutEncodeBoard(identity: identity)
        frame.replaceSubrange(2..<34, with: board)
        // bytes[34..35] remain 0x00 (trailing zeros in classic format)
        return Data(frame)
    }

    // MARK: - Frame processing

    private mutating func processFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard !frame.isEmpty else { return [] }
        switch frame[0] {
        case Opcode.boardState:
            // During a stored-game download, 0x01 frames are archived snapshots,
            // not live board state. Buffer them; do not emit realtime events.
            if fileTransferActive {
                accumulateFileSnapshot(frame)
                return []
            }
            return processBoardStateFrame(frame)
        case Opcode.batteryReply:
            return processBatteryFrame(frame)
        case Opcode.fileCountReply:
            return processFileCountReply(frame)
        case Opcode.fileFlag:
            return processFileFlagFrame(frame)
        default:
            // Unknown / unimplemented opcodes: forward as raw for debug logging.
            return [.raw(Data(frame))]
        }
    }

    /// Decode a board-state frame into an `identitySnapshot` and derived
    /// `squareSensed` lift/place deltas vs the previous frame.
    ///
    /// Acceptance rule (per spec section 9):
    ///   `bytes[0] == 0x01` AND `bytes.count >= 34`
    /// We do NOT hard-code 36 bytes — the spec explicitly says parsers must
    /// accept ≥34. [SWIFT-REF] does the same: it accepts ≥34 and its tests
    /// model classic frames as 36 bytes and Move frames as 38 bytes.
    ///
    /// [DISCREPANCY vs OFFICIAL-DOC]: OFFICIAL-DOC implies a fixed 36-byte
    /// frame. [SWIFT-REF] and [C-REF] both accept ≥34 via `real_size =
    /// buf[1] + 2`. We follow the REFERENCE implementations — they were
    /// written against real hardware.
    private mutating func processBoardStateFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame[0] == Opcode.boardState, frame.count >= 34 else {
            return [.raw(Data(frame))]
        }
        // Capture first-frame status BEFORE mutating previousIdentity so that
        // the .ready guard below is keyed on "no prior state" rather than on
        // event count.  Fixes two linked bugs:
        //   (a) a first frame that contains a 0xD–0xF nibble appended .raw
        //       before the count check, making count == 2 and suppressing
        //       .ready permanently for the session.
        //   (b) any repeat / heartbeat frame with no deltas also had
        //       events.count == 1, which re-emitted .ready on every tick.
        let isFirstFrame = (previousIdentity == nil)

        // Decode 64 squares via shared codec (ChessnutShared.swift).
        // 0xD–0xF nibbles are flagged but the rest of the frame is still used.
        // [SWIFT-REF] throws on invalid nibbles; we continue conservatively.
        let (identity, hasInvalidNibble) = chessnutDecodeBoard(from: frame, start: 2)

        // Build events.
        var events: [BoardEvent] = []

        // Always emit the full snapshot first.
        events.append(.identitySnapshot(identity))

        // Emit squareSensed deltas vs the previous snapshot (shared helper).
        if let prev = previousIdentity {
            events += chessnutDeltaEvents(prev: prev, curr: identity)
        }

        // First frame with invalid nibble: still emit what we have, but flag it.
        if hasInvalidNibble {
            events.append(.raw(Data(frame)))
        }

        previousIdentity = identity

        // Emit .ready only on the very first frame so the session's
        // handshake-complete gate fires exactly once per connect cycle.
        if isFirstFrame {
            events.append(.ready)
        }

        return events
    }

    /// Decode a battery-response frame (`0x2A 0x02 <battery> <reserved>`).
    ///
    /// `battery & 0x7F` = percentage 0–100.
    /// `battery & 0x80` = charging flag (not currently forwarded; surfacing
    /// it needs a struct payload — tracked for a future minor version).
    ///
    /// [DISCREPANCY vs C-REF]: [C-REF] drops frames where `battery == 0`
    /// as a firmware-workaround for spurious zero readings. We pass them
    /// through as `battery(percent: 0)` and let the session decide; zero
    /// is noted in [C-REF] as unreliable, so callers should display "—"
    /// rather than "0 %" for zero values.
    private func processBatteryFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count >= 4 else { return [.raw(Data(frame))] }
        let raw = frame[2]
        let percent = Int(raw & 0x7F)
        return [.battery(percent: percent)]
    }

    // MARK: - Stored-game import

    /// Handle a `0x32 01 <count>` file-count reply. Remembers how many games
    /// are on flash and, if any, enters upload mode and requests the first.
    /// [C-REF] `getFileCount` reads the count from byte 2.
    private mutating func processFileCountReply(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count >= 3 else { return [.raw(Data(frame))] }
        filesRemaining = Int(frame[2])
        guard filesRemaining > 0 else { return [] }   // no stored games
        // Enter upload mode once (0x21 01 01), then request the first game.
        pendingResponses.append(Data([Opcode.mode, 0x01, 0x01]))
        queueNextGameRequest()
        return []
    }

    /// Queue the per-game request pair the board expects before each transfer:
    /// `0x33 01 00` (ready for import) then `0x34 01 01` (start import).
    /// [C-REF] `getFile` writes exactly this pair per file.
    private mutating func queueNextGameRequest() {
        pendingResponses.append(Data([Opcode.readyForImport, 0x01, 0x00]))
        pendingResponses.append(Data([Opcode.startImport, 0x01, 0x01]))
    }

    /// Handle a `0x37 01 BE|ED` file-transfer flag. `BE` opens a game (start
    /// buffering snapshots); `ED` closes it — reconstruct the buffered
    /// snapshots and, if more games remain, request the next.
    /// [C-REF] notification handler: `0x37 01 BE` begin, `0x37 01 ED` end.
    private mutating func processFileFlagFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count >= 3 else { return [.raw(Data(frame))] }
        switch frame[2] {
        case 0xBE:
            fileTransferActive = true
            fileSnapshots.removeAll(keepingCapacity: true)
            return []
        case 0xED:
            fileTransferActive = false
            let event = reconstructBufferedGame()
            filesRemaining = max(0, filesRemaining - 1)
            if filesRemaining > 0 { queueNextGameRequest() }
            fileSnapshots.removeAll(keepingCapacity: true)
            return event.map { [$0] } ?? []
        default:
            return [.raw(Data(frame))]
        }
    }

    /// Decode one `0x01` snapshot frame into the file buffer during transfer.
    private mutating func accumulateFileSnapshot(_ frame: [UInt8]) {
        guard frame.count >= 34 else { return }
        let (identity, _) = chessnutDecodeBoard(from: frame, start: 2)
        fileSnapshots.append(identity)
    }

    /// Reconstruct the buffered snapshots into a `.storedGameImported` event, or
    /// `nil` for an empty buffer (firmware quirk — nothing to import).
    private func reconstructBufferedGame() -> BoardEvent? {
        guard !fileSnapshots.isEmpty else { return nil }
        switch ChessnutStoredGameDecoder.reconstruct(snapshots: fileSnapshots) {
        case .success(let reconstruction):
            return .storedGameImported(
                moves: reconstruction.moves,
                sanMoves: reconstruction.sanMoves,
                isComplete: reconstruction.isComplete
            )
        case .failure:
            // The stream did not start from the initial position, so no moves
            // could be anchored. Surface an empty, incomplete import so the
            // caller can report an unreadable game rather than dropping it.
            return .storedGameImported(moves: [], sanMoves: [], isComplete: false)
        }
    }

    /// Mandatory out-of-band responses queued while parsing the last
    /// `feed(bytes:)` — the download-handshake steps. The transport drains this
    /// after every `feed` and writes each value to the command characteristic.
    public mutating func takePendingResponses() -> [Data] {
        defer { pendingResponses.removeAll(keepingCapacity: true) }
        return pendingResponses
    }

    // MARK: - LED encoding

    /// Encode an LED command for the Chessnut Air family.
    ///
    /// Format: `0A 08 R8 R7 R6 R5 R4 R3 R2 R1` (10 bytes).
    /// Within each rank byte: bit 7 (MSB) = a-file … bit 0 (LSB) = h-file.
    /// I.e., `mask = 0x80 >> fileIndex` (a=0).
    ///
    /// Bit-order confirmation from two independent sources:
    ///   [C-REF] README c4 example: `leds[4] = "00100000"` (leftmost char
    ///   = column a = MSB via `bitset<8>(string)`) → rank-4 byte `0x20`.
    ///   [SWIFT-REF] `testClassicLEDCommandUsesEightBitRows`: fileIndex=2
    ///   → `[0x0A, 0x08, 0,0,0,0, 0x20, 0,0,0]` for c4.
    ///
    /// All LEDs off → empty `squares` array → bytes[2..9] all zero.
    private func encodeLED(squares: [String]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = Opcode.led
        bytes[1] = 0x08   // payload length = 8 rank bytes
        for square in squares {
            guard let sq = Square(algebraic: square) else { continue }
            let fileIdx = sq.file          // a=0…h=7
            let rank0   = sq.rank          // 0-indexed: 0=rank-1…7=rank-8
            // byte[2] = rank 8 (rank0 = 7), byte[9] = rank 1 (rank0 = 0)
            let byteIdx = 9 - rank0
            let mask: UInt8 = 0x80 >> UInt8(fileIdx)
            bytes[byteIdx] |= mask
        }
        return Data(bytes)
    }

    // MARK: - Index conversion helpers

    /// Convert a Chessnut protocol square index `s` (0=h8…63=a1) to the
    /// file-major index used by `BoardEvent` (a1=0…h8=63).
    ///
    /// Delegates to `chessnutProtocolSquareToFileMajor` in ChessnutShared.swift.
    /// Kept as a public-facing static on the type for backward compatibility
    /// with test code that calls `ChessnutAdapter.protocolSquareToFileMajor`.
    ///
    /// Sentinel checks (from spec):
    ///   s=0  → h8 → fileMajor=63
    ///   s=63 → a1 → fileMajor=0
    ///   s=35 → e4 → fileMajor=35
    ///   s=59 → e1 → fileMajor=32
    static func protocolSquareToFileMajor(_ s: Int) -> Int {
        chessnutProtocolSquareToFileMajor(s)
    }
}
