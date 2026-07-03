# BoardKit

A Swift package that defines the board-adapter seam between physical chess
boards and the Fianchetto chess engine / kernel stack. MIT licensed.

## Scope

BoardKit is the **seam layer** — it defines the shared vocabulary (`BoardEvent`,
`BoardCommand`, `BoardCapabilities`, `BoardAdapter`, `BoardTransport`) that
lets the kernel stack (move inference, sync gate, correction planner, etc.)
be written once and work with any physical board.

**This package does NOT contain BLE or USB-HID code.** Transport
implementations live in FianchettoKit or the app target (they import
CoreBluetooth or SkipFuse). BoardKit imports only ChessCore (MIT) and
Foundation.

### Two-pass extraction plan

| Pass | Status | Contents |
|---|---|---|
| **1 — Seam + Chessnut adapter** | This commit | BoardEvent/Command/Capabilities/Adapter/Transport protocols; ChessnutAdapter (Air family); test harness (ReplayTransport, SimulatedBoard) |
| **2 — Kernel migration** | Future | Seven SquareOff-rooted kernels migrate from FianchettoKit: BoardExecutionGate, OccupancyMoveInference, OccupancyDiffResolver, BoardCorrectionPlanner, BoardSyncGate, BoardReconnectPolicy, ChessBoardGeometry. A SquareOffAdapter joins ChessnutAdapter. |

After Pass 2, FianchettoKit imports BoardKit for the kernels, and the app
targets swap their `SquareOff*` usage for the `Board*` equivalents without
any session-level logic changing.

## Products

| Product | Contents |
|---|---|
| `BoardKit` | Core seam protocols and types |
| `ChessnutAdapter` | Chessnut Air-family BLE adapter |
| `BoardKitTestSupport` | ReplayTransport + SimulatedBoard test harness |

## Capability matrix

| Board | occupancy | identity | perSquareLEDs | moveIndication | motorised | battery | perPiece |
|---|---|---|---|---|---|---|---|
| Square Off | ✓ | | ✓ | ✓ | ✓ (GKS) | | |
| Chessnut Air | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Air+ | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Pro | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Go | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Move | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| DGT Pegasus | ✓ | | | ✓ (corner) | | | |
| Millennium | ✓ | ✓ | | ✓ (9×9 corner) | | | |
| Certabo | ✓ | ✓ | ✓ | ✓ | | | |

Capabilities for boards not yet implemented (non-Chessnut) are listed for
roadmap planning; only the Chessnut Air adapter exists in this package.

## ChessnutAdapter status

**Protocol-verified** against three authoritative sources (all fetched
2026-07-03):

- `[OFFICIAL-DOC]` github.com/chessnutech/Chessnut_eBoards README.md
  (official vendor documentation, Air / Air+ / Go / Pro)
- `[SWIFT-REF]` github.com/NSStudent/EasyLinkSwiftSDK (MIT licensed)
- `[C-REF]` github.com/chessnutech/EasyLinkSDK (official, MIT licensed)

**Hardware-unverified.** The adapter has NOT been tested against a
physical board or a live BLE capture log. All golden-frame fixtures from
the pinned spec pass (see `Tests/BoardKitTests/GoldenFrameTests.swift`).
Runtime verification is blocked on hardware access or a BLE capture log.

Where the three sources disagreed, the REFERENCE implementations
(SWIFT-REF + C-REF) were followed over OFFICIAL-DOC. Each discrepancy is
documented in a comment in `Sources/ChessnutAdapter/ChessnutAdapter.swift`.

## Quick start

```swift
// 1. Add to Package.swift
.package(path: "../BoardKit"),

// 2. Depend on the products you need
.target(name: "MyApp", dependencies: [
    .product(name: "BoardKit",       package: "BoardKit"),
    .product(name: "ChessnutAdapter", package: "BoardKit"),
])

// 3. Create an adapter and a replay harness (tests / simulator)
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport

var adapter = ChessnutAdapter()
let replay = ReplayTransport(adapter: adapter, script: [
    .bytes(capturedBLEFrame),
])
let events = replay.runSync()
// events: [.identitySnapshot([Piece?]), .ready]
```

## CONTRIBUTING

Adapter PRs need one of:
- **Hardware access**: Connect to a physical board, capture a BLE HCI log
  (on macOS: `sudo btsnoop` or PacketLogger from the Apple developer
  extras), and include the hex dump in the PR description.
- **Capture log**: A `.btsnoop` or Wireshark `.pcapng` file from a known
  board interaction (initial connection, a few moves, battery request).

This is the beta-tester hook: if you own a Chessnut board, opening the
board over a Mac's Bluetooth and running PacketLogger is the fastest path
to unblocking runtime verification.

PRs that add adapters for other boards (DGT Pegasus, Millennium, Certabo,
GoChess) follow the same hardware-or-capture requirement.
