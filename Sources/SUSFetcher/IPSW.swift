import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Modèles

enum IPSWFamily: String, CaseIterable, Identifiable, Sendable {
    case iPhone, iPad, mac
    var id: String { rawValue }

    /// Filtre sur l'identifiant Apple (iPhone17,1, iPad16,3, Mac14,2, iMac24,1, VirtualMac2,1…).
    func matches(_ identifier: String) -> Bool {
        switch self {
        case .iPhone: identifier.hasPrefix("iPhone")
        case .iPad: identifier.hasPrefix("iPad")
        case .mac: identifier.hasPrefix("Mac") || identifier.hasPrefix("iMac") || identifier.hasPrefix("VirtualMac")
        }
    }
}

struct IPSWDevice: Identifiable, Hashable, Codable, Sendable {
    let name: String
    let identifier: String
    var id: String { identifier }

    /// (génération, variante) tirées de l'identifiant : iPhone18,3 → (18, 3). Sert au tri « plus récent d'abord ».
    var generation: (Int, Int) {
        let digits = identifier.drop { !$0.isNumber }
        let parts = digits.split(separator: ",")
        return (Int(parts.first ?? "") ?? 0, Int(parts.dropFirst().first ?? "") ?? 0)
    }
}

struct IPSWFirmware: Identifiable, Hashable, Codable, Sendable {
    let identifier: String
    let version: String
    let build: String
    let sha256: String?
    var sha1: String? = nil
    var size: Int64
    let url: URL
    var releaseDate: Date?
    let signed: Bool

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
    var sortDate: Date { releaseDate ?? .distantPast }
    var signedRank: Int { signed ? 1 : 0 }

    /// Empreinte à vérifier après téléchargement : SHA-256 (ipsw.me) sinon SHA-1 (Apple).
    var checksum: DownloadItem.Checksum? {
        if let sha256, !sha256.isEmpty { return .init(algorithm: .sha256, value: sha256) }
        if let sha1, !sha1.isEmpty { return .init(algorithm: .sha1, value: sha1) }
        return nil
    }
}

/// D'où viennent les données affichées.
enum IPSWSource: Equatable, Sendable {
    case ipswme                 // API ipsw.me (normal)
    case cache(Date)            // ipsw.me injoignable : dernière copie enregistrée
    case apple                  // ipsw.me injoignable, pas de cache : listes officielles Apple
}

private struct FirmwareDTO: Decodable {
    let identifier: String
    let version: String
    let buildid: String
    let sha256sum: String?
    let sha1sum: String?
    let filesize: Int64?
    let url: String
    let releasedate: String?
    let uploaddate: String?
    let signed: Bool?
}

private struct DeviceDetailDTO: Decodable {
    let firmwares: [FirmwareDTO]
}

enum IPSWError: Error {
    case http(Int)
    case notFound

    @MainActor var message: String {
        switch self {
        case .http(let code):
            tr("ipsw.me a répondu HTTP \(code).", "ipsw.me responded with HTTP \(code).")
        case .notFound:
            tr("Aucune source disponible pour ce modèle (ipsw.me et Apple injoignables).",
               "No source available for this model (ipsw.me and Apple unreachable).")
        }
    }
}

// MARK: - Service

/// Données IPSW avec repli en cascade :
/// 1. API ipsw.me (historique complet, statut de signature, SHA-256)
/// 2. dernière copie enregistrée sur le disque
/// 3. listes officielles Apple (dernière version signée par modèle, SHA-1)
actor IPSWService {
    private let session: URLSession
    private let base = URL(string: "https://api.ipsw.me/v4")!
    private let cacheDir: URL
    private var appleIndex: [String: IPSWFirmware]?

    /// Listes publiques qu'Apple utilise pour les restaurations (Finder / Apple Configurator).
    private static let appleFeeds = [
        URL(string: "https://itunes.apple.com/WebObjects/MZStore.woa/wa/com.apple.jingle.appserver.client.MZITunesClientCheck/version")!,
        URL(string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")!,
    ]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "SUSFetcher (+https://github.com/Matt-uSk/SUSFetcher)"]
        session = URLSession(configuration: config)

        cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SUSFetcher/ipsw", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: Appareils

    func devices(forceRefresh: Bool) async throws -> (devices: [IPSWDevice], source: IPSWSource) {
        let file = cacheDir.appending(path: "devices.json")
        if !forceRefresh, let cached: [IPSWDevice] = readCache(file),
           let date = modificationDate(file), Date().timeIntervalSince(date) < 24 * 3600 {
            return (cached, .ipswme)
        }
        do {
            let data = try await get(base.appending(path: "devices"))
            let list = try JSONDecoder().decode([IPSWDevice].self, from: data)
            writeCache(list, to: file)
            return (list, .ipswme)
        } catch {
            if let cached: [IPSWDevice] = readCache(file), let date = modificationDate(file) {
                return (cached, .cache(date))
            }
            // Repli Apple : pas de nom commercial, l'identifiant sert de nom.
            let index = await loadAppleIndex()
            guard !index.isEmpty else { throw error }
            let list = index.keys.map { IPSWDevice(name: $0, identifier: $0) }
            return (list, .apple)
        }
    }

    // MARK: Firmwares

    func firmwares(for identifier: String) async throws -> (firmwares: [IPSWFirmware], source: IPSWSource) {
        let file = cacheDir.appending(path: "fw-\(identifier).json")
        do {
            var components = URLComponents(url: base.appending(path: "device/\(identifier)"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "type", value: "ipsw")]
            let data = try await get(components.url!)
            let dto = try JSONDecoder().decode(DeviceDetailDTO.self, from: data)
            let iso = ISO8601DateFormatter()
            let list: [IPSWFirmware] = dto.firmwares.compactMap { f in
                guard let url = URL(string: f.url) else { return nil }
                return IPSWFirmware(identifier: f.identifier, version: f.version, build: f.buildid,
                                    sha256: f.sha256sum, sha1: f.sha1sum, size: f.filesize ?? 0, url: url,
                                    releaseDate: (f.releasedate ?? f.uploaddate).flatMap { iso.date(from: $0) },
                                    signed: f.signed ?? false)
            }
            writeCache(list, to: file)
            return (list, .ipswme)
        } catch {
            if let cached: [IPSWFirmware] = readCache(file), let date = modificationDate(file) {
                return (cached, .cache(date))
            }
            guard var latest = await loadAppleIndex()[identifier] else {
                throw (error as? IPSWError) ?? IPSWError.notFound
            }
            // Taille et date via une requête HEAD sur le fichier lui-même.
            if let info = await headInfo(latest.url) {
                latest.size = info.0
                latest.releaseDate = info.1
            }
            return ([latest], .apple)
        }
    }

    // MARK: Listes Apple

    private func loadAppleIndex() async -> [String: IPSWFirmware] {
        if let appleIndex { return appleIndex }
        var index: [String: IPSWFirmware] = [:]
        await withTaskGroup(of: [String: IPSWFirmware].self) { group in
            for feed in Self.appleFeeds {
                group.addTask { [session] in
                    guard let (data, response) = try? await session.data(from: feed),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
                    return Self.parseAppleFeed(data)
                }
            }
            for await part in group { index.merge(part) { a, _ in a } }
        }
        if !index.isEmpty { appleIndex = index }
        return index
    }

    /// Structure : MobileDeviceSoftwareVersionsByVersion › <n> › MobileDeviceSoftwareVersions ›
    /// <ProductType> › <build | Unknown › Universal> › Restore { ProductVersion, BuildVersion, FirmwareURL, FirmwareSHA1 }
    static func parseAppleFeed(_ data: Data) -> [String: IPSWFirmware] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let byVersion = root["MobileDeviceSoftwareVersionsByVersion"] as? [String: Any],
              let latestKey = byVersion.keys.compactMap(Int.init).max(),
              let latest = byVersion[String(latestKey)] as? [String: Any],
              let products = latest["MobileDeviceSoftwareVersions"] as? [String: Any] else { return [:] }

        var result: [String: IPSWFirmware] = [:]
        for (productType, value) in products {
            guard let entries = value as? [String: Any] else { continue }
            var restores: [[String: Any]] = []
            for (_, entry) in entries {
                guard let dict = entry as? [String: Any] else { continue }
                if let r = dict["Restore"] as? [String: Any] { restores.append(r); continue }
                for (_, nested) in dict {
                    if let r = (nested as? [String: Any])?["Restore"] as? [String: Any] { restores.append(r) }
                }
            }
            let best = restores.max {
                ($0["ProductVersion"] as? String ?? "")
                    .compare($1["ProductVersion"] as? String ?? "", options: .numeric) == .orderedAscending
            }
            guard let r = best,
                  let urlString = r["FirmwareURL"] as? String, let url = URL(string: urlString),
                  let version = r["ProductVersion"] as? String else { continue }
            result[productType] = IPSWFirmware(identifier: productType, version: version,
                                               build: r["BuildVersion"] as? String ?? "",
                                               sha256: nil, sha1: r["FirmwareSHA1"] as? String,
                                               size: 0, url: url, releaseDate: nil, signed: true)
        }
        return result
    }

    private func headInfo(_ url: URL) async -> (Int64, Date?)? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let size = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = http.value(forHTTPHeaderField: "Last-Modified").flatMap { formatter.date(from: $0) }
        return (size, date)
    }

    // MARK: Réseau / cache disque

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw IPSWError.http(http.statusCode)
        }
        return data
    }

    private func readCache<T: Decodable>(_ file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func writeCache<T: Encodable>(_ value: T, to file: URL) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: file, options: .atomic) }
    }

    private func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}

// MARK: - Modèle d'UI

@Observable
@MainActor
final class IPSWModel {
    static let shared = IPSWModel()

    private(set) var devices: [IPSWDevice] = []
    private(set) var devicesSource: IPSWSource?
    private(set) var isLoadingDevices = false
    private(set) var devicesError: String?

    private(set) var firmwares: [String: [IPSWFirmware]] = [:]
    private(set) var firmwareSources: [String: IPSWSource] = [:]
    private(set) var loadingFirmwares: Set<String> = []
    private(set) var firmwareErrors: [String: String] = [:]

    var selection: [IPSWFamily: String] = [:]
    var signedOnly = false
    var firmwareSelection = Set<IPSWFirmware.ID>()
    var sortOrder = [KeyPathComparator(\IPSWFirmware.sortDate, order: .reverse)]

    @ObservationIgnored private let service = IPSWService()

    /// Plus récent d'abord : iPhone18,3 avant iPhone18,1 avant iPhone17,5…
    func devices(in family: IPSWFamily) -> [IPSWDevice] {
        devices.filter { family.matches($0.identifier) }
            .sorted { a, b in
                let (ga, gb) = (a.generation, b.generation)
                if ga.0 != gb.0 { return ga.0 > gb.0 }
                if ga.1 != gb.1 { return ga.1 > gb.1 }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    func count(_ family: IPSWFamily) -> Int { devices.filter { family.matches($0.identifier) }.count }

    func loadDevicesIfNeeded() {
        guard devices.isEmpty, !isLoadingDevices else { return }
        reloadDevices(force: false)
    }

    func reloadDevices(force: Bool) {
        isLoadingDevices = true
        devicesError = nil
        Task {
            do {
                let result = try await service.devices(forceRefresh: force)
                devices = result.devices
                devicesSource = result.source
            } catch {
                devicesError = (error as? IPSWError)?.message ?? error.localizedDescription
            }
            isLoadingDevices = false
        }
    }

    func select(_ identifier: String?, in family: IPSWFamily) {
        selection[family] = identifier
        firmwareSelection.removeAll()
        if let identifier { loadFirmwares(identifier, force: false) }
    }

    func loadFirmwares(_ identifier: String, force: Bool) {
        guard force || firmwares[identifier] == nil, !loadingFirmwares.contains(identifier) else { return }
        loadingFirmwares.insert(identifier)
        firmwareErrors[identifier] = nil
        Task {
            do {
                let result = try await service.firmwares(for: identifier)
                firmwares[identifier] = result.firmwares
                firmwareSources[identifier] = result.source
            } catch {
                firmwareErrors[identifier] = (error as? IPSWError)?.message ?? error.localizedDescription
            }
            loadingFirmwares.remove(identifier)
        }
    }
}

// MARK: - Vue

struct IPSWPane: View {
    let family: IPSWFamily
    let model: IPSWModel
    let downloads: DownloadManager
    let search: String

    private var deviceList: [IPSWDevice] {
        let all = model.devices(in: family)
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.identifier.localizedCaseInsensitiveContains(q)
        }
    }

    private var selectedID: String? { model.selection[family] }
    private var selectedDevice: IPSWDevice? { model.devices.first { $0.identifier == selectedID } }

    var body: some View {
        HSplitView {
            devicesColumn
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 380, maxHeight: .infinity)
            firmwaresColumn
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear { model.loadDevicesIfNeeded() }
    }

    // Colonne appareils

    private var devicesColumn: some View {
        List(selection: Binding(get: { selectedID }, set: { model.select($0, in: family) })) {
            ForEach(deviceList) { d in
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).lineLimit(1)
                    if d.name != d.identifier {
                        Text(d.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(d.identifier)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.isLoadingDevices && model.devices.isEmpty {
                ProgressView(tr("Chargement des appareils…", "Loading devices…"))
            } else if let error = model.devicesError, model.devices.isEmpty {
                ContentUnavailableView {
                    Label(tr("Aucune source disponible", "No source available"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(tr("Réessayer", "Retry")) { model.reloadDevices(force: true) }
                }
            } else if deviceList.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    // Colonne firmwares

    @ViewBuilder
    private var firmwaresColumn: some View {
        if let device = selectedDevice {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.headline)
                        if device.name != device.identifier {
                            Text(device.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle(tr("Signés uniquement", "Signed only"), isOn: Binding(model, \.signedOnly))
                        .toggleStyle(.checkbox)
                    Button {
                        model.loadFirmwares(device.identifier, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Recharger", "Reload"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if let banner = fallbackBanner(model.firmwareSources[device.identifier]) {
                    banner
                }
                Divider()
                IPSWFirmwareTable(firmwares: rows(for: device),
                                  device: device,
                                  downloads: downloads,
                                  selection: Binding(model, \.firmwareSelection),
                                  sortOrder: Binding(model, \.sortOrder))
                    .frame(maxHeight: .infinity)
                    .overlay { firmwareOverlay(device) }
            }
        } else {
            ContentUnavailableView(tr("Choisir un appareil", "Choose a device"),
                                   systemImage: icon,
                                   description: Text(tr("Les firmwares (IPSW) du modèle sélectionné s'affichent ici.",
                                                        "Firmwares (IPSW) for the selected model appear here.")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Bandeau affiché quand ipsw.me n'a pas répondu.
    private func fallbackBanner(_ source: IPSWSource?) -> AnyView? {
        let text: String
        switch source {
        case .cache(let date)?:
            let d = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppSettings.shared.locale))
            text = tr("ipsw.me ne répond pas — données enregistrées le \(d).",
                      "ipsw.me is not responding — data saved on \(d).")
        case .apple?:
            text = tr("ipsw.me ne répond pas — source de secours Apple : dernière version signée uniquement.",
                      "ipsw.me is not responding — Apple fallback: latest signed version only.")
        default:
            return nil
        }
        return AnyView(
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
        )
    }

    private func rows(for device: IPSWDevice) -> [IPSWFirmware] {
        let list = model.firmwares[device.identifier] ?? []
        let filtered = model.signedOnly ? list.filter(\.signed) : list
        return filtered.sorted(using: model.sortOrder)
    }

    @ViewBuilder
    private func firmwareOverlay(_ device: IPSWDevice) -> some View {
        if model.loadingFirmwares.contains(device.identifier) && model.firmwares[device.identifier] == nil {
            ProgressView()
        } else if let error = model.firmwareErrors[device.identifier] {
            ContentUnavailableView {
                Label(tr("Impossible de charger les firmwares", "Could not load firmwares"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(tr("Réessayer", "Retry")) { model.loadFirmwares(device.identifier, force: true) }
            }
        } else if rows(for: device).isEmpty, model.firmwares[device.identifier] != nil {
            ContentUnavailableView(model.signedOnly
                                   ? tr("Aucun firmware signé", "No signed firmware")
                                   : tr("Aucun firmware", "No firmware"),
                                   systemImage: "lock.slash")
        }
    }

    private var icon: String {
        switch family {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            sourceLabel
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

    @ViewBuilder
    private var sourceLabel: some View {
        switch model.devicesSource {
        case .cache?:
            Label(tr("Source : ipsw.me (hors ligne, cache)", "Source: ipsw.me (offline, cached)"),
                  systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        case .apple?:
            Label(tr("Source : Apple (secours)", "Source: Apple (fallback)"), systemImage: "applelogo")
                .foregroundStyle(.orange)
        default:
            HStack(spacing: 4) {
                Text(tr("Source :", "Source:")).foregroundStyle(.secondary)
                Link("ipsw.me", destination: URL(string: "https://ipsw.me")!)
            }
        }
    }
}

struct IPSWFirmwareTable: View {
    let firmwares: [IPSWFirmware]
    let device: IPSWDevice
    let downloads: DownloadManager
    @Binding var selection: Set<IPSWFirmware.ID>
    @Binding var sortOrder: [KeyPathComparator<IPSWFirmware>]

    var body: some View {
        Table(firmwares, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Version", value: \.version) { f in
                Text(f.version).fontWeight(f.signed ? .semibold : .regular)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Build", value: \.build) { f in
                Text(f.build).monospaced()
            }
            .width(min: 70, ideal: 85)

            TableColumn(tr("Signé", "Signed"), value: \.signedRank) { f in
                if f.signed {
                    Label(tr("Signé", "Signed"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(tr("Non", "No")).foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 80)

            TableColumn("Date", value: \.sortDate) { f in
                if let d = f.releaseDate {
                    Text(d, format: .dateTime.day(.twoDigits).month(.twoDigits).year()).monospacedDigit()
                }
            }
            .width(min: 80, ideal: 90)

            TableColumn(tr("Taille", "Size"), value: \.size) { f in
                if f.size > 0 { Text(formatBytes(f.size)).monospacedDigit() }
            }
            .width(min: 70, ideal: 80)

            TableColumn("") { f in
                IPSWActionCell(firmware: f, device: device, downloads: downloads)
            }
            .width(min: 150, ideal: 170)
        }
        .contextMenu(forSelectionType: IPSWFirmware.ID.self) { ids in
            if let f = firmwares.first(where: { ids.contains($0.id) }) {
                Button(tr("Copier l'URL", "Copy URL")) { copy(f.url.absoluteString) }
                if let c = f.checksum {
                    Button(tr("Copier le \(c.algorithm.rawValue)", "Copy \(c.algorithm.rawValue)")) { copy(c.value) }
                }
            }
        } primaryAction: { ids in
            for f in firmwares where ids.contains(f.id) { IPSWActionCell.start(f, device: device, downloads: downloads) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct IPSWActionCell: View {
    let firmware: IPSWFirmware
    let device: IPSWDevice
    let downloads: DownloadManager

    var body: some View {
        DownloadControl(
            state: downloads.state(of: firmware.url),
            idleTitle: "IPSW",
            start: {
                switch downloads.state(of: firmware.url) {
                case .paused?: downloads.resume(firmware.url)
                case .failed?: downloads.retry(firmware.url)
                default: Self.start(firmware, device: device, downloads: downloads)
                }
            },
            cancel: { downloads.cancel(firmware.url) }
        )
    }

    /// Enregistre dans <dossier>/IPSW/<nom d'origine Apple>.
    @MainActor
    static func start(_ f: IPSWFirmware, device: IPSWDevice, downloads: DownloadManager) {
        let folder = downloads.destinationFolder.appending(path: "IPSW", directoryHint: .isDirectory)
        downloads.download(url: f.url, size: f.size,
                           to: folder.appending(path: f.fileName),
                           title: "\(device.name) — \(f.version) (\(f.build))",
                           checksum: f.checksum)
    }
}
