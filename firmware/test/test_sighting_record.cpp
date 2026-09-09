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

TEST_CASE("SightingRecord: pins every field to its absolute byte offset") {
    // Round-trip tests cannot catch a bug applied symmetrically to both
    // encode and decode. These absolute offsets are the wire contract an
    // independently-built consumer relies on.
    SightingRecord in{};
    in.msSinceBoot = 0;
    setMAC(in.mac, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66);
    in.rssi       = -73;
    in.channel    = 6;
    in.radio      = RADIO_BLE;
    in.matchFlags = 0;
    in.certainty  = 42;
    in.alertLevel = 2;

    uint8_t raw[SIGHTING_RECORD_SIZE];
    encodeSighting(in, raw);

    CHECK(raw[4]  == 0x11);
    CHECK(raw[5]  == 0x22);
    CHECK(raw[6]  == 0x33);
    CHECK(raw[7]  == 0x44);
    CHECK(raw[8]  == 0x55);
    CHECK(raw[9]  == 0x66);
    CHECK(raw[10] == 0xB7);          // -73 in two's complement
    CHECK(raw[11] == 6);             // channel
    CHECK(raw[12] == RADIO_BLE);     // radio
    CHECK(raw[15] == 42);            // certainty
    CHECK(raw[16] == 2);             // alertLevel
}

TEST_CASE("SightingRecord: decodes a hand-authored buffer") {
    // Authored by hand rather than produced by encodeSighting, so this pins
    // the decode direction independently of the encoder under test.
    uint8_t raw[SIGHTING_RECORD_SIZE] = {
        0x04, 0x03, 0x02, 0x01,               // msSinceBoot = 0x01020304
        0xB4, 0x1E, 0x52, 0x0A, 0x0B, 0x0C,   // mac
        0xB7,                                  // rssi = -73
        0x06,                                  // channel
        0x01,                                  // radio = RADIO_BLE
        0x41, 0x01,                            // matchFlags = 0x0141
        0x64,                                  // certainty = 100
        0x03,                                  // alertLevel = 3
        0x00, 0x00, 0x00                       // reserved
    };

    SightingRecord out{};
    decodeSighting(raw, out);

    CHECK(out.msSinceBoot == 0x01020304);
    CHECK(out.mac[0] == 0xB4);
    CHECK(out.mac[5] == 0x0C);
    CHECK(out.rssi == -73);
    CHECK(out.channel == 6);
    CHECK(out.radio == RADIO_BLE);
    CHECK(out.matchFlags == 0x0141);
    CHECK(out.certainty == 100);
    CHECK(out.alertLevel == 3);
}

TEST_CASE("SightingRecord: radioTypeFromName matches what ThreatAnalyzer emits") {
    // ThreatAnalyzer writes "wifi" / "bluetooth", never "ble". Comparing
    // against "ble" silently tagged every Bluetooth sighting as WiFi.
    CHECK(radioTypeFromName("bluetooth") == RADIO_BLE);
    CHECK(radioTypeFromName("wifi") == RADIO_WIFI);
    CHECK(radioTypeFromName("ble") == RADIO_WIFI);      // the old, wrong string
    CHECK(radioTypeFromName("") == RADIO_WIFI);
}
