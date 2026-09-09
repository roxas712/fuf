#ifndef RATE_LIMITER_H
#define RATE_LIMITER_H

#include <Arduino.h>

// Caps how often a single device may produce a record. At 30mph, 100ms is
// about 1.3m of travel -- far finer than any GPS fix resolves -- so this
// costs no positioning accuracy while saving flash capacity and BLE airtime.
//
// Gates both the log write and the BLE notification, so the stored log and
// the streamed data never disagree.
class RateLimiter {
public:
    // constexpr, not `static const`: an in-class `static const` is only a
    // declaration, so any ODR-use (binding by const&, as doctest's CHECK
    // macros do) fails to LINK without an out-of-class definition. This
    // exact issue already bit DeviceTable::CAPACITY. constexpr statics are
    // implicitly inline in C++17, so no definition is needed.
    static constexpr uint8_t SLOTS = 32;

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
                // Unsigned subtraction, deliberately. This stays correct
                // across the millis() rollover at ~49 days. Do NOT rewrite
                // as `nowMs < lastMs + minInterval` -- that overflows near
                // the rollover and silently stops rate-limiting.
                if ((uint32_t)(nowMs - entries[i].lastMs) < minInterval) {
                    return false;
                }
                entries[i].lastMs = nowMs;
                return true;
            }
        }

        // Unknown device: take a free slot, else evict least-recently-seen.
        //
        // Eviction resets a device's rate-limit state: an evicted MAC looks
        // brand new on its next sighting and is allowed immediately, bypassing
        // its own interval. This only bites when concurrently-tracked devices
        // exceed SLOTS. Note that only devices which MATCHED a detector ever
        // reach this limiter (ThreatAnalyzer returns early on DET_NONE), so
        // that means 33+ simultaneous surveillance-device matches -- not
        // merely 33 nearby phones. 32 slots is ample for that.
        uint8_t target = 0;
        uint32_t oldest = UINT32_MAX;
        for (uint8_t i = 0; i < SLOTS; i++) {
            if (!entries[i].used) { target = i; break; }
            if (entries[i].lastMs < oldest) { oldest = entries[i].lastMs; target = i; }
        }

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
