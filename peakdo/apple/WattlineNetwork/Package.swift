// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WattlineNetwork",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WattlineNetwork", targets: ["WattlineNetwork"])
    ],
    dependencies: [
        .package(path: "../WattlineCore"),
        .package(url: "https://github.com/keithah/goodcloudkit", revision: "a20abe4c3a59e1a990800c3c5d48fa5f0176314d"),
    ],
    targets: [
        .target(name: "WattlineNetwork", dependencies: [
            .product(name: "WattlineCore", package: "WattlineCore"),
            .product(name: "GoodCloudKit", package: "goodcloudkit")
        ]),
        .testTarget(name: "WattlineNetworkTests", dependencies: [
            "WattlineNetwork",
            .product(name: "GoodCloudKit", package: "goodcloudkit")
        ])
    ]
)
