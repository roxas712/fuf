import Foundation
import Testing
@testable import FlockCore

@Suite("Device labels")
struct DeviceLabelsTests {

    /// The 46-byte DeviceInfo payload: 6 bytes MAC, 39 bytes null-padded
    /// identifier, 1 byte zero.
    private func payload(mac: [UInt8], label: String) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 46)
        for (i, b) in mac.enumerated() { raw[i] = b }
        for (i, b) in Array(label.utf8).enumerated() where i < 39 { raw[6 + i] = b }
        return raw
    }

    @Test("decodes a label and its MAC")
    func decodes() {
        let d = DeviceLabel(payload(mac: [0xB4,0x1E,0x52,0xAA,0xBB,0xCC],
                                    label: "Flock-A1B2C3"))
        #expect(d?.mac == "b4:1e:52:aa:bb:cc")
        #expect(d?.label == "Flock-A1B2C3")
    }

    @Test("stops at the first null rather than returning padding")
    func stopsAtNull() {
        let d = DeviceLabel(payload(mac: [1,2,3,4,5,6], label: "Short"))
        #expect(d?.label == "Short")
        #expect(d?.label?.count == 5)
    }

    @Test("a 39-character identifier with no null terminator still decodes")
    func fullWidthLabel() {
        let full = String(repeating: "X", count: 39)
        #expect(DeviceLabel(payload(mac: [1,2,3,4,5,6], label: full))?.label == full)
    }

    @Test("an empty identifier is nil, not an empty string")
    func emptyLabel() {
        // The firmware skips DeviceInfo for a hidden SSID, so this should not
        // arrive -- but an empty label must never overwrite a real one.
        #expect(DeviceLabel(payload(mac: [1,2,3,4,5,6], label: ""))?.label == nil)
    }

    @Test("a wrong-length payload is rejected")
    func wrongLength() {
        #expect(DeviceLabel([UInt8](repeating: 0, count: 45)) == nil)
        #expect(DeviceLabel([UInt8](repeating: 0, count: 47)) == nil)
    }

    @Test("labels persist and survive reopening")
    func persists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite")
        do {
            let s = try SightingStore(path: url.path)
            try s.recordLabel(mac: "aa:bb:cc:dd:ee:ff", label: "Flock-A1B2C3",
                              radio: 0, at: 1_757_000_000)
        }
        let reopened = try SightingStore(path: url.path)
        #expect(try reopened.label(for: "aa:bb:cc:dd:ee:ff") == "Flock-A1B2C3")
    }

    @Test("re-recording a MAC keeps its original first_seen")
    func firstSeenIsStable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite")
        let s = try SightingStore(path: url.path)
        try s.recordLabel(mac: "aa:bb:cc:dd:ee:ff", label: "First", radio: 0, at: 100)
        try s.recordLabel(mac: "aa:bb:cc:dd:ee:ff", label: "Second", radio: 0, at: 999)
        #expect(try s.label(for: "aa:bb:cc:dd:ee:ff") == "Second")
        #expect(try s.firstSeen(for: "aa:bb:cc:dd:ee:ff") == 100)
    }

    @Test("device count reflects distinct MACs, not sightings")
    func deviceCount() throws {
        let s = try SightingStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite").path)
        try s.recordLabel(mac: "aa:bb:cc:dd:ee:01", label: "A", radio: 0, at: 1)
        try s.recordLabel(mac: "aa:bb:cc:dd:ee:01", label: "A", radio: 0, at: 2)
        try s.recordLabel(mac: "aa:bb:cc:dd:ee:02", label: "B", radio: 0, at: 3)
        #expect(try s.deviceCount() == 2)
    }

    @Test("an unknown MAC has no label")
    func unknownMac() throws {
        let s = try SightingStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite").path)
        #expect(try s.label(for: "00:00:00:00:00:00") == nil)
    }
}
