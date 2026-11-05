import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Synchronisation automatique des collections : à intervalle régulier, recharge le catalogue et
/// les firmwares, télécharge la dernière version de chaque élément, et (option) met à la Corbeille
/// les anciennes versions **que la synchro a elle-même téléchargées**.
///
/// Garde-fous de la suppression :
/// - seuls les fichiers enregistrés dans le manifeste de la synchro sont concernés (jamais ceux de l'utilisateur) ;
/// - uniquement quand la nouvelle version est présente sur le disque et vérifiée (empreinte) ;
/// - jamais un fichier qui est la version actuelle d'un autre élément synchronisé (ex. IPSW Mac universel) ;
/// - mise à la Corbeille, pas de suppression définitive.
@Observable
@MainActor
final class AutoSync {
    static let shared = AutoSync()

    enum Frequency: Int, CaseIterable, Identifiable {
        case hourly = 3600, sixHours = 21_600, twelveHours = 43_200, daily = 86_400, weekly = 604_800
        var id: Int { rawValue }
        var interval: TimeInterval { TimeInterval(rawValue) }

        @MainActor var label: String {
            switch self {
            case .hourly: tr("Toutes les heures", "Every hour")
            case .sixHours: tr("Toutes les 6 heures", "Every 6 hours")
            case .twelveHours: tr("Toutes les 12 heures", "Every 12 hours")
            case .daily: tr("Une fois par jour", "Once a day")
            case .weekly: tr("Une fois par semaine", "Once a week")
            }
        }
    }

    private enum Key {
        static let frequency = "autoSyncFrequency"
        static let deleteOld = "autoSyncDeleteOld"
        static let lastSync = "autoSyncLast"
    }

    var frequency: Frequency = Frequency(rawValue: UserDefaults.standard.integer(forKey: Key.frequency)) ?? .daily {
        didSet { UserDefaults.standard.set(frequency.rawValue, forKey: Key.frequency) }
    }

    var deleteOldVersions: Bool = UserDefaults.standard.bool(forKey: Key.deleteOld) {
        didSet {
            UserDefaults.standard.set(deleteOldVersions, forKey: Key.deleteOld)
            if deleteOldVersions { pruneAll() }
        }
    }

    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: Key.lastSync) as? Date
    private(set) var isSyncing = false
    private(set) var lastSummary: String?
    private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private var timer: Timer?
    /// Téléchargements lancés par la synchro : URL source → clés d'éléments (« collection|élément »).
    @ObservationIgnored private var pending: [URL: [String]] = [:]
    @ObservationIgnored private var manifest = Manifest.load()

    var hasSyncedCollections: Bool { CollectionsStore.shared.collections.contains(where: \.autoSync) }

    var nextSync: Date? {
        guard hasSyncedCollections else { return nil }
        return (lastSync ?? .distantPast).addingTimeInterval(frequency.interval)
    }

    // MARK: Planification

    /// Appelé au lancement : vérifie toutes les minutes si une synchro est due.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AutoSync.shared.tick() }
        }
        // Premier passage un peu après le lancement (le catalogue se charge déjà).
        Task {
            try? await Task.sleep(for: .seconds(20))
            tick()
        }
    }

    func tick() {
        guard !isSyncing, let next = nextSync, next <= .now else { return }
        Task { await sync() }
    }

    // MARK: Synchronisation

    /// Synchronise toutes les collections en mode auto, ou une seule (`only`).
    func sync(only collectionID: UUID? = nil) async {
        guard !isSyncing else { return }
        let targets = CollectionsStore.shared.collections.filter {
            $0.autoSync && (collectionID == nil || $0.id == collectionID)
        }
        guard !targets.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }

        await CatalogModel.shared.refresh()
        LocalFiles.shared.rescan()

        var lines: [String] = []
        var started = 0
        for collection in targets {
            for item in collection.items {
                if case .device(let identifier, _) = item {
                    await IPSWModel.shared.refreshFirmwares(identifier)
                }
            }
            let plan = BulkPlan(collectionName: collection.name)
            await plan.build(from: collection)

            for entry in plan.entries where entry.kind != nil {
                let keys = entry.itemIDs.map { Self.key(collection.id, $0) }
                if let existing = entry.existing, !plan.toDownload.contains(where: { $0.id == entry.id }) {
                    // Dernière version déjà présente : elle devient la version de référence.
                    for k in keys { manifest.latestPath[k] = existing.path }
                } else if let url = entry.url {
                    pending[url, default: []].append(contentsOf: keys)
                }
            }
            let count = plan.toDownload.count
            plan.start(showDownloads: false)
            started += count
            if count > 0 {
                lines.append(tr("\(collection.name) : \(count) nouvelle(s) version(s) (\(formatBytes(plan.totalBytes)))",
                                "\(collection.name): \(count) new version(s) (\(formatBytes(plan.totalBytes)))"))
            }
        }
        manifest.save()

        if collectionID == nil {
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: Key.lastSync)
        }
        lastSummary = started == 0
            ? tr("Tout est à jour.", "Everything is up to date.")
            : lines.joined(separator: "\n")
        if started > 0 {
            notify(title: tr("Synchronisation SUS Fetcher", "SUS Fetcher sync"), body: lines.joined(separator: "\n"))
        }
        pruneAll()
    }

    // MARK: Fin des téléchargements (appelé par DownloadManager)

    /// `ok` : téléchargement terminé et empreinte vérifiée (ou pas d'empreinte à vérifier).
    func downloadFinished(source: URL, file: URL, ok: Bool) {
        guard let keys = pending.removeValue(forKey: source) else { return }
        guard ok else { return }   // fichier corrompu : on ne touche pas aux anciennes versions
        for k in keys {
            manifest.records[k, default: []].removeAll { $0 == file.path }
            manifest.records[k, default: []].append(file.path)
            manifest.latestPath[k] = file.path
        }
        manifest.save()
        for key in keys { prune(key) }
    }

    func downloadFailed(source: URL) {
        pending.removeValue(forKey: source)
    }

    // MARK: Anciennes versions

    private func pruneAll() {
        for key in Array(manifest.latestPath.keys) { prune(key) }
    }

    private func prune(_ key: String) {
        guard deleteOldVersions,
              let latest = manifest.latestPath[key],
              FileManager.default.fileExists(atPath: latest),
              let records = manifest.records[key] else { return }

        // Fichiers qui sont la version actuelle d'un élément synchronisé : intouchables.
        let protected = Set(manifest.latestPath.values)
        var kept: [String] = []
        var trashed = 0
        for path in records {
            if path == latest || protected.contains(path) || !FileManager.default.fileExists(atPath: path) {
                if FileManager.default.fileExists(atPath: path) { kept.append(path) }
                continue
            }
            if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil {
                trashed += 1
            } else {
                kept.append(path)
            }
        }
        manifest.records[key] = kept
        manifest.save()
        if trashed > 0 { LocalFiles.shared.rescan() }
    }

    private static func key(_ collection: UUID, _ item: String) -> String { "\(collection.uuidString)|\(item)" }

    // MARK: Ouverture à la connexion

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("Impossible de modifier l'ouverture à la connexion", "Could not change Open at Login")
            alert.informativeText = error.localizedDescription
            _ = alert.runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Notifications

    private var notificationsAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Manifeste (fichiers téléchargés par la synchro)

    private struct Manifest: Codable {
        /// clé d'élément → chemins des fichiers que la synchro a téléchargés pour lui
        var records: [String: [String]] = [:]
        /// clé d'élément → chemin de la version actuelle
        var latestPath: [String: String] = [:]

        private static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "SUSFetcher/sync-manifest.json")
        }

        static func load() -> Manifest {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else { return Manifest() }
            return decoded
        }

        func save() {
            if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
        }
    }
}

/// Onglet « Synchronisation » des réglages.
struct AutoSyncSettingsSection: View {
    let sync: AutoSync

    var body: some View {
        Section {
            Picker(tr("Fréquence", "Frequency"), selection: Binding(sync, \.frequency)) {
                ForEach(AutoSync.Frequency.allCases) { Text($0.label).tag($0) }
            }
            Toggle(isOn: Binding(sync, \.deleteOldVersions)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Supprimer les anciennes versions", "Delete old versions"))
                    Text(tr("Mises à la Corbeille, une fois la nouvelle version téléchargée et vérifiée. Seuls les fichiers téléchargés par la synchronisation sont concernés.",
                            "Moved to the Trash once the new version is downloaded and verified. Only files downloaded by sync are affected."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { sync.launchAtLogin }, set: { sync.setLaunchAtLogin($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Ouvrir SUS Fetcher à l'ouverture de session", "Open SUS Fetcher at login"))
                    Text(tr("La synchronisation ne tourne que lorsque l'app est ouverte.",
                            "Sync only runs while the app is open."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(tr("Synchronisation automatique", "Automatic sync"))
        } footer: {
            Text(tr("Active la synchronisation par collection : clic droit sur le titre d'une collection › Synchronisation automatique.",
                    "Enable sync per collection: right-click a collection's title › Automatic Sync."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(tr("État", "Status")) {
            let synced = CollectionsStore.shared.collections.filter(\.autoSync)
            LabeledContent(tr("Collections synchronisées", "Synced collections")) {
                Text(synced.isEmpty ? tr("Aucune", "None") : synced.map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            LabeledContent(tr("Dernière synchronisation", "Last sync")) {
                Text(sync.lastSync.map(format) ?? "—").foregroundStyle(.secondary)
            }
            LabeledContent(tr("Prochaine synchronisation", "Next sync")) {
                Text(sync.nextSync.map { $0 <= .now ? tr("Dès que possible", "As soon as possible") : format($0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            if let summary = sync.lastSummary {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if sync.isSyncing {
                    ProgressView().controlSize(.small)
                    Text(tr("Synchronisation…", "Syncing…")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("Synchroniser maintenant", "Sync Now")) { Task { await sync.sync() } }
                    .disabled(sync.isSyncing || synced.isEmpty)
            }
        }
    }

    private func format(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppSettings.shared.locale))
    }
}
