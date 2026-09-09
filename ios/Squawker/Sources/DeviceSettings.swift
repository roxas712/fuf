import Foundation

/// The detector's hardware settings, exactly as carried over BLE by the
/// `6F1D0007` characteristic (`FlockGATT.settings`).
///
/// Mirrors `DeviceSettings` in
/// `firmware/m5stack/flocksquawk_m5fire/src/BleReporter.h` byte for byte --
/// change one side, change the other. This is device control, not sighting
/// data, which is why it lives here rather than in FlockCore: FlockCore stays
/// hardware-independent (decoding, storage, upload), and nothing there needs
/// to know the detector has a volume knob.
///
///     [0] format version -- must be 1
///     [1] volume         0..100  (a percentage; the firmware rejects >100)
///     [2] brightness     0..255
///     [3] flags          bit0 = heartbeat enabled, bit1 = battery saver enabled
///     [4] accent index   0..N
///     [5..7] reserved, zero
struct DeviceSettings: Equatable {
    static let byteCount: Int = 8
    static let wireVersion: UInt8 = 1

    var volume: UInt8
    var brightness: UInt8
    var heartbeatEnabled: Bool
    var batterySaverEnabled: Bool
    var accentIndex: UInt8

    init(volume: UInt8, brightness: UInt8, heartbeatEnabled: Bool,
         batterySaverEnabled: Bool, accentIndex: UInt8) {
        // Clamped, not asserted: this initializer also builds the value this
        // app is about to send, and the firmware rejects the whole write
        // outright if volume is over 100 rather than clamping it itself.
        self.volume = min(volume, 100)
        self.brightness = brightness
        self.heartbeatEnabled = heartbeatEnabled
        self.batterySaverEnabled = batterySaverEnabled
        self.accentIndex = accentIndex
    }

    /// Returns nil for anything not exactly 8 bytes at version 1, or with a
    /// volume over 100 -- mirroring the firmware's own `decode`, which
    /// rejects rather than clamps. A permissive decode here would let the app
    /// display or re-send a value the device itself would never have
    /// accepted.
    init?(_ raw: [UInt8]) {
        guard raw.count == Self.byteCount, raw[0] == Self.wireVersion else { return nil }
        guard raw[1] <= 100 else { return nil }
        volume              = raw[1]
        brightness          = raw[2]
        heartbeatEnabled    = (raw[3] & 0x01) != 0
        batterySaverEnabled = (raw[3] & 0x02) != 0
        accentIndex         = raw[4]
    }

    /// Encodes exactly as the firmware's own `encode` does -- reserved bytes
    /// zeroed, not left to whatever `Data` would otherwise contain.
    func encoded() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        bytes[0] = Self.wireVersion
        bytes[1] = volume
        bytes[2] = brightness
        bytes[3] = (heartbeatEnabled ? 0x01 : 0) | (batterySaverEnabled ? 0x02 : 0)
        bytes[4] = accentIndex
        return Data(bytes)
    }
}
