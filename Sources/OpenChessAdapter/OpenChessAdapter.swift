import Foundation
import BoardKit

// ── Open Chess board adapter ──────────────────────────────────────────────────
//
// Open Chess by Concept Bytes (openchess.shop): an ESP32-S3 board with 64
// AH3411 hall-effect sensors (occupancy only, no piece identity) and 64 RGBW
// per-square LEDs, over USB serial or BLE with the same line protocol.
//
// HARDWARE STATUS: hardware-unverified. Built from the published protocol and
// the public web controller's behaviour (see OpenChessMessage.swift); no board
// has been tested. Open questions for the first hardware session:
//   - whether every installed game streams `occupancy`, `lift` and `place`,
//     or only some (the web controller shows occupancy for every game);
//   - whether `identify` prompts a fresh `occupancy` frame, which this adapter
//     relies on for `requestState`;
//   - whether `hint` replaces the lit squares or adds to them (encode clears
//     first either way), and whether the installed game's own LEDs compete
//     with the host's;
//   - the occupancy hex bit order is taken from the web controller and is
//     pinned by a test, but has not been read off a physical board.

extension BoardCapabilities {
    /// Capabilities exposed by the Open Chess adapter: occupancy sensing,
    /// RGBW per-square LEDs and battery reports. No piece identity (hall
    /// sensors detect a magnet, not which piece), not motorised, no archive.
    public static let openChess: BoardCapabilities = [
        .occupancySensing, .perSquareLEDs, .moveIndication, .batteryReporting,
    ]
}

/// BLE discovery and connection identity for Open Chess boards.
///
/// Scan for ``advertisedService`` or a name starting with ``namePrefix``,
/// then open ``dataService``: subscribe to ``notify`` for board lines and
/// write commands to ``write``, in chunks of at most ``maximumWriteLength``
/// bytes (without response when the characteristic allows it).
public enum OpenChessGATT {
    /// Service the board advertises for discovery.
    public static let advertisedService = "1b7e8261-2877-41c3-b46e-cf057c562023"
    /// The line-protocol service.
    public static let dataService = "6f1a0001-9c4e-4b7a-9f21-2f0f7a1b6d10"
    /// Board → host lines (notify).
    public static let notify = "6f1a0002-9c4e-4b7a-9f21-2f0f7a1b6d10"
    /// Host → board lines (write).
    public static let write = "6f1a0003-9c4e-4b7a-9f21-2f0f7a1b6d10"
    /// Advertised-name prefix. The web controller also filters on it.
    public static let namePrefix = "Open Chess"
    /// Largest single write the web controller sends. BoardKit transports do
    /// not chunk, so the platform's BLE writer must split longer commands.
    public static let maximumWriteLength = 180

    /// Whether `name` looks like an Open Chess board.
    public static func isOpenChess(name: String) -> Bool {
        name.hasPrefix(namePrefix)
    }
}

/// USB serial settings: 115200 baud, 8 data bits, no parity, 1 stop bit.
public enum OpenChessSerial {
    public static let baudRate = 115_200
}

/// `BoardAdapter` for Open Chess boards, over BLE or USB serial.
///
/// ## Protocol mapping
///
/// **feed(bytes:)** splits lines, decodes each with ``OpenChessMessage/parse(line:)``:
///   - `occupancy` → `.occupancySnapshot` (transposed to file-major)
///   - `lift` / `place` → `.squareSensed(square:isLift:piece: nil)`
///   - `battery` → `.battery(percent:)`
///   - `hello` → `.ready`, then `.raw(line)` so a consumer can read the
///     firmware version and installed game
///   - every other line (`move`, `state`, `status`, `result`, `button`,
///     `leds`, `ack`, `error`, unknown types and non-JSON text) → `.raw(line)`.
///     The installed game's own `move` and `state` are its opinion, not the
///     session's: Fianchetto infers moves from occupancy like any other
///     occupancy board.
///
/// **encode(_:)**:
///   - `.startSession`, `.requestState` → `identify` (hardware-unverified that
///     it refreshes occupancy). `newgame` is deliberately not sent: it resets
///     the installed game, which the host does not own.
///   - `.indicateSquares([], _)` → clear all LEDs
///   - `.indicateSquares(squares, style)` → clear, then `hint` in the style's
///     colour, as one write
///   - `.executeMove`, `.requestStoredGames` → nil (not motorised, no archive)
///   - `.custom(data)` → data verbatim
public struct OpenChessAdapter: BoardAdapter {

    public var capabilities: BoardCapabilities { .openChess }

    private var framer = OpenChessFramer()

    public init() {}

    public mutating func feed(bytes: Data) -> [BoardEvent] {
        framer.append(bytes).flatMap { line -> [BoardEvent] in
            let raw = BoardEvent.raw(Data(line.utf8))
            switch OpenChessMessage.parse(line: line) {
            case .occupancy(let squares):
                return [.occupancySnapshot(squares)]
            case .lift(let square):
                return [.squareSensed(square: square, isLift: true, piece: nil)]
            case .place(let square):
                return [.squareSensed(square: square, isLift: false, piece: nil)]
            case .battery(let percent, _, _, _):
                return [.battery(percent: percent)]
            case .hello:
                return [.ready, raw]
            case .status, .state, .move, .button, .leds, .result, .ack, .error, .unknown, .text:
                return [raw]
            }
        }
    }

    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession, .requestState:
            return OpenChessCodec.identify
        case .indicateSquares(let squares, let style):
            guard !squares.isEmpty else { return OpenChessCodec.clearLEDs }
            return OpenChessCodec.clearLEDs + OpenChessCodec.hint(squares, color: Self.color(for: style))
        case .executeMove, .requestStoredGames:
            return nil
        case .custom(let data):
            return data
        }
    }

    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)] {
        // `identify` on both paths: it changes nothing on the board, so a
        // reconnect cannot disturb the installed game. The 250 ms settle
        // matches the other BLE adapters until hardware says otherwise.
        [(.startSession, 0.25)]
    }

    /// The colour each advisory style lights. Green is the web controller's
    /// own highlight; the rest follow the Chessnut convention BoardKit
    /// documents (from green, to amber, danger red).
    static func color(for style: LEDStyle) -> OpenChessColor {
        switch style {
        case .highlight, .moveFrom: OpenChessColor(red: 0, green: 255, blue: 0)
        case .moveTo: OpenChessColor(red: 255, green: 160, blue: 0)
        case .danger: OpenChessColor(red: 255, green: 0, blue: 0)
        case .custom(let index): palette[Int(index) % palette.count]
        }
    }

    private static let palette: [OpenChessColor] = [
        OpenChessColor(red: 0, green: 255, blue: 0),
        OpenChessColor(red: 255, green: 160, blue: 0),
        OpenChessColor(red: 255, green: 0, blue: 0),
        OpenChessColor(red: 0, green: 90, blue: 255),
        OpenChessColor(red: 160, green: 0, blue: 255),
        OpenChessColor(red: 0, green: 200, blue: 255),
        OpenChessColor(red: 0, green: 0, blue: 0, white: 255),
    ]
}
