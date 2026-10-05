// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OnlyWallpapers",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OnlyWallpapers",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
