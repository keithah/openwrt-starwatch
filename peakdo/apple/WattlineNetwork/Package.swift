// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WattlineNetwork",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WattlineNetwork", targets: ["WattlineNetwork"])
    ],
    dependencies: [
        .package(path: "../WattlineCore")
    ],
    targets: [
        .target(name: "WattlineNetwork", dependencies: [
            .product(name: "WattlineCore", package: "WattlineCore")
        ]),
        .testTarget(name: "WattlineNetworkTests", dependencies: ["WattlineNetwork"])
    ]
)
