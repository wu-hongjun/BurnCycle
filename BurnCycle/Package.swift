// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurnCycle",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BurnCycle",
            path: "BurnCycle",
            exclude: ["Info.plist", "Assets.xcassets", "Resources", "BurnCycle.entitlements"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                // Links the private IOReport framework, used for live GPU/CPU
                // utilization stats (same approach as mactop). It has no public
                // headers, so SwiftPM cannot resolve it via .linkedFramework;
                // .unsafeFlags is required to pass -lIOReport to the linker.
                // Apple Silicon / macOS only — the build is already constrained
                // to that in README and platforms above.
                .unsafeFlags(["-lIOReport"])
            ]
        )
    ]
)
