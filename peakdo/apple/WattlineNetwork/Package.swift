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
        .package(url: "https://github.com/keithah/goodcloudkit", revision: "66226f7fb23876d273029a13d0a799bf8aa8cc7c"),
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
