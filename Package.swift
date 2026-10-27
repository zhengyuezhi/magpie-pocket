// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MagpieCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MagpieCore", targets: ["MagpieCore"])],
    targets: [
        .target(name: "MagpieCore"),
        .testTarget(name: "MagpieCoreTests", dependencies: ["MagpieCore"])
    ]
)
