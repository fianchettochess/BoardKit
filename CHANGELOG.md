# Changelog

All notable changes to BoardKit are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
BoardKit is pre-1.0: **under `0.x` the minor is the breaking position**, so
`0.7.0 → 0.8.0` may break source compatibility and `0.5.1 → 0.5.2` may not.
Depend on it with `.upToNextMinor(from:)` rather than `from:` — SwiftPM does not
special-case `0.x`, so `from: "0.8.0"` spans `0.8.0 ..< 1.0.0` and would accept a
breaking `0.9.0`.

Published tags are never moved or re-cut.

> **0.6.0 and earlier cannot be resolved from a URL by anyone.** If you are on
> one of those versions, the 0.7.0 entry below is the one to read.

## [0.10.0] — 2026-09-03

Breaking for consumers, though BoardKit's own API is unchanged: this release
changes which ChessCore a consumer receives, from 0.10.x to 0.11.x. Under `0.x`
the minor is the breaking position, so this is 0.10.0 rather than 0.9.1 — a
consumer resolving BoardKit 0.9.x cannot also resolve ChessCore 0.11.0, and
finds that out as a resolution failure rather than a compile error.

### Changed

- **ChessCore range moved to `0.11.0 ..< 0.12.0`.** ChessCore 0.11.0 is phase 2
  of the `PieceColor`/`PieceType` serialization migration: the ENCODER now
  writes the bare string form (`"white"`, `"knight"`) that `persistenceKey`
  documents, instead of the keyed form synthesized `Codable` produced
  (`{"white":{}}`). The decoder has accepted both since 0.10.3 and still does,
  so blobs written before it still load; only newly-written blobs change shape.

  BoardKit itself neither encodes nor decodes a `PieceColor` or `PieceType`
  through `Codable` — its codecs are the SquareOff wire format, which carries
  occupancy bits rather than piece identities — so nothing here changes
  behaviour. The bump exists because BoardKit's range was the binding
  constraint stopping its consumers from adopting 0.11.0 at all.

## [0.8.0] — 2026-08-02

Breaking for consumers, though BoardKit's own API is unchanged: this release
changes which ChessCore a consumer receives, from a pinned 0.8.0 to 0.9.x, and
ChessCore 0.9.0 removed public API. Under `0.x` the minor is the breaking
position, so this is 0.8.0 rather than 0.7.1.

### Changed

- **ChessCore is required as a range, not pinned.** 0.7.0 declared
  `.package(url: …ChessCore.git, exact: "0.8.0")`. An `exact:` requirement in a
  library propagates to every consumer, so a program that needed a different
  ChessCore than the one BoardKit named could not have it — resolution failed
  outright rather than negotiating:

  ```
  error: Dependencies could not be resolved because root depends on 'chesscore' 0.9.0..<0.10.0
  and 'boardkit' depends on 'chesscore' 0.8.0.
  ```

  The requirement is now `.upToNextMinor(from: "0.9.0")`, i.e.
  `0.9.0 ..< 0.10.0`. `.upToNextMinor` rather than `from:` because ChessCore is
  pre-1.0 and under `0.x` the minor is its breaking position — SwiftPM does not
  special-case `0.x`, so `from: "0.9.0"` would resolve `0.9.0 ..< 1.0.0` and
  accept a breaking `0.10.0`.

  **What to do.** Nothing, if you do not use ChessCore directly. If you do, you
  are now on ChessCore 0.9.x rather than 0.8.0, and 0.9.0 was a breaking release
  — see [ChessCore's
  changelog](https://github.com/fianchettochess/ChessCore/blob/main/CHANGELOG.md).
  The renames most likely to reach you are `Position.stockfishSafeFEN` →
  `consistentFEN` (deprecated alias retained, so it still compiles) and the
  `EngineError` cases. BoardKit itself uses none of the changed API.

  To develop against a local ChessCore, use `swift package edit ChessCore` or a
  root-level `.package(path:)` override. The manifest does not inspect the
  filesystem.

### Documentation

- The seam-vocabulary page still listed `BoardCapabilities.squareOff` and
  `.chessnutAirFamily` as members of `BoardCapabilities`; they moved to their
  adapter targets in 0.7.0. It also stated an absolute prohibition on
  `BoardEvent.raw` that 0.7.0 replaced with a capability-gated exception, and
  described `.perPieceTracking` as a modelled feature rather than a hardware
  fact the seam does not yet express.
- The reconnect examples said a two-entry `delays` array meant two attempts. It
  does not: `delays` shapes the ramp and `maxAttempts` decides how many attempts
  there are, so `BoardReconnectPolicy(delays: [0.5, 1])` waits `0.5, 1, 1, 1, 1`.
  Corrected in both `BoardReconnectPolicy`'s own documentation and on the
  documentation site.
- `SquareOffGATT`, added in 0.7.0, was missing from the GATT-constants table for
  transport authors.
- Added this changelog, and a changelog page on the documentation site.

## [0.7.0] — 2026-08-01

### Fixed

- **BoardKit is resolvable from a URL. Every earlier version is not.** The
  manifest probed the filesystem at evaluation time for a sibling `ChessCore`
  directory and preferred it over the versioned URL. SwiftPM checks every
  dependency out into `.build/checkouts/<name>`, so for anyone depending on
  BoardKit, ChessCore lands as a literal sibling of BoardKit — the probe fired,
  switched to a path dependency pointing into SwiftPM's own checkouts directory,
  and resolution died:

  ```
  error: exhausted attempts to resolve the dependencies graph
  ```

  Reproduced from a clean package whose only dependency was BoardKit. The probe
  also silently bound a build to any directory named `ChessCore` that happened
  to sit beside the checkout.

  **What to do.** Move to 0.7.0 or later. There is no workaround on 0.6.0 or
  earlier — the defect is in the published manifest, and a consumer cannot
  override it. The identity conflict the probe worked around is a monorepo
  problem: express it deliberately with `swift package edit ChessCore` or a
  root-level `.package(path:)` override in the package that consumes both.

### Changed

- **`BoardExecutionGate.humanDescription` is now `.san`.** The gate was
  composing and storing an unlocalized English sentence — `"Play Nf3 on the
  board"` — for one consumer's banner. It now exposes the SAN it had already
  computed, and the caller writes the sentence in its own words and language:

  ```swift
  let gate = BoardExecutionGate(move: engineMove, positionBefore: position)
  showBanner("Play \(gate.san) on the board")   // gate.san == "Nf3"
  ```

- **`BoardReconnectPolicy` takes its schedule as data.**
  `init(maxAttempts:delays:)`, with `delays` defaulting to `[2, 4, 8]` and the
  last entry held for every attempt beyond its length. How long to wait between
  attempts is a product's patience, not a hardware fact, and the type had looked
  configurable while hardcoding one curve. Four documentation sites quoted
  `"attempt N/5"` back at callers who had configured `maxAttempts` to something
  else.

  ```swift
  BoardReconnectPolicy()                              // 2, 4, 8, 8, 8
  BoardReconnectPolicy(delays: [0.5, 1])              // 0.5, 1, 1, 1, 1
  BoardReconnectPolicy(maxAttempts: 2, delays: [0.5]) // 0.5, 0.5 — then give up
  ```

  The default schedule is unchanged, so a caller that constructed
  `BoardReconnectPolicy()` or passed only `maxAttempts` gets the same behaviour
  as before.

- **Vendor capability presets moved to their adapter targets**, matching
  `.chessUp`, which was already there. Add the import; the values are unchanged.

  | Preset | Was | Now in |
  |---|---|---|
  | `BoardCapabilities.squareOff` | `BoardKit` | `import SquareOffAdapter` |
  | `BoardCapabilities.chessnutAirFamily` | `BoardKit` | `import ChessnutAdapter` |

  A vendor preset on the shared type would have been a source break to move
  after 1.0, and it made `BoardKit` alone carry vocabulary for hardware a
  consumer may not use.

### Added

- **`SquareOffGATT`** — the Square Off advertised marker service, Nordic UART
  service and characteristics, and an `isSquareOff(name:)` filter. All six
  adapter modules now publish their own discovery and connection identity, so a
  transport never hard-codes a UUID. `SquareOffPersonality` in the emulator
  reads it rather than repeating the UUIDs, so the emulator and the adapter
  cannot drift.

### Documentation

- **`BoardCapabilities.perPieceTracking` pointed callers at a `BoardAdapter`
  method that does not exist**, and told them to do what `BoardEvent.raw`
  forbids. The bit now states that the seam does not model the concept yet, and
  names the adapter method that does exist
  (`ChessnutMoveAdapter.pieceStatusRequestData()`). `BoardEvent.raw` permits
  exactly that capability-gated case rather than stating an absolute
  prohibition it then breaks.
- The stringly-typed square rationale no longer claims it exists so that one
  session needs no conversion. It is recorded as a known wart, with the reason
  it has not been changed: a typed square is a source break for every adapter
  and kernel call.
- Removed internal review-ticket citations, `"Renamed from … on <date>"` notes,
  migration provenance, and references to private predecessor types. The
  explanations were rewritten rather than deleted — the castle-deferral
  reasoning, the framer buffer cap, and the clock-inversion warning all survive.
  Dates attached to hardware verification and pinned upstream revisions stay:
  those are evidence a reader can weigh.
- `Captures/` is described as what it is — `boardkit-emulator` output at a fixed
  seed, not hardware traces — and the four files are renamed accordingly. One
  had been named for a chaos profile its own header contradicted.

## [0.6.0] — 2026-07-28

### Added

- **`BoardAdapter.minimumWriteInterval`** — the minimum interval between
  consecutive physical writes to a board, defaulting to `0` (no adapter-specific
  requirement). A transport must serialize every outgoing byte through one
  pacing path: commands from `encode(_:)`, handshake commands, and everything
  drained from `takePendingResponses()`. `ChessnutAdapter` declares 200 ms,
  which its firmware requires; without it, a stored-game import that queues
  three mandatory responses at once can make the board drop later commands.

### Documentation

- `BoardTransport`'s `.connected` state means a writable link with an active
  notification subscription. It deliberately precedes the adapter handshake —
  wait for `BoardEvent.ready` before treating the sensor stream as live.

## [0.5.2] — 2026-07-21

### Fixed

- Public dependency compatibility.
- Emulator: `setvbuf(stdout)` is scoped to Darwin, for Swift 6 concurrency and
  Linux.

### Changed

- CI: on-push Linux test gate on `ubuntu-latest`; updated checkout action
  runtime; authenticated private package dependencies.

### Documentation

- Dropped the private-repository installation caveat, corrected audited claims,
  and harmonized the README badge row across the package repositories.

## [0.5.1] — 2026-07-17

### Fixed

Pre-public hardening: adapter robustness fixes, additional Square Off tests, and
a validated README.

## [0.5.0] — 2026-07-17

### Added

- **Chessnut stored-game import.** `BoardCommand.requestStoredGames`,
  `BoardEvent.storedGameImported(moves:sanMoves:isComplete:)`, and
  `BoardCapabilities.gameArchive`, with the adapter file-transfer state machine
  and emulator replay behind them.
- **`ChessnutStoredGameDecoder`** — reconstructs completed games from a board's
  snapshot list.
- ChessUp live-play decode is locked by a 90-ply golden test taken from physical
  hardware.
- CI publishes a GitHub Release automatically on a version-tag push.

`BoardEvent` and `BoardCommand` each gained a case; an exhaustive `switch` over
either needs a new arm.

## [0.4.1] — 2026-07-15

### Changed

- Organization migration: `jaredbrewer` references retargeted to
  `fianchettochess`.

## [0.4.0] — 2026-07-13

### Fixed

- Chessnut `applyUCI`: an en-passant capture must move exactly one file.

## [0.3.0] — 2026-07-10

### Added

- **`BoardEvent.promotionPick(piece:)`** — a typed board-reported promotion
  choice (the ChessUp `0x97` frame). When the board reports the piece this way,
  the session can resolve the promotion picker without asking the human. Session
  code must handle this case and must not treat it like `.raw`. An exhaustive
  `switch` over `BoardEvent` needs a new arm.
- `ChessUpPersonality` in the emulator, modelling the hardware-verified
  protocol, and a ChessUp ack-drain hook plus phoneOTB session start.
- The MkDocs documentation site.

### Fixed

- Hardened Chessnut move validation.

### Changed

- ChessUp 2 is hardware-verified; the do-not-ship warnings are retired.

## [0.2.0] — 2026-07-05

### Changed

- **Deployment floor lowered to iOS 13.4 / macOS 10.15.4**, from iOS 16 /
  macOS 13. The floor is now the Swift-concurrency back-deployment minimum that
  `AsyncStream` and `actor` require, plus the `.4` point release for the
  throwing `FileHandle` APIs the emulator uses.

## [0.1.0] — 2026-07-05

First tagged release: the adapter seam (`BoardEvent`, `BoardCommand`,
`BoardCapabilities`, `BoardAdapter`, `BoardTransport`), the board-agnostic
kernels (`OccupancyMoveInference`, `BoardExecutionGate`, `BoardDiffResolver`,
`BoardCorrectionPlanner`, `BoardTakebackDetector`, `BoardSyncGate`,
`BoardReconnectPolicy`, `ChessBoardGeometry`), six adapter modules (Square Off,
Chessnut Air family and Move, DGT Pegasus, Millennium, Certabo, ChessUp), the
`ReplayTransport` / `SimulatedBoard` test harness, and the `boardkit-emulator`
BLE peripheral with per-board personalities and a chaos engine.

[0.8.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.8.0
[0.7.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.7.0
[0.6.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.6.0
[0.5.2]: https://github.com/fianchettochess/BoardKit/releases/tag/0.5.2
[0.5.1]: https://github.com/fianchettochess/BoardKit/releases/tag/0.5.1
[0.5.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.5.0
[0.4.1]: https://github.com/fianchettochess/BoardKit/releases/tag/0.4.1
[0.4.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.4.0
[0.3.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.3.0
[0.2.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.2.0
[0.1.0]: https://github.com/fianchettochess/BoardKit/releases/tag/0.1.0
