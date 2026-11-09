import Foundation

/// Appareils « restaurables » (DFU, Recovery, Restore) vus par MobileDevice.framework, la bibliothèque
/// privée d'Apple qu'utilisent le Finder et Apple Configurator.
///
/// Nécessaire pour les Mac Apple Silicon : reliés à un autre Mac Apple Silicon, ils n'apparaissent pas
/// comme un périphérique USB DFU classique (0x1227) mais derrière l'interface « Debug USB » gérée par
/// `deviceinterfaced` ; seul MobileDevice donne alors leur ECID, leur puce et leur carte.
///
/// Chargé dynamiquement (dlopen/dlsym) : si une fonction manque, la passerelle reste simplement inactive.
final class MobileDeviceBridge: @unchecked Sendable {
    static let shared = MobileDeviceBridge()

    struct Entry: Sendable {
        let ecid: UInt64
        let state: Int32
        let chipID: UInt32
        let boardID: UInt32
        let product: String?
        let friendlyName: String?
        let serial: String?
    }

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterFn = @convention(c) (Callback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias U64Fn = @convention(c) (UnsafeMutableRawPointer?) -> UInt64
    private typealias U32Fn = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    private typealias I32Fn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias CopyStringFn = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFString>?

    private let lock = NSLock()
    private var entries: [UInt: Entry] = [:]       // clé : adresse de l'AMRestorableDeviceRef
    private var events: [String] = []              // derniers événements (diagnostic)
    private var started = false
    private(set) var status = "not started"

    private var getECID: U64Fn?
    private var getChipID: U32Fn?
    private var getBoardID: U32Fn?
    private var getState: I32Fn?
    private var copyProduct: CopyStringFn?
    private var copyName: CopyStringFn?
    private var copySerial: CopyStringFn?

    /// À appeler sur le thread principal : les notifications arrivent sur sa boucle d'exécution.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY) else {
            status = "MobileDevice.framework introuvable"
            return
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let register = sym("AMRestorableDeviceRegisterForNotifications", RegisterFn.self),
              let ecid = sym("AMRestorableDeviceGetECID", U64Fn.self),
              let state = sym("AMRestorableDeviceGetState", I32Fn.self) else {
            status = "fonctions AMRestorableDevice absentes"
            return
        }
        getECID = ecid
        getState = state
        getChipID = sym("AMRestorableDeviceGetChipID", U32Fn.self)
        getBoardID = sym("AMRestorableDeviceGetBoardID", U32Fn.self)
        copyProduct = sym("AMRestorableDeviceCopyProductString", CopyStringFn.self)
        copyName = sym("AMRestorableDeviceCopyUserFriendlyName", CopyStringFn.self)
        copySerial = sym("AMRestorableDeviceCopySerialNumber", CopyStringFn.self)

        let callback: Callback = { device, event, _ in
            MobileDeviceBridge.shared.handle(device, event: event)
        }
        var error: Unmanaged<CFError>?
        let result = withUnsafeMutablePointer(to: &error) { register(callback, nil, UnsafeMutableRawPointer($0)) }
        status = "actif (code \(result))"
    }

    /// event 0 = branché, 1 = débranché (2+ : changement d'état, traité comme un branchement).
    private func handle(_ device: UnsafeMutableRawPointer?, event: Int32) {
        guard let device else { return }
        let key = UInt(bitPattern: device)
        if event == 1 {
            lock.lock(); entries[key] = nil; log("event 1 (removed)"); lock.unlock()
            return
        }
        let entry = Entry(ecid: getECID?(device) ?? 0,
                          state: getState?(device) ?? -1,
                          chipID: getChipID?(device) ?? 0,
                          boardID: getBoardID?(device) ?? 0,
                          product: copyProduct?(device)?.takeRetainedValue() as String?,
                          friendlyName: copyName?(device)?.takeRetainedValue() as String?,
                          serial: copySerial?(device)?.takeRetainedValue() as String?)
        lock.lock()
        entries[key] = entry
        log(String(format: "event %d state %d ecid %016llX cpid %04X bdid %02X product %@ name %@",
                   event, entry.state, entry.ecid, entry.chipID, entry.boardID,
                   entry.product ?? "-", entry.friendlyName ?? "-"))
        lock.unlock()
    }

    private func log(_ line: String) {
        events.append(line)
        if events.count > 20 { events.removeFirst(events.count - 20) }
    }

    var recentEvents: [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.values)
    }

    var statusText: String {
        lock.lock(); defer { lock.unlock() }
        return status
    }
}
