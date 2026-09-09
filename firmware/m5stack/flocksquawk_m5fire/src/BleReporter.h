#ifndef BLE_REPORTER_H
#define BLE_REPORTER_H

#include <Arduino.h>
#include <M5Unified.h>
#include <NimBLEDevice.h>
#include <esp_random.h>
#include <functional>
#include "EventBus.h"
#include "SightingRecord.h"
#include "DeviceTable.h"

// GATT peripheral streaming sightings to a paired phone.
//
// NimBLE already runs as a central here (the BLE scanner). Adding the
// peripheral role shares radio time on a chip that is also hopping WiFi
// channels, so advertising is deliberately slow: the phone connects once per
// drive, and every advertising event steals time from the scanner.
#define FS_SERVICE_UUID     "6f1d0001-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_SIGHTING    "6f1d0002-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_DEVICEINFO  "6f1d0003-b5a3-f393-e0a9-e50e24dcca9e"
#define FS_CHAR_TIMESYNC    "6f1d0004-b5a3-f393-e0a9-e50e24dcca9e"
// 6f1d0005 was LogControl (backfill request). It was declared but never had an
// onWrite handler, so it accepted writes and did nothing -- the service
// advertised a capability the firmware did not have. Removed rather than left
// as a trap for a client that discovers it. The UUID stays retired: if backfill
// is implemented later, give it a new one so an old client cannot bind to a
// characteristic that means something different now.
#define FS_CHAR_STATUS      "6f1d0006-b5a3-f393-e0a9-e50e24dcca9e"
// 0007, not 0005: that UUID belonged to LogControl and is retired.
#define FS_CHAR_SETTINGS    "6f1d0007-b5a3-f393-e0a9-e50e24dcca9e"

/// Device settings, as carried over BLE.
///
///     [0] format version
///     [1] volume      0..100
///     [2] brightness  0..255
///     [3] flags       bit0 heartbeat, bit1 battery saver
///     [4] accent index
///     [5..7] reserved
struct DeviceSettings {
    uint8_t volume       = 40;
    uint8_t brightness   = 160;
    bool    heartbeat    = true;
    bool    batterySaver = false;
    uint8_t accentIndex  = 0;

    static constexpr size_t WIRE_SIZE = 8;
    static constexpr uint8_t WIRE_VERSION = 1;

    void encode(uint8_t* out) const {
        memset(out, 0, WIRE_SIZE);
        out[0] = WIRE_VERSION;
        out[1] = volume;
        out[2] = brightness;
        out[3] = (heartbeat ? 0x01 : 0) | (batterySaver ? 0x02 : 0);
        out[4] = accentIndex;
    }

    /// Rejects anything that is not exactly the expected size and version, so a
    /// future format cannot be half-applied by an older build.
    static bool decode(const uint8_t* raw, size_t len, DeviceSettings& out) {
        if (len != WIRE_SIZE || raw[0] != WIRE_VERSION) return false;
        if (raw[1] > 100) return false;                 // volume is a percentage
        out.volume       = raw[1];
        out.brightness   = raw[2];
        out.heartbeat    = (raw[3] & 0x01) != 0;
        out.batterySaver = (raw[3] & 0x02) != 0;
        out.accentIndex  = raw[4];
        return true;
    }
};

class BleReporter : public NimBLEServerCallbacks,
                    public NimBLECharacteristicCallbacks {
public:
    // ~1 second advertising interval, in 0.625ms units. This is the first
    // lever to pull if the peripheral role costs detection rate.
    static constexpr uint16_t ADV_INTERVAL_MIN = 0x0640;
    static constexpr uint16_t ADV_INTERVAL_MAX = 0x0680;
    static constexpr const char* DEVICE_NAME   = "FlockSquawk";

    void initialize() {
        // NimBLEDevice::init() is already called by the scanner; calling it
        // again is harmless. Security config must precede advertising.
        // A fresh six-digit passkey each boot, from the hardware RNG.
        //
        // It used to be the constant 123456. This is a public repo, so that
        // passkey was published -- anyone could pair, which defeats the point
        // of MITM-protected pairing entirely. The whole value of display-only
        // pairing is that the person pairing must be looking at the screen.
        //
        // Rotating per boot costs nothing: bonds are stored in NVS and survive
        // restarts, so an already-paired phone is unaffected. The new passkey
        // only applies to pairings made after this boot.
        passkey = 100000 + (esp_random() % 900000);

        NimBLEDevice::setSecurityAuth(true, true, true);        // bond, MITM, SC
        NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY); // we show a passkey
        NimBLEDevice::setSecurityPasskey(passkey);

        server = NimBLEDevice::createServer();
        server->setCallbacks(this);

        NimBLEService* svc = server->createService(FS_SERVICE_UUID);

        // Three separate bits, and all three matter (NimBLELocalValueAttribute.h:36-43):
        //   READ        0x0002  grants the property at all
        //   READ_ENC    0x0200  requires an *encrypted* link
        //   READ_AUTHEN 0x0400  requires an *authenticated* link (MITM)
        //
        // READ_ENC alone is not enough. Just Works pairing produces an
        // encrypted-but-unauthenticated link, which satisfies READ_ENC without
        // anyone ever seeing a passkey -- observed on hardware: iOS showed a
        // bare "Pair / Cancel" dialog, pairing completed, and onPassKeyDisplay
        // never fired. READ_AUTHEN is what forces passkey entry and makes the
        // displayed code load-bearing rather than decorative.
        const uint32_t READ_SECURE  = NIMBLE_PROPERTY::READ  | NIMBLE_PROPERTY::READ_ENC
                                    | NIMBLE_PROPERTY::READ_AUTHEN;
        // No WRITE_SECURE: the service is read/notify only now that LogControl
        // is gone. Anything writable added later needs WRITE | WRITE_ENC |
        // WRITE_AUTHEN -- WRITE_ENC alone is satisfied by Just Works pairing.

        sighting   = svc->createCharacteristic(FS_CHAR_SIGHTING,
                         NIMBLE_PROPERTY::NOTIFY | READ_SECURE);
        deviceInfo = svc->createCharacteristic(FS_CHAR_DEVICEINFO,
                         NIMBLE_PROPERTY::NOTIFY | READ_SECURE);
        timeSync   = svc->createCharacteristic(FS_CHAR_TIMESYNC,   READ_SECURE);
        status     = svc->createCharacteristic(FS_CHAR_STATUS,     READ_SECURE);
        // The only writable characteristic in the service. WRITE_AUTHEN, not
        // merely WRITE_ENC: encryption alone is satisfied by Just Works
        // pairing, which would let an unauthenticated peer change the
        // device's settings.
        settings   = svc->createCharacteristic(FS_CHAR_SETTINGS,
                         READ_SECURE | NIMBLE_PROPERTY::WRITE
                                     | NIMBLE_PROPERTY::WRITE_ENC
                                     | NIMBLE_PROPERTY::WRITE_AUTHEN);
        settings->setCallbacks(this);

        // Only the notify characteristics need subscribe visibility.
        sighting->setCallbacks(this);
        deviceInfo->setCallbacks(this);
        status->setCallbacks(this);
        timeSync->setCallbacks(this);

        svc->start();

        NimBLEDevice::setDeviceName(DEVICE_NAME);

        NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
        adv->addServiceUUID(FS_SERVICE_UUID);
        adv->setMinInterval(ADV_INTERVAL_MIN);
        adv->setMaxInterval(ADV_INTERVAL_MAX);

        // The name goes in the scan response, not the main packet. A 128-bit
        // service UUID costs 18 of the 31 advertising bytes and flags cost 3,
        // leaving no room for a useful name. The scan response is a separate
        // 31 bytes, and scanners show names from it.
        NimBLEAdvertisementData scanData;
        scanData.setName(DEVICE_NAME);
        adv->setScanResponseData(scanData);

        adv->start();

        refreshTimeSync();
        Serial.printf("[BLE] Advertising as \"%s\", address %s\n",
                      DEVICE_NAME,
                      NimBLEDevice::getAddress().toString().c_str());
        // Logged at boot as well as during pairing. Reading it needs physical
        // USB access, which already implies being able to read the screen it
        // is displayed on, so this exposes nothing new -- and it makes the
        // per-boot rotation verifiable without triggering a pairing.
        Serial.printf("[BLE] Pairing passkey this boot: %06u\n",
                      (unsigned)passkey);
    }

    // Mirrors TelemetryReporter's entry point: one notification per threat
    // event, with no rate limit of its own. DetectionLog applies its own
    // 100ms-per-MAC limit internally, so the two are NOT guaranteed to agree
    // -- a burst faster than 10/s for one MAC streams more than it logs.
    // Measured ~2 notifications/sec per camera at close range.
    void handleThreatDetection(const ThreatEvent& threat) {
        if (!connected || sighting == nullptr) return;
        if (!notifyAllowed("sighting")) return;

        SightingRecord r{};
        r.msSinceBoot = millis();
        memcpy(r.mac, threat.mac, 6);
        r.rssi       = threat.rssi;
        r.channel    = threat.channel;
        r.radio      = radioTypeFromName(threat.radioType);
        r.matchFlags = threat.matchFlags;
        r.certainty  = threat.certainty;
        r.alertLevel = (uint8_t)threat.alertLevel;

        // Identity before the sighting that needs it, so the phone can label
        // the MAC rather than briefly showing a bare address. Once per MAC per
        // connection: a phone that connects mid-session has no labels, and
        // announced is cleared on connect so it gets them as devices reappear.
        // Nothing called this before -- publishDeviceInfo() existed and was
        // correct but was dead code, so the app only ever received MACs.
        // If the label does not go out -- the phone has not subscribed to
        // DeviceInfo yet, or dropped it -- the MAC must not stay marked, or it
        // is never labelled again for the rest of the connection. Observed on
        // hardware: a transient unsubscribe lost the label permanently.
        if (threat.identifier[0] != '\0' && announced.observe(threat.mac)
            && !publishDeviceInfo(threat)) {
            announced.forgetLast();
        }

        uint8_t raw[SIGHTING_RECORD_SIZE];
        encodeSighting(r, raw);
        sighting->setValue(raw, SIGHTING_RECORD_SIZE);
        // notify() returns false when nobody is subscribed. Without this the
        // failure mode "phone never subscribed" and "device never sent" look
        // identical from the serial console.
        bool sent = sighting->notify();
        if (sent != lastNotifyOk || !notifyEverLogged) {
            lastNotifyOk    = sent;
            notifyEverLogged = true;
            Serial.printf("[BLE] Sighting notify %s\n",
                          sent ? "delivered" : "DROPPED (no subscriber)");
        }
    }

    // Sent once per newly seen MAC so the phone can label it. Kept separate
    // from Sighting because identity arrives once while sightings stream.
    // Returns whether the label actually went out, so the caller can leave the
    // MAC unannounced and retry. notify() returns true even with no subscriber
    // -- observed on hardware -- so the subscription flag is the authority.
    bool publishDeviceInfo(const ThreatEvent& threat) {
        if (!connected || deviceInfo == nullptr) return false;
        if (!notifyAllowed("device info")) return false;
        if (!deviceInfoSubscribed) return false;
        uint8_t buf[46];
        memset(buf, 0, sizeof(buf));
        memcpy(buf, threat.mac, 6);
        strncpy((char*)(buf + 6), threat.identifier, 39);
        deviceInfo->setValue(buf, sizeof(buf));
        deviceInfo->notify();
        Serial.printf("[BLE] DeviceInfo sent: %02x:%02x:%02x:%02x:%02x:%02x \"%s\"\n",
                      threat.mac[0], threat.mac[1], threat.mac[2],
                      threat.mac[3], threat.mac[4], threat.mac[5],
                      threat.identifier);
        return true;
    }

    // The phone pairs this with its own wall clock, which is what lets every
    // logged record be placed in real time without an RTC on the device.
    void refreshTimeSync() {
        if (timeSync == nullptr) return;
        uint32_t now = millis();
        uint8_t buf[4] = {
            (uint8_t)( now        & 0xFF), (uint8_t)((now >> 8)  & 0xFF),
            (uint8_t)((now >> 16) & 0xFF), (uint8_t)((now >> 24) & 0xFF)
        };
        timeSync->setValue(buf, sizeof(buf));
    }

    // Throttled deliberately. NimBLEAttValue::setValue() zeroes m_attr_len
    // before appending the new bytes, with no lock, and reads are served from
    // the BLE host task while this runs on the loop task. A read landing in
    // that window returns zero bytes -- the characteristic reads as empty.
    // Calling this per detection (~2/sec) made Status reliably unreadable;
    // observed on hardware as "no value" in a GATT browser. Once every few
    // seconds shrinks the window to microseconds, and a fill-level gauge does
    // not need sub-second freshness. Do not remove the throttle, and do not add
    // a frequently-updated readable characteristic without reading this first.
    void setStatus(uint32_t stored, uint32_t capacity) {
        if (status == nullptr) return;
        if (stored == lastStored && capacity == lastCapacity) return;
        uint32_t now = millis();
        if (lastStored != UINT32_MAX &&
            (uint32_t)(now - lastStatusWriteMs) < STATUS_MIN_INTERVAL_MS) return;
        lastStatusWriteMs = now;
        lastStored   = stored;
        lastCapacity = capacity;
        uint8_t buf[10];
        memset(buf, 0, sizeof(buf));
        buf[0] = SIGHTING_FORMAT_VERSION;
        buf[1] = 1;  // revision of this GATT interface
        memcpy(buf + 2, &stored,   4);
        memcpy(buf + 6, &capacity, 4);
        status->setValue(buf, sizeof(buf));
        Serial.printf("[BLE] Status set: stored=%lu capacity=%lu\n",
                      (unsigned long)stored, (unsigned long)capacity);
    }

    bool isConnected() const { return connected; }

    /// Publishes the device's current settings so a connecting phone reads real
    /// values rather than showing its own defaults and then overwriting them.
    void setSettings(const DeviceSettings& s) {
        if (settings == nullptr) return;
        uint8_t buf[DeviceSettings::WIRE_SIZE];
        s.encode(buf);
        settings->setValue(buf, sizeof(buf));
    }

    /// Registered by the sketch. Invoked from tick(), on the loop task.
    void onSettingsChanged(std::function<void(const DeviceSettings&)> fn) {
        settingsHandler = std::move(fn);
    }

    // Call from loop(). All display work happens here, on the Arduino task,
    // because the BLE callbacks run on a stack that cannot afford M5GFX.
    // Returns true on the transition where the pairing screen comes down, so
    // the caller can repaint whatever it owns underneath.
    bool tick() {
        if (settingsPending) {
            settingsPending = false;
            if (settingsHandler) settingsHandler(pendingSettings);
        }
        if (showPasskeyPending) {
            showPasskeyPending = false;
            clearPasskeyPending = false;
            passkeyOnScreen = true;
            passkeyShownAt  = millis();
            drawPasskey();
        } else if (clearPasskeyPending ||
                   (passkeyOnScreen && millis() - passkeyShownAt > PASSKEY_SCREEN_MS)) {
            // The timeout matters because onConnect fires for every connection,
            // including a bonded reconnect that needs no code. Without it the
            // scanner UI would stay hidden for the whole session.
            clearPasskeyPending = false;
            if (passkeyOnScreen) {
                passkeyOnScreen = false;
                return true;
            }
        }
        return false;
    }

    // True while the pairing code owns the screen. The home UI redraws every
    // 100ms and would otherwise paint over the code before it could be read.
    bool isShowingPasskey() const { return passkeyOnScreen; }

    // --- NimBLEServerCallbacks ---
    void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
        connected = true;
        linkAuthenticated = false;   // fail closed until encryption is proven
        announced.initialize();      // a new phone knows no labels yet
        deviceInfoSubscribed = false;
        refreshTimeSync();
        Serial.println("[BLE] Phone connected");
        // Request the passkey screen; do NOT draw it here. This callback runs
        // on the NimBLE host task, whose stack is far too small for M5GFX --
        // drawing from it overflowed the stack and panicked with a double
        // exception (0xa5a5a5a5 in the backtrace is the FreeRTOS stack fill),
        // and touching SPI concurrently with the loop task scrambled the
        // display. Observed on hardware. loop() calls tick() and draws there,
        // the same deferral the sketch already uses for threat events.
        showPasskeyPending = true;
    }

    void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
        connected = false;
        linkAuthenticated = false;
        // The reason code names the failure when pairing does not complete.
        // 0x0205/517 = authentication failure, 0x055x = SM error from the peer.
        Serial.printf("[BLE] Phone disconnected (reason 0x%04x), bonds=%d; "
                      "re-advertising\n", reason, NimBLEDevice::getNumBonds());
        clearPasskeyPending = true;
        NimBLEDevice::startAdvertising();
    }

    // Not called while a static passkey is configured -- NimBLE resolves the
    // code from setSecurityPasskey() without asking. Kept because it is the
    // correct hook if the passkey ever becomes dynamic per pairing, and
    // because returning the wrong value here would be a silent trap.
    /// Runs on the BLE host task. It stores and returns -- nothing here may
    /// touch the display, the speaker or LittleFS. Applying a brightness change
    /// from this thread drives SPI concurrently with the loop task, which is
    /// what crashed the device when the pairing passkey was drawn here. loop()
    /// picks it up through tick().
    void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo& info) override {
        if (chr != settings) return;
        if (!info.isAuthenticated()) {
            Serial.println("[BLE] Settings write refused: link not authenticated");
            return;
        }
        auto value = chr->getValue();
        DeviceSettings incoming;
        if (!DeviceSettings::decode(value.data(), value.size(), incoming)) {
            Serial.printf("[BLE] Settings write rejected: %u bytes\n",
                          (unsigned)value.size());
            return;
        }
        pendingSettings = incoming;
        settingsPending = true;
        Serial.printf("[BLE] Settings write queued: vol=%u bright=%u hb=%d save=%d\n",
                      incoming.volume, incoming.brightness,
                      incoming.heartbeat, incoming.batterySaver);
    }

    void onRead(NimBLECharacteristic* chr, NimBLEConnInfo& info) override {
        Serial.printf("[BLE] Read %s (%u bytes), authenticated=%d\n",
                      chr->getUUID().toString().c_str(),
                      (unsigned)chr->getValue().size(), info.isAuthenticated());
    }

    // Runs on the BLE host task -- Serial only, never M5.Display.
    void onSubscribe(NimBLECharacteristic* chr, NimBLEConnInfo&,
                     uint16_t subValue) override {
        if (chr == deviceInfo) deviceInfoSubscribed = (subValue & 1) != 0;

        const char* what = subValue == 0 ? "unsubscribed"
                         : subValue == 1 ? "subscribed (notify)"
                         : subValue == 2 ? "subscribed (indicate)"
                                         : "subscribed (notify+indicate)";
        Serial.printf("[BLE] %s -> %s\n",
                      chr->getUUID().toString().c_str(), what);
    }

    uint32_t onPassKeyDisplay() override {
        showPasskeyPending = true;
        return passkey;
    }

    void onAuthenticationComplete(NimBLEConnInfo& info) override {
        // authenticated == MITM protection, i.e. the passkey was actually
        // used. It stays true for a restored bond, so a false here means the
        // link fell back to Just Works and the passkey bought nothing --
        // which is exactly the bug READ_AUTHEN was added to close.
        Serial.printf("[BLE] Pairing complete: bonded=%d encrypted=%d "
                      "authenticated=%d keysize=%u\n",
                      info.isBonded(), info.isEncrypted(),
                      info.isAuthenticated(), (unsigned)info.getSecKeySize());
        linkAuthenticated = info.isAuthenticated();
        if (!linkAuthenticated) {
            Serial.println("[BLE] WARNING: link is NOT MITM-protected; "
                           "notifications withheld");
        }
        clearPasskeyPending = true;   // cleared by tick(), not here
    }

private:
    // A client can subscribe before pairing: the CCCD carries no encryption
    // requirement of its own, so NimBLE accepts the write and only then calls
    // startSecurity(). Confirmed in the GATT dump -- the characteristic shows
    // [READ|NOTIFY|READ_ENC|READ_AUTHEN] but its descriptor has min_key_size 0.
    // A peer that subscribes and then declines to pair would otherwise be sent
    // sighting records in the clear, so being subscribed is not permission to
    // receive; being authenticated is.
    bool notifyAllowed(const char* what) {
        if (linkAuthenticated) return true;
        if (!withheldLogged) {
            withheldLogged = true;
            Serial.printf("[BLE] Withholding %s: link not authenticated\n", what);
        }
        return false;
    }

    void drawPasskey() {
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setCursor(0, 40);
        M5.Display.setTextSize(3);
        M5.Display.println("BLE PAIRING");
        M5.Display.setTextSize(4);
        M5.Display.printf("\n %06u\n", (unsigned)passkey);
        Serial.printf("[BLE] Passkey: %06u\n", (unsigned)passkey);
    }

    // Written from BLE callbacks, read and cleared by tick() on the loop task.
    volatile bool         showPasskeyPending  = false;
    volatile bool         clearPasskeyPending = false;
    bool                  passkeyOnScreen     = false;  // loop task only
    bool                  lastNotifyOk        = true;   // edge-log notify failures
    bool                  notifyEverLogged    = false;  // force the first result to print
    bool                  withheldLogged      = false;
    volatile bool         linkAuthenticated   = false;
    static const uint32_t STATUS_MIN_INTERVAL_MS = 5000;
    uint32_t              lastStatusWriteMs = 0;
    uint32_t              lastStored   = UINT32_MAX;   // force the first write
    uint32_t              lastCapacity = UINT32_MAX;
    volatile bool         deviceInfoSubscribed = false;
    DeviceTable           announced;            // labels sent this connection
    uint32_t              passkeyShownAt      = 0;
    static const uint32_t PASSKEY_SCREEN_MS   = 45000;
    uint32_t              passkey    = 0;   // set at initialize()
    NimBLEServer*         server     = nullptr;
    NimBLECharacteristic* sighting   = nullptr;
    NimBLECharacteristic* deviceInfo = nullptr;
    NimBLECharacteristic* timeSync   = nullptr;
    NimBLECharacteristic* status     = nullptr;
    NimBLECharacteristic* settings   = nullptr;
    std::function<void(const DeviceSettings&)> settingsHandler;
    volatile bool  settingsPending = false;
    DeviceSettings pendingSettings;
    bool                  connected  = false;
};

#endif // BLE_REPORTER_H
