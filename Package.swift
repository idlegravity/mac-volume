// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacVolume",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "MacVolume", path: "Sources/MacVolume")
    ]
)
