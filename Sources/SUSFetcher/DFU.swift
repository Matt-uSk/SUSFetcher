import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Observation

/// Passage en DFU d'un appareil USB-C (Mac Apple Silicon, iPad / iPhone USB-C) depuis ce Mac, via l'outil embarqué macvdmtool
/// (Asahi Linux, Apache-2.0) : il envoie une commande USB-PD « VDM » au contrôleur USB-C de la cible.
///
/// Conditions : ce Mac est lui-même Apple Silicon, les deux Mac sont reliés par leurs ports DFU,
/// et l'outil tourne en root : mot de passe administrateur à chaque fois, ou — après une installation
/// unique — une copie protégée de l'outil autorisée par une règle sudo limitée à ses deux commandes,
/// avec Touch ID (ou le mot de passe de session) devant chaque commande.
@Observable
@MainActor
final class DFUTool {
    static let shared = DFUTool()

    enum Command: String, Sendable {
        case dfu, reboot

        @MainActor var label: String {
            switch self {
            case .dfu: tr("Passer l'appareil relié en DFU", "Put the Connected Device into DFU")
            case .reboot: tr("Redémarrer l'appareil relié", "Restart the Connected Device")
            }
        }
    }

    struct Outcome: Equatable {
        enum Status: Equatable { case success, unconfirmed, failed }
        let command: Command
        let status: Status
        let output: String
        let date: Date
        var success: Bool { status != .failed }
    }

    private(set) var running: Command?
    private(set) var lastOutcome: Outcome?

    // MARK: Mode sans mot de passe

    /// Copie de l'outil appartenant à root (l'utilisateur ne peut pas la remplacer).
    nonisolated static let installedHelper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/local.susfetcher.macvdmtool")
    nonisolated static let sudoersFile = "/etc/sudoers.d/susfetcher"

    /// La règle sudo autorise l'outil installé sans mot de passe pour cet utilisateur.
    private(set) var passwordless = false
    /// L'outil installé diffère de celui de l'app (après une mise à jour).
    private(set) var installedOutdated = false
    private(set) var installing = false
    private(set) var installError: String?

    /// Demander Touch ID (ou le mot de passe de session) avant chaque commande en mode sans mot de passe.
    var biometricConfirmation: Bool = UserDefaults.standard.object(forKey: "dfuBiometricConfirmation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(biometricConfirmation, forKey: "dfuBiometricConfirmation") }
    }

    /// « Touch ID » si le Mac en a un et qu'il est configuré, sinon nil.
    var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.biometryType == .touchID ? "Touch ID" : nil
    }

    func refreshInstallState() {
        Task {
            let state = await Task.detached(priority: .utility) { () -> (Bool, Bool) in
                let fm = FileManager.default
                guard fm.isExecutableFile(atPath: Self.installedHelper.path) else { return (false, false) }
                let allowed = Self.runProcess("/usr/bin/sudo", ["-n", "-l", Self.installedHelper.path, "dfu"]).status == 0
                var outdated = false
                if let bundled = Self.bundledHelperPath,
                   let a = fm.contents(atPath: bundled), let b = fm.contents(atPath: Self.installedHelper.path) {
                    outdated = SHA256.hash(data: a) != SHA256.hash(data: b)
                }
                return (allowed, outdated)
            }.value
            passwordless = state.0
            installedOutdated = state.1
        }
    }

    nonisolated private static var bundledHelperPath: String? {
        let path = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "macvdmtool").path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// Installation unique (mot de passe administrateur une dernière fois).
    func installPasswordless() {
        guard !installing, let bundled = Self.helperURL else { return }
        installing = true
        installError = nil
        let user = NSUserName()
        let dest = Self.installedHelper.path
        let rule = "\(dest) dfu, \(dest) reboot"
        let script = """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        cp '\(bundled.path.replacingOccurrences(of: "'", with: "'\\''"))' '\(dest)'
        chown root:wheel '\(dest)'
        chmod 755 '\(dest)'
        TMP=$(mktemp)
        cat > "$TMP" <<'RULES'
        # SUS Fetcher — DFU sans mot de passe (uniquement ces deux commandes de l'outil macvdmtool)
        %admin ALL=(root) NOPASSWD: \(rule)
        \(user) ALL=(root) NOPASSWD: \(rule)
        RULES
        /usr/sbin/visudo -cf "$TMP"
        install -m 440 -o root -g wheel "$TMP" '\(Self.sudoersFile)'
        rm -f "$TMP"
        """
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.runAdminScript(script) }.value
            installing = false
            if !result.success && !result.cancelled {
                installError = result.output.isEmpty ? tr("Installation impossible.", "Installation failed.") : result.output
            }
            refreshInstallState()
        }
    }

    func uninstallPasswordless() {
        guard !installing else { return }
        installing = true
        installError = nil
        let script = "rm -f '\(Self.sudoersFile)' '\(Self.installedHelper.path)'"
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.runAdminScript(script) }.value
            installing = false
            if !result.success && !result.cancelled { installError = result.output }
            refreshInstallState()
        }
    }

    static let appleDFUPortsURL = URL(string: "https://support.apple.com/108900")!

    /// Ce Mac a-t-il une puce Apple (y compris si l'app tourne sous Rosetta) ?
    nonisolated static var isAppleSiliconHost: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var helperURL: URL? {
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "macvdmtool"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Raison pour laquelle le DFU logiciel est indisponible sur ce Mac (nil = disponible).
    var unavailableReason: String? {
        if !Self.isAppleSiliconHost {
            return tr("Ce Mac a un processeur Intel : le passage en DFU par câble nécessite un Mac Apple Silicon (sinon, utilisez la combinaison de touches).",
                      "This Mac has an Intel processor: entering DFU over the cable requires an Apple silicon Mac (otherwise, use the key combination).")
        }
        if Self.helperURL == nil {
            return tr("Outil DFU introuvable dans l'app (lancée hors bundle ?).",
                      "DFU tool not found in the app (running outside the bundle?).")
        }
        return nil
    }

    func run(_ command: Command) {
        guard running == nil, unavailableReason == nil, let helper = Self.helperURL else { return }
        guard confirm(command) else { return }
        running = command
        let before = Set(ConnectedDevices.shared.devices.filter { $0.mode == .dfu }.map(\.id))
        let usePasswordless = passwordless
        let askBiometrics = usePasswordless && biometricConfirmation
        Task {
            if askBiometrics {
                let context = LAContext()
                context.localizedCancelTitle = tr("Annuler", "Cancel")
                let reason = command == .dfu
                    ? tr("passer l'appareil relié en mode DFU", "put the connected device into DFU mode")
                    : tr("redémarrer l'appareil relié", "restart the connected device")
                if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                    guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else {
                        running = nil
                        return
                    }
                }
            }
            var result = await Task.detached(priority: .userInitiated) {
                usePasswordless ? Self.runWithSudo(command.rawValue) : Self.runPrivileged(helper, command.rawValue)
            }.value
            // Règle sudo supprimée entre-temps : on repasse par la demande de mot de passe.
            if usePasswordless, result.output.contains("a password is required") {
                passwordless = false
                result = await Task.detached(priority: .userInitiated) { Self.runPrivileged(helper, command.rawValue) }.value
            }
            if result.cancelled { running = nil; return }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            var status: Outcome.Status = result.success ? .success : .failed
            // Un iPad / iPhone redémarre si vite qu'il ne répond pas à la commande : l'outil signale
            // une erreur alors que tout s'est bien passé. Commande partie → on attend l'appareil en DFU.
            let marker = command == .dfu ? "Rebooting target into DFU mode" : "Rebooting target into normal mode"
            if !result.success, output.contains(marker) {
                status = .unconfirmed
                if command == .dfu {
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .seconds(1.5))
                        let now = Set(ConnectedDevices.shared.devices.filter { $0.mode == .dfu }.map(\.id))
                        if !now.subtracting(before).isEmpty { status = .success; break }
                    }
                }
            }
            running = nil
            lastOutcome = Outcome(command: command, status: status, output: output, date: .now)
        }
    }

    private var authNote: String {
        if !passwordless { return tr(" Un mot de passe administrateur va être demandé.", " An administrator password will be requested.") }
        if biometricConfirmation {
            let name = biometryName ?? tr("votre mot de passe de session", "your login password")
            return tr(" Confirmation par \(name).", " You'll confirm with \(name).")
        }
        return ""
    }

    private func confirm(_ command: Command) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch command {
        case .dfu:
            alert.messageText = tr("Passer l'appareil relié en mode DFU ?", "Put the connected device into DFU mode?")
            alert.informativeText = tr("L'appareil relié à ce Mac en USB-C (Mac Apple Silicon ou iPad) va s'éteindre immédiatement et redémarrer en DFU : tout travail non enregistré dessus sera perdu.\n\nCe Mac n'est pas concerné." + authNote,
                                       "The device connected to this Mac over USB-C (Apple silicon Mac or iPad) will shut down immediately and restart in DFU: any unsaved work on it will be lost.\n\nThis Mac is not affected." + authNote)
            alert.addButton(withTitle: tr("Passer en DFU", "Enter DFU"))
        case .reboot:
            alert.messageText = tr("Redémarrer l'appareil relié ?", "Restart the connected device?")
            alert.informativeText = tr("L'appareil relié redémarre normalement (sort du mode DFU)." + authNote,
                                       "The connected device restarts normally (leaves DFU mode)." + authNote)
            alert.addButton(withTitle: tr("Redémarrer", "Restart"))
        }
        alert.addButton(withTitle: tr("Annuler", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Outil installé + règle sudo : aucune demande de mot de passe.
    nonisolated private static func runWithSudo(_ argument: String) -> (success: Bool, output: String, cancelled: Bool) {
        let r = runProcess("/usr/bin/sudo", ["-n", installedHelper.path, argument])
        return (r.status == 0, r.output, false)
    }

    nonisolated static func runProcess(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Script shell exécuté en root (demande d'autorisation macOS).
    nonisolated private static func runAdminScript(_ script: String) -> (success: Bool, output: String, cancelled: Bool) {
        let file = FileManager.default.temporaryDirectory.appending(path: "susfetcher-\(UUID().uuidString).sh")
        do { try script.write(to: file, atomically: true, encoding: .utf8) } catch { return (false, error.localizedDescription, false) }
        defer { try? FileManager.default.removeItem(at: file) }
        return runAsAdmin("/bin/sh '\(file.path)' 2>&1")
    }

    /// Lance l'outil en root via la demande d'autorisation standard de macOS.
    nonisolated private static func runPrivileged(_ helper: URL, _ argument: String)
        -> (success: Bool, output: String, cancelled: Bool) {
        func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return runAsAdmin(shellQuote(helper.path) + " " + argument + " 2>&1")
    }

    nonisolated private static func runAsAdmin(_ command: String) -> (success: Bool, output: String, cancelled: Bool) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (false, error.localizedDescription, false) }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if process.terminationStatus == 0 { return (true, stdout, false) }
        if stderr.contains("(-128)") { return (false, "", true) }   // mot de passe annulé
        // « do shell script » renvoie la sortie de la commande dans le message d'erreur.
        let message = stderr
            .replacingOccurrences(of: #"^.*execution error: "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" \(-?\d+\)\s*$"#, with: "", options: .regularExpression)
        return (false, message, false)
    }
}

/// Combinaisons de touches pour mettre un iPhone / iPad en DFU (aucune commande logicielle n'existe).
enum ManualDFUGuide: String, CaseIterable, Identifiable {
    case faceID, iPhone7, homeButton, mac
    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .faceID: tr("iPhone 8 et ultérieurs (USB-C compris) · iPad sans bouton principal", "iPhone 8 and later (USB-C included) · iPad without Home button")
        case .iPhone7: "iPhone 7 / 7 Plus"
        case .homeButton: tr("iPhone 6s et antérieurs · iPad avec bouton principal", "iPhone 6s and earlier · iPad with Home button")
        case .mac: tr("Mac Apple Silicon (sans second Mac)", "Apple silicon Mac (without a second Mac)")
        }
    }

    var icon: String {
        switch self {
        case .faceID: "iphone"
        case .iPhone7: "iphone.gen1"
        case .homeButton: "iphone.homebutton"
        case .mac: "laptopcomputer"
        }
    }

    @MainActor var steps: [String] {
        switch self {
        case .faceID:
            [tr("Branchez l'appareil à ce Mac.", "Connect the device to this Mac."),
             tr("Appuyez puis relâchez Volume +, puis Volume − (iPad : le bouton de volume le plus proche du bouton du haut, puis l'autre).",
                "Press and release Volume Up, then Volume Down (iPad: the volume button closest to the top button, then the other)."),
             tr("Maintenez le bouton latéral (ou du haut) jusqu'à ce que l'écran devienne noir.",
                "Hold the side (or top) button until the screen goes black."),
             tr("Sans le relâcher, maintenez aussi Volume − pendant 5 secondes.",
                "Keep holding it and also hold Volume Down for 5 seconds."),
             tr("Relâchez le bouton latéral en gardant Volume − enfoncé encore 10 secondes. L'écran reste noir : l'appareil apparaît ici en « DFU ».",
                "Release the side button while holding Volume Down for 10 more seconds. The screen stays black: the device shows up here as “DFU”.")]
        case .iPhone7:
            [tr("Branchez l'iPhone à ce Mac.", "Connect the iPhone to this Mac."),
             tr("Maintenez le bouton latéral et Volume − pendant 8 secondes.",
                "Hold the side button and Volume Down for 8 seconds."),
             tr("Relâchez le bouton latéral en gardant Volume − jusqu'à ce que l'iPhone apparaisse ici en « DFU » (écran noir).",
                "Release the side button while holding Volume Down until the iPhone shows up here as “DFU” (black screen).")]
        case .homeButton:
            [tr("Branchez l'appareil à ce Mac.", "Connect the device to this Mac."),
             tr("Maintenez le bouton principal et le bouton marche/veille pendant 8 secondes.",
                "Hold the Home button and the Sleep/Wake button for 8 seconds."),
             tr("Relâchez le bouton marche/veille en gardant le bouton principal jusqu'à ce que l'appareil apparaisse ici en « DFU » (écran noir).",
                "Release the Sleep/Wake button while holding Home until the device shows up here as “DFU” (black screen).")]
        case .mac:
            [tr("Reliez le Mac cible à ce Mac par son port DFU, puis éteignez-le.",
                "Connect the target Mac to this Mac through its DFU port, then shut it down."),
             tr("Portable : appuyez sur le bouton d'alimentation et maintenez Contrôle gauche + Option gauche + Majuscule droite 10 s, relâchez-les en gardant le bouton d'alimentation jusqu'à son apparition ici.",
                "Laptop: press the power button and hold left Control + left Option + right Shift for 10 s, then release them while holding the power button until it shows up here."),
             tr("Ordinateur de bureau : débranchez-le 10 s, maintenez le bouton d'alimentation, rebranchez-le et gardez le bouton enfoncé environ 3 s.",
                "Desktop: unplug it for 10 s, hold the power button, plug it back in and keep holding for about 3 s.")]
        }
    }
}
