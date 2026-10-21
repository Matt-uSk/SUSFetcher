import Foundation

/// Canal du catalogue Apple Software Update.
/// L'URL n'est pas codée en dur : voir `CatalogLocator`, qui détecte la dernière version majeure.
enum CatalogChannel: String, CaseIterable, Identifiable, Sendable {
    case release
    case publicBeta
    case developerSeed
    case customerSeed

    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .release: tr("Public", "Public")
        case .publicBeta: tr("Bêta publique", "Public beta")
        case .developerSeed: tr("Bêta développeur", "Developer beta")
        case .customerSeed: "AppleSeed (customer)"
        }
    }

    /// Préfixe de l'URL du canal pour une version majeure donnée (ex. "27seed-").
    func prefix(major: Int) -> String {
        switch self {
        case .release: ""
        case .publicBeta: "\(major)beta-"
        case .developerSeed: "\(major)seed-"
        case .customerSeed: "\(major)customerseed-"
        }
    }
}

struct SUPackage: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    var sha1: String? = nil      // « Digest » du catalogue Apple
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
