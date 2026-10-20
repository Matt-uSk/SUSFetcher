import AppKit
import SwiftUI

/// Page « Téléchargements » (dans la fenêtre principale) : liste, pause / reprise / annulation.
struct DownloadsPane: View {
    let downloads: DownloadManager
    let search: String

    private var items: [DownloadItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let all = downloads.items.sorted { $0.createdAt > $1.createdAt }
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.fileName.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if downloads.items.isEmpty {
                ContentUnavailableView(tr("Aucun téléchargement", "No downloads"),
                                       systemImage: "arrow.down.circle",
                                       description: Text(tr("Les paquets lancés depuis le catalogue apparaîtront ici.",
                                                            "Packages started from the catalog will appear here.")))
                    .frame(maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        DownloadRow(item: item, downloads: downloads)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(tr("Téléchargements", "Downloads")).font(.headline)
            Spacer()
            Button { downloads.pauseAll() } label: { Label(tr("Tout en pause", "Pause all"), systemImage: "pause.fill") }
                .disabled(downloads.activeCount == 0)
            Button { downloads.resumeAll() } label: { Label(tr("Tout reprendre", "Resume all"), systemImage: "play.fill") }
                .disabled(downloads.pausedCount == 0)
            Button(role: .destructive) { downloads.cancelAll() } label: {
                Label(tr("Tout annuler", "Cancel all"), systemImage: "xmark.circle")
            }
            .disabled(downloads.pendingCount == 0)
            Button { downloads.clearFinished() } label: { Label(tr("Effacer les terminés", "Clear finished"), systemImage: "trash") }
                .disabled(!downloads.items.contains { $0.state.isDone })
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text(summary).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
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

    private var summary: String {
        var parts: [String] = []
        if downloads.activeCount > 0 {
            parts.append(tr("\(downloads.activeCount) en cours", "\(downloads.activeCount) active")
                         + " — \(formatBytes(Int64(downloads.totalSpeed)))/s")
        }
        if downloads.pausedCount > 0 {
            parts.append(tr("\(downloads.pausedCount) en pause", "\(downloads.pausedCount) paused"))
        }
        let done = downloads.items.filter(\.state.isDone).count
        if done > 0 { parts.append(tr("\(done) terminé\(done > 1 ? "s" : "")", "\(done) done")) }
        return parts.joined(separator: " · ")
    }
}

/// Mini-moniteur en bas de la sidebar : visible depuis toutes les pages tant qu'il reste du travail.
struct SidebarDownloadsMonitor: View {
    let downloads: DownloadManager
    let open: () -> Void

    private var pending: [DownloadItem] {
        downloads.items
            .filter { $0.state.isActive || $0.state.isPaused }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let list = pending
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Text(tr("En cours", "In progress")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if downloads.activeCount > 0 {
                        Text("\(formatBytes(Int64(downloads.totalSpeed)))/s")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ForEach(list.prefix(3)) { item in
                    MiniDownloadRow(item: item, downloads: downloads)
                }
                if list.count > 3 {
                    Text(tr("+ \(list.count - 3) autre\(list.count - 3 > 1 ? "s" : "")",
                            "+ \(list.count - 3) more"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .help(tr("Afficher les téléchargements", "Show downloads"))
        }
    }
}

struct MiniDownloadRow: View {
    let item: DownloadItem
    let downloads: DownloadManager

    var body: some View {
        let p = item.state.progress
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(item.title.isEmpty ? item.fileName : item.title)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    item.state.isPaused ? downloads.resume(item.source) : downloads.pause(item.source)
                } label: {
                    Image(systemName: item.state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help(item.state.isPaused ? tr("Reprendre", "Resume") : tr("Pause", "Pause"))
            }
            ProgressView(value: p?.fraction ?? 0)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(item.state.isPaused ? .secondary : .accentColor)
            Text(item.state.isPaused
                 ? tr("En pause", "Paused") + " — \((p?.fraction ?? 0).formatted(.percent.precision(.fractionLength(0))))"
                 : "\((p?.fraction ?? 0).formatted(.percent.precision(.fractionLength(0)))) — \(formatBytes(p?.received ?? 0)) / \(formatBytes(p?.total ?? 0))")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).fontWeight(.medium).lineLimit(1)
                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)

                if let p = item.state.progress {
                    ProgressView(value: p.fraction)
                        .progressViewStyle(.linear)
                        .tint(item.state.isPaused ? .secondary : .accentColor)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if let v = item.verification {
                    VerificationBadge(verification: v, algorithm: item.checksum?.algorithm.rawValue ?? "SHA-256")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                switch item.state {
                case .downloading:
                    iconButton("pause.fill", tr("Pause", "Pause")) { downloads.pause(item.source) }
                    iconButton("xmark", tr("Annuler", "Cancel")) { downloads.cancel(item.source) }
                case .paused:
                    iconButton("play.fill", tr("Reprendre", "Resume")) { downloads.resume(item.source) }
                    iconButton("xmark", tr("Annuler", "Cancel")) { downloads.cancel(item.source) }
                case .finished(let url):
                    iconButton("magnifyingglass", tr("Afficher dans le Finder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    iconButton("xmark", tr("Retirer de la liste", "Remove from list")) { downloads.remove(item.source) }
                case .failed:
                    iconButton("arrow.clockwise", tr("Réessayer", "Retry")) { downloads.retry(item.source) }
                    iconButton("xmark", tr("Retirer de la liste", "Remove from list")) { downloads.remove(item.source) }
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(tr("Copier l'URL", "Copy URL")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.source.absoluteString, forType: .string)
            }
            if case .finished(let url) = item.state {
                Button(tr("Afficher dans le Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 16) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
    }

    private var icon: String {
        switch item.state {
        case .downloading: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .downloading: .accentColor
        case .paused: .secondary
        case .finished: .green
        case .failed: .orange
        }
    }

    private var detail: String {
        switch item.state {
        case .downloading(let p):
            var s = "\(formatBytes(p.received)) / \(formatBytes(p.total)) — \(formatBytes(Int64(p.bytesPerSecond)))/s"
            if let eta = p.eta, let e = Self.etaFormatter.string(from: eta) {
                s += tr(" — reste \(e)", " — \(e) left")
            }
            return s
        case .paused(let p):
            return tr("En pause", "Paused") + " — \(formatBytes(p.received)) / \(formatBytes(p.total))"
        case .finished(let url):
            return url.deletingLastPathComponent().path
        case .failed(let message):
            return tr("Échec : ", "Failed: ") + message
        }
    }

    private static let etaFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Résultat du contrôle SHA-256 (IPSW).
struct VerificationBadge: View {
    let verification: DownloadItem.Verification
    let algorithm: String

    var body: some View {
        switch verification {
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(tr("Vérification \(algorithm)…", "Verifying \(algorithm)…"))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .ok:
            Label(tr("\(algorithm) vérifié", "\(algorithm) verified"), systemImage: "checkmark.shield.fill")
                .font(.caption).foregroundStyle(.green)
        case .mismatch:
            Label(tr("\(algorithm) invalide — fichier corrompu, à retélécharger",
                     "\(algorithm) mismatch — corrupted file, download again"),
                  systemImage: "xmark.shield.fill")
                .font(.caption).foregroundStyle(.red)
        case .error(let message):
            Label(tr("Vérification impossible : ", "Verification failed: ") + message,
                  systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
