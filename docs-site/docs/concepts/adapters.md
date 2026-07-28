# Concrete adapters

Each concrete adapter is a `struct` conforming to `BoardAdapter`. It owns
wire framing, protocol parsing, command encoding, handshake sequencing, and
orientation flip for one board family. Adapters depend only on `BoardKit`,
`ChessCore`, and system frameworks; Square Off conditionally uses Apple's `os`
module for logging. No adapter contains Bluetooth or networking code.

## Hardware status

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

These adapters implement the documented paths and pass their checked-in frame
and codec fixtures, but they have not been exercised on the named target
hardware.

| Board | Verification basis | Known limitations | `.occupancySensing` | `.pieceIdentity` | `.perSquareLEDs` | `.moveIndication` | `.motorised` | `.batteryReporting` | `.perPieceTracking` | `.gameArchive` |
|---|---|---|---|---|---|---|---|---|---|---|
| Chessnut Air | Official documentation and pinned MIT implementations; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | | ✓ | | ✓ |
| Chessnut Air+ | Official documentation and pinned MIT implementations; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | | ✓ | | ✓ |
| Chessnut Pro | Official documentation and pinned MIT implementations; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | | ✓ | | ✓ |
| Chessnut Move | Official protocol documentation with a pinned MIT cross-check; all golden-frame fixtures pass. | No physical-board or BLE capture-log validation. | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| DGT Pegasus | Pinned public implementations and protocol references; all frame fixtures pass. | No physical-board or BLE capture-log validation. The developer-key authorization context is documented in the adapter notes. | ✓ | | ✓ | ✓ | | ✓ | | |
| Certabo (classic LED) | A pinned MIT implementation and locally constructed protocol regressions. | No physical-board or USB/Bluetooth capture-log validation; identity requires calibration. | ✓ | ✓ after calibration | ✓ | ✓ | | | | |
| Certabo Spectrum RGB | A pinned MIT implementation and locally constructed protocol regressions. | No physical-board or USB/Bluetooth capture-log validation; identity requires calibration, and the 9×9 corner grid does not provide per-square LEDs. | ✓ | ✓ after calibration | | ✓ | | | | |
| Tabutronic Sentio | A pinned MIT implementation and locally constructed protocol regressions. | No physical-board or USB/Bluetooth capture-log validation. | ✓ | | ✓ | ✓ | | | | |
| ChessUp (gen-1) | Pinned protocol references; its shared GATT transport and exercised frame formats were corroborated indirectly on ChessUp 2. | No ChessUp gen-1 unit has been tested. | ✓ | | | ✓ | | | | |

!!! success "ChessUp 2 — hardware-verified (full 90-ply game, Android + iOS, 2026-07)"
    CU2 BLE transport is **identical to gen-1**: NUS service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E,
    write char 6E400002, notify char 6E400003, Battery 0x180F. No adapter changes required at
    the transport layer.

    **Verified on physical CU2 hardware:** 0x67 GET_STATE (73-byte board-state frame,
    home rank correct, 0x40 = empty); 0xB8/0xBB capacitive touch/release; 0xB1
    new-game/set-state; 0xA3 move frames (`[A3, sub, fromCol, fromRow, toCol, toRow]`).
    pieceCode in 0xB8 is type-only and color-agnostic (e.g., pawn = 0x00 for both sides).
    A complete 90-ply over-the-board game (Android btsnoop + iOS PacketLogger) decoded
    **90/90 moves with zero mismatches** against the board app's own PGN export,
    resolving the 0xA3 frame shapes:
    castling is a single king-slide 0xA3, promotion is a plain pawn 0xA3 followed by a
    0x97 board-side pick, capture is a plain from→to 0xA3, and the 0x35 sub byte is
    constant across every move kind (not a discriminator). Locked by the `G1` golden
    regression in `ChessUpAdapterTests`.

    **Key protocol discovery — phoneOTB session required:** 0xA3 move reporting is gated
    behind a 0xB9 game-settings frame with mode 5 (phoneOTB, both sides human, no remote
    — bytes `B9 05 00 01 00 00 01 00 00 00 00 00`). Standalone AI-mode games never stream
    moves to the host. `.startSession` now encodes this via `collectionSessionData()`.

    **Ack discipline (hardware-observed):** the board retransmits each 0xA3 until the host
    writes a 0x21 ack; an unacked flood destabilized the BLE link in testing. 0x97
    board-side promotions require 0x23. The adapter queues both internally —
    `takePendingResponses()` drains them; the transport need not inspect raw frames.

    **Remaining hardware validation:** 0x99 move-indication LEDs on CU2; 0xFD occupancy stream
    (0x50 enable); 0x66 FEN-load; Android `ChessUpBleManager.kt`; gen-1 physical hardware
    itself untested (but CU2 corroborates the gen-1-pinned transport and frame formats).

---

## SquareOffAdapter

Square Off Pro and Kingdom Set (GKS). Field-proven in the Fianchetto iOS and
Android production apps. The connection, field-update, board-state, LED,
handshake, and reconnect paths are hardware-verified.

The `executeMove` motor command is **quarantined** — its wire semantics may
auto-move on motorized GKS boards and are not fully confirmed. The adapter
returns `nil` from `encode(.executeMove(uci:))` until the wire format is
hardware-verified.

```swift
import SquareOffAdapter

var adapter = SquareOffAdapter()
// capabilities: [.occupancySensing, .perSquareLEDs, .moveIndication]

let handshake = adapter.handshakeCommands(isReconnect: false)
// [(command: .startSession, delayBefore: 0.25),
//  (command: .requestState, delayBefore: 0.15)]
```

---

## ChessnutAdapter

Covers the Chessnut **Air**, **Air+**, **Pro**, and **Go** (the "classic profile" boards).
Protocol-verified against the official Chessnut docs, NSStudent/EasyLinkSwiftSDK
(MIT, `1b971059`), and chessnutech/EasyLinkSDK (MIT, `4554d17b`).

The Air / Air+ / Pro / Go family uses the standard Chessnut BLE profile:
all golden-frame fixtures from the pinned spec pass. The **Chessnut Go**
onboard stored-game import path was exercised against real hardware (2026-07,
reconstructing completed games from the board's snapshot log); broader
live-play field validation across the family is ongoing.

Use `ChessnutGATT.isClassicProfile(name:)` to filter BLE scan results to this
adapter. For the Chessnut Move (motorized board), see the
[ChessnutMoveAdapter](#chessnutmoveadapter) section below.

```swift
import ChessnutAdapter

var adapter = ChessnutAdapter()        // Air / Air+ / Pro / Go
// capabilities: [.occupancySensing, .pieceIdentity, .perSquareLEDs,
//                .moveIndication, .batteryReporting, .gameArchive]
// minimumWriteInterval: 0.2 seconds — pace every command and queued response

// Feed a raw BLE ATT notification payload:
let events = adapter.feed(bytes: blePayload)
// events may contain .identitySnapshot([Piece?]) or .squareSensed(...)

// Illuminate e2 and e4:
let ledCommand = adapter.encode(.indicateSquares(["e2", "e4"], style: .moveFrom))
// Returns 10-byte LED frame
```

---

## ChessnutMoveAdapter

The Chessnut Move is a motorized board where 34 micro-robot pieces move
autonomously. It shares all GATT UUIDs with the classic profile but adds
four-color LEDs, an auto-move command (opcode 0x42), and per-piece tracking
(opcode 0x41/0x0B). Hardware-unverified; protocol-pinned against
chessnutech/chess_move_api (official, facts only; re-derived independently)
and NSStudent/EasyLinkSwiftSDK (MIT).

Select the Move by exact advertised name: `ChessnutGATT.isMoveProfile(name:)`
returns `true` only for the string `"Chessnut Move"`. GATT UUIDs alone cannot
distinguish it from the classic profile.

```swift
import ChessnutAdapter

var adapter = ChessnutMoveAdapter()
// capabilities: [.occupancySensing, .pieceIdentity, .perPieceTracking,
//                .perSquareLEDs, .moveIndication, .motorised, .batteryReporting]

// Feed a raw BLE notification:
let events = adapter.feed(bytes: blePayload)

// Send an auto-move command (robot executes the move autonomously):
let autoMoveCmd = ChessnutMoveAdapter.encodeAutoMove(identity: targetBoard, force: true)
// 35-byte 0x42 frame — write to ChessnutGATT.commandWriteChar

// Four-color LED indication:
let ledCmd = adapter.encode(.indicateSquares(["e2", "e4"], style: .moveFrom))
// 34-byte 0x43 frame (green = .moveFrom, blue = .moveTo, red = .danger)

// Request per-piece tracking snapshot:
let pieceReq = ChessnutMoveAdapter.pieceStatusRequestData()  // write 41 01 0B
// Response on notify char: 139-byte frame with 34 × 4-byte piece records

// Request battery level:
let batReq = ChessnutMoveAdapter.batteryRequestData()  // write 41 01 0C
```

!!! warning "MTU"
    The 139-byte piece-status notification will be truncated at the default
    ATT MTU of 23 bytes. On Android, request MTU ≥ 247 before subscribing to
    notifications.

!!! note "No auto-move completion frame"
    Opcode 0x42 has no documented ack or completion notification. FEN frames
    on 1b7e8262 are suppressed during execution. Session code must poll
    `pieceStatusRequestData()` or use an external timeout strategy.

---

## PegasusAdapter

DGT Pegasus BLE board. Occupancy sensing + per-square LED move indication;
no piece identity. Protocol-pinned against
[mono424/dgtdriver at `333b1d6b`](https://github.com/mono424/dgtdriver/blob/333b1d6b151368168a395c43364cc27798920bfc/lib/DGTBoard.dart)
(MIT, Dart) as the primary reference.

At least two public community implementations publish the same default
developer-key frame: the pinned dgtdriver source and
[PegasusChessComChromeExtension at `5fe10bdc`](https://github.com/EdNekebno/PegasusChessComChromeExtension/blob/5fe10bdcf00827886d1ad8702278abe65680a2ee/content_script.js)
at the pinned revisions. That public duplication does not establish official
DGT authorization for general reuse. Deployments requiring authorization
should confirm their requirements with DGT and inject an appropriate value via
`PegasusAdapter(devkey:)`.

```swift
import PegasusAdapter

var adapter = PegasusAdapter()
// capabilities: [.occupancySensing, .perSquareLEDs,
//                .moveIndication, .batteryReporting]
```

---

## MillenniumAdapter

Millennium chess boards (BLE and USB-HID). Piece identity via Hall sensors;
9×9 corner-LED grid for move indication. The board uses `.moveIndication` but
not `.perSquareLEDs`.

Protocol-pinned against domschl/python-mchess (MIT) and alstrup/chesslink
(MIT). Full codec implemented: MF1–MF7 golden fixtures pass, full-position
orientation detection, E2ROM read/write, and delta event generation.

```swift
import MillenniumAdapter

var adapter = MillenniumAdapter()
// capabilities: [.occupancySensing, .pieceIdentity, .moveIndication]
// Note: perSquareLEDs is not set; the board uses a 9×9 corner-LED grid.
```

---

## CertaboAdapter

Certabo RFID boards (USB serial, BT Classic RFCOMM, and BLE byte pipe) plus
the Tabutronic Sentio occupancy family. Piece identity via calibrated RFID
tags; per-square LEDs (classic LED) or 9×9 corner-LED grid (Spectrum RGB).

Protocol-pinned against mono424/certabodriver (MIT, `d61997c6`); behavior was
cross-checked using locally constructed regressions informed by gkalab/cer2nut.

```swift
import CertaboAdapter

// Default (uncalibrated) — occupancy + LEDs only:
var adapter = CertaboAdapter()
// capabilities: [.occupancySensing, .moveIndication, .perSquareLEDs]
// .pieceIdentity is not set until a calibrated RFID board is detected.

// With calibration — enables piece identity:
var calibratedAdapter = CertaboAdapter(calibration: myCalibration)
// After a calibrated RFID board frame arrives, capabilities gain .pieceIdentity.
// Obtain a CertaboCalibration by calling CertaboCalibration.learn(from:standardStart:)
// on a series of start-position RFID frames.
```

!!! note "Dynamic capabilities"
    `CertaboAdapter` capabilities are dynamic. The default is
    `[.occupancySensing, .moveIndication, .perSquareLEDs]`. `.pieceIdentity`
    is added only when an RFID board is detected and a `CertaboCalibration` is
    provided to the adapter. `.perSquareLEDs` is dropped for Spectrum RGB
    boards (reported `D` status), leaving `.moveIndication` only — the same
    corner-LED-grid pattern as `MillenniumAdapter`.

---

## ChessUpAdapter

ChessUp by Bryght Labs (gen-1 and CU2). NUS GATT transport, occupancy sensing, and
move-indication LEDs (from/to squares only). Protocol-pinned against
mono424/chessupdriver (MIT, commit 589d43ad); CU2 transport and core frame semantics
**hardware-verified 2026-07-07** against a physical ChessUp 2 / LightBlue BLE session.

**Two things an integrator must do:**

1. **phoneOTB session before requesting state.** `.startSession` encodes the 0xB9 mode-5
   frame (`collectionSessionData()`). Without it the board runs in standalone AI or no-phone
   mode and never streams 0xA3 move frames to the host. On reconnect, send `.requestState`
   only — re-sending 0xB9 resets the board's internal game score.

2. **Drain acks after every `feed()` call.** Call `adapter.takePendingResponses()` and write
   the returned bytes to the NUS write characteristic (`ChessUpGATT.nusRX`). The adapter
   queues a 0x21 ack for every 0xA3 frame (including retransmits) and a 0x23 ack for every
   0x97 promotion. Failing to drain causes the board to retransmit until it drops the link.

```swift
import ChessUpAdapter

var adapter = ChessUpAdapter()
// capabilities: [.occupancySensing, .moveIndication]
// Note: .perSquareLEDs is not set; the 0x99 command accepts only two squares
// and injects a remote-move intent, not free-form per-square illumination.
// This follows the same Millennium precedent: move-indication without
// per-square contract.

// Required: start a phoneOTB session before requesting state.
// Without 0xB9 mode-5 the board never streams 0xA3 move frames.
let handshake = adapter.handshakeCommands(isReconnect: false)
// First connect:  [(.startSession, 0.0s), (.requestState, 0.15s)]
//   .startSession encodes collectionSessionData() — 0xB9 phoneOTB frame
// Reconnect only: [(.requestState, 0.25s)] — 250 ms link-settle; never re-sends 0xB9 (would reset board score)

// Required: drain acks after every inbound feed() call.
let events = adapter.feed(bytes: bleNotification)
let acks = adapter.takePendingResponses()
// Write each element of `acks` to ChessUpGATT.nusRX.
// 0x21 is queued per 0xA3 frame; 0x23 per 0x97 promotion.
// Skipping this causes the board to retransmit and eventually drop the BLE link.
```

---

## GATT constants for transport authors

Each adapter module exposes a public `*GATT` (or `*BT`/`*Serial`) enum with
the service/characteristic UUIDs and device-name filters a `BoardTransport`
implementation needs. You must use these rather than hard-coding strings.

| Adapter | Constants enum | Key constants |
|---|---|---|
| `ChessnutAdapter` | `ChessnutGATT` | `boardStateService`, `commandWriteChar`, `isClassicProfile(name:)`, `isMoveProfile(name:)` |
| `ChessnutMoveAdapter` | `ChessnutGATT` | Same UUIDs as classic; use `isMoveProfile(name:)` to select the Move adapter |
| `PegasusAdapter` | `PegasusGATT` | `nordicUART`, `writeChar`, `notifyChar`, `factoryNamePrefix` (`"DGT_Pegasus"`) |
| `MillenniumAdapter` | `MillenniumGATT` | `serviceUUID`, `notifyCharUUID`, `writeCharUUID`, `advertisedName`, `usbVendorID`/`usbProductID` |
| `CertaboAdapter` | `CertaboSerial`, `CertaboBT` | Serial: `baudRate`, `usbVendorID`/`usbProductID`; BT: `rfcommChannel`, `serviceUUID`, `deviceNameHint` |
| `ChessUpAdapter` | `ChessUpGATT` | `nusService`, `nusRX`, `nusTX`, `batteryService`, `batteryLevel`, `requestedMTU`, `isChessUp(name:)` |

Example — looking up the Chessnut notify characteristic:

```swift
import ChessnutAdapter

// In your CoreBluetooth transport:
let boardStateService = ChessnutGATT.boardStateService  // 1b7e8261-…
let notifyChar        = ChessnutGATT.boardStateChar     // 1b7e8262-…

// Device-name filter (Air/Air+/Pro/Go vs. Move):
if ChessnutGATT.isClassicProfile(name: peripheral.name ?? "") {
    // instantiate ChessnutAdapter()
} else if ChessnutGATT.isMoveProfile(name: peripheral.name ?? "") {
    // instantiate ChessnutMoveAdapter()
}
```

---

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

GPL, AGPL, and license-less repositories are protocol research references. No
third-party source files or fixture blobs from them are redistributed here. See
per-adapter file headers for specific source attribution tags.

---

## Contributing a hardware-verified adapter

If you own a physical board and want to move it from "protocol-pinned;
hardware-unverified" to "hardware-verified", submit a capture log in the
`.replay` format accepted by `ReplayTransport`.

1. Capture a BLE session covering: initial connection, several moves, battery
   request (where available).
2. Remove device addresses and UUIDs, serial numbers, names, pairing material,
   local paths, account data, and unrelated traffic. Do not submit the raw
   PacketLogger, btsnoop, pcap, phone, or application log.
3. Convert the minimal protocol bytes to `.replay` format using `tshark` (see the README for the
   one-liner).
4. Save under `Tests/Fixtures/<board-name>.replay`. `Tests/Fixtures/` does
   not exist yet — create it with your first fixture and load it in the test
   via a `#filePath`-relative path (the test target declares no SwiftPM
   resources), or follow the existing `Captures/` convention.
5. Add a test in the matching `*AdapterTests.swift` that loads the fixture
   via `ReplayScript.parse(text:)` and asserts the resulting events.
6. Open a PR. `swift test` must pass before merge.
