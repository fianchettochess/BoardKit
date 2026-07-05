import Foundation
import ChessCore
import BoardKit

// ── ChessUp BLE adapter ───────────────────────────────────────────────────────
//
// Implements `BoardAdapter` for the ChessUp (gen-1) smart chess board.
// The board communicates over BLE using the Nordic UART Service (NUS) profile.
// Provides per-square RGB LED indication via opcode 0x99 (show move) and the
// 0x10 assistance frame; occupancy sensing via 0x67 snapshot, 0xFD FD stream,
// and 0xA3 move events.
//
// ⚠️  HARDWARE STATUS: Protocol-verified against three pinned sources (see below);
//     awaiting physical-board or capture-log validation.
//
// ⚠️  ChessUp 2 HARDWARE COVERAGE: EXPLICITLY UNVERIFIED. Every byte in this
//     file was derived from ChessUp-1-era sources. Only circumstantial evidence
//     (Bryght Labs engineer tool chessup-pc, Apr-2026) suggests CU2 keeps the
//     NUS transport, device name prefix "ChessUp", and opcode 0xB2 board-info.
//     All other CU2 frame semantics are UNKNOWN. Runtime-probe: send GET_STATE
//     (0x67); if a 73-byte 0x67 reply arrives, CU1 profile is live. Capture
//     the 0xB2 model string and surface it in telemetry for CU2 divergence
//     diagnosis. ChessUp 2 support is flagged experimental/unsupported until
//     hardware-verified.
//
// Sources:
//   [PRIMARY]    mono424/chessupdriver @ 589d43ad2b5eb32b1bcdcca9db2b4909efe5d9bb
//                (MIT © 2022 Khadim Fall) — code may be adapted with attribution.
//   [FACTS-ONLY] atomice1/bluecheese   @ 0df95887a59f5222dd021f67b5fab3832640aa31
//                (GPL-3.0 / LGPL-3.0 file headers) — protocol constants and
//                semantics re-expressed from spec facts; no code or comment
//                structure copied.
//   [FACTS-ONLY] Kevin-BryghtLabs/chessup-pc @ 522bebe2 (no license, all rights
//                reserved) — UUID/name/opcode facts only; no code copied.

// MARK: - GATT constants

/// BLE GATT constants for ChessUp boards (Nordic UART Service profile).
///
/// ## Device name filter
///
/// Both community sources confirm the name, with differing strictness:
/// chessup-pc matches exactly `"ChessUp"`; bluecheese uses `startsWith("ChessUp")`.
/// Prefix match is used here to tolerate firmware variants. [FACTS-ONLY: both]
///
/// ## MTU
///
/// Request MTU ≥ 247 immediately after connect. The 0x66 set-state frame is
/// ~57 bytes; at BLE's default 23-byte ATT MTU the write would fragment, and
/// fragmentation behaviour is untested on ChessUp firmware. Marked "Important"
/// in the primary source. [PRIMARY]
///
/// ## Single notify characteristic
///
/// [DISCREPANCY D8] The primary README sketches a second notify char for an
/// "ack stream" (`readB`) — dead code; the actual example uses only `...0003`.
/// NUS has one notify char. FOLLOW: single notify char; treat README as stale.
public enum ChessUpGATT {
    /// Nordic UART Service UUID (NUS).
    /// [PRIMARY] chessupdriver; [FACTS-ONLY] bluecheese, chessup-pc.
    public static let nusService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Host-to-board write characteristic (Write-With-Response). [PRIMARY]
    public static let nusRX      = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Board-to-host notify characteristic (subscribe via CCCD `01 00`). [PRIMARY]
    public static let nusTX      = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Standard BLE Battery Service UUID (read + notify). [FACTS-ONLY: bluecheese]
    public static let batteryService = "0000180F-0000-1000-8000-00805F9B34FB"
    /// Battery Level characteristic. [FACTS-ONLY: bluecheese]
    public static let batteryLevel   = "00002A19-0000-1000-8000-00805F9B34FB"
    /// Requested ATT MTU. [PRIMARY "Important"] See class-level doc.
    public static let requestedMTU: Int = 247

    /// Returns `true` when `name` matches the ChessUp advertising-name pattern.
    ///
    /// Prefix match to tolerate firmware variants. [see D-name note above]
    public static func isChessUp(name: String) -> Bool {
        name.hasPrefix("ChessUp")
    }
}

// MARK: - Inbound frame length table
//
// [DISCREPANCY D1] 0x67 frame length: primary declares 72 (off-by-one bug); its
// own parser reads byte index 72 (73rd byte), surviving only via resync; the stray
// fullmove byte can alias a phantom opcode (e.g. 0x22 fake move-ack). bluecheese
// reads a proper 73-byte frame. FOLLOW: 73 bytes.
//
// [DISCREPANCY D2] Board-side promotion: primary defines an unreachable
// `A3 35`-prefixed 3-byte message (its 0xA3 len-6 parser matches first, making
// the 3-byte variant dead code). bluecheese uses `97` len 2, which was actually
// exercised. FOLLOW: `97` len 2.
//
// Unknown leading byte: skip one byte and rescan. [PRIMARY] resync strategy.
// Required because the NUS notify pipe has no frame length prefix or CRC.

private func chessUpFrameLength(forOpcode opcode: UInt8) -> Int? {
    switch opcode {
    case 0x22: return 1   // move-shown ack (response to host 0x99). [PRIMARY]
    case 0x23: return 1   // promotion ack (host←→board 0x97 exchange). [PRIMARY+FACTS-ONLY]
    case 0x24: return 1   // generic OK. [FACTS-ONLY: bluecheese]
    case 0x33: return 2   // battery charging: [33, 0/1]. [PRIMARY]
    case 0x67: return 73  // full board state — 73 bytes. [see D1] [PRIMARY+FACTS-ONLY]
    case 0x97: return 2   // board-side promotion pick [see D2]. [FACTS-ONLY: bluecheese]
    case 0xA3: return 6   // move on board: [A3, sub, fromCol, fromRow, toCol, toRow]. [PRIMARY]
    case 0xB0: return 2   // pieces in start position: [B0, 0/1]. [PRIMARY]
    case 0xB1: return 1   // FEN load / set-state complete. [PRIMARY]
    case 0xB2: return 17  // board info: [B2] + 16 ASCII model chars. [PRIMARY+FACTS-ONLY: chessup-pc]
    case 0xB8: return 3   // piece touched (capacitive): [B8, squareIdx, pieceCode]. [PRIMARY+FACTS-ONLY]
    case 0xBB: return 1   // piece released (all touches ended). [PRIMARY]
    case 0xBD: return 1   // undo/takeback performed on board. [FACTS-ONLY: bluecheese]
    default:   return nil
    }
}

// MARK: - Piece code table
//
// Shared by 0x67 body (occupancy derivation) and 0xB8 capacitive-touch events.
// Used for occupancy classification only: code == 0x40 → empty, else occupied.
// Piece type/colour are NOT surfaced (no .pieceIdentity capability declared).
//
// [PRIMARY] chessupdriver PieceType enum; [FACTS-ONLY] bluecheese PIECE_* consts.
//
// White: 0x00=P  0x01=R  0x02=N  0x03=B  0x04=Q  0x05=K
// Black: 0x08=p  0x09=r  0x0A=n  0x0B=b  0x0C=q  0x0D=k
// Empty: 0x40
//
// Promotion-opcode 0x97 scale: 1=R, 2=N, 3=B, 4=Q (numerically matches white
// codes 01..04 — both sources agree).

// MARK: - ChessUpAdapter

/// BLE board adapter for the ChessUp smart chess board (gen-1).
///
/// ## Capabilities
///
/// | Capability       | ChessUp |
/// |------------------|---------|
/// | occupancySensing | ✓       |  via 0x67 snapshot, 0xFD stream, 0xA3 move events
/// | pieceIdentity    |         |  protocol has piece codes; not declared per product spec
/// | perSquareLEDs    |         |  NOT declared — see LED note below
/// | moveIndication   | ✓       |  0x99 lights from + to squares on board
/// | motorised        |         |  not applicable; executeMove → nil
/// | batteryReporting |         |  0x33 carries charging flag only, not percentage
///
/// ## Why `.perSquareLEDs` is not declared
///
/// `BoardCapabilities.perSquareLEDs` contracts that `BoardCommand.indicateSquares`
/// is **fully honoured** and every listed square can be lit independently.
/// ChessUp cannot meet that contract for two reasons:
///
/// 1. **0x99 only accepts exactly 2 squares.** Empty-array (clear-all-LEDs per
///    the `indicateSquares` doc), 1-square, and 3+-square calls all return `nil`.
///
/// 2. **0x99 is a remote-move injection command, not a pure LED command.**
///    Both sources confirm it is used by the board's `whiteRemote`/`blackRemote`
///    game modes to inject the engine's reply move into the board's active game
///    state, and also updates the LEDs as a side-effect. Sending it for arbitrary
///    squares (not the actual reply move) will disturb the board's game state.
///
/// The Millennium board is the repo precedent: it sets `.moveIndication` without
/// `.perSquareLEDs` because its 9×9 corner-LED grid does not meet the per-square
/// contract. `.moveIndication` is the correct declaration here.
///
/// ## LED note: using 0x99 safely
///
/// `indicateSquares(["e2","e4"], style:)` produces `[0x99, fromIdx, toIdx]` and
/// is the correct way to light the board's reply-move squares **in remote-move
/// mode** (`whiteRemote`/`blackRemote` = 1 in the active game settings). Only call
/// this to display the board's own reply move — the board treats 0x99 as a move
/// injection and will update its internal game state accordingly.
///
/// ## LED colour palette (0x99 path)
///
/// The board firmware controls the from/to RGB colours (typically green for
/// from-square, yellow/orange for to-square); the `LEDStyle` parameter is advisory
/// and has no wire effect on the 0x99 path.
///
/// For programmatic per-move colour control, use `rgbAssistanceData(colours:)` to
/// build a `0x10` frame and send it via `BoardCommand.custom(_:)`:
/// - colour `0` (Red)   → `.danger`    (blunder / threat emphasis)
/// - colour `1` (Blue)  → `.highlight` (neutral suggestion)
/// - colour `2` (Green) → `.moveFrom` / `.moveTo` (best move / destination)
///
/// The `0x10` command is a "Touch & Learn" hint for ALL legal moves ordered by
/// canonical from→to index; it is not a general arbitrary-square LED command.
///
/// ## Square indexing — the mirror trap
///
/// **Canonical index** (0x67 body, 0x99, 0xB8):
/// `idx = rank0indexed * 8 + file`, file a=0…h=7.  a1=0, h1=7, a2=8, …, h8=63.
///
/// **0xA3 frame** (move on board): `[A3, sub, fromCol, fromRow, toCol, toRow]`.
/// col = file (a=0…h=7), row = rank 0-indexed (rank1=0, rank8=7).
/// **NOT** a single-byte canonical index — do not confuse with 0x99.
///
/// **Occupancy bitmap** (0xFD 0xFD): rank-REVERSED — byte 0 = rank 8, byte 7 =
/// rank 1; within each byte LSB (bit 0) = file a … bit 7 = file h.
///
/// ## Ack discipline
///
/// **0xA3 move frames**: The board retransmits 0xA3 until it receives a `0x21`
/// ack. The adapter deduplicates consecutive identical 0xA3 frames (no
/// double-event). The transport MUST send `ChessUpAdapter.ackMoveData()`
/// (`Data([0x21])`) using a **write-with-response** characteristic write after
/// **every raw 0xA3 BLE notification** it receives — not just once per
/// adapter-emitted event pair. If the first write is lost, the dedup guard
/// means no further events arrive to trigger a retry; only the transport,
/// operating below the dedup layer, can guarantee delivery. This reproduces
/// bluecheese's until-confirmed ack-loop guarantee. [FACTS-ONLY: bluecheese]
///
/// **0x97 board-side promotion frames**: The board sends `[0x97, piece]` when
/// the player promotes a pawn. The transport MUST ack with
/// `ChessUpAdapter.ackBoardPromotionData()` (`Data([0x23])`) after every raw
/// 0x97 notification. The adapter surfaces 0x97 as `.raw`; the transport
/// MUST inspect raw frames for `raw[0] == 0x97` and write the ack. See the
/// `ackBoardPromotionData()` doc for the workaround contract. A fully typed
/// `BoardEvent.promotion` case (medium-term fix) would carry the ack
/// requirement in the API rather than comments.
///
/// ## Hardware status
///
/// Protocol-verified against [PRIMARY] mono424/chessupdriver (MIT) and
/// corroborated by [FACTS-ONLY] bluecheese and chessup-pc. All golden fixtures
/// (F1–F9 from the pinned spec) are exercised in `ChessUpAdapterTests.swift`.
/// Awaiting physical-board or BLE capture-log validation.
/// ChessUp 2 support is flagged experimental until hardware-verified — see the
/// top-of-file warning.
public struct ChessUpAdapter: BoardAdapter {

    // MARK: - State

    /// Raw byte accumulator for frame reassembly across BLE notification boundaries.
    /// The NUS notify pipe is a raw byte stream; notifications may coalesce or split
    /// frames. Buffer + opcode→length dispatch handles both cases.
    private var buffer: [UInt8] = []

    /// `true` before the first 0x67 board-state frame is received in this connect
    /// cycle. Re-armed by `resetFraming()` so each connect emits exactly one `.ready`.
    private var isFirstStateFrame: Bool = true

    /// Last 0xA3 frame bytes for dedup (board retransmits until acked).
    ///
    /// [DISCREPANCY D7] primary acks once per parsed message; bluecheese loops the
    /// 0x21 write until the BLE write is confirmed AND dedups retransmitted frames.
    /// FOLLOW: ack every 0xA3 promptly AND dedup consecutive identical frames.
    ///
    /// Cleared by: `resetFraming()` (link drop), 0xBD undo, 0xB1 FEN-load
    /// complete, and 0x67 board-state snapshot. After any of these, the next
    /// 0xA3 — even if byte-identical to the previous one — must NOT be
    /// suppressed as a retransmit. bluecheese clears its equivalent field
    /// (`m_previousMove`) on `setBoardState` for exactly this reason.
    private var lastA3Frame: [UInt8] = []

    // MARK: - BoardAdapter conformance

    public var capabilities: BoardCapabilities { .chessUp }

    public init() {}

    /// Feed raw BLE notification bytes through the ChessUp frame parser.
    ///
    /// Reassembles the NUS byte stream via a rolling buffer. Dispatch:
    /// - `0xFD 0xFD` (10 bytes): occupancy bitmap → `occupancySnapshot`
    /// - `0x67` (73 bytes):      full board state → `occupancySnapshot` (+ `.ready` on first)
    /// - `0xA3` (6 bytes):       move on board    → two `squareSensed` events; dedup
    /// - `0x33`, `0xB8`, `0xBB`, acks, `0xB2`, `0x97`, other:  → `raw(data)`
    /// - Unknown leading byte:   skip one byte and rescan (primary's resync strategy)
    public mutating func feed(bytes: Data) -> [BoardEvent] {
        buffer.append(contentsOf: bytes)
        var events: [BoardEvent] = []
        while !buffer.isEmpty {
            // Two-byte prefix 0xFD 0xFD — occupancy stream. Handle before single-byte
            // dispatch to avoid misrouting 0xFD as an unknown opcode.
            if buffer[0] == 0xFD {
                guard buffer.count >= 2 else { break }   // wait for second byte
                if buffer[1] == 0xFD {
                    guard buffer.count >= 10 else { break }
                    let frame = Array(buffer.prefix(10))
                    buffer.removeFirst(10)
                    events += processOccupancyFrame(frame)
                } else {
                    // 0xFD followed by a non-0xFD byte: unknown; skip 0xFD and rescan.
                    buffer.removeFirst()
                }
                continue
            }
            // Single-byte opcode dispatch.
            guard let len = chessUpFrameLength(forOpcode: buffer[0]) else {
                // Unknown opcode: skip one byte and rescan. [PRIMARY] resync strategy.
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= len else { break }
            let frame = Array(buffer.prefix(len))
            buffer.removeFirst(len)
            events += processFrame(frame)
        }
        return events
    }

    /// Encode a `BoardCommand` to its ChessUp wire representation.
    ///
    /// ## Mapping
    /// ```
    /// .startSession              → Data([0x67])         GET_STATE / handshake probe
    /// .requestState              → Data([0x67])         GET_STATE
    /// .indicateSquares([f,t], _) → Data([0x99, f, t])  show move on board LEDs
    /// .indicateSquares(≠2, _)   → nil                  unsupported (see LED note)
    /// .executeMove               → nil                  not motorised
    /// .custom(data)              → data verbatim
    /// ```
    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession:
            // GET_STATE: handshake probe. Board replies with a 73-byte 0x67 frame;
            // the first reply triggers .ready emission.
            // [DISCREPANCY D5] primary sends bare 0x67; bluecheese sends 0x67 0x00.
            // Both accepted by the firmware — send bare. FOLLOW: primary. [PRIMARY]
            return Data([0x67])

        case .requestState:
            return Data([0x67])

        case .indicateSquares(let squares, _):
            // Two-square path: encode as 0x99 [fromCanonical] [toCanonical].
            // [PRIMARY] MoveToBoardMessage; [FACTS-ONLY] bluecheese requestMove.
            //
            // ⚠️  0x99 is a remote-move INJECTION command, not a pure LED command.
            // Both sources confirm that 0x99 is used by the board's whiteRemote /
            // blackRemote game modes to inject the engine reply move into the board's
            // active game state; the LED update is a side-effect. Calling this for
            // arbitrary squares (not the actual board reply move) will disturb the
            // board's internal game state. Only use indicateSquares to display the
            // engine's actual reply move in remote-move mode.
            //
            // NOTE: The LEDStyle parameter is advisory only in this path — the
            // board firmware controls from/to RGB colours via 0x99; the host has
            // no colour selection. For per-colour control, use rgbAssistanceData
            // via .custom. See class-level LED colour palette documentation.
            guard squares.count == 2,
                  let fromIdx = Self.squareToCanonicalIdx(squares[0]),
                  let toIdx   = Self.squareToCanonicalIdx(squares[1]) else {
                // ChessUp has no general per-square arbitrary-colour LED command:
                // 0x10 requires the full legal-move list; 0x99 only takes 2 squares.
                // Return nil so the transport silently skips unsupported calls.
                return nil
            }
            return Data([0x99, fromIdx, toIdx])

        case .executeMove:
            // ChessUp is not motorised. [PRIMARY] no auto-move command defined.
            return nil

        case .custom(let data):
            return data
        }
    }

    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)] {
        if isReconnect {
            // Allow 250 ms for the BLE link to stabilise, then reprobe state.
            // Pattern mirrors ChessnutAdapter's reconnect delay.
            return [(.startSession, 0.25)] // 250ms
        }
        // First connect: probe immediately (no required delay before GET_STATE).
        return [(.startSession, 0)]
    }

    /// Reset the framing buffer and per-session state.
    ///
    /// Call this when the BLE link drops and is about to be re-established —
    /// before running `handshakeCommands(isReconnect: true)`. Clears:
    ///
    /// - `buffer`: any partial-frame bytes from the dropped link that would
    ///   desync the stream parser on the first post-reconnect notification.
    ///
    /// - `isFirstStateFrame`: re-arms `.ready` so the new connect cycle emits
    ///   exactly one `.ready` (on the first 0x67 response to GET_STATE).
    ///
    /// - `lastA3Frame`: clears the 0xA3 dedup guard so the first move on the
    ///   new link is never suppressed as a duplicate.
    public mutating func resetFraming() {
        buffer = []
        isFirstStateFrame = true
        lastA3Frame = []
    }

    // MARK: - Static wire helpers (ChessUp-specific command encoders)

    /// Encode a `0xB9` game-settings frame.
    ///
    /// [DISCREPANCY D6] `deviceUser` is always sent (primary) vs conditional
    /// (bluecheese). FOLLOW: always send — fixed-size frames are safer, and
    /// the primary's shipped White Pawn app always sends it. [PRIMARY]
    ///
    /// Known primary bug: its `setWhiteSettings()` helper mistakenly emits the
    /// black opcode 0xB4 instead of 0xB3. The wire opcodes 0xB3=white / 0xB4=black
    /// are what the message classes define — use those, not the buggy helper.
    ///
    /// [PRIMARY] GameSettings.toBytes(); [FACTS-ONLY] bluecheese requestNewGame
    /// corroborates field positions.
    ///
    /// - Parameters:
    ///   - mode: GameType+1 (1=phoneAI, 2=remote, 3=remote2, 4=lesson, 5=phoneOTB,
    ///     6=builtInAI, 7=noPhoneOTB). bluecheese MODE_LOCAL=5.
    ///   - whiteType: 0=human, 1=AI.
    ///   - whiteLevel: AI difficulty 1–30 or human assistance level 1–6.
    ///   - whiteLock: Button-lock 0=off, 1=on.
    ///   - blackType / blackLevel / blackLock: Same semantics as white counterparts.
    ///   - hintLimit: 0 (no hints) to 0xFF (≈unlimited per bluecheese). Semantics unpinned.
    ///   - whiteRemote: 1 = white's moves come from app/network via 0x99.
    ///   - blackRemote: 1 = black's moves come from app/network via 0x99.
    ///   - deviceUser: 0 = white holds the device, 1 = black. Always sent.
    public static func gameSettingsData(
        mode: UInt8,
        whiteType: UInt8, whiteLevel: UInt8, whiteLock: UInt8,
        blackType: UInt8, blackLevel: UInt8, blackLock: UInt8,
        hintLimit: UInt8,
        whiteRemote: UInt8, blackRemote: UInt8,
        deviceUser: UInt8
    ) -> Data {
        Data([
            0xB9, mode,
            whiteType, whiteLevel, whiteLock,
            blackType,  blackLevel, blackLock,
            hintLimit, whiteRemote, blackRemote, deviceUser,
        ])
    }

    /// Encode a `0x66` load-FEN frame (primary framing).
    ///
    /// Format: `[0x66] + ASCII("/" + fen4 + " ") + [halfmoveByte, fullmoveByte]`
    /// where `fen4 = field1 SP field2 SP field3 SP field4` (the first 4 FEN fields).
    ///
    /// [DISCREPANCY D4] bluecheese uses a different 0x66 tail (length-prefixed,
    /// 2-byte big-endian fullmove, no leading "/"). PRIMARY framing is followed here
    /// (MIT reference, simpler, demonstrated in the White Pawn app). If `0xB1` never
    /// arrives after sending this frame, switch to the bluecheese variant.
    /// Note: fullmove > 255 is unrepresentable in the primary framing (1-byte field).
    ///
    /// Board replies with `0xB1` (FEN load complete) when ready. [PRIMARY]
    ///
    /// - Parameter fen: A standard FEN string with all 6 space-separated fields.
    /// - Returns: `nil` if `fen` cannot be parsed or halfmove/fullmove exceed 255.
    public static func loadFENData(fen: String) -> Data? {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 6,
              let halfmove = UInt8(fields[4]),
              let fullmove = UInt8(fields[5]) else { return nil }
        let fen4 = [fields[0], fields[1], fields[2], fields[3]].joined(separator: " ")
        let ascii = "/" + fen4 + " "
        guard let body = ascii.data(using: .ascii) else { return nil }
        var result = Data([0x66])
        result.append(body)
        result.append(contentsOf: [halfmove, fullmove])
        return result
    }

    /// Encode a `0x10` RGB assistance (Touch & Learn hint) frame.
    ///
    /// [FACTS-ONLY: bluecheese sendAssistance, GPL-3.0/LGPL-3.0 — re-expressed
    /// from spec facts; no code copied.]
    ///
    /// ⚠️  MEDIUM confidence — single source (bluecheese only). Hardware-verify
    /// the move-ordering contract (ascending by canonical from-idx then to-idx)
    /// before relying on this in production. Risk R2 from the pinned spec.
    ///
    /// The board applies these colours to destination squares when the player
    /// touches a piece ("Touch & Learn" mode). `colours` must be ordered by
    /// the board firmware's legal-move enumeration: ascending by canonical
    /// from-idx (a1=0) then to-idx.
    ///
    /// Packing: 4 entries per byte, MSB-pair first:
    /// `colour_i = (byte[2 + i/4] >> (6 - 2*(i%4))) & 0x3`
    ///
    /// LED colour palette (for mapping `LEDStyle` to a colour value):
    /// - `0` = Red   → `.danger`     (blunder / threat)
    /// - `1` = Blue  → `.highlight`  (neutral suggestion)
    /// - `2` = Green → `.moveFrom` / `.moveTo`  (best move / destination)
    ///
    /// - Parameter colours: Per-move colour values (0=Red, 1=Blue, 2=Green),
    ///   one entry per legal move, sorted by canonical from→to index ascending.
    public static func rgbAssistanceData(colours: [UInt8]) -> Data {
        let count = colours.count
        let byteCount = (count + 3) / 4   // ceil(count / 4)
        var bytes = [UInt8](repeating: 0, count: 2 + byteCount)
        bytes[0] = 0x10
        bytes[1] = UInt8(min(count, 255))
        for i in 0..<count {
            let shift = UInt8(6 - 2 * (i % 4))
            bytes[2 + i / 4] |= (colours[i] & 0x03) << shift
        }
        return Data(bytes)
    }

    /// The `0x21` ack byte the transport MUST send after every 0xA3-derived
    /// move-event pair.
    ///
    /// The board retransmits 0xA3 frames until it receives this ack. Failure
    /// to send it promptly will wedge the board. Consecutive identical 0xA3
    /// frames are deduplicated by the adapter (no double-event emitted), but
    /// the transport MUST still ack every raw 0xA3 notification received.
    ///
    /// Usage: `transport.send(ChessUpAdapter.ackMoveData())`
    public static func ackMoveData() -> Data {
        Data([0x21])
    }

    /// The `0x23` ack byte the transport MUST send after every board-side 0x97
    /// promotion-pick frame.
    ///
    /// The board sends `[0x97, piece]` when the player promotes a pawn. The adapter
    /// surfaces it as `.raw` (see class-level ack discipline note). Because
    /// `BoardEvent.raw`'s contract forbids session code from branching on it, the
    /// transport — which operates below the session — MUST inspect raw BLE
    /// notification bytes for the 0x97 opcode directly and send this ack.
    ///
    /// Temporary workaround: check `rawNotification[0] == 0x97` and write this
    /// data using write-with-response on the NUS TX characteristic. A typed
    /// `BoardEvent.promotion` case is the medium-term fix and will carry this
    /// ack requirement in the API rather than comments.
    ///
    /// Usage: `transport.send(ChessUpAdapter.ackBoardPromotionData())`
    public static func ackBoardPromotionData() -> Data {
        Data([0x23])
    }

    /// Encode a host-side promotion command.
    ///
    /// Piece scale: 1=R, 2=N, 3=B, 4=Q (coincidentally matches white piece codes).
    /// Board replies with opcode `0x23` (promotion ack). [PRIMARY] PawnPromotionMessage;
    /// [FACTS-ONLY] bluecheese requestPromotion.
    ///
    /// - Parameter piece: 1=Rook, 2=Knight, 3=Bishop, 4=Queen.
    public static func promotionData(piece: UInt8) -> Data {
        Data([0x97, piece])
    }

    /// Enable the raw occupancy stream (`0xFD 0xFD` notifications).
    ///
    /// After sending, the board streams 10-byte `0xFD 0xFD + 8bytes` frames on
    /// occupancy changes/periodically. Single-source — MEDIUM confidence. [PRIMARY]
    public static var enableRawStreamData: Data { Data([0x50]) }

    /// Encode a game-result / win-on-time / resignation command.
    /// `winnerColour`: 0=white, 1=black. [PRIMARY] GameResultMessage.
    public static func resultData(winnerColour: UInt8) -> Data { Data([0xB6, winnerColour]) }

    /// Encode a game-end-reason command.
    ///
    /// Reasons: 1=whiteMate 2=whiteTime 3=whiteResigns 4=blackMate 5=blackTime
    /// 6=blackResigns 7=drawAgreed 8=threefold 9=fiftyMove 10=insufficient
    /// 11=stalemate. [PRIMARY]
    public static func gameEndData(reason: UInt8) -> Data { Data([0x52, reason]) }

    /// Encode a reset-game command. [PRIMARY]
    public static var resetGameData: Data { Data([0x64]) }

    // MARK: - Encode/decode helper: occupancy bitmap (for testing and tooling)

    /// Encode a file-major occupancy array to a 10-byte `0xFD 0xFD` frame.
    ///
    /// Inverse of the `0xFD 0xFD` decoder in `processOccupancyFrame`. Used by
    /// test harnesses and capture-log tooling — the board pushes these, not the host.
    ///
    /// Bitmap layout (RANK-REVERSED — the mirror trap):
    /// - `frame[2]` = rank 8 occupancy byte (rank0-idx=7)
    /// - `frame[9]` = rank 1 occupancy byte (rank0-idx=0)
    /// - Within each byte: bit `f` (LSB-first) = file f (a=0…h=7).
    ///
    /// - Parameter occupied: 64-element file-major array (a1=index0…h8=index63).
    public static func encodeOccupancyFrame(occupied: [Bool]) -> Data {
        precondition(occupied.count == 64, "occupied must be 64 elements")
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = 0xFD
        bytes[1] = 0xFD
        for file in 0..<8 {
            for rank in 0..<8 {   // rank: 0-indexed (0=rank1, 7=rank8)
                guard occupied[file * 8 + rank] else { continue }
                let byteIdx = 7 - rank   // payload[7-rank] encodes that rank
                bytes[2 + byteIdx] |= (1 << file)
            }
        }
        return Data(bytes)
    }

    // MARK: - Frame processing (board → host)

    private mutating func processFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard !frame.isEmpty else { return [] }
        switch frame[0] {
        case 0x67:
            return processBoardStateFrame(frame)
        case 0xA3:
            return processMoveFromBoardFrame(frame)
        case 0x33:
            // Battery-charging status [B0, 0/1]: carries only a flag, not a
            // percentage. BoardEvent.battery(percent:) requires a percentage, so
            // this frame is forwarded as raw. [PRIMARY] BatteryChargingMessage.
            return [.raw(Data(frame))]
        case 0xB8, 0xBB:
            // Capacitive touch (B8) and release (BB) events are supplementary to
            // the primary occupancy events (0x67, 0xFD stream, 0xA3). They are
            // forwarded as raw for debug logging; the session should not branch
            // on them for occupancy tracking.
            return [.raw(Data(frame))]
        case 0x22, 0x23, 0x24:
            // Acks for host commands (99/97) and generic OK: forward as raw so
            // the transport can observe command completion.
            return [.raw(Data(frame))]
        case 0xB0:
            // Start-position present/absent notification. Forward as raw.
            return [.raw(Data(frame))]
        case 0xB1:
            // FEN load complete: forward as raw. (.ready fires on the 0x67
            // handshake response, not on mid-session FEN loads.)
            //
            // Clear the A3 dedup guard: after a FEN reload the player can
            // legitimately replay the same move that was last seen before the
            // reload. Failing to clear would suppress that move as a retransmit.
            lastA3Frame = []
            return [.raw(Data(frame))]
        case 0xB2:
            // Board info: 16-char ASCII model string (e.g. "ChessUp 1.0.0   ").
            // Forward as raw; callers extract the model string for CU1/CU2 diagnosis.
            // [PRIMARY+FACTS-ONLY: chessup-pc (manufacturer tool) confirms presence.]
            return [.raw(Data(frame))]
        case 0x97:
            // Board-side promotion pick: [97, piece 1..4]. Host MUST ack with 0x23.
            // [FACTS-ONLY: bluecheese; see D2 for why this is not 0xA3-based.]
            //
            // ⚠️  ACK WORKAROUND: Forwarded as .raw because BoardEvent has no typed
            // promotion case. The transport MUST inspect every .raw frame for
            // raw[0] == 0x97 and send ackBoardPromotionData() (Data([0x23])) on
            // every occurrence. See class-level ack discipline note and
            // ackBoardPromotionData() doc. This workaround is temporary; a typed
            // BoardEvent.promotion case is the medium-term fix.
            return [.raw(Data(frame))]
        case 0xBD:
            // Undo/takeback performed on board. [FACTS-ONLY: bluecheese]
            //
            // Clear the A3 dedup guard: after a board-side takeback the player
            // can legitimately replay the identical move. bluecheese clears
            // m_previousMove on setBoardState for exactly this reason.
            lastA3Frame = []
            return [.raw(Data(frame))]
        default:
            return [.raw(Data(frame))]
        }
    }

    /// Decode a 73-byte `0x67` board-state frame into an occupancy snapshot.
    ///
    /// Frame layout:
    /// `[67][64 piece codes: a1,b1,...,h8][turn][wK][wQ][bK][bQ][ep][half][full]`
    ///
    /// Piece codes in canonical order (a1=offset1…h8=offset64); `0x40` = empty,
    /// any other code = occupied. The board's FEN-state tail (offsets 65–72) is
    /// parsed for occupancy only; ep, castling, and turn are not surfaced since
    /// this adapter does not declare `.pieceIdentity`.
    ///
    /// [DISCREPANCY D1] primary declares length 72 (off-by-one bug); follow 73.
    /// [DISCREPANCY D3] ep byte (offset 70): primary uses boolean; bluecheese uses
    /// square idx. This adapter derives occupancy only and does not inspect ep.
    ///
    /// The first 0x67 frame in each connect cycle also emits `.ready`
    /// (handshake-complete signal — analogous to Chessnut's first board-state frame).
    private mutating func processBoardStateFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count == 73 else {
            // Wrong length — likely a framing error or CU2 protocol divergence.
            return [.raw(Data(frame))]
        }
        let wasFirst = isFirstStateFrame
        isFirstStateFrame = false
        // Clear the A3 dedup guard on every board-state snapshot. After the
        // board resets state (including mid-game resync requests), the same
        // physical move is a fresh event, not a retransmit.
        lastA3Frame = []

        // Build file-major occupancy array (a1=0…h8=63).
        //
        // Canonical index → file-major index:
        //   canonical idx = (rank-1)*8 + file  →  file = idx%8, rank0 = idx/8
        //   fileMajor = file*8 + rank0 = (idx%8)*8 + (idx/8)
        //
        // Verified sentinels:
        //   a1: idx=0  → (0%8)*8+(0/8) = 0  ✓
        //   e2: idx=12 → (4)*8+(1)     = 33 ✓
        //   e4: idx=28 → (4)*8+(3)     = 35 ✓
        //   h8: idx=63 → (7)*8+(7)     = 63 ✓
        var occ = [Bool](repeating: false, count: 64)
        for canonIdx in 0..<64 {
            let code = frame[1 + canonIdx]
            let fileMajor = (canonIdx % 8) * 8 + (canonIdx / 8)
            occ[fileMajor] = code != 0x40
        }

        var events: [BoardEvent] = [.occupancySnapshot(occ)]
        if wasFirst { events.append(.ready) }
        return events
    }

    /// Decode a 6-byte `0xA3` move-on-board frame.
    ///
    /// Frame: `[A3, sub, fromCol, fromRow, toCol, toRow]`
    /// - `sub` (observed constant `0x35`): opaque, not parsed.
    /// - `fromCol` / `toCol`: file index, a=0…h=7.
    /// - `fromRow` / `toRow`: rank, 0-indexed (rank1=0, rank8=7).
    ///
    /// ⚠️  0xA3 uses `[col, row]` pairs, NOT single-byte canonical indices.
    /// Do not copy the `[col, row]` → single-idx conversion from 0x99.
    /// §4 "mirror trap" note: these are asymmetric conventions.
    ///
    /// [DISCREPANCY D7] Board retransmits until acked. Consecutive identical
    /// frames are deduplicated here. Transport MUST ack with `ackMoveData()`.
    private mutating func processMoveFromBoardFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count == 6 else { return [.raw(Data(frame))] }

        // Dedup consecutive identical 0xA3 frames.
        if frame == lastA3Frame { return [] }
        lastA3Frame = frame

        let fromCol = Int(frame[2])   // file a=0…h=7
        let fromRow = Int(frame[3])   // rank 0-indexed
        let toCol   = Int(frame[4])
        let toRow   = Int(frame[5])

        guard (0..<8).contains(fromCol), (0..<8).contains(fromRow),
              (0..<8).contains(toCol),   (0..<8).contains(toRow) else {
            return [.raw(Data(frame))]
        }

        let fromSq = Self.colRowToAlgebraic(col: fromCol, row: fromRow)
        let toSq   = Self.colRowToAlgebraic(col: toCol,   row: toRow)

        return [
            .squareSensed(square: fromSq, isLift: true,  piece: nil),
            .squareSensed(square: toSq,   isLift: false, piece: nil),
        ]
    }

    /// Decode a 10-byte `0xFD 0xFD` occupancy bitmap frame.
    ///
    /// Bitmap layout (RANK-REVERSED — the mirror trap):
    /// - `frame[2]` = rank 8 byte (rank0-idx=7); `frame[9]` = rank 1 byte (rank0-idx=0).
    /// - Within each byte: bit `f` (LSB, bit 0) = file a … bit 7 = file h.
    ///
    /// Formula: `occupied(file f, rank r_0indexed) = (frame[2 + (7-r)] >> f) & 1`
    ///
    /// Verified (F5 fixture): startpos-minus-e2 → `FD FD FF FF 00 00 00 00 EF FF`.
    /// - rank8=0xFF, rank7=0xFF (black pieces); ranks3-6=0x00; rank2=0xEF (e-file bit=0); rank1=0xFF.
    ///
    /// Enable stream first with `enableRawStreamData` (`Data([0x50])`).
    /// Single-source — MEDIUM confidence. [PRIMARY] RawBoardStateMessage.
    private func processOccupancyFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count == 10, frame[0] == 0xFD, frame[1] == 0xFD else {
            return [.raw(Data(frame))]
        }
        var occ = [Bool](repeating: false, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {   // rank: 0-indexed (0=rank1, 7=rank8)
                let byteIdx = 7 - rank           // payload[7-rank] = that rank's byte
                let bit = (frame[2 + byteIdx] >> file) & 1
                occ[file * 8 + rank] = bit != 0
            }
        }
        return [.occupancySnapshot(occ)]
    }

    // MARK: - Index conversion helpers

    /// Convert an algebraic square string to a canonical index byte.
    ///
    /// `idx = sq.rank * 8 + sq.file`  (sq.rank is 0-indexed in `Square`).
    ///
    /// Verified sentinels (spec §4, fixture F2):
    /// - e2: rank=1, file=4 → idx=12=0x0C ✓
    /// - e4: rank=3, file=4 → idx=28=0x1C ✓
    public static func squareToCanonicalIdx(_ algebraic: String) -> UInt8? {
        guard let sq = Square(algebraic: algebraic) else { return nil }
        return UInt8(sq.rank * 8 + sq.file)
    }

    /// Build an algebraic square string from a `[col, row]` pair (0xA3 frame format).
    ///
    /// `col` = file a=0…h=7; `row` = rank 0-indexed (rank1=0, rank8=7).
    ///
    /// Verified sentinel (F3): col=6, row=7 → "g8" ✓; col=5, row=5 → "f6" ✓.
    public static func colRowToAlgebraic(col: Int, row: Int) -> String {
        let fileChar = Character(UnicodeScalar(97 + col)!)
        return "\(fileChar)\(row + 1)"
    }
}

// MARK: - BoardCapabilities preset

extension BoardCapabilities {
    /// Capabilities for the ChessUp (gen-1) smart chess board.
    ///
    /// | occupancySensing | ✓ | 0x67 snapshot, 0xFD stream, 0xA3 move events |
    /// | perSquareLEDs    |   | not declared — 0x99 only accepts 2 squares   |
    /// |                  |   | and injects a remote move into board state;  |
    /// |                  |   | full per-square LED contract cannot be met   |
    /// | moveIndication   | ✓ | 0x99 lights from + to squares on the board  |
    ///
    /// `.perSquareLEDs` is NOT declared because `BoardCommand.indicateSquares`
    /// cannot be fully honoured: 0x99 only accepts exactly 2 squares, the
    /// empty-array (clear-LEDs) call is unsupported, and 0x99 is a remote-move
    /// injection command that alters board game state — not a pure LED command.
    /// The Millennium adapter (9×9 corner grid) is the canonical precedent:
    /// `.moveIndication` without `.perSquareLEDs`.
    ///
    /// `.pieceIdentity` is NOT declared: the 0x67 frame encodes piece codes but
    /// the product-spec capability set is occupancy + move indication only.
    /// `.batteryReporting` is NOT declared: the 0x33 frame carries a charging
    /// flag only (not a percentage), so `BoardEvent.battery(percent:)` cannot
    /// be populated from it.
    public static let chessUp: BoardCapabilities = [
        .occupancySensing, .moveIndication,
    ]
}
