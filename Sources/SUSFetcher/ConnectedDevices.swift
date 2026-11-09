import Darwin
import Foundation
import IOKit
import Observation

/// Appareil Apple branché en USB.
/// - mode normal : iPhone / iPad vus par usbmuxd, infos lues auprès de lockdownd (sans appairage) ;
/// - mode DFU / Recovery : n'importe quel appareil Apple (Mac Apple Silicon compris) vu par IOKit,
///   identifié par sa puce (CPID) et sa carte (BDID) lues dans le numéro de série USB.
struct ConnectedDevice: Identifiable, Hashable, Sendable {
    enum Mode: String, Sendable { case normal, recovery, dfu }

    let id: String             // UDID (mode normal) ou ECID (DFU / Recovery)
    var mode: Mode
    var productType: String?   // « iPhone18,1 » (mode normal uniquement)
    var deviceName: String?    // nom donné par l'utilisateur
    var deviceClass: String?   // iPhone / iPad / Watch…
    var osVersion: String?
    var build: String?
    var cpid: Int?
    var bdid: Int?
    var ecid: String?
    var udid: String?
}

@Observable
@MainActor
final class ConnectedDevices {
    static let shared = ConnectedDevices()

    private(set) var devices: [ConnectedDevice] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let probe = DeviceProbe()

    /// Lance la détection (toutes les 2 s : liste usbmuxd + parcours IOKit, très léger).
    func start() {
        guard task == nil else { return }
        MobileDeviceBridge.shared.start()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let probe = self?.probe else { return }
                let found = await probe.scan()
                guard let self else { return }
                if found != devices { devices = found }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func device(_ id: String) -> ConnectedDevice? { devices.first { $0.id == id } }

    /// Identifiant de modèle (iPhone18,1, Mac16,10…) : donné par l'appareil, sinon déduit de CPID/BDID.
    func identifier(of d: ConnectedDevice) -> String? {
        if let p = d.productType { return p }
        guard let cpid = d.cpid, let bdid = d.bdid else { return nil }
        return IPSWModel.shared.device(cpid: cpid, bdid: bdid)?.identifier
    }

    /// Modèle commercial (« iPhone 17 Pro ») d'après ipsw.me.
    func modelName(of d: ConnectedDevice) -> String? {
        identifier(of: d).flatMap { IPSWModel.shared.device($0)?.name }
    }

    func displayName(of d: ConnectedDevice) -> String {
        d.deviceName ?? modelName(of: d) ?? identifier(of: d) ?? d.deviceClass
            ?? tr("Appareil Apple", "Apple device")
    }

    func ipswDevice(of d: ConnectedDevice) -> IPSWDevice? {
        guard let id = identifier(of: d) else { return nil }
        return IPSWModel.shared.device(id) ?? IPSWDevice(name: modelName(of: d) ?? id, identifier: id)
    }

    func icon(of d: ConnectedDevice) -> String {
        let id = identifier(of: d) ?? d.deviceClass ?? ""
        if id.hasPrefix("iPhone") { return "iphone" }
        if id.hasPrefix("iPad") { return "ipad" }
        if id.hasPrefix("Watch") { return "applewatch" }
        if id.hasPrefix("AppleTV") { return "appletv" }
        if id.hasPrefix("AudioAccessory") { return "homepod" }
        if id.hasPrefix("iMac") { return "desktopcomputer" }
        if id.hasPrefix("Macmini") || id.hasPrefix("Mac") && (modelName(of: d) ?? "").contains("mini") { return "macmini" }
        if (modelName(of: d) ?? "").contains("Studio") { return "macstudio" }
        if id.hasPrefix("Mac") { return "laptopcomputer" }
        return d.mode == .normal ? "cable.connector" : "cpu"
    }
}

// MARK: - Sonde (hors thread principal)

actor DeviceProbe {
    /// Infos lockdownd par UDID : lues une seule fois par branchement.
    private var lockdownCache: [String: [String: String]] = [:]

    func scan() -> [ConnectedDevice] {
        var result: [ConnectedDevice] = []
        let muxed = USBMuxClient.listUSBDevices()
        for (deviceID, udid) in muxed {
            if lockdownCache[udid] == nil, let values = USBMuxClient.lockdownValues(deviceID: deviceID) {
                lockdownCache[udid] = values
            }
            let v = lockdownCache[udid] ?? [:]
            result.append(ConnectedDevice(id: udid, mode: .normal,
                                          productType: v["ProductType"], deviceName: v["DeviceName"],
                                          deviceClass: v["DeviceClass"], osVersion: v["ProductVersion"],
                                          build: v["BuildVersion"],
                                          cpid: v["ChipID"].flatMap { Int($0) }, bdid: v["BoardId"].flatMap { Int($0) },
                                          ecid: v["UniqueChipID"].flatMap { UInt64($0) }.map(formatECID),
                                          udid: udid))
        }
        // Oublie les appareils débranchés.
        let present = Set(muxed.map { $0.1 })
        lockdownCache = lockdownCache.filter { present.contains($0.key) }

        // DFU / Recovery : MobileDevice (indispensable pour les Mac Apple Silicon), puis IOKit en secours.
        var seen = Set(result.compactMap(\.ecid))
        for e in MobileDeviceBridge.shared.snapshot() where e.ecid != 0 {
            let mode: ConnectedDevice.Mode
            switch e.state {
            case 0: mode = .dfu
            case 1, 2: mode = .recovery
            default: continue        // démarré normalement : déjà couvert par usbmuxd
            }
            let ecid = formatECID(e.ecid)
            guard seen.insert(ecid).inserted else { continue }
            let product = e.product.flatMap { $0.contains(",") ? $0 : nil }
            result.append(ConnectedDevice(id: ecid, mode: mode, productType: product,
                                          deviceName: e.friendlyName,
                                          cpid: e.chipID == 0 ? nil : Int(e.chipID),
                                          bdid: e.chipID == 0 ? nil : Int(e.boardID),
                                          ecid: ecid))
        }
        for d in IOKitUSB.restoreModeDevices() where d.ecid.map({ seen.insert($0).inserted }) ?? true {
            result.append(d)
        }
        return result.sorted { $0.id < $1.id }
    }
}

// MARK: - IOKit : appareils en DFU / Recovery

enum IOKitUSB {
    static func restoreModeDevices() -> [ConnectedDevice] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return [] }
        matching["idVendor"] = 0x05AC
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [ConnectedDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let device = makeDevice(service) { result.append(device) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    /// Tous les périphériques USB Apple (diagnostic) : « Nom 0xPID serial ».
    static func appleUSBSummary() -> [String] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return [] }
        matching["idVendor"] = 0x05AC
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var lines: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let name = (property(service, "USB Product Name") as? String) ?? "?"
            let pid = (property(service, "idProduct") as? NSNumber)?.intValue ?? 0
            let serial = (property(service, "USB Serial Number") as? String) ?? ""
            lines.append(String(format: "%@ 0x%04X %@", name, pid, serial))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return lines
    }

    private static func makeDevice(_ service: io_object_t) -> ConnectedDevice? {
        let product = (property(service, "idProduct") as? NSNumber)?.intValue ?? 0
        let mode: ConnectedDevice.Mode
        switch product {
        case 0x1227: mode = .dfu
        case 0x1280...0x1283: mode = .recovery
        default: return nil
        }
        let serial = (property(service, "USB Serial Number") as? String)
            ?? (property(service, "kUSBSerialNumberString") as? String) ?? ""
        let fields = parseSerial(serial)
        let ecid = fields["ECID"].flatMap { UInt64($0, radix: 16) }.map(formatECID)
        let locationID = (property(service, "locationID") as? NSNumber)?.intValue ?? 0
        return ConnectedDevice(id: ecid ?? "usb-\(locationID)", mode: mode,
                               cpid: fields["CPID"].flatMap { Int($0, radix: 16) },
                               bdid: fields["BDID"].flatMap { Int($0, radix: 16) },
                               ecid: ecid)
    }

    /// « SDOM:01 CPID:8150 CPRV:11 CPFM:03 SCEP:01 BDID:0C ECID:001A2B3C4D5E6F70 IBFL:3C SRTG:[iBoot-…] »
    static func parseSerial(_ serial: String) -> [String: String] {
        var fields: [String: String] = [:]
        for token in serial.split(separator: " ") {
            let parts = token.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
        return fields
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

// MARK: - usbmuxd / lockdownd

/// Client minimal du démon usbmuxd de macOS (celui qu'utilisent le Finder et Apple Configurator).
/// Protocole plist : en-tête de 16 octets little-endian (longueur, version 1, type 8, tag) + plist XML.
enum USBMuxClient {
    private static let socketPath = "/var/run/usbmuxd"
    private static let lockdownPort: UInt16 = 62078

    private static func message(_ type: String) -> [String: Any] {
        ["MessageType": type, "ProgName": "SUSFetcher", "ClientVersionString": "SUSFetcher",
         "BundleID": "local.susfetcher", "kLibUSBMuxVersion": 3]
    }

    /// (DeviceID usbmuxd, UDID) des appareils branchés en USB.
    static func listUSBDevices() -> [(Int, String)] {
        guard let fd = openSocket() else { return [] }
        defer { Darwin.close(fd) }
        guard sendMux(fd, message("ListDevices"), tag: 1), let reply = readMux(fd),
              let list = reply["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any],
                  (props["ConnectionType"] as? String) == "USB",
                  let id = (props["DeviceID"] as? NSNumber)?.intValue,
                  let udid = props["SerialNumber"] as? String else { return nil }
            return (id, udid)
        }
    }

    /// Valeurs publiques de lockdownd (GetValue sans session : pas besoin d'appairage).
    static func lockdownValues(deviceID: Int) -> [String: String]? {
        guard let fd = openSocket() else { return nil }
        defer { Darwin.close(fd) }
        var connect = message("Connect")
        connect["DeviceID"] = deviceID
        connect["PortNumber"] = Int(lockdownPort.byteSwapped)
        guard sendMux(fd, connect, tag: 2), let result = readMux(fd),
              (result["Number"] as? NSNumber)?.intValue == 0 else { return nil }

        // La socket est maintenant un tunnel vers lockdownd : longueur big-endian (4 octets) + plist.
        let request: [String: Any] = ["Label": "SUSFetcher", "Request": "GetValue"]
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0) else { return nil }
        var frame = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        guard writeAll(fd, frame), let header = readExact(fd, 4) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length < 4 * 1024 * 1024, let body = readExact(fd, length),
              let reply = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let value = reply["Value"] as? [String: Any] else { return nil }

        var out: [String: String] = [:]
        for key in ["ProductType", "DeviceName", "DeviceClass", "ProductVersion", "BuildVersion",
                    "ChipID", "BoardId", "UniqueChipID", "HardwareModel"] {
            switch value[key] {
            case let s as String: out[key] = s
            case let n as NSNumber: out[key] = n.stringValue
            default: break
            }
        }
        return out
    }

    // MARK: Socket

    private static func openSocket() -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in path.enumerated() where i < buffer.count - 1 { buffer[i] = byte }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    private static func sendMux(_ fd: Int32, _ plist: [String: Any], tag: UInt32) -> Bool {
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return false }
        var frame = Data()
        for v: UInt32 in [UInt32(16 + payload.count), 1, 8, tag] {
            withUnsafeBytes(of: v.littleEndian) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return writeAll(fd, frame)
    }

    private static func readMux(_ fd: Int32) -> [String: Any]? {
        guard let header = readExact(fd, 16) else { return nil }
        let length = header.prefix(4).reversed().reduce(0) { ($0 << 8) | Int($1) }
        guard length >= 16, length < 16 * 1024 * 1024, let body = readExact(fd, length - 16) else { return nil }
        return try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return false }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, p, remaining)
                if n <= 0 { return false }
                remaining -= n
                p += n
            }
            return true
        }
    }

    private static func readExact(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            while got < count {
                let n = Darwin.read(fd, base + got, count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? data : nil
    }
}

/// ECID au même format quelle que soit la source (lockdownd en décimal, USB et MobileDevice en hexa).
func formatECID(_ value: UInt64) -> String { String(format: "%016llX", value) }
