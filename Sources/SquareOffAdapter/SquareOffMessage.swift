import Foundation
import ChessCore
#if canImport(os)
import os

private let framerLog = OSLog(subsystem: "BoardKit", category: "SquareOff.Framer")
#endif

// Square Off wire-protocol codec — SquareOffAdapter kernel.
//
// Moved from FianchettoKit/Sources/FianchettoKit/SquareOff/SquareOffMessage.swift on
// 2026-07-03 into the SquareOffAdapter target inside BoardKit. Wire-protocol names
// (SquareOffMessage, SquareOffFramer, SquareOffParser, SquareOffEvent, SquareOffCommand)
// are intentionally preserved — this file is Square Off-specific and belongs here.
// Pure protocol logic: no CoreBluetooth, no UI — the platform transports own the
// radio and feed bytes through SquareOffFramer.

public struct SquareOffMessage: Equatable, Sendable {
    public let code: String
    public let body: String

    public init(code: String, body: String) {
        self.code = code
        self.body = body
    }

    public var wireRepresentation: String { "\(code)#\(body)*" }
}

public enum SquareOffEvent: Equatable, Sendable {
    /// Code "0" — `0#<square><u|d>*`. Square is two-char algebraic, suffix is `u` (lifted) or `d` (placed).
    case fieldUpdate(square: String, isLift: Bool)
    /// Code "30" response — `30#<64 bits>*`. 64 chars of '0'/'1', one per square in a1..h8 order.
    case boardState(occupancy: [Bool])
    /// Code "14" response — `14#GO*`. Board acknowledges new game.
    case newGameReady
    /// Synthetic event yielded by the transport when the BLE link drops, so
    /// downstream consumers (e.g. the platform SquareOffSession) can clear any
    /// per-move state that would otherwise carry over to the next connection.
    case disconnected
    /// Any other message we haven't modeled.
    case raw(SquareOffMessage)
}

public enum SquareOffCommand: Sendable {
    case startNewGame
    case requestBoardState
    case setLeds(squares: [String])
    case sendMove(uci: String)
    case sendMoveWithComma(from: String, to: String)

    public var wire: String {
        switch self {
        case .startNewGame:
            return "14#1*"
        case .requestBoardState:
            return "30#R*"
        case .setLeds(let squares):
            return "25#\(squares.map { $0.lowercased() }.joined())*"
        case .sendMove(let uci):
            return "0#\(uci)*"
        case .sendMoveWithComma(let from, let to):
            return "24#\(from),\(to)*"
        }
    }

    public var data: Data { Data(wire.utf8) }
}

/// Buffers incoming bytes and emits whole `<code>#<body>*` frames as they complete.
///
/// Declared as a `struct` (value type) so that it composes safely into `Sendable`
/// value types such as `SquareOffAdapter`.
public struct SquareOffFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Hard cap on the accumulation buffer. A peripheral that streams
    /// bytes without ever sending the `*` (0x2A) terminator would
    /// otherwise grow `buffer` without bound for as long as the BLE
    /// link stays up. Real frames are tiny (the largest, a board-state
    /// response, is ~70 bytes), so 64 KB is orders of magnitude above
    /// anything legitimate — hitting it means the stream is garbage,
    /// and dropping the buffer loses nothing parseable. (V1-REVIEW
    /// follow-up 2026-06-10 §3 #20)
    public static let maxBufferSize = 64 * 1024

    public mutating func append(_ data: Data) -> [SquareOffMessage] {
        buffer.append(data)
        var messages: [SquareOffMessage] = []
        while let end = buffer.firstIndex(of: 0x2A) { // '*'
            let frameBytes = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let frame = String(data: Data(frameBytes), encoding: .utf8),
                  let hashIndex = frame.firstIndex(of: "#") else { continue }
            let code = String(frame[..<hashIndex])
            let body = String(frame[frame.index(after: hashIndex)...])
            messages.append(SquareOffMessage(code: code, body: body))
        }
        // Cap applies to the unterminated residue only, after the
        // drain above, so complete frames in an oversized chunk are
        // never discarded.
        if buffer.count > Self.maxBufferSize {
            let droppedCount = buffer.count
            #if canImport(os)
            os_log("Frame buffer exceeded %d bytes with no terminator — dropping %d buffered bytes", log: framerLog, type: .error, Self.maxBufferSize, droppedCount)
            #else
            print("[SquareOff.Framer] Frame buffer exceeded \(Self.maxBufferSize) bytes with no terminator — dropping \(buffer.count) buffered bytes")
            #endif
            // Fresh Data (not `reset()`) so the oversized allocation
            // is actually released.
            buffer = Data()
        }
        return messages
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}

public enum SquareOffParser {
    public static func event(from message: SquareOffMessage) -> SquareOffEvent {
        switch message.code {
        case "0":
            guard message.body.count == 3 else { return .raw(message) }
            let square = String(message.body.prefix(2))
            let suffix = message.body.last
            return .fieldUpdate(square: square.lowercased(), isLift: suffix == "u")
        case "30":
            let occ = message.body.prefix(64).map { $0 == "1" }
            guard occ.count == 64 else { return .raw(message) }
            return .boardState(occupancy: occ)
        case "14":
            if message.body == "GO" { return .newGameReady }
            return .raw(message)
        default:
            return .raw(message)
        }
    }
}
