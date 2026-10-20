import Foundation
import Observation

@Observable
@MainActor
final class CatalogModel {
    private static let channelKey = "catalogChannel"

    var channel: CatalogChannel
    private(set) var products: [SUProduct] = []
    private(set) var isLoading = false
    private(set) var status: String?
    private(set) var errorMessage: String?
    private(set) var lastRefresh: Date?
    private(set) var catalogMajor: Int?
    private(set) var catalogURL: URL?

    @ObservationIgnored private let service = CatalogService()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var indexByID: [String: Int] = [:]

    init() {
        channel = UserDefaults.standard.string(forKey: Self.channelKey)
            .flatMap(CatalogChannel.init(rawValue:)) ?? .release
    }

    var installers: [SUProduct] { products.filter(\.isInstaller) }
    var others: [SUProduct] { products.filter { !$0.isInstaller } }

    func reload() {
        UserDefaults.standard.set(channel.rawValue, forKey: Self.channelKey)
        loadTask?.cancel()
        let channel = self.channel
        loadTask = Task { await load(channel) }
    }

    func clearCacheAndReload() {
        Task {
            await service.clearCache()
            reload()
        }
    }

    private func load(_ channel: CatalogChannel) async {
        isLoading = true
        errorMessage = nil
        status = tr("Téléchargement du catalogue \(channel.label)…", "Downloading \(channel.label) catalog…")

        do {
            let custom = AppSettings.shared.customCatalogURL
            let result = try await service.fetchCatalog(channel, customReleaseURL: custom)
            guard !Task.isCancelled else { return }
            let list = result.products
            catalogMajor = result.major
            catalogURL = result.url
            products = list
            indexByID = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) })
            lastRefresh = .now
            await resolveMissingMetadata()
        } catch {
            if !Task.isCancelled {
                errorMessage = (error as? CatalogError)?.message ?? error.localizedDescription
            }
        }

        if !Task.isCancelled {
            isLoading = false
            status = nil
        }
    }

    /// Récupère les .dist manquants (installers d'abord, puis les plus récents), 12 en parallèle.
    private func resolveMissingMetadata() async {
        let missing = products
            .filter { !$0.metadataLoaded && $0.distributionURL != nil }
            .sorted { a, b in
                if a.isInstaller != b.isInstaller { return a.isInstaller }
                return a.postDate > b.postDate
            }
        guard !missing.isEmpty else { return }

        let service = self.service
        let total = missing.count

        await withTaskGroup(of: (String, DistInfo?).self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<12 {
                guard let p = iterator.next() else { break }
                group.addTask { (p.id, await service.distInfo(for: p)) }
            }

            var done = 0
            var buffer: [(String, DistInfo)] = []

            while let result = await group.next() {
                done += 1
                if let info = result.1 { buffer.append((result.0, info)) }

                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if let p = iterator.next() {
                    group.addTask { (p.id, await service.distInfo(for: p)) }
                }
                if buffer.count >= 25 || done == total {
                    self.apply(buffer)
                    buffer.removeAll()
                }
                self.status = tr("Lecture des métadonnées \(done)/\(total)…", "Reading metadata \(done)/\(total)…")
            }
            if !buffer.isEmpty { self.apply(buffer) }
        }

        await service.saveCache()
    }

    private func apply(_ batch: [(String, DistInfo)]) {
        guard !Task.isCancelled, !batch.isEmpty else { return }
        var copy = products
        for (pid, info) in batch {
            guard let i = indexByID[pid], i < copy.count, copy[i].id == pid else { continue }
            copy[i].apply(info)
            copy[i].metadataLoaded = true
        }
        products = copy
    }
}
