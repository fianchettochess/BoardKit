# BoardKit

[![Swift Package Index — Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FBoardKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/fianchettochess/BoardKit)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FBoardKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/fianchettochess/BoardKit)
[![Release](https://img.shields.io/github/v/release/fianchettochess/BoardKit?sort=semver&label=release&color=blue)](https://github.com/fianchettochess/BoardKit/releases)
[![CI](https://github.com/fianchettochess/BoardKit/actions/workflows/ci.yml/badge.svg)](https://github.com/fianchettochess/BoardKit/actions/workflows/ci.yml)
[![Linux CI](https://github.com/fianchettochess/BoardKit/actions/workflows/ci-linux.yml/badge.svg)](https://github.com/fianchettochess/BoardKit/actions/workflows/ci-linux.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

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
| Chessnut Go | **Protocol-verified; onboard stored-game import exercised against real hardware (2026-07)** | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| Chessnut Move | **Protocol-pinned; should work; hardware-unverified** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| DGT Pegasus | **Protocol-pinned; should work; hardware-unverified** | ✓ | | ✓ | ✓ | | ✓ | |
| Millennium (BLE/USB) | **Protocol-pinned; exercised on a physical board (a live move-decode issue was found + fixed)** | ✓ | ✓ | | ✓ (9×9 corner) | | | |
| Certabo (classic LED) | **Protocol-pinned; should work; hardware-unverified** | ✓ | ✓ (calibrated) | ✓ | ✓ | | | |
| Certabo Spectrum RGB | **Protocol-pinned; should work; hardware-unverified** | ✓ | ✓ (calibrated) | | ✓ (9×9 corner) | | | |
| Tabutronic Sentio | **Protocol-pinned; should work; hardware-unverified** | ✓ | | ✓ | ✓ | | | |
| ChessUp (gen-1) | **Protocol-pinned; transport + frame formats corroborated on ChessUp 2 hardware; gen-1 unit untested** | ✓ | | | ✓ | | | |
| ChessUp 2 | **Hardware-verified (full 90-ply game, Android + iOS) 2026-07** | ✓ | | | pinned | | svc ✓ (pct readable; adapter: charging flag only) | |

> **Recent hardware validation (2026-07).** The status column reflects what has
> actually been run against physical hardware, and is deliberately honest about
> what has not:
> - **Field-tested on physical boards we own:** Square Off Pro / Kingdom Set
>   (production), ChessUp 2 (a full 90-ply live game decoded 0/90 on both Android
>   and iOS — see the ChessUp 2 note), Chessnut Go (onboard stored-game import),
>   and Millennium (a real move-decode misread was found and fixed).
> - **Protocol-verified against reference implementations only — no physical
>   board tested yet, so treat with more caution:** Certabo (classic + Spectrum),
>   Tabutronic Sentio, DGT Pegasus, Chessnut Move, and ChessUp gen-1. These are
>   codec-complete with all golden fixtures passing and *should* work, but the
>   wire behaviour has not been confirmed on the hardware itself. A capture-log
>   contribution (see below) is the fastest way to promote one of these.

### Per-board status notes

- **Square Off Pro / Kingdom Set (GKS):** Field-proven in the Fianchetto iOS
  and Android production apps. All BLE codec paths (fieldUpdate, boardState,
  setLeds, handshake/reconnect) are hardware-verified. The `executeMove` motor
  command is quarantined pending confirmed wire semantics.

- **Chessnut Air family (Air, Air+, Pro, Go):** Protocol-verified against the
  official Chessnut docs, NSStudent/EasyLinkSwiftSDK (MIT), and
  chessnutech/EasyLinkSDK (MIT). All golden-frame fixtures from the pinned spec
  pass. The **Chessnut Go** onboard stored-game import path was exercised against
  real hardware (2026-07, reconstructing completed games from the board's
  snapshot log); broader live-play field validation across the family is ongoing.

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
  generation. All golden fixtures pass, and the adapter has been exercised on a
  physical Millennium board — a real live move-decode misread was reproduced and
  fixed there — though systematic field validation across firmware variants is
  still ongoing.

- **Certabo (classic LED and Spectrum RGB) / Tabutronic Sentio:** Protocol
  pinned against mono424/certabodriver (MIT); LED + occupancy vectors fully
  confirmed and RFID wrapped-frame parsing verified against gkalab/cer2nut
  golden-fixture vectors. Should work — codec complete with all test vectors
  green; awaiting physical-board or USB/BT capture-log validation.

- **ChessUp (gen-1):** Protocol-pinned against mono424/chessupdriver (MIT,
  commit 589d43ad). NUS GATT transport, per-square RGB LEDs, occupancy
  sensing. Codec complete and all golden-frame fixtures pass. Transport layer
  and frame formats (0x67/0xB1/0xB8/0xBB/0xA3) corroborated by a ChessUp 2
  hardware session (2026-07-07) — CU2 and gen-1 share an identical NUS GATT
  profile, and every opcode exercised so far matches the gen-1 pins. Gen-1
  unit itself remains untested.

- **ChessUp 2:** Hardware-verified (game-collection path) 2026-07-07 on a
  physical ChessUp 2 (Bryght Labs, LightBlue BLE session). NUS transport
  confirmed identical to gen-1 constants — same service UUID
  (6E400001-B5A3-F393-E0A9-E50E24DCCA9E), same characteristic UUIDs, same
  device-name prefix "ChessUp". Verified on hardware: 0x67 GET_STATE returns
  the 73-byte board-state frame (RNBQKBNR home rank, 0x40 = empty); 0xB8
  capacitive-touch + 0xBB release; 0xB1 new-game/set-state; 0xA3 move frames
  (1.d4 arrived as A3 35 03 01 03 03; sub byte 0x35 semantics undecoded).
  Battery service 0x180F present and readable (e.g. 96%); adapter currently
  surfaces the 0x33 charging flag only.

  **Key protocol discovery:** 0xA3 move reporting is GATED behind a phoneOTB
  session. Standalone board games (builtInAI mode 6 / noPhoneOTB mode 7) never
  stream moves to a connected host. `.startSession` writes the 0xB9 mode-5
  (phoneOTB) frame to unlock move reporting; hardware-verified. This is what
  `ChessUpAdapter.collectionSessionData()` / `.startSession` encodes.

  **Ack discipline (hardware-observed):** The board retransmits each 0xA3 until
  the host writes a 0x21 ack. A passive listener that never acked saw the same
  frame approximately five times and the unacked flood destabilised the BLE link
  until it dropped (while the board's own game stayed live). 0x97 board-side
  promotions require a 0x23 ack. The adapter queues these internally;
  transports drain them via `takePendingResponses()` — no raw-frame inspection
  needed in the transport layer.

  **Full-game validation (2026-07):** a complete 90-ply over-the-board game was
  harvested from physical hardware — an Android live BLE HCI sniff (btsnoop) and
  an iOS PacketLogger session — and decoded **0/90** against the board app's own
  PGN export. This RESOLVED the previously-pending 0xA3 frame shapes: castling is
  a single king-slide 0xA3 (no separate rook frame), promotion is a plain
  pawn-move 0xA3 immediately followed by a 0x97 board-side pick, capture is a
  plain from→to 0xA3, and the 0x35 sub byte is **constant** across every move
  kind (not a discriminator). The iOS transport uses the identical NUS GATT
  profile on plain ATT (fixed CID 0x0004; no EATT). **No downloadable onboard
  game archive exists on either platform** — the board streams completed moves
  live (0xA3); it exposes no flash-stored-game pull (unlike the Chessnut Go).
  Locked by the `G1` golden regression in `ChessUpAdapterTests`.

  **Still pending:** 0x99 move-indication LEDs untested on CU2; 0xFD occupancy
  stream (0x50 enable) untested on CU2; 0x66 FEN-load untested on CU2; Android
  Kotlin manager (Swift side compiled; ChessUpBleManager.kt not yet written).

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

## License

MIT — see [LICENSE](LICENSE). Rules for what adapter authors may learn from
third-party sources are in [License hygiene](#license-hygiene-adapter-authors)
above.
