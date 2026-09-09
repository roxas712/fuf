#ifndef SIGHTING_RECORD_H
#define SIGHTING_RECORD_H

#include <Arduino.h>

// One logged detection. Encoded to exactly 20 bytes, which is also the
// usable payload of a default-MTU (23 byte) BLE notification, so one
// sighting is one packet with no fragmentation.
static const size_t  SIGHTING_RECORD_SIZE   = 20;
// Versioning is deliberately at the file/stream level, not per record: this
// value is written once into the log file header and exposed once per
// connection via the BLE Status characteristic. Storing it in all 20 bytes of
// every record would spend ~100KB of flash re-encoding a per-session constant.
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

// Byte layout (little-endian, explicit -- struct padding is not the contract):
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

// ThreatAnalyzer sets ThreatEvent::radioType to the literal strings "wifi"
// or "bluetooth" (ThreatAnalyzer.h:215 and :274). Consumers previously
// compared against "ble", which never matched -- every Bluetooth sighting was
// silently recorded as RADIO_WIFI. Keep the comparison in one tested place.
inline uint8_t radioTypeFromName(const char* radioType) {
    return (strcmp(radioType, "bluetooth") == 0) ? RADIO_BLE : RADIO_WIFI;
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
