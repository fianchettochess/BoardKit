import Foundation

/// Pure-value reconnect policy for a physical chess board's BLE transport.
///
/// Encodes the reconnect schedule for unexpected disconnections (BLE drop,
/// not user-initiated). The transport layer instantiates one policy, then
/// calls `nextDelay(attempt:)` before each reconnection attempt and gives up
/// when the attempt count exceeds `maxAttempts`.
///
/// Board-agnostic kernel — applies to any BLE transport (Square Off, Chessnut,
/// DGT Pegasus, etc.). Renamed from SquareOffReconnectPolicy on 2026-07-03.
///
/// **Policy**
///   - Max 5 attempts per disconnection.
///   - Back-off schedule: 2 s → 4 s → 8 s → 8 s → 8 s (attempt 1 through 5).
///   - Beyond attempt 5 (or below 1): nil — give up.
///
/// Callers that want to surface attempt progress in UI should expose an
/// `attempt: Int` observable on the transport alongside its state, and
/// build the "Reconnecting (attempt N/5)…" label from it.
public struct BoardReconnectPolicy: Sendable {

    /// Maximum number of reconnection attempts before the transport gives up
    /// and stays in `.disconnected`.
    public let maxAttempts: Int

    public init(maxAttempts: Int = 5) {
        self.maxAttempts = maxAttempts
    }

    /// Delay to wait before the given reconnect attempt (1-indexed).
    ///
    /// - Parameter attempt: 1-based attempt number.
    /// - Returns: The delay to sleep before firing the attempt, or `nil` if
    ///   `attempt` is out of the valid range (`1…maxAttempts`).
    ///
    /// Schedule for the default `maxAttempts == 5`:
    ///
    /// | Attempt | Delay |
    /// |---------|-------|
    /// | 1       | 2 s   |
    /// | 2       | 4 s   |
    /// | 3–5     | 8 s   |
    public func nextDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        switch attempt {
        case 1:  return 2
        case 2:  return 4
        default: return 8
        }
    }
}
