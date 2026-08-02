# Installation

BoardKit is a Swift Package Manager library. Its only runtime dependency is
[ChessCore](https://github.com/fianchettochess/ChessCore) (MIT), required as
`.upToNextMinor(from: "0.9.0")` — a range rather than a pin, so a program that
depends on both can choose its own ChessCore within that minor. No third-party
networking, UI, or platform-specific libraries are required by the library
targets.

## Requirements

| | Minimum |
|---|---|
| Swift tools | 6.0 (Swift 6 language mode) |
| iOS | 13.4 |
| macOS | 10.15.4 |
| tvOS | 13.4 |
| watchOS | 6.2 |
| visionOS | 1.0 |

The floor matches the Swift-concurrency back-deployment minimum that
`AsyncStream` and `actor` require. The `boardkit-emulator` executable target
uses throwing `FileHandle` APIs (available since iOS 13.4 / macOS 10.15.4).

## Add the package

### Local ChessCore checkout

The manifest declares one ordinary versioned dependency and never inspects the
filesystem. To develop against a local ChessCore alongside BoardKit, use
`swift package edit ChessCore` or a root-level `.package(path:)` override in
the package that consumes both.

### Remote dependency

```swift
dependencies: [
    .package(url: "https://github.com/fianchettochess/BoardKit.git", .upToNextMinor(from: "0.8.0")),
],
```

!!! danger "0.6.0 and earlier cannot be resolved from a URL"
    Their manifest probed the filesystem for a sibling ChessCore directory.
    SwiftPM checks every dependency out into `.build/checkouts/<name>`, so for
    anyone depending on BoardKit, ChessCore lands as a literal sibling — the
    probe fired, switched to a path dependency pointing into SwiftPM's own
    checkouts directory, and resolution failed with *"exhausted attempts to
    resolve the dependencies graph"*. **0.7.0 is the first tag that resolves.**

### Choosing a version requirement

BoardKit is pre-1.0, and under `0.x` the minor is the breaking position: a
`0.7.0 → 0.8.0` step may break source compatibility, a `0.5.1 → 0.5.2` step will
not. The [changelog](changelog.md) records what changed in each.

Prefer `.upToNextMinor(from:)` over `from:`. SwiftPM does not special-case `0.x`
— `from: "0.8.0"` is shorthand for `.upToNextMajor(from: "0.8.0")`, which
resolves `0.8.0 ..< 1.0.0` and would accept a breaking `0.9.0`.

### Xcode

In Xcode: **File ▸ Add Package Dependencies…**, enter the repository URL (or
add the local package), then add the specific library products you need to your
target.

## Choosing products

Only import the adapter products you actually need — each adapter brings in only
its own wire-codec files and declares no transitive library dependencies beyond
`BoardKit` itself.

| You need | Add product |
|---|---|
| Square Off boards | `SquareOffAdapter` |
| Chessnut Air / Air+ / Pro / Go / Move | `ChessnutAdapter` |
| DGT Pegasus | `PegasusAdapter` |
| Millennium (BLE or USB) | `MillenniumAdapter` |
| Certabo / Tabutronic Sentio | `CertaboAdapter` |
| ChessUp (gen-1 / ChessUp 2) | `ChessUpAdapter` |
| Tests and simulation | `BoardKitTestSupport` |

## Import

```swift
import BoardKit           // seam protocols + kernels
import ChessnutAdapter    // the concrete adapter you chose
import BoardKitTestSupport // in test targets only
```

## Verifying the install

```bash
swift build
swift test    # runs framing regression tests against golden-fixture files
```
