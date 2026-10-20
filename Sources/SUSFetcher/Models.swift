import Foundation

/// Canal du catalogue Apple Software Update.
/// Pour une future version majeure (macOS 28…), il suffit d'ajouter "28-" en tête de `CatalogChannel.versions`
/// et de changer `CatalogChannel.latestMajor`.
enum CatalogChannel: String, CaseIterable, Identifiable, Sendable {
    case release
    case publicBeta
    case developerSeed
    case customerSeed

    static let latestMajor = "27"
    static let versions = "27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard"

    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .release: tr("Public", "Public")
        case .publicBeta: tr("Bêta publique", "Public beta")
        case .developerSeed: tr("Bêta développeur", "Developer beta")
        case .customerSeed: "AppleSeed (customer)"
        }
    }

    var url: URL {
        let prefix: String
        switch self {
        case .release: prefix = ""
        case .publicBeta: prefix = "\(Self.latestMajor)beta-"
        case .developerSeed: prefix = "\(Self.latestMajor)seed-"
        case .customerSeed: prefix = "\(Self.latestMajor)customerseed-"
        }
        return URL(string: "https://swscan.apple.com/content/catalogs/others/index-\(prefix)\(Self.versions).merged-1.sucatalog")!
    }
}

struct SUPackage: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    var id: URL { url }
    var fileName: String { url.lastPathComponent }
}

/// Infos extraites du fichier .dist d'un produit (mises en cache sur disque).
struct DistInfo: Codable, Hashable, Sendable {
    var title: String?
    var version: String?
    var build: String?
}

struct SUProduct: Identifiable, Hashable, Sendable {
    let id: String              // Product ID, ex. 142-27431
    let postDate: Date
    let packages: [SUPackage]
    let distributionURL: URL?
    let isInstaller: Bool       // possède InstallAssistantPackageIdentifiers
    var isBeta = false          // présent dans le canal bêta mais absent du catalogue public
    var title: String?
    var version: String?
    var build: String?
    var metadataLoaded = false

    var displayTitle: String {
        if let title { return title }
        if let first = packages.first {
            return (first.fileName as NSString).deletingPathExtension
        }
        return id
    }
    var versionString: String { version ?? "" }
    var buildString: String { build ?? "" }
    var totalSize: Int64 { packages.reduce(0) { $0 + $1.size } }

    var installAssistant: SUPackage? {
        packages.first { $0.fileName == "InstallAssistant.pkg" }
    }

    /// Nom du fichier final selon le modèle choisi dans les réglages,
    /// ex. InstallermacOSTahoe-26.7.1.pkg
    func installAssistantFileName(template: String) -> String {
        InstallerFileName.make(template: template, title: title, version: version, build: build, id: id)
    }

    mutating func apply(_ info: DistInfo) {
        title = info.title ?? title
        version = info.version ?? version
        build = info.build ?? build
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
