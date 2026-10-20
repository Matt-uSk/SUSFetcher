import AppKit
import SwiftUI

@main
struct SUSFetcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Pas de @State ni d'@Environment : avec le SDK macOS 27, @State est une macro dont le plugin
    // n'existe que dans Xcode, et les @Environment(Observable) crashent dans les cellules de Table.
    // La struct App n'est instanciée qu'une fois, des `let` suffisent.
    private let catalog = CatalogModel()
    private let downloads = DownloadManager.shared
    private let viewState = ViewState.shared
    private let settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("SUS Fetcher") {
            ContentView(catalog: catalog, downloads: downloads, state: viewState)
                .frame(minWidth: 960, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button(tr("Installers macOS", "macOS Installers")) { viewState.sidebar = .installers }
                    .keyboardShortcut("1")
                Button(tr("Autres", "Other")) { viewState.sidebar = .others }
                    .keyboardShortcut("2")
                Button("iPhone (IPSW)") { viewState.sidebar = .iphone }
                    .keyboardShortcut("3")
                Button("iPad (IPSW)") { viewState.sidebar = .ipad }
                    .keyboardShortcut("4")
                Button("Mac (IPSW)") { viewState.sidebar = .mac }
                    .keyboardShortcut("5")
                Button(tr("Téléchargements", "Downloads")) { viewState.showDownloads() }
                    .keyboardShortcut("6")
                Divider()
            }
            CommandGroup(after: .newItem) {
                Button(tr("Recharger le catalogue", "Reload catalog")) { catalog.reload() }
                    .keyboardShortcut("r")
                Button(tr("Vider le cache des métadonnées", "Clear metadata cache")) { catalog.clearCacheAndReload() }
                Divider()
                Button(tr("Annuler tous les téléchargements", "Cancel all downloads")) { downloads.cancelAll() }
                    .disabled(downloads.pendingCount == 0)
            }
        }

        // Fenêtre Réglages standard (menu de l'app > Réglages…, ⌘,)
        Settings {
            SettingsView(settings: settings, downloads: downloads, catalog: catalog)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nécessaire quand l'exécutable est lancé hors bundle (swift run).
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated {
            AppSettings.shared.applyAppearance()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Appelé pour ⌘Q, menu Quitter, Dock > Quitter et fermeture de la dernière fenêtre.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let downloads = DownloadManager.shared
            let active = downloads.activeCount
            let paused = downloads.pausedCount
            guard active + paused > 0 else { return .terminateNow }

            var parts: [String] = []
            if active > 0 { parts.append(tr("\(active) en cours", "\(active) in progress")) }
            if paused > 0 { parts.append(tr("\(paused) en pause", "\(paused) paused")) }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("Des téléchargements ne sont pas terminés",
                                   "Some downloads are not finished")
            alert.informativeText = parts.joined(separator: tr(" et ", " and ")) + ". "
                + tr("Si tu quittes maintenant, ils seront perdus et devront être relancés depuis le début.",
                     "If you quit now, they will be lost and will have to restart from the beginning.")
            alert.addButton(withTitle: tr("Ne pas quitter", "Don't Quit"))   // bouton par défaut (Entrée)
            let quit = alert.addButton(withTitle: tr("Quitter quand même", "Quit Anyway"))
            quit.hasDestructiveAction = true
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                downloads.cancelAll()
                return .terminateNow
            }
            ViewState.shared.showDownloads()
            return .terminateCancel
        }
    }
}
