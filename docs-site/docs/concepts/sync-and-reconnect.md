# Sync gate & reconnect policy

Two lightweight value-type utilities handle the board's out-of-sync state
machine and BLE reconnect scheduling.

---

## BoardSyncGate

A pure-logic state machine for the "physical board diverged from the app"
transition that drives the clock pause and haptic in an OTB view.

The session feeds it the current `(isOutOfSync, clockIsRunning, activeColor)`
on every change; the gate decides whether the clock should be paused or
resumed and whether the entry-only haptic should fire.

```swift
public struct BoardSyncGate: Sendable {
    public private(set) var clockWasRunningBeforeDesync: Bool
    public private(set) var pausedActiveColor: PieceColor
    public private(set) var isDesynced: Bool
    public private(set) var shouldFireHaptic: Bool

    public init()

    public mutating func update(
        isOutOfSync: Bool,
        clockIsRunning: Bool,
        currentActiveColor: PieceColor
    ) -> Action

    public mutating func acknowledgeHaptic()
}

public enum BoardSyncGate.Action: Equatable, Sendable {
    case none
    case pauseClock
    case resumeClock(color: PieceColor)
}
```

### Transition rules

| Previous | New | Action |
|---|---|---|
| in sync | out of sync | `.pauseClock` (if clock was running), fire haptic |
| out of sync | in sync | `.resumeClock(color:)` (if clock was paused) |
| same state | same state | `.none` |

`currentActiveColor` in `update` is the side **currently on the move in the
game position** — not the clock's cached color. This ensures a move that
committed during the desync window (advancing the position) resumes the clock
on the correct side.

`acknowledgeHaptic()` resets `shouldFireHaptic` to `false` after the view has
consumed it. The haptic flag is a one-shot per entry transition; consuming it
explicitly prevents re-firing on subsequent updates.

### Example

```swift
var syncGate = BoardSyncGate()

func onBoardUpdate(isOutOfSync: Bool, clockIsRunning: Bool, activeColor: PieceColor) {
    let action = syncGate.update(
        isOutOfSync: isOutOfSync,
        clockIsRunning: clockIsRunning,
        currentActiveColor: activeColor
    )
    switch action {
    case .pauseClock:
        gameClock.pause()
    case .resumeClock(let color):
        gameClock.resume(for: color)
    case .none:
        break
    }
    if syncGate.shouldFireHaptic {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        syncGate.acknowledgeHaptic()
    }
}
```

---

## BoardReconnectPolicy

A pure-value reconnect schedule for unexpected disconnections (a link drop,
not a user-initiated one). How long to wait and when to stop are your
product's patience rather than the hardware's, so both are parameters.

```swift
public struct BoardReconnectPolicy: Sendable {
    public let maxAttempts: Int
    public let delays: [TimeInterval]

    public init(maxAttempts: Int = 5, delays: [TimeInterval] = [2, 4, 8])
    public func nextDelay(attempt: Int) -> TimeInterval?
}
```

The transport calls `nextDelay(attempt:)` before each reconnect attempt.
`nil` means "give up": the attempt is outside `1...maxAttempts`.

Attempts past the end of `delays` repeat its last entry, so a short schedule
describes a ramp that then holds steady. The default `[2, 4, 8]` over five
attempts waits 2 s, 4 s, then 8 s three times.

### Example

```swift
let policy = BoardReconnectPolicy()                    // 2 s, 4 s, then 8 s
// let policy = BoardReconnectPolicy(delays: [0.5, 1]) // impatient, two attempts

for attempt in 1... {
    guard let delay = policy.nextDelay(attempt: attempt) else {
        transport.state = .disconnected
        break
    }
    transport.state = .reconnecting(attempt: attempt)
    try await Task.sleep(for: .seconds(delay))
    await transport.attemptReconnect()
}
```
