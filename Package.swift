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
                "BoardKitTestSupport",
                .product(name: "ChessCore", package: "ChessCore"),
            ],
            path: "Tests/BoardKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
