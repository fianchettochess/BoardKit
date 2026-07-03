// swift-tools-version: 6.0
//
// BoardKit — the board-adapter seam layer between physical chess boards (Square
// Off, Chessnut Air family, DGT Pegasus, Millennium, …) and the Fianchetto
// kernel stack (BoardExecutionGate, OccupancyMoveInference, OccupancyDiffResolver,
// BoardCorrectionPlanner, BoardSyncGate, BoardReconnectPolicy, ChessBoardGeometry).
//
// Two-pass design:
//   Pass 1 (this commit) — seam types (BoardEvent/Command/Capabilities/Adapter/
//     Transport protocols) + the Chessnut Air adapter + test harness.
//   Pass 2 (future) — the seven SquareOff-rooted kernels migrate from
//     FianchettoKit into BoardKit, renamed per the seam design; a SquareOff
//     adapter joins ChessnutAdapter as a second concrete target.
//
// BoardKit depends on ChessCore (permissive MIT floor) and carries the same
// generous community deployment floor. No SwiftUI, CoreBluetooth, SkipFuse,
// or Foundation-networking in any library target.
import PackageDescription

let package = Package(
    name: "BoardKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        // Core seam: BoardEvent, BoardCommand, BoardCapabilities, BoardAdapter,
        // BoardTransport. Kernel types (BoardExecutionGate, etc.) arrive in
        // Pass 2 when they migrate from FianchettoKit.
        .library(name: "BoardKit", targets: ["BoardKit"]),
        // Chessnut Air-family adapter (Air, Air+, Pro, Go).
        // Protocol-verified against the official Chessnut docs, SWIFT-REF
        // (NSStudent/EasyLinkSwiftSDK, MIT), and C-REF (EasyLinkSDK, MIT).
        // Hardware-unverified — awaiting physical-board or capture-log
        // validation (see README).
        .library(name: "ChessnutAdapter", targets: ["ChessnutAdapter"]),
        // Test support: ReplayTransport + SimulatedBoard. Listed as a product
        // so test-only app targets can depend on it. Not part of the production
        // graph.
        .library(name: "BoardKitTestSupport", targets: ["BoardKitTestSupport"]),
    ],
    dependencies: [
        // ChessCore is its own repo, sibling of the consumer monorepos.
        // MIT licensed; no network, no platform-specific dependencies.
        .package(path: "../ChessCore"),
        // DocC for documentation generation only.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        // ── Core seam ─────────────────────────────────────────────────────────
        .target(
            name: "BoardKit",
            dependencies: [
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Sources/BoardKit"
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
                "ChessnutAdapter",
                "BoardKitTestSupport",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Tests/BoardKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
