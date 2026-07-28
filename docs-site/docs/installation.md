# Installation

BoardKit is a Swift Package Manager library. Its only runtime dependency is
[ChessCore](https://github.com/fianchettochess/ChessCore) 0.8.0 (MIT), which it
pins exactly until the private packages make their public debut. No third-party
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

When a valid `../ChessCore` sibling checkout is present, BoardKit selects it
automatically. Standalone consumers resolve the exact versioned dependency.

### Remote dependency

```swift
dependencies: [
    .package(url: "https://github.com/fianchettochess/BoardKit.git", exact: "0.6.0"),
],
```

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
