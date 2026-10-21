import AppKit
import Foundation
import Observation
import SwiftUI

/// « Télécharger les dernières versions » d'une collection : résout la dernière version de chaque
/// élément, montre un récapitulatif (taille, fichiers déjà présents, espace disque) avant de lancer.
@Observable
@MainActor
final class BulkPlan {
    enum Kind {
        case installer(SUProduct)
        case package(SUPackage, SUProduct)
        case ipsw(IPSWFirmware, IPSWDevice)
    }

    struct Entry: Identifiable {
        let id = UUID()
        var label: String
        let icon: String
        let version: String
        let fileName: String
        let size: Int64
        let url: URL?
        let kind: Kind?          // nil : rien trouvé pour cet élément
        let existing: URL?       // déjà présent dans le dossier de destination
        var note: String?
    }

    let collectionName: String
    private(set) var entries: [Entry] = []
    private(set) var isLoading = true
    var includeExisting = false

    init(collectionName: String) { self.collectionName = collectionName }

    // MARK: Résumé

    var toDownload: [Entry] {
        entries.filter { $0.kind != nil && (includeExisting || $0.existing == nil) }
    }
    var totalBytes: Int64 { toDownload.reduce(0) { $0 + $1.size } }
    var existingCount: Int { entries.filter { $0.kind != nil && $0.existing != nil }.count }
    var missingCount: Int { entries.filter { $0.kind == nil }.count }

    var availableBytes: Int64? {
        let folder = DownloadManager.shared.destinationFolder
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var hasEnoughSpace: Bool {
        guard let available = availableBytes else { return true }
        return available > totalBytes
    }

    // MARK: Résolution

    private(set) var identifyingLocalFiles = false

    /// Résout les éléments, puis attend l'identification des fichiers locaux (empreintes)
    /// et recommence pour que les fichiers renommés soient bien reconnus comme présents.
    func build(from collection: ItemCollection) async {
        entries = await resolve(collection)
        try? await Task.sleep(for: .milliseconds(300))      // laisse démarrer les calculs d'empreinte
        if LocalFiles.shared.hashingCount > 0 {
            identifyingLocalFiles = true
            while LocalFiles.shared.hashingCount > 0 {
                try? await Task.sleep(for: .milliseconds(500))
            }
            identifyingLocalFiles = false
            entries = await resolve(collection)
        }
        isLoading = false
    }

    private func resolve(_ collection: ItemCollection) async -> [Entry] {
        let downloads = DownloadManager.shared
        let catalog = CatalogModel.shared
        var result: [Entry] = []
        var indexByURL: [URL: Int] = [:]

        func add(_ entry: Entry) {
            // Un même fichier (ex. IPSW universel Mac) n'est listé qu'une fois.
            if let url = entry.url, let i = indexByURL[url] {
                result[i].label += ", " + entry.label
                return
            }
            if let url = entry.url { indexByURL[url] = result.count }
            result.append(entry)
        }

        for item in collection.items {
            switch item {
            case .catalog(let title, _):
                let candidates = catalog.products.filter { $0.displayTitle == title }
                guard let latest = candidates.max(by: { a, b in
                    let order = a.versionString.compare(b.versionString, options: .numeric)
                    return order == .orderedSame ? a.postDate < b.postDate : order == .orderedAscending
                }) else {
                    add(Entry(label: title, icon: item.icon, version: "", fileName: "", size: 0, url: nil,
                              kind: nil, existing: nil,
                              note: tr("Absent du catalogue chargé", "Not in the loaded catalog")))
                    continue
                }
                if let pkg = latest.installAssistant {
                    add(Entry(label: title, icon: item.icon, version: latest.versionString,
                              fileName: downloads.installerDestination(latest).lastPathComponent,
                              size: pkg.size, url: pkg.url, kind: .installer(latest),
                              existing: downloads.existingInstaller(latest), note: nil))
                } else {
                    for pkg in latest.packages {
                        add(Entry(label: title, icon: item.icon, version: latest.versionString,
                                  fileName: pkg.fileName, size: pkg.size, url: pkg.url,
                                  kind: .package(pkg, latest),
                                  existing: downloads.existingPackage(pkg, of: latest), note: nil))
                    }
                }

            case .device(let identifier, let name):
                let device = IPSWDevice(name: name, identifier: identifier)
                let firmwares = await IPSWModel.shared.ensureFirmwares(identifier)
                let byDate = firmwares.sorted { $0.sortDate > $1.sortDate }
                guard let latest = byDate.first(where: \.signed) ?? byDate.first else {
                    add(Entry(label: name, icon: item.icon, version: "", fileName: "", size: 0, url: nil,
                              kind: nil, existing: nil,
                              note: tr("Aucun firmware trouvé", "No firmware found")))
                    continue
                }
                add(Entry(label: name, icon: item.icon, version: "\(latest.version) (\(latest.build))",
                          fileName: latest.fileName, size: latest.size, url: latest.url,
                          kind: .ipsw(latest, device), existing: downloads.existingIPSW(latest),
                          note: latest.signed ? nil : tr("Plus signé par Apple", "No longer signed by Apple")))
            }
        }
        return result
    }

    // MARK: Lancement

    func start() {
        let downloads = DownloadManager.shared
        for entry in toDownload {
            switch entry.kind {
            case .installer(let product)?: downloads.downloadInstaller(product)
            case .package(let pkg, let product)?: downloads.download(pkg, of: product)
            case .ipsw(let firmware, let device)?: downloads.downloadIPSW(firmware, device: device)
            case nil: break
            }
        }
        if !toDownload.isEmpty { ViewState.shared.showDownloads() }
    }
}

// MARK: - Fenêtre

@MainActor
final class BulkDownloadWindow {
    static let shared = BulkDownloadWindow()
    private var window: NSWindow?

    func show(_ collection: ItemCollection) {
        window?.close()
        let plan = BulkPlan(collectionName: collection.name)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = tr("Télécharger les dernières versions", "Download Latest Versions")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: BulkDownloadView(plan: plan) { [weak self] in
            self?.window?.close()
            self?.window = nil
        })
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await plan.build(from: collection) }
    }
}

struct BulkDownloadView: View {
    let plan: BulkPlan
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.collectionName).font(.title3.weight(.semibold))
                Text(tr("Dernière version de chaque élément de la collection",
                        "Latest version of each item in the collection"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if plan.isLoading {
                ProgressView(plan.identifyingLocalFiles
                             ? tr("Identification des fichiers déjà présents (empreintes)…",
                                  "Identifying files already present (checksums)…")
                             : tr("Recherche des dernières versions…", "Looking up the latest versions…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(plan.entries) { entry in
                    BulkEntryRow(entry: entry, willDownload: willDownload(entry))
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

                if plan.existingCount > 0 {
                    Toggle(tr("Retélécharger aussi les fichiers déjà présents (\(plan.existingCount))",
                              "Also download files already present (\(plan.existingCount))"),
                           isOn: Binding(plan, \.includeExisting))
                }
                summary
            }

            HStack {
                Spacer()
                Button(tr("Annuler", "Cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                Button(downloadTitle) {
                    plan.start()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isLoading || plan.toDownload.isEmpty || !plan.hasEnoughSpace)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 380)
        .environment(\.locale, AppSettings.shared.locale)
    }

    private func willDownload(_ entry: BulkPlan.Entry) -> Bool {
        entry.kind != nil && (plan.includeExisting || entry.existing == nil)
    }

    private var downloadTitle: String {
        let n = plan.toDownload.count
        guard n > 0 else { return tr("Rien à télécharger", "Nothing to download") }
        return tr("Télécharger \(n) fichier\(n > 1 ? "s" : "") (\(formatBytes(plan.totalBytes)))",
                  "Download \(n) file\(n > 1 ? "s" : "") (\(formatBytes(plan.totalBytes)))")
    }

    private var summaryParts: [String] {
        var p = [tr("\(plan.toDownload.count) à télécharger", "\(plan.toDownload.count) to download")
                 + " (\(formatBytes(plan.totalBytes)))"]
        if plan.existingCount > 0 {
            p.append(tr("\(plan.existingCount) déjà présent(s)", "\(plan.existingCount) already present"))
        }
        if plan.missingCount > 0 {
            p.append(tr("\(plan.missingCount) introuvable(s)", "\(plan.missingCount) not found"))
        }
        return p
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summaryParts.joined(separator: " · ")).font(.callout)

            if !plan.hasEnoughSpace, let available = plan.availableBytes {
                Label(tr("Espace insuffisant : \(formatBytes(available)) libres dans le dossier de destination.",
                         "Not enough space: \(formatBytes(available)) free in the destination folder."),
                      systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
            } else if plan.totalBytes > 20_000_000_000 {
                Label(tr("Téléchargement volumineux (\(formatBytes(plan.totalBytes))).",
                         "Large download (\(formatBytes(plan.totalBytes)))."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            if let available = plan.availableBytes {
                Text(tr("Espace libre : ", "Free space: ") + formatBytes(available)
                     + " — " + DownloadManager.shared.destinationFolder.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

struct BulkEntryRow: View {
    let entry: BulkPlan.Entry
    let willDownload: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.label).fontWeight(.medium).lineLimit(1)
                    if !entry.version.isEmpty {
                        Text(entry.version).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if !entry.fileName.isEmpty {
                    Text(entry.fileName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if let existing = entry.existing, existing.lastPathComponent != entry.fileName {
                    Text(tr("Présent sous le nom : ", "Present as: ") + existing.lastPathComponent)
                        .font(.caption).foregroundStyle(.green).lineLimit(1)
                }
                if let note = entry.note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if entry.size > 0 {
                Text(formatBytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            status.frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(willDownload || entry.kind == nil ? 1 : 0.6)
    }

    @ViewBuilder
    private var status: some View {
        if entry.kind == nil {
            Label(tr("Introuvable", "Not found"), systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        } else if entry.existing != nil && !willDownload {
            Label(tr("Déjà présent", "Already here"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if entry.existing != nil {
            Label(tr("Retéléchargé", "Re-download"), systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
        } else {
            Label(tr("À télécharger", "To download"), systemImage: "arrow.down.circle")
                .foregroundStyle(.tint)
        }
    }
}
