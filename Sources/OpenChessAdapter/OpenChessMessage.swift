import Foundation
import ChessCore
#if canImport(os)
import os

private let framerLog = OSLog(subsystem: "BoardKit", category: "OpenChess.Framer")
#endif

// Open Chess wire-protocol codec — OpenChessAdapter kernel.
//
// Protocol designed for the Open Chess Arduino-based smart chessboard.
// The board communicates via USB serial (9600 baud) or WiFi (TCP/IP).
//
// This protocol is a PROPOSED extension to the Open Chess firmware.
// The current Open Chess board runs game logic internally and does not
// have a defined protocol for external app control. This adapter provides
// a reference implementation that can be used if the firmware is extended
// to support external control.
//
// Protocol overview:
// - Board → Host: Sensor events, board state, game events
// - Host → Board: LED commands, game commands, configuration
//
// Frame format: <code>:<payload>\n
// - code: 2-character ASCII command code
// - payload: variable-length ASCII data
// - terminator: newline character (\n)

// MARK: - Serial Constants

/// USB serial constants for Open Chess boards.
///
/// The Arduino board communicates via USB serial at 9600 baud.
/// This matches the debug output baud rate in the current firmware.
public enum OpenChessSerial {
    /// Baud rate for USB serial communication.
    public static let baudRate: Int = 9600
    /// Number of squares on the board.
    public static let squareCount: Int = 64
    /// Number of rows and columns.
    public static let boardSize: Int = 8
}

// MARK: - WiFi Constants

/// WiFi constants for Open Chess boards.
///
/// The board can create an Access Point for configuration and game selection.
/// For external control, the board would need to expose a TCP server.
public enum OpenChessWiFi {
    /// Default Access Point SSID.
    public static let defaultSSID: String = "OpenChessBoard"
    /// Default Access Point password.
    public static let defaultPassword: String = "chess123"
    /// Default TCP port for external control (proposed).
    public static let controlPort: Int = 8888
}

// MARK: - BLE Constants

/// BLE constants for Open Chess boards.
///
/// The board uses the NINA-W102 module's BLE capability with a custom service.
/// These UUIDs match the firmware implementation in ble_manager.h.
public enum OpenChessBLE {
    /// Custom service UUID for Open Chess boards.
    public static let serviceUUID: String = "19B10000-E8F2-537E-4F6C-D104768A1214"
    
    /// Characteristic for board → host (sensor events, notify).
    public static let sensorCharUUID: String = "19B10001-E8F2-537E-4F6C-D104768A1214"
    
    /// Characteristic for host → board (commands, write).
    public static let commandCharUUID: String = "19B10002-E8F2-537E-4F6C-D104768A1214"
    
    /// Characteristic for board state (occupancy snapshot, read/notify).
    public static let stateCharUUID: String = "19B10003-E8F2-537E-4F6C-D104768A1214"
    
    /// Characteristic for LED control (write).
    public static let ledCharUUID: String = "19B10004-E8F2-537E-4F6C-D104768A1214"
    
    /// Characteristic for game state (read/notify).
    public static let gameCharUUID: String = "19B10005-E8F2-537E-4F6C-D104768A1214"
    
    /// Default BLE device name when advertising.
    public static let deviceName: String = "OpenChess"
    
    /// Whether `name` looks like an Open Chess board via BLE.
    ///
    /// Case-insensitive match on "OpenChess" (the default BLE device name).
    public static func isOpenChess(name: String) -> Bool {
        name.lowercased() == "openchess"
    }
}

// MARK: - Message Types

/// A parsed Open Chess message.
public struct OpenChessMessage: Equatable, Sendable {
    /// Two-character command code.
    public let code: String
    /// Payload data (may be empty).
    public let payload: String
    
    public init(code: String, payload: String) {
        self.code = code
        self.payload = payload
    }
    
    /// Wire representation: `<code>:<payload>\n`
    public var wireRepresentation: String { "\(code):\(payload)\n" }
}

// MARK: - Events (Board → Host)

/// Events emitted by the Open Chess board.
public enum OpenChessEvent: Equatable, Sendable {
    /// Sensor state change: `SE:<square><state>*`
    /// square: 2-char algebraic (e.g., "e2")
    /// state: "L" (lift) or "P" (place)
    case sensorEvent(square: String, isLift: Bool)
    
    /// Full board occupancy snapshot: `OC:<64 bits>*`
    /// 64 chars of '0'/'1', one per square in a1..h8 order.
    case occupancySnapshot(occupancy: [Bool])
    
    /// Board ready after initialization: `RD:*`
    case ready
    
    /// Move executed confirmation: `MV:<from><to>*`
    case moveExecuted(from: String, to: String)
    
    /// Invalid move attempt: `IV:<reason>*`
    case invalidMove(reason: String)
    
    /// Game state update: `GS:<state>*`
    /// state: "IDLE", "ACTIVE", "CHECKMATE", "STALEMATE", etc.
    case gameState(state: String)
    
    /// Game over: `GO:<result>*`
    /// result: "W" (white wins), "B" (black wins), "D" (draw)
    case gameOver(result: String)
    
    /// Battery level: `BL:<percent>*`
    case battery(percent: Int)
    
    /// Error or disconnection: `ER:<message>*`
    case error(message: String)
    
    /// Any other message we haven't modeled.
    case raw(OpenChessMessage)
}

// MARK: - Commands (Host → Board)

/// Commands sent to the Open Chess board.
public enum OpenChessCommand: Sendable {
    /// Start a new game: `CMD:NEWGAME`
    case startNewGame
    
    /// Request current board state: `CMD:GETSTATE`
    case requestBoardState
    
    /// Set LEDs on specific squares: `LED:<sq1>,<sq2>,...`
    /// Each square is 2-char algebraic (e.g., "e2").
    /// LEDs will be set to white (move indication).
    case setLeds(squares: [String])
    
    /// Set LED with color: `LEDC:<sq><r><g><b>`
    /// Color values are 0-255.
    case setLedColor(square: String, r: UInt8, g: UInt8, b: UInt8)
    
    /// Clear all LEDs: `LED:CLEAR`
    case clearLeds
    
    /// Execute a move (for motorized boards): `MOVE:<from><to>`
    case executeMove(from: String, to: String)
    
    /// Set game mode: `MODE:<mode>`
    /// mode: "HVH" (human vs human), "HVA" (human vs AI)
    case setGameMode(mode: String)
    
    /// Set AI difficulty: `AI:<level>`
    /// level: "EASY", "MEDIUM", "HARD", "EXPERT"
    case setAIDifficulty(level: String)
    
    /// Custom data forward: forwarded verbatim.
    case custom(Data)
    
    /// Wire representation of the command.
    public var wire: String {
        switch self {
        case .startNewGame:
            return "CMD:NEWGAME\n"
        case .requestBoardState:
            return "CMD:GETSTATE\n"
        case .setLeds(let squares):
            let sqList = squares.map { $0.lowercased() }.joined(separator: ",")
            return "LED:\(sqList)\n"
        case .setLedColor(let square, let r, let g, let b):
            return "LEDC:\(square.lowercased())\(r)\(g)\(b)\n"
        case .clearLeds:
            return "LED:CLEAR\n"
        case .executeMove(let from, let to):
            return "MOVE:\(from.lowercased())\(to.lowercased())\n"
        case .setGameMode(let mode):
            return "MODE:\(mode)\n"
        case .setAIDifficulty(let level):
            return "AI:\(level)\n"
        case .custom(let data):
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
    
    /// Convert command to Data for transmission.
    public var data: Data { Data(wire.utf8) }
}

// MARK: - Framer

/// Buffers incoming bytes and emits whole `<code>:<payload>\n` frames.
///
/// Declared as a `struct` (value type) so that it composes safely into `Sendable`
/// value types such as `OpenChessAdapter`.
public struct OpenChessFramer: Sendable {
    private var buffer = Data()
    
    public init() {}
    
    /// Hard cap on the accumulation buffer.
    public static let maxBufferSize = 64 * 1024
    
    /// Append raw bytes and return any complete frames.
    public mutating func append(_ data: Data) -> [OpenChessMessage] {
        buffer.append(data)
        var messages: [OpenChessMessage] = []
        
        // Look for newline terminators
        while let newlineIndex = buffer.firstIndex(of: 0x0A) { // '\n'
            let frameBytes = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            
            guard let frame = String(data: Data(frameBytes), encoding: .utf8),
                  let colonIndex = frame.firstIndex(of: ":") else { continue }
            
            let code = String(frame[..<colonIndex])
            let payload = String(frame[frame.index(after: colonIndex)...])
            
            // Validate code is exactly 2 characters
            guard code.count == 2 else { continue }
            
            messages.append(OpenChessMessage(code: code, payload: payload))
        }
        
        // Cap applies to the unterminated residue only
        if buffer.count > Self.maxBufferSize {
            let droppedCount = buffer.count
            #if canImport(os)
            os_log("Frame buffer exceeded %d bytes with no terminator — dropping %d buffered bytes", log: framerLog, type: .error, Self.maxBufferSize, droppedCount)
            #else
            FileHandle.standardError.write(Data("[OpenChess.Framer] Frame buffer exceeded \(Self.maxBufferSize) bytes with no terminator — dropping \(droppedCount) buffered bytes\n".utf8))
            #endif
            buffer = Data()
        }
        
        return messages
    }
    
    /// Reset the buffer.
    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}

// MARK: - Parser

/// Parses Open Chess messages into semantic events.
public enum OpenChessParser {
    /// Parse a message into an event.
    public static func event(from message: OpenChessMessage) -> OpenChessEvent {
        switch message.code {
        case "SE":
            // Sensor event: <square><state>
            guard message.payload.count == 3 else { return .raw(message) }
            let square = String(message.payload.prefix(2))
            let stateChar = message.payload.last
            return .sensorEvent(square: square.lowercased(), isLift: stateChar == "L")
            
        case "OC":
            // Occupancy snapshot: 64 bits
            let occ = message.payload.prefix(64).map { $0 == "1" }
            guard occ.count == 64 else { return .raw(message) }
            return .occupancySnapshot(occupancy: occ)
            
        case "RD":
            // Ready
            return .ready
            
        case "MV":
            // Move executed: <from><to>
            guard message.payload.count == 4 else { return .raw(message) }
            let from = String(message.payload.prefix(2))
            let to = String(message.payload.suffix(2))
            return .moveExecuted(from: from.lowercased(), to: to.lowercased())
            
        case "IV":
            // Invalid move
            return .invalidMove(reason: message.payload)
            
        case "GS":
            // Game state update
            return .gameState(state: message.payload)
            
        case "GO":
            // Game over
            return .gameOver(result: message.payload)
            
        case "BL":
            // Battery level
            guard let percent = Int(message.payload) else { return .raw(message) }
            return .battery(percent: percent)
            
        case "ER":
            // Error
            return .error(message: message.payload)
            
        default:
            return .raw(message)
        }
    }
}

// MARK: - Square Conversion Helpers

/// Helper functions for square coordinate conversion.
public enum OpenChessSquareHelper {
    /// Convert algebraic notation (e.g., "e2") to row/col (0-indexed).
    /// Returns nil for invalid squares.
    public static func algebraicToRowCol(_ square: String) -> (row: Int, col: Int)? {
        guard square.count == 2 else { return nil }
        let chars = Array(square.lowercased())
        guard let fileChar = chars.first,
              let rankChar = chars.last,
              let file = fileChar.asciiValue,
              file >= UInt8(ascii: "a"),
              file <= UInt8(ascii: "h"),
              let rank = Int(String(rankChar)),
              rank >= 1,
              rank <= 8 else { return nil }
        
        let col = Int(file - UInt8(ascii: "a"))
        let row = rank - 1
        return (row, col)
    }
    
    /// Convert row/col (0-indexed) to algebraic notation.
    public static func rowColToAlgebraic(row: Int, col: Int) -> String? {
        guard row >= 0, row < 8, col >= 0, col < 8 else { return nil }
        let fileChar = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(col)))
        return "\(fileChar)\(row + 1)"
    }
    
    /// Convert stream index (0=a8, 63=h1) to file-major index (a1=0, h8=63).
    public static func streamIndexToFileMajor(_ i: Int) -> Int {
        let file = i % 8
        let rank = 7 - i / 8
        return file * 8 + rank
    }
    
    /// Convert file-major index (a1=0, h8=63) to stream index (0=a8, 63=h1).
    public static func fileMajorToStreamIndex(_ fm: Int) -> Int {
        let file = fm / 8
        let rank = fm % 8
        return (7 - rank) * 8 + file
    }
    
    /// Convert file-major index to algebraic notation.
    public static func fileMajorToAlgebraic(_ fm: Int) -> String {
        let file = fm / 8
        let rank = fm % 8
        let fileChar = Character(UnicodeScalar(UInt8(97 + min(max(file, 0), 7))))
        return "\(fileChar)\(rank + 1)"
    }
}
