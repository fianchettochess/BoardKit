# Board-agnostic kernels

The kernel layer is a set of pure-logic, actor-free types that sit between the
transport's `BoardEvent` stream and the session's game state. All kernels
import only `ChessCore` and `Foundation`; none import UI, Bluetooth, or
networking. They are testable without live hardware.

---

## OccupancyMoveInference

Reconstructs chess moves from the physical lift-and-place sequence reported by
an occupancy-sensing board.

The board reports per-square presence transitions but no piece identity. Up to
four slots are tracked so simple moves, captures, castling, and en-passant can
be reconstructed. After every event, `handle(square:isLift:)` returns
candidates for the session to validate against the current legal-move list.

```swift
public final class OccupancyMoveInference {
    public var isCastlingStillLegal: ((_ rookHomeSquare: String) -> Bool)?
    public func reset()
    public func handle(square: String, isLift: Bool) -> OccupancyInferenceFeedback
    public func commit(_ uci: String)
}

public enum OccupancyInferenceFeedback: Equatable, Sendable {
    case pieceLifted(square: String)
    case moveCandidates(_ uciMoves: [String])
    case noChange
}
```

### Feedback cases

| Case | When emitted |
|---|---|
| `.pieceLifted(square:)` | Only the first lift observed — highlight legal destinations |
| `.moveCandidates([String])` | One or more UCI candidates; session validates against legal moves |
| `.noChange` | No complete shape yet (castling deferral or mid-sequence) |

### Castling oracle

Wire `isCastlingStillLegal` before using the inference machine. Without it, a
physical rook move from a corner square after castling rights are gone may be
incorrectly deferred. Set it to a closure that queries the game's current
castling rights for the given rook-home square.

### Commit

Call `commit(_:)` after the session accepts a move. This resets all four slots
so subsequent events build a fresh move. Leftover slots from a castling
king+rook sequence are also cleared.

---

## BoardExecutionGate

Tracks whether the human has physically executed an app-dictated move on the
board. The session creates a gate for an engine reply or analysis navigation
move, then routes field events through it instead of `OccupancyMoveInference`
until the gate reaches `.executed` or `.deviated`.

```swift
public final class BoardExecutionGate {
    public let expectedUCI: String
    public let humanDescription: String   // e.g. "Play Nf3 on the board"

    public init(move: Move, positionBefore: Position)
    public func feed(square: String, isLift: Bool) -> State
}

public enum BoardExecutionGate.State: Equatable {
    case inProgress
    case executed
    case deviated([String])   // payload = offending squares
}
```

The gate computes the **required physical effect set** from the move geometry:

| Move type | Required lifts | Required places |
|---|---|---|
| Simple move | `{from}` | `{to}` |
| Capture | `{from, to}` | `{to}` |
| En passant | `{from, capturedPawn}` | `{to}` |
| Castling | `{kingFrom, rookFrom}` | `{kingTo, rookTo}` |
| Promotion | `{from}` | `{to}` |

Terminal states (`.executed`, `.deviated`) are sticky — further calls return
the same value without mutating tracking state.

---

## BoardDiffResolver

Reconciles the app's `Position` against a 64-bit occupancy array reported by
the board, by searching the legal-move tree for sequences whose resulting
occupancy matches the snapshot.

```swift
public enum BoardDiffResolver {
    public struct Resolution: Equatable, Sendable {
        public let moves: [String]   // UCI strings
        public var depth: Int        // moves.count
    }

    public static func resolve(
        from position: Position,
        targetOccupancy: [Bool],
        maxDepth: Int = 3,
        limit: Int = 8
    ) -> [Resolution]

    public static func occupancyArray(for position: Position) -> [Bool]
}
```

`resolve` performs a BFS over the legal-move tree up to `maxDepth` plies and
returns the shallowest set of explanations, sorted by a **wander score**. A
resolution "wanders" when it touches squares that are neither part of the
occupancy diff nor a capture target — a signature of a coincidental sequence.
Zero-wander resolutions (the actual move) are surfaced first; the rest are
truncated to the three least-wandering alternatives.

`occupancyArray(for:)` converts a `Position` into the same file-major `[Bool]`
the board reports (a1=0, a2=1, …, h8=63). Useful for building the diff before
calling `resolve`.

---

## BoardCorrectionPlanner

Computes the minimal, identity-aware set of physical corrections needed to
bring the board back into agreement with the app's expected `Position`.

```swift
public enum BoardCorrectionPlanner {
    public struct Correction: Equatable, Sendable, Hashable {
        public enum Kind: Equatable, Sendable, Hashable {
            case place(piece: Piece, from: String?)  // `from` = relocate source
            case remove
        }
        public let square: String
        public let kind: Kind
        public var expectedPiece: Piece?   // non-nil for .place
        public var fromSquare: String?     // non-nil for .place(..., from: nonNil)
    }

    public static func corrections(
        for expected: Position,
        boardOccupancy: [Bool]
    ) -> [Correction]
}
```

The planner is **identity-aware**: a missing piece on one square and a stray
piece on another are paired as a single **relocate** action (`.place(piece:,
from: straySquare)`) when possible, rather than a bare remove + place. Pairing
uses Chebyshev distance so the most nearby stray is preferred.

Returns an empty array when occupancy already matches. Corrections are emitted
only for disagreeing squares; correct squares are silently skipped.

---

## BoardTakebackDetector

Detects a physical take-back: the player has picked pieces up and restored an
earlier position on the current game line.

`BoardDiffResolver` only searches forward from the app's position. A take-back
is never forward-reachable, so it reaches this detector only after the forward
resolver has failed.

```swift
public enum BoardTakebackDetector {
    public static func pliesToUndo(
        boardOccupancy: [Bool],
        ancestorPositions: [Position]
    ) -> Int?
}
```

`ancestorPositions` is `[Position]` indexed as 0 = one ply back, 1 = two plies
back, etc. The caller bounds the list (e.g. the last 5–10 plies) to prevent a
distant coincidental occupancy from triggering a huge rollback.

Returns the shallowest matching depth (1-based), or `nil` if no ancestor
matches.

---

## ChessBoardGeometry

Pure square-geometry helpers shared by all board integrations.

```swift
public enum ChessBoardGeometry {
    // 180° board rotation: a1 ↔ h8, e4 ↔ d5, …
    // Returns nil for malformed input.
    public static func flippedSquare(_ square: String) -> String?

    // File-major occupancy array index: a1=0, a2=1, …, h8=63.
    // Returns nil for malformed input.
    public static func boardOccupancyIndex(for square: String) -> Int?

    // Squares where board and position disagree (both file-major comparison).
    public static func mismatchedSquares(
        position: Position,
        boardOccupancy: [Bool]
    ) -> [String]
}
```

`flippedSquare` applies the 180° orientation flip used when a player is seated
on the Black side. The session applies it to incoming `squareSensed.square`
values when `orientationFlipped` is active; adapters are always stateless with
respect to UI orientation preferences.

`boardOccupancyIndex` converts an algebraic square to its file-major index —
the index scheme used by `[Bool]` occupancy arrays throughout BoardKit.

`mismatchedSquares` lists every square whose occupancy differs between the
app's `Position` and the board's reported array, for desync display or
correction planning.
