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
        let zipURL: URL?
        let shaURL: URL?
    }

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
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, tag: tag, notes: json["body"] as? String ?? "",
                       pageURL: page, zipURL: asset(".zip"), shaURL: asset(".zip.sha256"))
    }

    // MARK: Proposition

    private func offer(_ release: Release, current: String) {
        let alert = NSAlert()
        alert.messageText = tr("SUS Fetcher \(release.version) est disponible",
                               "SUS Fetcher \(release.version) is available")
        alert.informativeText = tr("Version installée : \(current)", "Installed version: \(current)")
            + "\n\n" + Self.summary(of: release.notes)
        alert.icon = NSApp.applicationIconImage
        let canInstall = release.zipURL != nil && installLocationIsWritable
        if canInstall { alert.addButton(withTitle: tr("Installer et relancer", "Install and Relaunch")) }
        alert.addButton(withTitle: tr("Voir sur GitHub", "View on GitHub"))
        alert.addButton(withTitle: tr("Plus tard", "Later"))
        alert.addButton(withTitle: tr("Ignorer cette version", "Skip This Version"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        // Les indices des boutons dépendent de la présence de « Installer ».
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        var actions: [() -> Void] = []
        if canInstall { actions.append { Task { await self.install(release) } } }
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

    private var installLocationIsWritable: Bool {
        guard appURL.pathExtension == "app" else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: appURL.path)
    }

    private func install(_ release: Release) async {
        guard let zipURL = release.zipURL else { return }
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

            let (tmpZip, response) = try await URLSession.shared.download(from: zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let zip = work.appending(path: "update.zip")
            try fm.moveItem(at: tmpZip, to: zip)

            // Vérification SHA-256 (fichier .sha256 publié avec la release).
            if let shaURL = release.shaURL {
                let (shaData, _) = try await URLSession.shared.data(from: shaURL)
                let expected = String(decoding: shaData, as: UTF8.self)
                    .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?.lowercased() ?? ""
                let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard !expected.isEmpty, expected == actual else {
                    throw UpdateError.message(tr("L'empreinte SHA-256 du téléchargement ne correspond pas.",
                                                 "The download's SHA-256 checksum does not match."))
                }
            }

            status = .installing
            let extractDir = work.appending(path: "extracted", directoryHint: .isDirectory)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])

            guard let newApp = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError.message(tr("L'archive ne contient pas SUS Fetcher.", "The archive does not contain SUS Fetcher."))
            }

            try launchReplacementScript(newApp: newApp, workDir: work)
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("La mise à jour a échoué", "The update failed")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: tr("Voir sur GitHub", "View on GitHub"))
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
        }
    }

    /// Script détaché : attend la fin de l'app, remplace le bundle, relance.
    private func launchReplacementScript(newApp: URL, workDir: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
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
        open "$DEST"
        """
        let scriptURL = workDir.appending(path: "update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path,
                             String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, appURL.path, workDir.path]
        try process.run()
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
