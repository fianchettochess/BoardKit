import Foundation
import ChessCore
import BoardKit

// ── DGT Pegasus BLE adapter ───────────────────────────────────────────────────
//
// HARDWARE STATUS: protocol-verified against mono424/dgtdriver (MIT, Dart) [DD],
// DGTCentaurMods pegasus.py (GPL — protocol constants as facts only; no code
// structure copied) [PY], Graham O'Neill "DGT Pegasus driver" ReadMe PDF [GON],
// and classic DGT protocol header dgtbrd13.h (DGT Projects, via picochess copy;
// "may not be used commercially without written permission" — all facts
// independently corroborated by the MIT [DD] code) [BRD]; awaiting
// physical-board or BLE capture-log validation.
//
// License hygiene (CRITICAL):
//   MIT sources ([DD]) — code may inform structure with source-attribution
//     comments; direct code references cited inline.
//   GPL sources ([PY]), license-restricted sources ([BRD]) — protocol
//     constants and frame layouts learned as facts only; no code structure
//     copied.
//   License-less sources — facts only.
//
// Source tags used throughout:
//   [DD]  mono424/dgtdriver (MIT, Dart) — primary implementation reference
//   [PY]  DGTCentaurMods pegasus.py (GPL — facts only, no code structure)
//   [GON] Graham O'Neill "DGT Pegasus driver" ReadMe PDF (public document)
//   [BRD] DGT Projects dgtbrd13.h (facts only — restricted doc)

// MARK: - GATT constants

/// BLE connection constants for the DGT Pegasus.
///
/// **Discovery rule (PINNED):** scan by service UUID `PegasusGATT.nordicUART`
/// as the primary filter. Use the device name only as a display hint or for an
/// optional user override. Never hard-require a name prefix.
///
/// Rationale: The official DGT app prompts users to rename the board on first
/// run. After renaming, any `DGT_Pegasus`-prefix scanner silently fails in the
/// field. [GON §2.1] DGTCentaurMods emulates Pegasus under the name
/// `PCS-REVII-081500`, which the DGT app accepts. [PY line 88] DD's
/// `name.contains("DGT")` filter also breaks on renamed boards. Scan by UUID;
/// accept any name.
///
/// Factory name: `DGT_Pegasus_XXXXX`. The GON PDF prints it as
/// "DGT_Pegasaus_XXXXX" — almost certainly a typo; the load-bearing token is
/// `DGT_Pegasus`. [GON §2]
public enum PegasusGATT {
    /// Nordic UART Service — the Pegasus's primary BLE service.
    ///
    /// Use this UUID as the primary scanner filter, NOT the device name.
    /// [PY lines 91/97; implied by DD example characteristics]
    public static let nordicUART = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"

    /// Host→board write characteristic.
    ///
    /// **Data transfers (LED, streaming mode, board-dump request):** write
    /// without response is acceptable — a single unacked frame poses no
    /// ordering risk.
    ///
    /// **Handshake (first connect):** the board can drop commands when
    /// flooded. Use write-with-response (or the inter-step delays baked into
    /// `PegasusAdapter.handshakeCommands`) so each frame is ACKed before the
    /// next is sent. DD's field-proven `DGTBoard.reset()` relies on Flutter
    /// Blue's default write-with-response for exactly this pacing. [DD example]
    ///
    /// [DD `_characteristicWriteId`; PY UARTRXCharacteristic]
    public static let writeChar  = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

    /// Board→host notify+read characteristic.
    ///
    /// Subscribe to CCCD notifications **before** sending any command.
    /// [DD `_characteristicReadId` + `setNotifyValue(true)`; PY UARTTXCharacteristic]
    public static let notifyChar = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    /// Factory advertising name prefix (hint only; see type-level discovery rule). [GON §2]
    public static let factoryNamePrefix = "DGT_Pegasus"
}

// MARK: - Wire constants (host→board)

/// Command bytes sent from host to board. [DD Command enum; BRD — facts only]
private enum Cmd {
    /// Reset/clear state. Fire-and-forget; board ignores mid-game. [BRD DGT_SEND_RESET; PY '@' handler]
    static let reset:           UInt8 = 0x40
    /// Request full 64-byte board dump. [BRD DGT_SEND_BRD]
    static let boardDump:       UInt8 = 0x42
    /// Enter field-update push mode (Pegasus only).
    ///
    /// NOT 0x43 (DGT_SEND_UPDATE) or 0x4B (DGT_SEND_UPDATE_NICE) — those are
    /// clock-inclusive modes; DD explicitly guards them off with
    /// `if (isPegasusBoard) return;`. Use only 0x44. [DD isPegasusBoard guard]
    static let fieldUpdateMode: UInt8 = 0x44
    /// Request 5-ASCII-char serial number. [BRD DGT_RETURN_SERIALNR]
    static let serialNr:        UInt8 = 0x45
    /// Request trademark / device-info string.
    ///
    /// DD calls this "RequestDeviceInfo"; BRD calls it "DGT_SEND_TRADEMARK".
    /// Same wire exchange. [DD; BRD — facts only]
    static let trademark:       UInt8 = 0x47
    /// Request battery status; also enables battery push updates on Pegasus. [DD; BRD DGT_SEND_BATTERY_STATUS]
    static let batteryStatus:   UInt8 = 0x4C
    /// Request firmware version `[major, minor]`. Pegasus reports major == 1. [BRD DGT_SEND_VERSION; DD]
    static let version:         UInt8 = 0x4D
    /// LED command opcode (Pegasus dialect, subcommand 0x05 list form). [DD; PY]
    static let led:             UInt8 = 0x60
    /// Register developer key (DataCommand form). [DD AuthorizeWithDeveloperKey]
    static let devkey:          UInt8 = 0x63
}

// MARK: - Wire constants (board→host reply message IDs)

/// Board→host reply message IDs, each carrying bit 7 set.
/// Frame format: `[msgId, lenHi, lenLo, payload…]` where
/// `totalLen = (lenHi << 7) | lenLo` and includes the 3 header bytes. [DD DGTMessage.parse; PY sendMessage]
private enum MsgId {
    /// Board dump reply — 64 occupancy bytes. [BRD DGT_MSG_BOARD_DUMP]
    static let boardDump:   UInt8 = 0x86
    /// Field update — `[squareIndex, code]`. totalLen always 5. [BRD DGT_MSG_FIELD_UPDATE]
    static let fieldUpdate: UInt8 = 0x8E
    /// Serial number ASCII bytes. [BRD DGT_MSG_SERIALNR]
    static let serialNr:    UInt8 = 0x91
    /// Firmware version `[major, minor]`. major == 1 → Pegasus. [BRD DGT_MSG_VERSION; DD]
    static let version:     UInt8 = 0x93
    /// Battery status — 9-byte payload. [BRD DGT_MSG_BATTERY_STATUS]
    static let battery:     UInt8 = 0xA0
    /// Developer key state (emulation guess: 0x01 = registered).
    ///
    /// [DISCREPANCY] DD sends devkey fire-and-forget and expects no reply; PY
    /// emulation replies with 0xA5 [0x01]. Send and continue; log any 0xA5
    /// frame as `.raw`. [DD vs PY; spec discrepancy 4 / risk 1]
    static let devkeyState: UInt8 = 0xA5
}

// MARK: - Developer key

/// The default developer key bundled in mono424/dgtdriver (White Pawn app). [DD DGTBoard.init]
///
/// Wire frame: `63 07 BE F5 AE DD A9 5F 00`
/// (code 0x63, len 0x07 = 6 key bytes + 0x00 terminator, then key bytes, then 0x00)

// MARK: - PegasusAdapter

/// BLE board adapter for the DGT Pegasus.
///
/// The Pegasus is an **occupancy-only** board: it reports which squares are
/// occupied but NOT which piece type or colour occupies each square. All
/// `squareSensed` events carry `piece: nil`.
///
/// ## Capabilities
///
/// | Capability       | Pegasus |
/// |------------------|---------|
/// | occupancySensing | ✓       |
/// | pieceIdentity    |         |
/// | perSquareLEDs    | ✓       |
/// | moveIndication   | ✓       |
/// | motorised        |         |
/// | batteryReporting | ✓       |
///
/// ## Square indexing — the mirror trap
///
/// Protocol index `i` ∈ 0..63: **0 = a8, 1 = b8, … 7 = h8, 8 = a7, … 63 = h1.**
/// [DD DGTProtocol.SQUARES; BRD board-dump doc]
///
/// Decomposition: `file = i & 7` (a=0…h=7); `rankIdx = 7 - (i >> 3)` (0-indexed: 0=rank1, 7=rank8).
/// File-major index used by `BoardEvent`: `fileMajor = file * 8 + rankIdx`.
///
/// Inversion (Square → protocol index): `i = (7 - sq.rank) * 8 + sq.file`
/// where `sq.rank` is 0-indexed.
///
/// Sanity anchors: a8=0x00, h8=0x07, a1=0x38, h1=0x3F, e2=0x34, e4=0x24.
///
/// **Orientation — adapter-level vs. session-level flip:** index 0 is a
/// fixed physical corner; the electronics never renumber. If the player has
/// Black nearest themselves the board must be rotated 180°.
///
/// Two mechanisms exist; **use exactly one, never both:**
///
/// - **Adapter-level (this adapter):** set `orientationFlipped = true`.
///   The adapter remaps `i' = 63 - i` consistently for ALL inbound squares
///   AND outbound LED indices, so LEDs stay coherent in the board's frame.
///
/// - **Session-level:** leave `orientationFlipped = false` and apply
///   `ChessBoardGeometry.flippedSquare` in the session on each
///   `squareSensed` square. The session must then also flip outbound
///   `indicateSquares` squares before passing them to `encode(_:)` to
///   keep LEDs consistent.
///
/// Combining both mechanisms double-flips inbound squares (net identity)
/// and double-flips LED targets — producing mirror-imaged LEDs. This is the
/// mirror-trap the flag was created to prevent. See also the `orientationFlipped`
/// property doc and `BoardEvent.squareSensed` (which documents the session-level
/// seam as the general contract; this adapter's flag is an intentional
/// exception to that general rule). [GON §2.3; spec §5 / risk 6]
///
/// ## Board→host framing
///
/// `[msgId, lenHi, lenLo, payload…]`
/// `totalLen = (lenHi << 7) | lenLo` — counts all 3 header bytes; bit 7 is set
/// ONLY on msgId. [DD DGTMessage.parse; PY sendMessage `lo=(len+3)&127, hi=…`]
///
/// Board dumps are 67 bytes; this exceeds a typical 20-byte ATT MTU so the
/// adapter reassembles frames across BLE notifications. [DD `_handleInputStream`]
///
/// **Resync rule:** on garbage, skip forward to the next byte whose bit 7 is
/// set (only message-ID bytes have the MSB). [DD skipBadBytes rule — pinned;
/// DD's implementation has an off-by-N bug — not ported]
///
/// ## LED encoding
///
/// Pegasus subcommand-0x05 list form: `60 <len> 05 <speed> <repeat> <brightness> <sq0>…<sqN-1> 00`
/// All-off frame: `60 02 00 00` (exact pattern from the official DGT app). [PY handler]
///
/// [DISCREPANCY] Classic Revelation II uses `60 04 <pattern> <start> <end> 00`
/// [BRD]; Pegasus uses the 0x05 subcommand list form [DD, PY]. Same opcode,
/// different device dialect. Do NOT use the RevII form on Pegasus.
///
/// ## Hardware status
///
/// Protocol-verified against [DD] (MIT, Dart), with protocol facts from [PY]
/// (GPL), [GON] (public), and [BRD] (restricted doc, facts only). Awaiting
/// physical-board or BLE capture-log runtime validation.
public struct PegasusAdapter: BoardAdapter {

    // MARK: - Configuration

    /// The dgtdriver / White Pawn app's built-in developer key — the default
    /// ``devkey``.
    ///
    /// **Provenance risk:** a third-party app's hardcoded key, not a
    /// BoardKit-specific one. Inject your own key obtained directly from DGT for
    /// production. [spec risk]
    public static let defaultDevkey: [UInt8] = [0xBE, 0xF5, 0xAE, 0xDD, 0xA9, 0x5F]

    /// 6-byte developer key sent in the devkey handshake frame.
    ///
    /// Defaults to ``defaultDevkey``. Inject your own key obtained from DGT for
    /// production.
    public var devkey: [UInt8]

    /// When `true`, all incoming square indices and outgoing LED indices are
    /// remapped `i' = 63 - i` (180° rotation).
    ///
    /// Set this when the physical board is oriented with Black nearest the user.
    /// Orientation cannot be auto-detected on an occupancy-only board because
    /// the starting position is 180°-symmetric. [GON §2.3; spec §5 / risk 6]
    ///
    /// **Mutual exclusivity — CRITICAL:** this adapter-level flip and the
    /// session-level `ChessBoardGeometry.flippedSquare` mechanism are mutually
    /// exclusive. **When this flag is `true`, the session MUST NOT also apply
    /// `ChessBoardGeometry.flippedSquare` on `squareSensed` squares.**
    /// Doing so double-flips inbound squares (squares round-trip to identity)
    /// and double-flips outbound LED indices — producing mirror-imaged LEDs,
    /// which is exactly the trap this flag exists to prevent.
    /// Conversely, when the session owns orientation (the general pattern
    /// described in `BoardEvent.squareSensed`), set this flag to `false`.
    /// See the type-level "Orientation" section for the full decision matrix.
    public var orientationFlipped: Bool

    // MARK: - Mutable parser state

    /// Byte accumulator. Board→host frames do NOT align to BLE notification
    /// boundaries — the 67-byte board dump exceeds a typical 20-byte ATT MTU.
    /// [DD `_handleInputStream`]
    private var buffer: [UInt8] = []

    /// Previous occupancy snapshot in file-major layout (`[Bool]`, a1=0…h8=63),
    /// used to compute per-square lift/place deltas on each new board dump.
    /// `nil` until the first board dump is decoded — re-arming to `nil` via
    /// `resetFraming()` causes the next board dump to re-emit `.ready`.
    private var previousOccupancy: [Bool]? = nil

    // MARK: - BoardAdapter conformance

    public var capabilities: BoardCapabilities {
        [.occupancySensing, .perSquareLEDs, .moveIndication, .batteryReporting]
    }

    public init(
        devkey: [UInt8] = PegasusAdapter.defaultDevkey,
        orientationFlipped: Bool = false
    ) {
        self.devkey = devkey
        self.orientationFlipped = orientationFlipped
    }

    // MARK: - feed(bytes:)

    /// Feed raw BLE notification bytes through the streaming frame reassembler.
    ///
    /// Accumulates bytes across calls; emits events only when a complete frame
    /// has been reassembled.
    ///
    /// **Resync:** if `buffer[0]` does not have bit 7 set it cannot be a valid
    /// message-ID byte — advance until a byte with bit 7 set is found or the
    /// buffer is exhausted. Matches the pinned protocol rule; not a port of DD's
    /// off-by-N `skipBadBytes`. [spec §2; DD skipBadBytes — off-by-N noted]
    ///
    /// **Length validation:** `lenHi` and `lenLo` (bytes 1 and 2) must NOT have
    /// bit 7 set (they are 7-bit fields). If either does, the frame is corrupt —
    /// skip the msgId byte and resync. [DD DGTMessage.parse framing contract]
    public mutating func feed(bytes: Data) -> [BoardEvent] {
        buffer.append(contentsOf: bytes)
        var events: [BoardEvent] = []
        while true {
            // Resync: skip bytes that cannot be message-ID bytes (bit 7 clear).
            while !buffer.isEmpty && (buffer[0] & 0x80) == 0 {
                buffer.removeFirst()
            }
            guard buffer.count >= 3 else { break }

            let lenHi = buffer[1]
            let lenLo = buffer[2]
            // lenHi and lenLo are 7-bit fields — bit 7 must be clear. [DD framing]
            guard (lenHi & 0x80) == 0, (lenLo & 0x80) == 0 else {
                // Framing corrupt — skip the msgId byte and try to resync.
                buffer.removeFirst()
                continue
            }
            let totalLen = (Int(lenHi) << 7) | Int(lenLo)
            // totalLen must be ≥ 3 (covers at minimum the header only) and
            // within a sane upper bound.
            guard totalLen >= 3, totalLen <= 4096 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= totalLen else { break }  // wait for more data

            let frame = Array(buffer.prefix(totalLen))
            buffer.removeFirst(totalLen)
            events += processFrame(frame)
        }
        return events
    }

    // MARK: - encode(_:)

    /// Encode a `BoardCommand` to its Pegasus wire bytes.
    ///
    /// Mapping:
    /// - `.startSession` → `0x44` enter field-update streaming mode
    /// - `.requestState` → `0x42` board dump request
    /// - `.indicateSquares([], *)` → all-off frame `60 02 00 00`
    /// - `.indicateSquares(squares, *)` → 0x05-subcommand list LED frame
    /// - `.executeMove` → `nil` (not motorised)
    /// - `.custom(data)` → `data` verbatim
    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession:
            // Enter field-update push mode (Pegasus-specific; NOT 0x43/0x4B). [DD]
            return Data([Cmd.fieldUpdateMode])
        case .requestState:
            // Request a full board occupancy dump. [BRD DGT_SEND_BRD]
            return Data([Cmd.boardDump])
        case .indicateSquares(let squares, _):
            // Style is advisory; Pegasus has one LED colour per square. [BoardCommand doc]
            return encodeLED(squares: squares)
        case .executeMove:
            // Not motorised — return nil for silent transport skip. [BoardAdapter doc]
            return nil
        case .requestStoredGames:
            // DGT Pegasus streams live; no host-pullable on-device game archive.
            return nil
        case .custom(let data):
            return data
        }
    }

    // MARK: - handshakeCommands(isReconnect:)

    /// Pinned init sequence derived from DD `DGTBoard.reset()`, field-proven by
    /// the White Pawn app against real Pegasus hardware. [DD DGTBoard.reset()]
    ///
    /// ## First-connect sequence
    /// 1. Wait ≥300 ms (initial BLE stabilisation) → `0x40` reset
    /// 2. `0x45` serial request (50 ms before)
    /// 3. `0x4D` version request (50 ms before; major == 1 → Pegasus confirmed)
    /// 4. Devkey frame `63 07 <key> 00` (50 ms before; fire-and-forget; tolerate 0xA5 reply)
    /// 5. `0x47` trademark / device-info request (50 ms before)
    /// 6. `0x40` reset again (50 ms before)
    /// 7. `0x42` board dump request → `.requestState` (50 ms before)
    /// 8. `0x44` enter field-update streaming mode → `.startSession` (50 ms before)
    /// 9. `0x4C` battery request (50 ms before; also enables push battery updates)
    ///
    /// ## Handshake pacing
    ///
    /// DD's `DGTBoard.reset()` awaits each board reply before the next write,
    /// using Flutter Blue's default write-with-response as the natural pacing
    /// mechanism. The `delayBefore` values above (50 ms between steps 2-9)
    /// approximate this sequencing for integrators that use write-without-response
    /// (see `PegasusGATT.writeChar`). If your transport uses write-with-response,
    /// the extra delay is harmless but the board's ACK already provides the
    /// needed pacing. **Hardware-unverified:** flag for the first
    /// physical-board or BLE capture-log validation pass.
    ///
    /// ## Reconnect sequence
    /// Re-request the board dump for a fresh occupancy snapshot.  The transport
    /// **must** call `resetFraming()` before executing this sequence to discard
    /// any partial-frame remnant from the dropped link.
    ///
    /// **Transport note:** subscribe to `PegasusGATT.notifyChar` CCCD
    /// notifications BEFORE issuing any command. [DD `setNotifyValue(true)`]
    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)] {
        if isReconnect {
            // Occupancy boards resync by snapshot — re-request the board dump
            // after allowing 250 ms for the link to restabilise.
            return [(.requestState, 0.25)] // 250ms
        }
        return [
            (.custom(Data([Cmd.reset])),         0.3),  // 300ms — initial delay then reset
            (.custom(Data([Cmd.serialNr])),      0.05), // 50ms — serial number
            (.custom(Data([Cmd.version])),       0.05), // 50ms — version → confirm Pegasus
            (.custom(devkeyFrame()),             0.05), // 50ms — devkey (fire-and-forget)
            (.custom(Data([Cmd.trademark])),     0.05), // 50ms — trademark/device-info
            (.custom(Data([Cmd.reset])),         0.05), // 50ms — reset again
            (.requestState,                      0.05), // 50ms — board dump (0x42)
            (.startSession,                      0.05), // 50ms — streaming mode (0x44)
            (.custom(Data([Cmd.batteryStatus])), 0.05), // 50ms — battery + enable push
        ]
    }

    // MARK: - resetFraming()

    /// Reset the frame reassembler and occupancy history.
    ///
    /// **Call this when the BLE link drops, before executing the reconnect
    /// handshake sequence.** It clears two pieces of mutable state:
    ///
    /// - `buffer`: any partial-frame bytes from the dropped link that would
    ///   corrupt the parser's frame alignment on the first post-reconnect
    ///   notification (board dumps span multiple ATT MTU packets).
    ///
    /// - `previousOccupancy`: re-arming this to `nil` re-triggers the
    ///   first-snapshot `.ready` emission after the board dump arrives,
    ///   giving the session a clean "reconnected and ready" signal without
    ///   needing to recreate the adapter.
    public mutating func resetFraming() {
        buffer = []
        previousOccupancy = nil
    }

    // MARK: - Devkey frame helper

    /// Encode the developer-key registration frame.
    ///
    /// Wire: `63 07 BE F5 AE DD A9 5F 00` (using the default key)
    ///
    /// Derivation: code `0x63`; payload = N key bytes + `0x00` terminator
    /// → len byte = N + 1 (payload count only, host-side DataCommand form).
    /// [DD AuthorizeWithDeveloperKey + DGTBoard.init default key `[190,245,174,221,169,95]`]
    ///
    /// [DISCREPANCY] DD sends devkey fire-and-forget. PY emulation replies with
    /// `0xA5 [0x01]`. The adapter sends and continues; any 0xA5 frame that
    /// arrives is logged as `.raw`. [spec discrepancy 4]
    public func devkeyFrame() -> Data {
        var frame: [UInt8] = [Cmd.devkey, UInt8(devkey.count + 1)]
        frame.append(contentsOf: devkey)
        frame.append(0x00)
        return Data(frame)
    }

    // MARK: - Frame processing (board→host)

    private mutating func processFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard !frame.isEmpty else { return [] }
        switch frame[0] {
        case MsgId.boardDump:
            return processBoardDump(frame)
        case MsgId.fieldUpdate:
            return processFieldUpdate(frame)
        case MsgId.battery:
            return processBattery(frame)
        default:
            // Unknown / unimplemented reply codes: forward as .raw for debug logging.
            // Callers must never branch on .raw. [BoardEvent doc]
            return [.raw(Data(frame))]
        }
    }

    /// Decode a board-dump frame (`0x86`, 64 payload bytes) into an
    /// `occupancySnapshot`, per-square `squareSensed` deltas, and `.ready`.
    ///
    /// Payload byte `i` = occupancy of protocol square `i` (0=a8…63=h1).
    /// `0x00` = empty; any nonzero value = occupied.
    ///
    /// **Pegasus occupancy encoding:** the hardware reports `0x01` for every
    /// occupied square. Bytes `0x01`–`0x0F` are all treated as "occupied";
    /// piece identity is NOT available. [DD PegasusPiece collapse; BRD — facts only]
    ///
    /// Emits:
    /// - `.occupancySnapshot([Bool])` — file-major array (a1=0…h8=63)
    /// - `.squareSensed` deltas vs the previous snapshot (squares that changed)
    /// - `.ready` — emitted exactly once on the first board dump per connect cycle
    private mutating func processBoardDump(_ frame: [UInt8]) -> [BoardEvent] {
        let payloadLen = frame.count - 3
        guard frame[0] == MsgId.boardDump, payloadLen >= 64 else {
            return [.raw(Data(frame))]
        }
        let isFirst = (previousOccupancy == nil)

        // Build file-major occupancy array (a1=0…h8=63).
        var occupancy = [Bool](repeating: false, count: 64)
        for i in 0..<64 {
            let raw = frame[3 + i]
            let pi = orientationFlipped ? (63 - i) : i
            let (file, rankIdx) = PegasusAdapter.squareComponents(protocolIndex: pi)
            occupancy[file * 8 + rankIdx] = (raw != 0x00)
        }

        var events: [BoardEvent] = []
        events.append(.occupancySnapshot(occupancy))

        // Emit squareSensed deltas vs the previous snapshot.
        if let prev = previousOccupancy {
            let fileChars = Array("abcdefgh")
            for file in 0..<8 {
                for rankIdx in 0..<8 {
                    let idx = file * 8 + rankIdx
                    let was = prev[idx]
                    let now = occupancy[idx]
                    if !was && now {
                        let sq = "\(fileChars[file])\(rankIdx + 1)"
                        events.append(.squareSensed(square: sq, isLift: false, piece: nil))
                    } else if was && !now {
                        let sq = "\(fileChars[file])\(rankIdx + 1)"
                        events.append(.squareSensed(square: sq, isLift: true, piece: nil))
                    }
                }
            }
        }
        previousOccupancy = occupancy

        // Emit .ready exactly once per connect cycle (first board dump). [ChessnutAdapter pattern]
        if isFirst {
            events.append(.ready)
        }
        return events
    }

    /// Decode a field-update frame (`0x8E`, 2 payload bytes) into a
    /// `squareSensed` event.
    ///
    /// Payload: `[squareIndex, code]`
    /// - `code == 0x00` → square became EMPTY (piece lifted)
    /// - nonzero (observed `0x01`) → square became OCCUPIED (piece placed)
    ///
    /// One physical move = ≥2 frames (lift + place; a capture adds a lift).
    /// [DD FieldUpdateAnswer; PY sends (idx,0) for lift event 0x40, (idx,1) for place event 0x41]
    ///
    /// Also updates `previousOccupancy` so a subsequent board dump delta
    /// calculation sees consistent state.
    private mutating func processFieldUpdate(_ frame: [UInt8]) -> [BoardEvent] {
        let payloadLen = frame.count - 3
        guard frame[0] == MsgId.fieldUpdate, payloadLen >= 2 else {
            return [.raw(Data(frame))]
        }
        let rawIndex  = Int(frame[3])
        let pieceCode = frame[4]
        let isOccupied = (pieceCode != 0x00)

        let pi = orientationFlipped ? (63 - rawIndex) : rawIndex
        guard (0..<64).contains(pi) else {
            return [.raw(Data(frame))]
        }
        let (file, rankIdx) = PegasusAdapter.squareComponents(protocolIndex: pi)
        let fileMajor = file * 8 + rankIdx
        let fileChar  = Character(UnicodeScalar(UInt8(97 + file)))
        let sq        = "\(fileChar)\(rankIdx + 1)"

        // Keep previousOccupancy consistent with field updates. [delta accuracy]
        if previousOccupancy != nil {
            previousOccupancy![fileMajor] = isOccupied
        }

        return [.squareSensed(square: sq, isLift: !isOccupied, piece: nil)]
    }

    /// Decode a battery-status frame (`0xA0`).
    ///
    /// Payload byte 0 = battery percentage (literal integer 0–100). [BRD; DD]
    ///
    /// [DISCREPANCY] PY comment reads "0x58 ≈ 100%"; BRD says literal percent,
    /// DD parses `payload[0] / 100` as a fraction → 0x58 = 88%. Follow BRD+DD;
    /// PY author explicitly admits faking the value. [spec §6, discrepancy 1]
    ///
    /// [DISCREPANCY] BRD defines `DGT_SIZE_BATTERY_STATUS 7` but its own layout
    /// and PY's observed 12-byte total frame both describe a 9-byte payload.
    /// Parse by the frame's declared length, never a hardcoded size.
    /// [spec §6, discrepancy 2]
    private func processBattery(_ frame: [UInt8]) -> [BoardEvent] {
        let payloadLen = frame.count - 3
        guard payloadLen >= 1 else { return [.raw(Data(frame))] }
        return [.battery(percent: Int(frame[3]))]
    }

    // MARK: - LED encoding (host→board)

    /// Encode an LED command for the Pegasus (0x05 subcommand list form).
    ///
    /// Wire format: `60 <len> 05 <speed> <repeatCount> <brightness> <sq0>…<sqN-1> 00`
    /// All-off: `60 02 00 00` — official DGT app's exact pattern. [PY handler]
    ///
    /// **Speed** (wire 1..7): DD sends `speed.index + 1`; higher values appear
    /// to produce faster flashing. Hardware-unverified direction. [DD]
    ///
    /// **RepeatCount**: DD enum forever=0, once=1, twice=2, three_times=3.
    /// Only 0 and 1 are field-proven from the official app. [DD; PY]
    ///
    /// **Brightness** (wire byte): DD enum 0=highest, 1=high, 2=middle, 3=low.
    /// [DISCREPANCY] GON's user-facing scale says "1=quite dim … 4=full".
    /// The wire offset is agreed; the value→intensity DIRECTION is not confirmed
    /// on hardware. Default 0x02 (DD's "middle"); expose the raw byte so the
    /// caller can verify on hardware. [spec §7, discrepancy 3]
    ///
    /// [DISCREPANCY] Classic Revision II `0x60` form uses `60 04 <pattern>
    /// <startField> <endField> 00` [BRD — facts only]. Pegasus uses the
    /// 0x05 subcommand list form [DD; PY]. Never use the RevII form on Pegasus.
    /// [spec §7, discrepancy 5]
    ///
    /// Cross-check: PY's rule "byte1 = total_packet_length − 2" → for N squares
    /// total = 9 bytes (F5), byte1 = 7 = len ✓.
    ///
    /// - Parameters:
    ///   - squares: Algebraic square strings to illuminate (e.g. `["e2","e4"]`).
    ///   - speed: Wire speed byte 1–7. Default 3 (mid-range).
    ///   - repeatCount: DD enum — 0=forever, 1=once (field-proven only 0/1). Default 1.
    ///   - brightness: Wire byte per DD enum (0=highest…3=low). Default 2.
    public func encodeLED(
        squares: [String],
        speed: UInt8 = 3,
        repeatCount: UInt8 = 1,
        brightness: UInt8 = 2
    ) -> Data {
        if squares.isEmpty {
            // All-off frame: `60 02 00 00`. [PY exact-match; spec §7]
            return Data([Cmd.led, 0x02, 0x00, 0x00])
        }
        var squareIndices: [UInt8] = []
        for algebraic in squares {
            guard let sq = Square(algebraic: algebraic) else { continue }
            // Inversion formula: i = (7 - sq.rank) * 8 + sq.file  [spec §5]
            var i = (7 - sq.rank) * 8 + sq.file
            if orientationFlipped { i = 63 - i }
            squareIndices.append(UInt8(i))
        }
        // len = 5 + N: subcmd(1) + speed(1) + repeat(1) + brightness(1) + squares(N) + terminator(1)
        let len = 5 + squareIndices.count
        var frame: [UInt8] = [Cmd.led, UInt8(len), 0x05, speed, repeatCount, brightness]
        frame.append(contentsOf: squareIndices)
        frame.append(0x00)
        return Data(frame)
    }

    // MARK: - Index conversion helper

    /// Decompose a Pegasus protocol index `i` (0=a8…63=h1) into
    /// `(file, rankIdx)` where `file` ∈ 0..7 (a=0…h=7) and
    /// `rankIdx` ∈ 0..7 (0=rank1…7=rank8).
    ///
    /// Formula: `file = i & 7`, `rankIdx = 7 - (i >> 3)`. [spec §5; DD DGTProtocol.SQUARES]
    ///
    /// Sanity anchors:
    /// - a8 → i=0  → file=0, rankIdx=7
    /// - h8 → i=7  → file=7, rankIdx=7
    /// - a1 → i=56 → file=0, rankIdx=0
    /// - h1 → i=63 → file=7, rankIdx=0
    /// - e2 → i=52 → file=4, rankIdx=1
    /// - e4 → i=36 → file=4, rankIdx=3
    public static func squareComponents(protocolIndex i: Int) -> (file: Int, rankIdx: Int) {
        return (i & 7, 7 - (i >> 3))
    }

    /// Encode a position into a Pegasus board-dump frame (67 bytes).
    ///
    /// The inverse of the board-dump decoder. Used by test harnesses and
    /// capture-log tooling; not normally sent over the wire.
    ///
    /// `occupancy` must be a 64-element file-major array (a1=0…h8=63).
    public static func encodeBoardDump(occupancy: [Bool]) -> Data {
        precondition(occupancy.count == 64, "occupancy must be 64 elements")
        var frame = [UInt8](repeating: 0, count: 67)
        frame[0] = MsgId.boardDump   // 0x86
        frame[1] = 0x00              // lenHi: totalLen 67 >> 7 = 0
        frame[2] = 0x43              // lenLo: totalLen 67 & 0x7F = 67
        for i in 0..<64 {
            let (file, rankIdx) = squareComponents(protocolIndex: i)
            let fileMajor = file * 8 + rankIdx
            frame[3 + i] = occupancy[fileMajor] ? 0x01 : 0x00
        }
        return Data(frame)
    }
}
