#ifndef DEVICE_TABLE_H
#define DEVICE_TABLE_H

#include <Arduino.h>

// Remembers which MACs have already had their identity persisted, so a
// device's name is written once rather than duplicated across every sighting
// of it. 512 entries x 6 bytes = 3KB of RAM, which the FIRE has in abundance.
class DeviceTable {
public:
    static constexpr uint16_t CAPACITY = 512;

    void initialize() { used = 0; }

    // Returns true when this MAC is newly seen AND there was room to record
    // it. At capacity we return false: identity cannot be stored, so the
    // caller must not believe it was. Labels are lost, sighting data is not --
    // the MAC is in every sighting record regardless.
    // Undo the most recent successful observe(). Callers mark a MAC observed
    // before persisting its identifier; if that write fails the entry has to
    // come back out, or observe() reports it as already-recorded for the rest
    // of the run and the identifier is never written at all. Safe to call when
    // nothing was added -- observe() always appends at the end.
    void forgetLast() {
        if (used > 0) used--;
    }

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
    // Only indices [0, used) hold valid data. initialize() deliberately does
    // not clear this array -- `used` alone bounds every reader. Any new reader
    // must respect that bound rather than scanning the whole array.
    uint8_t  macs[CAPACITY][6];
    uint16_t used = 0;
};

#endif // DEVICE_TABLE_H
