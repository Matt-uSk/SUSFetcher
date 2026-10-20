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

/// Construit les URLs du catalogue Apple. Aucune version n'est figée :
/// la dernière version majeure est détectée au lancement (cf. `CatalogService.resolve`).
enum CatalogLocator {
    /// Plus haute version connue à la compilation : simple point de départ de la détection.
    static let baselineMajor = 27
    /// Première version de la numérotation « année » (après macOS 15 vient macOS 26).
    static let firstYearMajor = 26
    /// Partie fixe de l'URL (versions historiques), identique depuis macOS 26.
    static let legacyTail =
        "15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard"

    static func url(_ channel: CatalogChannel, major: Int) -> URL {
        let majors = stride(from: major, through: firstYearMajor, by: -1).map(String.init).joined(separator: "-")
        let name = "index-\(channel.prefix(major: major))\(majors)-\(legacyTail).merged-1.sucatalog"
        return URL(string: "https://swscan.apple.com/content/catalogs/others/\(name)")!
    }
}

struct CatalogResult: Sendable {
    let products: [SUProduct]
    let major: Int?        // version majeure détectée (nil si URL personnalisée)
    let url: URL
}

/// Télécharge et parse le catalogue SUS, résout les métadonnées (.dist) avec un cache disque.
actor CatalogService {
    private let session: URLSession
    private var resolvedMajor: [CatalogChannel: Int] = [:]
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
    /// `customReleaseURL` (réglages) remplace l'URL détectée du catalogue public.
    func fetchCatalog(_ channel: CatalogChannel, customReleaseURL: URL?) async throws -> CatalogResult {
        loadCacheIfNeeded()

        let release: (url: URL, major: Int?)
        if let customReleaseURL {
            release = (customReleaseURL, nil)
        } else {
            let r = await resolve(.release)
            release = (r.url, r.major)
        }

        if channel == .release {
            let products = parse(try await fetchProducts(release.url), releaseIDs: nil)
            return CatalogResult(products: products, major: release.major, url: release.url)
        }

        let beta = await resolve(channel)
        async let betaProducts = fetchProducts(beta.url)
        async let releaseProducts = fetchProducts(release.url)
        let (b, r) = try await (betaProducts, releaseProducts)
        return CatalogResult(products: parse(b, releaseIDs: Set(r.keys)), major: beta.major, url: beta.url)
    }

    // MARK: Détection de la dernière version majeure

    /// Trouve la plus haute version majeure dont le catalogue existe pour ce canal.
    /// Point de départ : max(version connue, version du Mac, dernière détection), puis on teste
    /// N+1, N+2… jusqu'au premier 404. Résultat mémorisé (UserDefaults) pour les lancements suivants.
    func resolve(_ channel: CatalogChannel) async -> (url: URL, major: Int) {
        if let major = resolvedMajor[channel] {
            return (CatalogLocator.url(channel, major: major), major)
        }

        let key = "catalogMajor.\(channel.rawValue)"
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let remembered = UserDefaults.standard.integer(forKey: key)
        var major = max(CatalogLocator.baselineMajor, osMajor, remembered)

        // Point de départ inexistant (ex. Mac sur une bêta dont le catalogue n'est pas public) : on redescend.
        while major > CatalogLocator.baselineMajor, !(await exists(CatalogLocator.url(channel, major: major))) {
            major -= 1
        }
        // On monte tant qu'Apple publie un catalogue plus récent.
        while await exists(CatalogLocator.url(channel, major: major + 1)) {
            major += 1
        }

        resolvedMajor[channel] = major
        UserDefaults.standard.set(major, forKey: key)
        return (CatalogLocator.url(channel, major: major), major)
    }

    /// Teste l'existence d'un catalogue en ne demandant qu'un octet.
    private func exists(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 || http.statusCode == 206
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
        resolvedMajor = [:]
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
