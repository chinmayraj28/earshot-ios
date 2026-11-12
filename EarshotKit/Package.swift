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
        .executableTarget(
            name: "EarshotProbe",
            dependencies: ["EarshotKit"],
            exclude: ["Info.plist"],
            // macOS only lets a command-line tool use Bluetooth if it carries a usage description.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "Sources/EarshotProbe/Info.plist"])]
        ),
        .testTarget(name: "EarshotKitTests", dependencies: ["EarshotKit"]),
    ]
)
