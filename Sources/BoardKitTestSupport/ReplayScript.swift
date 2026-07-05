import Foundation
import BoardKit

// ── ReplayScript — text-format capture parser ─────────────────────────────
//
// Closes the gap between "tester attaches a hex dump / BLE capture log" and
// "regression test replays it".  tshark can extract HCI payload bytes from a
// .pcapng as a sequence of hex lines; paste the result into a .replay file
// and it becomes a permanent golden test via `ReplayTransport`.
//
// ## Format
//
// One directive per line, leading/trailing whitespace stripped. Lines beginning
// with `#` (after trimming) and blank lines are ignored.
//
// | Line form           | Resulting step                              |
// |---------------------|---------------------------------------------|
// | `rx <HEX>`          | `.bytes(Data)` — space-separated hex octets |
// | `delay <MS>`        | `.delay(.milliseconds(Int))`                |
// | `event connected`   | `.lifecycle(.connected)`                    |
// | `event disconnected`| `.lifecycle(.disconnected(error: nil))`     |
//
// Hex octets in `rx` lines are case-insensitive and separated by single
// spaces (e.g. `rx 01 22 00 00 FF`).
//
// tshark one-liner to extract ATT notification payloads from a pcapng:
//   tshark -r capture.pcapng -Y 'btatt.opcode == 0x1b' -T fields \
//          -e btatt.value | sed 's/../& /g;s/ $//' | sed 's/^/rx /'
// Paste the output into a .replay fixture file and add it to Tests/Fixtures/.
//
// ## Usage
//
//   let steps = try ReplayScript.parse(text: scriptText)
//   let replay = ReplayTransport(adapter: ChessnutAdapter(), parsedScript: steps)
//   let events = replay.runSync()

/// A line-oriented text format for board-adapter capture replay.
///
/// Parse `.replay` files into `[ReplayScript.Step]` values, then hand
/// them to `ReplayTransport(adapter:parsedScript:)` to run as a
/// deterministic regression harness.
public struct ReplayScript {

    // MARK: - Parsed step type

    /// A single step decoded from a `.replay` script text file.
    ///
    /// The cases mirror `ReplayTransport.Step` exactly so that
    /// `ReplayTransport(adapter:parsedScript:)` can convert without loss.
    public enum Step: Sendable {
        /// Raw wire bytes decoded from an `rx` line.
        case bytes(Data)
        /// Lifecycle event decoded from an `event` line.
        case lifecycle(BoardEvent)
        /// Delay decoded from a `delay` line (not enforced in `runSync()`).
        case delay(TimeInterval)
    }

    // MARK: - Parse errors

    /// Errors thrown by `ReplayScript.parse(text:)`.
    public enum ParseError: Error, CustomStringConvertible {
        /// The line has a recognised keyword but malformed arguments.
        case malformedLine(lineNumber: Int, text: String, reason: String)
        /// The line starts with an unrecognised keyword.
        case unknownDirective(lineNumber: Int, text: String)

        public var description: String {
            switch self {
            case .malformedLine(let n, let t, let r):
                return "Line \(n): \(r) — \"\(t)\""
            case .unknownDirective(let n, let t):
                return "Line \(n): unknown directive — \"\(t)\""
            }
        }
    }

    // MARK: - Parser

    /// Parse a `.replay` script text and return the decoded step sequence.
    ///
    /// - Parameter text: The full contents of a `.replay` file.
    /// - Returns: Steps in document order; comment and blank lines omitted.
    /// - Throws: `ParseError` on the first malformed or unrecognised line.
    public static func parse(text: String) throws -> [Step] {
        var steps: [Step] = []
        let lines = text.components(separatedBy: .newlines)
        for (zeroBasedIndex, raw) in lines.enumerated() {
            let lineNumber = zeroBasedIndex + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Blank lines and comments.
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Split keyword from the rest.
            let parts = line.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true)
            guard let keyword = parts.first.map(String.init) else { continue }

            switch keyword {
            case "rx":
                let hexString = parts.count > 1 ? String(parts[1]) : ""
                let data = try parseHex(hexString, lineNumber: lineNumber, line: line)
                steps.append(.bytes(data))

            case "delay":
                guard parts.count == 2, let ms = Int(parts[1]) else {
                    throw ParseError.malformedLine(
                        lineNumber: lineNumber, text: line,
                        reason: "`delay` requires a single integer millisecond value")
                }
                steps.append(.delay(Double(ms) / 1000.0))

            case "event":
                guard parts.count == 2 else {
                    throw ParseError.malformedLine(
                        lineNumber: lineNumber, text: line,
                        reason: "`event` requires one argument: connected | disconnected")
                }
                switch String(parts[1]) {
                case "connected":
                    steps.append(.lifecycle(.connected))
                case "disconnected":
                    steps.append(.lifecycle(.disconnected(error: nil)))
                default:
                    throw ParseError.malformedLine(
                        lineNumber: lineNumber, text: line,
                        reason: "unknown event name '\(parts[1])'; expected connected | disconnected")
                }

            default:
                throw ParseError.unknownDirective(lineNumber: lineNumber, text: line)
            }
        }
        return steps
    }

    // MARK: - Hex decode helper

    private static func parseHex(
        _ hexString: String,
        lineNumber: Int,
        line: String
    ) throws -> Data {
        let tokens = hexString.split(separator: " ", omittingEmptySubsequences: true)
        if tokens.isEmpty {
            throw ParseError.malformedLine(
                lineNumber: lineNumber, text: line,
                reason: "`rx` requires at least one hex octet")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(tokens.count)
        for token in tokens {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else {
                throw ParseError.malformedLine(
                    lineNumber: lineNumber, text: line,
                    reason: "invalid hex octet '\(token)'; expected exactly 2 hex digits")
            }
            bytes.append(byte)
        }
        return Data(bytes)
    }
}

// MARK: - ReplayTransport convenience init

extension ReplayTransport {

    /// Initialise from a parsed `ReplayScript` step sequence.
    ///
    /// This is the bridge between `ReplayScript.parse(text:)` and the
    /// adapter test harness:
    ///
    /// ```swift
    /// let steps = try ReplayScript.parse(text: fixtureText)
    /// let replay = ReplayTransport(adapter: ChessnutAdapter(), parsedScript: steps)
    /// let events = replay.runSync()
    /// ```
    public convenience init(adapter: A, parsedScript: [ReplayScript.Step]) {
        let script: [Step] = parsedScript.map { s in
            switch s {
            case .bytes(let d):     return .bytes(d)
            case .lifecycle(let e): return .lifecycle(e)
            case .delay(let d):     return .delay(d)
            }
        }
        self.init(adapter: adapter, script: script)
    }
}
