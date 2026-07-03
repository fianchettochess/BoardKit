import Foundation
import ChessCore

/// Pure-logic state machine for the "physical board diverged from the
/// app" transition that drives the clock pause + haptic in the OTB view.
/// The view holds the gate's state in `@State` and feeds it the current
/// `(isOutOfSync, clockRunning, activeColor)` on every change; the gate
/// decides whether the clock should be paused or resumed and whether the
/// entry-only haptic should fire.
///
/// Lives outside the view so the transition logic is unit-testable
/// without standing up SwiftUI. Board-agnostic kernel — renamed from
/// SquareOffSyncGate on 2026-07-03.
public nonisolated struct BoardSyncGate: Sendable {

    public nonisolated enum Action: Equatable, Sendable {
        case none
        case pauseClock
        case resumeClock(color: PieceColor)
    }

    /// Was the clock running the last time we entered the desync state?
    /// We remember this so the resume goes back to running, and pick up
    /// from the correct side's turn. Defaults to false; the gate flips
    /// it when it issues a `pauseClock`.
    public private(set) var clockWasRunningBeforeDesync = false

    /// The side that was on the move when the clock paused. Only
    /// meaningful while `clockWasRunningBeforeDesync` is true.
    public private(set) var pausedActiveColor: PieceColor = .white

    /// Whether we believe the system is currently in the desync state.
    /// Compared against incoming `isOutOfSync` on each update to detect
    /// the false→true entry transition (haptic + pause).
    public private(set) var isDesynced = false

    /// `true` once per entry transition — exposed so the view's
    /// `sensoryFeedback` trigger can bump on it.
    public private(set) var shouldFireHaptic = false

    public init() {}

    /// Process a snapshot of (`isOutOfSync`, current clock state).
    /// Returns the action the caller should take on the clock. Also
    /// flips `shouldFireHaptic` to `true` on the entry transition;
    /// callers consume it via `acknowledgeHaptic()`.
    ///
    /// `currentActiveColor` is the side that is currently on the
    /// move per the **game position** — not the clock's cached color.
    /// On exit-from-desync, the resume uses this current value so a
    /// resolution that committed a move during the desync window
    /// (advancing the position) resumes the clock on the correct
    /// side. The earlier implementation cached
    /// `pausedActiveColor` at desync-entry and resumed with that
    /// remembered value, which inverted the clock forever once a
    /// resolution ran inside the gate. (V1-REVIEW §2 SO High #3)
    public mutating func update(
        isOutOfSync: Bool,
        clockIsRunning: Bool,
        currentActiveColor: PieceColor
    ) -> Action {
        defer { isDesynced = isOutOfSync }
        if isOutOfSync && !isDesynced {
            shouldFireHaptic = true
            if clockIsRunning {
                clockWasRunningBeforeDesync = true
                pausedActiveColor = currentActiveColor
                return .pauseClock
            }
            return .none
        }
        if !isOutOfSync && isDesynced {
            if clockWasRunningBeforeDesync {
                clockWasRunningBeforeDesync = false
                return .resumeClock(color: currentActiveColor)
            }
            return .none
        }
        return .none
    }

    /// Reset the haptic flag after the view has consumed it. Lets the
    /// state machine treat haptic firing as a one-shot per transition.
    public mutating func acknowledgeHaptic() {
        shouldFireHaptic = false
    }
}
