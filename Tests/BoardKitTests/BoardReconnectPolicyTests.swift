import Testing
import Foundation
import BoardKit

/// Tests for `BoardReconnectPolicy` — the pure-value reconnect schedule
/// shared by the iOS and Android BLE transports.
struct BoardReconnectPolicyTests {

    private let policy = BoardReconnectPolicy()

    // MARK: - Default configuration

    @Test func testDefaultMaxAttempts() {
        #expect(policy.maxAttempts == 5)
    }

    @Test func testCustomMaxAttempts() {
        let custom = BoardReconnectPolicy(maxAttempts: 3)
        #expect(custom.maxAttempts == 3)
    }

    // MARK: - Back-off schedule (default policy)

    @Test func testAttempt1Delay() {
        #expect(policy.nextDelay(attempt: 1) == 2)
    }

    @Test func testAttempt2Delay() {
        #expect(policy.nextDelay(attempt: 2) == 4)
    }

    @Test func testAttempt3Delay() {
        #expect(policy.nextDelay(attempt: 3) == 8)
    }

    @Test func testAttempt4Delay() {
        #expect(policy.nextDelay(attempt: 4) == 8)
    }

    @Test func testAttempt5Delay() {
        #expect(policy.nextDelay(attempt: 5) == 8)
    }

    // MARK: - Out-of-range attempts return nil (give up)

    @Test func testAttempt0ReturnsNil() {
        #expect(policy.nextDelay(attempt: 0) == nil, "Attempt 0 is invalid — policy gives up")
    }

    @Test func testAttemptBeyondMaxReturnsNil() {
        #expect(policy.nextDelay(attempt: policy.maxAttempts + 1) == nil, "Attempt beyond maxAttempts should return nil")
    }

    @Test func testNegativeAttemptReturnsNil() {
        #expect(policy.nextDelay(attempt: -1) == nil)
    }

    // MARK: - Custom max policy only runs for its range

    @Test func testCustomPolicy3AttemptSchedule() {
        let custom = BoardReconnectPolicy(maxAttempts: 3)
        #expect(custom.nextDelay(attempt: 1) == 2)
        #expect(custom.nextDelay(attempt: 2) == 4)
        #expect(custom.nextDelay(attempt: 3) == 8)
        #expect(custom.nextDelay(attempt: 4) == nil, "Fourth attempt exceeds custom maxAttempts of 3")
    }

    // MARK: - Injected schedules

    @Test func testInjectedScheduleIsUsedVerbatim() {
        let eager = BoardReconnectPolicy(delays: [0.5, 1, 2])
        #expect(eager.nextDelay(attempt: 1) == 0.5)
        #expect(eager.nextDelay(attempt: 2) == 1)
        #expect(eager.nextDelay(attempt: 3) == 2)
    }

    @Test func testScheduleShorterThanMaxAttemptsHoldsItsLastValue() {
        let policy = BoardReconnectPolicy(maxAttempts: 6, delays: [1, 3])
        #expect(policy.nextDelay(attempt: 2) == 3)
        #expect(policy.nextDelay(attempt: 3) == 3, "attempts past the schedule hold the last delay")
        #expect(policy.nextDelay(attempt: 6) == 3)
        #expect(policy.nextDelay(attempt: 7) == nil, "maxAttempts still bounds the retry loop")
    }

    @Test func testScheduleLongerThanMaxAttemptsIsBoundedByMaxAttempts() {
        let policy = BoardReconnectPolicy(maxAttempts: 2, delays: [1, 2, 3, 4])
        #expect(policy.nextDelay(attempt: 2) == 2)
        #expect(policy.nextDelay(attempt: 3) == nil)
    }

    @Test func testEmptyScheduleFallsBackToTheDefault() {
        let policy = BoardReconnectPolicy(delays: [])
        #expect(policy.delays == [2, 4, 8])
        #expect(policy.nextDelay(attempt: 1) == 2)
    }

    // MARK: - Full schedule is monotonically non-decreasing

    @Test func testScheduleIsMonotonicallyNonDecreasing() {
        var previous: TimeInterval = 0
        for attempt in 1...policy.maxAttempts {
            guard let delay = policy.nextDelay(attempt: attempt) else {
                Issue.record("Unexpected nil for attempt \(attempt)")
                return
            }
            #expect(delay >= previous, "Delay for attempt \(attempt) (\(delay)) must be >= previous (\(previous))")
            previous = delay
        }
    }
}
