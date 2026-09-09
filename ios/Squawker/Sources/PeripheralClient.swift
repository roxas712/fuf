import CoreBluetooth
import FlockCore

/// The FlockSquawk GATT service. Read/notify only -- there is nothing writable.
/// Taken from docs/handoff/ios-app.md, which was corrected against the device's
/// own GATT registration dump.
enum FlockGATT {
    // `CBUUID` predates `Sendable` in this SDK, so a plain `static let` is
    // flagged as concurrency-unsafe under Swift 6's strict checking.
    // `nonisolated(unsafe)` is the honest annotation, not a suppression: each
    // value is built once from a fixed string and never mutated after, so
    // there is nothing for concurrent access to race on.
    nonisolated(unsafe) static let service    = CBUUID(string: "6F1D0001-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) static let sighting   = CBUUID(string: "6F1D0002-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) static let deviceInfo = CBUUID(string: "6F1D0003-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) static let timeSync   = CBUUID(string: "6F1D0004-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) static let status     = CBUUID(string: "6F1D0006-B5A3-F393-E0A9-E50E24DCCA9E")
    // 6F1D0005 (LogControl) was removed from the service on 2026-09-08. The
    // UUID is retired -- do not discover or bind to it.
}

/// Scan, connect, subscribe, and stay connected.
///
/// Reconnection is CoreBluetooth's job, not this class's. `connect` with no
/// timeout leaves a standing request that iOS satisfies whenever the device
/// reappears -- out of range, powered off, rebooted. Rolling our own retry loop
/// would fight that and drain the battery.
@MainActor
final class PeripheralClient: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, poweredOff, unauthorized, scanning, connecting
        case connected, subscribed
        /// The bond was removed on one side. The one failure needing the user.
        case needsRepair
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var deviceID: String?

    /// Called on the main actor for each decoded notification.
    var onSighting: ((SightingRecord) -> Void)?
    var onDeviceLabel: ((DeviceLabel) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var wantsConnection = false

    /// Restoration is what makes the pocketed-phone case work: with this key
    /// iOS can relaunch the app after it was terminated and hand back the live
    /// peripheral through `willRestoreState`.
    static let restoreID = "com.example.flocksquawk.central"

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    func start() {
        wantsConnection = true
        guard central.state == .poweredOn else { return }
        beginScan()
    }

    func stop() {
        wantsConnection = false
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        state = .idle
    }

    private func beginScan() {
        // Reconnect to an already-known device without scanning at all, which
        // is faster and cheaper than discovery.
        let known = central.retrieveConnectedPeripherals(withServices: [FlockGATT.service])
        if let p = known.first {
            connect(p); return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [FlockGATT.service])
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central.stopScan()
        // No timeout: this is the standing request iOS honours on reappearance.
        central.connect(p)
    }

    /// Re-issues the standing connect request. Shared by the disconnect path
    /// (spontaneous, frequent, expected) and the fail-to-connect path (rare,
    /// but unlike a drop after a successful connect, CoreBluetooth does not
    /// retry a failed `connect(_:)` on its own -- skipping this would strand
    /// the standing request with no error surfaced and no way back).
    private func rearmIfWanted(_ p: CBPeripheral) {
        state = wantsConnection ? .connecting : .idle
        if wantsConnection { central.connect(p) }
    }
}

// `CBCentralManagerDelegate`/`CBPeripheralDelegate` are plain (non-isolated)
// Objective-C protocols -- CoreBluetooth predates Swift concurrency and its
// parameter types (`CBPeripheral`, `CBCentralManager`, `CBCharacteristic`,
// `CBService`) are not `Sendable`. The `@preconcurrency` on each conformance
// below is what lets a `@MainActor` type implement them directly rather than
// as `nonisolated` methods that then have to hop back with `Task { @MainActor
// in ... }` -- which would mean *sending* those non-Sendable parameters
// across an isolation boundary, exactly the "risks causing data races" error
// this file used to hit. Implementing the requirements directly is also
// correct, not just legal: `CBCentralManager` was constructed with `queue:
// nil`, so every one of these callbacks already arrives on the main queue --
// there is no thread hop actually happening, only one the compiler needed
// convincing about.
extension PeripheralClient: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:    if wantsConnection { beginScan() }
        case .poweredOff:   state = .poweredOff
        case .unauthorized: state = .unauthorized
        default:            state = .idle
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        if let p = restored.first {
            wantsConnection = true
            peripheral = p
            p.delegate = self
            state = p.state == .connected ? .connected : .connecting
            if p.state == .connected { p.discoverServices([FlockGATT.service]) }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected
        deviceID = p.identifier.uuidString
        p.discoverServices([FlockGATT.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        // Rare for a BLE peripheral -- this callback is mostly a classic-
        // Bluetooth-era leftover -- but the delegate protocol allows for it,
        // and silently not implementing it would mean a connection attempt
        // that fails this way never gets retried and never surfaces as
        // anything: the UI would just sit at "connecting" forever.
        rearmIfWanted(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        // Expected and frequent: out of range, device rebooted, or an HCI
        // supervision timeout (0x0208 is routine on this hardware). Re-arm
        // the standing request rather than surfacing an error.
        rearmIfWanted(p)
    }
}

extension PeripheralClient: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let svc = p.services?.first(where: { $0.uuid == FlockGATT.service })
        else { return }
        p.discoverCharacteristics(
            [FlockGATT.sighting, FlockGATT.deviceInfo,
             FlockGATT.timeSync, FlockGATT.status], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService,
                    error: Error?) {
        // A failed discovery -- or one that came back without the
        // characteristic that actually carries data -- must not be reported
        // as subscribed. Setting `.subscribed` unconditionally here would
        // tell the UI a link is live when nothing was ever subscribed to:
        // connected-but-recording-nothing dressed up as ready.
        guard error == nil, let characteristics = svc.characteristics else { return }
        var subscribedToSighting = false
        for ch in characteristics where
            ch.uuid == FlockGATT.sighting || ch.uuid == FlockGATT.deviceInfo {
            // Subscribing is what triggers pairing: the CCCD carries no
            // encryption requirement of its own, so the device accepts the
            // write and only then starts security. A successful subscribe
            // therefore does NOT mean paired -- only arriving data does.
            p.setNotifyValue(true, for: ch)
            if ch.uuid == FlockGATT.sighting { subscribedToSighting = true }
        }
        if subscribedToSighting { state = .subscribed }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error = error as NSError?,
           error.domain == CBATTErrorDomain,
           error.code == CBATTError.insufficientAuthentication.rawValue
            || error.code == CBATTError.insufficientEncryption.rawValue {
            state = .needsRepair
            return
        }
        guard let data = ch.value else { return }
        let bytes = [UInt8](data)
        switch ch.uuid {
        case FlockGATT.sighting:
            // A short or oversized notification is rejected by the decoder
            // rather than zero-padded into a plausible-looking sighting.
            if let r = SightingRecord(bytes), !r.isEmptySlot { onSighting?(r) }
        case FlockGATT.deviceInfo:
            if let d = DeviceLabel(bytes) { onDeviceLabel?(d) }
        default:
            break
        }
    }
}
