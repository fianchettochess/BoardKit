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
// events: [.connected, .identitySnapshot([Piece?]), .ready]
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

To assert delay values without blocking, inspect `replay.recordedSteps` — it
exposes the full script (including `.delay` steps) exactly as provided at init:

```swift
// Assert that a delay step was recorded between frames:
let steps = replay.recordedSteps
if case .delay(let t) = steps[1] {
    XCTAssertGreaterThan(t, 0.1)
}
```

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
# Paste output (rx lines) into a new .replay file. Tests/Fixtures/ does not
# exist yet — create it with your first fixture and load it via a
# #filePath-relative path (the test target declares no SwiftPM resources),
# or follow the existing Captures/ convention.
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
// [squareSensed("e2", isLift: true, piece: Piece(type: .pawn, color: .white)),
//  squareSensed("e4", isLift: false, piece: Piece(type: .pawn, color: .white))]

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

# Select the board kind as the first positional argument:
.build/release/boardkit-emulator chessnut

# Play a specific PGN file (main line only):
.build/release/boardkit-emulator chessnut --pgn game.pgn

# Dry-run (no BLE, print frames and exit after N plies):
.build/release/boardkit-emulator chessnut --dry-run 8

# Other personality tokens: squareoff | pegasus | millennium | certabo | chessup
.build/release/boardkit-emulator millennium --chaos clumsy --seed 42
```

The board kind is selected via a **positional token** (`squareoff`, `chessnut`,
`pegasus`, `millennium`, `certabo`, or `chessup`) — there is no `--personality`
flag. Game input comes from `--pgn <file>` or a seeded random game; there is
no `--moves` flag. Run `boardkit-emulator --help` to see the full option list.

The emulator personalities reuse the same host-side codec structs from the
adapter targets in the **opposite direction** — encoding the board's outbound
frames using the same tables the adapter uses to decode them.

---

## Chaos / fallible-human simulation

`ChaosEngine` (in `BoardKitTestSupport`) transforms the clean sensor event
sequence for one chess move into a perturbed stream that models how a real
human actually handles pieces on a sensor board: j'adoube adjusts, captures
executed in either order, lift-and-put-back second thoughts, slow two-phase
castles, pieces slid across intermediate squares, sensor chatter, knocked
neighbours, promotion piece-swaps, and mid-move stalls.

The same engine is shared between the `boardkit-emulator` tool and consumer
unit tests, so CI and the live radio path exercise identical perturbation logic.

### Determinism contract

`ChaosEngine.perturb` is a pure function of `(context, profile, rng state)`.
No `Date`, no uncontrolled randomness. Pass the same `SeededRNG` seed and you
get byte-identical perturbation streams on every run.

### ChaosProfile presets

| Profile | Characteristics |
|---|---|
| `.clean` | No perturbation; steady human pacing |
| `.casual` | Occasional j'adoube, captures sometimes captured-piece-first, human-speed castles |
| `.clumsy` | Same tolerated patterns as `.casual` at much higher rates |
| `.hostile` | Everything in `.clumsy` plus dragged-piece blips and knocked neighbours (adversarial) |

Profiles `.clean`, `.casual`, and `.clumsy` draw only **tolerated** patterns:
the `OccupancyMoveInference` and `BoardExecutionGate` kernels must resolve and
execute 100% of streams from these profiles. `.hostile` adds adversarial
patterns that may legitimately deviate the gate — the survival corpus asserts
the outcome distribution rather than perfection.

### Usage

```swift
import BoardKitTestSupport

// Build a context from the clean SimulatedBoard events for one move.
let sim = SimulatedBoard(
    position: .initial(),
    capabilities: [.occupancySensing, .pieceIdentity]
)
let cleanEvents = try await sim.executeMove(uci: "e2e4")
let move = /* ChessCore.Move for e2e4 */
let context = ChaosMoveContext(
    move: move,
    positionBefore: .initial(),
    cleanEvents: cleanEvents
)

// Perturb with a seeded RNG for reproducibility.
var rng = SeededRNG(seed: 0xDEAD_BEEF)
let engine = ChaosEngine(profile: .casual)
let result = engine.perturb(context, rng: &rng)

// result.events: [ChaosMoveEvent] — feed into your inference under test.
// result.appliedPatterns: [ChaosPatternID] — log which transforms fired.
for event in result.events {
    let feedback = inference.handle(square: event.square, isLift: event.isLift)
    // … assert feedback
}
```

### ChaosPatternID

Every transform the engine can apply is identified by a `ChaosPatternID` case
(e.g. `.adjustInPlace`, `.captureOrderSwap`, `.knockedNeighbor`). The
`appliedPatterns` array in `ChaosPerturbation` lists exactly which patterns
fired for a given call, letting tests classify and assert outcome distributions
per pattern type.

### SeededRNG

`SeededRNG` is a simple xorshift64 generator exposed publicly so consumer tests
can produce reproducible perturbation streams independently of the engine. Pass
an explicit seed to `SeededRNG(seed:)` and the perturbation output is
byte-identical across platforms and Swift versions.
