import Foundation
import Observation

/// Infos de sécurité et de compatibilité tirées de SOFA (Mac Admins Open Source, Apache 2.0) :
/// https://sofa.macadmins.io — failles corrigées par chaque version (CVE, exploitées ou non),
/// priorité de mise à jour, et versions de macOS supportées par chaque modèle de Mac.
///
/// - Lecture tolérante (JSONSerialization, tout est optionnel) : le schéma SOFA évolue souvent.
/// - `index.json` donne l'empreinte de chaque flux : on ne retélécharge un flux que s'il a changé.
/// - Un résumé compact est gardé en cache (Application Support) : l'app fonctionne hors ligne.
struct SOFARelease: Codable, Hashable, Sendable {
    let version: String
    let build: String?
    let allBuilds: [String]
    let releaseDate: Date?
    let securityInfo: URL?
    let cveCount: Int
    let exploited: [String]
    /// Failles exploitées dans d'autres produits (CISA KEV), pas sur Apple.
    let exploitedElsewhere: Int
    let priority: String?
    let summary: String?
    let recommendation: String?
    /// Identifiants concernés (vide = toute la plateforme).
    let supportedDevices: [String]

    var major: Int? { Int(version.split(separator: ".").first ?? "") }
    var exploitedOnApple: Int { max(0, exploited.count - exploitedElsewhere) }
}

struct SOFASnapshot: Codable, Sendable {
    var macReleases: [SOFARelease] = []
    var iosReleases: [SOFARelease] = []
    /// Identifiant de Mac → (nom commercial, versions majeures de macOS supportées).
    var macModels: [String: MacModel] = [:]
    /// Identifiant iPhone / iPad → nom commercial.
    var iosDevices: [String: String] = [:]
    var macHash: String?
    var iosHash: String?
    var fetched: Date?

    struct MacModel: Codable, Hashable, Sendable {
        let name: String
        let majors: [Int]
    }
}

enum SOFAPlatform { case macOS, iOS }

@Observable
@MainActor
final class SOFAModel {
    static let shared = SOFAModel()

    private(set) var snapshot = SOFASnapshot()
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    var enabled: Bool = UserDefaults.standard.object(forKey: "sofaEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "sofaEnabled")
            if enabled { refresh() }
        }
    }

    static let feedBase = URL(string: "https://sofafeed.macadmins.io/v2/")!
    static let website = URL(string: "https://sofa.macadmins.io")!

    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SUSFetcher", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appending(path: "sofa.json")
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(SOFASnapshot.self, from: data) {
            snapshot = decoded
        }
    }

    /// Rafraîchit au lancement puis toutes les 6 h (index léger, flux seulement s'ils ont changé).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func refresh() {
        guard enabled, !isRefreshing else { return }
        isRefreshing = true
        let current = snapshot
        Task {
            do {
                let updated = try await Task.detached(priority: .utility) { try await Self.fetch(current) }.value
                snapshot = updated
                lastError = nil
                if let data = try? JSONEncoder().encode(updated) { try? data.write(to: cacheURL, options: .atomic) }
            } catch {
                lastError = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    // MARK: Requêtes

    private func releases(_ platform: SOFAPlatform) -> [SOFARelease] {
        platform == .macOS ? snapshot.macReleases : snapshot.iosReleases
    }

    /// Version précise (build en priorité, sinon numéro de version).
    func release(_ platform: SOFAPlatform, version: String, build: String? = nil) -> SOFARelease? {
        guard enabled, !version.isEmpty else { return nil }
        let list = releases(platform)
        if let build, !build.isEmpty,
           let r = list.first(where: { $0.build == build || $0.allBuilds.contains(build) }) {
            return r
        }
        return list.first { $0.version == version }
    }

    /// Versions plus récentes de la même version majeure (celles qu'il manque à `version`),
    /// limitées à celles qui concernent `identifier` quand il est connu.
    func laterReleases(_ platform: SOFAPlatform, after version: String, identifier: String? = nil) -> [SOFARelease] {
        guard enabled, let major = Int(version.split(separator: ".").first ?? "") else { return [] }
        return releases(platform).filter { r in
            r.major == major
                && r.version.compare(version, options: .numeric) == .orderedDescending
                && (identifier == nil || r.supportedDevices.isEmpty || r.supportedDevices.contains(identifier!))
        }
    }

    /// Failles activement exploitées corrigées après `version` (même version majeure).
    func exploitedFixedLater(_ platform: SOFAPlatform, after version: String, identifier: String? = nil) -> (count: Int, fixedIn: String?) {
        let later = laterReleases(platform, after: version, identifier: identifier)
        let cves = Set(later.flatMap(\.exploited))
        let first = later.filter { !$0.exploited.isEmpty }
            .min { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
        return (cves.count, first?.version)
    }

    func iosMarketingName(_ identifier: String) -> String? {
        enabled ? snapshot.iosDevices[identifier] : nil
    }

    /// Ce modèle de Mac supporte-t-il cette version majeure ? nil = inconnu (modèle ou version absent du flux).
    func supports(model: String, major: Int) -> Bool? {
        guard enabled, let m = snapshot.macModels[model] else { return nil }
        let covered = Set(snapshot.macModels.values.flatMap(\.majors))
        guard covered.contains(major) else { return nil }
        return m.majors.contains(major)
    }

    func macModelName(_ identifier: String) -> String? { snapshot.macModels[identifier]?.name }

    /// Modèles de Mac connus, triés par nom commercial.
    struct MacModelEntry: Identifiable, Hashable { let id: String; let name: String }

    var macModelList: [MacModelEntry] {
        snapshot.macModels.map { MacModelEntry(id: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Identifiant de ce Mac (« Mac15,6 », « MacBookPro16,1 »).
    nonisolated static let thisMacModel: String? = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }()

    // MARK: Téléchargement

    nonisolated private static func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: feedBase.appending(path: path))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        r.setValue("SUSFetcher/\(version) (+https://github.com/Matt-uSk/SUSFetcher)", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 30
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    nonisolated private static func json(_ path: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return object
    }

    nonisolated private static func fetch(_ current: SOFASnapshot) async throws -> SOFASnapshot {
        var snap = current
        // Empreintes publiées : on évite de retélécharger un flux inchangé.
        var hashes: [String: String] = [:]
        if let index = try? await json("index.json"), let feeds = index["Feeds"] as? [[String: Any]] {
            for f in feeds {
                if let name = f["Name"] as? String, let hash = f["ContentHash"] as? String { hashes[name] = hash }
            }
        }
        let macHash = hashes["macos_data_feed"], iosHash = hashes["ios_data_feed"]

        if macHash == nil || macHash != snap.macHash || snap.macReleases.isEmpty {
            let feed = try await json("macos_data_feed.json")
            snap.macReleases = parseReleases(feed)
            snap.macModels = parseMacModels(feed)
            snap.macHash = macHash
        }
        if iosHash == nil || iosHash != snap.iosHash || snap.iosReleases.isEmpty {
            if let feed = try? await json("ios_data_feed.json") {
                snap.iosReleases = parseReleases(feed)
                snap.iosDevices = parseNames(feed["Devices"])
                snap.iosHash = iosHash
            }
        }
        snap.fetched = .now
        return snap
    }

    // MARK: Analyse (tolérante)

    nonisolated private static func parseReleases(_ feed: [String: Any]) -> [SOFARelease] {
        let iso = ISO8601DateFormatter()
        var seen = Set<String>()
        var out: [SOFARelease] = []
        for os in feed["OSVersions"] as? [[String: Any]] ?? [] {
            var list = os["SecurityReleases"] as? [[String: Any]] ?? []
            if let latest = os["Latest"] as? [String: Any] { list.insert(latest, at: 0) }
            for r in list {
                guard let version = r["ProductVersion"] as? String else { continue }
                let build = r["Build"] as? String
                let key = version + "|" + (build ?? "")
                guard seen.insert(key).inserted else { continue }
                let summary = r["UpdateSummary"] as? [String: Any]
                let stats = summary?["Stats"] as? [String: Any]
                let dateString = (r["ReleaseDate"] as? String) ?? ""
                out.append(SOFARelease(
                    version: version,
                    build: build,
                    allBuilds: r["AllBuilds"] as? [String] ?? [],
                    releaseDate: iso.date(from: dateString) ?? iso.date(from: dateString + "T00:00:00Z"),
                    securityInfo: (r["SecurityInfo"] as? String).flatMap(URL.init(string:)),
                    cveCount: (r["UniqueCVEsCount"] as? Int) ?? (r["CVEs"] as? [String: Any])?.count ?? 0,
                    exploited: r["ActivelyExploitedCVEs"] as? [String] ?? [],
                    exploitedElsewhere: stats?["ExploitedElsewhere"] as? Int ?? 0,
                    priority: summary?["Priority"] as? String,
                    summary: summary?["Summary"] as? String,
                    recommendation: summary?["Recommendation"] as? String,
                    supportedDevices: r["SupportedDevices"] as? [String] ?? []))
            }
        }
        return out
    }

    nonisolated private static func parseMacModels(_ feed: [String: Any]) -> [String: SOFASnapshot.MacModel] {
        var out: [String: SOFASnapshot.MacModel] = [:]
        for (id, value) in feed["Models"] as? [String: Any] ?? [:] {
            guard let m = value as? [String: Any] else { continue }
            let majors = (m["OSVersions"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
            out[id] = .init(name: (m["MarketingName"] as? String) ?? id, majors: majors)
        }
        return out
    }

    nonisolated private static func parseNames(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (id, v) in value as? [String: Any] ?? [:] {
            if let name = (v as? [String: Any])?["MarketingName"] as? String { out[id] = name }
        }
        return out
    }
}
