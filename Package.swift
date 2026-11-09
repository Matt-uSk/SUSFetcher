// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SUSFetcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SUSFetcher", path: "Sources/SUSFetcher"),
        // Outil DFU (Apache-2.0, cf. ThirdParty/macvdmtool) : lancé en root par l'app.
        .executableTarget(
            name: "macvdmtool",
            path: "Sources/macvdmtool",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
    ],
    cxxLanguageStandard: .cxx14
)
