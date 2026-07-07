# Concrete adapters

Each concrete adapter is a `struct` conforming to `BoardAdapter`. It owns
wire framing, protocol parsing, command encoding, handshake sequencing, and
orientation flip for one board family. All adapters import only `BoardKit` and
`ChessCore` — no Bluetooth, no networking.

## Hardware status

| Adapter | Status | occupancy | identity | perSquareLEDs | motorised | battery |
|---|---|---|---|---|---|---|
| `SquareOffAdapter` | **Battle-tested in-app** | ✓ | | ✓ | ✓ (GKS, quarantined) | |
| `ChessnutAdapter` (Air family) | **Protocol-verified** | ✓ | ✓ | ✓ | | ✓ |
| `ChessnutMoveAdapter` | Protocol-pinned; hardware-unverified | ✓ | ✓ | ✓ | ✓ | ✓ |
| `PegasusAdapter` | Protocol-pinned; hardware-unverified | ✓ | | ✓ | | ✓ |
| `MillenniumAdapter` | Protocol-pinned; hardware-unverified | ✓ | ✓ | | | |
| `CertaboAdapter` | Protocol-pinned; hardware-unverified | ✓ | ✓ | ✓ | | |
| `ChessUpAdapter` (gen-1) | Protocol-pinned; hardware-unverified | ✓ | | ✓ | | |

!!! warning "ChessUp 2"
    ChessUp 2 support is **explicitly unverified — do not ship** to CU2 users.
    Only circumstantial evidence suggests CU2 keeps the NUS transport. All CU2
    frame semantics are unknown. The adapter will be updated once a capture log
    is contributed.

---

## SquareOffAdapter

Square Off Pro and Kingdom Set (GKS). Field-proven in the Fianchetto iOS and
Android production apps. All BLE codec paths (fieldUpdate, boardState, setLeds,
handshake/reconnect) are hardware-verified.

The `executeMove` motor command is **quarantined** — its wire semantics may
auto-move on motorised GKS boards and are not fully confirmed. The adapter
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

Covers the Chessnut **Air**, **Air+**, **Pro**, **Go**, and **Move** families.
Protocol-verified against the official Chessnut docs, NSStudent/EasyLinkSwiftSDK
(MIT), and chessnutech/EasyLinkSDK (MIT).

The Air family (Air / Air+ / Pro / Go) uses the standard Chessnut BLE profile:
all golden-frame fixtures from the pinned spec pass. Awaiting physical-board or
BLE capture-log runtime validation.

The **Move** (motorised, per-piece identity) adds opcode 0x0B per-piece status
polling and auto-move commands.

```swift
import ChessnutAdapter

var adapter = ChessnutAdapter()        // Air / Air+ / Pro / Go
// capabilities: [.occupancySensing, .pieceIdentity, .perSquareLEDs,
//                .moveIndication, .batteryReporting]

// Feed a raw BLE ATT notification payload:
let events = adapter.feed(bytes: blePayload)
// events may contain .identitySnapshot([Piece?]) or .squareSensed(...)

// Illuminate e2 and e4:
let ledCommand = adapter.encode(.indicateSquares(["e2", "e4"], style: .moveFrom))
// Returns 10-byte LED frame
```

---

## PegasusAdapter

DGT Pegasus BLE board. Occupancy sensing + per-square LED move indication;
no piece identity. Protocol-pinned against mono424/dgtdriver (MIT, Dart) as
primary reference.

The devkey bundled is the White Pawn / dgtdriver default. Integrators should
obtain their own from DGT Projects for production deployments.

```swift
import PegasusAdapter

var adapter = PegasusAdapter()
// capabilities: [.occupancySensing, .perSquareLEDs,
//                .moveIndication, .batteryReporting]
```

---

## MillenniumAdapter

Millennium chess boards (BLE and USB-HID). Piece identity via Hall sensors;
9×9 corner-LED grid for move indication — the board uses `.moveIndication` but
NOT `.perSquareLEDs`.

Protocol-pinned against domschl/python-mchess (MIT) and alstrup/chesslink
(MIT). Full codec implemented: MF1–MF7 golden fixtures pass, full-position
orientation detection, E2ROM read/write, and delta event generation.

```swift
import MillenniumAdapter

var adapter = MillenniumAdapter()
// capabilities: [.occupancySensing, .pieceIdentity, .moveIndication]
// Note: perSquareLEDs is NOT set — the board uses a 9×9 corner-LED grid.
```

---

## CertaboAdapter

Certabo RFID boards (USB serial, BT Classic RFCOMM, and BLE byte pipe) plus
the Tabutronic Sentio occupancy family. Piece identity via calibrated RFID
tags; per-square LEDs (classic LED) or 9×9 corner-LED grid (Spectrum RGB).

Protocol-pinned against mono424/certabodriver (MIT); test vectors confirmed
against gkalab/cer2nut fixtures.

```swift
import CertaboAdapter

var adapter = CertaboAdapter()
// capabilities: [.occupancySensing, .pieceIdentity, .perSquareLEDs, .moveIndication]
```

---

## ChessUpAdapter

ChessUp gen-1 (Bryght Labs). NUS GATT transport, per-square RGB LEDs,
occupancy sensing. Protocol-pinned against mono424/chessupdriver (MIT,
commit 589d43ad).

```swift
import ChessUpAdapter

var adapter = ChessUpAdapter()
// capabilities: [.occupancySensing, .perSquareLEDs, .moveIndication]
```

---

## Source attributions

| Adapter | MIT sources (code-ok) | Facts-only sources (GPL / proprietary) |
|---|---|---|
| SquareOffAdapter | First-party reverse engineering | — |
| ChessnutAdapter | NSStudent/EasyLinkSwiftSDK (MIT); chessnutech/EasyLinkSDK (MIT) | chessnutech README |
| PegasusAdapter | mono424/dgtdriver (MIT, Dart) | DGTCentaurMods/pegasus.py (GPL); DGT docs |
| MillenniumAdapter | domschl/python-mchess (MIT); alstrup/chesslink (MIT) | Graham O'Neill readme |
| CertaboAdapter | mono424/certabodriver (MIT) | Various GPL drivers (facts only) |
| ChessUpAdapter | mono424/chessupdriver (MIT, 589d43ad) | chessup-pc (all rights reserved) |

GPL, AGPL, and license-less repos are **facts only** — protocol constants and
frame layouts may be learned from them but no code structure is copied. See
per-adapter file headers for specific source attribution tags.

---

## Contributing a hardware-verified adapter

If you own a physical board and want to move it from "protocol-pinned;
hardware-unverified" to "hardware-verified", submit a capture log in the
`.replay` format accepted by `ReplayTransport`.

1. Capture a BLE session covering: initial connection, several moves, battery
   request (where available).
2. Convert to `.replay` format using `tshark` (see the README for the
   one-liner).
3. Save under `Tests/Fixtures/<board-name>.replay`.
4. Add a test in the matching `*AdapterTests.swift` that loads the fixture
   via `ReplayScript.parse(text:)` and asserts the resulting events.
5. Open a PR. `swift test` must pass before merge.
