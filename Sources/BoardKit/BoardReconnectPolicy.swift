import Foundation

/// Pure-value reconnect schedule for a physical board's transport.
///
/// Applies to any board and any transport — how long to wait between
/// reconnection attempts after an unexpected drop, and when to stop trying.
/// Neither is a hardware fact: they state how patient a program wants to be, so
/// both are parameters with defaults rather than constants.
///
/// The transport builds one policy, then calls ``nextDelay(attempt:)`` before
/// each reconnection attempt and gives up once it returns `nil`.
///
/// ```swift
/// let policy  = BoardReconnectPolicy()                       // 2 s, 4 s, then 8 s, five attempts
/// let eager   = BoardReconnectPolicy(delays: [0.5, 1, 2])    // three attempts, faster
/// let patient = BoardReconnectPolicy(maxAttempts: 10, delays: [5])
///
/// var attempt = 1
/// while let delay = policy.nextDelay(attempt: attempt) {
///     try await Task.sleep(for: .seconds(delay))
///     if await transport.reconnect() { break }
///     attempt += 1
/// }
/// ```
public struct BoardReconnectPolicy: Sendable {

    /// Maximum number of reconnection attempts before the transport gives up
    /// and stays disconnected.
    public let maxAttempts: Int

    /// The back-off schedule, in seconds, one entry per attempt.
    ///
    /// Attempts past the end of the array repeat the last entry, so a schedule
    /// shorter than ``maxAttempts`` describes a ramp that then holds steady.
    public let delays: [TimeInterval]

    /// Create a policy.
    ///
    /// - Parameters:
    ///   - maxAttempts: How many attempts to make before giving up. Defaults
    ///     to 5.
    ///   - delays: Seconds to wait before each attempt. The last entry is held
    ///     for every attempt beyond its length. Defaults to `[2, 4, 8]` — a
    ///     ramp that then settles. An empty array falls back to that default.
    public init(maxAttempts: Int = 5, delays: [TimeInterval] = [2, 4, 8]) {
        self.maxAttempts = maxAttempts
        self.delays = delays.isEmpty ? [2, 4, 8] : delays
    }

    /// Seconds to wait before the given reconnect attempt.
    ///
    /// - Parameter attempt: 1-based attempt number.
    /// - Returns: The delay to sleep before firing the attempt, or `nil` when
    ///   `attempt` falls outside `1...maxAttempts` — which is the signal to
    ///   stop retrying.
    public func nextDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return delays[min(attempt - 1, delays.count - 1)]
    }
}
