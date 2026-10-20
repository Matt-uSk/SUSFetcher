import AppKit
import CryptoKit
import Foundation
import Observation

struct TransferProgress: Equatable {
    var received: Int64
    var total: Int64
    var startedAt: Date
    var startedReceived: Int64 = 0   // octets déjà présents au (re)démarrage, pour la vitesse

    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    var bytesPerSecond: Double {
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed > 0.5 ? Double(received - startedReceived) / elapsed : 0
    }

    var eta: TimeInterval? {
        let speed = bytesPerSecond
        guard total > 0, speed > 0 else { return nil }
        return Double(total - received) / speed
    }
}

/// Un téléchargement (en cours, en pause, terminé ou échoué).
struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case downloading(TransferProgress)
        case paused(TransferProgress)
        case finished(URL)
        case failed(String)

        var isActive: Bool { if case .downloading = self { true } else { false } }
        var isPaused: Bool { if case .paused = self { true } else { false } }
        var isDone: Bool {
            switch self {
            case .finished, .failed: true
            default: false
            }
        }
        var progress: TransferProgress? {
            switch self {
            case .downloading(let p), .paused(let p): p
            default: nil
            }
        }
    }

    let source: URL
    let destination: URL
    let title: String
    let expectedSize: Int64
    let createdAt: Date
    var state: State
    /// Empreinte attendue (IPSW) : vérifiée automatiquement à la fin du téléchargement.
    var checksum: Checksum? = nil
    var verification: Verification? = nil

    struct Checksum: Equatable, Sendable {
        enum Algorithm: String, Sendable { case sha256 = "SHA-256", sha1 = "SHA-1" }
        let algorithm: Algorithm
        let value: String
    }

    enum Verification: Equatable {
        case running
        case ok
        case mismatch
        case error(String)
    }

    var id: URL { source }
    var fileName: String { destination.lastPathComponent }
}

@Observable
@MainActor
final class DownloadManager {
    private static let folderKey = "destinationFolder"

    /// Instance unique, partagée avec l'AppDelegate (confirmation à la fermeture).
    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []

    var destinationFolder: URL {
        didSet { UserDefaults.standard.set(destinationFolder.path, forKey: Self.folderKey) }
    }

    @ObservationIgnored private let bridge = DownloadBridge()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var tasks: [URL: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var resumeData: [URL: Data] = [:]

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) {
            destinationFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            destinationFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)

        bridge.onProgress = { [weak self] source, taskID, received, total in
            Task { @MainActor in self?.updateProgress(source, taskID, received, total) }
        }
        bridge.onFinish = { [weak self] source, taskID, result in
            Task { @MainActor in self?.finish(source, taskID, result) }
        }
    }

    // MARK: Lecture

    func state(of url: URL) -> DownloadItem.State? { item(url)?.state }

    var activeCount: Int { items.filter(\.state.isActive).count }
    var pausedCount: Int { items.filter(\.state.isPaused).count }
    var pendingCount: Int { activeCount + pausedCount }

    var totalSpeed: Double {
        items.reduce(0) { sum, item in
            if case .downloading(let p) = item.state { return sum + p.bytesPerSecond }
            return sum
        }
    }

    // MARK: Démarrage

    /// One-click : InstallAssistant.pkg renommé avec version + build.
    func downloadInstaller(_ product: SUProduct) {
        guard let pkg = product.installAssistant else { return }
        let name = product.installAssistantFileName(template: AppSettings.shared.installerTemplate)
        start(pkg, to: destinationFolder.appending(path: name),
              title: "\(product.displayTitle) \(product.versionString)".trimmingCharacters(in: .whitespaces))
    }

    /// N'importe quel paquet d'un produit, rangé dans un sous-dossier par produit.
    func download(_ pkg: SUPackage, of product: SUProduct) {
        let folderName = "\(product.displayTitle) \(product.versionString) [\(product.id)]"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "  ", with: " ")
        let folder = destinationFolder.appending(path: folderName, directoryHint: .isDirectory)
        start(pkg, to: folder.appending(path: pkg.fileName), title: product.displayTitle)
    }

    func downloadAll(of product: SUProduct) {
        product.packages.forEach { download($0, of: product) }
    }

    // MARK: Contrôle

    func pause(_ url: URL) {
        guard let task = tasks[url], case .downloading(let p)? = state(of: url) else { return }
        tasks[url] = nil
        set(url, .paused(p))
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self, case .paused = self.state(of: url) else { return }
                if let data { self.resumeData[url] = data }
                else { self.resumeData[url] = nil }   // pas reprenable : on repartira de zéro
            }
        }
    }

    func resume(_ url: URL) {
        guard let item = item(url), case .paused(var p) = item.state else { return }
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: url) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
            p.received = 0
        }
        p.startedAt = .now
        p.startedReceived = p.received
        bridge.register(task, source: url, destination: item.destination)
        tasks[url] = task
        set(url, .downloading(p))
        task.resume()
    }

    func cancel(_ url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
        resumeData[url] = nil
        items.removeAll { $0.source == url }
    }

    func retry(_ url: URL) {
        guard let item = item(url), case .failed = item.state else { return }
        items.removeAll { $0.source == url }
        start(SUPackage(url: url, size: item.expectedSize), to: item.destination,
              title: item.title, checksum: item.checksum)
    }

    /// Téléchargement générique (IPSW…) avec vérification d'empreinte optionnelle.
    func download(url: URL, size: Int64, to destination: URL, title: String, checksum: DownloadItem.Checksum?) {
        start(SUPackage(url: url, size: size), to: destination, title: title, checksum: checksum)
    }

    func remove(_ url: URL) {
        guard state(of: url)?.isDone == true else { return }
        items.removeAll { $0.source == url }
    }

    func pauseAll() { for u in Array(tasks.keys) { pause(u) } }
    func resumeAll() { for i in items where i.state.isPaused { resume(i.source) } }
    func cancelAll() { for i in items where !i.state.isDone { cancel(i.source) } }
    func clearFinished() { items.removeAll { $0.state.isDone } }

    // MARK: Interne

    private func item(_ url: URL) -> DownloadItem? { items.first { $0.source == url } }

    private func set(_ url: URL, _ state: DownloadItem.State) {
        guard let i = items.firstIndex(where: { $0.source == url }) else { return }
        items[i].state = state
    }

    private func start(_ pkg: SUPackage, to destination: URL, title: String,
                       checksum: DownloadItem.Checksum? = nil) {
        if let existing = state(of: pkg.url), !existing.isDone { return }
        items.removeAll { $0.source == pkg.url }

        let task = session.downloadTask(with: pkg.url)
        bridge.register(task, source: pkg.url, destination: destination)
        tasks[pkg.url] = task
        items.append(DownloadItem(
            source: pkg.url, destination: destination, title: title,
            expectedSize: pkg.size, createdAt: .now,
            state: .downloading(TransferProgress(received: 0, total: pkg.size, startedAt: .now)),
            checksum: checksum.map { .init(algorithm: $0.algorithm, value: $0.value.lowercased()) }
        ))
        task.resume()
    }

    private func setVerification(_ url: URL, _ v: DownloadItem.Verification?) {
        guard let i = items.firstIndex(where: { $0.source == url }) else { return }
        items[i].verification = v
    }

    /// Calcule le SHA-256 en flux (fichiers de 10 Go+) hors du thread principal.
    private func verify(_ source: URL, file: URL, expected: DownloadItem.Checksum) {
        setVerification(source, .running)
        Task.detached(priority: .utility) {
            let result: DownloadItem.Verification
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let digest: String
                switch expected.algorithm {
                case .sha256:
                    var hasher = SHA256()
                    while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                        hasher.update(data: chunk)
                    }
                    digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                case .sha1:
                    var hasher = Insecure.SHA1()
                    while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                        hasher.update(data: chunk)
                    }
                    digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                }
                result = digest == expected.value ? .ok : .mismatch
            } catch {
                result = .error(error.localizedDescription)
            }
            await MainActor.run { DownloadManager.shared.setVerification(source, result) }
        }
    }

    private func updateProgress(_ source: URL, _ taskID: Int, _ received: Int64, _ total: Int64) {
        guard tasks[source]?.taskIdentifier == taskID,
              case .downloading(var p)? = state(of: source) else { return }
        p.received = received
        if total > 0 { p.total = total }
        set(source, .downloading(p))
    }

    private func finish(_ source: URL, _ taskID: Int, _ result: Result<URL, Error>) {
        guard tasks[source]?.taskIdentifier == taskID else { return }   // annulé / mis en pause : ignoré
        tasks[source] = nil
        switch result {
        case .success(let file):
            set(source, .finished(file))
            _ = NSApp.requestUserAttention(.informationalRequest)
            if let expected = item(source)?.checksum, !expected.value.isEmpty {
                verify(source, file: file, expected: expected)
            }
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled {
                items.removeAll { $0.source == source }
            } else {
                set(source, .failed(error.localizedDescription))
            }
        }
    }
}

/// Délégué URLSession (thread d'arrière-plan) : progression + déplacement du fichier final.
final class DownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Job {
        let source: URL
        let destination: URL
        var lastReport: Date = .distantPast
    }

    var onProgress: (@Sendable (URL, Int, Int64, Int64) -> Void)?
    var onFinish: (@Sendable (URL, Int, Result<URL, Error>) -> Void)?

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]

    func register(_ task: URLSessionTask, source: URL, destination: URL) {
        lock.withLock { jobs[task.taskIdentifier] = Job(source: source, destination: destination) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        let source: URL? = lock.withLock {
            guard var job = jobs[id] else { return nil }
            let now = Date()
            guard now.timeIntervalSince(job.lastReport) > 0.25 else { return nil }
            job.lastReport = now
            jobs[id] = job
            return job.source
        }
        if let source {
            onProgress?(source, id, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        let id = downloadTask.taskIdentifier
        if let source = lock.withLock({ jobs[id]?.source }) {
            onProgress?(source, id, fileOffset, expectedTotalBytes)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        guard let job = lock.withLock({ jobs.removeValue(forKey: id) }) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onFinish?(job.source, id, .failure(URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])))
            return
        }

        // Le fichier temporaire est supprimé à la fin de ce callback : on le déplace maintenant.
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: job.destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: job.destination.path) {
                try fm.removeItem(at: job.destination)
            }
            try fm.moveItem(at: location, to: job.destination)
            onFinish?(job.source, id, .success(job.destination))
        } catch {
            onFinish?(job.source, id, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        guard let job = lock.withLock({ jobs.removeValue(forKey: id) }) else { return }
        onFinish?(job.source, id, .failure(error))
    }
}
