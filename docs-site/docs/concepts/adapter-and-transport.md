# Adapter & transport protocols

BoardKit separates two concerns into two protocols:

- **`BoardAdapter`** — pure wire framing. A value type that accumulates raw
  bytes, parses frames, and emits `[BoardEvent]`. No I/O, no async, no
  concurrency primitives. Lives in the library target.
- **`BoardTransport`** — platform radio. A reference type that owns the BLE or
  USB-HID link, holds a `BoardAdapter`, and exposes an `AsyncStream<BoardEvent>`
  to the session layer. Lives in the app target where `CoreBluetooth` or
  `SkipFuse` is available.

---

## BoardAdapter

`BoardAdapter` is a `Sendable` protocol. Every concrete adapter is a **value
type** (struct) so the test harness can copy it cheaply without heap allocation.

```swift
public protocol BoardAdapter: Sendable {
    var capabilities: BoardCapabilities { get }
    var minimumWriteInterval: TimeInterval { get }
    mutating func feed(bytes: Data) -> [BoardEvent]
    func encode(_ command: BoardCommand) -> Data?
    func handshakeCommands(isReconnect: Bool)
        -> [(command: BoardCommand, delayBefore: TimeInterval)]
    // Default: empty. Ack-based protocols like ChessUp override it —
    // the transport must drain it after every feed(bytes:).
    mutating func takePendingResponses() -> [Data]
}
```

### `capabilities`

Queried once at connect time. The session reads this immediately after
connecting and routes events through the appropriate kernel path
(occupancy-only vs. identity-aware).

### `feed(bytes:)`

The adapter accumulates partial frame bytes across calls (framing is
stateful). Emits events only when a complete frame boundary is reached.
Must be called serially — concurrent calls to a `mutating` function on a
value type are undefined behavior. An empty `Data` is safe (no-op).

### `encode(_:)`

Returns the wire bytes for a `BoardCommand`, or `nil` when the command is
unsupported for this board. The transport silently skips `nil` results.

### `minimumWriteInterval`

The transport serializes every outgoing adapter payload through one writer and
leaves at least this many seconds between physical writes. This includes normal
commands, handshake commands, and values returned by
`takePendingResponses()`. The default is zero. `ChessnutAdapter` declares
`0.2` seconds because classic Chessnut firmware requires a 200 ms write floor;
stored-game import can queue three responses from one incoming frame, so those
responses must not be written as a synchronous burst.

### `handshakeCommands(isReconnect:)`

Returns the ordered handshake sequence the transport executes after a link
is established. Returning the sequence (rather than executing it) keeps the
adapter pure and testable without a live transport or timer.

`isReconnect: true` for a restored link (BLE drop-and-reconnect),
`false` for the initial fresh connection.

### `takePendingResponses()`

Mandatory wire-level responses the adapter queued while parsing the most
recent `feed(bytes:)` input. The default implementation returns `[]`;
ack-based protocols override it. The ChessUp board retransmits every `0xA3`
move frame until the host writes a `0x21` ack (and board-side promotions
until a `0x23` ack) — leaving them unacked floods the notify pipe until the
BLE link drops. The transport MUST call this immediately after every
`feed(bytes:)` and enqueue each returned payload on the same serialized, paced
writer used for normal commands. Draining is destructive: each queued response
is returned exactly once.

```swift
// Chessnut Air — first connect:
// [(command: .startSession, delayBefore: 0)]

// Square Off — first connect:
// [(command: .startSession, delayBefore: 0.25),
//  (command: .requestState, delayBefore: 0.15)]
```

---

## BoardTransport

`BoardTransport` is a `@MainActor` protocol (conformers are `@Observable`
classes observed by SwiftUI or SkipFuse). Its implementation lives in the app
target; BoardKit defines only the protocol.

```swift
@MainActor
public protocol BoardTransport: AnyObject {
    var state: BoardTransportState { get }
    var discovered: [DiscoveredBoardDevice] { get }
    var connectedDeviceName: String? { get }
    var lastError: String? { get }
    var events: AsyncStream<BoardEvent> { get }

    func startScan()
    func stopScan()
    func connect(_ device: DiscoveredBoardDevice)
    func disconnect()
    func send(_ command: BoardCommand)
}
```

The transport's responsibility is:

1. On raw BLE data arrival: call `adapter.feed(bytes:)` → yield each
   `BoardEvent` into `events`.
   After each feed, call `adapter.takePendingResponses()` and write every
   returned payload to the board's write characteristic through the same
   serialized writer used by `send(_:)`.
2. On link established: yield `.connected`, execute
   `adapter.handshakeCommands(isReconnect:)` with inter-command delays and the
   adapter's `minimumWriteInterval` floor, then let `adapter.feed()` emit
   `.ready` when the board ACKs.
3. On link drop: yield `.disconnected(error:)`.

```
┌─────────────┐  raw bytes  ┌──────────────┐  BoardEvent  ┌──────────────┐
│  BLE radio  │ ──────────► │ BoardAdapter │ ────────────► │BoardTransport│
└─────────────┘             └──────────────┘               │   .events    │
                                                            └──────────────┘
```

### BoardTransportState

```swift
public enum BoardTransportState: Equatable, Sendable {
    case poweredOff
    case unauthorized
    case idle
    case scanning
    case connecting
    case connected
    case disconnected
    case reconnecting(attempt: Int)
}
```

`.connected` means the transport has a writable link and its notification
subscription is active. It deliberately precedes the adapter handshake; wait
for `BoardEvent.ready` before treating the board's sensor stream as ready.

The `.reconnecting(attempt:)` case is 1-indexed. Display as
"Reconnecting (attempt N/5)…" alongside a `BoardReconnectPolicy` that
supplies the per-attempt delay schedule.

### DiscoveredBoardDevice

```swift
public struct DiscoveredBoardDevice: Identifiable, Equatable, Sendable {
    public let id: UUID       // stable OS-assigned peripheral UUID
    public let name: String   // advertised device name ("Chessnut Air", …)
    public let rssi: Int      // signal strength in dBm — use for proximity sorting
    public let token: String  // opaque transport token; do not interpret
}
```

Discovered devices are listed in `transport.discovered` during a scan.
Pass one to `transport.connect(_:)` to initiate a connection.
