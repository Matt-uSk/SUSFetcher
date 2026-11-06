import AppKit
import SwiftUI

/// Ligne de la page « Sur ce Mac ».
struct LocalFileRow: Identifiable, Hashable {
    let url: URL
    let name: String          // produit identifié ou nom du fichier
    let fileName: String
    let kind: String          // Installer / Paquet / IPSW
    let version: String
    let size: Int64
    let date: Date
    let folder: String        // sous-dossier relatif au dossier de destination
    let newer: String?        // version plus récente disponible dans le catalogue

    var id: URL { url }
}

/// Fichiers .pkg / .ipsw déjà présents dans le dossier de destination.
struct LocalFilesPane: View {
    let files: LocalFiles
    let downloads: DownloadManager
    let state: ViewState
    let search: String

    var body: some View {
        let rows = makeRows()
        VStack(spacing: 0) {
            header(rows)
            Divider()
            Table(rows, selection: Binding(state, \.localSelection), sortOrder: Binding(state, \.localSortOrder)) {
                TableColumn(tr("Nom", "Name"), value: \.name) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(r.name).lineLimit(1)
                            if let newer = r.newer {
                                Text(tr("\(newer) disponible", "\(newer) available"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .foregroundStyle(.white)
                                    .background(Capsule().fill(Color.orange))
                                    .help(tr("Une version plus récente est dans le catalogue", "A newer version is in the catalog"))
                            }
                        }
                        if r.name != r.fileName {
                            Text(r.fileName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 220, ideal: 320)

                TableColumn(tr("Type", "Type"), value: \.kind)
                    .width(min: 60, ideal: 80)

                TableColumn("Version", value: \.version) { r in
                    Text(r.version).monospacedDigit()
                }
                .width(min: 60, ideal: 80)

                TableColumn(tr("Taille", "Size"), value: \.size) { r in
                    Text(formatBytes(r.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 80)

                TableColumn("Date", value: \.date) { r in
                    Text(r.date, format: .dateTime.day(.twoDigits).month(.twoDigits).year()).monospacedDigit()
                }
                .width(min: 80, ideal: 90)

                TableColumn(tr("Dossier", "Folder"), value: \.folder) { r in
                    Text(r.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 80, ideal: 140)

                TableColumn("") { r in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([r.url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Afficher dans le Finder", "Show in Finder"))
                }
                .width(28)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                contextMenu(Array(urls), rows: rows)
            } primaryAction: { urls in
                NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
            }
            .overlay {
                if rows.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView(tr("Aucun fichier", "No files"), systemImage: "internaldrive",
                                               description: Text(tr("Aucun .pkg ni .ipsw dans le dossier de destination.",
                                                                    "No .pkg or .ipsw in the destination folder.")))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
        }
        .onAppear { files.rescan() }
        .environment(\.locale, AppSettings.shared.locale)
    }

    // MARK: En-tête

    private func header(_ rows: [LocalFileRow]) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Sur ce Mac", "On This Mac")).font(.headline)
                Text(tr("\(rows.count) fichier(s) · \(formatBytes(rows.reduce(0) { $0 + $1.size }))",
                        "\(rows.count) file(s) · \(formatBytes(rows.reduce(0) { $0 + $1.size }))"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button {
                files.rescan()
            } label: {
                Label(tr("Actualiser", "Refresh"), systemImage: "arrow.clockwise")
            }
            Button {
                NSWorkspace.shared.open(downloads.destinationFolder)
            } label: {
                Label(downloads.destinationFolder.lastPathComponent, systemImage: "folder")
            }
            .help(downloads.destinationFolder.path)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Menu contextuel

    @ViewBuilder
    private func contextMenu(_ urls: [URL], rows: [LocalFileRow]) -> some View {
        if !urls.isEmpty {
            Button(tr("Afficher dans le Finder", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Button(tr("Copier le chemin", "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button(tr("Mettre à la Corbeille…", "Move to Trash…")) {
                confirmTrash(urls, rows: rows)
            }
        }
    }

    private func confirmTrash(_ urls: [URL], rows: [LocalFileRow]) {
        let size = rows.filter { urls.contains($0.url) }.reduce(0) { $0 + $1.size }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? tr("Mettre « \(urls[0].lastPathComponent) » à la Corbeille ?", "Move “\(urls[0].lastPathComponent)” to the Trash?")
            : tr("Mettre \(urls.count) fichiers à la Corbeille ?", "Move \(urls.count) files to the Trash?")
        alert.informativeText = tr("\(formatBytes(size)) seront libérés une fois la Corbeille vidée.",
                                   "\(formatBytes(size)) will be freed once the Trash is emptied.")
        alert.addButton(withTitle: tr("Mettre à la Corbeille", "Move to Trash")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("Annuler", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = files.trash(urls)
        state.localSelection.removeAll()
    }

    // MARK: Identification

    private func makeRows() -> [LocalFileRow] {
        let folder = downloads.destinationFolder.standardizedFileURL.path
        // Paquets du catalogue indexés par « Digest » (TOC xar) pour reconnaître les fichiers, même renommés.
        var productByTOC: [String: SUProduct] = [:]
        var latestByTitle: [String: String] = [:]
        for p in CatalogModel.shared.products {
            for pkg in p.packages { if let d = pkg.tocDigest?.lowercased() { productByTOC[d] = p } }
            let v = p.versionString
            if !v.isEmpty, (latestByTitle[p.displayTitle].map { v.compare($0, options: .numeric) == .orderedDescending } ?? true) {
                latestByTitle[p.displayTitle] = v
            }
        }

        let q = search.trimmingCharacters(in: .whitespaces)
        let rows: [LocalFileRow] = files.allFiles.map { f in
            let fileName = f.url.lastPathComponent
            let parent = f.url.deletingLastPathComponent().standardizedFileURL.path
            let relative = parent.hasPrefix(folder) ? String(parent.dropFirst(folder.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : parent
            let isIPSW = f.url.pathExtension.lowercased() == "ipsw"

            var name = (fileName as NSString).deletingPathExtension
            var version = Self.version(in: fileName) ?? ""
            var kind = isIPSW ? "IPSW" : tr("Paquet", "Package")
            var newer: String?

            if !isIPSW, let toc = f.xarTOC?.lowercased(), let product = productByTOC[toc] {
                name = product.displayTitle
                version = product.versionString.isEmpty ? version : product.versionString
                if product.isInstaller { kind = "Installer" }
                if let latest = latestByTitle[product.displayTitle], !version.isEmpty,
                   latest.compare(version, options: .numeric) == .orderedDescending {
                    newer = latest
                }
            }
            return LocalFileRow(url: f.url, name: name, fileName: fileName, kind: kind, version: version,
                                size: f.size, date: Date(timeIntervalSince1970: f.modified),
                                folder: relative.isEmpty ? "—" : relative, newer: newer)
        }
        let filtered = q.isEmpty ? rows : rows.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.fileName.localizedCaseInsensitiveContains(q)
                || $0.version.localizedCaseInsensitiveContains(q)
        }
        return filtered.sorted(using: state.localSortOrder)
    }

    /// Première version « 27.0.1 » / « 15.8 » trouvée dans un nom de fichier.
    private static func version(in name: String) -> String? {
        guard let range = name.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(name[range])
    }
}
