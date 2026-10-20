import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Traduction

/// Traduction inline FR / EN. Lit `AppSettings.shared` (observable) : les vues se
/// redessinent automatiquement quand la langue change.
@MainActor
func tr(_ fr: String, _ en: String) -> String {
    AppSettings.shared.isFrench ? fr : en
}

// MARK: - Options

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, fr, en
    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .system: tr("Langue du système", "System language")
        case .fr: "Français"
        case .en: "English"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .system: tr("Système", "System")
        case .light: tr("Clair", "Light")
        case .dark: tr("Sombre", "Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Préréglages de nommage pour InstallAssistant.pkg.
enum InstallerNaming: String, CaseIterable, Identifiable {
    case apple, versionBuild, readable, readableBuild, custom
    var id: String { rawValue }

    var template: String? {
        switch self {
        case .apple: "InstallAssistant"
        case .versionBuild: "InstallAssistant-{version}-{build}"
        case .readable: "Installer{name}-{version}"
        case .readableBuild: "Installer{name}-{version}-{build}"
        case .custom: nil
        }
    }

    @MainActor var label: String {
        switch self {
        case .apple: tr("Nom Apple d'origine", "Original Apple name")
        case .versionBuild: tr("InstallAssistant + version + build", "InstallAssistant + version + build")
        case .readable: tr("Lisible (nom + version)", "Readable (name + version)")
        case .readableBuild: tr("Lisible (nom + version + build)", "Readable (name + version + build)")
        case .custom: tr("Personnalisé…", "Custom…")
        }
    }
}

// MARK: - Réglages

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let language = "language"
        static let appearance = "appearance"
        static let naming = "installerNaming"
        static let customTemplate = "installerCustomTemplate"
    }

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Key.language) }
    }

    var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    var naming: InstallerNaming {
        didSet { UserDefaults.standard.set(naming.rawValue, forKey: Key.naming) }
    }

    var customTemplate: String {
        didSet { UserDefaults.standard.set(customTemplate, forKey: Key.customTemplate) }
    }

    init() {
        let d = UserDefaults.standard
        language = d.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        appearance = d.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        naming = d.string(forKey: Key.naming).flatMap(InstallerNaming.init(rawValue:)) ?? .readable
        customTemplate = d.string(forKey: Key.customTemplate) ?? "Installer{name}-{version}-{build}"
    }

    var isFrench: Bool {
        switch language {
        case .fr: true
        case .en: false
        case .system: Locale.preferredLanguages.first?.lowercased().hasPrefix("fr") ?? false
        }
    }

    var locale: Locale { Locale(identifier: isFrench ? "fr_CH" : "en_US") }

    var installerTemplate: String { naming.template ?? customTemplate }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

// MARK: - Nom de fichier

enum InstallerFileName {
    static let tokens = ["{name}", "{title}", "{version}", "{build}", "{id}"]

    /// Construit le nom final d'un InstallAssistant.pkg à partir d'un modèle.
    /// Les jetons sans valeur sont supprimés, ainsi que les séparateurs orphelins.
    static func make(template: String, title: String?, version: String?, build: String?, id: String) -> String {
        let cleanTitle = (title ?? "macOS")
            .replacingOccurrences(of: "Install ", with: "")
            .trimmingCharacters(in: .whitespaces)
        let compactName = cleanTitle.replacingOccurrences(of: " ", with: "")

        var s = template
            .replacingOccurrences(of: "{name}", with: compactName)
            .replacingOccurrences(of: "{title}", with: cleanTitle)
            .replacingOccurrences(of: "{version}", with: version ?? "")
            .replacingOccurrences(of: "{build}", with: build ?? "")
            .replacingOccurrences(of: "{id}", with: id)

        // Caractères interdits dans un nom de fichier macOS
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        // Séparateurs doublés laissés par un jeton vide
        for sep in ["-", "_", " ", "."] {
            while s.contains(sep + sep) { s = s.replacingOccurrences(of: sep + sep, with: sep) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        if s.lowercased().hasSuffix(".pkg") { s = String(s.dropLast(4)) }
        if s.isEmpty { s = "InstallAssistant" }
        return s + ".pkg"
    }
}

// MARK: - Fenêtre de réglages

struct SettingsView: View {
    let settings: AppSettings
    let downloads: DownloadManager

    var body: some View {
        Form {
            Section(tr("Général", "General")) {
                Picker(tr("Langue", "Language"), selection: Binding(settings, \.language)) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                Picker(tr("Apparence", "Appearance"), selection: Binding(settings, \.appearance)) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section(tr("Téléchargements", "Downloads")) {
                LabeledContent(tr("Dossier par défaut", "Default folder")) {
                    HStack(spacing: 8) {
                        Text(abbreviated(downloads.destinationFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(downloads.destinationFolder.path)
                        Button(tr("Choisir…", "Choose…")) { chooseFolder(for: downloads) }
                        Button {
                            NSWorkspace.shared.open(downloads.destinationFolder)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(tr("Ouvrir dans le Finder", "Open in Finder"))
                    }
                }
            }

            Section {
                Picker(tr("Format", "Format"), selection: Binding(settings, \.naming)) {
                    ForEach(InstallerNaming.allCases) { Text($0.label).tag($0) }
                }

                if settings.naming == .custom {
                    TextField(tr("Modèle", "Template"), text: Binding(settings, \.customTemplate))
                        .font(.body.monospaced())
                    Text(tr("Jetons : ", "Tokens: ") + InstallerFileName.tokens.joined(separator: "  "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent(tr("Aperçu", "Preview")) {
                    Text(preview)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text(tr("Nommage des installers macOS", "macOS installer naming"))
            } footer: {
                Text(tr("S'applique à InstallAssistant.pkg au moment du téléchargement. Les autres paquets gardent leur nom d'origine.",
                        "Applies to InstallAssistant.pkg when the download starts. Other packages keep their original name."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, settings.locale)
    }

    private var preview: String {
        InstallerFileName.make(template: settings.installerTemplate,
                               title: "macOS Tahoe", version: "26.7.1", build: "25H123", id: "142-28081")
    }

    private func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Sélecteur de dossier partagé (réglages + toolbar).
@MainActor
func chooseFolder(for downloads: DownloadManager) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = downloads.destinationFolder
    panel.prompt = tr("Choisir", "Choose")
    panel.message = tr("Dossier où enregistrer les paquets", "Folder where packages are saved")
    if panel.runModal() == .OK, let url = panel.url {
        downloads.destinationFolder = url
    }
}
