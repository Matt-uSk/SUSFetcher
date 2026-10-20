import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Modèles (API ipsw.me v4)

enum IPSWFamily: String, CaseIterable, Identifiable, Sendable {
    case iPhone, iPad, mac
    var id: String { rawValue }

    /// Filtre sur l'identifiant Apple (iPhone17,1, iPad16,3, Mac14,2, VirtualMac2,1…).
    func matches(_ identifier: String) -> Bool {
        switch self {
        case .iPhone: identifier.hasPrefix("iPhone")
        case .iPad: identifier.hasPrefix("iPad")
        case .mac: identifier.hasPrefix("Mac") || identifier.hasPrefix("VirtualMac")
        }
    }
}

struct IPSWDevice: Identifiable, Hashable, Decodable, Sendable {
    let name: String
    let identifier: String
    var id: String { identifier }
}

struct IPSWFirmware: Identifiable, Hashable, Sendable {
    let identifier: String
    let version: String
    let build: String
    let sha256: String?
    let size: Int64
    let url: URL
    let releaseDate: Date?
    let signed: Bool

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
    var sortDate: Date { releaseDate ?? .distantPast }
    var signedRank: Int { signed ? 1 : 0 }
}

private struct FirmwareDTO: Decodable {
    let identifier: String
    let version: String
    let buildid: String
    let sha256sum: String?
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

    @MainActor var message: String {
        switch self {
        case .http(let code):
            tr("ipsw.me a répondu HTTP \(code).", "ipsw.me responded with HTTP \(code).")
        }
    }
}

// MARK: - Service

/// Client de l'API publique https://api.ipsw.me/v4 (liste des appareils + firmwares).
actor IPSWService {
    private let session: URLSession
    private let base = URL(string: "https://api.ipsw.me/v4")!
    private let devicesCacheURL: URL

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "SUSFetcher (+https://github.com/Matt-uSk/SUSFetcher)"]
        session = URLSession(configuration: config)

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SUSFetcher", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        devicesCacheURL = dir.appending(path: "ipsw-devices.json")
    }

    /// Liste des appareils, mise en cache 24 h sur disque (elle change rarement).
    func devices(forceRefresh: Bool = false) async throws -> [IPSWDevice] {
        if !forceRefresh,
           let attrs = try? FileManager.default.attributesOfItem(atPath: devicesCacheURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 24 * 3600,
           let data = try? Data(contentsOf: devicesCacheURL),
           let cached = try? JSONDecoder().decode([IPSWDevice].self, from: data) {
            return cached
        }
        let data = try await get(base.appending(path: "devices"))
        let list = try JSONDecoder().decode([IPSWDevice].self, from: data)
        try? data.write(to: devicesCacheURL, options: .atomic)
        return list
    }

    func firmwares(for identifier: String) async throws -> [IPSWFirmware] {
        var components = URLComponents(url: base.appending(path: "device/\(identifier)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "type", value: "ipsw")]
        let data = try await get(components.url!)
        let dto = try JSONDecoder().decode(DeviceDetailDTO.self, from: data)

        let iso = ISO8601DateFormatter()
        return dto.firmwares.compactMap { f in
            guard let url = URL(string: f.url) else { return nil }
            let date = (f.releasedate ?? f.uploaddate).flatMap { iso.date(from: $0) }
            return IPSWFirmware(identifier: f.identifier, version: f.version, build: f.buildid,
                                sha256: f.sha256sum, size: f.filesize ?? 0, url: url,
                                releaseDate: date, signed: f.signed ?? false)
        }
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw IPSWError.http(http.statusCode)
        }
        return data
    }
}

// MARK: - Modèle d'UI

@Observable
@MainActor
final class IPSWModel {
    static let shared = IPSWModel()

    private(set) var devices: [IPSWDevice] = []
    private(set) var isLoadingDevices = false
    private(set) var devicesError: String?

    private(set) var firmwares: [String: [IPSWFirmware]] = [:]
    private(set) var loadingFirmwares: Set<String> = []
    private(set) var firmwareErrors: [String: String] = [:]

    var selection: [IPSWFamily: String] = [:]
    var signedOnly = false
    var firmwareSelection = Set<IPSWFirmware.ID>()
    var sortOrder = [KeyPathComparator(\IPSWFirmware.sortDate, order: .reverse)]

    @ObservationIgnored private let service = IPSWService()

    func devices(in family: IPSWFamily) -> [IPSWDevice] {
        devices.filter { family.matches($0.identifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
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
                devices = try await service.devices(forceRefresh: force)
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
                firmwares[identifier] = try await service.firmwares(for: identifier)
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
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            firmwaresColumn
                .frame(minWidth: 480, maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear { model.loadDevicesIfNeeded() }
    }

    // Colonne appareils

    private var devicesColumn: some View {
        List(selection: Binding(get: { selectedID }, set: { model.select($0, in: family) })) {
            ForEach(deviceList) { d in
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).lineLimit(1)
                    Text(d.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .tag(d.identifier)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.isLoadingDevices && model.devices.isEmpty {
                ProgressView(tr("Chargement des appareils…", "Loading devices…"))
            } else if let error = model.devicesError, model.devices.isEmpty {
                ContentUnavailableView {
                    Label(tr("ipsw.me indisponible", "ipsw.me unavailable"), systemImage: "exclamationmark.triangle")
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
                        Text(device.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
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
                Divider()
                IPSWFirmwareTable(firmwares: rows(for: device),
                                  device: device,
                                  downloads: downloads,
                                  selection: Binding(model, \.firmwareSelection),
                                  sortOrder: Binding(model, \.sortOrder))
                    .overlay { firmwareOverlay(device) }
            }
        } else {
            ContentUnavailableView(tr("Choisir un appareil", "Choose a device"),
                                   systemImage: icon,
                                   description: Text(tr("Les firmwares (IPSW) du modèle sélectionné s'affichent ici.",
                                                        "Firmwares (IPSW) for the selected model appear here.")))
        }
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
        HStack {
            Text(tr("Données : ", "Data: ") + "ipsw.me")
                .foregroundStyle(.secondary)
            Link("ipsw.me", destination: URL(string: "https://ipsw.me")!)
                .font(.callout)
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
                Text(formatBytes(f.size)).monospacedDigit()
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
                if let sha = f.sha256 {
                    Button(tr("Copier le SHA-256", "Copy SHA-256")) { copy(sha) }
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
                           sha256: f.sha256)
    }
}
