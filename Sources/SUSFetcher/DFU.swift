import AppKit
import Foundation
import Observation

/// Passage d'un Mac Apple Silicon en DFU depuis ce Mac, via l'outil embarqué macvdmtool
/// (Asahi Linux, Apache-2.0) : il envoie une commande USB-PD « VDM » au contrôleur USB-C de la cible.
///
/// Conditions : ce Mac est lui-même Apple Silicon, les deux Mac sont reliés par leurs ports DFU,
/// et l'outil tourne en root (mot de passe administrateur demandé à chaque fois).
@Observable
@MainActor
final class DFUTool {
    static let shared = DFUTool()

    enum Command: String, Sendable {
        case dfu, reboot

        @MainActor var label: String {
            switch self {
            case .dfu: tr("Passer le Mac relié en DFU", "Put the Connected Mac into DFU")
            case .reboot: tr("Redémarrer le Mac relié", "Restart the Connected Mac")
            }
        }
    }

    struct Outcome: Equatable {
        let command: Command
        let success: Bool
        let output: String
        let date: Date
    }

    private(set) var running: Command?
    private(set) var lastOutcome: Outcome?

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
            return tr("Ce Mac a un processeur Intel : le passage en DFU par câble nécessite un Mac Apple Silicon (ou Apple Configurator et la combinaison de touches).",
                      "This Mac has an Intel processor: putting a Mac into DFU over the cable requires an Apple silicon Mac (or Apple Configurator and the key combination).")
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
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.runPrivileged(helper, command.rawValue) }.value
            running = nil
            if result.cancelled { return }
            lastOutcome = Outcome(command: command, success: result.success,
                                  output: result.output.trimmingCharacters(in: .whitespacesAndNewlines), date: .now)
        }
    }

    private func confirm(_ command: Command) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch command {
        case .dfu:
            alert.messageText = tr("Passer le Mac relié en mode DFU ?", "Put the connected Mac into DFU mode?")
            alert.informativeText = tr("Le Mac relié à ce Mac par son port DFU va s'éteindre immédiatement et redémarrer en DFU : tout travail non enregistré sur ce Mac-là sera perdu.\n\nCe Mac n'est pas concerné. Un mot de passe administrateur va être demandé.",
                                       "The Mac connected to this Mac through its DFU port will shut down immediately and restart in DFU: any unsaved work on that Mac will be lost.\n\nThis Mac is not affected. An administrator password will be requested.")
            alert.addButton(withTitle: tr("Passer en DFU", "Enter DFU"))
        case .reboot:
            alert.messageText = tr("Redémarrer le Mac relié ?", "Restart the connected Mac?")
            alert.informativeText = tr("Le Mac relié redémarre normalement (sort du mode DFU). Un mot de passe administrateur va être demandé.",
                                       "The connected Mac restarts normally (leaves DFU mode). An administrator password will be requested.")
            alert.addButton(withTitle: tr("Redémarrer", "Restart"))
        }
        alert.addButton(withTitle: tr("Annuler", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Lance l'outil en root via la demande d'autorisation standard de macOS.
    nonisolated private static func runPrivileged(_ helper: URL, _ argument: String)
        -> (success: Bool, output: String, cancelled: Bool) {
        func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = shellQuote(helper.path) + " " + argument + " 2>&1"
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
        case .faceID: tr("iPhone 8 et ultérieurs · iPad sans bouton principal", "iPhone 8 and later · iPad without Home button")
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
