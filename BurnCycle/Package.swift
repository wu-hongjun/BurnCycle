// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurnCycle",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BurnCycle",
            path: "BurnCycle",
            exclude: ["Info.plist", "Assets.xcassets", "Resources"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .unsafeFlags(["-lIOReport"])
            ]
        )
    ]
)
