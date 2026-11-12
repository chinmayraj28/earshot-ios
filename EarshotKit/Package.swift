// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EarshotKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EarshotKit", targets: ["EarshotKit"]),
        .executable(name: "earshot-probe", targets: ["EarshotProbe"]),
    ],
    targets: [
        .target(name: "EarshotKit"),
        .executableTarget(name: "EarshotProbe", dependencies: ["EarshotKit"]),
        .testTarget(name: "EarshotKitTests", dependencies: ["EarshotKit"]),
    ]
)
