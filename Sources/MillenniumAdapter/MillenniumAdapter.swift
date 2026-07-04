import Foundation
import ChessCore
import BoardKit

// ── Millennium ChessLink adapter ──────────────────────────────────────────────
//
// HARDWARE STATUS: protocol-verified against domschl/python-mchess (MIT) and
// alstrup/chesslink (MIT); awaiting physical-board or capture-log validation.
//
// Sources consulted:
//   [MCHESS]  domschl/python-mchess — magic-board.md + chess_link*.py (MIT)
//   [ALSTRUP] alstrup/chesslink — independent WebBluetooth implementation (MIT)
//   [GONEILL] Graham O'Neill Millennium driver readme — facts only (proprietary)

// MARK: - Transport constants

/// BLE and USB constants for the Millennium ChessLink family.
///
/// Boards: ChessGenius Exclusive + Supreme (via external ChessLink module M822),
/// and eONE (M841, built-in ChessLink). BLE + USB-HID + Bluetooth Classic SPP.
///
/// Source: [MCHESS] chess_link_bluepy.py + chess_link_usb.py; confirmed by [ALSTRUP].
public enum MillenniumGATT {
    /// Advertised BLE device name. [MCHESS] matches as substring; [ALSTRUP] exact.
    public static let advertisedName    = "MILLENNIUM CHESS"
    /// Microchip/ISSC Transparent UART service UUID. [MCHESS] chess_link_bluepy.py.
    public static let serviceUUID       = "49535343-FE7D-4AE5-8FA9-9FAFD205E455"
    /// Board→host notification characteristic. Subscribe by writing 0x0001 to CCCD.
    public static let notifyCharUUID    = "49535343-1E4D-4BD9-BA61-23C647249616"
    /// Host→board write characteristic. Use write-with-response.
    /// L-frame (167 bytes) may exceed ATT MTU — fragment writes at ~200 bytes.
    public static let writeCharUUID     = "49535343-8841-43F4-A8D4-ECBE34729BB3"
    /// USB FTDI FT232: VID 0x0403, PID 0x6001. Open 38400 8N1, DTR=0, software parity.
    /// [DISCREPANCY D6]: doc says 7O1; proven path is 8N1 + software parity. [MCHESS].
    public static let usbVendorID:  UInt16 = 0x0403
    public static let usbProductID: UInt16 = 0x6001
    /// Minimum spacing between outgoing BLE frames (empirical, not in spec). [MCHESS].
    public static let bleMinFrameSpacingMs: Int = 100

    /// Returns true when `name` belongs to a Millennium board.
    public static func isMillennium(name: String) -> Bool { name.contains(advertisedName) }
}

// MARK: - Wire helpers (internal)

/// Add odd parity to a 7-bit ASCII byte.
///
/// Bit 7 is set iff popcount(low 7 bits) is even, producing odd parity across
/// all 8 bits. Applied to EVERY wire byte (command chars, payload, checksum chars).
///
/// [DISCREPANCY D5]: XOR checksum is computed over 7-bit values (pre-parity),
/// verified post-mask. Both [MCHESS] and [ALSTRUP] agree; validated by Fixture 2
/// byte log. Fixture 1 wire D6 B5 B6 confirmed byte-identical to chess_link.py log.
func millenniumOddParityByte(_ byte: UInt8) -> UInt8 {
    let v = byte & 0x7F
    return v.nonzeroBitCount % 2 == 0 ? v | 0x80 : v
}

/// Compute the 2-char uppercase hex XOR block checksum.
///
/// XOR of 7-bit ASCII values of every frame char before the checksum.
/// Always zero-padded to exactly 2 chars.
///
/// [DISCREPANCY D3]: alstrup `toString(16).toUpperCase()` emits 1 char when
/// XOR < 0x10 — latent bug that breaks fixed-length framing. We always
/// emit 2 chars per spec and [MCHESS].
func computeMillenniumChecksum(_ frameChars: [UInt8]) -> String {
    let xor = frameChars.reduce(UInt8(0)) { $0 ^ ($1 & 0x7F) }
    return String(format: "%02X", xor)
}

/// Build a complete wire frame: ASCII chars + checksum + odd-parity encoding.
///
/// `asciiChars` is the command char + payload (7-bit ASCII values, no parity).
/// Returns the full wire-ready Data (including 2-char checksum), all parity-encoded.
func millenniumBuildFrame(_ asciiChars: [UInt8]) -> Data {
    let chk = computeMillenniumChecksum(asciiChars)
    let all = asciiChars + Array(chk.utf8)
    return Data(all.map { millenniumOddParityByte($0) })
}

// MARK: - Piece codec (internal)

/// Maps s-frame piece chars to ChessCore Piece values.
/// K Q R N B P (white upper), k q r n b p (black lower), '.' → nil (empty).
/// [MCHESS] magic-board.md §4 piece identity chars.
let millenniumPieceByChar: [UInt8: Piece] = [
    UInt8(ascii: "K"): Piece(type: .king,   color: .white),
    UInt8(ascii: "Q"): Piece(type: .queen,  color: .white),
    UInt8(ascii: "R"): Piece(type: .rook,   color: .white),
    UInt8(ascii: "N"): Piece(type: .knight, color: .white),
    UInt8(ascii: "B"): Piece(type: .bishop, color: .white),
    UInt8(ascii: "P"): Piece(type: .pawn,   color: .white),
    UInt8(ascii: "k"): Piece(type: .king,   color: .black),
    UInt8(ascii: "q"): Piece(type: .queen,  color: .black),
    UInt8(ascii: "r"): Piece(type: .rook,   color: .black),
    UInt8(ascii: "n"): Piece(type: .knight, color: .black),
    UInt8(ascii: "b"): Piece(type: .bishop, color: .black),
    UInt8(ascii: "p"): Piece(type: .pawn,   color: .black),
]

func millenniumCharFromPiece(_ piece: Piece?) -> UInt8 {
    guard let piece else { return UInt8(ascii: ".") }
    switch (piece.type, piece.color) {
    case (.king,   .white): return UInt8(ascii: "K")
    case (.queen,  .white): return UInt8(ascii: "Q")
    case (.rook,   .white): return UInt8(ascii: "R")
    case (.knight, .white): return UInt8(ascii: "N")
    case (.bishop, .white): return UInt8(ascii: "B")
    case (.pawn,   .white): return UInt8(ascii: "P")
    case (.king,   .black): return UInt8(ascii: "k")
    case (.queen,  .black): return UInt8(ascii: "q")
    case (.rook,   .black): return UInt8(ascii: "r")
    case (.knight, .black): return UInt8(ascii: "n")
    case (.bishop, .black): return UInt8(ascii: "b")
    case (.pawn,   .black): return UInt8(ascii: "p")
    }
}

// MARK: - Square index (internal)

/// Convert s-frame payload index k (A8=0 … H1=63) to file-major index (a1=0 … h8=63).
///
/// Payload order: A8,B8,…,H8, A7,…,H7, …, A1,…,H1 (FEN board reading order).
/// [MCHESS] magic-board.md: "Data order is A8...H8,A7...H7 etc."
///
/// Sentinels: k=0→a8 (fileMajor=7), k=7→h8 (fileMajor=63), k=56→a1 (fileMajor=0),
///            k=63→h1 (fileMajor=56).
func millenniumSquareToFileMajor(_ k: Int) -> Int {
    let file   = k % 8
    let rank_0 = 7 - k / 8   // 0-indexed: 0=rank1 … 7=rank8
    return file * 8 + rank_0
}

/// Inverse: file-major index → s-frame payload index k.
func millenniumFileMajorToK(_ fm: Int) -> Int {
    let file   = fm / 8
    let rank_0 = fm % 8
    return file + (7 - rank_0) * 8
}

// MARK: - LED helpers (internal)

/// Map a chess square to its 4 corner LED numbers (1-based, 1…81).
///
/// The 81 LEDs sit on the 9×9 grid of square CORNERS. LED N = 9·i + j + 1
/// where i = vertical-line index (0=left of a-file … 8=right of h-file),
///       j = horizontal-line index (0=rank8-outer-edge … 8=rank1-outer-edge).
///
/// Square (file f=0..7, rank r=1..8) → corners at i∈{f, f+1}, j∈{8-r, 9-r}.
/// Fixture 6: e2 (f=4, r=2) → LEDs 43,44,53,54. ✓
/// Spec anchors: N=1→A8-corner [i=0,j=0]; N=9→A1; N=73→H8; N=81→H1. [MCHESS] §5.
public func millenniumSquareToCornerLEDs(file f: Int, rank r: Int) -> [Int] {
    let j0 = 8 - r
    let j1 = 9 - r
    return [
        9 * f       + j0 + 1,
        9 * f       + j1 + 1,
        9 * (f + 1) + j0 + 1,
        9 * (f + 1) + j1 + 1,
    ]
}

/// 180° rotation of a corner LED number. (i,j) → (8-i, 8-j) ≡ N → 82-N.
/// Applied to LED frames when `isRotated` is true. [MCHESS] magic-board.md §4.
func millenniumRotateLED(_ n: Int) -> Int { 82 - n }

/// Encode an L (LED pattern) frame (167 wire bytes).
///
/// - frameSlotTime: 2-char slot-duration field (e.g. 0x0F = 61 ms/slot).
/// - ledPattern: pattern byte for lit LED corners (0xFF = solid on).
/// - isRotated: when true, apply 180° rotation (N → 82-N).
///
/// [MCHESS] magic-board.md §5; Fixture 6.
func millenniumLEDFrame(squares: [String], frameSlotTime: UInt8 = 0x0F,
                        ledPattern: UInt8 = 0xFF, isRotated: Bool = false) -> Data {
    var patterns = [UInt8](repeating: 0x00, count: 81)
    for algebraic in squares {
        guard let sq = Square(algebraic: algebraic) else { continue }
        let r = sq.rank + 1   // convert 0-indexed rank to 1-indexed
        for n in millenniumSquareToCornerLEDs(file: sq.file, rank: r) {
            guard n >= 1, n <= 81 else { continue }
            let idx = isRotated ? (millenniumRotateLED(n) - 1) : (n - 1)
            if idx >= 0, idx < 81 { patterns[idx] = ledPattern }
        }
    }
    var ascii = [UInt8]()
    ascii.reserveCapacity(165)
    ascii.append(UInt8(ascii: "L"))
    ascii += Array(String(format: "%02X", frameSlotTime).utf8)
    for p in patterns { ascii += Array(String(format: "%02X", p).utf8) }
    return millenniumBuildFrame(ascii)
}

// MARK: - Delta events (internal)

/// Compute squareSensed lift/place deltas between two consecutive identity snapshots.
/// Both arrays are file-major (a1=0 … h8=63).
func millenniumDeltaEvents(prev: [Piece?], curr: [Piece?]) -> [BoardEvent] {
    var events: [BoardEvent] = []
    let files = Array("abcdefgh")
    for file in 0..<8 {
        for rank in 0..<8 {
            let idx = file * 8 + rank
            if prev[idx] == nil, let placed = curr[idx] {
                events.append(.squareSensed(square: "\(files[file])\(rank + 1)", isLift: false, piece: placed))
            } else if let lifted = prev[idx], curr[idx] == nil {
                events.append(.squareSensed(square: "\(files[file])\(rank + 1)", isLift: true, piece: lifted))
            }
        }
    }
    return events
}

// MARK: - Frame length table (internal)

/// Expected frame length in chars (including 2-char Chk) per frame-type char.
/// [MCHESS] chess_link_protocol.py length table. 't' NOT included — no reply to T.
/// [DISCREPANCY D2]: alstrup speculatively listens for 't'; doc says no reply; we ignore.
let millenniumFrameLengths: [UInt8: Int] = [
    0x76: 7,   // 'v' firmware version reply
    0x73: 67,  // 's' board status (64 piece chars + 's' + Chk)
    0x6C: 3,   // 'l' LED-set ack
    0x78: 3,   // 'x' extinguish ack
    0x77: 7,   // 'w' E2ROM write ack (echoes addr + data)
    0x72: 7,   // 'r' E2ROM read reply (addr + data)
]

// MARK: - MillenniumAdapter

/// Board adapter for the Millennium ChessLink family.
///
/// ## Protocol overview
/// Text-framed (7-bit ASCII). Per-character odd-parity encoding on the wire;
/// mask `& 0x7F` on receive. A 2-char XOR block checksum terminates each frame.
/// `feed` reassembles fragmented frames (BLE + USB both fragment arbitrarily).
/// Unknown type bytes are discarded for resync. `s` frames may arrive unsolicited
/// between a command and its ack — the parser is fully async, never lock-step.
/// [MCHESS] magic-board.md §2; [SPEC RISK]: async interleaving.
///
/// ## Capability profile
/// `occupancySensing` + `pieceIdentity` + `moveIndication` (corner grid).
/// NOT `perSquareLEDs` — the 9×9 LED corner grid illuminates 4 LEDs per square.
/// `indicateSquares` maps each square to its 4 corner LED numbers via
/// `millenniumSquareToCornerLEDs(file:rank:)` — the seam-degradation showcase.
///
/// ## Orientation
/// A 180°-rotated board sends the byte-reversed s-payload. The adapter detects
/// orientation by exact-matching the full 64-char payload against the two
/// canonical start-position signatures; `isRotated` flips only on an exact
/// match, mirroring domschl/python-mchess chess_link.py:360. LED frames rotate
/// consistently (N → 82-N).
/// [SPEC RISK]: orientation trap — XOR checksum is order-independent and cannot
/// distinguish native from rotated; position signature is the only reliable
/// discriminant.
///
/// ## eONE caveat
/// eONE senses occupancy only; piece chars are firmware-tracked and may drift
/// after manual setup or promotions. [GONEILL]; verify on real hardware.
public struct MillenniumAdapter: BoardAdapter {

    // MARK: - State

    /// Parity-stripped receive buffer (7-bit ASCII values).
    private var rawBuffer: [UInt8] = []

    /// Previous decoded identity array for delta computation. nil = first frame.
    private var previousIdentity: [Piece?]? = nil

    /// True when the board is physically rotated 180° (cable on opposite side).
    /// Detected by exact-matching the full 64-char payload against the two
    /// canonical start-position signatures (native or its 180° reversal),
    /// mirroring domschl/python-mchess chess_link.py:360. Updated on every
    /// s-frame so that re-placing pieces re-detects orientation without a
    /// resetFraming() call.
    public private(set) var isRotated: Bool = false

    // MARK: - Start-position orientation signatures

    /// Native start-position payload (A8…H1 FEN board-reading order).
    /// "rnbqkbnr" + "pppppppp" + 32×'.' + "PPPPPPPP" + "RNBQKBNR".
    private static let nativeStartPayload: [UInt8] =
        Array("rnbqkbnrpppppppp................................PPPPPPPPRNBQKBNR".utf8)

    /// Rotated start-position payload: exact byte-reversal of `nativeStartPayload`.
    /// Begins "RNBKQBNR" (K/Q transposed relative to native rank-1 order).
    private static let rotatedStartPayload: [UInt8] =
        Array(nativeStartPayload.reversed())

    // MARK: - BoardAdapter

    public var capabilities: BoardCapabilities {
        [.occupancySensing, .pieceIdentity, .moveIndication]
    }

    public init() {}

    // MARK: - feed(bytes:)

    /// Decode raw wire bytes from BLE notifications or USB reads.
    ///
    /// Strips odd-parity bit, reassembles fragmented frames via length table,
    /// verifies XOR block checksum (drops bad frames silently), dispatches.
    /// The board may insert unsolicited `s` frames at any time — the parser
    /// dispatches asynchronously by frame-type char, never by arrival order.
    public mutating func feed(bytes: Data) -> [BoardEvent] {
        for byte in bytes { rawBuffer.append(byte & 0x7F) }
        var events: [BoardEvent] = []
        while !rawBuffer.isEmpty {
            guard let typeChar = rawBuffer.first else { break }
            guard let frameLen = millenniumFrameLengths[typeChar] else {
                rawBuffer.removeFirst()   // resync: discard unknown byte
                continue
            }
            guard rawBuffer.count >= frameLen else { break }
            let frame = Array(rawBuffer.prefix(frameLen))
            rawBuffer.removeFirst(frameLen)
            let body = Array(frame.dropLast(2))
            let expected = computeMillenniumChecksum(body)
            let actual = String(bytes: frame.suffix(2), encoding: .ascii) ?? ""
            guard expected == actual else { continue }   // drop bad frame silently
            events += processMillenniumFrame(frame)
        }
        return events
    }

    // MARK: - encode(_:)

    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession:
            // V: version/liveness check. Recommended first step. [MCHESS] session_open.
            return MillenniumAdapter.encodeVersionRequest()
        case .requestState:
            // S: request full board state. Poll after connect and after setup.
            // [DISCREPANCY D7]: over BLE, auto-reports may be change-triggered only.
            return MillenniumAdapter.encodeStateRequest()
        case .indicateSquares(let squares, _):
            if squares.isEmpty { return MillenniumAdapter.encodeLEDOff() }
            // Each square → 4 corner LEDs. slotTime=0x0F (61 ms/slot), solid on.
            // Style is advisory; corner grid has no per-square colour in base protocol.
            return millenniumLEDFrame(squares: squares, frameSlotTime: 0x0F,
                                      ledPattern: 0xFF, isRotated: isRotated)
        case .executeMove:
            return nil   // Millennium boards are not motorised.
        case .custom(let data):
            return data
        }
    }

    // MARK: - handshakeCommands(isReconnect:)

    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: Duration)] {
        if isReconnect {
            // Settle ≥100 ms (BLE minimum spacing empirical [MCHESS]), then V+S.
            return [
                (.startSession, .milliseconds(100)),
                (.requestState, .milliseconds(150)),
            ]
        }
        // First connect: V immediately, S after 150 ms for firmware settling.
        return [
            (.startSession, .zero),
            (.requestState, .milliseconds(150)),
        ]
    }

    // MARK: - Static command encoders (public for tests + transport helpers)

    /// V command wire bytes. Fixture 1: "V56" → D6 B5 B6.
    /// Byte-identical to chess_link.py log "Sending: <b'\xd6\xb5\xb6'>". [MCHESS].
    public static func encodeVersionRequest() -> Data {
        millenniumBuildFrame([UInt8(ascii: "V")])
    }

    /// S command wire bytes. Fixture 3: "S53" → D3 B5 B3.
    public static func encodeStateRequest() -> Data {
        millenniumBuildFrame([UInt8(ascii: "S")])
    }

    /// X command wire bytes. Fixture 4: "X58" → 58 B5 38. Cheaper than all-zero L.
    public static func encodeLEDOff() -> Data {
        millenniumBuildFrame([UInt8(ascii: "X")])
    }

    /// T command wire bytes. Fixture 4: "T54" → 54 B5 34. NO reply; ~3 s startup.
    public static func encodeReset() -> Data {
        millenniumBuildFrame([UInt8(ascii: "T")])
    }

    /// W (E2ROM write) wire bytes. Fixture 7: W0204 → 57 B0 32 B0 34 B5 31.
    public static func encodeWriteRegister(addr: UInt8, data: UInt8) -> Data {
        var ascii: [UInt8] = [UInt8(ascii: "W")]
        ascii += Array(String(format: "%02X", addr).utf8)
        ascii += Array(String(format: "%02X", data).utf8)
        return millenniumBuildFrame(ascii)
    }

    /// R (E2ROM read) wire bytes. Fixture 7: R02 → 52 B0 32 B5 B0.
    public static func encodeReadRegister(addr: UInt8) -> Data {
        var ascii: [UInt8] = [UInt8(ascii: "R")]
        ascii += Array(String(format: "%02X", addr).utf8)
        return millenniumBuildFrame(ascii)
    }

    /// Encode a position as a Millennium s-frame (67 wire bytes).
    ///
    /// `identity` is file-major (a1=0…h8=63). Used by test harnesses and
    /// capture-log tooling — the board generates s-frames; the host never does.
    ///
    /// Payload: A8…H1 (FEN board reading order). Produces wire bytes with
    /// parity. Fixture 5 round-trip: encodeFrame(start) → feed → identitySnapshot.
    public static func encodeFrame(identity: [Piece?]) -> Data {
        precondition(identity.count == 64)
        var payload = [UInt8](repeating: UInt8(ascii: "."), count: 64)
        for fm in 0..<64 { payload[millenniumFileMajorToK(fm)] = millenniumCharFromPiece(identity[fm]) }
        var ascii: [UInt8] = [UInt8(ascii: "s")]
        ascii += payload
        return millenniumBuildFrame(ascii)
    }

    // MARK: - Frame processing (private)

    private mutating func processMillenniumFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard let t = frame.first else { return [] }
        if t == UInt8(ascii: "s") { return processSFrame(frame) }
        // v, l, x, w, r: acks/replies. Emit as raw for debug logging.
        // Tolerates any unknown type (incl. speculative 't'). [DISCREPANCY D2].
        return [.raw(Data(frame))]
    }

    private mutating func processSFrame(_ frame: [UInt8]) -> [BoardEvent] {
        guard frame.count == 67, frame[0] == UInt8(ascii: "s") else { return [] }
        let payload = Array(frame[1...64])   // 64 piece chars
        let isFirstFrame = (previousIdentity == nil)

        // Detect orientation by exact-matching the full 64-char payload against
        // the two canonical start-position signatures (native / reversed).
        // [MCHESS] chess_link.py:360 — flips only on exact start-position match.
        // [SPEC RISK]: orientation trap — XOR checksum is order-independent and
        // cannot distinguish native from rotated; position signature only.
        updateOrientation(payload: payload)

        var identity = [Piece?](repeating: nil, count: 64)
        for k in 0..<64 {
            let squareK = isRotated ? (63 - k) : k
            identity[millenniumSquareToFileMajor(squareK)] = millenniumPieceByChar[payload[k]]
        }

        var events: [BoardEvent] = []
        events.append(.identitySnapshot(identity))
        if let prev = previousIdentity { events += millenniumDeltaEvents(prev: prev, curr: identity) }
        previousIdentity = identity
        if isFirstFrame { events.append(.ready) }
        return events
    }

    /// Detect board orientation from the full 64-char s-frame payload.
    ///
    /// Flips `isRotated` only when `payload` exactly equals one of the two
    /// canonical 64-char start-position signatures, mirroring the algorithm in
    /// domschl/python-mchess chess_link.py:360.
    ///
    /// A 2-char heuristic (payload[3]='K' && payload[4]='Q') produces false
    /// positives in K+Q endgames and after promotions — any legal native-
    /// orientation position with the white king on D8 and white queen on E8
    /// triggers the old check, permanently flipping `isRotated` until a full
    /// start position is re-placed. Full 64-char matching eliminates that class
    /// of error entirely.
    private mutating func updateOrientation(payload: [UInt8]) {
        guard payload.count == 64 else { return }
        if payload == Self.nativeStartPayload {
            isRotated = false
        } else if payload == Self.rotatedStartPayload {
            isRotated = true
        }
    }

    /// Reset receive buffer and board-state history.
    ///
    /// Call when the physical link drops before executing the reconnect handshake.
    /// Clears the buffer (avoids mid-frame desync) and re-arms `.ready` emission
    /// for the first frame on the new link.
    public mutating func resetFraming() {
        rawBuffer = []
        previousIdentity = nil
    }
}



