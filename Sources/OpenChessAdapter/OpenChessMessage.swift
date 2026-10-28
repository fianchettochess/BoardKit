import Foundation

// ── Open Chess wire codec ─────────────────────────────────────────────────────
//
// One JSON object per line, each naming its type in a "t" field, identical
// over USB serial and BLE. Board → host types: hello, status, state,
// occupancy, move, lift, place, button, leds, battery, result, ack, error.
// Both sides ignore types they do not know, so board and host firmware can
// update independently; lines that are not JSON (sketches that only print
// debug text) are passed through as raw lines.
//
// Sources: the board protocol section of openchess.shop/how-it-works and the
// observable behaviour of the public web controller at openchess.shop/connect
// (October 2026). No firmware or controller source was copied; the firmware
// for the ESP32-S3 product is not public.

/// One decoded line from an Open Chess board.
public enum OpenChessMessage: Sendable, Equatable {
    /// The board's identity, sent on connect and in answer to `identify`.
    case hello(Hello)
    /// The installed game's phase (for example "setup", "playing") and a
    /// human-readable status line.
    case status(phase: String?, message: String?)
    /// The installed game's own position, when it tracks one.
    case state(fen: String, turn: String?)
    /// Every square's occupancy, in BoardKit's file-major order
    /// (a1=0, a2=1 … a8=7, b1=8 … h8=63).
    case occupancy([Bool])
    /// A move the installed game accepted, in UCI.
    case move(uci: String)
    /// A piece left `square`.
    case lift(square: String)
    /// A piece arrived on `square`.
    case place(square: String)
    /// One of the board's two buttons ("a" or "b") changed state.
    case button(id: String, pressed: Bool)
    /// The board's current LED frame: 64 RGBW values in file-major order.
    case leds([OpenChessColor])
    /// Battery state. `volts` and `usb` are optional in the protocol.
    case battery(percent: Int, charging: Bool, usb: Bool, volts: Double?)
    /// The installed game ended (for example "checkmate", "stalemate").
    case result(result: String, winner: String?)
    /// The board acknowledged a command.
    case ack
    /// The board reported an error; the line is kept whole.
    case error(line: String)
    /// A JSON line of a type this codec does not model, or a known type with
    /// unusable fields.
    case unknown(line: String)
    /// A line that is not a JSON object (debug output from a sketch).
    case text(line: String)

    public struct Hello: Sendable, Equatable {
        /// Board family, "open-chess" on the production board.
        public let board: String?
        /// Firmware version, e.g. "1.2.0".
        public let firmware: String?
        public let core: String?
        /// The installed game's identifier (e.g. "classic-chess"), sent as
        /// "game" or, by older firmware, "mode".
        public let game: String?
        /// The installed game's display name.
        public let name: String?
        public let volume: Int?

        public init(board: String?, firmware: String?, core: String?,
                    game: String?, name: String?, volume: Int?) {
            self.board = board; self.firmware = firmware; self.core = core
            self.game = game; self.name = name; self.volume = volume
        }
    }

    /// Decode one line, without its terminator.
    public static func parse(line: String) -> OpenChessMessage {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let wire = try? JSONDecoder().decode(Wire.self, from: Data(trimmed.utf8))
        else { return .text(line: line) }

        switch wire.t {
        case "hello":
            return .hello(Hello(
                board: wire.board, firmware: wire.fw, core: wire.core,
                game: wire.game ?? wire.mode, name: wire.name,
                volume: wire.volume.flatMap { $0 >= 0 ? $0 : nil }
            ))
        case "status":
            return .status(phase: wire.phase, message: wire.msg)
        case "state":
            guard let fen = wire.fen else { return .unknown(line: line) }
            return .state(fen: fen, turn: wire.turn)
        case "occupancy":
            guard let hex = wire.squares, let squares = OpenChessCodec.occupancy(hex: hex)
            else { return .unknown(line: line) }
            return .occupancy(squares)
        case "move":
            guard let uci = wire.uci, OpenChessCodec.isUCI(uci) else { return .unknown(line: line) }
            return .move(uci: uci)
        case "lift", "place":
            guard let square = wire.sq, OpenChessCodec.isSquare(square) else { return .unknown(line: line) }
            return wire.t == "lift" ? .lift(square: square) : .place(square: square)
        case "button":
            guard let id = wire.id, let pressed = wire.pressed else { return .unknown(line: line) }
            return .button(id: id, pressed: pressed)
        case "leds":
            guard let hex = wire.frame, let frame = OpenChessCodec.ledFrame(hex: hex)
            else { return .unknown(line: line) }
            return .leds(frame)
        case "battery":
            guard let percent = wire.percent else { return .unknown(line: line) }
            return .battery(percent: min(100, max(0, percent)),
                            charging: wire.charging ?? false, usb: wire.usb ?? false,
                            volts: wire.volts)
        case "result":
            guard let result = wire.result else { return .unknown(line: line) }
            return .result(result: result, winner: wire.winner)
        case "ack":
            return .ack
        case "error":
            return .error(line: line)
        default:
            return .unknown(line: line)
        }
    }

    /// Every field any board line carries. Each is read leniently: a field
    /// of the wrong JSON type is nil rather than a failed line, so
    /// `"percent": true` is not a battery level and a board that adds a
    /// field, or changes one this codec does not use, still decodes.
    private struct Wire: Decodable {
        let t: String
        let board, fw, core, game, mode, name: String?
        let volume: Int?
        let phase, msg, fen, turn, squares, uci, sq, id, frame, result, winner: String?
        let pressed, charging, usb: Bool?
        let percent: Int?
        let volts: Double?

        private enum Key: String, CodingKey {
            case t, board, fw, core, game, mode, name, volume, phase, msg, fen, turn,
                 squares, uci, sq, id, frame, result, winner, pressed, charging, usb, percent, volts
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            t = try c.decode(String.self, forKey: .t)
            func text(_ key: Key) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
            func flag(_ key: Key) -> Bool? { try? c.decodeIfPresent(Bool.self, forKey: key) }
            board = text(.board); fw = text(.fw); core = text(.core)
            game = text(.game); mode = text(.mode); name = text(.name)
            phase = text(.phase); msg = text(.msg); fen = text(.fen); turn = text(.turn)
            squares = text(.squares); uci = text(.uci); sq = text(.sq); id = text(.id)
            frame = text(.frame); result = text(.result); winner = text(.winner)
            pressed = flag(.pressed); charging = flag(.charging); usb = flag(.usb)
            volume = try? c.decodeIfPresent(Int.self, forKey: .volume)
            percent = try? c.decodeIfPresent(Int.self, forKey: .percent)
            volts = try? c.decodeIfPresent(Double.self, forKey: .volts)
        }
    }
}

/// An Open Chess LED colour: red, green, blue and white channels, 0–255 each.
public struct OpenChessColor: Sendable, Equatable {
    public let red: UInt8, green: UInt8, blue: UInt8, white: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, white: UInt8 = 0) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
    }

    /// The protocol's four-element `[r, g, b, w]` array.
    var json: String { "[\(red),\(green),\(blue),\(white)]" }
}

/// Wire helpers shared by the adapter, its tests and any emulator personality.
public enum OpenChessCodec {

    /// Decode the `occupancy` message's 16 hex digits.
    ///
    /// THE BIT ORDER IS RANK-MAJOR AND BOARDKIT IS FILE-MAJOR. The hex string
    /// is one 64-bit number whose bit k is square k with k = rank × 8 + file
    /// (a1 = bit 0, b1 = bit 1 … h1 = bit 7, a2 = bit 8 … h8 = bit 63), as the
    /// web controller reads it. BoardKit's occupancy arrays are file-major
    /// (a1 = 0, a2 = 1 … a8 = 7, b1 = 8), so every bit is transposed here.
    /// Returns nil unless the string is exactly 16 hex digits.
    public static func occupancy(hex: String) -> [Bool]? {
        let digits = hex.trimmingCharacters(in: .whitespaces).lowercased()
        // Every character a hex digit: `UInt64(_:radix:)` alone accepts a sign.
        guard digits.utf8.count == 16,
              digits.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let value = UInt64(digits, radix: 16) else { return nil }
        var squares = [Bool](repeating: false, count: 64)
        for bit in 0..<64 where value & (1 << UInt64(bit)) != 0 {
            let rank = bit / 8, file = bit % 8
            squares[file * 8 + rank] = true
        }
        return squares
    }

    /// The inverse of ``occupancy(hex:)``: file-major squares to 16 hex digits.
    public static func occupancyHex(_ squares: [Bool]) -> String? {
        guard squares.count == 64 else { return nil }
        var value: UInt64 = 0
        for index in 0..<64 where squares[index] {
            let file = index / 8, rank = index % 8
            value |= 1 << UInt64(rank * 8 + file)
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Decode a `leds` frame: 512 hex digits, 64 squares × RGBW, rank-major on
    /// the wire like occupancy, returned file-major.
    public static func ledFrame(hex: String) -> [OpenChessColor]? {
        let bytes = Array(hex.trimmingCharacters(in: .whitespaces).lowercased().utf8)
        guard bytes.count == 512 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            default: return nil
            }
        }
        var wire: [OpenChessColor] = []
        wire.reserveCapacity(64)
        for square in 0..<64 {
            var channels: [UInt8] = []
            for channel in 0..<4 {
                let offset = square * 8 + channel * 2
                guard let high = nibble(bytes[offset]), let low = nibble(bytes[offset + 1]) else { return nil }
                channels.append(high << 4 | low)
            }
            wire.append(OpenChessColor(red: channels[0], green: channels[1], blue: channels[2], white: channels[3]))
        }
        return (0..<64).map { index in wire[(index % 8) * 8 + index / 8] }
    }

    static func isSquare(_ square: String) -> Bool {
        let bytes = Array(square.utf8)
        return bytes.count == 2 && (97...104).contains(bytes[0]) && (49...56).contains(bytes[1])
    }

    static func isUCI(_ uci: String) -> Bool {
        let bytes = Array(uci.utf8)
        guard bytes.count == 4 || bytes.count == 5,
              isSquare(String(decoding: bytes[0..<2], as: UTF8.self)),
              isSquare(String(decoding: bytes[2..<4], as: UTF8.self)) else { return false }
        return bytes.count == 4 || "qrbn".utf8.contains(bytes[4])
    }

    // MARK: - Host → board

    /// One command line, newline-terminated.
    static func line(_ json: String) -> Data { Data((json + "\n").utf8) }

    /// Ask the board to identify itself (`hello`).
    public static let identify = line(#"{"t":"identify"}"#)

    /// Turn every LED off.
    public static let clearLEDs = line(#"{"t":"leds","clear":true}"#)

    /// Light `squares` in `color`. Squares that are not a1–h8 are dropped.
    public static func hint(_ squares: [String], color: OpenChessColor) -> Data {
        let valid = squares.filter(isSquare).map { "\"\($0)\"" }.joined(separator: ",")
        return line(#"{"t":"hint","squares":["# + valid + #"],"color":"# + color.json + "}")
    }

    /// Light one square.
    public static func led(_ square: String, color: OpenChessColor) -> Data? {
        guard isSquare(square) else { return nil }
        return line(#"{"t":"led","sq":""# + square + #"","color":"# + color.json + "}")
    }

    /// LED brightness, as the board's slider sends it (0–255).
    public static func brightness(_ value: UInt8) -> Data {
        line(#"{"t":"brightness","value":"# + String(value) + "}")
    }
}

/// Splits the byte stream into lines. Bytes are split before UTF-8 decoding,
/// so a multi-byte character divided across BLE notifications is reassembled.
struct OpenChessFramer: Sendable {
    /// Longest pending partial line kept. The web controller keeps the last
    /// 8,000 characters once 64,000 accumulate without a newline; a board
    /// streaming that much without a terminator is not speaking the protocol.
    static let maximumBuffer = 64_000
    static let retainedOnOverflow = 8_000

    private var buffer = Data()

    mutating func append(_ bytes: Data) -> [String] {
        buffer.append(bytes)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineBytes = buffer[buffer.startIndex..<newline]
            if lineBytes.last == 0x0D { lineBytes = lineBytes.dropLast() }
            buffer = Data(buffer[buffer.index(after: newline)...])
            if !lineBytes.isEmpty { lines.append(String(decoding: lineBytes, as: UTF8.self)) }
        }
        if buffer.count > Self.maximumBuffer { buffer = Data(buffer.suffix(Self.retainedOnOverflow)) }
        return lines
    }
}
