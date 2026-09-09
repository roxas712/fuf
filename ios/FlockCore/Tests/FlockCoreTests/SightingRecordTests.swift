import Testing
@testable import FlockCore

/// Ported from firmware/test/test_sighting_record.cpp. The byte offsets
/// are the wire contract; round-trip tests alone cannot catch a bug applied
/// symmetrically to both encode and decode, which is why these pin absolute
/// positions rather than re-reading what was just written.
@Suite("SightingRecord wire format")
struct SightingRecordTests {

    @Test("size is exactly 20 bytes")
    func size() {
        #expect(SightingRecord.byteCount == 20)
    }

    @Test("pins every field to its absolute byte offset")
    func absoluteOffsets() throws {
        // Mirrors the C++ case of the same name.
        var raw = [UInt8](repeating: 0, count: 20)
        raw[4] = 0x11; raw[5] = 0x22; raw[6] = 0x33
        raw[7] = 0x44; raw[8] = 0x55; raw[9] = 0x66
        raw[10] = 0xB7          // -73 in two's complement
        raw[11] = 6             // channel
        raw[12] = 1             // radio: BLE
        raw[15] = 42            // certainty
        raw[16] = 2             // alertLevel

        // #require, not #expect-then-force-unwrap: #expect records the failure
        // and CONTINUES, so the next line would trap on nil and take the whole
        // test process down with it, including every other test.
        let r = try #require(SightingRecord(raw))
        #expect(r.msSinceBoot == 0)
        #expect(r.mac == [0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        #expect(r.rssi == -73)
        #expect(r.channel == 6)
        #expect(r.radio == .ble)
        #expect(r.matchFlags == 0)
        #expect(r.certainty == 42)
        #expect(r.alertLevel == 2)
    }

    @Test("decodes little-endian regardless of host")
    func littleEndian() {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[0] = 0x04; raw[1] = 0x03; raw[2] = 0x02; raw[3] = 0x01
        raw[13] = 0x0B; raw[14] = 0x0A

        let r = SightingRecord(raw)!
        #expect(r.msSinceBoot == 0x01020304)
        #expect(r.matchFlags == 0x0A0B)
    }

    @Test("preserves strongly negative RSSI")
    func negativeRSSI() {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[10] = 0x80          // -128
        #expect(SightingRecord(raw)!.rssi == -128)
    }

    @Test("radio is an integer, not a string")
    func radioIsAnInteger() {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[12] = 0
        #expect(SightingRecord(raw)!.radio == .wifi)
        raw[12] = 1
        #expect(SightingRecord(raw)!.radio == .ble)
    }

    @Test("an unknown radio value decodes rather than crashing")
    func unknownRadio() {
        // The firmware only emits 0 and 1 today. A future value must not be a
        // crash in a background BLE callback, so it degrades to .unknown.
        var raw = [UInt8](repeating: 0, count: 20)
        raw[12] = 7
        #expect(SightingRecord(raw)!.radio == .unknown(7))
    }

    @Test("decodes the hand-authored buffer from the C++ suite")
    func handAuthoredBuffer() throws {
        // Byte for byte the buffer in test_sighting_record.cpp:125. Every field
        // non-zero at once, which no other case here exercises -- and the only
        // coverage macString has, whose lowercase zero-padded form is what the
        // server's mac column and DeviceLabels both key on. A %2x instead of
        // %02x would pass every other test in this file.
        let raw: [UInt8] = [
            0x04, 0x03, 0x02, 0x01,
            0xB4, 0x1E, 0x52, 0x0A, 0x0B, 0x0C,
            0xB7, 0x06, 0x01, 0x41, 0x01, 0x64, 0x03,
            0x00, 0x00, 0x00,
        ]
        let r = try #require(SightingRecord(raw))
        #expect(r.msSinceBoot == 0x0102_0304)
        #expect(r.mac == [0xB4, 0x1E, 0x52, 0x0A, 0x0B, 0x0C])
        #expect(r.macString == "b4:1e:52:0a:0b:0c")
        #expect(r.rssi == -73)
        #expect(r.channel == 6)
        #expect(r.radio == .ble)
        #expect(r.matchFlags == 0x0141)
        #expect(r.certainty == 100)
        #expect(r.alertLevel == 3)
        #expect(r.isEmptySlot == false)
    }

    @Test("an unknown radio keeps the byte the device sent")
    func unknownRadioKeepsItsByte() {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[12] = 7
        #expect(SightingRecord(raw)!.radio == .unknown(7))
        #expect(SightingRecord(raw)!.radio.wireValue == 7)
    }

    @Test("a wrong-length buffer is rejected, not truncated")
    func wrongLength() {
        #expect(SightingRecord([UInt8](repeating: 0, count: 19)) == nil)
        #expect(SightingRecord([UInt8](repeating: 0, count: 21)) == nil)
        #expect(SightingRecord([]) == nil)
    }

    @Test("an all-zero buffer is an empty slot")
    func emptySlot() {
        #expect(SightingRecord([UInt8](repeating: 0, count: 20))!.isEmptySlot)
    }

    @Test("a record with a MAC is not an empty slot")
    func notAnEmptySlot() {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[9] = 1
        #expect(SightingRecord(raw)!.isEmptySlot == false)
    }

    @Test("a non-zero reserved byte means not empty, as it does in the firmware")
    func reservedBytesCount() {
        // sightingSlotIsEmpty() in the firmware scans all 20 bytes. Deciding
        // this from the decoded fields alone would disagree with it here, on a
        // record neither side would call empty.
        for offset in 17...19 {
            var raw = [UInt8](repeating: 0, count: 20)
            raw[offset] = 1
            #expect(SightingRecord(raw)!.isEmptySlot == false,
                    "reserved byte \(offset) was ignored")
        }
    }
}
