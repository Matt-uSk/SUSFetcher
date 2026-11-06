import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Mise à jour de l'app depuis les Releases GitHub, sans dépendance (pas de Sparkle).
///
/// 1. GET api.github.com/repos/<repo>/releases/latest
/// 2. version plus récente → fenêtre : Installer et relancer / Voir sur GitHub / Plus tard / Ignorer
/// 3. Installer : télécharge le zip + son .sha256, vérifie l'empreinte et l'identifiant de l'app,
///    puis un petit script remplace l'app une fois quittée et la relance.
@Observable
@MainActor
final class Updater {
    static let shared = Updater()

    static let repository = "Matt-uSk/SUSFetcher"
    private static let autoKey = "updatesAutoCheck"
    private static let lastCheckKey = "updatesLastCheck"
    private static let skippedKey = "updatesSkippedVersion"

    struct Release: Sendable {
        let version: String          // "1.4.1"
        let tag: String              // "v1.4.1"
        let notes: String
        let pageURL: URL
        let zip: Asset?
        let sha: Asset?
        var zipURL: URL? { zip?.downloadURL }
    }

    /// Fichier attaché à une release : lien public + lien API (secours) + taille annoncée.
    struct Asset: Sendable {
        let name: String
        let downloadURL: URL
        let apiURL: URL?
        let size: Int64
    }

    /// Session dédiée : aucun cache, pour ne jamais réutiliser une réponse intermédiaire.
    @ObservationIgnored private let updateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    enum Status: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: Updater.lastCheckKey) as? Date

    var automaticChecks: Bool = UserDefaults.standard.object(forKey: Updater.autoKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: Self.autoKey) }
    }

    /// Version de l'app en cours (nil quand lancée via `swift run`, hors bundle).
    var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: Vérification

    /// Au lancement : au plus une vérification par 24 h, silencieuse si à jour.
    func checkAutomaticallyIfNeeded() {
        guard automaticChecks, currentVersion != nil else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    /// `userInitiated` : affiche aussi « à jour » et les erreurs, et ignore la version mise de côté.
    func check(userInitiated: Bool) async {
        guard status != .checking, status != .downloading, status != .installing else { return }
        status = .checking
        do {
            let release = try await fetchLatest()
            lastCheck = .now
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)

            guard let current = currentVersion else {
                status = .idle
                if userInitiated {
                    info(tr("Version de développement", "Development build"),
                         tr("L'app tourne hors bundle (swift run) : la mise à jour automatique est désactivée. Dernière version publiée : \(release.version).",
                            "The app is running outside a bundle (swift run): automatic updates are disabled. Latest published version: \(release.version)."))
                }
                return
            }

            let isNewer = release.version.compare(current, options: .numeric) == .orderedDescending
            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            guard isNewer, userInitiated || skipped != release.version else {
                status = .upToDate
                if userInitiated {
                    info(tr("SUS Fetcher est à jour", "SUS Fetcher is up to date"),
                         tr("La version \(current) est la plus récente.", "Version \(current) is the latest."))
                }
                return
            }
            status = .idle
            offer(release, current: current)
        } catch {
            status = .failed(error.localizedDescription)
            if userInitiated {
                info(tr("Vérification impossible", "Could not check for updates"), error.localizedDescription)
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SUSFetcher", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw URLError(.badServerResponse)
        }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(_ suffix: String) -> Asset? {
            guard let a = assets.first(where: { ($0["name"] as? String)?.hasSuffix(suffix) == true }),
                  let name = a["name"] as? String,
                  let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Asset(name: name, downloadURL: url,
                         apiURL: (a["url"] as? String).flatMap(URL.init(string:)),
                         size: (a["size"] as? NSNumber)?.int64Value ?? 0)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, tag: tag, notes: json["body"] as? String ?? "",
                       pageURL: page, zip: asset(".zip"), sha: asset(".zip.sha256"))
    }

    // MARK: Proposition

    private func offer(_ release: Release, current: String) {
        let alert = NSAlert()
        alert.messageText = tr("SUS Fetcher \(release.version) est disponible",
                               "SUS Fetcher \(release.version) is available")
        alert.informativeText = tr("Version installée : \(current)", "Installed version: \(current)")
            + "\n\n" + Self.summary(of: release.notes)
        alert.icon = NSApp.applicationIconImage

        let mode = release.zipURL == nil ? InstallMode.unavailable(tr("Aucune archive dans cette version.",
                                                                     "No archive in this release.")) : installMode
        let canInstall: Bool
        switch mode {
        case .direct:
            canInstall = true
            alert.addButton(withTitle: tr("Installer et relancer", "Install and Relaunch"))
        case .administrator:
            canInstall = true
            alert.informativeText += "\n\n" + tr("SUS Fetcher n'a pas le droit de modifier « \(appURL.deletingLastPathComponent().path) » avec ce compte : un mot de passe administrateur sera demandé.",
                                                  "SUS Fetcher can't modify “\(appURL.deletingLastPathComponent().path)” with this account: an administrator password will be requested.")
            alert.addButton(withTitle: tr("Installer et relancer (mot de passe administrateur)",
                                          "Install and Relaunch (administrator password)"))
        case .unavailable(let reason):
            canInstall = false
            alert.informativeText += "\n\n" + tr("Installation automatique impossible : ", "Automatic install unavailable: ") + reason
        }
        alert.addButton(withTitle: tr("Voir sur GitHub", "View on GitHub"))
        alert.addButton(withTitle: tr("Plus tard", "Later"))
        alert.addButton(withTitle: tr("Ignorer cette version", "Skip This Version"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        // Les indices des boutons dépendent de la présence de « Installer ».
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        var actions: [() -> Void] = []
        if canInstall {
            let privileged = mode == .administrator
            actions.append { Task { await self.install(release, privileged: privileged) } }
        }
        actions.append { NSWorkspace.shared.open(release.pageURL) }
        actions.append {}
        actions.append { UserDefaults.standard.set(release.version, forKey: Updater.skippedKey) }
        if actions.indices.contains(index) { actions[index]() }
    }

    /// « What's new » du CHANGELOG, sans la partie installation, tronqué pour l'alerte.
    private static func summary(of notes: String) -> String {
        var text = notes.components(separatedBy: "## Installation").first ?? notes
        text = text.replacingOccurrences(of: "## What's new", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 900 ? String(text.prefix(900)) + "…" : text
    }

    // MARK: Installation

    private var appURL: URL { Bundle.main.bundleURL }

    enum InstallMode: Equatable {
        case direct                    // l'utilisateur peut remplacer l'app lui-même
        case administrator             // remplacement avec un mot de passe administrateur
        case unavailable(String)       // impossible (raison affichée)
    }

    private var installMode: InstallMode {
        guard appURL.pathExtension == "app" else {
            return .unavailable(tr("l'app ne tourne pas depuis un bundle .app.", "the app isn't running from an .app bundle."))
        }
        // App Translocation : macOS fait tourner l'app depuis un emplacement temporaire en lecture seule.
        if appURL.path.contains("/AppTranslocation/") {
            return .unavailable(tr("macOS exécute l'app depuis un emplacement temporaire. Déplace « SUS Fetcher » dans le dossier Applications, relance-la puis réessaie.",
                                   "macOS is running the app from a temporary location. Move “SUS Fetcher” to the Applications folder, relaunch it and try again."))
        }
        let fm = FileManager.default
        if fm.isWritableFile(atPath: appURL.deletingLastPathComponent().path), fm.isWritableFile(atPath: appURL.path) {
            return .direct
        }
        return .administrator
    }

    private func install(_ release: Release, privileged: Bool = false) async {
        guard release.zip != nil else { return }
        if DownloadManager.shared.pendingCount > 0 {
            info(tr("Téléchargements en cours", "Downloads in progress"),
                 tr("Termine ou annule les téléchargements avant d'installer la mise à jour.",
                    "Finish or cancel the downloads before installing the update."))
            return
        }

        status = .downloading
        do {
            // Dossier temporaire sur le même volume que l'app (déplacement atomique).
            let fm = FileManager.default
            let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: appURL, create: true)

            guard let zipAsset = release.zip else { return }
            let zip = work.appending(path: "update.zip")

            // Empreinte attendue (fichier .sha256 publié avec la release).
            var expected: String?
            if let shaAsset = release.sha {
                let shaFile = try await fetch(shaAsset)
                let text = (try? String(contentsOf: shaFile, encoding: .utf8)) ?? ""
                let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init)?.lowercased() ?? ""
                guard first.count == 64, first.allSatisfy(\.isHexDigit) else {
                    throw UpdateError.message(tr("Le fichier d'empreinte reçu est illisible.", "The checksum file received is unreadable.")
                                              + "\n" + Self.preview(of: shaFile))
                }
                expected = first
            }

            // Téléchargement + contrôles ; un second essai par l'API GitHub si le premier ne colle pas.
            var lastProblem = ""
            var verified = false
            for attempt in 0..<2 {
                let tmp = try await fetch(zipAsset, preferAPI: attempt == 1)
                try? fm.removeItem(at: zip)
                try fm.moveItem(at: tmp, to: zip)

                if let problem = Self.problem(with: zip, expectedSize: zipAsset.size, expectedSHA: expected) {
                    lastProblem = problem
                    continue
                }
                verified = true
                break
            }
            guard verified else { throw UpdateError.message(lastProblem) }

            status = .installing
            let extractDir = work.appending(path: "extracted", directoryHint: .isDirectory)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])

            guard let newApp = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError.message(tr("L'archive ne contient pas SUS Fetcher.", "The archive does not contain SUS Fetcher."))
            }

            try launchReplacementScript(newApp: newApp, workDir: work, privileged: privileged)
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("La mise à jour a échoué", "The update failed")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: tr("Télécharger manuellement", "Download Manually"))
            alert.addButton(withTitle: tr("Copier le détail", "Copy Details"))
            alert.addButton(withTitle: "OK")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(release.pageURL)
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("SUS Fetcher \(currentVersion ?? "?") → \(release.version)\n"
                                               + error.localizedDescription, forType: .string)
            default:
                break
            }
        }
    }

    /// Télécharge un fichier de la release sans cache ; `preferAPI` passe par api.github.com.
    private func fetch(_ asset: Asset, preferAPI: Bool = false) async throws -> URL {
        let url = (preferAPI ? asset.apiURL : nil) ?? asset.downloadURL
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("SUSFetcher", forHTTPHeaderField: "User-Agent")
        if url == asset.apiURL { request.setValue("application/octet-stream", forHTTPHeaderField: "Accept") }
        let (tmp, response) = try await updateSession.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError.message(tr("Le serveur a répondu HTTP \(code) pour \(asset.name).",
                                         "The server responded with HTTP \(code) for \(asset.name)."))
        }
        return tmp
    }

    /// Décrit précisément ce qui ne va pas avec l'archive reçue (nil = tout est correct).
    private static func problem(with file: URL, expectedSize: Int64, expectedSHA: String?) -> String? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { h -> Data? in
            defer { try? h.close() }
            return try? h.read(upToCount: 4)
        } ?? Data()

        if head != Data([0x50, 0x4B, 0x03, 0x04]) {
            return tr("Le fichier reçu n'est pas une archive zip (\(formatBytes(size))). Un proxy, un filtre web ou un antivirus a probablement remplacé le téléchargement.",
                      "The file received is not a zip archive (\(formatBytes(size))). A proxy, web filter or antivirus probably replaced the download.")
                + "\n" + preview(of: file)
        }
        if expectedSize > 0, size != expectedSize {
            return tr("Taille reçue : \(formatBytes(size)) au lieu de \(formatBytes(expectedSize)) (téléchargement incomplet ou modifié).",
                      "Received size: \(formatBytes(size)) instead of \(formatBytes(expectedSize)) (incomplete or altered download).")
        }
        if let expectedSHA {
            guard let data = try? Data(contentsOf: file) else { return tr("Lecture de l'archive impossible.", "Could not read the archive.") }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actual != expectedSHA {
                return tr("L'empreinte SHA-256 ne correspond pas.", "The SHA-256 checksum does not match.")
                    + "\n" + tr("Attendue : ", "Expected: ") + String(expectedSHA.prefix(16)) + "…"
                    + "\n" + tr("Reçue : ", "Received: ") + String(actual.prefix(16)) + "…"
            }
        }
        return nil
    }

    /// Début du fichier en texte (utile quand un proxy renvoie une page HTML).
    private static func preview(of file: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 160)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "« " + text + " »"
    }

    /// Script détaché : attend la fin de l'app, remplace le bundle, relance.
    /// `privileged` : lancé en root via une demande de mot de passe administrateur ; l'app est
    /// ensuite relancée sous le compte de l'utilisateur (pas en root).
    private func launchReplacementScript(newApp: URL, workDir: URL, privileged: Bool = false) throws {
        let script = """
        #!/bin/sh
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"; USER_ID="$5"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          i=$((i+1)); [ "$i" -gt 600 ] && exit 1   # abandon après ~2 min (quitter annulé)
          sleep 0.2
        done
        if mv "$DEST" "$DEST.old-update"; then
          if mv "$NEW" "$DEST"; then
            rm -rf "$DEST.old-update"
          else
            mv "$DEST.old-update" "$DEST"
          fi
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        rm -rf "$WORK"
        if [ "$(id -u)" = "0" ] && [ -n "$USER_ID" ] && [ "$USER_ID" != "0" ]; then
          launchctl asuser "$USER_ID" sudo -u "#$USER_ID" /usr/bin/open "$DEST"
        else
          /usr/bin/open "$DEST"
        fi
        """
        let scriptURL = workDir.appending(path: "update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let args = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                    newApp.path, appURL.path, workDir.path, String(getuid())]

        guard privileged else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = args
            try process.run()
            return
        }

        // Demande d'autorisation macOS standard, script lancé en arrière-plan en root.
        func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/bin/sh " + args.map(shellQuote).joined(separator: " ") + " >/dev/null 2>&1 &"
        let appleScriptCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(appleScriptCommand)\" with administrator privileges"
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -128 : l'utilisateur a annulé la demande de mot de passe.
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 {
                throw UpdateError.message(tr("Installation annulée.", "Installation cancelled."))
            }
            throw UpdateError.message((errorInfo[NSAppleScript.errorMessage] as? String)
                                      ?? tr("Autorisation administrateur refusée.", "Administrator authorization denied."))
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.message("\(tool) → \(p.terminationStatus)")
        }
    }

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): m }
        }
    }
}

/// Section « Mises à jour » des réglages.
struct UpdatesSettingsSection: View {
    let updater: Updater

    var body: some View {
        Section(tr("Mises à jour", "Updates")) {
            LabeledContent(tr("Version installée", "Installed version")) {
                Text(updater.currentVersion ?? tr("développement", "development")).monospacedDigit()
            }
            Toggle(tr("Vérifier automatiquement (une fois par jour)", "Check automatically (once a day)"),
                   isOn: Binding(updater, \.automaticChecks))
            HStack {
                statusText
                Spacer()
                Button(tr("Rechercher maintenant", "Check Now")) {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.status == .checking || updater.status == .downloading)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.status {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(tr("Vérification…", "Checking…")) }
                .foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(tr("Téléchargement…", "Downloading…")) }
                .foregroundStyle(.secondary)
        case .installing:
            Text(tr("Installation…", "Installing…")).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.orange).lineLimit(2)
        default:
            if let date = updater.lastCheck {
                Text(tr("Dernière vérification : ", "Last checked: ")
                     + date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                        .locale(AppSettings.shared.locale)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
