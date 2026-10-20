import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case installers, others, iphone, ipad, mac, downloads
    var id: String { rawValue }

    static let catalogItems: [SidebarItem] = [.installers, .others]
    static let ipswItems: [SidebarItem] = [.iphone, .ipad, .mac]

    var isCatalog: Bool { self == .installers || self == .others }

    var ipswFamily: IPSWFamily? {
        switch self {
        case .iphone: .iPhone
        case .ipad: .iPad
        case .mac: .mac
        default: nil
        }
    }

    @MainActor var title: String {
        switch self {
        case .installers: tr("Installers macOS", "macOS Installers")
        case .others: tr("Autres", "Other")
        case .downloads: tr("Téléchargements", "Downloads")
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .mac: tr("Mac (Apple Silicon)", "Mac (Apple Silicon)")
        }
    }

    var icon: String {
        switch self {
        case .installers: "laptopcomputer.and.arrow.down"
        case .others: "shippingbox"
        case .downloads: "arrow.down.circle"
        case .iphone: "iphone"
        case .ipad: "ipad"
        case .mac: "laptopcomputer"
        }
    }
}

/// État d'UI de la fenêtre principale (remplace les @State, cf. SUSFetcherApp).
@Observable
@MainActor
final class ViewState {
    static let shared = ViewState()

    var sidebar: SidebarItem? = .installers
    var search = ""
    var selection = Set<SUProduct.ID>()
    var sortOrder = [KeyPathComparator(\SUProduct.postDate, order: .reverse)]
    var betaOnly = true

    func showDownloads() {
        sidebar = .downloads
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

extension Binding {
    /// Binding vers une propriété d'un objet (remplace $state / @Bindable).
    init<Root: AnyObject>(_ root: Root, _ keyPath: ReferenceWritableKeyPath<Root, Value>) {
        self.init(get: { root[keyPath: keyPath] }, set: { root[keyPath: keyPath] = $0 })
    }
}

struct ContentView: View {
    let catalog: CatalogModel
    let downloads: DownloadManager
    let state: ViewState

    private var sidebar: SidebarItem? { state.sidebar }
    private var search: String { state.search }
    private var sortOrder: [KeyPathComparator<SUProduct>] { state.sortOrder }

    var body: some View {
        NavigationSplitView {
            sidebarList
        } detail: {
            detail
        }
        .searchable(text: Binding(state, \.search), placement: .toolbar,
                    prompt: searchPrompt)
        .toolbar { toolbarContent }
        .task {
            if catalog.products.isEmpty { catalog.reload() }
            IPSWModel.shared.loadDevicesIfNeeded()
        }
        .onChange(of: catalog.channel) { catalog.reload() }
        .onChange(of: state.sidebar) { state.selection.removeAll() }
        .environment(\.locale, AppSettings.shared.locale)
    }

    private var sidebarList: some View {
        List(selection: Binding(state, \.sidebar)) {
            Section(tr("Catalogue", "Catalog")) {
                ForEach(SidebarItem.catalogItems) { item in
                    SidebarRow(item: item, count: count(for: item))
                        .tag(item)
                }
            }
            Section(tr("Firmwares (IPSW)", "Firmwares (IPSW)")) {
                ForEach(SidebarItem.ipswItems) { item in
                    SidebarRow(item: item, count: count(for: item))
                        .tag(item)
                }
            }
            Section(tr("Activité", "Activity")) {
                SidebarRow(item: .downloads, count: downloads.pendingCount)
                    .tag(SidebarItem.downloads)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarDownloadsMonitor(downloads: downloads) { state.showDownloads() }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }

    @ViewBuilder
    private var detail: some View {
        if sidebar == .downloads {
            DownloadsPane(downloads: downloads, search: search)
        } else if let family = sidebar?.ipswFamily {
            IPSWPane(family: family, model: IPSWModel.shared, downloads: downloads, search: search)
                .id(family)
        } else {
            catalogDetail
        }
    }

    private var catalogDetail: some View {
        ProductTable(products: rows,
                     downloads: downloads,
                     selection: Binding(state, \.selection),
                     sortOrder: Binding(state, \.sortOrder))
            .overlay { placeholder }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(catalog: catalog, downloads: downloads)
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
            ToolbarItem {
                // Menu plutôt que Picker(.menu) : dans la toolbar macOS 26+, le Picker
                // n'affiche que les chevrons, sans la valeur sélectionnée.
                Menu {
                    Picker(tr("Canal", "Channel"), selection: Binding(catalog, \.channel)) {
                        ForEach(CatalogChannel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    // Un seul Text : la toolbar ne garde que le premier Text d'un HStack.
                    Text(tr("Canal : ", "Channel: ") + catalog.channel.label)
                        .fixedSize()
                }
                .menuIndicator(.visible)
                .fixedSize()
                .disabled(!(sidebar?.isCatalog ?? true))
                .help(tr("Canal du catalogue Apple", "Apple catalog channel"))
            }
            ToolbarItem {
                Toggle(isOn: Binding(state, \.betaOnly)) {
                    Label(tr("Bêtas uniquement", "Betas only"), systemImage: "testtube.2")
                }
                .toggleStyle(.button)
                .disabled(catalog.channel == .release || !(sidebar?.isCatalog ?? true))
                .help(catalog.channel == .release
                      ? tr("Choisir un canal bêta pour filtrer les bêtas", "Pick a beta channel to filter betas")
                      : tr("N'afficher que les produits absents du catalogue public",
                           "Only show products missing from the public catalog"))
            }
            ToolbarItem {
                Button { catalog.reload() } label: {
                    Label(tr("Recharger", "Reload"), systemImage: "arrow.clockwise")
                }
                .disabled(catalog.isLoading)
            }
            ToolbarItem {
                Button { chooseFolder(for: downloads) } label: {
                    Label(tr("Dossier de destination", "Destination folder"), systemImage: "folder.badge.gearshape")
                }
                .help(tr("Destination : ", "Destination: ") + downloads.destinationFolder.path)
            }
    }

    private var searchPrompt: String {
        switch sidebar {
        case .downloads?: tr("Nom du fichier, produit…", "File name, product…")
        case .iphone?, .ipad?, .mac?: tr("Modèle ou identifiant…", "Model or identifier…")
        default: tr("Titre, version, build, ID…", "Title, version, build, ID…")
        }
    }

    /// Sur un canal bêta, ne garder (par défaut) que les produits absents du catalogue public.
    private func visible(_ list: [SUProduct]) -> [SUProduct] {
        guard catalog.channel != .release, state.betaOnly else { return list }
        return list.filter(\.isBeta)
    }

    private var rows: [SUProduct] {
        let base = visible(sidebar == .others ? catalog.others : catalog.installers)
        let q = search.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? base : base.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q)
                || $0.versionString.localizedCaseInsensitiveContains(q)
                || $0.buildString.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
        }
        return filtered.sorted(using: sortOrder)
    }

    private func count(for item: SidebarItem) -> Int {
        switch item {
        case .installers: visible(catalog.installers).count
        case .others: visible(catalog.others).count
        case .downloads: downloads.pendingCount
        case .iphone, .ipad, .mac:
            item.ipswFamily.map { IPSWModel.shared.count($0) } ?? 0
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if catalog.products.isEmpty {
            if catalog.isLoading {
                ProgressView(catalog.status ?? tr("Chargement…", "Loading…"))
            } else if let error = catalog.errorMessage {
                ContentUnavailableView {
                    Label(tr("Catalogue indisponible", "Catalog unavailable"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(tr("Réessayer", "Retry")) { catalog.reload() }
                }
            }
        } else if rows.isEmpty, !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if rows.isEmpty, catalog.channel != .release, state.betaOnly, !catalog.isLoading {
            ContentUnavailableView {
                Label(tr("Aucune bêta dans ce canal", "No beta in this channel"), systemImage: "testtube.2")
            } description: {
                Text(tr("Le canal « \(catalog.channel.label) » ne contient actuellement rien de plus que le catalogue public.",
                        "The “\(catalog.channel.label)” channel currently contains nothing beyond the public catalog."))
            } actions: {
                Button(tr("Tout afficher", "Show all")) { state.betaOnly = false }
            }
        }
    }
}

struct BetaBadge: View {
    var body: some View {
        Text(tr("BÊTA", "BETA"))
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.orange))
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    let count: Int

    var body: some View {
        Label(item.title, systemImage: item.icon)
            .badge(count)
    }
}

// MARK: - Table

struct ProductTable: View {
    let products: [SUProduct]
    let downloads: DownloadManager
    @Binding var selection: Set<SUProduct.ID>
    @Binding var sortOrder: [KeyPathComparator<SUProduct>]

    var body: some View {
        Table(products, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(tr("Titre", "Title"), value: \.displayTitle) { p in
                HStack(spacing: 6) {
                    Text(p.displayTitle)
                        .foregroundStyle(p.metadataLoaded ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    if p.isBeta { BetaBadge() }
                }
            }
            .width(min: 180, ideal: 240)

            TableColumn("Version", value: \.versionString)
                .width(min: 60, ideal: 80)

            TableColumn("Build", value: \.buildString) { p in
                Text(p.buildString).monospaced()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Date", value: \.postDate) { p in
                Text(p.postDate, format: .dateTime.day(.twoDigits).month(.twoDigits).year())
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90)

            TableColumn(tr("Taille", "Size"), value: \.totalSize) { p in
                Text(formatBytes(p.totalSize)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)

            TableColumn("Product ID", value: \.id) { p in
                Text(p.id).monospaced().foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 95)

            TableColumn("") { p in
                ProductActionCell(product: p, downloads: downloads)
            }
            .width(min: 170, ideal: 200)
        }
        .contextMenu(forSelectionType: SUProduct.ID.self) { ids in
            contextMenu(for: products.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            products.filter { ids.contains($0.id) }.forEach(downloads.downloadInstaller)
        }
    }

    @ViewBuilder
    private func contextMenu(for selected: [SUProduct]) -> some View {
        if selected.count == 1, let p = selected.first {
            if p.installAssistant != nil {
                Button(tr("Télécharger InstallAssistant.pkg", "Download InstallAssistant.pkg")) { downloads.downloadInstaller(p) }
            }
            Menu(tr("Télécharger un paquet", "Download a package")) {
                ForEach(p.packages) { pkg in
                    Button("\(pkg.fileName) — \(formatBytes(pkg.size))") { downloads.download(pkg, of: p) }
                }
                Divider()
                Button(tr("Tous les paquets", "All packages")) { downloads.downloadAll(of: p) }
            }
            Divider()
            Button(tr("Copier le Product ID", "Copy Product ID")) { copy(p.id) }
            if let ia = p.installAssistant {
                Button(tr("Copier l'URL d'InstallAssistant.pkg", "Copy InstallAssistant.pkg URL")) { copy(ia.url.absoluteString) }
            }
            Button(tr("Copier les URLs des paquets", "Copy package URLs")) {
                copy(p.packages.map(\.url.absoluteString).joined(separator: "\n"))
            }
        } else if selected.count > 1 {
            let installers = selected.filter { $0.installAssistant != nil }
            if !installers.isEmpty {
                Button(tr("Télécharger \(installers.count) InstallAssistant.pkg", "Download \(installers.count) InstallAssistant.pkg")) {
                    installers.forEach(downloads.downloadInstaller)
                }
            }
            Button(tr("Copier les Product IDs", "Copy Product IDs")) { copy(selected.map(\.id).joined(separator: "\n")) }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Cellule d'action

struct ProductActionCell: View {
    let product: SUProduct
    let downloads: DownloadManager

    var body: some View {
        if let pkg = product.installAssistant {
            DownloadControl(
                state: downloads.state(of: pkg.url),
                idleTitle: "InstallAssistant.pkg",
                start: {
                    switch downloads.state(of: pkg.url) {
                    case .paused?: downloads.resume(pkg.url)
                    case .failed?: downloads.retry(pkg.url)
                    default: downloads.downloadInstaller(product)
                    }
                },
                cancel: { downloads.cancel(pkg.url) }
            )
        } else if let active = product.packages.first(where: {
            let s = downloads.state(of: $0.url)
            return s?.isActive == true || s?.isPaused == true
        }) {
            DownloadControl(
                state: downloads.state(of: active.url),
                idleTitle: active.fileName,
                start: { downloads.resume(active.url) },
                cancel: { downloads.cancel(active.url) }
            )
        } else {
            Menu {
                ForEach(product.packages) { pkg in
                    Button("\(pkg.fileName) — \(formatBytes(pkg.size))") { downloads.download(pkg, of: product) }
                }
                if product.packages.count > 1 {
                    Divider()
                    Button(tr("Tous les paquets", "All packages")) { downloads.downloadAll(of: product) }
                }
            } label: {
                Label(product.packages.count == 1
                      ? tr("1 paquet", "1 package")
                      : tr("\(product.packages.count) paquets", "\(product.packages.count) packages"),
                      systemImage: "arrow.down.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct DownloadControl: View {
    let state: DownloadItem.State?
    let idleTitle: String
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        switch state {
        case .downloading(let p)?:
            HStack(spacing: 6) {
                ProgressView(value: p.fraction)
                    .frame(width: 80)
                Text(p.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(tr("Annuler", "Cancel"))
            }
            .help(progressHelp(p))

        case .paused(let p)?:
            HStack(spacing: 6) {
                ProgressView(value: p.fraction).frame(width: 80).tint(.secondary)
                Text(tr("Pause", "Paused")).font(.caption).foregroundStyle(.secondary)
                Button(action: start) { Image(systemName: "play.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(tr("Reprendre", "Resume"))
            }

        case .finished(let url)?:
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label(tr("Afficher", "Show"), systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .help(url.path)

        case .failed(let message)?:
            Button(action: start) {
                Label(tr("Réessayer", "Retry"), systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .help(message)

        case nil:
            Button(action: start) {
                Label(idleTitle, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func progressHelp(_ p: TransferProgress) -> String {
        var s = "\(formatBytes(p.received)) / \(formatBytes(p.total)) — \(formatBytes(Int64(p.bytesPerSecond)))/s"
        if let eta = p.eta {
            let f = DateComponentsFormatter()
            f.allowedUnits = [.hour, .minute, .second]
            f.unitsStyle = .abbreviated
            if let e = f.string(from: eta) { s += tr(" — reste ", " — ") + e + tr("", " left") }
        }
        return s
    }
}

// MARK: - Barre de statut

struct StatusBar: View {
    let catalog: CatalogModel
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            if catalog.isLoading {
                ProgressView().controlSize(.small)
            }
            if let error = catalog.errorMessage, !catalog.products.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(statusText).foregroundStyle(.secondary)
            }

            Spacer()

            if downloads.pendingCount > 0 {
                Button {
                    ViewState.shared.showDownloads()
                } label: {
                    Label(tr("\(downloads.activeCount) en cours", "\(downloads.activeCount) active")
                          + " — \(formatBytes(Int64(downloads.totalSpeed)))/s",
                          systemImage: "arrow.down.circle")
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
            }

            Button {
                NSWorkspace.shared.open(downloads.destinationFolder)
            } label: {
                Label(downloads.destinationFolder.lastPathComponent, systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help(downloads.destinationFolder.path)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        if let status = catalog.status { return status }
        guard let date = catalog.lastRefresh else { return "" }
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppSettings.shared.locale))
        let source = catalog.catalogMajor.map { " (macOS \($0))" } ?? ""
        return tr("\(catalog.channel.label)\(source) — \(catalog.products.count) produits — mis à jour à \(time)",
                  "\(catalog.channel.label)\(source) — \(catalog.products.count) products — updated at \(time)")
    }
}
