// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryBurner",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CRandomX",
            path: "CRandomX",
            pkgConfig: nil,
            providers: nil
        ),
        .executableTarget(
            name: "BatteryBurner",
            dependencies: ["CRandomX"],
            path: "BatteryBurner",
            exclude: ["Info.plist", "Assets.xcassets"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .unsafeFlags(["-L\(Context.packageDirectory)/CRandomX", "-lrandomx", "-lc++"])
            ]
        )
    ]
)
