// swift-tools-version: 6.0
//
// BoardKit — the board-adapter seam between physical chess boards (Square
// Off, Chessnut Air family, DGT Pegasus, Millennium, …) and downstream session
// shells, plus the shared board-agnostic kernels built on that seam
// (BoardExecutionGate, OccupancyMoveInference, BoardDiffResolver,
// BoardCorrectionPlanner, BoardSyncGate, BoardReconnectPolicy, ChessBoardGeometry).
//
// Product design:
//   BoardKit          — seam protocols (BoardEvent/Command/Capabilities/Adapter/
//                       Transport) + shared board-agnostic kernels (gate, inference,
//                       diff resolver, correction planner, geometry, reconnect policy,
//                       sync gate).
//   Adapter libraries — Square Off, Chessnut, DGT Pegasus, Millennium, Certabo,
//                       and ChessUp wire codecs and BoardAdapter implementations.
//   BoardKitTestSupport — ReplayTransport + SimulatedBoard harness.
//   boardkit-emulator — macOS BLE peripheral emulator for integration testing.
//
// BoardKit depends on ChessCore (permissive MIT floor) and carries the same
// generous community deployment floor. No SwiftUI, CoreBluetooth, SkipFuse,
// or networking code in any library target.
import Foundation
import PackageDescription

// ChessCore is reached by PATH when it is checked out beside this package, and
// by URL otherwise.
//
// Both forms are needed because BoardKit is consumed two ways. Standalone —
// external consumers, and BoardKit's own CI/release, which clone this repo
// alone — there is no sibling and the versioned URL is the only correct answer.
// Inside the Fianchetto layout every graph reaches ChessCore by path already
// (FianchettoKit and FianchettoAndroid declare `../../ChessCore`,
// Fianchetto.xcodeproj carries a local package reference, and Xcode Cloud's
// ci_post_clone.sh clones the siblings at pinned revisions), so a URL here put
// two locations behind one package identity — SwiftPM reports it as a
// "Conflicting identity for chesscore" between the remote URL and the sibling
// path dependency.
//
// SwiftPM resolves that today by letting the root's path win, but warns that it
// will become an error. Matching the surrounding layout removes the second
// location instead of relying on the override. Same conditional-manifest
// approach as FianchettoAndroid's RECKLESS_LIB_DIR archive input.
//
// The probe is deliberately narrow: a directory named ChessCore next to this
// one that actually contains a package manifest. A consumer who happens to
// vendor an unrelated `ChessCore` package beside BoardKit would build against
// it — the same thing SwiftPM's own side-by-side checkout layout would do.
let siblingChessCore = URL(fileURLWithPath: Context.packageDirectory)
    .deletingLastPathComponent()
    .appendingPathComponent("ChessCore")

let chessCoreDependency: Package.Dependency =
    FileManager.default.fileExists(atPath: siblingChessCore.appendingPathComponent("Package.swift").path)
        ? .package(path: siblingChessCore.path)
        : .package(url: "https://github.com/fianchettochess/ChessCore.git", .upToNextMinor(from: "0.7.2"))

let package = Package(
    name: "BoardKit",
    platforms: [
        // Lowest floor with no device-compatibility loss. The .4 point release is
        // the minimum for the throwing FileHandle APIs (write(contentsOf:)) used by
        // the emulator; the Swift-concurrency seam (AsyncStream/actor) already needs
        // 13.0/10.15, so this is a free point-bump. Every 13.0–13.3 device updated
        // to 13.4, so reach is identical.
        .macOS("10.15.4"),
        .iOS("13.4"),
        .tvOS("13.4"),
        .watchOS("6.2"),
        .visionOS("1.0"),
    ],
    products: [
        // Core seam + board-agnostic kernels.
        .library(name: "BoardKit", targets: ["BoardKit"]),
        // Square Off protocol codec + BoardAdapter implementation.
        .library(name: "SquareOffAdapter", targets: ["SquareOffAdapter"]),
        // Chessnut Air-family adapter (Air, Air+, Pro, Go) + Chessnut Move.
        // Protocol-verified against the official Chessnut docs, SWIFT-REF
        // (NSStudent/EasyLinkSwiftSDK, MIT), and C-REF (EasyLinkSDK, MIT).
        // Chessnut Go onboard stored-game import exercised against real
        // hardware (2026-07); broader live-play field validation ongoing
        // (see README).
        .library(name: "ChessnutAdapter", targets: ["ChessnutAdapter"]),
        // DGT Pegasus BLE adapter. Occupancy-sensing + per-square LED move indication.
        // Protocol-informed from DGT developer resources; hardware-unverified.
        .library(name: "PegasusAdapter", targets: ["PegasusAdapter"]),
        // Millennium chess board adapter (BLE + USB-HID family).
        // Piece identity via Hall sensors; 9×9 corner LED grid.
        // Protocol-informed from MIT community drivers; exercised on a
        // physical board (a live move-decode misread was found + fixed).
        .library(name: "MillenniumAdapter", targets: ["MillenniumAdapter"]),
        // Certabo e-board adapter (USB serial, RFID piece identity).
        // Per-square LED indicators. Protocol-informed from MIT drivers;
        // hardware-unverified.
        .library(name: "CertaboAdapter", targets: ["CertaboAdapter"]),
        // ChessUp BLE adapter (Bryght Labs, gen-1 + ChessUp 2).
        // NUS GATT transport, occupancy sensing, move-indication LEDs.
        // Protocol-pinned against mono424/chessupdriver; ChessUp 2
        // hardware-verified (full 90-ply game, Android + iOS, 2026-07).
        .library(name: "ChessUpAdapter", targets: ["ChessUpAdapter"]),
        // Test support: ReplayTransport + SimulatedBoard. Listed as a product
        // so test-only app targets can depend on it. Not part of the production
        // graph.
        .library(name: "BoardKitTestSupport", targets: ["BoardKitTestSupport"]),
        // Tier-0 board emulator: a macOS CLI that advertises over real BLE as a
        // physical chess board (Square Off Pro / Chessnut Air) so the Fianchetto
        // apps on a real phone can connect to it as if it were hardware. ALL
        // CoreBluetooth code lives inside this executable target, guarded by
        // `#if os(macOS) && canImport(CoreBluetooth)` — the library targets
        // above stay platform-free.
        .executable(name: "boardkit-emulator", targets: ["BoardKitEmulator"]),
    ],
    dependencies: [
        // Versioned remote dependency; use SwiftPM edit mode for a local
        // ChessCore checkout during coordinated development.
        chessCoreDependency,
        // DocC for documentation generation only.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        // ── Core seam + board-agnostic kernels ────────────────────────────────
        .target(
            name: "BoardKit",
            dependencies: [
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/BoardKit"
        ),

        // ── Square Off adapter ────────────────────────────────────────────────
        // Wire codec (SquareOffMessage/Framer/Parser/Event/Command) + adapter.
        // Square Off-specific names are preserved here — this is the right layer.
        .target(
            name: "SquareOffAdapter",
            dependencies: [
                "BoardKit",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/SquareOffAdapter"
        ),

        // ── Chessnut Air-family adapter ───────────────────────────────────────
        .target(
            name: "ChessnutAdapter",
            dependencies: [
                "BoardKit",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/ChessnutAdapter"
        ),

        // ── DGT Pegasus adapter ───────────────────────────────────────────────
        // Occupancy-sensing + per-square LED move indication. No piece identity.
        // Hardware-unverified: awaiting physical-board or BLE capture-log.
        .target(
            name: "PegasusAdapter",
            dependencies: [
                "BoardKit",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/PegasusAdapter"
        ),

        // ── Millennium adapter ────────────────────────────────────────────────
        // Piece identity via Hall sensors; 9×9 corner LED grid for move
        // indication. BLE + USB-HID connection modes.
        // Exercised on a physical board (move-decode misread found + fixed);
        // systematic field validation across firmware variants ongoing.
        .target(
            name: "MillenniumAdapter",
            dependencies: [
                "BoardKit",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/MillenniumAdapter"
        ),

        // ── Certabo adapter ───────────────────────────────────────────────────
        // RFID piece identity; per-square LEDs (classic) or 9×9 corner-LED
        // grid (Spectrum RGB). USB serial, BT Classic RFCOMM, and BLE byte
        // pipe — transport-agnostic. Tabutronic Sentio occupancy family also
        // supported. Hardware-unverified: awaiting physical-board or capture-log.
        .target(
            name: "CertaboAdapter",
            dependencies: [
                "BoardKit",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/CertaboAdapter"
        ),

        // ── ChessUp adapter ───────────────────────────────────────────────────
        // NUS GATT transport; occupancy + move-indication LEDs (no per-square
        // contract). ChessUp 2 hardware-verified (full 90-ply game, 2026-07);
        // gen-1 unit untested but shares the identical NUS profile.
        .target(
            name: "ChessUpAdapter",
            dependencies: [
                "BoardKit",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/ChessUpAdapter"
        ),

        // ── Test support library ──────────────────────────────────────────────
        .target(
            name: "BoardKitTestSupport",
            dependencies: [
                "BoardKit",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/BoardKitTestSupport"
        ),

        // ── Tests ─────────────────────────────────────────────────────────────
        .testTarget(
            name: "BoardKitTests",
            dependencies: [
                "BoardKit",
                "SquareOffAdapter",
                "ChessnutAdapter",
                "PegasusAdapter",
                "MillenniumAdapter",
                "CertaboAdapter",
                "ChessUpAdapter",
                "BoardKitTestSupport",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Tests/BoardKitTests"
        ),

        // ── Tier-0 board emulator (executable) ───────────────────────────────
        // Peripheral-side personalities (SquareOffPersonality /
        // ChessnutPersonality) reuse the host-side codecs from the adapter
        // targets in the opposite direction. The BLE peripheral server and
        // the CLI entry point are macOS-only (`#if os(macOS) &&
        // canImport(CoreBluetooth)`); every other file in the target is
        // platform-free and unit-tested by BoardKitEmulatorTests.
        .executableTarget(
            name: "BoardKitEmulator",
            dependencies: [
                "BoardKit",
                "SquareOffAdapter",
                "ChessnutAdapter",
                "PegasusAdapter",
                "MillenniumAdapter",
                "CertaboAdapter",
                "ChessUpAdapter",
                "BoardKitTestSupport",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/BoardKitEmulator"
        ),

        // ── Tier-0 emulator + chaos-layer tests ──────────────────────────────
        // Separate test target (rather than growing BoardKitTests) so the
        // emulator stream stays merge-clean against parallel adapter work.
        .testTarget(
            name: "BoardKitEmulatorTests",
            dependencies: [
                "BoardKitEmulator",
                "BoardKit",
                "SquareOffAdapter",
                "ChessnutAdapter",
                "PegasusAdapter",
                "MillenniumAdapter",
                "CertaboAdapter",
                "ChessUpAdapter",
                "BoardKitTestSupport",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Tests/BoardKitEmulatorTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
