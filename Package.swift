// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SUSFetcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SUSFetcher", path: "Sources/SUSFetcher")
    ]
)
