// swift-tools-version: 6.0
//
// BoardKit — the board-adapter seam layer between physical chess boards (Square
// Off, Chessnut Air family, DGT Pegasus, Millennium, …) and the Fianchetto
// kernel stack (BoardExecutionGate, OccupancyMoveInference, BoardDiffResolver,
// BoardCorrectionPlanner, BoardSyncGate, BoardReconnectPolicy, ChessBoardGeometry).
//
// Three-target design (as of 2026-07-03 extraction pass):
//   BoardKit          — seam protocols (BoardEvent/Command/Capabilities/Adapter/
//                       Transport) + shared board-agnostic kernels (gate, inference,
//                       diff resolver, correction planner, geometry, reconnect policy,
//                       sync gate).
//   SquareOffAdapter  — Square Off wire codec (SquareOffMessage/Framer/Parser/Event/
//                       Command) + SquareOffAdapter: BoardAdapter implementation.
//   ChessnutAdapter   — Chessnut Air-family adapter.
//   BoardKitTestSupport — ReplayTransport + SimulatedBoard harness.
//
// BoardKit depends on ChessCore (permissive MIT floor) and carries the same
// generous community deployment floor. No SwiftUI, CoreBluetooth, SkipFuse,
// or Foundation-networking in any library target.
import Foundation
import PackageDescription

// Local Fianchetto development keeps ChessCore next to BoardKit, while a
// standalone/remote BoardKit checkout does not. The old unconditional
// `../ChessCore` dependency made every remote BoardKit release unusable unless
// consumers happened to reproduce the author's folder layout. Prefer the
// sibling only when it actually exists; otherwise resolve the public package.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let siblingChessCoreManifest = packageDirectory
    .deletingLastPathComponent()
    .appendingPathComponent("ChessCore/Package.swift")
let chessCoreDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: siblingChessCoreManifest.path
) ? .package(path: "../ChessCore")
  : .package(url: "https://github.com/fianchettochess/ChessCore.git", from: "0.3.0")

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
        // Chessnut Air-family adapter (Air, Air+, Pro, Go).
        // Protocol-verified against the official Chessnut docs, SWIFT-REF
        // (NSStudent/EasyLinkSwiftSDK, MIT), and C-REF (EasyLinkSDK, MIT).
        // Hardware-unverified — awaiting physical-board or capture-log
        // validation (see README).
        .library(name: "ChessnutAdapter", targets: ["ChessnutAdapter"]),
        // DGT Pegasus BLE adapter. Occupancy-sensing + per-square LED move indication.
        // Protocol-informed from DGT developer resources; hardware-unverified.
        .library(name: "PegasusAdapter", targets: ["PegasusAdapter"]),
        // Millennium chess board adapter (BLE + USB-HID family).
        // Piece identity via Hall sensors; 9×9 corner LED grid.
        // Protocol-informed from MIT community drivers; hardware-unverified.
        .library(name: "MillenniumAdapter", targets: ["MillenniumAdapter"]),
        // Certabo e-board adapter (USB serial, RFID piece identity).
        // Per-square LED indicators. Protocol-informed from MIT drivers;
        // hardware-unverified.
        .library(name: "CertaboAdapter", targets: ["CertaboAdapter"]),
        // ChessUp BLE adapter (Moverio/BrainBox smart board).
        // Per-square LEDs; piece identity TBD. Protocol partially known from
        // community BLE captures; hardware-unverified.
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
        // Local sibling for coordinated development; versioned remote package
        // for standalone clones and normal SwiftPM consumers.
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
        // Hardware-unverified: awaiting physical-board or capture-log.
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
        // Per-square LEDs; piece identity TBD. BLE connection.
        // Hardware-unverified: awaiting physical-board or BLE capture-log.
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
