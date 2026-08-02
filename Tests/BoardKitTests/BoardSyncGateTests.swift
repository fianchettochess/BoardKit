import Testing
import BoardKit
import ChessCore

/// Covers `BoardSyncGate`, the pure-logic state machine behind an
/// over-the-board view's clock-pause + haptic on physical board desync.
struct BoardSyncGateTests {

    @Test func testSteadyStateSyncedReturnsNone() {
        var gate = BoardSyncGate()
        let action = gate.update(
            isOutOfSync: false,
            clockIsRunning: true,
            currentActiveColor: .white
        )
        #expect(action == .none)
        #expect(!(gate.shouldFireHaptic))
    }

    @Test func testEnteringDesyncWhileClockRunningPausesAndHaptics() {
        var gate = BoardSyncGate()
        let action = gate.update(
            isOutOfSync: true,
            clockIsRunning: true,
            currentActiveColor: .black
        )
        #expect(action == .pauseClock)
        #expect(gate.shouldFireHaptic)
        #expect(gate.clockWasRunningBeforeDesync)
        #expect(gate.pausedActiveColor == .black)
        #expect(gate.isDesynced)
    }

    @Test func testEnteringDesyncWithStoppedClockSkipsPauseButStillHaptics() {
        var gate = BoardSyncGate()
        let action = gate.update(
            isOutOfSync: true,
            clockIsRunning: false,
            currentActiveColor: .white
        )
        #expect(action == .none)
        #expect(gate.shouldFireHaptic)
        #expect(!(gate.clockWasRunningBeforeDesync))
    }

    @Test func testStayingDesyncedDoesNotRepeatHaptic() {
        var gate = BoardSyncGate()
        _ = gate.update(isOutOfSync: true, clockIsRunning: true, currentActiveColor: .white)
        gate.acknowledgeHaptic()
        let action = gate.update(isOutOfSync: true, clockIsRunning: false, currentActiveColor: .white)
        #expect(action == .none)
        #expect(!(gate.shouldFireHaptic), "Per-event chatter should not retrigger the haptic")
    }

    @Test func testLeavingDesyncResumesClockForSamesSide() {
        var gate = BoardSyncGate()
        // White was on the move when the board went out of sync.
        _ = gate.update(isOutOfSync: true, clockIsRunning: true, currentActiveColor: .white)
        gate.acknowledgeHaptic()
        // Reconciled.
        let action = gate.update(isOutOfSync: false, clockIsRunning: false, currentActiveColor: .white)
        #expect(action == .resumeClock(color: .white))
        #expect(!(gate.clockWasRunningBeforeDesync), "Flag should clear after resume so a re-entry recomputes from scratch")
    }

    @Test func testLeavingDesyncWithoutPriorPauseDoesNotResume() {
        var gate = BoardSyncGate()
        // Entered desync with the clock already stopped, so we never
        // paused it; on exit there's nothing to resume.
        _ = gate.update(isOutOfSync: true, clockIsRunning: false, currentActiveColor: .white)
        gate.acknowledgeHaptic()
        let action = gate.update(isOutOfSync: false, clockIsRunning: false, currentActiveColor: .white)
        #expect(action == .none)
    }

    @Test func testResumeUsesCurrentActiveColorAfterResolutionAppliedMove() {
        // Entered desync on Black's turn. While desynced, a diff
        // resolution committed Black's move — `game.position.activeColor`
        // advanced to White. On exit-from-desync the gate must resume
        // the clock on whichever side is on the move NOW (White), not
        // on the side that was on the move when we paused (Black).
        var gate = BoardSyncGate()
        _ = gate.update(isOutOfSync: true, clockIsRunning: true, currentActiveColor: .black)
        gate.acknowledgeHaptic()
        let action = gate.update(isOutOfSync: false, clockIsRunning: false, currentActiveColor: .white)
        #expect(action == .resumeClock(color: .white))
    }

    @Test func testAcknowledgeHapticIsIdempotent() {
        var gate = BoardSyncGate()
        _ = gate.update(isOutOfSync: true, clockIsRunning: true, currentActiveColor: .white)
        gate.acknowledgeHaptic()
        gate.acknowledgeHaptic()
        #expect(!(gate.shouldFireHaptic))
    }
}
