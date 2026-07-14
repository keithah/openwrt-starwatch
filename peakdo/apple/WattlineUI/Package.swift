// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WattlineUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WattlineUI", targets: ["WattlineUI"])],
    dependencies: [.package(path: "../WattlineCore")],
    targets: [
        .target(
            name: "WattlineUI",
            dependencies: ["WattlineCore"]
        ),
        .testTarget(
            name: "WattlineUITests",
            dependencies: ["WattlineUI"]
        ),
    ]
)
