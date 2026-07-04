import Foundation
import ChessCore
import BoardKit

// ── Certabo RFID board adapter ────────────────────────────────────────────────
//
// Covers the Certabo e-board family (RFID pieces, full piece identity,
// per-square LEDs), and the Tabutronic Sentio family (same electronics vendor,
// same wire framing, occupancy-only). Classic single-color and Spectrum RGB
// LED boards are both supported. Transport-agnostic: USB serial, BT-Classic
// RFCOMM, or BLE byte pipe — all produce byte-identical ASCII streams.
//
// HARDWARE STATUS: Partially verified — LED + occupancy vectors fully confirmed
// against [MONO424] (MIT) semantics and [CER2NUT] golden-fixture vectors; RFID
// wrapped-frame parsing verified against [CER2NUT] CertaboParser fixture family.
// Awaiting physical-board or USB/BT capture-log validation.
//
// Sources (code-ok, MIT):
//   [MONO424]  mono424/certabodriver (MIT, © 2021 Khadim Fall)
//              lib/CertaboBoard.dart, CertaboMessage.dart, CertaboProtocol.dart,
//              LEDPattern.dart, CertaboCommunicationClient.dart,
//              example/lib/main.dart
//
// Sources (facts only — GPL v3 / proprietary — no code structure copied):
//   [OFFICIAL] CERTABO/CERTABO-CHESSBOARDS-SOFTWARE (GPL v3)
//              codes.py, usbtool.py, run.py, reader_writer.py
//   [BT]       CERTABO/BT (GPL v3)
//              bluetooth_server.py, cfg.py, utils/usbtool.py, reader_writer.py
//   [HAKLEIN]  haklein/certabo-lichess (GPL v3)
//              certabo/serialreader.py, certabo/certabo.py
//   [CER2NUT]  gkalab/cer2nut (GPL-3.0) — wire-format test vectors / golden
//              fixtures used as protocol facts; no code structure copied.
//   [ONEILL]   goneill.co.nz "ReadMe (Certabo).pdf" (proprietary doc)
//   [CERTABO]  certabo.com FAQ, BLE-module page, manual (proprietary)

// MARK: - Transport constants

/// USB serial constants for Certabo boards.
///
/// The Silicon Labs CP210x bridge chip provides a virtual COM port at 38400 baud.
/// Source: [HAKLEIN] serialreader.py `pid == 0xea60 and vid == 4292`;
/// [OFFICIAL] usbtool.py `serial.Serial(port, 38400)`; [MONO424] README `38400, DATABITS_8`.
public enum CertaboSerial {
    /// Baud rate for USB serial communication.
    public static let baudRate: Int = 38400
    /// Silicon Labs CP210x USB vendor ID (decimal 4292 = hex 0x10C4).
    public static let usbVendorID: Int = 0x10C4
    /// Silicon Labs CP210x USB product ID.
    public static let usbProductID: Int = 0xEA60
    /// RFID tag length in bytes (5 bytes per piece).
    public static let rfidTagLength: Int = 5
    /// Number of squares on the board.
    public static let squareCount: Int = 64
    /// Token count for a Certabo RFID position frame (64 squares × 5 bytes).
    public static let rfidTokenCount: Int = 320
    /// Token count for a Tabutronic Sentio occupancy frame (8 rank bitmasks).
    public static let occupancyTokenCount: Int = 8
}

/// Bluetooth Classic RFCOMM constants for the Certabo BT module.
///
/// The BT module is a Raspberry Pi bridging the USB serial port to RFCOMM SPP.
/// The byte stream is identical to USB — same parsing applies.
/// Source: [BT] cfg.py `BTPORT = 10`; [ONEILL] ReadMe PDF.
public enum CertaboBT {
    /// RFCOMM channel. Source: [BT] cfg.py `BTPORT = 10`.
    public static let rfcommChannel: Int = 10
    /// SPP profile service UUID. Source: [BT] cfg.py.
    public static let serviceUUID: String = "41c9ee4d-871e-4556-b521-84c89c24710a"
    /// Service name registered via SPP. Source: [BT].
    public static let serviceName: String = "Certabo"
    /// The Raspberry Pi BT device may advertise this hostname. Source: [ONEILL].
    public static let deviceNameHint: String = "raspberrypi"
}

// MARK: - RFID tag ID

/// A 5-byte Certabo RFID piece tag.
///
/// Each physical piece carries a unique RFID chip. Sets share 3-byte
/// manufacturer prefixes (`3 0 84 …`, `3 0 85 …`, `3 0 83 …`), so all 5
/// bytes must be compared for identity.
/// Source: [OFFICIAL] compare_cells compares all 5; [MONO424] full 5-byte compare.
public struct CertaboTagID: Equatable, Hashable, Sendable {
    public let b0, b1, b2, b3, b4: UInt8

    public init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, _ b4: UInt8) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.b3 = b3; self.b4 = b4
    }

    /// The all-zero tag. Represents an empty square (primary test).
    public static let zero = CertaboTagID(0, 0, 0, 0, 0)

    /// `true` when all 5 bytes are zero. The authoritative empty-square test (D7).
    public var isAllZero: Bool { b0 == 0 && b1 == 0 && b2 == 0 && b3 == 0 && b4 == 0 }

    /// `true` when 3 or more bytes are zero. Secondary RFID-noise heuristic (D7).
    /// Source: [OFFICIAL] cell_empty "≥3 zero bytes" additional filter.
    public var hasThreeOrMoreZeroBytes: Bool {
        [b0, b1, b2, b3, b4].filter { $0 == 0 }.count >= 3
    }

    /// `true` when this tag should be treated as representing an empty square
    /// (primary all-zero test OR secondary noise heuristic).
    public var isEffectivelyEmpty: Bool { isAllZero || hasThreeOrMoreZeroBytes }

    /// The 5 bytes as a flat array (for serialisation).
    public var bytes: [UInt8] { [b0, b1, b2, b3, b4] }
}

// MARK: - LED type

/// The LED hardware type as reported by the board via status lines in the stream.
///
/// After `L\r\n` the board has single-color per-square LEDs (8-byte commands).
/// After `D\r\n` the board has Spectrum RGB corner LEDs (247-byte commands).
/// Source: [CER2NUT] parsePart; `L`/`D` status line detection.
public enum CertaboLEDType: Sendable {
    /// Not yet determined; classic 8-byte command is used as safe default.
    case undecided
    /// Single-color per-square LEDs. Use 8-byte classic frame.
    case classic
    /// Spectrum RGB corner-LED grid (9×9 points). Use 247-byte frame.
    case rgb
}

// MARK: - Internal board type

private enum CertaboBoardType: Sendable {
    /// RFID board: 320-token frames. Full piece identity when calibrated.
    case rfid
    /// Occupancy-only board (Tabutronic Sentio family): 8-token frames.
    case occupancy
}

// MARK: - Calibration

/// Maps Certabo RFID tag IDs to chess pieces.
///
/// Each physical piece set has random RFID tag IDs that are LEARNED during
/// a calibration procedure and can never be derived analytically.
///
/// ## Calibration procedure (new setup)
///
/// 1. Place the standard start position on the board plus spare queens:
///    extra black queen on d6, extra white queen on d3.
/// 2. Collect 15 frames via the adapter's `feed(bytes:)` (voted tags are
///    available on `CertaboAdapter.lastVotedTags` after each frame).
/// 3. Call `CertaboCalibration.learn(from:standardStart:)` with those frames.
///
/// ## Add-piece mode
///
/// Call `adding(from:)` to union new tag IDs into an existing calibration
/// (for second queen pairs, extra sets with different themes, etc.).
///
/// Sources: [OFFICIAL] reader_writer.py calibration logic; [CER2NUT] CertaboCalibrator;
/// D5: follow newer behavior (d6/d3 spare-queen squares, skip-if-empty).
/// D10: 15-frame modal vote (official parity).
public struct CertaboCalibration: Sendable {

    // MARK: - Storage

    /// Runtime lookup: tag ID → piece (reverse of the calibration map).
    private let tagToPiece: [CertaboTagID: Piece]

    // MARK: - Init

    /// Create an empty (uncalibrated) calibration.
    public init() { self.tagToPiece = [:] }

    /// Create a calibration directly from a tag-to-piece mapping.
    ///
    /// Use in tests and personality emulation to build a deterministic calibration
    /// from a known set of tag IDs. In production, prefer `learn(from:standardStart:)`.
    public init(tagToPieceMap: [CertaboTagID: Piece]) { self.tagToPiece = tagToPieceMap }

    /// Returns the tag ID mapped to `piece` in this calibration, or `nil` if none.
    ///
    /// Scans the internal tag→piece map to invert it. Use for personality-side
    /// RFID frame encoding where the piece→tag direction is needed.
    public func tagID(for piece: Piece) -> CertaboTagID? {
        tagToPiece.first { $0.value == piece }?.key
    }

    init(tagToPiece: [CertaboTagID: Piece]) { self.tagToPiece = tagToPiece }

    // MARK: - Lookup

    /// Returns the piece for a tag ID, or `nil` if empty or unmapped.
    ///
    /// `nil` for effectively-empty tags (D7) and for unknown non-zero tags (D6:
    /// unknown collapses to nil at the FEN boundary emitted by the adapter).
    public func piece(for id: CertaboTagID) -> Piece? {
        guard !id.isEffectivelyEmpty else { return nil }
        return tagToPiece[id]
    }

    /// `true` when no tag-to-piece mappings have been learned.
    public var isEmpty: Bool { tagToPiece.isEmpty }

    // MARK: - Learn

    /// Build a calibration from a set of start-position frames.
    ///
    /// - Parameters:
    ///   - frames: Each element is a 64-element array of tag IDs in stream order
    ///     (index 0 = a8, index 63 = h1). Typically 15 frames are collected;
    ///     the method accepts any count ≥ 1.
    ///   - standardStart: When `true` (the default), assigns pieces according to
    ///     the standard start-position layout plus spare queens at d6 (stream
    ///     index 19) and d3 (stream index 43). Cells whose modal tag is all-zero
    ///     are skipped (D5: spares are optional; backward-compatible with old-style
    ///     calibration that has no spare squares).
    ///
    /// Sources: [OFFICIAL] reader_writer.py; [CER2NUT] CertaboCalibrator; D5/D10.
    public static func learn(
        from frames: [[CertaboTagID]],
        standardStart: Bool = true
    ) -> CertaboCalibration {
        guard !frames.isEmpty else { return CertaboCalibration() }

        // Step 1: modal (most frequent) tag ID per square across frames.
        let squareCount = 64
        var voted = [CertaboTagID](repeating: .zero, count: squareCount)
        for sq in 0..<squareCount {
            var counts: [CertaboTagID: Int] = [:]
            for frame in frames where sq < frame.count {
                counts[frame[sq], default: 0] += 1
            }
            voted[sq] = counts.max(by: { $0.value < $1.value })?.key ?? .zero
        }

        // Step 2: assign pieces to modal tag IDs at fixed stream-index positions.
        guard standardStart else { return CertaboCalibration() }
        var tagToPiece: [CertaboTagID: Piece] = [:]
        for (streamIndex, piece) in standardCalibrationMap {
            guard streamIndex < squareCount else { continue }
            let id = voted[streamIndex]
            guard !id.isAllZero else { continue }  // D5: skip empty (spares optional)
            tagToPiece[id] = piece
        }
        return CertaboCalibration(tagToPiece: tagToPiece)
    }

    /// Add new tag IDs to an existing calibration (add-piece mode).
    ///
    /// Unions newly learned IDs with existing ones. Existing mappings win if
    /// there is a collision (the session layer should warn the user if an ID
    /// maps to a different piece type than expected).
    /// Source: [HAKLEIN] `--addpiece`; [OFFICIAL] add-piece mode.
    public func adding(from frames: [[CertaboTagID]]) -> CertaboCalibration {
        let newCal = CertaboCalibration.learn(from: frames)
        var merged = tagToPiece
        for (id, piece) in newCal.tagToPiece {
            if merged[id] == nil { merged[id] = piece }
            // Collision: existing mapping wins silently at the adapter level.
        }
        return CertaboCalibration(tagToPiece: merged)
    }

    // MARK: - Standard calibration square map

    /// Fixed stream-index → piece assignments for a standard chess start
    /// position, including the two spare queens.
    ///
    /// Stream index formula: i = (8 − rank) × 8 + file (file a=0…h=7).
    ///
    /// - d6 (spare black queen): (8−6)×8 + 3 = 19.
    /// - d3 (spare white queen): (8−3)×8 + 3 = 43.
    ///
    /// Source: [OFFICIAL] reader_writer.py `squares_to_piece` + spare-queen
    /// `# Spare queen` comments; [CER2NUT] CertaboCalibrator identical squares.
    static let standardCalibrationMap: [(streamIndex: Int, piece: Piece)] = {
        var map: [(Int, Piece)] = []
        // Black back rank: stream indices 0..7 → a8..h8
        let blackBack: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for (f, t) in blackBack.enumerated() { map.append((f, Piece(type: t, color: .black))) }
        // Black pawns: stream indices 8..15 → a7..h7
        for f in 0..<8 { map.append((8 + f, Piece(type: .pawn, color: .black))) }
        // White pawns: stream indices 48..55 → a2..h2
        for f in 0..<8 { map.append((48 + f, Piece(type: .pawn, color: .white))) }
        // White back rank: stream indices 56..63 → a1..h1
        let whiteBack: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for (f, t) in whiteBack.enumerated() { map.append((56 + f, Piece(type: t, color: .white))) }
        // Spare queens (D5: newer behavior — d6/d3, skip if zero)
        map.append((19, Piece(type: .queen, color: .black)))   // d6
        map.append((43, Piece(type: .queen, color: .white)))   // d3
        return map
    }()
}

// MARK: - CertaboAdapter

/// Board adapter for the Certabo RFID chess board family and the Tabutronic
/// Sentio occupancy boards.
///
/// ## Board variants handled
///
/// - **Certabo RFID boards** (Oak, S, and others): Each piece has a 5-byte RFID
///   tag. Position frames carry 320 ASCII decimal tokens (64 squares × 5 bytes).
///   Full piece identity when a `CertaboCalibration` is injected; occupancy-only
///   (with calibration samples via `lastVotedTags`) when uncalibrated.
/// - **Tabutronic Sentio family**: Same electronics vendor, same wire framing.
///   Position frames carry 8 ASCII decimal rank bitmasks. Occupancy-only.
///
/// ## Transport
///
/// All three transports produce byte-identical ASCII streams; the adapter is
/// transport-agnostic:
/// - **USB serial**: Silicon Labs CP210x, 38400 baud 8N1, DTR+RTS asserted.
/// - **BT Classic**: Raspberry Pi RFCOMM bridge on channel 10. Byte-identical.
/// - **BLE**: ESP32-S3 module (2023+, Tabutronic-built). Closed firmware targeting
///   the (also closed) ChessConnect extension; GATT UUIDs unpublished and absent
///   from all open source — [OFFICIAL]/[BT] are serial-only, and Chesstimation's
///   Certabo mode is classic-BT serial (its BLE is ChessLink/Pegasus only). The
///   practical community BLE path is [CER2NUT], which presents the board as a
///   Chessnut Air — handled by ChessnutAdapter, not this one.
///
/// ## Square indexing
///
/// Stream index `i` runs a8 (i=0) → h8 (i=7) → a7 (i=8) → … → h1 (i=63).
/// Row-major, rank 8→1, file a→h.
/// Formula: `i = (8 − rank) × 8 + file`, `file(a)=0`.
/// Source: [OFFICIAL] codes.py, [MONO424] `_SQUARES`, [CER2NUT] `toSquare`.
///
/// ## LED bit-order asymmetry (the off-by-mirror trap)
///
/// - Classic LED: `byte[7−rank] |= 1 << file`  (LSB = a-file)
/// - Occupancy decode: `1 << (7 − file)`        (MSB = a-file)
///
/// These are OPPOSITE. Both are confirmed by the golden fixtures.
///
/// ## Frame scanner — cer2nut wrapped-frame support
///
/// Some firmware variants (observed in [CER2NUT] capture logs) wrap RFID frames
/// with bare-LF after every ~65 characters, even splitting a numeric token
/// across the line break ("84 4\\n4 81" → token 44). The scanner uses `\\r\\n`
/// as the primary frame terminator and `\\n` as a secondary terminator only
/// when the accumulated content does not begin with `:` or already constitutes
/// a complete frame. Interior bare-LF wraps inside `:` prefixed frames are
/// stripped and the bytes concatenated before tokenising ([CER2NUT] semantics).
/// BLE colon-less frames are terminated by bare `\\n` (D1).
///
/// ## Discrepancy rulings applied (from pinned spec)
///
/// - [DISCREPANCY D1] ':' prefix: scan to ':', strip it; accept ':'-less lines too (BLE).
/// - [DISCREPANCY D2] High-bit masking: NOT applied (non-ASCII invalidates the line).
/// - [DISCREPANCY D3] Terminator: `\r\n` primary; bare `\n` secondary (see scanner note).
/// - [DISCREPANCY D4] LED pacing: transport's responsibility; adapter is a pure codec.
/// - [DISCREPANCY D5] Spare queens: d6/d3, skip-if-empty.
/// - [DISCREPANCY D6] Unknown ids: exposed as nil in identitySnapshot; session queries
///                    lastVotedTags for re-calibration prompt.
/// - [DISCREPANCY D7] Empty test: all-zero authoritative; ≥3-zeros as secondary heuristic.
/// - [DISCREPANCY D8] mono424 bugs: NOT copied (skipToNextStart, 384-byte gate, etc.).
/// - [DISCREPANCY D9] Board-type detection: token count (320 vs 8); L/D for LED type.
/// - [DISCREPANCY D10] Calibration sample count: 15-frame modal vote.
///
/// ## Capabilities
///
/// Capabilities are derived from detected board state (D9). Pre-detection default
/// assumes classic single-color LED and no piece identity:
/// `[.occupancySensing, .moveIndication, .perSquareLEDs]`.
///
/// - `.pieceIdentity` is added only when an RFID board is detected AND a
///   `CertaboCalibration` is provided. Tabutronic Sentio boards are
///   occupancy-only and never satisfy the pieceIdentity contract.
/// - `.perSquareLEDs` is dropped when the board reports `D` (Spectrum RGB
///   corner-LED grid, 9×9 shared-corner points). The RGB variant gets
///   `.moveIndication` only — same as Millennium per BoardCapabilities.swift.
///
/// ## Calibration UX seam
///
/// `lastVotedTags` is the proper seam-safe channel for calibration data.
/// After each RFID frame, `lastVotedTags` holds the 64-element majority-voted
/// tag array (stream order). The session accumulates 15 such snapshots and
/// calls `CertaboCalibration.learn(from:)`. Session code must NOT branch on
/// `BoardEvent.raw` for calibration; `.raw` is for capture-log research only.
///
/// ## HARDWARE STATUS
///
/// Partially verified — LED encoder and occupancy decoder confirmed against
/// [MONO424] (MIT) and [CER2NUT] golden fixtures. RFID wrapped-frame scanner
/// confirmed against the [CER2NUT] CertaboParser fixture family. Awaiting
/// physical-board or USB/BT capture-log validation for the full runtime path.
public struct CertaboAdapter: BoardAdapter {

    // MARK: - Injectable state

    /// Piece-identity calibration. `nil` = uncalibrated (occupancy-only output).
    ///
    /// When nil, the adapter emits `.occupancySnapshot`. The voted tag array is
    /// available on `lastVotedTags` so the session can drive the calibration UX
    /// and inject a new `CertaboCalibration` when done.
    public var calibration: CertaboCalibration?

    /// Apply 180° rotation symmetrically to incoming square indices and outgoing
    /// LED bytes. Set when the board is physically rotated so the h1 corner is
    /// nearest the white player.
    ///
    /// Rotation formula: `i' = 63 − i`. Never a single-axis mirror.
    /// Source: [OFFICIAL] move2led(rotate180); [MONO424] reverseBoardOrientation.
    public var rotate180: Bool

    // MARK: - Calibration UX seam

    /// The 64-element majority-voted RFID tag array (stream order: a8=0…h1=63)
    /// from the most recent RFID position frame.
    ///
    /// This is the seam-safe channel for driving the calibration UX. The session
    /// accumulates 15 snapshots and calls `CertaboCalibration.learn(from:)`.
    /// Updated after every RFID frame regardless of calibration state.
    /// `nil` until the first RFID frame is processed.
    public private(set) var lastVotedTags: [CertaboTagID]? = nil

    // MARK: - Parser state

    /// LED hardware type, updated from `L`/`D` status lines in the stream (D9).
    private var ledType: CertaboLEDType = .undecided

    /// Board type detected from frame token count (D9).
    /// `nil` until the first valid position frame arrives.
    private var detectedBoardType: CertaboBoardType? = nil

    /// Raw byte accumulator. Holds bytes arriving mid-frame.
    private var buffer: [UInt8] = []

    /// Frame accumulator for cer2nut-style wrapped RFID frames.
    ///
    /// Bytes from lines terminated by bare-LF that are NOT a complete frame
    /// (and start with `:`) are appended here rather than flushed. When the
    /// definitive `\r\n` terminator arrives the full accumulated content is
    /// processed as one logical frame ([CER2NUT] CertaboParser semantics).
    private var frameAccumulator: [UInt8] = []

    /// Ring buffer of up to 3 recent RFID frames for majority-vote debounce.
    /// Each element is a 64-element array of tag IDs (stream order).
    /// Source: [OFFICIAL] `usb_data_history_depth = 3`; [CER2NUT] history of 3.
    private var rfidHistory: [[CertaboTagID]] = []

    /// Ring buffer of up to 3 recent occupancy frames for debounce.
    private var occupancyHistory: [[Bool]] = []

    /// Last emitted file-major identity array. Used for `squareSensed` diffs.
    /// `nil` until the first frame is processed.
    private var previousIdentity: [Piece?]? = nil

    /// Last emitted file-major occupancy array (occupancy boards + uncalibrated RFID).
    private var previousOccupancy: [Bool]? = nil

    /// `true` after the first `.ready` event has been emitted.
    private var hasEmittedReady: Bool = false

    // MARK: - BoardAdapter conformance

    /// Advertised capabilities, derived from detected board state (D9).
    ///
    /// Pre-detection default: `[.occupancySensing, .moveIndication, .perSquareLEDs]`
    /// (classic single-color LED assumed until a `D` status line is seen;
    /// `.pieceIdentity` omitted until an RFID board is detected AND calibrated).
    ///
    /// Post-detection updates:
    /// - RFID board detected + `calibration` non-nil → adds `.pieceIdentity`.
    /// - `D` status line received → drops `.perSquareLEDs` (Spectrum RGB is a
    ///   9×9 corner-LED grid; `.moveIndication` only, per Millennium precedent).
    /// - Tabutronic Sentio (8-token occupancy frames) → `.pieceIdentity` never added.
    public var capabilities: BoardCapabilities {
        var caps: BoardCapabilities = [.occupancySensing, .moveIndication]
        // Spectrum RGB corner-LED grid: .moveIndication only (9×9 shared-corner
        // points, not individually addressable per-square). Pre-detection and
        // classic-LED boards both include .perSquareLEDs.
        if ledType != .rgb {
            caps.insert(.perSquareLEDs)
        }
        // .pieceIdentity: only when an RFID board is detected AND calibrated.
        // Uncalibrated RFID and all Tabutronic Sentio boards emit occupancySnapshot
        // only and must NOT advertise pieceIdentity.
        if detectedBoardType == .rfid, calibration != nil {
            caps.insert(.pieceIdentity)
        }
        return caps
    }

    public init(calibration: CertaboCalibration? = nil, rotate180: Bool = false) {
        self.calibration = calibration
        self.rotate180 = rotate180
    }

    /// Feed raw transport bytes through the Certabo ASCII frame scanner.
    ///
    /// Frames are ASCII lines terminated by `\r\n` (primary) or bare `\n`
    /// (secondary, for BLE colon-less frames and short single-line frames).
    /// Interior bare-`\n` wraps inside `:` prefixed RFID frames are stripped
    /// and accumulated before tokenising ([CER2NUT] wrapped-frame semantics).
    /// Partial frames are buffered across calls. Non-ASCII bytes invalidate
    /// the current partial frame (D2).
    public mutating func feed(bytes: Data) -> [BoardEvent] {
        buffer.append(contentsOf: bytes)
        return processBuffer()
    }

    /// Encode a `BoardCommand` to its Certabo wire representation.
    ///
    /// - `.indicateSquares`: classic 8-byte frame (or 247-byte RGB if the board
    ///   reported `D` in its stream). Pacing (≥600 ms between different frames)
    ///   is the **transport's** responsibility (D4).
    /// - `.startSession` / `.requestState`: `nil` (no handshake; board streams
    ///   continuously on port open).
    /// - `.executeMove`: `nil` (Certabo boards are not motorised).
    /// - `.custom(data)`: forwarded verbatim.
    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession, .requestState:
            return nil  // no handshake needed; board streams on port open
        case .indicateSquares(let squares, _):
            return ledType == .rgb ? encodeRGBLED(squares: squares)
                                   : encodeClassicLED(squares: squares)
        case .executeMove:
            return nil  // not motorised
        case .custom(let data):
            return data
        }
    }

    /// Handshake sequence after the transport link is established.
    ///
    /// Empty — the Certabo board streams unsolicited immediately when the serial
    /// port is opened (DTR/RTS asserted by the transport). No host command is
    /// required. Source: [MONO424] README; [OFFICIAL] usbtool.py.
    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: Duration)] {
        []
    }

    // MARK: - Frame scanner

    /// Scan the buffer for complete frames and process each one.
    ///
    /// Primary terminator: `\r\n` (CRLF). Everything accumulated in
    /// `frameAccumulator` up to the CRLF is flushed as one logical frame,
    /// with any interior `\r`/`\n` bytes already stripped during accumulation.
    ///
    /// Secondary terminator: bare `\n` (LF only). Flushes immediately when
    /// the accumulated content does NOT start with `:`, OR starts with `:`
    /// and already constitutes a complete frame. When the content starts with
    /// `:` but is not yet complete, the bare LF is treated as an interior
    /// line-wrap and stripped ([CER2NUT] wrapped RFID frame semantics).
    private mutating func processBuffer() -> [BoardEvent] {
        var events: [BoardEvent] = []
        while let lfIdx = buffer.firstIndex(of: 0x0A) {
            let hasCR = lfIdx > 0 && buffer[lfIdx - 1] == 0x0D
            let chunkEnd = hasCR ? lfIdx - 1 : lfIdx
            // Append content bytes to accumulator; strip any CR bytes.
            frameAccumulator += buffer.prefix(chunkEnd).filter { $0 != 0x0D }
            buffer.removeFirst(lfIdx + 1)

            if hasCR {
                // Definitive frame end (CRLF): flush the full accumulator.
                let content = frameAccumulator
                frameAccumulator = []
                events += processLineBytes(content)
            } else {
                // Bare LF: flush unless this looks like an interior line-wrap
                // inside a ':'-prefixed cer2nut wrapped RFID frame.
                let startsWithColon = frameAccumulator.first == UInt8(ascii: ":")
                if !startsWithColon || isFrameComplete(frameAccumulator) {
                    let content = frameAccumulator
                    frameAccumulator = []
                    events += processLineBytes(content)
                }
                // else: keep accumulating — the bare LF was an interior wrap.
            }
        }
        // Resync guard: prevent unbounded growth on a garbage stream.
        if buffer.count + frameAccumulator.count > 4096 {
            if let colonIdx = buffer.firstIndex(of: 0x3A) {
                buffer.removeFirst(colonIdx)
            } else {
                buffer.removeAll()
            }
            frameAccumulator.removeAll()
        }
        return events
    }

    /// Returns `true` when `bytes` constitute a complete Certabo ASCII frame:
    /// exactly 8 or 320 space-separated tokens (after stripping the leading `:`),
    /// or a standalone `L`/`D` status character, or an empty/whitespace-only line.
    ///
    /// Used to decide whether a bare-LF should close a `:` prefixed frame or
    /// be treated as an interior line-wrap ([CER2NUT] wrapped RFID semantics).
    private func isFrameComplete(_ bytes: [UInt8]) -> Bool {
        guard bytes.allSatisfy({ $0 <= 127 }) else { return true }  // non-ASCII → flush to reject
        guard let s = String(bytes: bytes, encoding: .ascii) else { return true }
        let tokenStr = s.hasPrefix(":") ? String(s.dropFirst()) : s
        let trimmed = tokenStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "L" || trimmed == "D" { return true }
        let count = trimmed.split(separator: " ", omittingEmptySubsequences: true).count
        return count == CertaboSerial.rfidTokenCount
            || count == CertaboSerial.occupancyTokenCount
            || count == 0
    }

    /// Process one decoded frame (bytes already stripped of `\r`/`\n` by the
    /// accumulator). Applies D2 non-ASCII rejection, D1 colon stripping, and
    /// D9 token-count dispatch.
    private mutating func processLineBytes(_ bytes: [UInt8]) -> [BoardEvent] {
        // D2: reject non-ASCII bytes.
        guard bytes.allSatisfy({ $0 <= 127 }) else { return [] }

        // Convert to string and trim leading/trailing whitespace (D3).
        let trimmed = (String(bytes: bytes, encoding: .ascii) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // D9: LED-type status lines.
        if trimmed == "L" { ledType = .classic; return [] }
        if trimmed == "D" { ledType = .rgb;     return [] }

        // D1: strip leading ':' if present.
        let tokenStr = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
        guard !tokenStr.isEmpty else { return [] }

        let parts = tokenStr.split(separator: " ", omittingEmptySubsequences: true)

        switch parts.count {
        case CertaboSerial.rfidTokenCount:
            return processRFIDTokens(parts)
        case CertaboSerial.occupancyTokenCount:
            return processOccupancyTokens(parts)
        default:
            return []  // unknown token count → ignore / resync
        }
    }

    // MARK: - RFID frame processing

    private mutating func processRFIDTokens(_ parts: [Substring]) -> [BoardEvent] {
        detectedBoardType = .rfid
        // Parse 64 × 5 = 320 tokens into tag IDs.
        var frame = [CertaboTagID](repeating: .zero, count: 64)
        for sq in 0..<64 {
            let base = sq * 5
            guard let b0 = UInt8(parts[base]),
                  let b1 = UInt8(parts[base + 1]),
                  let b2 = UInt8(parts[base + 2]),
                  let b3 = UInt8(parts[base + 3]),
                  let b4 = UInt8(parts[base + 4]) else { return [] }
            frame[sq] = CertaboTagID(b0, b1, b2, b3, b4)
        }
        // Majority-vote debounce over last 3 frames (D10 / runtime debounce).
        rfidHistory.append(frame)
        if rfidHistory.count > 3 { rfidHistory.removeFirst() }
        let voted = rfidMajorityVote()
        lastVotedTags = voted   // expose for calibration UX (seam-safe channel)
        return emitRFIDEvents(voted: voted)
    }

    /// Mode per square over the RFID history (up to 3 frames).
    ///
    /// Tie-breaking: when two values are equally frequent, the most recent
    /// frame's value wins (favours the new stable state after a move).
    private func rfidMajorityVote() -> [CertaboTagID] {
        var result = [CertaboTagID](repeating: .zero, count: 64)
        for sq in 0..<64 {
            // Build counts; iterate frames oldest→newest so that on a tie,
            // the last-inserted (most recent) key survives Dictionary ordering
            // by being the last to match the max count.
            var counts: [CertaboTagID: Int] = [:]
            for frame in rfidHistory { counts[frame[sq], default: 0] += 1 }
            let maxCount = counts.values.max() ?? 0
            // Among entries with the max count, prefer the most recent frame's value.
            var winner: CertaboTagID = .zero
            for frame in rfidHistory {
                if counts[frame[sq]] == maxCount { winner = frame[sq] }
            }
            result[sq] = winner
        }
        return result
    }

    private mutating func emitRFIDEvents(voted: [CertaboTagID]) -> [BoardEvent] {
        let isFirst = !hasEmittedReady

        // Build file-major identity array, applying optional rotation.
        var identity = [Piece?](repeating: nil, count: 64)
        var hasUnknownTags = false
        var occupancy = [Bool](repeating: false, count: 64)

        for streamIdx in 0..<64 {
            let effectiveStream = rotate180 ? (63 - streamIdx) : streamIdx
            let tagID = voted[effectiveStream]
            let fm = Self.streamIndexToFileMajor(streamIdx)

            if tagID.isEffectivelyEmpty {
                // Empty square — both identity and occupancy stay false/nil.
            } else if let cal = calibration {
                if let piece = cal.piece(for: tagID) {
                    identity[fm] = piece
                    occupancy[fm] = true
                } else {
                    // D6: non-empty unmapped tag → unknown; collapses to nil at
                    // FEN boundary. Session uses lastVotedTags to prompt recal.
                    occupancy[fm] = true
                    hasUnknownTags = true
                }
            } else {
                // Uncalibrated: record occupancy from non-empty tag.
                occupancy[fm] = true
            }
        }

        var events: [BoardEvent] = []

        if calibration != nil {
            // ── Calibrated path ──────────────────────────────────────────────
            events.append(.identitySnapshot(identity))
            if let prev = previousIdentity {
                events += squareSensedDeltas(previous: prev, current: identity)
            }
            // D6: unknown tags signal re-calibration need. Session reads
            // lastVotedTags (already updated in processRFIDTokens) to build
            // the prompt. No .raw emission — .raw is for capture-log research.
            _ = hasUnknownTags  // acknowledged; session polls lastVotedTags
            previousIdentity = identity
        } else {
            // ── Uncalibrated path ─────────────────────────────────────────────
            // Emit occupancy events. Session reads lastVotedTags (already
            // updated in processRFIDTokens) to drive the calibration UX.
            events.append(.occupancySnapshot(occupancy))
            if let prev = previousOccupancy {
                events += occupancyDeltas(previous: prev, current: occupancy)
            }
            previousOccupancy = occupancy
            // Keep previousIdentity = nil so the first calibrated frame after
            // calibration injection skips delta emission (no phantom place events).
            // An all-nil array here would look like a valid prior snapshot and
            // trigger up to 32 spurious .squareSensed(place) events.
            previousIdentity = nil
        }

        if isFirst {
            hasEmittedReady = true
            events.append(.ready)
        }

        return events
    }

    // MARK: - Occupancy frame processing

    /// Parse 8 rank bitmasks from a Tabutronic Sentio occupancy frame.
    ///
    /// Number `k` covers rank `(8−k)` (1-indexed); bit for file `f` is
    /// `1 << (7−f)` (MSB = a-file).
    ///
    /// [DISCREPANCY] NOTE: This bit order is the **opposite** of the classic
    /// LED command's LSB=a-file convention. Both are confirmed by golden fixtures.
    ///
    /// Source: [MONO424] parseTabutronic; [CER2NUT] col 7..0 loop.
    private mutating func processOccupancyTokens(_ parts: [Substring]) -> [BoardEvent] {
        detectedBoardType = .occupancy
        var frame = [Bool](repeating: false, count: 64)
        for k in 0..<8 {
            guard let mask = UInt8(parts[k]) else { return [] }
            let rank = 7 - k   // 0-indexed: k=0 → rank-8 → index 7; k=7 → rank-1 → index 0
            for file in 0..<8 {
                let bit = mask & (1 << (7 - file))   // MSB = a-file
                let fm = file * 8 + rank
                frame[fm] = bit != 0
            }
        }

        // Apply 180° rotation if requested.
        let applied: [Bool]
        if rotate180 {
            // Rotate: for each output fileMajor, read from the rotated source square.
            applied = (0..<64).map { fm -> Bool in
                let rotatedFM = Self.rotateFileMajor180(fm)
                return frame[rotatedFM]
            }
        } else {
            applied = frame
        }

        occupancyHistory.append(applied)
        if occupancyHistory.count > 3 { occupancyHistory.removeFirst() }
        let voted = occupancyMajorityVote()
        return emitOccupancyEvents(voted: voted)
    }

    /// Majority vote (simple threshold) over the occupancy history.
    private func occupancyMajorityVote() -> [Bool] {
        (0..<64).map { sq in
            let trueCount = occupancyHistory.filter { $0[sq] }.count
            // Favour the most recent frame's value on a tie (same logic as RFID).
            if trueCount * 2 == occupancyHistory.count {
                return occupancyHistory.last?[sq] ?? false
            }
            return trueCount * 2 > occupancyHistory.count
        }
    }

    private mutating func emitOccupancyEvents(voted: [Bool]) -> [BoardEvent] {
        let isFirst = !hasEmittedReady
        var events: [BoardEvent] = []
        events.append(.occupancySnapshot(voted))
        if let prev = previousOccupancy {
            events += occupancyDeltas(previous: prev, current: voted)
        }
        previousOccupancy = voted
        if isFirst {
            hasEmittedReady = true
            events.append(.ready)
        }
        return events
    }

    // MARK: - Delta helpers

    private func squareSensedDeltas(previous: [Piece?], current: [Piece?]) -> [BoardEvent] {
        var events: [BoardEvent] = []
        for fm in 0..<64 {
            let p = previous[fm]; let c = current[fm]
            guard p != c else { continue }
            let sq = Self.fileMajorToAlgebraic(fm)
            if p == nil {
                // empty → occupied: place event.
                events.append(.squareSensed(square: sq, isLift: false, piece: c))
            } else if c == nil {
                // occupied → empty: lift event.
                events.append(.squareSensed(square: sq, isLift: true,  piece: p))
            } else {
                // occupied → occupied (different piece): lift old piece, then place new piece.
                // Reachable via the 3-frame majority-vote tie-break: a capture sequence
                // (pawn@e5 → empty → knight@e5) votes to a direct pawn→knight transition
                // with no empty intermediate. Emit both events so the delta channel
                // stays consistent with the accompanying identitySnapshot.
                events.append(.squareSensed(square: sq, isLift: true,  piece: p))
                events.append(.squareSensed(square: sq, isLift: false, piece: c))
            }
        }
        return events
    }

    private func occupancyDeltas(previous: [Bool], current: [Bool]) -> [BoardEvent] {
        var events: [BoardEvent] = []
        for fm in 0..<64 {
            guard previous[fm] != current[fm] else { continue }
            let sq = Self.fileMajorToAlgebraic(fm)
            events.append(.squareSensed(square: sq, isLift: previous[fm], piece: nil))
        }
        return events
    }

    // MARK: - LED encoding

    /// Encode a classic single-color LED command: 8 raw binary bytes.
    ///
    /// `byte[7−rank] |= 1 << file`  (rank 0-indexed, LSB = a-file).
    ///
    /// Confirmed by three independent sources:
    /// - [OFFICIAL] reader_writer.py docstring: `['e2','e4'] = [0,0,0,0,16,0,16,0]`
    /// - [OFFICIAL] codes.py `move2led`: `(8-4, 2^4, 8-2, 2^4)` = bytes 4=0x10, 6=0x10
    /// - [MONO424] LEDPattern: `bytePattern[i] += 1 << j`
    ///
    /// Shutdown: send all-off = `Data(repeating: 0, count: 8)` (pass empty squares).
    /// Pacing: ≥600 ms between different frames is the transport's responsibility (D4).
    private func encodeClassicLED(squares: [String]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        for s in squares {
            guard let sq = Square(algebraic: s) else { continue }
            var file = sq.file   // a=0…h=7
            var rank = sq.rank   // 0-indexed
            if rotate180 { file = 7 - file; rank = 7 - rank }
            bytes[7 - rank] |= 1 << file
        }
        return Data(bytes)
    }

    /// Encode a Spectrum RGB LED command: 247-byte frame.
    ///
    /// Format: `0xFF 0x55 | 81 LEDs × 3 bytes RGB | 0x0D 0x0A` (247 bytes total).
    ///
    /// The LEDs form a 9×9 grid of square-corner points. Each board square lights
    /// its 4 corner LEDs in the 9×9 grid; adjacent squares share corners.
    /// Default brightness 0x40 written to the Blue (index+2) channel.
    ///
    /// Grid mapping for stream index `s` (0=a8):
    ///   `row = 7 − s/8`,  `col = 7 − s%8`
    ///   `base = (row × 9 + col) × 3`  (payload offset)
    ///   4 corner LED payload offsets: `{base, base+3, base+27, base+30}`
    ///   Blue channel payload offsets: `{base+2, base+5, base+29, base+32}`
    ///
    /// Source: [CER2NUT] RgbLedCommandTranslator (single source — facts only;
    /// see Spec Risks). Verified byte-for-byte against cer2nut test vectors.
    private func encodeRGBLED(squares: [String]) -> Data {
        var payload = [UInt8](repeating: 0, count: 243)   // 81 LEDs × 3
        for s in squares {
            guard let sq = Square(algebraic: s) else { continue }
            var file = sq.file
            var rank = sq.rank
            if rotate180 { file = 7 - file; rank = 7 - rank }
            let streamIdx = (7 - rank) * 8 + file
            let row = 7 - streamIdx / 8
            let col = 7 - streamIdx % 8
            let base = (row * 9 + col) * 3
            for cornerBase in [base, base + 3, base + 27, base + 30] {
                let blueOff = cornerBase + 2
                if blueOff < payload.count { payload[blueOff] = 0x40 }
            }
        }
        var frame = Data(capacity: 247)
        frame.append(0xFF); frame.append(0x55)
        frame.append(contentsOf: payload)
        frame.append(0x0D); frame.append(0x0A)
        return frame
    }

    // MARK: - Index conversion helpers

    /// Convert stream index (0=a8, 63=h1) to file-major index (a1=0, h8=63).
    ///
    /// Stream: `i = (8−rank) × 8 + file`  →  `file = i%8`, `rank₀ = 7 − i/8`
    /// File-major: `file × 8 + rank₀`
    ///
    /// Confirmed: [OFFICIAL] codes.py, [MONO424] `_SQUARES`, [CER2NUT] `toSquare`.
    public static func streamIndexToFileMajor(_ i: Int) -> Int {
        let file = i % 8
        let rank = 7 - i / 8
        return file * 8 + rank
    }

    /// Convert file-major index (a1=0, h8=63) to stream index (0=a8, 63=h1).
    static func fileMajorToStreamIndex(_ fm: Int) -> Int {
        let file = fm / 8
        let rank = fm % 8
        return (7 - rank) * 8 + file
    }

    /// Rotate a file-major index 180°: `i → 63 − i` in stream space.
    static func rotateFileMajor180(_ fm: Int) -> Int {
        let s = fileMajorToStreamIndex(fm)
        return streamIndexToFileMajor(63 - s)
    }

    /// Algebraic notation for a file-major index.
    static func fileMajorToAlgebraic(_ fm: Int) -> String {
        let file = fm / 8
        let rank = fm % 8
        let fileChar = Character(UnicodeScalar(97 + file)!)
        return "\(fileChar)\(rank + 1)"
    }
}
