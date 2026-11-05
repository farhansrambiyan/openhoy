// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenHoy",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "OpenHoy",
            path: "Sources/OpenHoy",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // Linked explicitly: AVPlayerView must be loadable at runtime for inline video.
                .linkedFramework("AVKit"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
