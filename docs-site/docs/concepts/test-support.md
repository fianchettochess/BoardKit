# Test support & emulator

The `BoardKitTestSupport` library and the `boardkit-emulator` executable make
it possible to develop and test board integrations without physical hardware.

---

## ReplayTransport

A deterministic, synchronous harness that replays a scripted sequence of byte
chunks and lifecycle events through a real `BoardAdapter`.

Use `ReplayTransport` for **adapter framing regressions** against captured byte
streams. For **session-level** tests that bypass byte decoding, use
`SimulatedBoard`.

```swift
import BoardKitTestSupport
import ChessnutAdapter

// Build a script from raw BLE frames.
var adapter = ChessnutAdapter()
let replay = ReplayTransport(adapter: adapter, script: [
    .lifecycle(.connected),
    .bytes(Data([0x01, 0x22, /* ... Chessnut initial-position frame */])),
])
let events = replay.runSync()
// events: [.connected, .identitySnapshot([Piece?])]
```

### Script steps

```swift
public enum ReplayTransport<A: BoardAdapter>.Step: Sendable {
    case bytes(Data)              // push through adapter.feed(bytes:)
    case lifecycle(BoardEvent)    // inject directly into the output stream
    case delay(TimeInterval)      // recorded but NOT enforced in runSync()
}
```

### Execution modes

**`runSync()`** — executes all steps and returns the accumulated event list.
Delay steps are skipped. Use for golden-fixture assertions.

**`runByStep()`** — returns `[[BoardEvent]]`, one inner array per step. Use
when a test needs to assert the event set *between* step N and step N+1.

```swift
let perStep = replay.runByStep()
XCTAssertEqual(perStep[1], [.identitySnapshot(expectedPieces)])
```

!!! note "Conformance"
    `ReplayTransport` does NOT conform to `BoardTransport`. It intentionally
    omits the BLE scan/connect surface that requires a platform import. It
    replaces only the byte-injection path.

---

## ReplayScript

A line-oriented text parser that converts `.replay` capture-log files into
`[ReplayScript.Step]` values for use with `ReplayTransport`.

```swift
let scriptText = try String(contentsOf: fixtureURL, encoding: .utf8)
let steps = try ReplayScript.parse(text: scriptText)
let replay = ReplayTransport(adapter: ChessnutAdapter(), parsedScript: steps)
let events = replay.runSync()
```

### .replay file format

One directive per line. `#`-comment lines and blank lines are ignored.

| Line form | Meaning |
|---|---|
| `rx 01 22 00 FF` | Raw bytes (space-separated hex octets) through `adapter.feed` |
| `delay 250` | Record a 250 ms pause (not enforced in `runSync()`) |
| `event connected` | Inject `.connected` |
| `event disconnected` | Inject `.disconnected(error: nil)` |

### Generating a .replay file from a BLE capture

```sh
# Requires tshark (Wireshark CLI) and an Apple HCI log (.pcapng).
tshark -r capture.pcapng \
  -Y 'btatt.opcode == 0x1b' \
  -T fields -e btatt.value \
  | sed 's/../& /g;s/ $//' \
  | sed 's/^/rx /'
# Paste output (rx lines) into Tests/Fixtures/<board>.replay
```

### Parse errors

`ReplayScript.parse(text:)` throws `ReplayScript.ParseError` on the first
malformed or unrecognised line:

```swift
public enum ReplayScript.ParseError: Error {
    case malformedLine(lineNumber: Int, text: String, reason: String)
    case unknownDirective(lineNumber: Int, text: String)
}
```

---

## SimulatedBoard

A virtual chess board (`actor`) that applies ChessCore moves to a position and
emits the corresponding physical sensor events. Bypasses byte decoding — tests
session logic directly.

```swift
import BoardKitTestSupport

let sim = SimulatedBoard(
    position: .initial(),
    capabilities: [.occupancySensing, .pieceIdentity]
)

// Apply a move and get the physical lift/place events.
let events = try await sim.executeMove(uci: "e2e4")
// [squareSensed("e2", isLift: true, piece: Piece(.pawn, .white)),
//  squareSensed("e4", isLift: false, piece: Piece(.pawn, .white))]

// Emit a full snapshot.
let snapshot = await sim.boardSnapshot()
// .identitySnapshot([Piece?])  — because .pieceIdentity is set

// Reset to a custom position.
await sim.reset(to: endgamePosition)
```

### Event sequences by move type

| Move type | Events emitted (in order) |
|---|---|
| Simple (e2e4) | lift(e2, piece), place(e4, piece) |
| Normal capture | lift(from, mover), lift(to, captured), place(to, mover) |
| En passant (e5d6) | lift(e5, pawn), lift(d5, captured), place(d6, pawn) |
| Castling (e1g1) | lift(e1, K), lift(h1, R), place(f1, R), place(g1, K) |
| Promotion (e7e8q) | lift(e7, pawn), place(e8, queen) |

When capabilities do NOT include `.pieceIdentity`, all `piece` fields are `nil`.

---

## boardkit-emulator

A macOS CLI executable that advertises over real Bluetooth as a physical chess
board. The Fianchetto apps on a real iPhone or iPad connect to it exactly as
they would to physical hardware.

All CoreBluetooth code is inside the executable target, guarded by
`#if os(macOS) && canImport(CoreBluetooth)` — the library targets remain
platform-free.

**Supported personalities** (board emulation profiles):

- `SquareOffPersonality` — Square Off Pro protocol
- `ChessnutPersonality` — Chessnut Air protocol
- `PegasusPersonality` — DGT Pegasus protocol
- `MillenniumPersonality` — Millennium protocol
- `CertaboPersonality` — Certabo protocol
- `ChessUpPersonality` — ChessUp gen-1 protocol

Build and run:

```bash
swift build -c release --product boardkit-emulator
.build/release/boardkit-emulator --personality chessnut --moves e2e4 e7e5
```

The emulator personalities reuse the same host-side codec structs from the
adapter targets in the **opposite direction** — encoding the board's outbound
frames using the same tables the adapter uses to decode them.
