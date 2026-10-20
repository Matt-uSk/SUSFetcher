import Foundation

enum CatalogError: Error {
    case http(Int)
    case invalidFormat

    /// Message traduit (la traduction dépend des réglages, donc du MainActor).
    @MainActor var message: String {
        switch self {
        case .http(let code):
            tr("Le serveur Apple a répondu HTTP \(code).", "Apple's server responded with HTTP \(code).")
        case .invalidFormat:
            tr("Le catalogue reçu n'est pas un plist valide.", "The catalog received is not a valid plist.")
        }
    }
}

/// Télécharge et parse le catalogue SUS, résout les métadonnées (.dist) avec un cache disque.
actor CatalogService {
    private let session: URLSession
    private let cacheURL: URL
    private var cache: [String: DistInfo] = [:]
    private var cacheLoaded = false
    private var dirty = false

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 12
        session = URLSession(configuration: config)

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SUSFetcher", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cacheURL = base.appending(path: "dist-cache.json")
    }

    // MARK: Catalogue

    /// Les catalogues bêta sont des sur-ensembles du catalogue public : on charge aussi le public
    /// pour marquer `isBeta` les produits qui n'existent que dans le canal bêta.
    func fetchCatalog(_ channel: CatalogChannel) async throws -> [SUProduct] {
        loadCacheIfNeeded()

        if channel == .release {
            return parse(try await fetchProducts(channel.url), releaseIDs: nil)
        }
        async let beta = fetchProducts(channel.url)
        async let release = fetchProducts(CatalogChannel.release.url)
        let (betaProducts, releaseProducts) = try await (beta, release)
        return parse(betaProducts, releaseIDs: Set(releaseProducts.keys))
    }

    private func fetchProducts(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CatalogError.http(http.statusCode)
        }
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = root as? [String: Any],
              let products = dict["Products"] as? [String: Any] else {
            throw CatalogError.invalidFormat
        }
        return products
    }

    private func parse(_ products: [String: Any], releaseIDs: Set<String>?) -> [SUProduct] {

        var result: [SUProduct] = []
        result.reserveCapacity(products.count)

        for (pid, value) in products {
            guard let p = value as? [String: Any] else { continue }

            let packages: [SUPackage] = (p["Packages"] as? [[String: Any]] ?? []).compactMap { d in
                guard let s = d["URL"] as? String, let url = URL(string: s) else { return nil }
                let size = (d["Size"] as? NSNumber)?.int64Value ?? 0
                return SUPackage(url: url, size: size)
            }
            guard !packages.isEmpty else { continue }

            let dists = p["Distributions"] as? [String: Any]
            let distString = (dists?["English"] as? String)
                ?? (dists?["en"] as? String)
                ?? (dists?.values.first as? String)

            let ext = p["ExtendedMetaInfo"] as? [String: Any]
            let isInstaller = ext?["InstallAssistantPackageIdentifiers"] != nil
                || packages.contains { $0.fileName == "InstallAssistant.pkg" }

            var product = SUProduct(
                id: pid,
                postDate: p["PostDate"] as? Date ?? .distantPast,
                packages: packages,
                distributionURL: distString.flatMap(URL.init(string:)),
                isInstaller: isInstaller
            )
            if let releaseIDs { product.isBeta = !releaseIDs.contains(pid) }
            if let cached = cache[pid] {
                product.apply(cached)
                product.metadataLoaded = true
            }
            result.append(product)
        }
        return result
    }

    // MARK: Métadonnées (.dist)

    func distInfo(for product: SUProduct) async -> DistInfo? {
        if let cached = cache[product.id] { return cached }
        guard let url = product.distributionURL,
              let result = try? await session.data(from: url) else { return nil }
        if let http = result.1 as? HTTPURLResponse, http.statusCode != 200 { return nil }

        let text = String(data: result.0, encoding: .utf8)
            ?? String(data: result.0, encoding: .isoLatin1)
            ?? ""
        let info = DistParser.parse(text)
        cache[product.id] = info
        dirty = true
        return info
    }

    func saveCache() {
        guard dirty, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        dirty = false
    }

    func clearCache() {
        cache = [:]
        dirty = false
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: DistInfo].self, from: data) {
            cache = decoded
        }
    }
}

/// Extraction titre / version / build depuis un fichier .dist Apple.
enum DistParser {
    static func parse(_ text: String) -> DistInfo {
        var info = DistInfo()

        info.title = match(#""SU_TITLE"\s*=\s*"([^"]+)""#, in: text)
        if info.title == nil,
           let t = match(#"<title>\s*([^<]+?)\s*</title>"#, in: text),
           t != "SU_TITLE" {
            info.title = t
        }

        info.version = match(#"<key>VERSION</key>\s*<string>([^<]+)</string>"#, in: text)
            ?? match(#""SU_VERS"\s*=\s*"([^"]+)""#, in: text)
            ?? match(#"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>"#, in: text)

        info.build = match(#"<key>BUILD</key>\s*<string>([^<]+)</string>"#, in: text)

        info.title = info.title.map(unescape)
        return info
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
