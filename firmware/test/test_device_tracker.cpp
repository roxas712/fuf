#include "doctest.h"
#include "ThreatAnalyzer.h"

extern uint32_t mock_millis_value;

// ============================================================
// Helpers
// ============================================================

static void setMAC(uint8_t* dst, uint8_t a, uint8_t b, uint8_t c,
                   uint8_t d, uint8_t e, uint8_t f) {
    dst[0] = a; dst[1] = b; dst[2] = c;
    dst[3] = d; dst[4] = e; dst[5] = f;
}

// ============================================================
// DeviceTracker tests
// ============================================================

TEST_CASE("DeviceTracker: initialize clears all slots") {
    DeviceTracker tracker;
    tracker.initialize();
    // After initialize, no device should be in range
    CHECK_FALSE(tracker.hasHighConfidenceInRange(1000));
}

TEST_CASE("DeviceTracker: first detection returns EMPTY") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);
    DeviceState prev = tracker.recordDetection(mac, 1000, ALERT_CONFIRMED);
    CHECK(prev == DeviceState::EMPTY);
}

TEST_CASE("DeviceTracker: second detection returns NEW_DETECT") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);
    tracker.recordDetection(mac, 1000, ALERT_CONFIRMED);
    DeviceState prev = tracker.recordDetection(mac, 2000, ALERT_CONFIRMED);
    CHECK(prev == DeviceState::NEW_DETECT);
}

TEST_CASE("DeviceTracker: third detection returns IN_RANGE") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);
    tracker.recordDetection(mac, 1000, ALERT_CONFIRMED);
    tracker.recordDetection(mac, 2000, ALERT_CONFIRMED);
    DeviceState prev = tracker.recordDetection(mac, 3000, ALERT_CONFIRMED);
    CHECK(prev == DeviceState::IN_RANGE);
}

TEST_CASE("DeviceTracker: timeout transitions to DEPARTED") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);
    tracker.recordDetection(mac, 1000, ALERT_CONFIRMED);
    tracker.recordDetection(mac, 2000, ALERT_CONFIRMED);  // now IN_RANGE, lastSeenMs=2000
    // Tick past the 60s timeout from last-seen time
    tracker.tick(2000 + DEVICE_TIMEOUT_MS + 1);
    CHECK_FALSE(tracker.hasHighConfidenceInRange(1000));
}

TEST_CASE("DeviceTracker: hasHighConfidenceInRange") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);

    SUBCASE("SUSPICIOUS and IN_RANGE returns true") {
        tracker.recordDetection(mac, 1000, ALERT_SUSPICIOUS);
        tracker.recordDetection(mac, 2000, ALERT_SUSPICIOUS);  // IN_RANGE
        CHECK(tracker.hasHighConfidenceInRange(2000));
    }
    SUBCASE("NONE level returns false") {
        tracker.recordDetection(mac, 1000, ALERT_NONE);
        tracker.recordDetection(mac, 2000, ALERT_NONE);
        CHECK_FALSE(tracker.hasHighConfidenceInRange(2000));
    }
    SUBCASE("NEW_DETECT alone is not IN_RANGE") {
        tracker.recordDetection(mac, 1000, ALERT_CONFIRMED);
        CHECK_FALSE(tracker.hasHighConfidenceInRange(1000));
    }
}

TEST_CASE("DeviceTracker: max alert level updates on higher value") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);
    tracker.recordDetection(mac, 1000, ALERT_NONE);       // NEW_DETECT
    tracker.recordDetection(mac, 2000, ALERT_SUSPICIOUS);  // IN_RANGE, level bumped
    CHECK(tracker.hasHighConfidenceInRange(2000));
}

TEST_CASE("DeviceTracker: LRU eviction prefers empty slots") {
    DeviceTracker tracker;
    tracker.initialize();
    // Fill all 32 slots
    for (uint8_t i = 0; i < MAX_TRACKED_DEVICES; i++) {
        uint8_t mac[6];
        setMAC(mac, 0x10, 0x20, 0x30, 0x00, 0x00, i);
        tracker.recordDetection(mac, 1000 + i, ALERT_SUSPICIOUS);
    }
    // 33rd device should evict the oldest departed (none departed)
    // so it evicts oldest active device (slot 0, lastSeen=1000)
    uint8_t newMac[6];
    setMAC(newMac, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x01);
    DeviceState prev = tracker.recordDetection(newMac, 5000, ALERT_CONFIRMED);
    CHECK(prev == DeviceState::EMPTY);
}

TEST_CASE("DeviceTracker: eviction prefers departed over active") {
    DeviceTracker tracker;
    tracker.initialize();
    // Fill 32 slots
    for (uint8_t i = 0; i < MAX_TRACKED_DEVICES; i++) {
        uint8_t mac[6];
        setMAC(mac, 0x10, 0x20, 0x30, 0x00, 0x00, i);
        tracker.recordDetection(mac, 1000, ALERT_SUSPICIOUS);
    }
    // Timeout all → DEPARTED
    tracker.tick(1000 + DEVICE_TIMEOUT_MS + 1);
    // New device should reuse a departed slot
    uint8_t newMac[6];
    setMAC(newMac, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x01);
    DeviceState prev = tracker.recordDetection(newMac, 200000, ALERT_CONFIRMED);
    CHECK(prev == DeviceState::EMPTY);
}

TEST_CASE("DeviceTracker: NEW_DETECT times out") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);
    tracker.recordDetection(mac, 1000, ALERT_CONFIRMED);  // NEW_DETECT
    // Tick past timeout — NEW_DETECT should also depart
    tracker.tick(1000 + DEVICE_TIMEOUT_MS + 1);
    // Re-detect should return EMPTY (departed slot doesn't match)
    DeviceState prev = tracker.recordDetection(mac, 200000, ALERT_CONFIRMED);
    CHECK(prev == DeviceState::EMPTY);
}

// Regression: a tick timestamp older than a device's lastSeenMs must not age
// it out. loop() captures `now` at the top, analyzeWiFiFrame() then stamps
// lastSeenMs from a later millis(), and tick(now) runs afterwards -- so the
// subtraction nowMs - lastSeenMs underflows to ~4.29e9 and every freshly seen
// device was marked DEPARTED on the same iteration it was detected. On
// hardware one stationary camera produced 57 "first detection" alerts in 123
// seconds because each re-detection allocated a new slot.
TEST_CASE("DeviceTracker: a stale tick timestamp does not evict a fresh device") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);

    tracker.recordDetection(mac, 10001, ALERT_CONFIRMED);   // seen at T+1
    tracker.tick(10000);                                    // ticked with T

    DeviceState prev = tracker.recordDetection(mac, 10002, ALERT_CONFIRMED);
    CHECK(prev != DeviceState::EMPTY);   // must not look like a first detection
}

// The same underflow at the millis() rollover, which happens every 49.7 days
// of uptime and would otherwise depart every tracked device at once.
TEST_CASE("DeviceTracker: survives the millis() rollover") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);

    tracker.recordDetection(mac, 0xFFFFFF00, ALERT_CONFIRMED);
    tracker.tick(0x00000100);            // wrapped: true elapsed is 512ms

    DeviceState prev = tracker.recordDetection(mac, 0x00000101, ALERT_CONFIRMED);
    CHECK(prev != DeviceState::EMPTY);
}

// Regression: the heartbeat claims a camera is *nearby*, so it must follow
// recency, not the departure timeout. Reusing DEVICE_TIMEOUT_MS meant the beep
// kept sounding for a full minute after the target powered off -- observed on
// hardware as six beeps at lastSeen 2.4s, 12.5s, 22.5s, 32.6s, 42.7s, 52.7s.
TEST_CASE("DeviceTracker: heartbeat presence expires well before the timeout") {
    DeviceTracker tracker;
    tracker.initialize();
    uint8_t mac[6];
    setMAC(mac, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33);

    tracker.recordDetection(mac, 1000, ALERT_CONFIRMED);
    tracker.recordDetection(mac, 2000, ALERT_CONFIRMED);   // IN_RANGE

    CHECK(tracker.hasHighConfidenceInRange(2000));                       // present
    CHECK(tracker.hasHighConfidenceInRange(2000 + PRESENCE_FRESH_MS - 1));

    // Gone: still IN_RANGE (not yet departed) but no longer nearby.
    CHECK_FALSE(tracker.hasHighConfidenceInRange(2000 + PRESENCE_FRESH_MS + 1));
    CHECK_FALSE(tracker.hasHighConfidenceInRange(2000 + 52713));  // the observed case

    // And the device is still tracked, so returning does not re-alert.
    CHECK(tracker.recordDetection(mac, 2000 + 30000, ALERT_CONFIRMED)
          != DeviceState::EMPTY);
}
