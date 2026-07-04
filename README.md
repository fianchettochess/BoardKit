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

## Products

| Product | Contents |
|---|---|
| `BoardKit` | Core seam protocols and types + board-agnostic kernels |
| `SquareOffAdapter` | Square Off wire codec and BoardAdapter |
| `ChessnutAdapter` | Chessnut Air-family BLE adapter |
| `PegasusAdapter` | DGT Pegasus BLE adapter |
| `MillenniumAdapter` | Millennium BLE + USB-HID adapter |
| `CertaboAdapter` | Certabo RFID adapter (USB serial, BT Classic, BLE) |
| `ChessUpAdapter` | ChessUp BLE adapter |
| `BoardKitTestSupport` | ReplayTransport + SimulatedBoard test harness |

## Capability and status matrix

| Board | Status | occupancy | identity | perSquareLEDs | moveIndication | motorised | battery | perPiece |
|---|---|---|---|---|---|---|---|---|
| Square Off Pro/GKS | **Battle-tested in-app** | ✓ | | ✓ | ✓ | ✓ (GKS, quarantined) | | |
| Chessnut Air | **Protocol-verified** | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Air+ | **Protocol-verified** | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Pro | **Protocol-verified** | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Go | **Protocol-verified** | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Move | **Protocol-pinned; should work; hardware-unverified** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| DGT Pegasus | **Protocol-pinned; should work; hardware-unverified** | ✓ | | ✓ | ✓ | | ✓ | |
| Millennium (BLE/USB) | **Protocol-pinned; should work; hardware-unverified** | ✓ | ✓ | | ✓ (9×9 corner) | | | |
| Certabo (classic LED) | **Protocol-pinned; should work; hardware-unverified** | ✓ | ✓ (calibrated) | ✓ | ✓ | | | |
| Certabo Spectrum RGB | **Protocol-pinned; should work; hardware-unverified** | ✓ | ✓ (calibrated) | | ✓ (9×9 corner) | | | |
| Tabutronic Sentio | **Protocol-pinned; should work; hardware-unverified** | ✓ | | ✓ | ✓ | | | |
| ChessUp (gen-1) | **Protocol-pinned; should work; hardware-unverified** | ✓ | | ✓ | ✓ | | | |
| ChessUp 2 | **EXPLICITLY UNVERIFIED — do not ship** | ? | ? | ? | ? | | | |

### Per-board status notes

- **Square Off Pro / Kingdom Set (GKS):** Field-proven in the Fianchetto iOS
  and Android production apps. All BLE codec paths (fieldUpdate, boardState,
  setLeds, handshake/reconnect) are hardware-verified. The `executeMove` motor
  command is quarantined pending confirmed wire semantics.

- **Chessnut Air family (Air, Air+, Pro, Go):** Protocol-verified against the
  official Chessnut docs, NSStudent/EasyLinkSwiftSDK (MIT), and
  chessnutech/EasyLinkSDK (MIT). All golden-frame fixtures from the pinned spec
  pass. Awaiting physical-board or BLE capture-log runtime validation.

- **Chessnut Move:** Protocol-pinned against chessnutech/chess_move_api
  (official, no license — protocol facts re-derived independently), with
  cross-check against NSStudent/EasyLinkSwiftSDK (MIT). Motorised auto-move
  and per-piece identity beyond the Air family. Should work — codec is complete
  and all golden-frame fixtures pass; awaiting physical-board or BLE
  capture-log validation to confirm.

- **DGT Pegasus:** Protocol-pinned against mono424/dgtdriver (MIT, Dart) as
  the primary reference, with protocol facts from DGTCentaurMods/pegasus.py
  (GPL — facts only, no code structure), Graham O'Neill Pegasus ReadMe PDF
  (public), and DGT Projects dgtbrd13.h (restricted doc — facts only).
  The devkey bundled is the White Pawn / dgtdriver default — integrators should
  obtain their own from DGT for production. Should work — codec complete and
  frame fixtures pass; awaiting physical-board or BLE capture-log validation.

- **Millennium:** Protocol-pinned against domschl/python-mchess (MIT, primary
  reference: magic-board.md + chess_link*.py), alstrup/chesslink (MIT,
  independent WebBluetooth implementation), and Graham O'Neill Millennium
  driver readme (facts only, proprietary). Full codec implemented: frame
  encoding/decoding (MF1–MF7 golden fixtures), full-position orientation
  detection, 9×9 LED corner-grid mapping, E2ROM read/write, and delta event
  generation. Should work — all golden fixtures pass; awaiting physical-board
  or capture-log validation.

- **Certabo (classic LED and Spectrum RGB) / Tabutronic Sentio:** Protocol
  pinned against mono424/certabodriver (MIT); LED + occupancy vectors fully
  confirmed and RFID wrapped-frame parsing verified against gkalab/cer2nut
  golden-fixture vectors. Should work — codec complete with all test vectors
  green; awaiting physical-board or USB/BT capture-log validation.

- **ChessUp (gen-1):** Protocol-pinned against mono424/chessupdriver (MIT,
  commit 589d43ad). NUS GATT transport, per-square RGB LEDs, occupancy
  sensing. Should work — codec complete and fixtures pass; awaiting
  physical-board or BLE capture-log validation.

- **ChessUp 2:** EXPLICITLY UNVERIFIED — do not ship to CU2 users. Only
  circumstantial evidence (Bryght Labs engineer tool chessup-pc, Apr-2026)
  suggests CU2 keeps the NUS transport, device name prefix "ChessUp", and
  opcode 0xB2 board-info. All other CU2 frame semantics are UNKNOWN.
  Runtime-probe: send GET_STATE (0x67); if a 73-byte 0x67 reply arrives, CU1
  profile is live. Surface the 0xB2 model string in telemetry for CU2
  divergence diagnosis. ChessUp 2 support is flagged experimental/unsupported
  until a capture log is contributed and hardware-verified.

## Source attributions by adapter

| Adapter | MIT sources (code-ok) | Facts-only sources (GPL/proprietary) |
|---|---|---|
| SquareOffAdapter | First-party reverse engineering — no external driver | — |
| ChessnutAdapter | NSStudent/EasyLinkSwiftSDK (MIT); chessnutech/EasyLinkSDK (MIT) | chessnutech/Chessnut_eBoards README |
| ChessnutMoveAdapter | NSStudent/EasyLinkSwiftSDK (MIT, cross-check) | chessnutech/chess_move_api (no license — facts only, re-derived) |
| PegasusAdapter | mono424/dgtdriver (MIT, Dart) | DGTCentaurMods/pegasus.py (GPL); Graham O'Neill ReadMe PDF; DGT Projects dgtbrd13.h |
| MillenniumAdapter | domschl/python-mchess (MIT); alstrup/chesslink (MIT) | Graham O'Neill readme (proprietary — facts only) |
| CertaboAdapter | mono424/certabodriver (MIT) | CERTABO/CERTABO-CHESSBOARDS-SOFTWARE (GPL); haklein/certabo-lichess (GPL); gkalab/cer2nut (GPL — test vectors as facts) |
| ChessUpAdapter | mono424/chessupdriver (MIT, commit 589d43ad) | atomice1/bluecheese (GPL/LGPL); Kevin-BryghtLabs/chessup-pc (all rights reserved) |

## Validating a board: the capture-log contribution flow

If you own a physical board and want to move a board from
"protocol-pinned; hardware-unverified" to "hardware-verified", submit a
capture log in the `.replay` format accepted by `ReplayTransport`.

### Capture on macOS (BLE boards)

```sh
# Requires the Apple PacketLogger from the Additional Tools for Xcode DMG
# (developer.apple.com/download/all/?q=Additional+Tools+for+Xcode).
# 1. Open PacketLogger, start capture.
# 2. Connect the board and make several moves.
# 3. File > Export > HCI Log.
# 4. Convert ATT notification payloads to .replay format with tshark:
tshark -r capture.pcapng \
  -Y 'btatt.opcode == 0x1b' \
  -T fields -e btatt.value \
  | sed 's/../& /g;s/ $//' \
  | sed 's/^/rx /'
# Paste the output (rx lines) into a new Tests/Fixtures/<board>.replay file.
```

### .replay file format

One directive per line. Leading/trailing whitespace and `#`-comment lines
are ignored.

| Line form            | Meaning |
|----------------------|---------|
| `rx <HEX>`           | Raw bytes received from board (space-separated hex octets) |
| `delay <MS>`         | Millisecond pause (recorded; not enforced during runSync) |
| `event connected`    | Inject `.connected` lifecycle event |
| `event disconnected` | Inject `.disconnected(error: nil)` lifecycle event |

Example fixture (`Tests/Fixtures/pegasus-initial.replay`):

```
# DGT Pegasus — first board dump (initial position, White to move)
event connected
rx 86 00 43 01 01 01 01 01 01 01 01 00 00 00 00 00 00 00 00 ...
```

### Submitting a fixture

1. Capture a log covering: initial connection, several moves, battery
   request (where available).
2. Convert to `.replay` format and save under `Tests/Fixtures/`.
3. Add a test case in the matching `*AdapterTests.swift` that loads the
   fixture via `ReplayScript.parse(text:)` and asserts the resulting events.
4. Open a PR. The test gate (`swift test`) must pass before merge.

## Quick start

```swift
// 1. Add to Package.swift
.package(path: "../BoardKit"),

// 2. Depend on the products you need
.target(name: "MyApp", dependencies: [
    .product(name: "BoardKit",       package: "BoardKit"),
    .product(name: "ChessnutAdapter", package: "BoardKit"),
])

// 3. Create an adapter and replay a capture log in tests
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport

var adapter = ChessnutAdapter()
let replay = ReplayTransport(adapter: adapter, script: [
    .bytes(capturedBLEFrame),
])
let events = replay.runSync()
// events: [.identitySnapshot([Piece?]), .ready]

// 4. Or parse a .replay fixture file
let scriptText = try String(contentsOf: fixtureURL, encoding: .utf8)
let steps = try ReplayScript.parse(text: scriptText)
let replay2 = ReplayTransport(adapter: ChessnutAdapter(), parsedScript: steps)
let events2 = replay2.runSync()
```

## License hygiene (adapter authors)

MIT sources (mono424 drivers, python-mchess, NSStudent/EasyLinkSwiftSDK,
official EasyLinkSDK) may inform code with source-attribution comments.
GPL/AGPL sources and license-less repos are **facts only** — protocol
constants and frame layouts may be learned, but no code structure may be
copied. See per-adapter file headers for specific source tags.
