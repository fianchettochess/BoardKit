# Usage Examples

The following examples combine BoardKit's components into common tasks.
Every snippet uses only the public API.

## Replay a captured BLE log as a golden test

```swift
import XCTest
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport

final class ChessnutAdapterTests: XCTestCase {
    func testInitialPositionFrame() throws {
        // Load a .replay fixture captured from a real Chessnut Air session.
        // The test target declares no SwiftPM resources, so resolve the file
        // relative to #filePath rather than via Bundle.module.
        // (Tests/Fixtures/ does not exist yet — create it with your first
        // fixture, or follow the existing Captures/ convention.)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                    // Tests/BoardKitTests/
            .deletingLastPathComponent()                    // Tests/
            .appendingPathComponent("Fixtures/chessnut-initial.replay")
        let text = try String(contentsOf: url, encoding: .utf8)
        let steps = try ReplayScript.parse(text: text)

        let replay = ReplayTransport(
            adapter: ChessnutAdapter(), parsedScript: steps)
        let events = replay.runSync()

        // First non-lifecycle event must be a full identity snapshot.
        let snapshot = events.first { if case .identitySnapshot = $0 { return true }
                                      return false }
        XCTAssertNotNil(snapshot, "Expected an identitySnapshot event")
    }
}
```

## Simulate a game and assert move events

```swift
import BoardKit
import BoardKitTestSupport

func testCaptureSendsThreeEvents() async throws {
    // Occupation-only board for this test.
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    // Advance to a position where a capture is available (Bxf7).
    for uci in ["e2e4", "e7e5", "f1c4", "d7d6"] {
        _ = try await sim.executeMove(uci: uci)
    }

    let events = try await sim.executeMove(uci: "c4f7")
    // Normal capture: lift mover, lift captured, place mover.
    XCTAssertEqual(events.count, 3)

    guard case .squareSensed("c4", isLift: true, piece: nil) = events[0],
          case .squareSensed("f7", isLift: true, piece: nil) = events[1],
          case .squareSensed("f7", isLift: false, piece: nil) = events[2]
    else { XCTFail("Unexpected event sequence"); return }
}
```

## Infer moves from occupancy events

```swift
import ChessCore
import BoardKit

func handleBoardEvent(
    _ event: BoardEvent,
    inference: OccupancyMoveInference,
    position: inout Position
) {
    guard case .squareSensed(let square, let isLift, _) = event else { return }
    let feedback = inference.handle(square: square, isLift: isLift)

    switch feedback {
    case .pieceLifted(let sq):
        // Highlight legal destinations for the lifted piece.
        let legal = MoveGenerator.legalMoves(for: position)
        let destinations = legal.filter { $0.from.algebraic == sq }
                                .map(\.to.algebraic)
        highlightSquares(destinations)

    case .moveCandidates(let uciList):
        let legal = MoveGenerator.legalMoves(for: position)
        let legalUCIs = Set(legal.map(\.uci))
        guard let match = uciList.first(where: { legalUCIs.contains($0) }),
              let move = UCIParser.uciToMove(match, in: legal) else { return }
        MoveGenerator.applyMoveUnchecked(&position, move)
        inference.commit(match)
        clearHighlights()

    case .noChange:
        break
    }
}
```

## Resolve an occupancy snapshot to a move sequence

```swift
import ChessCore
import BoardKit

// Board reports this occupancy after the player made a move.
let boardOccupancy: [Bool] = /* 64-element file-major array from the board */

let resolutions = BoardDiffResolver.resolve(
    from: currentPosition,
    targetOccupancy: boardOccupancy,
    maxDepth: 2
)

switch resolutions.first {
case .none:
    showDesyncUI()
case .some(let res) where res.moves.isEmpty:
    // Board already matches — no action needed.
    break
case .some(let res):
    // Auto-commit if there's exactly one clean explanation.
    if resolutions.count == 1 && res.depth == 1 {
        applyMove(uci: res.moves[0])
    } else {
        askUserToConfirm(resolutions)
    }
}
```

## Show a correction prompt for a mis-placed piece

```swift
import ChessCore
import BoardKit

func buildCorrectionMessage(
    expected: Position,
    boardOccupancy: [Bool]
) -> String {
    let corrections = BoardCorrectionPlanner.corrections(
        for: expected, boardOccupancy: boardOccupancy)
    guard !corrections.isEmpty else { return "Board looks good!" }

    return corrections.map { c in
        switch c.kind {
        case .place(let piece, let from?):
            return "Move \(piece) from \(from) to \(c.square)"
        case .place(let piece, nil):
            return "Place \(piece) on \(c.square)"
        case .remove:
            return "Remove piece from \(c.square)"
        }
    }.joined(separator: "\n")
}
```

## Gate an engine move on physical execution

```swift
import ChessCore
import BoardKit

// After the engine has chosen and applied a move:
let gate = BoardExecutionGate(move: engineMove, positionBefore: beforePosition)
showBanner(gate.humanDescription)   // "Play Nf3 on the board"

for await event in transport.events {
    guard case .squareSensed(let sq, let isLift, _) = event else { continue }
    switch gate.feed(square: sq, isLift: isLift) {
    case .inProgress:
        break
    case .executed:
        dismissBanner()
        resumeNormalInference()
        return
    case .deviated(let squares):
        showDesyncUI(squares: squares)
        return
    }
}
```

## Detect and handle a take-back

```swift
import ChessCore
import BoardKit

// After BoardDiffResolver found no forward explanation:
let ancestorPositions = gameHistory.suffix(5).reversed().map(\.position)

if let plies = BoardTakebackDetector.pliesToUndo(
    boardOccupancy: currentBoardOccupancy,
    ancestorPositions: Array(ancestorPositions)
) {
    print("Player took back \(plies) ply(s)")
    undoMoves(count: plies)
} else {
    showFullDesyncUI()
}
```

## Apply orientation flip for Black-side seating

```swift
import BoardKit

// When the player is seated on the Black side, flip every incoming square.
func normalise(square: String, orientationFlipped: Bool) -> String {
    guard orientationFlipped else { return square }
    return ChessBoardGeometry.flippedSquare(square) ?? square
}

for await event in transport.events {
    guard case .squareSensed(let raw, let isLift, let piece) = event else { continue }
    let sq = normalise(square: raw, orientationFlipped: sessionIsFlipped)
    let feedback = inference.handle(square: sq, isLift: isLift)
    // ...
}
```
