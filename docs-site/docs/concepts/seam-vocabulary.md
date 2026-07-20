# Seam vocabulary

The seam vocabulary is the shared language that every board adapter speaks and
every session-layer consumer understands. All types live in the `BoardKit`
target and import only `ChessCore` and `Foundation`.

## BoardEvent

`BoardEvent` is the decoded output of a board adapter — the semantic events
that a physical board can produce regardless of brand or protocol.

```swift
public enum BoardEvent: Sendable {
    // Sensor events
    case squareSensed(square: String, isLift: Bool, piece: Piece? = nil)
    case occupancySnapshot([Bool])
    case identitySnapshot([Piece?])
    // Connection lifecycle
    case connected
    case ready
    case disconnected(error: String?)
    // Housekeeping
    case battery(percent: Int)
    case raw(Data)
    // Hardware-reported picks
    case promotionPick(piece: PieceType)
    // Stored-game import
    case storedGameImported(moves: [Move], sanMoves: [String], isComplete: Bool)
}
```

### Sensor cases

**`.squareSensed`** fires on every lift or place detected by the board's
sensors. `square` is an algebraic string in the board's physical frame
(no orientation correction — that is a session concern). `piece` is non-nil
only on identity-sensing boards (Chessnut, Certabo, Millennium). Square Off and
DGT Pegasus always emit `piece: nil`.

**`.occupancySnapshot`** is a 64-element `[Bool]` in **file-major** order
(a1=0, a2=1, … a8=7, b1=8, … h8=63). Occupancy-only adapters (Square Off,
DGT Pegasus) emit this; identity boards emit `.identitySnapshot` instead.

**`.identitySnapshot`** is a 64-element `[Piece?]` in the same file-major
layout. Only emitted by Chessnut, Certabo, and Millennium. Callers that need
only occupancy: `map { $0 != nil }`.

### Lifecycle cases

| Case | Meaning |
|---|---|
| `.connected` | Physical + protocol link established |
| `.ready` | Board completed its handshake; sensor stream is live |
| `.disconnected(error:)` | Link dropped; `error` is nil for a clean disconnect |

### Housekeeping

**`.battery(percent:)`** — battery level 0–100, emitted by boards that
support it (Chessnut Air family, DGT Pegasus).

**`.raw(Data)`** — undecoded bytes for unknown opcodes; session code must
never branch on this case.

### Hardware-reported picks and stored games

**`.promotionPick(piece:)`** — a board-side promotion piece pick (ChessUp
`0x97` frame). When the board reports the promotion piece this way, the
session can auto-resolve the promotion picker without asking the human.
Session code must handle this case and must NOT treat it like `.raw`.

**`.storedGameImported(moves:sanMoves:isComplete:)`** — one game
reconstructed from a board's internal storage during a
`BoardCommand.requestStoredGames` import. Emitted by adapters that advertise
`BoardCapabilities.gameArchive` (Chessnut Air family), one event per stored
game. `isComplete` is `false` when the replay truncated and `moves` holds the
recovered prefix.

---

## BoardCommand

`BoardCommand` is the session-to-adapter vocabulary — commands the session
sends down to the board. The adapter's `encode(_:) -> Data?` translates each
case into board-specific wire bytes, returning `nil` for unsupported commands
(which the transport silently skips).

```swift
public enum BoardCommand: Sendable {
    case startSession
    case requestState
    case indicateSquares([String], style: LEDStyle)
    case executeMove(uci: String)
    case requestStoredGames
    case custom(Data)
}
```

| Case | Purpose |
|---|---|
| `.startSession` | Begin a new game / enter active-play state |
| `.requestState` | Request a full occupancy or identity snapshot |
| `.indicateSquares([String], style:)` | Illuminate squares with the given style |
| `.executeMove(uci:)` | Ask a motorised board to physically play a move |
| `.requestStoredGames` | Begin importing the games stored on the board's internal flash (`.gameArchive` boards); each game surfaces as `.storedGameImported` |
| `.custom(Data)` | Adapter-specific payload not yet in the shared vocabulary |

`squares` in `.indicateSquares` is an array of algebraic strings (`["e2",
"e4"]`). Pass an empty array to clear all LEDs.

---

## LEDStyle

`LEDStyle` is an advisory illumination hint for `.indicateSquares`. Adapters
that support only a single LED colour treat all non-`.highlight` values as
`.highlight`.

```swift
public enum LEDStyle: Sendable {
    case highlight          // plain on/off — universally supported
    case moveFrom           // source-square emphasis (green on Chessnut)
    case moveTo             // destination-square emphasis (yellow on Chessnut)
    case danger             // check/threat emphasis (red on Chessnut)
    case custom(UInt8)      // board-specific colour index
}
```

---

## BoardCapabilities

`BoardCapabilities` is an `OptionSet` of feature flags declared by a concrete
`BoardAdapter`. Query it once at connect time to determine which kernel paths
to activate.

```swift
public struct BoardCapabilities: OptionSet, Sendable {
    public static let occupancySensing  // per-square lift/place
    public static let pieceIdentity     // piece type+colour per square
    public static let perSquareLEDs     // individually addressable per-square LEDs
    public static let moveIndication    // any move-highlight capability
    public static let motorised         // auto-move mechanism
    public static let batteryReporting  // reports battery level
    public static let perPieceTracking  // per-robot unique identity (Chessnut Move)
    public static let gameArchive       // onboard stored-game archive (requestStoredGames)

    // Convenience presets
    public static let chessnutAirFamily: BoardCapabilities
    public static let squareOff: BoardCapabilities
}
```

### Capability matrix

| Board | occupancy | identity | perSquareLEDs | moveIndication | motorised | battery | gameArchive |
|---|---|---|---|---|---|---|---|
| Square Off Pro / GKS | ✓ | | ✓ | ✓ | ✓ (GKS) | | |
| Chessnut Air family | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ |
| Chessnut Move | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| DGT Pegasus | ✓ | | ✓ | ✓ | | ✓ | |
| Millennium | ✓ | ✓ | | ✓ (9×9 corner) | | | |
| Certabo | ✓ | ✓ | ✓ | ✓ | | | |

!!! note "Millennium and `perSquareLEDs`"
    The Millennium board uses a 9×9 corner-LED grid rather than per-square LEDs.
    It sets `.moveIndication` but NOT `.perSquareLEDs`. Always check `.perSquareLEDs`
    before sending granular LED commands.
