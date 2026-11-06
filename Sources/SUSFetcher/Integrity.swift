import CryptoKit
import Foundation

/// Contrôles d'intégrité des paquets Apple (vérifiés sur de vrais fichiers du catalogue).
///
/// - Le « Digest » du catalogue est le **SHA-1 de la table des matières (TOC) compressée** de
///   l'archive xar, pas celui du fichier complet. Il identifie le paquet mais ne garantit pas le contenu.
/// - L'« IntegrityDataURL » (InstallAssistant…) pointe vers une **chunklist** : le SHA-256 de chaque
///   morceau (10 Mo) du fichier. C'est le contrôle complet utilisé par macOS.
enum PackageIntegrity {

    // MARK: TOC xar

    /// SHA-1 de la TOC compressée d'une archive xar (= « Digest » du catalogue). nil si ce n'est pas un xar.
    static func xarTOCDigest(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // En-tête xar (big-endian) : magic "xar!", taille d'en-tête (UInt16), version (UInt16),
        // taille TOC compressée (UInt64), taille TOC décompressée (UInt64), algo de checksum (UInt32).
        guard let header = try? handle.read(upToCount: 28), header.count == 28,
              header.prefix(4) == Data("xar!".utf8) else { return nil }
        let headerSize = UInt64(header.readBE(UInt16.self, at: 4))
        let tocLength = header.readBE(UInt64.self, at: 8)
        guard tocLength > 0, tocLength < 64 * 1024 * 1024 else { return nil }
        try? handle.seek(toOffset: headerSize)
        guard let toc = try? handle.read(upToCount: Int(tocLength)), toc.count == Int(tocLength) else { return nil }
        return Insecure.SHA1.hash(data: toc).hexString
    }

    // MARK: Chunklist

    struct Chunk { let size: Int; let sha256: Data }

    /// Lit une chunklist Apple (magic "CNKL", little-endian) : en-tête de 36 octets, puis
    /// pour chaque morceau 4 octets de taille + 32 octets de SHA-256.
    static func parseChunklist(_ data: Data) -> [Chunk]? {
        guard data.count >= 36, data.prefix(4) == Data("CNKL".utf8) else { return nil }
        let count = Int(data.readLE(UInt64.self, at: 12))
        let offset = Int(data.readLE(UInt64.self, at: 20))
        guard count > 0, offset + count * 36 <= data.count else { return nil }
        return (0..<count).map { i in
            let o = offset + i * 36
            return Chunk(size: Int(data.readLE(UInt32.self, at: o)),
                         sha256: data.subdata(in: (o + 4)..<(o + 36)))
        }
    }

    /// Vérifie un fichier morceau par morceau. `false` dès qu'un morceau ou la taille totale diffère.
    static func verify(file: URL, against chunks: [Chunk]) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        for chunk in chunks {
            guard let data = try handle.read(upToCount: chunk.size), data.count == chunk.size,
                  Data(SHA256.hash(data: data)) == chunk.sha256 else { return false }
        }
        // Rien après le dernier morceau.
        return (try handle.read(upToCount: 1))?.isEmpty ?? true
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    func readBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        subdata(in: offset..<(offset + MemoryLayout<T>.size)).reduce(T(0)) { ($0 << 8) | T($1) }
    }
    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        subdata(in: offset..<(offset + MemoryLayout<T>.size)).reversed().reduce(T(0)) { ($0 << 8) | T($1) }
    }
}
