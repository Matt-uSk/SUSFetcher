import AppKit
import SwiftUI

/// Cellule « Sécurité » : failles corrigées par cette version (SOFA), et alerte si une version
/// plus récente de la même série corrige des failles activement exploitées.
struct SecurityCell: View {
    let platform: SOFAPlatform
    let version: String
    var build: String? = nil
    var identifier: String? = nil

    var body: some View {
        let sofa = SOFAModel.shared
        let release = sofa.release(platform, version: version, build: build)
        let later = sofa.exploitedFixedLater(platform, after: version, identifier: identifier)
        HStack(spacing: 5) {
            if let release {
                Button {
                    if let url = release.securityInfo { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "shield.lefthalf.filled")
                        Text("\(release.cveCount)").monospacedDigit()
                        if !release.exploited.isEmpty {
                            Text(tr("\(release.exploited.count) expl.", "\(release.exploited.count) expl."))
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(priorityColor(release.priority)))
                        }
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(release.cveCount == 0 ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .help(fixesText(release))
            }
            if later.count > 0, let fixedIn = later.fixedIn {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(tr("Version dépassée : \(fixedIn) et suivantes corrigent \(later.count) faille(s) activement exploitée(s).",
                             "Outdated: \(fixedIn) and later fix \(later.count) actively exploited vulnerabilit\(later.count > 1 ? "ies" : "y")."))
            }
        }
        .font(.callout)
    }
}

func priorityColor(_ priority: String?) -> Color {
    switch priority {
    case "critical": .red
    case "high": .orange
    default: .secondary
    }
}

@MainActor
func fixesText(_ r: SOFARelease) -> String {
    var lines: [String] = []
    if r.exploited.isEmpty {
        lines.append(tr("Corrige \(r.cveCount) faille(s) de sécurité.", "Fixes \(r.cveCount) security issue(s)."))
    } else {
        lines.append(tr("Corrige \(r.cveCount) faille(s), dont \(r.exploited.count) activement exploitée(s) : \(r.exploited.joined(separator: ", ")).",
                        "Fixes \(r.cveCount) issue(s), including \(r.exploited.count) actively exploited: \(r.exploited.joined(separator: ", "))."))
    }
    if let s = r.summary, !r.exploited.isEmpty { lines.append(s) }
    if let rec = r.recommendation { lines.append(rec) }
    if r.securityInfo != nil { lines.append(tr("Cliquer pour ouvrir l'avis de sécurité Apple.", "Click to open Apple's security advisory.")) }
    lines.append(tr("Source : SOFA (macadmins.io)", "Source: SOFA (macadmins.io)"))
    return lines.joined(separator: "\n")
}

/// Pastille « compatible avec le Mac choisi » pour un installer macOS.
struct CompatibilityCell: View {
    let major: Int?
    let model: String?

    var body: some View {
        if let major, let model, let ok = SOFAModel.shared.supports(model: model, major: major) {
            let name = SOFAModel.shared.macModelName(model) ?? model
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .help(ok ? tr("Compatible avec \(name)", "Compatible with \(name)")
                         : tr("Non compatible avec \(name)", "Not compatible with \(name)"))
        }
    }
}

extension SUProduct {
    /// Version majeure de macOS d'un installer (« 26.2 » → 26).
    var macOSMajor: Int? {
        guard isInstaller else { return nil }
        return Int(versionString.split(separator: ".").first ?? "")
    }
}

/// Bloc sécurité de la fiche d'un iPhone / iPad branché.
struct DeviceSecuritySummary: View {
    let version: String
    let identifier: String?

    var body: some View {
        let sofa = SOFAModel.shared
        let later = sofa.laterReleases(.iOS, after: version, identifier: identifier)
        if !later.isEmpty {
            let cves = later.reduce(0) { $0 + $1.cveCount }
            let exploited = Set(later.flatMap(\.exploited))
            let worst = later.contains { $0.priority == "critical" } ? "critical"
                : (later.contains { $0.priority == "high" } ? "high" : nil)
            let newest = later.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
            HStack(spacing: 6) {
                Image(systemName: exploited.isEmpty ? "shield.lefthalf.filled" : "exclamationmark.shield.fill")
                Text(exploited.isEmpty
                     ? tr("Les mises à jour depuis \(version) corrigent \(cves) faille(s).",
                          "Updates since \(version) fix \(cves) issue(s).")
                     : tr("Les mises à jour depuis \(version) corrigent \(cves) faille(s), dont \(exploited.count) activement exploitée(s).",
                          "Updates since \(version) fix \(cves) issue(s), including \(exploited.count) actively exploited."))
                if let url = newest?.securityInfo {
                    Link(tr("Détails", "Details"), destination: url)
                }
            }
            .font(.callout)
            .foregroundStyle(exploited.isEmpty ? Color.secondary : priorityColor(worst))
            .help(newest?.recommendation ?? "")
        } else if let current = sofa.release(.iOS, version: version) {
            Label(tr("Version actuelle : corrige \(current.cveCount) faille(s), aucune mise à jour de sécurité plus récente dans cette série.",
                     "Current version: fixes \(current.cveCount) issue(s), no newer security update in this series."),
                  systemImage: "checkmark.shield.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Menu de la barre d'outils : Mac de référence et filtre des installers incompatibles.
struct CompatibilityMenu: View {
    let state: ViewState
    let sofa: SOFAModel

    var body: some View {
        let current = state.effectiveCompatModel
        let name = current.flatMap { sofa.macModelName($0) } ?? current ?? "—"
        Menu {
            Toggle(tr("Masquer les installers incompatibles", "Hide incompatible installers"),
                   isOn: Binding(state, \.hideIncompatible))
            Divider()
            Picker(tr("Vérifier pour", "Check for"), selection: Binding(state, \.compatModel)) {
                Text(tr("Ce Mac", "This Mac") + (SOFAModel.thisMacModel.flatMap { sofa.macModelName($0) }.map { " (\($0))" } ?? ""))
                    .tag(String?.none)
                Divider()
                ForEach(sofa.macModelList) { m in
                    Text("\(m.name) — \(m.id)").tag(Optional(m.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(state.hideIncompatible ? tr("Compatibles : \(name)", "Compatible: \(name)") : tr("Compatibilité", "Compatibility"),
                  systemImage: state.hideIncompatible ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .help(tr("Compatibilité des installers avec \(name) (données SOFA)",
                 "Installer compatibility with \(name) (SOFA data)"))
    }
}

// MARK: - Fiche « Sécurité et compatibilité » (clic droit)

struct SecurityInfoRequest: Identifiable {
    let id = UUID()
    let title: String
    let platform: SOFAPlatform
    let version: String
    let build: String?
    let identifier: String?
}

struct SecurityInfoView: View {
    let request: SecurityInfoRequest
    let state: ViewState
    let sofa: SOFAModel

    var body: some View {
        let release = sofa.release(request.platform, version: request.version, build: request.build)
        let later = sofa.laterReleases(request.platform, after: request.version, identifier: request.identifier)
        let laterExploited = Set(later.flatMap(\.exploited))
        let newest = later.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.title3.weight(.semibold))
                Text([request.version, request.build].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !sofa.enabled {
                        Label(tr("SOFA est désactivé (Réglages › Catalogue).", "SOFA is turned off (Settings › Catalog)."),
                              systemImage: "power").foregroundStyle(.secondary)
                    } else {
                        securitySection(release)
                        if !laterExploited.isEmpty, let newest {
                            warningBox(tr("Version dépassée : les versions suivantes corrigent \(laterExploited.count) faille(s) activement exploitée(s). Préférez \(newest.version).",
                                          "Outdated: later versions fix \(laterExploited.count) actively exploited vulnerabilit\(laterExploited.count > 1 ? "ies" : "y"). Prefer \(newest.version)."),
                                       color: priorityColor(newest.priority ?? "critical"))
                        } else if !later.isEmpty, let newest {
                            Label(tr("Une version plus récente existe : \(newest.version).", "A newer version exists: \(newest.version)."),
                                  systemImage: "arrow.up.circle").foregroundStyle(.secondary)
                        }
                        if request.platform == .macOS, let major = Int(request.version.split(separator: ".").first ?? "") {
                            compatibilitySection(major)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Link(tr("Source : SOFA", "Source: SOFA"), destination: SOFAModel.website).font(.caption)
                Spacer()
                Button(tr("Fermer", "Close")) { state.securityInfo = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
        .environment(\.locale, AppSettings.shared.locale)
    }

    @ViewBuilder
    private func securitySection(_ release: SOFARelease?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Sécurité", "Security")).font(.headline)
            if let r = release {
                HStack(spacing: 8) {
                    Image(systemName: r.exploited.isEmpty ? "shield.lefthalf.filled" : "exclamationmark.shield.fill")
                        .foregroundStyle(r.exploited.isEmpty ? Color.secondary : priorityColor(r.priority))
                    Text(tr("Corrige \(r.cveCount) faille(s) de sécurité", "Fixes \(r.cveCount) security issue(s)"))
                    if let d = r.releaseDate {
                        Text("· " + d.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    }
                }
                if !r.exploited.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Activement exploitées :", "Actively exploited:")).font(.callout.weight(.semibold))
                        ForEach(r.exploited, id: \.self) { cve in
                            if let url = URL(string: "https://nvd.nist.gov/vuln/detail/\(cve)") {
                                Link(cve, destination: url).font(.callout.monospaced())
                            }
                        }
                    }
                    if let s = r.summary { Text(s).font(.callout).foregroundStyle(.secondary) }
                }
                if let rec = r.recommendation {
                    Text(rec).font(.callout).foregroundStyle(priorityColor(r.priority))
                }
                if let url = r.securityInfo {
                    Link(tr("Avis de sécurité Apple", "Apple security advisory"), destination: url).font(.callout)
                }
            } else {
                Text(tr("Aucune information pour cette version (bêta, version trop ancienne, ou données pas encore chargées).",
                        "No information for this version (beta, too old, or data not loaded yet)."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func compatibilitySection(_ major: Int) -> some View {
        let models = sofa.macModelList.filter { sofa.supports(model: $0.id, major: major) == true }
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Compatibilité", "Compatibility")).font(.headline)
            if let me = SOFAModel.thisMacModel {
                compatRow(model: me, label: tr("Ce Mac", "This Mac"), major: major)
            }
            if let other = state.compatModel, other != SOFAModel.thisMacModel {
                compatRow(model: other, label: tr("Mac choisi", "Selected Mac"), major: major)
            }
            if models.isEmpty {
                Text(tr("Liste des modèles indisponible pour macOS \(major).", "Model list unavailable for macOS \(major)."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(tr("\(models.count) modèles compatibles", "\(models.count) compatible models")) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(models) { m in
                            HStack {
                                Text(m.name)
                                Spacer()
                                Text(m.id).monospaced().foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func compatRow(model: String, label: String, major: Int) -> some View {
        let name = sofa.macModelName(model) ?? model
        switch sofa.supports(model: model, major: major) {
        case true?:
            Label("\(label) (\(name)) : " + tr("compatible", "compatible"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case false?:
            Label("\(label) (\(name)) : " + tr("non compatible", "not compatible"), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        case nil:
            Label("\(label) (\(name)) : " + tr("inconnu", "unknown"), systemImage: "questionmark.circle")
                .foregroundStyle(.secondary).font(.callout)
        }
    }

    private func warningBox(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }
}
