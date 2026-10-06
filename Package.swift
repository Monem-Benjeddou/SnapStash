// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SnapStash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SnapStash", path: "Sources/SnapStash")
    ]
)
