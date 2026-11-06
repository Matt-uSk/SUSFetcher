import CryptoKit
import Foundation
import Observation

/// Index des fichiers déjà présents dans le dossier de destination, pour reconnaître un paquet
/// ou un IPSW même **renommé** : même taille à l'octet près, puis même empreinte (SHA-1 / SHA-256).
///
/// - Le scan ne liste que les .pkg et .ipsw (sous-dossiers compris, 4 niveaux max).
/// - Une empreinte n'est calculée que pour un fichier dont la taille correspond à un élément recherché,
///   puis gardée en cache (chemin + taille + date de modification) : chaque fichier n'est hashé qu'une fois.
@Observable
@MainActor
final class LocalFiles {
    static let shared = LocalFiles()

    struct ScannedFile: Sendable {
        let url: URL
        let size: Int64
        let modified: Double
    }

    struct Fingerprint: Codable, Sendable {
        let size: Int64
        let modified: Double
        /// Empreintes du fichier entier (IPSW).
        var sha1: String?
        var sha256: String?
        /// SHA-1 de la TOC xar (paquets .pkg) = « Digest » du catalogue Apple.
        var xarTOC: String?
    }

    private(set) var filesBySize: [Int64: [ScannedFile]] = [:]
    private(set) var fingerprints: [String: Fingerprint] = [:]
    private(set) var hashingCount = 0

    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    nonisolated private static let extensions: Set<String> = ["pkg", "ipsw"]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SUSFetcher", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appending(path: "file-hashes.json")
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: Fingerprint].self, from: data) {
            fingerprints = decoded
        }
    }

    // MARK: Scan

    /// Relit le contenu du dossier de destination (rapide : simple listing, pas de hash).
    func rescan() {
        let folder = DownloadManager.shared.destinationFolder
        scanTask?.cancel()
        scanTask = Task {
            let files = await Task.detached(priority: .utility) { Self.scan(folder) }.value
            guard !Task.isCancelled else { return }
            filesBySize = Dictionary(grouping: files, by: \.size)
        }
    }

    nonisolated private static func scan(_ folder: URL) -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [ScannedFile] = []
        for case let url as URL in enumerator {
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0 else { continue }
            result.append(ScannedFile(url: url, size: Int64(size),
                                      modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return result
    }

    // MARK: Recherche

    /// Fichier local ayant cette taille et cette empreinte. Lance en arrière-plan le calcul des
    /// empreintes manquantes des candidats : la vue se met à jour quand il est prêt.
    func match(size: Int64, sha1: String? = nil, sha256: String? = nil, xarTOC: String? = nil) -> URL? {
        let sha1 = sha1?.lowercased(), sha256 = sha256?.lowercased(), xarTOC = xarTOC?.lowercased()
        guard size > 0, sha1 != nil || sha256 != nil || xarTOC != nil,
              let candidates = filesBySize[size] else { return nil }
        for file in candidates {
            // Paquet : la TOC xar suffit (lecture de quelques Ko). IPSW : empreinte du fichier entier.
            let wantsTOC = xarTOC != nil
            guard let fp = fingerprints[file.url.path], fp.size == file.size, fp.modified == file.modified,
                  wantsTOC ? fp.xarTOC != nil : (fp.sha1 != nil || fp.sha256 != nil) else {
                schedule(file)
                continue
            }
            if (xarTOC != nil && fp.xarTOC == xarTOC)
                || (sha1 != nil && fp.sha1 == sha1)
                || (sha256 != nil && fp.sha256 == sha256) {
                return file.url
            }
        }
        return nil
    }

    // MARK: Empreintes

    private func schedule(_ file: ScannedFile) {
        let path = file.url.path
        guard !queued.contains(path) else { return }
        queued.insert(path)
        // Différé : `match` est appelé pendant le rendu des vues, on ne modifie pas l'état à ce moment-là.
        Task { @MainActor in
            hashingCount += 1
            let fp = await Task.detached(priority: .utility) { Self.fingerprint(file) }.value
            hashingCount -= 1
            queued.remove(path)
            if let fp {
                // Fusionne avec une empreinte existante du même fichier (TOC + hash complet).
                if var old = fingerprints[path], old.size == fp.size, old.modified == fp.modified {
                    old.sha1 = fp.sha1 ?? old.sha1
                    old.sha256 = fp.sha256 ?? old.sha256
                    old.xarTOC = fp.xarTOC ?? old.xarTOC
                    fingerprints[path] = old
                } else {
                    fingerprints[path] = fp
                }
                save()
            }
        }
    }

    /// .pkg : SHA-1 de la TOC xar (instantané). .ipsw : SHA-1 + SHA-256 du fichier entier en une lecture.
    nonisolated private static func fingerprint(_ file: ScannedFile) -> Fingerprint? {
        if file.url.pathExtension.lowercased() == "pkg" {
            // "" si ce n'est pas une archive xar : mémorisé pour ne pas recalculer en boucle.
            let toc = PackageIntegrity.xarTOCDigest(of: file.url) ?? ""
            return Fingerprint(size: file.size, modified: file.modified, xarTOC: toc)
        }
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        while let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            sha1.update(data: chunk)
            sha256.update(data: chunk)
        }
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
            d.map { String(format: "%02x", $0) }.joined()
        }
        return Fingerprint(size: file.size, modified: file.modified,
                           sha1: hex(sha1.finalize()), sha256: hex(sha256.finalize()))
    }

    private func save() {
        // Ne garde que les fichiers qui existent encore.
        let alive = fingerprints.filter { FileManager.default.fileExists(atPath: $0.key) }
        if let data = try? JSONEncoder().encode(alive) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
