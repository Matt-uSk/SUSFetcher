import AppKit
import SwiftUI

// MARK: - Barre latérale

struct ConnectedDeviceRow: View {
    let device: ConnectedDevice
    let devices: ConnectedDevices

    var body: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(devices.displayName(of: device)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if device.mode != .normal { ModeBadge(mode: device.mode) }
            }
        } icon: {
            Image(systemName: devices.icon(of: device))
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if device.deviceName != nil, let model = devices.modelName(of: device) { parts.append(model) }
        if let v = device.osVersion { parts.append(v) }
        if device.mode != .normal, devices.identifier(of: device) == nil, let cpid = device.cpid {
            parts.append(String(format: "CPID %04X", cpid))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ModeBadge: View {
    let mode: ConnectedDevice.Mode

    var body: some View {
        Text(mode == .dfu ? "DFU" : "Recovery")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(.white)
            .background(Capsule().fill(mode == .dfu ? Color.purple : Color.orange))
    }
}

// MARK: - Fiche d'un appareil

struct DevicePane: View {
    let deviceID: String
    let devices: ConnectedDevices
    let model: IPSWModel
    let downloads: DownloadManager
    let state: ViewState

    var body: some View {
        if let device = devices.device(deviceID) {
            VStack(spacing: 0) {
                header(device)
                Divider()
                if let ipsw = devices.ipswDevice(of: device) {
                    IPSWFirmwarePanel(device: ipsw, model: model, downloads: downloads)
                        .id(ipsw.identifier)
                } else {
                    ContentUnavailableView {
                        Label(tr("Modèle non identifié", "Unidentified model"), systemImage: "questionmark.circle")
                    } description: {
                        Text(unidentifiedText(device))
                    } actions: {
                        Button(tr("Recharger la liste des modèles", "Reload model list")) { model.reloadDevices(force: true) }
                    }
                }
            }
        } else {
            ContentUnavailableView(tr("Appareil déconnecté", "Device disconnected"), systemImage: "cable.connector.slash",
                                   description: Text(tr("Rebranchez-le pour retrouver sa fiche.", "Reconnect it to see its details.")))
        }
    }

    private func unidentifiedText(_ d: ConnectedDevice) -> String {
        if d.mode == .normal {
            return tr("L'appareil n'a pas encore donné son modèle (déverrouillez-le, ou attendez la fin du démarrage).",
                      "The device hasn't reported its model yet (unlock it, or wait for it to finish booting).")
        }
        let chip = [d.cpid.map { String(format: "CPID 0x%04X", $0) }, d.bdid.map { String(format: "BDID 0x%02X", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return tr("Aucun modèle connu ne correspond à cette puce (\(chip)).", "No known model matches this chip (\(chip)).")
    }

    // MARK: En-tête

    private func header(_ d: ConnectedDevice) -> some View {
        let identifier = devices.identifier(of: d)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: devices.icon(of: d))
                    .font(.system(size: 34, weight: .light))
                    .frame(width: 44)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(devices.displayName(of: d)).font(.title3.weight(.semibold))
                        if d.mode != .normal { ModeBadge(mode: d.mode) }
                    }
                    Text([devices.modelName(of: d) == devices.displayName(of: d) ? nil : devices.modelName(of: d),
                          identifier, osLine(d)].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if let udid = d.udid { CopyableID(label: "UDID", value: udid) }
                        if let ecid = d.ecid { CopyableID(label: "ECID", value: ecid) }
                    }
                }
                Spacer()
                actions(d, identifier: identifier)
            }
            if let status = status(d, identifier: identifier) { status }
            if let outcome = DFUTool.shared.lastOutcome, Date().timeIntervalSince(outcome.date) < 120 {
                DFUOutcomeBanner(outcome: outcome)
            }
        }
        .padding(14)
    }

    private func osLine(_ d: ConnectedDevice) -> String? {
        guard let v = d.osVersion else { return nil }
        return d.build.map { "\(v) (\($0))" } ?? v
    }

    @ViewBuilder
    private func actions(_ d: ConnectedDevice, identifier: String?) -> some View {
        let isMac = identifier.map { IPSWFamily.mac.matches($0) } ?? false
        VStack(alignment: .trailing, spacing: 6) {
            if isMac && d.mode != .normal {
                let tool = DFUTool.shared
                Button {
                    tool.run(.reboot)
                } label: {
                    Label(tr("Quitter le DFU (redémarrer)", "Exit DFU (restart)"), systemImage: "arrow.clockwise.circle")
                }
                .disabled(tool.unavailableReason != nil || tool.running != nil)
                .help(tool.unavailableReason ?? tr("Redémarre le Mac relié par son port DFU", "Restarts the Mac connected through its DFU port"))
            }
            if d.mode == .normal || !isMac {
                Button {
                    state.sidebar = .dfu
                } label: {
                    Label(tr("Mode DFU…", "DFU Mode…"), systemImage: "bolt.horizontal.circle")
                }
            }
        }
        .controlSize(.small)
    }

    /// « À jour » / « 26.2 disponible » / « Restaurable avec … ».
    private func status(_ d: ConnectedDevice, identifier: String?) -> AnyView? {
        guard let identifier, let list = model.firmwares[identifier] else { return nil }
        let latest = list.filter(\.signed).max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
        guard let latest else { return nil }
        let text: String, color: Color, icon: String
        if d.mode != .normal {
            text = tr("Restaurable avec \(latest.version) (\(latest.build)), dernière version signée.",
                      "Can be restored with \(latest.version) (\(latest.build)), the latest signed version.")
            color = .accentColor; icon = "arrow.counterclockwise.circle.fill"
        } else if let current = d.osVersion {
            if latest.version.compare(current, options: .numeric) == .orderedDescending {
                text = tr("\(latest.version) disponible (installé : \(current)).", "\(latest.version) available (installed: \(current)).")
                color = .orange; icon = "arrow.down.circle.fill"
            } else {
                text = tr("À jour : \(current) est la dernière version signée.", "Up to date: \(current) is the latest signed version.")
                color = .green; icon = "checkmark.circle.fill"
            }
        } else {
            return nil
        }
        return AnyView(Label(text, systemImage: icon).font(.callout).foregroundStyle(color))
    }
}

struct CopyableID: View {
    let label: String
    let value: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            HStack(spacing: 3) {
                Text(label).foregroundStyle(.secondary)
                Text(value).monospaced().lineLimit(1).truncationMode(.middle)
                Image(systemName: "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: 260, alignment: .leading)
        .help(tr("Copier", "Copy"))
    }
}

struct DFUOutcomeBanner: View {
    let outcome: DFUTool.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(outcome.success
                  ? (outcome.command == .dfu ? tr("Commande DFU envoyée : le Mac relié redémarre en DFU.", "DFU command sent: the connected Mac is restarting in DFU.")
                                             : tr("Redémarrage envoyé au Mac relié.", "Restart sent to the connected Mac."))
                  : tr("Échec de la commande", "Command failed"),
                  systemImage: outcome.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.success ? Color.green : Color.red)
            if !outcome.success, !outcome.output.isEmpty {
                Text(outcome.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((outcome.success ? Color.green : Color.red).opacity(0.08)))
    }
}

// MARK: - Page « Mode DFU »

struct DFUPane: View {
    let devices: ConnectedDevices
    let tool: DFUTool
    let state: ViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Mode DFU", "DFU Mode")).font(.title2.weight(.semibold))
                    Text(tr("Un appareil en DFU ou en Recovery apparaît tout seul dans « Appareils connectés », avec les firmwares qui lui correspondent.",
                            "A device in DFU or Recovery shows up on its own under “Connected Devices”, with its matching firmwares."))
                        .foregroundStyle(.secondary)
                }

                restoreModeList
                macSection
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ManualDFUGuide.allCases) { guide in
                            GuideView(guide: guide)
                            if guide != ManualDFUGuide.allCases.last { Divider() }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(tr("Avec les boutons", "Using the buttons"), systemImage: "hand.point.up.left")
                }

                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostic(), forType: .string)
                    } label: {
                        Label(tr("Copier le diagnostic", "Copy Diagnostics"), systemImage: "stethoscope")
                    }
                    .controlSize(.small)
                    .help(tr("Copie l'état de la détection USB (à joindre à un rapport de bug)",
                             "Copies the USB detection state (to attach to a bug report)"))
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var restoreModeList: some View {
        let inRestore = devices.devices.filter { $0.mode != .normal }
        if !inRestore.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(inRestore) { d in
                        HStack {
                            Image(systemName: devices.icon(of: d)).frame(width: 20)
                            Text(devices.displayName(of: d))
                            ModeBadge(mode: d.mode)
                            Spacer()
                            Button(tr("Voir les firmwares", "Show firmwares")) { state.sidebar = .device(d.id) }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(6)
            } label: {
                Label(tr("Détectés en ce moment", "Currently detected"), systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }

    private var macSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Ce Mac envoie la commande DFU au Mac relié par câble USB-C, sans toucher au clavier de la cible (comme Apple Configurator ou DFU Blaster).",
                        "This Mac sends the DFU command to the Mac connected with a USB-C cable, without touching the target's keyboard (like Apple Configurator or DFU Blaster)."))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Reliez les deux Mac par leurs ports DFU :", "Connect both Macs through their DFU ports:")).bold()
                    Text(tr("• MacBook Air et MacBook Pro 13\" : le port arrière gauche", "• MacBook Air and 13\" MacBook Pro: the rear left port"))
                    Text(tr("• MacBook Pro 14\" et 16\" : le port à côté du MagSafe", "• 14\" and 16\" MacBook Pro: the port next to MagSafe"))
                    Text(tr("• Mac mini, Mac Studio, iMac… : voir la liste d'Apple", "• Mac mini, Mac Studio, iMac…: see Apple's list"))
                    Link(tr("Trouver le port DFU (support Apple)", "Find the DFU port (Apple Support)"), destination: DFUTool.appleDFUPortsURL)
                        .font(.callout)
                }
                .font(.callout)

                if let reason = tool.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                HStack {
                    Button {
                        tool.run(.dfu)
                    } label: {
                        Label(DFUTool.Command.dfu.label, systemImage: "bolt.horizontal.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        tool.run(.reboot)
                    } label: {
                        Label(DFUTool.Command.reboot.label, systemImage: "arrow.clockwise")
                    }
                    if tool.running != nil { ProgressView().controlSize(.small) }
                }
                .disabled(tool.unavailableReason != nil || tool.running != nil)

                if let outcome = tool.lastOutcome { DFUOutcomeBanner(outcome: outcome) }

                Text(tr("Mot de passe administrateur requis. Outil : macvdmtool (Asahi Linux, licence Apache 2.0).",
                        "Administrator password required. Tool: macvdmtool (Asahi Linux, Apache 2.0 license)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(tr("Mac Apple Silicon relié à ce Mac", "Apple silicon Mac connected to this Mac"), systemImage: "laptopcomputer.and.arrow.down")
        }
    }
}

extension DFUPane {
    func diagnostic() -> String {
        var lines = ["SUS Fetcher \(Updater.shared.currentVersion ?? "dev") — "
                     + "\(ProcessInfo.processInfo.operatingSystemVersionString) — "
                     + (DFUTool.isAppleSiliconHost ? "Apple silicon" : "Intel")]
        lines += ["", "## Détectés"]
        for d in devices.devices {
            lines.append("- \(d.mode.rawValue) id=\(d.id) product=\(d.productType ?? "-") name=\(d.deviceName ?? "-") "
                         + "os=\(d.osVersion ?? "-") cpid=\(d.cpid.map { String(format: "%04X", $0) } ?? "-") "
                         + "bdid=\(d.bdid.map { String(format: "%02X", $0) } ?? "-") → \(devices.identifier(of: d) ?? "?")")
        }
        lines += ["", "## MobileDevice : \(MobileDeviceBridge.shared.statusText)"]
        lines += MobileDeviceBridge.shared.recentEvents.map { "- " + $0 }
        lines += ["", "## USB Apple (IOKit)"]
        lines += IOKitUSB.appleUSBSummary().map { "- " + $0 }
        if let o = tool.lastOutcome {
            lines += ["", "## Dernière commande DFU : \(o.command.rawValue) \(o.success ? "OK" : "échec")", o.output]
        }
        return lines.joined(separator: "\n")
    }
}

private struct GuideView: View {
    let guide: ManualDFUGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(guide.title, systemImage: guide.icon).font(.headline)
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.caption.weight(.bold)).monospacedDigit()
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }
}
