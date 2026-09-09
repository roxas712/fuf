import Foundation

/// Radio that produced a sighting. Wire values are fixed by the firmware's
/// `RadioType` enum in `firmware/common/SightingRecord.h`.
public enum RadioType: Equatable, Sendable {
    case wifi
    case ble
    /// Keeps the byte the device actually sent. Collapsing an unknown radio to
    /// a sentinel would upload that sentinel as the radio value and destroy the
    /// evidence of what arrived -- in a type whose whole contract is that the
    /// wire value is authoritative.
    case unknown(UInt8)

    init(wire: UInt8) {
        switch wire {
        case 0:  self = .wifi
        case 1:  self = .ble
        default: self = .unknown(wire)
        }
    }

    public var wireValue: UInt8 {
        switch self {
        case .wifi:              0
        case .ble:               1
        case .unknown(let raw):  raw
        }
    }
}

/// One 20-byte sighting exactly as the device transmits it.
///
/// Twenty bytes is one notification at the default BLE MTU, which is why the
/// firmware will not widen it without negotiating a larger MTU first. Byte
/// offsets are the contract -- do not infer them from Swift struct layout.
///
///     [0..3]   msSinceBoot  UInt32 little-endian, wraps at ~49 days
///     [4..9]   mac
///     [10]     rssi         Int8, signed
///     [11]     channel
///     [12]     radio        0 wifi, 1 ble
///     [13..14] matchFlags   UInt16 little-endian
///     [15]     certainty    0-100
///     [16]     alertLevel   0-3
///     [17..19] reserved     earmarked for a GPS-fix index (project D)
public struct SightingRecord: Equatable, Sendable {
    public static let byteCount = 20

    public let msSinceBoot: UInt32
    public let mac: [UInt8]
    public let rssi: Int8
    public let channel: UInt8
    public let radio: RadioType
    public let matchFlags: UInt16
    public let certainty: UInt8
    public let alertLevel: UInt8
    /// True when every one of the 20 bytes is zero.
    ///
    /// Computed from the raw buffer, not from the decoded fields, so it means
    /// exactly what the firmware's `sightingSlotIsEmpty` means -- that scans all
    /// 20 bytes including the reserved tail. Deciding it from the eight decoded
    /// fields alone would call a buffer with a non-zero reserved byte "empty"
    /// here and "not empty" there, which is precisely the silent drift these
    /// ported test vectors exist to prevent.
    public let isEmptySlot: Bool

    /// Returns nil for any buffer that is not exactly 20 bytes. A short read is
    /// rejected rather than zero-padded: a truncated notification is a bug
    /// worth seeing, not a sighting worth inventing.
    public init?(_ raw: [UInt8]) {
        guard raw.count == Self.byteCount else { return nil }
        msSinceBoot = UInt32(raw[0])
            | UInt32(raw[1]) << 8
            | UInt32(raw[2]) << 16
            | UInt32(raw[3]) << 24
        mac         = Array(raw[4...9])
        rssi        = Int8(bitPattern: raw[10])
        channel     = raw[11]
        radio       = RadioType(wire: raw[12])
        matchFlags  = UInt16(raw[13]) | UInt16(raw[14]) << 8
        certainty   = raw[15]
        alertLevel  = raw[16]
        // The firmware uses an all-zero record to mean an unwritten log slot;
        // a live notification should never be one.
        isEmptySlot = raw.allSatisfy { $0 == 0 }
    }

    /// Canonical lowercase colon-separated form, which is what the server's
    /// `mac` column stores and what `DeviceLabels` keys on.
    public var macString: String {
        mac.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
