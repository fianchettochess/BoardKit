# Getting Started

This guide shows the minimal path from adding a board transport to receiving
reconciled move candidates in a session. Each step is also independently
unit-testable without live hardware.

## 1. Choose an adapter

Pick the `BoardAdapter`-conforming struct that matches your board brand:

```swift
import BoardKit
import ChessnutAdapter   // Chessnut Air / Air+ / Pro / Go

var adapter = ChessnutAdapter()
print(adapter.capabilities)
// [.occupancySensing, .pieceIdentity, .perSquareLEDs,
//  .moveIndication, .batteryReporting, .gameArchive]
```

Each adapter declares its capabilities once at init time. Query
`adapter.capabilities` to decide which kernel paths to activate.

## 2. Create a transport (app-side)

`BoardTransport` is implemented in your app target, where `CoreBluetooth` (iOS
/ macOS) or `SkipFuse` (Android) is available. BoardKit defines the protocol;
your transport implements it:

```swift
// In your app target — pseudo-code for the CoreBluetooth implementation.
@MainActor
final class MyBoardTransport: BoardTransport, Observable {
    var state: BoardTransportState = .idle
    var discovered: [DiscoveredBoardDevice] = []
    var connectedDeviceName: String? = nil
    var lastError: String? = nil
    private(set) var events: AsyncStream<BoardEvent> = .never

    private var adapter: ChessnutAdapter = ChessnutAdapter()
    // ...
    // On BLE data received:
    //   let newEvents = adapter.feed(bytes: data)
    //   newEvents.forEach { eventsContinuation.yield($0) }
}
```

The transport calls `adapter.feed(bytes:)` on every raw BLE notification and
yields the resulting `[BoardEvent]` into the `events` stream.

## 3. Consume the event stream

Iterate `transport.events` in a `Task` from your session or view-model:

```swift
let transport: any BoardTransport = MyBoardTransport()
transport.startScan()

for await event in transport.events {
    switch event {
    case .connected:
        print("Board linked")
    case .ready:
        print("Handshake done — board is live")
    case .identitySnapshot(let pieces):
        // pieces: [Piece?], file-major, a1=0…h8=63
        print("Full snapshot received")
    case .squareSensed(let square, let isLift, let piece):
        // Feed into OccupancyMoveInference
        break
    case .battery(let pct):
        print("Battery: \(pct)%")
    case .disconnected(let error):
        print("Disconnected:", error ?? "clean")
    default:
        break
    }
}
```

## 4. Infer moves from lift/place events

`OccupancyMoveInference` reconstructs move candidates from the physical
lift-and-place sequence. Feed every `.squareSensed` event into it:

```swift
import ChessCore
import BoardKit

let inference = OccupancyMoveInference()

// Wire up the castling-legality oracle so the inference machine
// doesn't defer rook moves when castling rights are already gone.
inference.isCastlingStillLegal = { rookHomeSquare in
    gamePosition.castlingRights.contains(for: rookHomeSquare)
}

for await event in transport.events {
    guard case .squareSensed(let square, let isLift, _) = event else { continue }
    let feedback = inference.handle(square: square, isLift: isLift)
    switch feedback {
    case .pieceLifted(let sq):
        highlightLegalDestinations(from: sq)
    case .moveCandidates(let uciList):
        let legal = MoveGenerator.legalMoves(for: gamePosition)
        if let match = uciList.first(where: { legal.map(\.uci).contains($0) }) {
            MoveGenerator.applyMoveUnchecked(&gamePosition, ...)
            inference.commit(match)
        }
    case .noChange:
        break
    }
}
```

## 5. Gate engine moves on physical execution

When the engine plays a move, wait for the human to physically execute it using
`BoardExecutionGate` before recording the move:

```swift
import ChessCore
import BoardKit

// After the engine or navigation layer has applied a move:
let gate = BoardExecutionGate(move: engineMove, positionBefore: positionBefore)
print("Play \(gate.san) on the board")   // gate.san == "Nf3"

for await event in transport.events {
    guard case .squareSensed(let square, let isLift, _) = event else { continue }
    let state = gate.feed(square: square, isLift: isLift)
    switch state {
    case .inProgress: break
    case .executed:
        // Human has completed the move — resume normal inference.
        break
    case .deviated(let offSquares):
        // Player touched a square outside the move — show desync UI.
        break
    }
}
```

## 6. Test without hardware

Use `ReplayTransport` to feed captured BLE frames through the real adapter
decoder in a synchronous test:

```swift
import BoardKitTestSupport
import ChessnutAdapter

func testInitialPosition() {
    var adapter = ChessnutAdapter()
    let replay = ReplayTransport(adapter: adapter, script: [
        .lifecycle(.connected),
        .bytes(goldenInitialFrame),
    ])
    let events = replay.runSync()
    guard case .identitySnapshot(let pieces) = events.first(where: {
        if case .identitySnapshot = $0 { return true }; return false
    }) else {
        XCTFail("Expected identitySnapshot"); return
    }
    XCTAssertEqual(pieces[0], Piece(type: .rook, color: .white))  // a1 in file-major
}
```

Or bypass byte-decoding entirely with `SimulatedBoard` to test session logic:

```swift
let sim = SimulatedBoard(capabilities: [.occupancySensing])
let events = try await sim.executeMove(uci: "e2e4")
// events: [squareSensed("e2", isLift: true, piece: nil),
//          squareSensed("e4", isLift: false, piece: nil)]
```

## Next steps

- [Seam vocabulary](concepts/seam-vocabulary.md) — `BoardEvent`, `BoardCommand`,
  `BoardCapabilities`, and `LEDStyle` in depth.
- [Adapter & transport protocols](concepts/adapter-and-transport.md) — the
  `BoardAdapter` and `BoardTransport` contracts.
- [Board-agnostic kernels](concepts/kernels.md) — `OccupancyMoveInference`,
  `BoardExecutionGate`, `BoardDiffResolver`, `BoardCorrectionPlanner`,
  `BoardTakebackDetector`, and `ChessBoardGeometry`.
