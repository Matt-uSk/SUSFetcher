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
        static let customCatalog = "customCatalogURL"
        static let ipswNaming = "ipswNaming"
        static let ipswCustomTemplate = "ipswCustomTemplate"
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

    /// URL de catalogue saisie à la main (avancé). Vide = détection automatique.
    var ipswNaming: IPSWNaming {
        didSet { UserDefaults.standard.set(ipswNaming.rawValue, forKey: Key.ipswNaming) }
    }

    var ipswCustomTemplate: String {
        didSet { UserDefaults.standard.set(ipswCustomTemplate, forKey: Key.ipswCustomTemplate) }
    }

    /// Modèle de nom des IPSW (nil = nom d'origine Apple).
    var ipswTemplate: String? {
        switch ipswNaming {
        case .custom: ipswCustomTemplate
        default: ipswNaming.template
        }
    }

    var customCatalog: String {
        didSet { UserDefaults.standard.set(customCatalog, forKey: Key.customCatalog) }
    }

    var customCatalogURL: URL? {
        let s = customCatalog.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    init() {
        let d = UserDefaults.standard
        language = d.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        appearance = d.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        naming = d.string(forKey: Key.naming).flatMap(InstallerNaming.init(rawValue:)) ?? .readable
        customTemplate = d.string(forKey: Key.customTemplate) ?? "Installer{name}-{version}-{build}"
        customCatalog = d.string(forKey: Key.customCatalog) ?? ""
        ipswNaming = d.string(forKey: Key.ipswNaming).flatMap(IPSWNaming.init(rawValue:)) ?? .readable
        ipswCustomTemplate = d.string(forKey: Key.ipswCustomTemplate) ?? "{model}-{os}{version}-{build}"
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

/// Préréglages de nommage des IPSW.
enum IPSWNaming: String, CaseIterable, Identifiable {
    case apple, readable, readableBuild, identifier, custom
    var id: String { rawValue }

    /// nil = nom d'origine Apple.
    var template: String? {
        switch self {
        case .apple: nil
        case .readable: "{model}-{os}{version}"
        case .readableBuild: "{model}-{os}{version}-{build}"
        case .identifier: "{identifier}-{os}{version}-{build}"
        case .custom: nil
        }
    }

    @MainActor var label: String {
        switch self {
        case .apple: tr("Nom Apple d'origine", "Original Apple name")
        case .readable: tr("Lisible (modèle + version)", "Readable (model + version)")
        case .readableBuild: tr("Lisible (modèle + version + build)", "Readable (model + version + build)")
        case .identifier: tr("Identifiant + version + build", "Identifier + version + build")
        case .custom: tr("Personnalisé…", "Custom…")
        }
    }
}

enum IPSWFileName {
    static let tokens = ["{model}", "{identifier}", "{os}", "{version}", "{build}"]

    /// Nom final d'un IPSW. Les IPSW Mac universels (un seul fichier pour tous les modèles)
    /// utilisent « UniversalMac » comme modèle, pour ne pas dupliquer le même fichier sous plusieurs noms.
    static func make(template: String?, originalName: String, deviceName: String,
                     identifier: String, version: String, build: String) -> String {
        guard let template else { return originalName }
        let universal = originalName.hasPrefix("UniversalMac")
        let model = universal ? "UniversalMac" : compact(deviceName)
        let os: String
        if IPSWFamily.iPhone.matches(identifier) { os = "iOS" }
        else if IPSWFamily.iPad.matches(identifier) { os = "iPadOS" }
        else { os = "macOS" }
        return FileNameTemplate.render(template, values: [
            "{model}": model,
            "{identifier}": universal ? "UniversalMac" : identifier,
            "{os}": os,
            "{version}": version,
            "{build}": build,
        ], ext: "ipsw", fallback: (originalName as NSString).deletingPathExtension)
    }

    /// « iPhone 17 Pro » → « iPhone17Pro », « MacBook Pro (14-inch, M5) » → « MacBookPro14-inchM5 ».
    static func compact(_ name: String) -> String {
        name.filter { !" (),".contains($0) }
    }
}

/// Rendu générique d'un modèle de nom de fichier : remplace les jetons, retire les caractères
/// interdits et les séparateurs orphelins laissés par un jeton vide.
enum FileNameTemplate {
    static func render(_ template: String, values: [String: String], ext: String, fallback: String) -> String {
        var s = template
        for (token, value) in values { s = s.replacingOccurrences(of: token, with: value) }
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        for sep in ["-", "_", " ", "."] {
            while s.contains(sep + sep) { s = s.replacingOccurrences(of: sep + sep, with: sep) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        if s.lowercased().hasSuffix("." + ext) { s = String(s.dropLast(ext.count + 1)) }
        if s.isEmpty { s = fallback }
        return s + "." + ext
    }
}

// MARK: - Fenêtre de réglages

struct SettingsView: View {
    let settings: AppSettings
    let downloads: DownloadManager
    let catalog: CatalogModel

    var body: some View {
        TabView {
            Form {
                generalSection
                UpdatesSettingsSection(updater: Updater.shared)
            }
            .formStyle(.grouped)
            .tabItem { Label(tr("Général", "General"), systemImage: "gearshape") }

            Form { downloadsSection }
                .formStyle(.grouped)
                .tabItem { Label(tr("Téléchargements", "Downloads"), systemImage: "arrow.down.circle") }

            Form {
                installerNamingSection
                ipswNamingSection
            }
            .formStyle(.grouped)
            .tabItem { Label(tr("Nommage", "Naming"), systemImage: "textformat") }

            Form { catalogSection }
                .formStyle(.grouped)
                .tabItem { Label(tr("Catalogue", "Catalog"), systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 600, height: 470)
        .environment(\.locale, settings.locale)
    }

    // MARK: Sections

    private var generalSection: some View {
        Section(tr("Général", "General")) {
            Picker(tr("Langue", "Language"), selection: Binding(settings, \.language)) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            Picker(tr("Apparence", "Appearance"), selection: Binding(settings, \.appearance)) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var downloadsSection: some View {
        Section {
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
            Stepper(value: Binding(downloads, \.maxConcurrent), in: 1...10) {
                LabeledContent(tr("Téléchargements simultanés", "Simultaneous downloads")) {
                    Text("\(downloads.maxConcurrent)").monospacedDigit()
                }
            }
        } header: {
            Text(tr("Téléchargements", "Downloads"))
        } footer: {
            Text(tr("Au-delà, les téléchargements attendent leur tour dans la file et démarrent automatiquement.",
                    "Beyond that, downloads wait in the queue and start automatically."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var catalogSection: some View {
        Section {
            LabeledContent(tr("Version détectée", "Detected version")) {
                if let major = catalog.catalogMajor {
                    Text("macOS \(major)")
                } else if settings.customCatalogURL != nil {
                    Text(tr("URL personnalisée", "Custom URL")).foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            TextField(tr("URL personnalisée", "Custom URL"),
                      text: Binding(settings, \.customCatalog),
                      prompt: Text(tr("Automatique", "Automatic")))
                .font(.callout.monospaced())
                .onSubmit { catalog.reload() }
            HStack {
                Spacer()
                Button(tr("Redétecter et recharger", "Re-detect and reload")) { catalog.clearCacheAndReload() }
            }
        } header: {
            Text(tr("Catalogue Apple", "Apple catalog"))
        } footer: {
            Text(tr("La dernière version de macOS est détectée automatiquement : rien à modifier quand une nouvelle version majeure sort. L'URL personnalisée (canal Public) n'est utile qu'en dépannage.",
                    "The latest macOS version is detected automatically: nothing to change when a new major version ships. The custom URL (Public channel) is only for troubleshooting."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var installerNamingSection: some View {
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
                Text(preview).font(.body.monospaced()).textSelection(.enabled)
            }
        } header: {
            Text(tr("Installers macOS (InstallAssistant.pkg)", "macOS installers (InstallAssistant.pkg)"))
        } footer: {
            Text(tr("Les autres paquets du catalogue gardent leur nom d'origine.",
                    "Other catalog packages keep their original name."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ipswNamingSection: some View {
        Section {
            Picker(tr("Format", "Format"), selection: Binding(settings, \.ipswNaming)) {
                ForEach(IPSWNaming.allCases) { Text($0.label).tag($0) }
            }
            if settings.ipswNaming == .custom {
                TextField(tr("Modèle", "Template"), text: Binding(settings, \.ipswCustomTemplate))
                    .font(.body.monospaced())
                Text(tr("Jetons : ", "Tokens: ") + IPSWFileName.tokens.joined(separator: "  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent(tr("Aperçu", "Preview")) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ipswPreview(device: "iPhone 17 Pro", identifier: "iPhone18,1",
                                     original: "iPhone18,1_27.0.1_24A446_Restore.ipsw"))
                    Text(ipswPreview(device: "MacBook Pro (14-inch, M5)", identifier: "Mac17,2",
                                     original: "UniversalMac_27.0.1_26A434_Restore.ipsw"))
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
            }
        } header: {
            Text("IPSW")
        } footer: {
            Text(tr("Les IPSW Mac sont universels (un même fichier pour tous les modèles) : ils sont nommés « UniversalMac » pour éviter les doublons.",
                    "Mac IPSWs are universal (one file for all models): they are named “UniversalMac” to avoid duplicates."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ipswPreview(device: String, identifier: String, original: String) -> String {
        let build = original.contains("UniversalMac") ? "26A434" : "24A446"
        return IPSWFileName.make(template: settings.ipswTemplate, originalName: original, deviceName: device,
                                 identifier: identifier, version: "27.0.1", build: build)
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
