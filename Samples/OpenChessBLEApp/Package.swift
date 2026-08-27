// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenChessBLEApp",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "OpenChessBLEApp", targets: ["OpenChessBLEApp"])
    ],
    dependencies: [
        .package(path: "../../")
    ],
    targets: [
        .executableTarget(
            name: "OpenChessBLEApp",
            dependencies: [
                .product(name: "BoardKit", package: "BoardKit"),
                .product(name: "OpenChessAdapter", package: "BoardKit")
            ],
            path: "."
        )
    ]
)
