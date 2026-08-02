# BoardKit

[![Swift Package Index — Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FBoardKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/fianchettochess/BoardKit)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FBoardKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/fianchettochess/BoardKit)
[![Release](https://img.shields.io/github/v/release/fianchettochess/BoardKit?sort=semver&label=release&color=blue)](https://github.com/fianchettochess/BoardKit/releases)
[![CI](https://github.com/fianchettochess/BoardKit/actions/workflows/ci.yml/badge.svg)](https://github.com/fianchettochess/BoardKit/actions/workflows/ci.yml)
[![Linux CI](https://github.com/fianchettochess/BoardKit/actions/workflows/ci-linux.yml/badge.svg)](https://github.com/fianchettochess/BoardKit/actions/workflows/ci-linux.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Swift package that defines the adapter seam between physical chess boards
(BLE and USB-HID) and a chess engine or kernel stack, and ships the
board-agnostic kernels built on top of that seam.

## Scope

**BoardKit** is the seam and kernel layer. It defines the shared
vocabulary (`BoardEvent`, `BoardCommand`, `BoardCapabilities`, `BoardAdapter`,
`BoardTransport`) and ships the board-agnostic kernels built on it (move
inference, execution gate, diff resolver, correction planner, takeback
detector, sync gate, reconnect policy), so a session shell is written once
against those kernels and then works with any physical board.

**No library target contains BLE or USB-HID code.** Transport implementations
live in the consuming app targets (they import CoreBluetooth or SkipFuse);
BoardKit's library targets depend only on
[ChessCore](https://github.com/fianchettochess/ChessCore) (MIT) and system
frameworks. They use Foundation throughout and conditionally use Apple's `os`
module for Square Off logging; none contains UI, Bluetooth, or networking
code. The `boardkit-emulator` executable is the only CoreBluetooth exception,
and its peripheral code is guarded by
`#if os(macOS) && canImport(CoreBluetooth)` and never enters the library
graph.

## Products

| Product | Contents |
|---|---|
| `BoardKit` | Core seam protocols, types, and board-agnostic kernels |
| `SquareOffAdapter` | Square Off wire codec and `BoardAdapter` |
| `ChessnutAdapter` | Chessnut Air-family and Chessnut Move BLE adapters, including the stored-game import decoder |
| `PegasusAdapter` | DGT Pegasus BLE adapter |
| `MillenniumAdapter` | Millennium BLE and USB-HID adapter |
| `CertaboAdapter` | Certabo RFID adapter (USB serial, BT Classic, BLE) |
| `ChessUpAdapter` | ChessUp BLE adapter |
| `BoardKitTestSupport` | `ReplayTransport` and `SimulatedBoard` test harness |
| `boardkit-emulator` | macOS CLI BLE peripheral that emulates a supported board (Square Off, Chessnut, Pegasus, Millennium, Certabo, ChessUp) so the apps on a real phone can connect to it as if it were hardware |

## Installation

Add BoardKit to your package dependencies:

```swift
.package(url: "https://github.com/fianchettochess/BoardKit.git", exact: "0.6.0")
```

Then depend on the products you need:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "BoardKit",        package: "BoardKit"),
    .product(name: "ChessnutAdapter", package: "BoardKit"),
])
```

## Compatibility and implemented capabilities

A checkmark means the adapter implements and declares the corresponding
`BoardCapabilities` flag. It does not mean that every listed capability has
been exercised on physical hardware. A blank means the flag is not declared.
The `motorised` spelling is retained because it is an exact API identifier.

### Hardware-tested: works within the verified scope

These adapters have at least one hardware-tested path. The verified scope and
known limitations are explicit because other implemented capabilities may
remain untested.

| Board | Hardware-verified scope | Known limitations | `.occupancySensing` | `.pieceIdentity` | `.perSquareLEDs` | `.moveIndication` | `.motorised` | `.batteryReporting` | `.perPieceTracking` | `.gameArchive` |
|---|---|---|---|---|---|---|---|---|---|---|
| Square Off Pro / Kingdom Set (GKS) | Production use on iOS and Android covers connection, handshake and reconnect, field updates, board state, and LEDs. | The `executeMove` motor command remains quarantined; `.motorised` is not declared. | ✓ | | ✓ | ✓ | | | | |
| Chessnut Go | Onboard stored-game import reconstructed completed games from a physical board in July 2026. | Only the archive/import path is hardware-tested; broader live play and the remaining capabilities are not. | ✓ | ✓ | ✓ | ✓ | | ✓ | | ✓ |
| Millennium (BLE/USB) | Live move decoding was exercised on a physical board, exposing a misread that was reproduced and fixed. | Validation covers one board and firmware path; broader firmware variants and the full command surface remain untested. | ✓ | ✓ | | ✓ | | | | |
| ChessUp 2 | A complete 90-ply live game decoded 90/90 with zero mismatches on Android and iOS; phoneOTB session setup and acknowledgments were also verified. | The `0x99` move-indication command, `0xFD` occupancy stream, and `0x66` FEN load remain untested. Battery percentage is readable from the standard service, but the adapter does not declare `.batteryReporting`. | ✓ | | | ✓ | | | | |

### Should work but untested on target hardware

These adapters are protocol-complete and pass their checked-in frame and codec
fixtures, but they have not been exercised on the named target hardware.

| Board | Verification basis | Known limitations | `.occupancySensing` | `.pieceIdentity` | `.perSquareLEDs` | `.moveIndication` | `.motorised` | `.batteryReporting` | `.perPieceTracking` | `.gameArchive` |
|---|---|---|---|---|---|---|---|---|---|---|
| Chessnut Air | Official documentation and pinned MIT implementations; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | | ✓ | | ✓ |
| Chessnut Air+ | Official documentation and pinned MIT implementations; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | | ✓ | | ✓ |
| Chessnut Pro | Official documentation and pinned MIT implementations; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | | ✓ | | ✓ |
| Chessnut Move | Official protocol documentation with a pinned MIT cross-check; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| DGT Pegasus | Pinned public implementations and protocol references; all frame fixtures pass. | No physical-board or BLE capture-log validation. The developer-key authorization context is documented below. | ✓ | | ✓ | ✓ | | ✓ | | |
| Certabo (classic LED) | A pinned MIT implementation and locally constructed protocol regressions. | No physical-board or USB/Bluetooth capture-log validation; identity requires calibration. | ✓ | ✓ after calibration | ✓ | ✓ | | | | |
| Certabo Spectrum RGB | A pinned MIT implementation and locally constructed protocol regressions. | No physical-board or USB/Bluetooth capture-log validation; identity requires calibration, and the 9×9 corner grid does not provide per-square LEDs. | ✓ | ✓ after calibration | | ✓ | | | | |
| Tabutronic Sentio | A pinned MIT implementation and locally constructed protocol regressions. | No physical-board or USB/Bluetooth capture-log validation. | ✓ | | ✓ | ✓ | | | | |
| ChessUp (gen-1) | Pinned protocol references; its shared GATT transport and exercised frame formats were corroborated indirectly on ChessUp 2. | No ChessUp gen-1 unit has been tested. | ✓ | | | ✓ | | | | |

A capture-log contribution is the fastest way to expand a verified scope or
move an adapter into the hardware-tested group; see the contribution flow below.

### Per-board status notes

- **Square Off Pro / Kingdom Set (GKS):** Field-proven in shipping iOS and
  Android clients. The connection, field-update, board-state, LED,
  handshake, and reconnect paths are hardware-verified. The `executeMove`
  motor command is quarantined pending confirmed wire semantics.

- **Chessnut Air family (Air, Air+, Pro, Go):** Protocol-verified against the
  official Chessnut docs, NSStudent/EasyLinkSwiftSDK (MIT, `1b971059`), and
  chessnutech/EasyLinkSDK (MIT, `4554d17b`). All golden-frame fixtures from the
  pinned specifications pass. The **Chessnut Go** onboard stored-game import
  path was exercised against real hardware in July 2026, reconstructing
  completed games from the board's snapshot log. Broader live-play validation
  across the family is ongoing.

- **Chessnut Move:** Protocol-complete based on chessnutech/chess_move_api
  (official, no license — protocol facts re-derived independently), with
  a cross-check against NSStudent/EasyLinkSwiftSDK (MIT). It implements
  motorized auto-move and per-piece identity beyond the Air family. The codec
  is complete and all golden-frame fixtures pass, but physical-board or BLE
  capture-log validation is still pending.

- **DGT Pegasus:** Protocol-complete based on
  [mono424/dgtdriver at `333b1d6b`](https://github.com/mono424/dgtdriver/blob/333b1d6b151368168a395c43364cc27798920bfc/lib/DGTBoard.dart)
  (MIT, Dart) as the primary reference, with behavior cross-checks from
  DGTCentaurMods/pegasus.py (GPL), Graham O'Neill's Pegasus ReadMe PDF, and the
  restricted DGT protocol header. At least two public community implementations
  publish the same default developer-key frame: dgtdriver above and
  [PegasusChessComChromeExtension at `5fe10bdc`](https://github.com/EdNekebno/PegasusChessComChromeExtension/blob/5fe10bdcf00827886d1ad8702278abe65680a2ee/content_script.js)
  at the pinned revisions. That public duplication does not establish official
  DGT authorization for general reuse. Deployments requiring authorization
  should confirm their requirements with DGT and inject an appropriate value
  via `PegasusAdapter(devkey:)`.
  The codec and frame fixtures pass, but physical-board or BLE capture-log
  validation is still pending.

- **Millennium:** Protocol-complete based on domschl/python-mchess (MIT, primary
  reference: magic-board.md and chess_link*.py), alstrup/chesslink (MIT,
  independent WebBluetooth implementation), and Graham O'Neill Millennium
  driver readme (facts only, proprietary). The codec covers frame encoding and
  decoding (MF1–MF7 golden fixtures), full-position orientation detection, 9×9
  LED corner-grid mapping, E2ROM read/write, and delta event generation. All
  golden fixtures pass. A live move-decode misread was reproduced and fixed on
  a physical Millennium board, but systematic validation across firmware
  variants is still pending.

- **Certabo (classic LED and Spectrum RGB) / Tabutronic Sentio:** Protocol
  pinned against mono424/certabodriver (MIT, `d61997c6`); LED and occupancy
  behavior cross-checked and RFID wrapped-frame parsing exercised with locally
  constructed regressions based on gkalab/cer2nut behavior. The codec is
  complete and all test vectors pass, but physical-board or USB/Bluetooth
  capture-log validation is still pending.

- **ChessUp (gen-1):** Protocol-complete based on mono424/chessupdriver (MIT,
  commit 589d43ad). It covers NUS GATT transport, per-square RGB LEDs, and
  occupancy sensing. The codec is complete and all golden-frame fixtures pass.
  The transport layer and frame formats (0x67/0xB1/0xB8/0xBB/0xA3) were
  corroborated by a ChessUp 2
  hardware session (2026-07-07) — CU2 and gen-1 share an identical NUS GATT
  profile, and every opcode exercised so far matches the pinned gen-1 protocol
  references. The gen-1
  unit itself remains untested.

- **ChessUp 2:** Hardware-verified on July 7, 2026, with a physical ChessUp 2
  (Bryght Labs, LightBlue BLE session). NUS transport was
  confirmed identical to gen-1 constants — same service UUID
  (6E400001-B5A3-F393-E0A9-E50E24DCCA9E), same characteristic UUIDs, same
  device-name prefix "ChessUp". Verified on hardware: 0x67 GET_STATE returns
  the 73-byte board-state frame (RNBQKBNR home rank, 0x40 = empty); 0xB8
  capacitive-touch and 0xBB release; 0xB1 new-game/set-state; 0xA3 move frames
  (1.d4 arrived as A3 35 03 01 03 03; sub byte 0x35 semantics undecoded).
  Battery service 0x180F present and readable (for example, 96%); the adapter currently
  surfaces the 0x33 charging flag only.

  **Key protocol discovery:** 0xA3 move reporting is gated behind a phoneOTB
  session. Standalone board games (builtInAI mode 6 / noPhoneOTB mode 7) never
  stream moves to a connected host. `.startSession` writes the 0xB9 mode-5
  (phoneOTB) frame to unlock move reporting; hardware-verified. This is what
  `ChessUpAdapter.collectionSessionData()` / `.startSession` encodes.

  **Acknowledgment behavior (hardware-observed):** The board retransmits each
  0xA3 until the host writes a 0x21 acknowledgment. A passive listener that
  never acknowledged a frame saw the same frame approximately five times; the
  resulting flood destabilized the BLE link
  until it dropped (while the board's own game stayed live). 0x97 board-side
  promotions require a 0x23 ack. The adapter queues these internally;
  transports drain them via `takePendingResponses()` — no raw-frame inspection
  needed in the transport layer.

  **Full-game validation (July 2026):** A complete 90-ply over-the-board game was
  harvested from physical hardware — an Android live BLE HCI sniff (btsnoop) and
  an iOS PacketLogger session — and decoded **90/90 moves with zero mismatches**
  against the board app's own PGN export. This resolved the previously pending
  0xA3 frame shapes: castling is
  a single king-slide 0xA3 (no separate rook frame), promotion is a plain
  pawn-move 0xA3 immediately followed by a 0x97 board-side pick, capture is a
  plain from→to 0xA3, and the 0x35 sub byte is **constant** across every move
  kind (not a discriminator). The iOS transport uses the identical NUS GATT
  profile on plain ATT (fixed CID 0x0004; no EATT). **No downloadable onboard
  game archive exists on either platform** — the board streams completed moves
  live (0xA3); it exposes no flash-stored-game pull (unlike the Chessnut Go).
  Locked by the `G1` golden regression in `ChessUpAdapterTests`.

  **Remaining hardware checks:** 0x99 move-indication LEDs on CU2; the 0xFD
  occupancy stream (0x50 enable) on CU2; and 0x66 FEN loading on CU2.

## Source attributions by adapter

| Adapter | MIT implementation sources | Protocol/behavior references (other terms) |
|---|---|---|
| SquareOffAdapter | First-party reverse engineering — no external driver | — |
| ChessnutAdapter | NSStudent/EasyLinkSwiftSDK (MIT, `1b971059`); chessnutech/EasyLinkSDK (MIT, `4554d17b`) | chessnutech/Chessnut_eBoards README |
| ChessnutMoveAdapter | NSStudent/EasyLinkSwiftSDK (MIT, `1b971059`, cross-check) | chessnutech/chess_move_api (no license — facts only, re-derived) |
| PegasusAdapter | mono424/dgtdriver (MIT, Dart, `333b1d6b`) | EdNekebno/PegasusChessComChromeExtension (GPL-3.0, `5fe10bdc`); DGTCentaurMods/pegasus.py (GPL); Graham O'Neill ReadMe PDF; DGT Projects dgtbrd13.h |
| MillenniumAdapter | domschl/python-mchess (MIT, `74ccfd40`); alstrup/chesslink (MIT, `13b64273`) | Graham O'Neill readme (proprietary — facts only) |
| CertaboAdapter | mono424/certabodriver (MIT, `d61997c6`) | Protocol/behavior references: CERTABO software (GPL), CERTABO/BT (no declared license), haklein/certabo-lichess (GPL), gkalab/cer2nut (GPL) |
| ChessUpAdapter | mono424/chessupdriver (MIT, commit 589d43ad) | atomice1/bluecheese (GPL/LGPL); Kevin-BryghtLabs/chessup-pc (all rights reserved) |

## Hardware validation with capture logs

If you own a physical board and want to move an adapter from “should work but
untested on target hardware” into the hardware-tested group, submit a capture
log in the `.replay` format accepted by `ReplayTransport`.

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
# Paste the output (rx lines) into a new .replay file (see "Submitting a
# fixture" below for where to put it).
```

### Replay file format

One directive per line. Leading/trailing whitespace and `#`-comment lines
are ignored.

| Line form            | Meaning |
|----------------------|---------|
| `rx <HEX>`           | Raw bytes received from board (space-separated hex octets) |
| `delay <MS>`         | Millisecond pause (recorded; not enforced during runSync) |
| `event connected`    | Inject `.connected` lifecycle event |
| `event disconnected` | Inject `.disconnected(error: nil)` lifecycle event |

Example fixture (format illustration; `Captures/` holds generated sessions —
`boardkit-emulator` output at a fixed seed, not hardware traces):

```text
# DGT Pegasus — first board dump (initial position, White to move)
event connected
rx 86 00 43 01 01 01 01 01 01 01 01 00 00 00 00 00 00 00 00 ...
```

### Submitting a fixture

1. Capture a log covering: initial connection, several moves, battery
   request (where available).
2. Redact device addresses and UUIDs, serial numbers, names, pairing material,
   local paths, account data, and unrelated traffic. Do not commit a raw
   PacketLogger, btsnoop, pcap, phone, or application log; see
   [CONTRIBUTING.md](CONTRIBUTING.md#capture-logs-and-privacy).
3. Convert the minimal protocol bytes to `.replay` format and save under `Tests/Fixtures/`.
   `Tests/Fixtures/` does not exist yet — create it with your first fixture
   and load it in the test via a `#filePath`-relative path (the test target
   declares no SwiftPM resources), or follow the existing `Captures/`
   convention.
4. Add a test case in the matching `*AdapterTests.swift` that loads the
   fixture via `ReplayScript.parse(text:)` and asserts the resulting events.
5. Open a PR. The test gate (`swift test`) must pass before merge.

## Quick start

```swift
// 1. Create an adapter and replay a capture log in tests
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport

var adapter = ChessnutAdapter()
let replay = ReplayTransport(adapter: adapter, script: [
    .bytes(capturedBLEFrame),
])
let events = replay.runSync()
// events: [.identitySnapshot([Piece?]), .ready]

// 2. Or parse a .replay fixture file
let scriptText = try String(contentsOf: fixtureURL, encoding: .utf8)
let steps = try ReplayScript.parse(text: scriptText)
let replay2 = ReplayTransport(adapter: ChessnutAdapter(), parsedScript: steps)
let events2 = replay2.runSync()
```

## Building and testing

```bash
swift build
swift test
```

On-push Linux CI runs both the declared Swift 6.0 floor and the latest Swift
image through the same versioned ChessCore dependency path used by consumers.

The manifest declares one ordinary versioned ChessCore dependency and knows
nothing about how your checkout is arranged. To develop against a local
ChessCore alongside BoardKit, use `swift package edit ChessCore` or a
root-level `.package(path:)` override — the published manifest stays
deterministic either way.

## Releasing

BoardKit follows semantic versioning. From a clean, tested `main`, create and
push a new annotated `N.N.N` tag. The release workflow builds and tests that
exact tag against its exact ChessCore pin before publishing the corresponding
GitHub Release. Published tags are never moved or re-cut.

## License hygiene for adapter authors

MIT sources (mono424 drivers, python-mchess, NSStudent/EasyLinkSwiftSDK,
official EasyLinkSDK) may inform code with source-attribution comments.
GPL/AGPL and license-less sources may be consulted for protocol research;
contributors must not submit third-party source files or fixture blobs unless
their distribution terms are compatible and their notices are preserved. See
per-adapter file headers for specific source tags.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for testing, capture-log privacy, and
source-provenance requirements. Report security issues using the private process
in [SECURITY.md](SECURITY.md), not a public issue containing sensitive details.

## License

BoardKit is available under the MIT license. See [LICENSE](LICENSE). Rules for
what adapter authors may learn from third-party sources are in
[License hygiene](#license-hygiene-for-adapter-authors).
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency and source
attributions, and [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidance.

BoardKit is independent and is not affiliated with or endorsed by the board
manufacturers named above. Product names and trademarks belong to their
respective owners and are used only to identify compatibility.
