# BoardKit

BoardKit is a **ChessCore + Foundation** Swift package that defines the adapter seam
between physical chess boards (BLE and USB-HID) and a chess engine or kernel
stack — together with a suite of board-agnostic reconciliation kernels, a
macOS BLE emulator, and a deterministic replay/simulation test harness.

## What BoardKit is

BoardKit is the **seam and kernel layer**. It defines the shared vocabulary
(`BoardEvent`, `BoardCommand`, `BoardCapabilities`, `BoardAdapter`,
`BoardTransport`) and ships the board-agnostic kernels built on it (move
inference, execution gate, diff resolver, correction planner, takeback
detector, sync gate, reconnect policy), so downstream session shells are
written once and work with any physical board brand. BLE and USB-HID
transport code lives in the consuming app targets (where `CoreBluetooth` or
`SkipFuse` is available); BoardKit's library targets import only ChessCore
and Foundation and carry no platform-specific dependencies. The one exception
is the `boardkit-emulator` executable, whose CoreBluetooth peripheral code is
guarded by `#if os(macOS) && canImport(CoreBluetooth)` and never enters the
library graph.

## Products

| Product | Contents |
|---|---|
| `BoardKit` | Seam protocols and types + board-agnostic kernels |
| `SquareOffAdapter` | Square Off wire codec and `BoardAdapter` implementation |
| `ChessnutAdapter` | Chessnut Air-family + Chessnut Move BLE adapters (incl. stored-game import decoder) |
| `PegasusAdapter` | DGT Pegasus BLE adapter |
| `MillenniumAdapter` | Millennium BLE + USB-HID adapter |
| `CertaboAdapter` | Certabo RFID adapter (USB serial, BT Classic, BLE) |
| `ChessUpAdapter` | ChessUp BLE adapter |
| `BoardKitTestSupport` | `ReplayTransport` + `SimulatedBoard` test harness |
| `boardkit-emulator` | macOS CLI BLE peripheral that emulates any supported board |

## Example

```swift
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport

// Replay a captured BLE frame through the Chessnut Air adapter.
var adapter = ChessnutAdapter()
let replay = ReplayTransport(adapter: adapter, script: [
    .lifecycle(.connected),
    .bytes(capturedBLEFrame),         // raw ATT notification payload
])
let events = replay.runSync()
// events: [.connected, .identitySnapshot([Piece?]), .ready]
```

Or, bypass byte-level decoding and drive session logic with a simulated board:

```swift
import BoardKitTestSupport

let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])
let events = try await sim.executeMove(uci: "e2e4")
// [squareSensed("e2", isLift: true, piece: Piece(type: .pawn, color: .white)),
//  squareSensed("e4", isLift: false, piece: Piece(type: .pawn, color: .white))]
```

## License

BoardKit is **MIT licensed**. Adapter implementations may be derived from
MIT-licensed community drivers with source-attribution comments in file
headers. GPL and license-less community sources are treated as **facts only**
— protocol constants may be learned but no code structure is copied. See each
adapter's file header for its specific attribution chain.

## See Also

- [Installation](installation.md) — add BoardKit via Swift Package Manager.
- [Getting Started](getting-started.md) — connect a transport, receive board
  frames, reconcile moves.
- **Concepts** — one page per major subsystem, starting with
  [the seam vocabulary](concepts/seam-vocabulary.md).
- [Usage Examples](examples.md) — task-oriented code samples.
