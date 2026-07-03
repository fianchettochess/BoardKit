import Foundation
import ChessCore
import BoardKit

/// A deterministic, synchronous test harness that replays a scripted
/// sequence of byte chunks and lifecycle events through a real
/// `BoardAdapter`.
///
/// Use for adapter framing regressions against captured byte streams.
/// For session-level tests that bypass byte decoding, use `SimulatedBoard`.
///
/// ## Usage
///
/// ```swift
/// var adapter = ChessnutAdapter()
/// let replay = ReplayTransport(adapter: adapter, script: [
///     .bytes(Data([0x01, 0x22, ...])),   // initial-position frame
///     .bytes(Data([0x01, 0x22, ...])),   // after 1.e4
/// ])
/// let events = replay.runSync()
/// // events contains identitySnapshot + squareSensed deltas
/// ```
///
/// ## Delay steps
///
/// `Step.delay(_:)` is recorded in the script but does NOT sleep during
/// `runSync()` execution. Tests that need timing verification can inspect
/// `recordedSteps` to assert the expected delay values without blocking.
///
/// ## Conformance note
///
/// `ReplayTransport` does NOT conform to `BoardTransport` — it intentionally
/// omits the BLE scan/connect surface that requires a platform import. It
/// replaces only the byte-injection path, which is sufficient for adapter
/// unit tests.
public final class ReplayTransport<A: BoardAdapter>: @unchecked Sendable {

    /// A single step in a replay script.
    public enum Step: Sendable {
        /// Raw wire bytes to push through `adapter.feed(bytes:)`.
        case bytes(Data)
        /// Inject a lifecycle event directly into the output stream
        /// (bypasses the adapter parser — use for `.connected`,
        /// `.disconnected`, etc.).
        case lifecycle(BoardEvent)
        /// Record a delay. Not enforced during `runSync()`.
        case delay(Duration)
    }

    private var adapter: A
    private let script: [Step]

    /// The script as provided at init; inspectable for timing assertions.
    public var recordedSteps: [Step] { script }

    public init(adapter: A, script: [Step]) {
        self.adapter = adapter
        self.script = script
    }

    /// Execute the full script synchronously and return all emitted events
    /// in emission order.
    ///
    /// `delay` steps are skipped (not executed). Lifecycle events are
    /// appended directly. Byte steps are pushed through `adapter.feed`.
    @discardableResult
    public func runSync() -> [BoardEvent] {
        var adapter = self.adapter   // local mutable copy
        var events: [BoardEvent] = []
        for step in script {
            switch step {
            case .bytes(let data):
                events += adapter.feed(bytes: data)
            case .lifecycle(let event):
                events.append(event)
            case .delay:
                break   // not enforced in synchronous mode
            }
        }
        return events
    }

    /// Execute steps one at a time and return the events from each step,
    /// preserving per-step granularity.
    ///
    /// Useful when a test needs to assert the event set between step N and
    /// step N+1 rather than the cumulative output.
    public func runByStep() -> [[BoardEvent]] {
        var adapter = self.adapter
        var perStep: [[BoardEvent]] = []
        for step in script {
            switch step {
            case .bytes(let data):
                perStep.append(adapter.feed(bytes: data))
            case .lifecycle(let event):
                perStep.append([event])
            case .delay:
                perStep.append([])
            }
        }
        return perStep
    }
}
