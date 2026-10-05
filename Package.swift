// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OnlyWallpapers",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OnlyWallpapers",
            exclude: ["web"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
