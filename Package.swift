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
    ],
    swiftLanguageModes: [.v6]
)
