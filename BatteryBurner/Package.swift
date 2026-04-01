// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryBurner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BatteryBurner",
            path: "BatteryBurner",
            exclude: ["Info.plist", "Assets.xcassets"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
