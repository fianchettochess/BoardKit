import Foundation

/// Builds a ReplayScript-format capture of an emulator session, so every
/// session doubles as a replayable fixture.
///
/// ## Direction mapping
///
/// `ReplayScript` is a HOST-side format: `rx` lines are bytes the host
/// adapter receives (board→host). The emulator therefore logs:
///
/// - board→host notifications as `rx <HEX>` lines — paste the capture into
///   `ReplayTransport(adapter:parsedScript:)` and the host adapter replays
///   the session;
/// - host→board writes as `# tx <HEX>` comment lines — ReplayScript has no
///   host-write directive, so they ride along as comments (parse-ignored,
///   human-readable, and greppable when promoting a capture to a fixture);
/// - elapsed gaps ≥ `delayThresholdMs` as `delay <MS>` lines;
/// - central subscribe/unsubscribe as `event connected` / `event
///   disconnected` lines.
///
/// The output of `text` is guaranteed to round-trip through
/// `ReplayScript.parse(text:)` (asserted by BoardKitEmulatorTests).
///
/// Pure value type — timing is injected by the caller (the BLE server
/// passes real elapsed milliseconds; tests pass fixed values), keeping the
/// recorder deterministic.
public struct CaptureRecorder: Sendable {

    /// Gaps shorter than this are considered pacing noise and not recorded.
    public let delayThresholdMs: Int

    private(set) var lines: [String]

    public init(header: String = "", delayThresholdMs: Int = 100) {
        self.delayThresholdMs = delayThresholdMs
        var initial: [String] = []
        if !header.isEmpty {
            for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                initial.append("# \(line)")
            }
        }
        self.lines = initial
    }

    // MARK: - Recording

    /// Record a board→host notification frame.
    public mutating func recordNotification(_ data: Data, elapsedMs: Int = 0) {
        appendDelayIfNeeded(elapsedMs)
        lines.append("rx \(Self.hex(data))")
    }

    /// Record a host→board write (comment line; see type docs).
    public mutating func recordHostWrite(_ data: Data, elapsedMs: Int = 0) {
        appendDelayIfNeeded(elapsedMs)
        lines.append("# tx \(Self.hex(data))")
    }

    /// Record a lifecycle transition.
    public mutating func recordLifecycle(connected: Bool) {
        lines.append(connected ? "event connected" : "event disconnected")
    }

    /// Record a free-form annotation (move played, pattern applied, …).
    public mutating func recordComment(_ text: String) {
        lines.append("# \(text)")
    }

    private mutating func appendDelayIfNeeded(_ elapsedMs: Int) {
        if elapsedMs >= delayThresholdMs {
            lines.append("delay \(elapsedMs)")
        }
    }

    // MARK: - Output

    /// The capture as `.replay` text (trailing newline included).
    public var text: String {
        lines.joined(separator: "\n") + "\n"
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
