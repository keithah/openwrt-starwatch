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
        .package(url: "https://github.com/keithah/goodcloudkit", revision: "e8e1518e8d29a0ce73697bf4f93a72fc49cf53a6"),
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
