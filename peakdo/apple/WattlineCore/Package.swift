// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WattlineCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WattlineCore", targets: ["WattlineCore"])],
    targets: [
        .target(name: "WattlineCore"),
        .testTarget(name: "WattlineCoreTests", dependencies: ["WattlineCore"]),
    ]
)
