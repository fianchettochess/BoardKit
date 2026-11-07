import Foundation

/// Counts how often each square's reading flips, against a clock the caller
/// supplies, so a session can tell a flickering sensor from a move.
///
/// Occupancy-only boards (Square Off, Pegasus, uncalibrated Certabo, Tabutronic
/// Sentio) have no piece identity to reject a phantom reading: a square that
/// toggles occupied/empty a few times in a second looks, to the inference
/// kernels, like pieces arriving and leaving. This kernel is the piece of the
/// flicker filter that needs time (Fianchetto-1ml):
///
/// - ``isFlickering(_:at:)``: the square toggled at least
///   ``Thresholds/flickerToggles`` times within ``Thresholds/window``.
/// - ``isSettled(_:for:at:)``: the square has not toggled for a given span, so
///   a move landing on it can be committed.
/// - ``totalToggles``: lifetime counts per square, for telling the player that
///   a square is reading unreliably instead of prompting another resync.
///
/// It is a pure value: no `Date`, no timers. The transport stamps each event
/// with a monotonic receive time (seconds, any origin) and passes it in;
/// `BoardEvent` itself carries no time. Times must not go backwards between
/// calls. Only `squareSensed` events count; snapshots are state, not toggles.
public struct SquareToggleMonitor: Equatable, Sendable {

    /// When a square counts as flickering.
    public struct Thresholds: Equatable, Sendable {
        /// Span, in seconds, over which toggles are counted.
        public var window: TimeInterval
        /// Toggles within `window` at which a square is flickering. A real move
        /// toggles its squares once each (twice for a lift-and-replace), so the
        /// default of four is two full lift/place pairs.
        public var flickerToggles: Int

        public init(window: TimeInterval = 1.0, flickerToggles: Int = 4) {
            self.window = window
            self.flickerToggles = flickerToggles
        }
    }

    public let thresholds: Thresholds

    /// Toggle times per square still inside the window of the latest record.
    private var recent: [String: [TimeInterval]] = [:]

    /// Every toggle seen per square since creation or `reset()`.
    public private(set) var totalToggles: [String: Int] = [:]

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// Record one adapter event received at `time`. Ignores everything but
    /// `squareSensed`.
    public mutating func record(_ event: BoardEvent, at time: TimeInterval) {
        guard case .squareSensed(let square, _, _) = event else { return }
        recordToggle(of: square, at: time)
    }

    /// Record that `square`'s reading flipped at `time`.
    public mutating func recordToggle(of square: String, at time: TimeInterval) {
        var times = recent[square, default: []]
        times.removeAll { $0 <= time - thresholds.window }
        times.append(time)
        recent[square] = times
        totalToggles[square, default: 0] += 1
    }

    /// Toggles of `square` in the window ending at `time`.
    public func toggles(of square: String, at time: TimeInterval) -> Int {
        (recent[square] ?? []).filter { $0 > time - thresholds.window && $0 <= time }.count
    }

    /// Whether `square` toggled often enough in the window ending at `time`
    /// to be treated as sensor noise.
    public func isFlickering(_ square: String, at time: TimeInterval) -> Bool {
        toggles(of: square, at: time) >= thresholds.flickerToggles
    }

    /// Every flickering square at `time`, in algebraic order.
    public func flickeringSquares(at time: TimeInterval) -> [String] {
        recent.keys.filter { isFlickering($0, at: time) }.sorted()
    }

    /// Whether `square` has gone at least `duration` seconds without a toggle
    /// as of `time`. A square never seen toggling is settled.
    public func isSettled(_ square: String, for duration: TimeInterval, at time: TimeInterval) -> Bool {
        guard let last = recent[square]?.last else { return true }
        return time - last >= duration
    }

    /// Forget everything, for a new game or a reconnect.
    public mutating func reset() {
        recent.removeAll()
        totalToggles.removeAll()
    }
}
