import Foundation
import ChessCore
import BoardKit

// ── Open Chess board adapter ──────────────────────────────────────────────────
//
// Covers the Open Chess Arduino-based smart chessboard.
//
// HARDWARE STATUS: Protocol-designed only — the current Open Chess firmware
// runs game logic internally and does not expose a protocol for external app
// control. This adapter provides a reference implementation assuming the
// firmware is extended to support external control via serial or WiFi.
//
// The Open Chess board features:
// - 64 Hall effect sensors (one per square) for piece detection
// - 64 NeoPixel LEDs (one per square) for visual feedback
// - WiFi connectivity for Stockfish AI integration
// - USB serial communication (9600 baud) for debugging
//
// This adapter is designed to work with a modified firmware that exposes:
// - Serial protocol for sensor events and LED control
// - WiFi TCP server for remote control
//
// Sources:
//   Open Chess repository: https://github.com/Concept-Bytes/Open-Chess
//   MIT License

// MARK: - Board Capabilities

extension BoardCapabilities {
    /// Capabilities exposed by the Open Chess adapter.
    ///
    /// Open Chess boards are occupancy-only (no piece identity) with
    /// per-square LEDs. The board can detect piece presence/absence via
    /// Hall effect sensors but cannot identify which piece is on a square.
    public static let openChess: BoardCapabilities = [
        .occupancySensing, .perSquareLEDs, .moveIndication
    ]
}

// MARK: - Connection Identity

/// Connection identity for Open Chess boards.
///
/// For serial connections, the board is identified by USB vendor/product ID.
/// For WiFi connections, the board creates an Access Point or connects to a network.
/// For BLE connections, the board advertises as "OpenChess" with a custom service.
public enum OpenChessConnection {
    /// Default Access Point SSID.
    public static let defaultSSID = OpenChessWiFi.defaultSSID
    /// Default Access Point password.
    public static let defaultPassword = OpenChessWiFi.defaultPassword
    /// Default TCP port for external control.
    public static let controlPort = OpenChessWiFi.controlPort
    
    /// Whether `name` looks like an Open Chess board.
    ///
    /// Case-insensitive substring match on "openchess" or "open chess".
    /// Also matches the default BLE device name "OpenChess".
    public static func isOpenChess(name: String) -> Bool {
        let lowerName = name.lowercased()
        return lowerName.contains("openchess") || lowerName.contains("open chess")
    }
    
    /// Whether `name` matches an Open Chess board via BLE.
    ///
    /// Checks for the default BLE device name "OpenChess".
    public static func isOpenChessBLE(name: String) -> Bool {
        return OpenChessBLE.isOpenChess(name: name)
    }
}

// MARK: - OpenChessAdapter

/// Board adapter for the Open Chess Arduino-based smart chessboard.
///
/// ## Protocol mapping
///
/// **feed(bytes:)** runs incoming raw bytes through `OpenChessFramer` → `OpenChessParser`
/// → `OpenChessEvent` → `BoardEvent`:
///   - `.sensorEvent(square:isLift:)` → `.squareSensed(square:isLift:piece: nil)`
///   - `.occupancySnapshot(occupancy:)` → `.occupancySnapshot(occupancy)`
///   - `.ready` → `.ready`
///   - `.error(message:)` → `.disconnected(error: message)`
///   - `.raw(_)` → `.raw(msg.wireRepresentation.data(using: .utf8) ?? Data())`
///
/// **encode(_ command:)** maps `BoardCommand` → `OpenChessCommand` wire bytes:
///   - `.startSession` → `OpenChessCommand.startNewGame` ("CMD:NEWGAME\n")
///   - `.requestState` → `OpenChessCommand.requestBoardState` ("CMD:GETSTATE\n")
///   - `.indicateSquares(squares, style:)` → `OpenChessCommand.setLeds(squares:)` ("LED:<sq1>,<sq2>\n")
///   - `.executeMove(uci:)` → `OpenChessCommand.executeMove(from:to:)` ("MOVE:<from><to>\n")
///     (for motorized boards; returns nil for non-motorized)
///   - `.custom(data)` → `data` verbatim
///
/// **handshakeCommands(isReconnect:)** encodes the reconnect rule:
///   - First connect: `[(.startSession, 500ms), (.requestState, 200ms)]`
///   - Reconnect: `[(.requestState, 250ms)]`
///
/// ## Capabilities
///
/// Open Chess boards are occupancy-only (no piece identity). All models support
/// per-square LEDs and move indication. The board does not have piece identity
/// sensing — only presence/absence detection via Hall effect sensors.
///
/// ## HARDWARE STATUS
///
/// Protocol-designed only — awaiting firmware extension to expose serial/WiFi
/// protocol for external app control. Current firmware runs game logic internally.
public struct OpenChessAdapter: BoardAdapter {
    
    // MARK: - Properties
    
    public var capabilities: BoardCapabilities { .openChess }
    
    /// Minimum interval between consecutive writes (200ms for Arduino serial buffer).
    public var minimumWriteInterval: TimeInterval { 0.2 }
    
    private var framer = OpenChessFramer()
    
    // MARK: - Init
    
    public init() {}
    
    // MARK: - BoardAdapter conformance
    
    /// Feed raw transport bytes through the Open Chess frame scanner.
    ///
    /// Frames are ASCII lines terminated by `\n`. Partial frames are buffered
    /// across calls. The adapter parses sensor events, occupancy snapshots,
    /// and other board events.
    public mutating func feed(bytes: Data) -> [BoardEvent] {
        let messages = framer.append(bytes)
        return messages.compactMap { msg -> BoardEvent? in
            let event = OpenChessParser.event(from: msg)
            switch event {
            case .sensorEvent(let square, let isLift):
                return .squareSensed(square: square, isLift: isLift, piece: nil)
            case .occupancySnapshot(let occupancy):
                return .occupancySnapshot(occupancy)
            case .ready:
                return .ready
            case .moveExecuted:
                // Move confirmation — session can use this for game state tracking
                return nil // Not mapped to a BoardEvent case
            case .invalidMove(let reason):
                // Invalid move notification — session can log or alert
                return .raw(Data("IV:\(reason)".utf8))
            case .gameOver(let result):
                // Game over notification
                return .raw(Data("GO:\(result)".utf8))
            case .battery(let percent):
                return .battery(percent: percent)
            case .error(let message):
                return .disconnected(error: message)
            case .raw(let raw):
                return .raw(Data((raw.wireRepresentation).utf8))
            }
        }
    }
    
    /// Encode a `BoardCommand` to its Open Chess wire representation.
    ///
    /// Returns `nil` when the command is unsupported for this board.
    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession:
            return OpenChessCommand.startNewGame.data
        case .requestState:
            return OpenChessCommand.requestBoardState.data
        case .indicateSquares(let squares, _):
            return OpenChessCommand.setLeds(squares: squares).data
        case .executeMove(let uci):
            // Parse UCI move (e.g., "e2e4") to from/to squares
            guard uci.count == 4 else { return nil }
            let from = String(uci.prefix(2))
            let to = String(uci.suffix(2))
            return OpenChessCommand.executeMove(from: from, to: to).data
        case .requestStoredGames:
            // Open Chess has no on-device game archive.
            return nil
        case .custom(let data):
            return data
        }
    }
    
    /// Handshake sequence after the transport link is established.
    ///
    /// - First connect: Start new game, then request board state.
    /// - Reconnect: Request board state only (preserve game state).
    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)] {
        if isReconnect {
            // Mid-game reconnect: request current board state only.
            return [(.requestState, 0.25)] // 250ms
        } else {
            // Fresh connection: start new game, then request state.
            return [
                (.startSession, 0.5), // 500ms - allow board to initialize
                (.requestState, 0.2), // 200ms
            ]
        }
    }
}

// MARK: - BLE-Specific Extensions

/// BLE-specific extensions for Open Chess adapter.
///
/// These methods provide access to BLE GATT service/characteristic definitions
/// for use with platform-specific BLE transports (CoreBluetooth, SkipFuse).
public extension OpenChessAdapter {
    
    /// BLE GATT service and characteristic UUIDs for Open Chess boards.
    ///
    /// Use these with platform BLE APIs to discover and connect to Open Chess boards.
    struct BLEConstants {
        /// Service UUID for Open Chess boards.
        static let serviceUUID = OpenChessBLE.serviceUUID
        
        /// Characteristic UUID for board → host (sensor events).
        static let sensorCharUUID = OpenChessBLE.sensorCharUUID
        
        /// Characteristic UUID for host → board (commands).
        static let commandCharUUID = OpenChessBLE.commandCharUUID
        
        /// Characteristic UUID for board state (occupancy snapshot).
        static let stateCharUUID = OpenChessBLE.stateCharUUID
        
        /// Characteristic UUID for LED control.
        static let ledCharUUID = OpenChessBLE.ledCharUUID
    }
    
    /// Create a command to set LEDs via BLE.
    ///
    /// - Parameter squares: Array of squares to light up (e.g., ["e2", "e4"]).
    /// - Returns: Data to write to the LED characteristic.
    static func bleSetLEDs(squares: [String]) -> Data {
        let ledCommand = "SET:" + squares.joined(separator: ",")
        return Data(ledCommand.utf8)
    }
    
    /// Create a command to set LED color via BLE.
    ///
    /// - Parameters:
    ///   - square: Square to set (e.g., "e4").
    ///   - r, g, b: Color values (0-255).
    /// - Returns: Data to write to the LED characteristic.
    static func bleSetLEDColor(square: String, r: UInt8, g: UInt8, b: UInt8) -> Data {
        let colorCommand = "COLOR:\(square)R\(r)G\(g)B\(b)"
        return Data(colorCommand.utf8)
    }
    
    /// Create a command to clear all LEDs via BLE.
    ///
    /// - Returns: Data to write to the LED characteristic.
    static func bleClearLEDs() -> Data {
        return Data("CLEAR".utf8)
    }
    
    /// Create a command to request board state via BLE.
    ///
    /// - Returns: Data to write to the command characteristic.
    static func bleRequestState() -> Data {
        return Data("GETSTATE".utf8)
    }
    
    /// Create a command to start a new game via BLE.
    ///
    /// - Returns: Data to write to the command characteristic.
    static func bleStartNewGame() -> Data {
        return Data("NEWGAME".utf8)
    }
}

// MARK: - Extended Commands

/// Extended commands specific to Open Chess boards.
///
/// These commands go beyond the standard `BoardCommand` protocol and provide
/// access to Open Chess-specific features.
public extension OpenChessAdapter {
    
    /// Set a specific LED color on a square.
    ///
    /// - Parameters:
    ///   - square: Algebraic notation (e.g., "e4")
    ///   - r, g, b: Color values (0-255)
    /// - Returns: Data to send to the board, or nil for invalid square.
    static func setLedColor(square: String, r: UInt8, g: UInt8, b: UInt8) -> Data? {
        guard OpenChessSquareHelper.algebraicToRowCol(square) != nil else { return nil }
        return OpenChessCommand.setLedColor(square: square, r: r, g: g, b: b).data
    }
    
    /// Clear all LEDs on the board.
    ///
    /// - Returns: Data to send to the board.
    static func clearAllLeds() -> Data {
        return OpenChessCommand.clearLeds.data
    }
    
    /// Set the game mode.
    ///
    /// - Parameter mode: "HVH" for human vs human, "HVA" for human vs AI.
    /// - Returns: Data to send to the board.
    static func setGameMode(_ mode: String) -> Data {
        return OpenChessCommand.setGameMode(mode: mode).data
    }
    
    /// Set the AI difficulty level.
    ///
    /// - Parameter level: "EASY", "MEDIUM", "HARD", or "EXPERT".
    /// - Returns: Data to send to the board.
    static func setAIDifficulty(_ level: String) -> Data {
        return OpenChessCommand.setAIDifficulty(level: level).data
    }
}

// MARK: - Board State Utilities

/// Utilities for working with Open Chess board state.
public enum OpenChessBoardState {
    
    /// Create an occupancy array from a FEN position string.
    ///
    /// Only handles piece placement (before the first space in FEN).
    /// Returns nil for invalid FEN.
    ///
    /// - Parameter fen: FEN position string (e.g., "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR")
    /// - Returns: 64-element occupancy array in file-major order (a1=0, h8=63).
    static func occupancyFromFEN(_ fen: String) -> [Bool]? {
        let parts = fen.split(separator: " ")
        guard let placement = parts.first else { return nil }
        
        var occupancy = [Bool](repeating: false, count: 64)
        var file = 0
        var rank = 7 // Start from rank 8 (top of board)
        
        for char in placement {
            if char == "/" {
                rank -= 1
                file = 0
            } else if let digits = char.wholeNumberValue {
                file += digits
            } else {
                // Piece character
                guard file < 8, rank >= 0 else { return nil }
                let index = file * 8 + rank
                occupancy[index] = true
                file += 1
            }
        }
        
        return occupancy
    }
    
    /// Create a FEN position string from an occupancy array.
    ///
    /// - Parameter occupancy: 64-element array in file-major order (a1=0, h8=63).
    /// - Returns: FEN placement string (without side to move, castling, etc.).
    static func fenFromOccupancy(_ occupancy: [Bool]) -> String {
        guard occupancy.count == 64 else { return "" }
        
        var fen = ""
        for rank in (0..<8).reversed() { // Start from rank 8
            var emptyCount = 0
            for file in 0..<8 {
                let index = file * 8 + rank
                if occupancy[index] {
                    if emptyCount > 0 {
                        fen += String(emptyCount)
                        emptyCount = 0
                    }
                    // Use 'P' for occupied squares (piece type unknown)
                    fen += "P"
                } else {
                    emptyCount += 1
                }
            }
            if emptyCount > 0 {
                fen += String(emptyCount)
            }
            if rank > 0 {
                fen += "/"
            }
        }
        
        return fen
    }
}

// MARK: - Protocol Documentation

/*
 ## Open Chess Protocol Specification (Proposed)
 
 ### Overview
 
 The Open Chess protocol is a text-based protocol for communicating with
 Open Chess Arduino-based smart chessboards. It is designed to be simple
 to implement on both the Arduino firmware and the host application.
 
 ### Physical Layer
 
 - **USB Serial**: 9600 baud, 8N1 (8 data bits, no parity, 1 stop bit)
 - **WiFi TCP**: Port 8888 (configurable)
 
 ### Frame Format
 
 All frames are ASCII text terminated by a newline character (`\n`).
 
 ```
 <code>:<payload>\n
 ```
 
 - **code**: 2-character command code (uppercase)
 - **payload**: Variable-length ASCII data (may be empty)
 
 ### Board → Host Events
 
 | Code | Name | Payload | Description |
 |------|------|---------|-------------|
 | SE | Sensor Event | `<square><state>` | Square occupancy changed. square=2-char algebraic (e.g., "e2"), state="L" (lift) or "P" (place) |
 | OC | Occupancy Snapshot | `<64 bits>` | Full board state. 64 chars of '0'/'1', a1..h8 order |
 | RD | Ready | (empty) | Board initialized and ready |
 | MV | Move Executed | `<from><to>` | Move confirmed. from/to are 2-char algebraic |
 | IV | Invalid Move | `<reason>` | Move rejected (reason text) |
 | GO | Game Over | `<result>` | Game ended. result="W" (white wins), "B" (black wins), "D" (draw) |
 | BL | Battery Level | `<percent>` | Battery level 0-100 |
 | ER | Error | `<message>` | Error or disconnection |
 
 ### Host → Board Commands
 
 | Code | Name | Payload | Description |
 |------|------|---------|-------------|
 | CMD | Command | `NEWGAME` or `GETSTATE` | Start new game or request board state |
 | LED | Set LEDs | `<sq1>,<sq2>,...` | Light up squares (white) |
 | LEDC | Set LED Color | `<sq><r><g><b>` | Set LED color (0-255) |
 | LED | Clear LEDs | `CLEAR` | Turn off all LEDs |
 | MOVE | Execute Move | `<from><to>` | Make a move (motorized boards) |
 | MODE | Set Mode | `HVH` or `HVA` | Set game mode |
 | AI | Set AI Level | `EASY`/`MEDIUM`/`HARD`/`EXPERT` | Set AI difficulty |
 
 ### Examples
 
 1. **Piece lifted from e2**:
    ```
    SE:e2L\n
    ```
 
 2. **Piece placed on e4**:
    ```
    SE:e4P\n
    ```
 
 3. **Request board state**:
    ```
    CMD:GETSTATE\n
    ```
 
 4. **Response with occupancy**:
    ```
    OC:1111111111111111000000000000000000000000000000001111111111111111\n
    ```
 
 5. **Highlight squares e2 and e4**:
    ```
    LED:e2,e4\n
    ```
 
 6. **Set LED to red**:
    ```
    LEDC:e4255000\n
    ```
 
 ### Implementation Notes
 
 1. The board should buffer incoming bytes and parse frames on newline.
 2. The board should send sensor events as they occur (interrupt-driven).
 3. The board should send a full occupancy snapshot on request or after
    a new game is started.
 4. LED commands should be processed immediately and acknowledged with
    a ready event if needed.
 5. The board should validate moves and send invalid move events for
    illegal moves.
 
 ### Firmware Extension
 
 To implement this protocol in the Open Chess firmware, the following
 changes would be needed:
 
 1. Add serial command parsing in the main loop
 2. Add sensor event reporting (on piece lift/place)
 3. Add LED control commands (beyond internal game logic)
 4. Add WiFi TCP server for remote control
 5. Add game state management for external control mode
 
 ### Future Extensions
 
 - Piece identity (RFID or other technology)
 - Motorized piece movement
 - Time control support
 - Game recording and replay
 - Multiple board connections
 */
