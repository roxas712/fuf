import Testing
@testable import FlockCore

@Suite("Boot epoch detection")
struct BootEpochTests {

    private func record(ms: UInt32) -> SightingRecord {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[0] = UInt8(ms & 0xFF)
        raw[1] = UInt8((ms >> 8) & 0xFF)
        raw[2] = UInt8((ms >> 16) & 0xFF)
        raw[3] = UInt8((ms >> 24) & 0xFF)
        raw[9] = 1                                  // not an empty slot
        return SightingRecord(raw)!
    }

    @Test("starts at epoch 0")
    func startsAtZero() {
        #expect(BootEpoch().current == 0)
    }

    @Test("a rising counter stays in the same epoch")
    func risingStaysPut() {
        var e = BootEpoch()
        #expect(e.observe(record(ms: 1_000), at: 100.0) == 0)
        #expect(e.observe(record(ms: 2_000), at: 101.0) == 0)
        #expect(e.observe(record(ms: 2_001), at: 101.001) == 0)
        #expect(e.current == 0)
    }

    @Test("a counter that goes backwards means the device rebooted")
    func regressionIsAReboot() {
        var e = BootEpoch()
        _ = e.observe(record(ms: 500_000), at: 100.0)
        #expect(e.observe(record(ms: 12), at: 101.0) == 1)
        #expect(e.current == 1)
    }

    @Test("each further reboot increments again")
    func repeatedReboots() {
        var e = BootEpoch()
        _ = e.observe(record(ms: 900), at: 100.0)
        _ = e.observe(record(ms: 10), at: 101.0)      // epoch 1
        _ = e.observe(record(ms: 900), at: 102.0)
        #expect(e.observe(record(ms: 10), at: 103.0) == 2)
        #expect(e.current == 2)
    }

    @Test("an equal timestamp is not a reboot")
    func equalIsNotAReboot() {
        // Two sightings inside the same millisecond are ordinary at ~2/sec per
        // camera with several cameras in range. Treating equality as a reboot
        // would shred the ordering it exists to protect.
        var e = BootEpoch()
        _ = e.observe(record(ms: 1_000), at: 100.0)
        #expect(e.observe(record(ms: 1_000), at: 100.0) == 0)
    }

    @Test("a small backwards step still counts as a reboot")
    func smallRegression() {
        // There is no reordering to absorb: notifications arrive over an
        // ordered GATT connection, so any decrease is a genuine restart.
        var e = BootEpoch()
        _ = e.observe(record(ms: 1_000), at: 100.0)
        #expect(e.observe(record(ms: 999), at: 100.5) == 1)
    }

    @Test("a reboot is caught even when the counter did not go backwards")
    func rebootAcrossASlowReconnect() {
        // The case a bare regression check misses, and the likeliest one in the
        // field: the device browned out after 20s of uptime and took 40s to
        // reconnect, so the first record back reads HIGHER than the last one
        // before the reboot. Only the phone's clock reveals it.
        var e = BootEpoch()
        _ = e.observe(record(ms: 20_000), at: 1_000.0)
        #expect(e.observe(record(ms: 38_000), at: 1_040.0) == 1)
    }

    @Test("the 49-day counter wrap opens a new epoch, as a reboot does")
    func counterWrap() {
        // millis() wraps at 2^32 ms. The device did not restart, but its
        // counter did, and (epoch, ms) only stays ordered if the epoch
        // advances. Suppressing this to label the wrap "not a reboot" would
        // sort post-wrap records before their predecessors.
        var e = BootEpoch()
        _ = e.observe(record(ms: 0xFFFF_FFFE), at: 1_000.0)
        #expect(e.observe(record(ms: 2), at: 1_000.5) == 1)
    }
}
