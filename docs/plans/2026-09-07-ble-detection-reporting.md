# BLE Detection Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream FlockSquawk detections off the M5Stack FIRE over BLE and keep a durable on-device log, so discovered cameras can be mapped instead of only announced.

**Architecture:** Four pure, host-testable units (record codec, ring index math, per-MAC rate limiter, device dedupe table) in `common/`, plus two hardware-bound components in the FIRE variant — `DetectionLog` (binds the pure units to LittleFS) and `BleReporter` (NimBLE GATT peripheral with passkey pairing). Both are invoked directly from the existing `threatPending` block, matching how `TelemetryReporter` is already wired.

**Tech Stack:** Arduino ESP32 core 3.0.7, NimBLE-Arduino 2.3.7, M5Unified 0.2.11, LittleFS, doctest 2.4.12 for host tests, clang++ C++17.

**Spec:** `docs/superpowers/specs/2026-09-07-ble-detection-reporting-design.md`

**Location:** `~/dev/fuf/firmware`, branch `flock-ingest` (historical: this plan was executed in the standalone FlockSquawk clone, since archived)

---

## Environment facts you need

- `make test` compiles and runs the host suite. Baseline before this work: **48 test cases, 167 assertions, all passing.**
- New test files must be added to `TEST_SRCS` in the `Makefile` (line ~148) or they will not run.
- Host tests compile with `-isystem test/mocks -I common -I test`. Anything in `common/` is reachable; anything under `m5stack/` is **not**.
- `test/mocks/Arduino.h` provides `millis()` backed by the global `mock_millis_value`. Set it directly in tests to control time.
- Build firmware: `make build VARIANT=m5fire`. Flash: `make upload VARIANT=m5fire PORT=/dev/cu.usbserial-XXXX`.
- Find the port with `ls /dev/cu.* | grep usbserial`. It disappears when esptool toggles DTR/RTS on a marginal cable — replug and retry; failed uploads abort before writing.

## File structure

**Created — pure units, host-tested:**

| File | Responsibility |
|---|---|
| `common/SightingRecord.h` | 20-byte record layout; explicit little-endian encode/decode |
| `common/RingIndex.h` | Ring position arithmetic and seam recovery. No filesystem. |
| `common/RateLimiter.h` | Per-MAC minimum interval gate |
| `common/DeviceTable.h` | Tracks which MACs have had identity persisted |

**Created — hardware-bound, device-tested:**

| File | Responsibility |
|---|---|
| `m5stack/flocksquawk_m5fire/src/DetectionLog.h` | Binds the pure units to LittleFS files |
| `m5stack/flocksquawk_m5fire/src/BleReporter.h` | NimBLE peripheral, 5 characteristics, passkey pairing |

**Created — tests:**

`test/test_sighting_record.cpp`, `test/test_ring_index.cpp`, `test/test_rate_limiter.cpp`, `test/test_device_table.cpp`

**Modified:**

| File | Change |
|---|---|
| `Makefile` | Add four test files to `TEST_SRCS` |
| `m5stack/flocksquawk_m5fire/flocksquawk_m5fire.ino` | Include, instantiate, initialize, and call the two components |

---

## Task 1: SightingRecord codec

Explicit byte-by-byte little-endian encoding — never `memcpy` the struct. Struct padding and endianness are not part of the on-disk contract, and this record also goes over BLE to a different architecture.

**Files:**
- Create: `common/SightingRecord.h`
- Create: `test/test_sighting_record.cpp`
- Modify: `Makefile` (TEST_SRCS)

- [ ] **Step 1: Write the failing test**

Create `test/test_sighting_record.cpp`:

```cpp
#include "doctest.h"
#include "SightingRecord.h"

static void setMAC(uint8_t* dst, uint8_t a, uint8_t b, uint8_t c,
                   uint8_t d, uint8_t e, uint8_t f) {
    dst[0] = a; dst[1] = b; dst[2] = c;
    dst[3] = d; dst[4] = e; dst[5] = f;
}

TEST_CASE("SightingRecord: size is exactly 20 bytes") {
    CHECK(SIGHTING_RECORD_SIZE == 20);
}

TEST_CASE("SightingRecord: round-trips all fields") {
    SightingRecord in{};
    in.msSinceBoot = 0x11223344;
    setMAC(in.mac, 0xB4, 0x1E, 0x52, 0xAA, 0xBB, 0xCC);
    in.rssi       = -73;
    in.channel    = 11;
    in.radio      = RADIO_WIFI;
    in.matchFlags = 0x0141;
    in.certainty  = 100;
    in.alertLevel = 3;

    uint8_t raw[SIGHTING_RECORD_SIZE];
    encodeSighting(in, raw);

    SightingRecord out{};
    decodeSighting(raw, out);

    CHECK(out.msSinceBoot == 0x11223344);
    CHECK(memcmp(out.mac, in.mac, 6) == 0);
    CHECK(out.rssi == -73);
    CHECK(out.channel == 11);
    CHECK(out.radio == RADIO_WIFI);
    CHECK(out.matchFlags == 0x0141);
    CHECK(out.certainty == 100);
    CHECK(out.alertLevel == 3);
}

TEST_CASE("SightingRecord: encodes little-endian regardless of host") {
    SightingRecord in{};
    in.msSinceBoot = 0x01020304;
    in.matchFlags  = 0x0A0B;

    uint8_t raw[SIGHTING_RECORD_SIZE];
    encodeSighting(in, raw);

    CHECK(raw[0] == 0x04);
    CHECK(raw[1] == 0x03);
    CHECK(raw[2] == 0x02);
    CHECK(raw[3] == 0x01);
    CHECK(raw[13] == 0x0B);
    CHECK(raw[14] == 0x0A);
}

TEST_CASE("SightingRecord: preserves strongly negative RSSI") {
    SightingRecord in{};
    in.rssi = -128;
    uint8_t raw[SIGHTING_RECORD_SIZE];
    encodeSighting(in, raw);
    SightingRecord out{};
    decodeSighting(raw, out);
    CHECK(out.rssi == -128);
}

TEST_CASE("SightingRecord: reserved bytes are zeroed") {
    SightingRecord in{};
    in.msSinceBoot = 0xFFFFFFFF;
    uint8_t raw[SIGHTING_RECORD_SIZE];
    memset(raw, 0xAB, sizeof(raw));
    encodeSighting(in, raw);
    CHECK(raw[17] == 0);
    CHECK(raw[18] == 0);
    CHECK(raw[19] == 0);
}

TEST_CASE("SightingRecord: all-zero buffer reads as an empty slot") {
    uint8_t raw[SIGHTING_RECORD_SIZE];
    memset(raw, 0, sizeof(raw));
    CHECK(sightingSlotIsEmpty(raw));
}

TEST_CASE("SightingRecord: a record with a MAC is not an empty slot") {
    SightingRecord in{};
    setMAC(in.mac, 0, 0, 0, 0, 0, 1);
    uint8_t raw[SIGHTING_RECORD_SIZE];
    encodeSighting(in, raw);
    CHECK_FALSE(sightingSlotIsEmpty(raw));
}
```

Add the file to `TEST_SRCS` in `Makefile` (around line 148):

```make
TEST_SRCS     := test/test_main.cpp test/eventbus_impl.cpp \
                 test/test_detectors.cpp test/test_device_tracker.cpp \
                 test/test_threat_analyzer.cpp test/test_sighting_record.cpp
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `make test`
Expected: compile error — `fatal error: 'SightingRecord.h' file not found`

- [ ] **Step 3: Write the implementation**

Create `common/SightingRecord.h`:

```cpp
#ifndef SIGHTING_RECORD_H
#define SIGHTING_RECORD_H

#include <Arduino.h>

// One logged detection. Encoded to exactly 20 bytes, which is also the
// usable payload of a default-MTU (23 byte) BLE notification, so one
// sighting is one packet with no fragmentation.
static const size_t  SIGHTING_RECORD_SIZE   = 20;
static const uint8_t SIGHTING_FORMAT_VERSION = 1;

enum RadioType : uint8_t {
    RADIO_WIFI = 0,
    RADIO_BLE  = 1
};

struct SightingRecord {
    uint32_t msSinceBoot;   // wraps at ~49 days
    uint8_t  mac[6];
    int8_t   rssi;          // drives position estimation
    uint8_t  channel;
    uint8_t  radio;         // RadioType
    uint16_t matchFlags;    // which detectors fired
    uint8_t  certainty;
    uint8_t  alertLevel;
};

// Byte layout (little-endian, explicit — struct padding is not the contract):
//   [0..3]   msSinceBoot
//   [4..9]   mac
//   [10]     rssi
//   [11]     channel
//   [12]     radio
//   [13..14] matchFlags
//   [15]     certainty
//   [16]     alertLevel
//   [17..19] reserved, zero (GPS fix index in project D)
inline void encodeSighting(const SightingRecord& r, uint8_t* out) {
    out[0]  = (uint8_t)( r.msSinceBoot        & 0xFF);
    out[1]  = (uint8_t)((r.msSinceBoot >> 8)  & 0xFF);
    out[2]  = (uint8_t)((r.msSinceBoot >> 16) & 0xFF);
    out[3]  = (uint8_t)((r.msSinceBoot >> 24) & 0xFF);
    memcpy(out + 4, r.mac, 6);
    out[10] = (uint8_t)r.rssi;
    out[11] = r.channel;
    out[12] = r.radio;
    out[13] = (uint8_t)( r.matchFlags       & 0xFF);
    out[14] = (uint8_t)((r.matchFlags >> 8) & 0xFF);
    out[15] = r.certainty;
    out[16] = r.alertLevel;
    out[17] = 0;
    out[18] = 0;
    out[19] = 0;
}

inline void decodeSighting(const uint8_t* in, SightingRecord& out) {
    out.msSinceBoot = (uint32_t)in[0]
                    | ((uint32_t)in[1] << 8)
                    | ((uint32_t)in[2] << 16)
                    | ((uint32_t)in[3] << 24);
    memcpy(out.mac, in + 4, 6);
    out.rssi       = (int8_t)in[10];
    out.channel    = in[11];
    out.radio      = in[12];
    out.matchFlags = (uint16_t)in[13] | ((uint16_t)in[14] << 8);
    out.certainty  = in[15];
    out.alertLevel = in[16];
}

// The ring file is created zero-filled, so an all-zero slot is unwritten.
// A real record always carries a non-zero MAC.
inline bool sightingSlotIsEmpty(const uint8_t* raw) {
    for (size_t i = 0; i < SIGHTING_RECORD_SIZE; i++) {
        if (raw[i] != 0) return false;
    }
    return true;
}

#endif // SIGHTING_RECORD_H
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test`
Expected: `55 passed | 0 failed` (48 baseline + 7 new)

- [ ] **Step 5: Commit**

```bash
git add common/SightingRecord.h test/test_sighting_record.cpp Makefile
git commit -m "Add 20-byte sighting record codec"
```

---

## Task 2: RingIndex

Position arithmetic and seam recovery, with no filesystem dependency. Recovery reads timestamps through a callback so it can be tested against synthetic buffers.

**Files:**
- Create: `common/RingIndex.h`
- Create: `test/test_ring_index.cpp`
- Modify: `Makefile` (TEST_SRCS)

- [ ] **Step 1: Write the failing test**

Create `test/test_ring_index.cpp`:

```cpp
#include "doctest.h"
#include "RingIndex.h"
#include <vector>

// Synthetic ring: -1 means the slot is empty.
static RingRecovery recoverFrom(const std::vector<long>& slots) {
    return recoverRing((uint32_t)slots.size(),
        [&slots](uint32_t slot, uint32_t& tsOut) -> bool {
            if (slots[slot] < 0) return false;
            tsOut = (uint32_t)slots[slot];
            return true;
        });
}

TEST_CASE("RingIndex: advances and wraps") {
    RingIndex ring;
    ring.initialize(4);
    CHECK(ring.writeSlot() == 0);
    CHECK(ring.count() == 0);
    CHECK_FALSE(ring.wrapped());

    ring.advance();
    ring.advance();
    CHECK(ring.writeSlot() == 2);
    CHECK(ring.count() == 2);

    ring.advance();
    ring.advance();
    CHECK(ring.writeSlot() == 0);
    CHECK(ring.wrapped());
    CHECK(ring.count() == 4);

    ring.advance();
    CHECK(ring.writeSlot() == 1);
    CHECK(ring.count() == 4);   // stays saturated once wrapped
}

TEST_CASE("RingIndex: oldest slot is the write slot once wrapped") {
    RingIndex ring;
    ring.initialize(4);
    for (int i = 0; i < 6; i++) ring.advance();
    CHECK(ring.writeSlot() == 2);
    CHECK(ring.slotForAge(0) == 2);   // oldest
    CHECK(ring.slotForAge(3) == 1);   // newest
}

TEST_CASE("RingIndex: oldest slot is 0 before wrapping") {
    RingIndex ring;
    ring.initialize(4);
    ring.advance();
    ring.advance();
    CHECK(ring.slotForAge(0) == 0);
}

TEST_CASE("RingIndex: recovery on a completely empty ring") {
    RingRecovery r = recoverFrom({-1, -1, -1, -1});
    CHECK(r.writeSlot == 0);
    CHECK_FALSE(r.wrapped);
}

TEST_CASE("RingIndex: recovery on a partially filled ring resumes at first gap") {
    // This is the never-wrapped case: no descending step exists.
    RingRecovery r = recoverFrom({100, 200, 300, -1});
    CHECK(r.writeSlot == 3);
    CHECK_FALSE(r.wrapped);
}

TEST_CASE("RingIndex: recovery on a full ring finds the seam") {
    // Seam between 400 and 150: writing resumes at that slot.
    RingRecovery r = recoverFrom({300, 400, 150, 200});
    CHECK(r.writeSlot == 2);
    CHECK(r.wrapped);
}

TEST_CASE("RingIndex: recovery on a full ring that wrapped exactly") {
    RingRecovery r = recoverFrom({100, 200, 300, 400});
    CHECK(r.writeSlot == 0);
    CHECK(r.wrapped);
}

TEST_CASE("RingIndex: restore round-trips through recovery") {
    RingIndex ring;
    ring.initialize(4);
    RingRecovery r = recoverFrom({300, 400, 150, 200});
    ring.restore(r.writeSlot, r.wrapped);
    CHECK(ring.writeSlot() == 2);
    CHECK(ring.count() == 4);
}
```

Add `test/test_ring_index.cpp` to `TEST_SRCS`.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `make test`
Expected: compile error — `fatal error: 'RingIndex.h' file not found`

- [ ] **Step 3: Write the implementation**

Create `common/RingIndex.h`:

```cpp
#ifndef RING_INDEX_H
#define RING_INDEX_H

#include <Arduino.h>
#include <functional>

struct RingRecovery {
    uint32_t writeSlot;
    bool     wrapped;
};

class RingIndex {
public:
    void initialize(uint32_t capacity) {
        cap      = capacity;
        writePos = 0;
        didWrap  = false;
    }

    void restore(uint32_t writeSlot, bool wrapped) {
        writePos = (cap == 0) ? 0 : (writeSlot % cap);
        didWrap  = wrapped;
    }

    uint32_t capacity()  const { return cap; }
    uint32_t writeSlot() const { return writePos; }
    bool     wrapped()   const { return didWrap; }
    uint32_t count()     const { return didWrap ? cap : writePos; }

    void advance() {
        if (cap == 0) return;
        writePos++;
        if (writePos >= cap) {
            writePos = 0;
            didWrap  = true;
        }
    }

    // age 0 is the oldest retained record.
    uint32_t slotForAge(uint32_t age) const {
        if (cap == 0) return 0;
        if (!didWrap) return age;          // oldest lives at slot 0
        return (writePos + age) % cap;     // oldest is the next write slot
    }

private:
    uint32_t cap      = 0;
    uint32_t writePos = 0;
    bool     didWrap  = false;
};

// Recover the write position after a reboot, since the index is kept in RAM
// rather than rewritten to flash on every record.
//
// readTs(slot, tsOut) returns false when the slot is unwritten.
//
// Two distinct cases:
//   - Never wrapped: there is a gap. Resume at the first empty slot. There is
//     no descending timestamp step to find, so this must be handled first --
//     otherwise a first-session log would resume at 0 and overwrite good data.
//   - Wrapped: the ring is full and timestamps descend exactly once, at the
//     seam. Resume there.
inline RingRecovery recoverRing(
        uint32_t capacity,
        const std::function<bool(uint32_t slot, uint32_t& tsOut)>& readTs) {
    RingRecovery result{0, false};
    if (capacity == 0) return result;

    for (uint32_t i = 0; i < capacity; i++) {
        uint32_t ts;
        if (!readTs(i, ts)) {
            result.writeSlot = i;
            result.wrapped   = false;
            return result;
        }
    }

    // Full ring: find the single descending step.
    uint32_t prev = 0;
    readTs(0, prev);
    for (uint32_t i = 1; i < capacity; i++) {
        uint32_t ts;
        readTs(i, ts);
        if (ts < prev) {
            result.writeSlot = i;
            result.wrapped   = true;
            return result;
        }
        prev = ts;
    }

    // Monotonic throughout: the seam is the wrap point at slot 0.
    result.writeSlot = 0;
    result.wrapped   = true;
    return result;
}

#endif // RING_INDEX_H
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test`
Expected: `63 passed | 0 failed` (55 + 8 new)

- [ ] **Step 5: Commit**

```bash
git add common/RingIndex.h test/test_ring_index.cpp Makefile
git commit -m "Add ring buffer index math and seam recovery"
```

---

## Task 3: RateLimiter

Gates both the log write and the BLE notification, so the stream and the log always agree.

**Files:**
- Create: `common/RateLimiter.h`
- Create: `test/test_rate_limiter.cpp`
- Modify: `Makefile` (TEST_SRCS)

- [ ] **Step 1: Write the failing test**

Create `test/test_rate_limiter.cpp`:

```cpp
#include "doctest.h"
#include "RateLimiter.h"

static void setMAC(uint8_t* dst, uint8_t last) {
    dst[0] = 0xB4; dst[1] = 0x1E; dst[2] = 0x52;
    dst[3] = 0x00; dst[4] = 0x00; dst[5] = last;
}

TEST_CASE("RateLimiter: first sighting of a MAC is always allowed") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
}

TEST_CASE("RateLimiter: a burst inside the interval is suppressed") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
    CHECK_FALSE(limiter.allow(mac, 1050));
    CHECK_FALSE(limiter.allow(mac, 1099));
}

TEST_CASE("RateLimiter: allowed again once the interval elapses") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
    CHECK(limiter.allow(mac, 1100));
    CHECK_FALSE(limiter.allow(mac, 1150));
    CHECK(limiter.allow(mac, 1200));
}

TEST_CASE("RateLimiter: limits are per-MAC, not global") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t a[6], b[6];
    setMAC(a, 1);
    setMAC(b, 2);
    CHECK(limiter.allow(a, 1000));
    CHECK(limiter.allow(b, 1000));      // different device, not throttled
    CHECK_FALSE(limiter.allow(a, 1010));
}

TEST_CASE("RateLimiter: more MACs than slots still admits new devices") {
    RateLimiter limiter;
    limiter.initialize(100);
    for (uint8_t i = 0; i < RateLimiter::SLOTS + 8; i++) {
        uint8_t mac[6];
        setMAC(mac, i);
        CHECK(limiter.allow(mac, 1000 + i));
    }
}

TEST_CASE("RateLimiter: a zero interval never suppresses") {
    RateLimiter limiter;
    limiter.initialize(0);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
    CHECK(limiter.allow(mac, 1000));
}
```

Add `test/test_rate_limiter.cpp` to `TEST_SRCS`.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `make test`
Expected: compile error — `fatal error: 'RateLimiter.h' file not found`

- [ ] **Step 3: Write the implementation**

Create `common/RateLimiter.h`:

```cpp
#ifndef RATE_LIMITER_H
#define RATE_LIMITER_H

#include <Arduino.h>

// Caps how often a single device may produce a record. At 30mph, 100ms is
// about 1.3m of travel -- far finer than any GPS fix resolves -- so this
// costs no positioning accuracy while saving flash capacity and BLE airtime.
class RateLimiter {
public:
    static const uint8_t SLOTS = 32;

    void initialize(uint32_t minIntervalMs) {
        minInterval = minIntervalMs;
        for (uint8_t i = 0; i < SLOTS; i++) {
            entries[i].used   = false;
            entries[i].lastMs = 0;
        }
    }

    bool allow(const uint8_t* mac, uint32_t nowMs) {
        if (minInterval == 0) return true;

        for (uint8_t i = 0; i < SLOTS; i++) {
            if (entries[i].used && memcmp(entries[i].mac, mac, 6) == 0) {
                if ((uint32_t)(nowMs - entries[i].lastMs) < minInterval) {
                    return false;
                }
                entries[i].lastMs = nowMs;
                return true;
            }
        }

        // Unknown device: take a free slot, else evict least-recently-seen.
        uint8_t target = 0;
        uint32_t oldest = UINT32_MAX;
        bool foundFree = false;
        for (uint8_t i = 0; i < SLOTS; i++) {
            if (!entries[i].used) { target = i; foundFree = true; break; }
            if (entries[i].lastMs < oldest) { oldest = entries[i].lastMs; target = i; }
        }
        (void)foundFree;

        memcpy(entries[target].mac, mac, 6);
        entries[target].lastMs = nowMs;
        entries[target].used   = true;
        return true;
    }

private:
    struct Entry {
        uint8_t  mac[6];
        uint32_t lastMs;
        bool     used;
    };
    Entry    entries[SLOTS];
    uint32_t minInterval = 0;
};

#endif // RATE_LIMITER_H
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test`
Expected: `69 passed | 0 failed` (63 + 6 new)

- [ ] **Step 5: Commit**

```bash
git add common/RateLimiter.h test/test_rate_limiter.cpp Makefile
git commit -m "Add per-MAC rate limiter"
```

---

## Task 4: DeviceTable

Tracks which MACs already had their identity written to `/devices.bin`, so SSIDs are stored once rather than duplicated across thousands of sightings.

**Files:**
- Create: `common/DeviceTable.h`
- Create: `test/test_device_table.cpp`
- Modify: `Makefile` (TEST_SRCS)

- [ ] **Step 1: Write the failing test**

Create `test/test_device_table.cpp`:

```cpp
#include "doctest.h"
#include "DeviceTable.h"

static void setMACIndex(uint8_t* dst, uint16_t index) {
    dst[0] = 0xB4; dst[1] = 0x1E; dst[2] = 0x52; dst[3] = 0x00;
    dst[4] = (uint8_t)(index >> 8);
    dst[5] = (uint8_t)(index & 0xFF);
}

TEST_CASE("DeviceTable: a new MAC is reported as new exactly once") {
    DeviceTable table;
    table.initialize();
    uint8_t mac[6];
    setMACIndex(mac, 1);
    CHECK(table.observe(mac));
    CHECK_FALSE(table.observe(mac));
    CHECK_FALSE(table.observe(mac));
}

TEST_CASE("DeviceTable: distinct MACs are each new") {
    DeviceTable table;
    table.initialize();
    uint8_t a[6], b[6];
    setMACIndex(a, 1);
    setMACIndex(b, 2);
    CHECK(table.observe(a));
    CHECK(table.observe(b));
    CHECK(table.size() == 2);
}

TEST_CASE("DeviceTable: size starts at zero") {
    DeviceTable table;
    table.initialize();
    CHECK(table.size() == 0);
    CHECK_FALSE(table.atCapacity());
}

TEST_CASE("DeviceTable: stops reporting new MACs at capacity") {
    DeviceTable table;
    table.initialize();
    for (uint16_t i = 0; i < DeviceTable::CAPACITY; i++) {
        uint8_t mac[6];
        setMACIndex(mac, i);
        CHECK(table.observe(mac));
    }
    CHECK(table.atCapacity());

    uint8_t overflow[6];
    setMACIndex(overflow, DeviceTable::CAPACITY + 1);
    // Full: identity cannot be recorded, so do not claim it is new.
    CHECK_FALSE(table.observe(overflow));
    CHECK(table.size() == DeviceTable::CAPACITY);
}

TEST_CASE("DeviceTable: known MACs still resolve when full") {
    DeviceTable table;
    table.initialize();
    for (uint16_t i = 0; i < DeviceTable::CAPACITY; i++) {
        uint8_t mac[6];
        setMACIndex(mac, i);
        table.observe(mac);
    }
    uint8_t known[6];
    setMACIndex(known, 0);
    CHECK_FALSE(table.observe(known));
}
```

Add `test/test_device_table.cpp` to `TEST_SRCS`.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `make test`
Expected: compile error — `fatal error: 'DeviceTable.h' file not found`

- [ ] **Step 3: Write the implementation**

Create `common/DeviceTable.h`:

```cpp
#ifndef DEVICE_TABLE_H
#define DEVICE_TABLE_H

#include <Arduino.h>

// Remembers which MACs have already had their identity persisted.
// 512 entries x 6 bytes = 3KB of RAM, which the FIRE has in abundance.
class DeviceTable {
public:
    static const uint16_t CAPACITY = 512;

    void initialize() { used = 0; }

    // Returns true when this MAC is newly seen AND there was room to record
    // it. At capacity we return false: identity cannot be stored, so the
    // caller must not believe it was.
    bool observe(const uint8_t* mac) {
        for (uint16_t i = 0; i < used; i++) {
            if (memcmp(macs[i], mac, 6) == 0) return false;
        }
        if (used >= CAPACITY) return false;
        memcpy(macs[used], mac, 6);
        used++;
        return true;
    }

    uint16_t size()       const { return used; }
    bool     atCapacity() const { return used >= CAPACITY; }

private:
    uint8_t  macs[CAPACITY][6];
    uint16_t used = 0;
};

#endif // DEVICE_TABLE_H
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test`
Expected: `74 passed | 0 failed` (69 + 5 new)

- [ ] **Step 5: Commit**

```bash
git add common/DeviceTable.h test/test_device_table.cpp Makefile
git commit -m "Add device dedupe table"
```

---

## Task 5: DetectionLog

Binds the four pure units to LittleFS. Not host-testable — verified on hardware in Task 8.

**Files:**
- Create: `m5stack/flocksquawk_m5fire/src/DetectionLog.h`

- [ ] **Step 1: Write the implementation**

Create `m5stack/flocksquawk_m5fire/src/DetectionLog.h`:

```cpp
#ifndef DETECTION_LOG_H
#define DETECTION_LOG_H

#include <Arduino.h>
#include <LittleFS.h>
#include "EventBus.h"
#include "SightingRecord.h"
#include "RingIndex.h"
#include "RateLimiter.h"
#include "DeviceTable.h"

// Durable log of raw sightings. Logging is strictly secondary to detection:
// every failure path here leaves the device detecting and alerting normally.
class DetectionLog {
public:
    static constexpr const char* SIGHTINGS_PATH = "/sightings.bin";
    static constexpr const char* DEVICES_PATH   = "/devices.bin";

    // 2MB of sightings leaves room for audio (~328KB) in the 3456K partition.
    static const uint32_t RING_CAPACITY   = 100000;   // 100k * 20B = 2.0MB
    static const uint32_t RATE_LIMIT_MS   = 100;
    static const size_t   DEVICE_REC_SIZE = 48;       // 6 mac + 40 name + 1 radio + 1 pad

    bool initialize() {
        ready = false;
        limiter.initialize(RATE_LIMIT_MS);
        devices.initialize();
        ring.initialize(RING_CAPACITY);

        if (!LittleFS.exists(SIGHTINGS_PATH)) {
            if (!createRingFile()) {
                Serial.println("[Log] Could not create ring file; logging disabled");
                return false;
            }
        }

        RingRecovery rec = recoverRing(RING_CAPACITY,
            [this](uint32_t slot, uint32_t& tsOut) -> bool {
                uint8_t raw[SIGHTING_RECORD_SIZE];
                if (!readSlot(slot, raw)) return false;
                if (sightingSlotIsEmpty(raw)) return false;
                SightingRecord r{};
                decodeSighting(raw, r);
                tsOut = r.msSinceBoot;
                return true;
            });
        ring.restore(rec.writeSlot, rec.wrapped);

        ready = true;
        Serial.printf("[Log] Ready: slot %u/%u, wrapped=%d\n",
                      (unsigned)ring.writeSlot(), (unsigned)RING_CAPACITY,
                      (int)ring.wrapped());
        return true;
    }

    // Mirrors TelemetryReporter's entry point.
    void handleThreatDetection(const ThreatEvent& threat) {
        if (!ready) return;

        uint32_t now = millis();
        if (!limiter.allow(threat.mac, now)) return;

        if (devices.observe(threat.mac)) {
            appendDevice(threat);
        }

        SightingRecord r{};
        r.msSinceBoot = now;
        memcpy(r.mac, threat.mac, 6);
        r.rssi       = threat.rssi;
        r.channel    = threat.channel;
        r.radio      = (strcmp(threat.radioType, "ble") == 0) ? RADIO_BLE : RADIO_WIFI;
        r.matchFlags = threat.matchFlags;
        r.certainty  = threat.certainty;
        r.alertLevel = (uint8_t)threat.alertLevel;

        uint8_t raw[SIGHTING_RECORD_SIZE];
        encodeSighting(r, raw);
        if (writeSlot(ring.writeSlot(), raw)) {
            ring.advance();
        }
    }

    bool     isReady()   const { return ready; }
    uint32_t stored()    const { return ring.count(); }
    uint32_t capacity()  const { return RING_CAPACITY; }

    // Read one record by age; age 0 is the oldest retained. Used for backfill.
    bool readByAge(uint32_t age, uint8_t* out) {
        if (!ready || age >= ring.count()) return false;
        return readSlot(ring.slotForAge(age), out);
    }

private:
    bool createRingFile() {
        File f = LittleFS.open(SIGHTINGS_PATH, FILE_WRITE);
        if (!f) return false;
        uint8_t zeros[SIGHTING_RECORD_SIZE * 64];
        memset(zeros, 0, sizeof(zeros));
        uint32_t remaining = RING_CAPACITY;
        while (remaining > 0) {
            uint32_t batch = remaining > 64 ? 64 : remaining;
            if (f.write(zeros, SIGHTING_RECORD_SIZE * batch)
                    != SIGHTING_RECORD_SIZE * batch) {
                f.close();
                return false;
            }
            remaining -= batch;
        }
        f.close();
        return true;
    }

    bool readSlot(uint32_t slot, uint8_t* out) {
        File f = LittleFS.open(SIGHTINGS_PATH, FILE_READ);
        if (!f) return false;
        if (!f.seek(slot * SIGHTING_RECORD_SIZE)) { f.close(); return false; }
        size_t got = f.read(out, SIGHTING_RECORD_SIZE);
        f.close();
        return got == SIGHTING_RECORD_SIZE;
    }

    bool writeSlot(uint32_t slot, const uint8_t* raw) {
        File f = LittleFS.open(SIGHTINGS_PATH, "r+");
        if (!f) return false;
        if (!f.seek(slot * SIGHTING_RECORD_SIZE)) { f.close(); return false; }
        size_t put = f.write(raw, SIGHTING_RECORD_SIZE);
        f.close();
        return put == SIGHTING_RECORD_SIZE;
    }

    void appendDevice(const ThreatEvent& threat) {
        File f = LittleFS.open(DEVICES_PATH, FILE_APPEND);
        if (!f) return;
        uint8_t rec[DEVICE_REC_SIZE];
        memset(rec, 0, sizeof(rec));
        memcpy(rec, threat.mac, 6);
        strncpy((char*)(rec + 6), threat.identifier, 39);
        rec[46] = (strcmp(threat.radioType, "ble") == 0) ? RADIO_BLE : RADIO_WIFI;
        f.write(rec, sizeof(rec));
        f.close();
    }

    RingIndex   ring;
    RateLimiter limiter;
    DeviceTable devices;
    bool        ready = false;
};

#endif // DETECTION_LOG_H
```

- [ ] **Step 2: Confirm it compiles**

Run: `make build VARIANT=m5fire`
Expected: compiles; reports program storage usage. Nothing else uses it yet.

- [ ] **Step 3: Prove random-access writes actually work before depending on them**

The entire ring design rests on `LittleFS.open(path, "r+")` supporting seek-and-
overwrite. Arduino's FS layer documents only `FILE_READ`/`FILE_WRITE`/`FILE_APPEND`;
`"r+"` is passed through to the ESP-IDF VFS. **Verify it rather than assume it** —
if it silently truncates or fails, every design decision above changes.

Add this temporarily to `setup()`, after `detectionLog.initialize()`:

```cpp
    {   // TEMPORARY probe -- remove after verifying
        File f = LittleFS.open("/rwtest.bin", FILE_WRITE);
        uint8_t z[60]; memset(z, 0, sizeof(z));
        f.write(z, sizeof(z)); f.close();

        File w = LittleFS.open("/rwtest.bin", "r+");
        Serial.printf("[Probe] r+ open: %s\n", w ? "OK" : "FAILED");
        if (w) {
            w.seek(20);
            uint8_t marker[20]; memset(marker, 0xA5, sizeof(marker));
            size_t put = w.write(marker, sizeof(marker));
            w.close();
            Serial.printf("[Probe] wrote %u bytes at offset 20\n", (unsigned)put);
        }
        File r = LittleFS.open("/rwtest.bin", FILE_READ);
        Serial.printf("[Probe] size after write: %u (expect 60)\n", (unsigned)r.size());
        r.seek(20);
        uint8_t chk[20]; r.read(chk, sizeof(chk)); r.close();
        Serial.printf("[Probe] byte at 20: 0x%02X (expect 0xA5)\n", chk[0]);
        LittleFS.remove("/rwtest.bin");

        uint32_t t0 = millis();
        for (int i = 0; i < 100; i++) {
            uint8_t rec[SIGHTING_RECORD_SIZE]; memset(rec, i, sizeof(rec));
            File wf = LittleFS.open(DetectionLog::SIGHTINGS_PATH, "r+");
            if (wf) { wf.seek(i * SIGHTING_RECORD_SIZE);
                      wf.write(rec, sizeof(rec)); wf.close(); }
        }
        Serial.printf("[Probe] 100 open-seek-write-close: %lu ms\n",
                      (unsigned long)(millis() - t0));
    }
```

Build, flash, and read the serial output.

Expected: `r+ open: OK`, `wrote 20 bytes`, `size after write: 60` (**not** 20 —
truncation would mean `"r+"` behaved as `"w"`), `byte at 20: 0xA5`.

The timing line is the real decision point. `DetectionLog` opens and closes the
file per record, which is the durable choice — nothing is buffered when power
is cut. If 100 writes take **under ~500ms** (5ms each), that comfortably absorbs
the ~10 records/sec the rate limiter permits; keep it. If it is much slower,
hold one `File` handle open in `DetectionLog` and flush every N records,
accepting that a power cut loses the unflushed tail.

Record the measured number here before continuing. Remove the probe block once done.

- [ ] **Step 4: Commit**

```bash
git add m5stack/flocksquawk_m5fire/src/DetectionLog.h
git commit -m "Add LittleFS-backed detection log"
```

---

## Task 6: BleReporter

NimBLE GATT peripheral. Signatures below were read from the installed NimBLE-Arduino 2.3.7 headers at `~/Documents/Arduino/libraries/NimBLE-Arduino/src/NimBLEServer.h`.

**Files:**
- Create: `m5stack/flocksquawk_m5fire/src/BleReporter.h`

- [ ] **Step 1: Re-confirm the callback signatures before writing code**

Run:
```bash
grep -nE 'virtual (void|uint32_t) on(Connect|Disconnect|PassKeyDisplay|AuthenticationComplete)' \
  ~/Documents/Arduino/libraries/NimBLE-Arduino/src/NimBLEServer.h
```

Expected exactly:
```
virtual void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo);
virtual void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason);
virtual uint32_t onPassKeyDisplay();
virtual void onAuthenticationComplete(NimBLEConnInfo& connInfo);
```

If they differ, the library version changed — adjust the overrides below to match before continuing.

- [ ] **Step 2: Write the implementation**

Create `m5stack/flocksquawk_m5fire/src/BleReporter.h`:

```cpp
#ifndef BLE_REPORTER_H
#define BLE_REPORTER_H

#include <Arduino.h>
#include <M5Unified.h>
#include <NimBLEDevice.h>
#include "EventBus.h"
#include "SightingRecord.h"

// GATT peripheral streaming sightings to a paired phone.
//
// NimBLE already runs as a central here (the scanner). Adding the peripheral
// role shares radio time on a chip that is also hopping WiFi channels, so
// advertising is deliberately slow: the phone connects once per drive.
#define FS_SERVICE_UUID     "6f1d0001-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_SIGHTING    "6f1d0002-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_DEVICEINFO  "6f1d0003-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_TIMESYNC    "6f1d0004-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_LOGCONTROL  "6f1d0005-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_STATUS      "6f1d0006-b5a3-f393-e0a9-e50e24dcca9e"

class BleReporter : public NimBLEServerCallbacks {
public:
    // Advertise once per second. This is the first lever to pull if the
    // peripheral role measurably costs detection rate.
    static const uint16_t ADV_INTERVAL_MIN = 0x0640;  // 1000ms
    static const uint16_t ADV_INTERVAL_MAX = 0x0680;  // 1040ms
    static const uint32_t PASSKEY          = 123456;

    void initialize() {
        // NimBLEDevice::init() is already called by the scanner. Calling it
        // twice is harmless, but security config must be set before advertising.
        NimBLEDevice::setSecurityAuth(true, true, true);        // bond, MITM, SC
        NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY); // we show a passkey
        NimBLEDevice::setSecurityPasskey(PASSKEY);

        server = NimBLEDevice::createServer();
        server->setCallbacks(this);

        NimBLEService* svc = server->createService(FS_SERVICE_UUID);

        sighting = svc->createCharacteristic(
            FS_CHAR_SIGHTING, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ_ENC);
        deviceInfo = svc->createCharacteristic(
            FS_CHAR_DEVICEINFO, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ_ENC);
        timeSync = svc->createCharacteristic(
            FS_CHAR_TIMESYNC, NIMBLE_PROPERTY::READ_ENC);
        logControl = svc->createCharacteristic(
            FS_CHAR_LOGCONTROL, NIMBLE_PROPERTY::WRITE_ENC);
        status = svc->createCharacteristic(
            FS_CHAR_STATUS, NIMBLE_PROPERTY::READ_ENC);

        svc->start();

        NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
        adv->addServiceUUID(FS_SERVICE_UUID);
        adv->setMinInterval(ADV_INTERVAL_MIN);
        adv->setMaxInterval(ADV_INTERVAL_MAX);
        adv->start();

        Serial.println("[BLE] Peripheral advertising");
    }

    // Mirrors TelemetryReporter's entry point. The caller applies the rate
    // limit before this, so the stream and the log always agree.
    void handleThreatDetection(const ThreatEvent& threat) {
        if (!connected || sighting == nullptr) return;

        SightingRecord r{};
        r.msSinceBoot = millis();
        memcpy(r.mac, threat.mac, 6);
        r.rssi       = threat.rssi;
        r.channel    = threat.channel;
        r.radio      = (strcmp(threat.radioType, "ble") == 0) ? RADIO_BLE : RADIO_WIFI;
        r.matchFlags = threat.matchFlags;
        r.certainty  = threat.certainty;
        r.alertLevel = (uint8_t)threat.alertLevel;

        uint8_t raw[SIGHTING_RECORD_SIZE];
        encodeSighting(r, raw);
        sighting->setValue(raw, SIGHTING_RECORD_SIZE);
        sighting->notify();
    }

    // Called once per newly seen MAC so the phone can label it.
    void publishDeviceInfo(const ThreatEvent& threat) {
        if (!connected || deviceInfo == nullptr) return;
        uint8_t buf[46];
        memset(buf, 0, sizeof(buf));
        memcpy(buf, threat.mac, 6);
        strncpy((char*)(buf + 6), threat.identifier, 39);
        deviceInfo->setValue(buf, sizeof(buf));
        deviceInfo->notify();
    }

    // The phone pairs this with its own wall clock to place every record in
    // real time. This is what removes the need for an RTC.
    void refreshTimeSync() {
        if (timeSync == nullptr) return;
        uint32_t now = millis();
        uint8_t buf[4] = {
            (uint8_t)( now        & 0xFF), (uint8_t)((now >> 8)  & 0xFF),
            (uint8_t)((now >> 16) & 0xFF), (uint8_t)((now >> 24) & 0xFF)
        };
        timeSync->setValue(buf, sizeof(buf));
    }

    void setStatus(uint32_t stored, uint32_t capacity) {
        if (status == nullptr) return;
        uint8_t buf[10];
        buf[0] = SIGHTING_FORMAT_VERSION;
        buf[1] = 1;  // firmware revision of this interface
        memcpy(buf + 2, &stored,   4);
        memcpy(buf + 6, &capacity, 4);
        status->setValue(buf, sizeof(buf));
    }

    bool isConnected() const { return connected; }

    // --- NimBLEServerCallbacks ---
    void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
        connected = true;
        refreshTimeSync();
        Serial.println("[BLE] Phone connected");
    }

    void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
        connected = false;
        Serial.println("[BLE] Phone disconnected; re-advertising");
        NimBLEDevice::startAdvertising();
    }

    uint32_t onPassKeyDisplay() override {
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setCursor(0, 40);
        M5.Display.setTextSize(3);
        M5.Display.println("BLE PAIRING");
        M5.Display.setTextSize(4);
        M5.Display.printf("\n %06u\n", (unsigned)PASSKEY);
        Serial.printf("[BLE] Passkey: %06u\n", (unsigned)PASSKEY);
        return PASSKEY;
    }

    void onAuthenticationComplete(NimBLEConnInfo&) override {
        Serial.println("[BLE] Pairing complete");
    }

private:
    NimBLEServer*         server     = nullptr;
    NimBLECharacteristic* sighting   = nullptr;
    NimBLECharacteristic* deviceInfo = nullptr;
    NimBLECharacteristic* timeSync   = nullptr;
    NimBLECharacteristic* logControl = nullptr;
    NimBLECharacteristic* status     = nullptr;
    bool                  connected  = false;
};

#endif // BLE_REPORTER_H
```

- [ ] **Step 3: Confirm it compiles**

Run: `make build VARIANT=m5fire`
Expected: compiles cleanly. If `BLE_HS_IO_DISPLAY_ONLY` is undefined, add `#include <host/ble_sm.h>` above the NimBLE include.

- [ ] **Step 4: Commit**

```bash
git add m5stack/flocksquawk_m5fire/src/BleReporter.h
git commit -m "Add NimBLE GATT peripheral with passkey pairing"
```

---

## Task 7: Wire both components into the sketch

**Files:**
- Modify: `m5stack/flocksquawk_m5fire/flocksquawk_m5fire.ino`

- [ ] **Step 1: Add the includes**

Near the existing `#include "src/SoundEngine.h"`, add:

```cpp
#include "src/DetectionLog.h"
#include "src/BleReporter.h"
```

- [ ] **Step 2: Declare the instances**

Beside the existing `TelemetryReporter reporter;` declaration, add:

```cpp
DetectionLog detectionLog;
BleReporter  bleReporter;
```

- [ ] **Step 3: Initialize them in setup()**

In `setup()`, immediately after `audioSystem.initialize();` and `loadSettingsFromSd();`:

```cpp
    detectionLog.initialize();
    bleReporter.initialize();
    bleReporter.setStatus(detectionLog.stored(), detectionLog.capacity());
```

`DetectionLog::initialize()` returns false on failure and logs it; detection continues regardless, which is the required behaviour.

- [ ] **Step 4: Call them from the threat handler**

In `loop()`, in the existing `if (threatPending)` block, after
`reporter.handleThreatDetection(threatCopy);` add:

```cpp
        detectionLog.handleThreatDetection(threatCopy);
        bleReporter.handleThreatDetection(threatCopy);
```

Leave the existing alert handling below untouched.

- [ ] **Step 5: Build**

Run: `make build VARIANT=m5fire`
Expected: compiles. Program storage should rise a few percent from the ~22% baseline.

- [ ] **Step 6: Commit**

```bash
git add m5stack/flocksquawk_m5fire/flocksquawk_m5fire.ino
git commit -m "Wire detection log and BLE reporter into the FIRE sketch"
```

---

## Task 8: On-device verification

These are the spec's acceptance criteria. Do not mark the feature done until each passes.

- [x] **Step 1: Flash** — PASSED

```bash
ls /dev/cu.* | grep usbserial
make upload VARIANT=m5fire PORT=/dev/cu.usbserial-XXXX
```

Expected: `Hash of data verified.` If the port vanishes mid-flash, replug and retry — the write aborts before touching flash.

- [x] **Step 2: Confirm a clean boot** — PASSED (the `[Log] Ready:` line now reads `seg N seq M, x/y in segment, z total`; the `slot/wrapped` form below predates the segmented log)

Open a capture, then power-cycle the board (double-press the red side button to power off, single press to power on):

```bash
PORT=/dev/cu.usbserial-XXXX
exec 3<> "$PORT"; stty -f "$PORT" 115200 raw -echo; cat <&3 | head -40
```

Expected lines:
```
[Audio] LittleFS mounted: ...
[Audio] PSRAM: 4191656 free of 4194304 total; ...
[Log] Ready: slot 0/100000, wrapped=0
[BLE] Peripheral advertising
System operational - scanning for targets
```

First boot also spends time creating the 2MB ring file. If `[Log]` reports a failure, logging is disabled but detection must still work — verify that before debugging the log.

- [x] **Step 3: Verify pairing and the live stream** — PASSED 2026-09-08

Install LightBlue on the iPhone, scan, and connect to the FlockSquawk service.

Expected: the FIRE's screen shows `BLE PAIRING` and a six-digit passkey; entering it on the phone completes pairing. Subscribe to the `Sighting` characteristic, then bring up a hotspot named `Flock-A1B2C3` (with **Maximize Compatibility ON** — the scanner is 2.4GHz only).

Expected: 20-byte notifications arrive. Byte 10 is RSSI as a signed value; bytes 4–9 are the MAC.

- [x] **Step 4: Verify an unpaired client cannot read** — PASSED, but the stated expectation was WRONG

Reads are refused. **Subscribes are not.** The CCCD does not inherit the
characteristic's encryption requirement — the GATT dump shows `6f1d0002` as
`[READ|NOTIFY|READ_ENC|READ_AUTHEN]` while its descriptor registers with
`min_key_size 0`. NimBLE accepts the CCCD write and only then calls
`startSecurity()` reactively. Also note `READ_ENC` alone is satisfied by Just
Works pairing, which made the passkey decorative until `READ_AUTHEN` was added.

Closed in `a2a6468` by gating transmission on `isAuthenticated()` rather than
trying to refuse the subscribe.

- [ ] **Step 5: Verify clock correlation (acceptance criterion 4)**

Read `TimeSync`, note the wall-clock time at that moment, then trigger a detection and note its wall-clock time. Convert the notification's `msSinceBoot` using the offset.

Expected: within one second of observed reality.

- [x] **Step 6: Measure the dual-role cost (acceptance criterion 1)** — PASSED 2026-09-08, +3.6%, see docs/handoff/firmware-remaining-work.md

With the `Flock-A1B2C3` hotspot up and the board stationary, count `target_detected` lines over 60 seconds with BLE disconnected, then repeat with a phone connected and subscribed:

```bash
exec 3<> "$PORT"; stty -f "$PORT" 115200 raw -echo; cat <&3 > /tmp/rate.log &
sleep 60; kill %1; grep -c target_detected /tmp/rate.log
```

Expected: no measurable drop. **If detections fall materially, stop and report it** — the spec calls for a design change (advertise only when a phone is near, or batch notifications), not a quiet tuning tweak.

- [x] **Step 7: Verify segment rotation does not brick the device (acceptance criterion 2)** — PASSED 2026-09-08

Rewritten: the LittleFS ring buffer was replaced by a segmented append-only log
after the 1690ms/record measurement, so `RING_CAPACITY` and `wrapped=` no longer
exist. Segment size is now build-overridable, so no source edit is needed:

```bash
make build VARIANT=m5fire m5fire_DEFINES="-DBOARD_HAS_PSRAM -mfix-esp32-psram-cache-issue -mfix-esp32-psram-cache-strategy=memw -DFS_RECORDS_PER_SEGMENT=20"
```

Observed: rotation through `seg 0→1→…→7→0` with the sequence climbing
monotonically, no `Rotation failed`, no crash. After the wrap, a reboot reported
`[Log] Ready: seg 7 seq 32, 3/20 in segment, 143 total` — the segment was
recovered from on-disk headers alone, and the record count was capped at the
8x20 capacity where it had held 1835 before, proving the oldest data is deleted
rather than accumulated.

- [x] **Step 8: Verify graceful degradation (acceptance criterion 6)** — PASSED 2026-09-08

Filling the partition is **not sufficient**, which is worth knowing before
anyone retries it: the log survives a full filesystem. Rotation truncates an
existing segment and reuses its blocks, so it is space-neutral, and a fresh
segment is only a 12-byte header. Both were confirmed on hardware with LittleFS
filled to 3,169,280 bytes — rotation still succeeded and detection was
unaffected.

The failure therefore has to be injected. Build with `-DFS_FORCE_LOG_FAIL`,
which points segments at a directory LittleFS does not have:

```
[Log] Cannot create segment; logging disabled
System operational - scanning for targets
```

Observed with logging fully dead: 23 detections, 1 alert with audio, BLE
advertising and pairing all normal, 0 crashes. `FS_FILL_DISK`, `FS_WIPE_SEGMENTS`
and `FS_FREE_DISK` hooks in the sketch support the disk-full variants.

- [x] **Step 9: Confirm the host suite still passes**

Run: `make test`
Expected: `86 passed | 0 failed` (was 74 when this plan was written; the storage
redesign and the 2026-09-08 tracker fixes added tests).

- [ ] **Step 10: Commit any fixes and update the spec status**

```bash
git add -A
git commit -m "Verify BLE detection reporting on hardware"
```

---

## Self-review notes

**Spec coverage.** Every spec section maps to a task: record format and capacity → Task 1; ring behaviour, wrap policy and seam recovery → Task 2; rate limiting across both sinks → Task 3; device dedupe and capacity → Task 4; storage layout and error handling → Task 5; GATT interface, advertising interval and passkey pairing → Task 6; integration point → Task 7; all six acceptance criteria → Task 8.

**Deliberately deferred.** `LogControl` backfill is declared as a characteristic but its handler is not implemented. The spec frames backfill as dropout resilience rather than standalone operation, and the phone cannot place location-free records without its own track. Implementing it now would be building against an unwritten consumer — it belongs with the iOS app spec (project B).

**Type consistency.** `handleThreatDetection(const ThreatEvent&)` is the entry point on both new components, matching `TelemetryReporter`. `SightingRecord` field names are identical across Tasks 1, 5 and 6. `RADIO_WIFI`/`RADIO_BLE` come from `SightingRecord.h` and are used unchanged in both hardware components.

**Known issue, not introduced here.** `DeviceTracker` re-registers MACs that never left range, so `firstDetection` fires repeatedly. It does not affect any field this plan logs. Out of scope, recorded in the spec.
