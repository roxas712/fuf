#ifndef DETECTION_LOG_H
#define DETECTION_LOG_H

#include <Arduino.h>
#include <LittleFS.h>
#include "EventBus.h"
#include "SightingRecord.h"
#include "SegmentIndex.h"
#include "RateLimiter.h"
#include "DeviceTable.h"

// Durable log of raw sightings, stored as rotating append-only segments.
//
// Shape chosen from measurement on this hardware, not from taste. LittleFS is
// log-structured and copy-on-write, so a fixed-slot ring with random-access
// overwrites cost ~1690ms per 20-byte record and eventually exhausted free
// space. Appending with the handle held open costs ~1.1ms, and deleting a
// whole segment costs ~12ms. So: append, rotate, delete.
//
// Logging is strictly secondary to detection. Every failure path here leaves
// the device detecting and alerting normally -- a detector that cannot log is
// still a detector, one that crashes while logging is not.
class DetectionLog {
public:
    // Overridable so segment rotation and seam recovery can be exercised on
    // hardware in minutes rather than hours. Build the verification firmware
    // with -DFS_RECORDS_PER_SEGMENT=20; production uses the default.
#ifndef FS_RECORDS_PER_SEGMENT
#define FS_RECORDS_PER_SEGMENT 4000
#endif
    static constexpr uint8_t  SEGMENT_COUNT       = 8;
    static constexpr uint32_t RECORDS_PER_SEGMENT = FS_RECORDS_PER_SEGMENT;  // ~32k total
    static constexpr uint32_t RATE_LIMIT_MS       = 100;
    static constexpr size_t   DEVICE_REC_SIZE     = 48;

    // magic(4) + version(1) + reserved(3) + sequence(4)
    static constexpr size_t   HEADER_SIZE   = 12;
    static constexpr uint32_t SEGMENT_MAGIC = 0x534B4C46;   // "FLKS"

    // Flush every 20 records OR every 2s, whichever comes first. Flushing per
    // record would cost 42ms instead of 1.1ms; this bounds power-cut loss to
    // ~20 records or ~2 seconds while keeping the fast path fast.
    static constexpr uint32_t FLUSH_EVERY       = 20;
    // Tolerates a transient failure without losing the log; a genuinely broken
    // filesystem trips it within a couple of seconds at typical detection rates.
    static constexpr uint8_t  WRITE_FAILURES_BEFORE_DISABLE = 5;
    static constexpr uint32_t FLUSH_INTERVAL_MS = 2000;

    static constexpr const char* DEVICES_PATH = "/devices.bin";

    bool initialize() {
        ready = false;
        limiter.initialize(RATE_LIMIT_MS);
        devices.initialize();
        index.initialize(SEGMENT_COUNT, RECORDS_PER_SEGMENT);

        // Scan what is on disk and let SegmentIndex decide which is current.
        SegmentState states[SEGMENT_COUNT];
        for (uint8_t i = 0; i < SEGMENT_COUNT; i++) {
            uint32_t seq = 0, recs = 0;
            states[i].present  = readSegmentHeader(i, seq, recs);
            states[i].sequence = seq;
            states[i].records  = recs;
        }
        index.restore(states, SEGMENT_COUNT);

        // A first boot has no segments at all; create one.
        if (!index.currentExists()) {
            uint8_t target = index.rotate();
            if (!createSegment(target, index.currentSequence())) {
                Serial.println("[Log] Cannot create segment; logging disabled");
                return false;
            }
        }

        if (!openCurrentForAppend()) {
            Serial.println("[Log] Cannot open segment for append; logging disabled");
            return false;
        }

        lastFlushMs = millis();
        sinceFlush  = 0;
        ready       = true;
        Serial.printf("[Log] Ready: seg %u seq %lu, %lu/%lu in segment, %lu total\n",
                      (unsigned)index.currentSegment(),
                      (unsigned long)index.currentSequence(),
                      (unsigned long)index.recordsInCurrent(),
                      (unsigned long)RECORDS_PER_SEGMENT,
                      (unsigned long)index.totalRecords());
        return true;
    }

    // Mirrors TelemetryReporter's entry point.
    void handleThreatDetection(const ThreatEvent& threat) {
        if (!ready) return;

        uint32_t now = millis();
        if (!limiter.allow(threat.mac, now)) return;

        if (index.needsRotation() && !rotateSegment()) return;

        // observe() marks the MAC recorded in memory before it is persisted.
        // If the write fails the entry must come back out, or observe() reports
        // it as already-recorded for the rest of the run and the identifier is
        // never written at all.
        if (devices.observe(threat.mac) && !appendDevice(threat)) {
            devices.forgetLast();
        }

        SightingRecord r{};
        r.msSinceBoot = now;
        memcpy(r.mac, threat.mac, 6);
        r.rssi       = threat.rssi;
        r.channel    = threat.channel;
        r.radio      = radioTypeFromName(threat.radioType);
        r.matchFlags = threat.matchFlags;
        r.certainty  = threat.certainty;
        r.alertLevel = (uint8_t)threat.alertLevel;

        uint8_t raw[SIGHTING_RECORD_SIZE];
        encodeSighting(r, raw);
        if (current && current.write(raw, SIGHTING_RECORD_SIZE) == SIGHTING_RECORD_SIZE) {
            index.recordAppended();
            consecutiveWriteFailures = 0;
            sinceFlush++;
            if (sinceFlush >= FLUSH_EVERY) flushNow(now);
            return;
        }

        // The record count stays correct either way -- recordAppended() is only
        // reached on success -- but silently dropping every record leaves
        // isReady() true and the Status characteristic reporting a total that
        // never moves. Treat a sustained failure the way rotation failure is
        // treated: say so once, and stop claiming to log.
        if (++consecutiveWriteFailures >= WRITE_FAILURES_BEFORE_DISABLE) {
            Serial.printf("[Log] %u consecutive write failures; logging disabled\n",
                          (unsigned)consecutiveWriteFailures);
            ready = false;
        }
    }

    // Call from loop(). Bounds power-cut loss by time as well as by count, so
    // a slow trickle of detections is not left unflushed indefinitely.
    void tick() {
        if (!ready || sinceFlush == 0) return;
        uint32_t now = millis();
        if ((uint32_t)(now - lastFlushMs) >= FLUSH_INTERVAL_MS) flushNow(now);
    }

    bool     isReady()  const { return ready; }

    /// Distinct MACs seen since boot. Shown on the home screen, where "how many
    /// cameras" is a more useful number than how many sightings they produced.
    uint16_t uniqueDevices() const { return devices.size(); }
    uint32_t stored()   const { return index.totalRecords(); }
    uint32_t capacity() const { return SEGMENT_COUNT * RECORDS_PER_SEGMENT; }

    // Read one record by age; age 0 is the oldest retained. Walks segments in
    // sequence order, so it is O(segments) not O(records).
    bool readByAge(uint32_t age, uint8_t* out) {
        if (!ready || age >= index.totalRecords()) return false;

        // Visit present segments oldest-first by sequence.
        uint8_t  order[SEGMENT_COUNT];
        uint8_t  n = 0;
        for (uint8_t i = 0; i < SEGMENT_COUNT; i++) {
            uint32_t seq = 0, recs = 0;
            if (readSegmentHeader(i, seq, recs) && recs > 0) order[n++] = i;
        }
        for (uint8_t a = 0; a + 1 < n; a++) {
            for (uint8_t b = 0; b + 1 < n - a; b++) {
                uint32_t sa = 0, sb = 0, ra = 0, rb = 0;
                readSegmentHeader(order[b], sa, ra);
                readSegmentHeader(order[b + 1], sb, rb);
                if (sa > sb) { uint8_t t = order[b]; order[b] = order[b + 1]; order[b + 1] = t; }
            }
        }

        uint32_t seen = 0;
        for (uint8_t k = 0; k < n; k++) {
            uint32_t seq = 0, recs = 0;
            readSegmentHeader(order[k], seq, recs);
            if (age < seen + recs) {
                return readRecord(order[k], age - seen, out);
            }
            seen += recs;
        }
        return false;
    }

private:

    static void segmentPath(uint8_t idx, char* out, size_t n) {
#ifdef FS_FORCE_LOG_FAIL
        // Acceptance-criterion 6: points segments at a directory LittleFS does
        // not have, so createSegment() fails deterministically. A genuinely
        // full filesystem does not reach this branch -- rotation truncates an
        // existing segment and reuses its blocks, and a fresh segment is only
        // a 12-byte header -- so the failure has to be injected to be tested.
        snprintf(out, n, "/nodir/seg%u.bin", (unsigned)idx);
#else
        snprintf(out, n, "/seg%u.bin", (unsigned)idx);
#endif
    }

    // Returns true when the segment exists and its header parses. A segment
    // whose header will not parse is reported absent, which makes it the next
    // rotation target rather than a source of garbage records.
    bool readSegmentHeader(uint8_t idx, uint32_t& seqOut, uint32_t& recordsOut) {
        char path[24];
        segmentPath(idx, path, sizeof(path));
        if (!LittleFS.exists(path)) return false;
        File f = LittleFS.open(path, FILE_READ);
        if (!f) return false;
        if (f.size() < HEADER_SIZE) { f.close(); return false; }
        uint8_t h[HEADER_SIZE];
        if (f.read(h, HEADER_SIZE) != HEADER_SIZE) { f.close(); return false; }
        uint32_t magic = (uint32_t)h[0] | ((uint32_t)h[1] << 8)
                       | ((uint32_t)h[2] << 16) | ((uint32_t)h[3] << 24);
        if (magic != SEGMENT_MAGIC) { f.close(); return false; }
        seqOut = (uint32_t)h[8] | ((uint32_t)h[9] << 8)
               | ((uint32_t)h[10] << 16) | ((uint32_t)h[11] << 24);
        recordsOut = (uint32_t)((f.size() - HEADER_SIZE) / SIGHTING_RECORD_SIZE);
        f.close();
        return true;
    }

    bool createSegment(uint8_t idx, uint32_t sequence) {
        char path[24];
        segmentPath(idx, path, sizeof(path));
        LittleFS.remove(path);                 // rotation: discard the old data
        File f = LittleFS.open(path, FILE_WRITE);
        if (!f) return false;
        uint8_t h[HEADER_SIZE];
        memset(h, 0, sizeof(h));
        h[0] = (uint8_t)( SEGMENT_MAGIC        & 0xFF);
        h[1] = (uint8_t)((SEGMENT_MAGIC >> 8)  & 0xFF);
        h[2] = (uint8_t)((SEGMENT_MAGIC >> 16) & 0xFF);
        h[3] = (uint8_t)((SEGMENT_MAGIC >> 24) & 0xFF);
        h[4] = SIGHTING_FORMAT_VERSION;
        h[8]  = (uint8_t)( sequence        & 0xFF);
        h[9]  = (uint8_t)((sequence >> 8)  & 0xFF);
        h[10] = (uint8_t)((sequence >> 16) & 0xFF);
        h[11] = (uint8_t)((sequence >> 24) & 0xFF);
        bool ok = (f.write(h, HEADER_SIZE) == HEADER_SIZE);
        f.close();
        return ok;
    }

    bool openCurrentForAppend() {
        closeCurrent();
        char path[24];
        segmentPath(index.currentSegment(), path, sizeof(path));
        current = LittleFS.open(path, FILE_APPEND);
        return (bool)current;
    }

    void closeCurrent() {
        if (current) { current.flush(); current.close(); }
    }

    bool rotateSegment() {
        closeCurrent();
        uint8_t target = index.rotate();
        if (!createSegment(target, index.currentSequence())) {
            Serial.println("[Log] Rotation failed; logging stops");
            ready = false;
            return false;
        }
        if (!openCurrentForAppend()) {
            Serial.println("[Log] Reopen after rotation failed; logging stops");
            ready = false;
            return false;
        }
        sinceFlush = 0;
        Serial.printf("[Log] Rotated to seg %u seq %lu\n",
                      (unsigned)target, (unsigned long)index.currentSequence());
        return true;
    }

    void flushNow(uint32_t now) {
        if (current) current.flush();
        sinceFlush  = 0;
        lastFlushMs = now;
    }

    bool readRecord(uint8_t segIdx, uint32_t offset, uint8_t* out) {
        char path[24];
        segmentPath(segIdx, path, sizeof(path));
        File f = LittleFS.open(path, FILE_READ);
        if (!f) return false;
        if (!f.seek(HEADER_SIZE + offset * SIGHTING_RECORD_SIZE)) { f.close(); return false; }
        size_t got = f.read(out, SIGHTING_RECORD_SIZE);
        f.close();
        return got == SIGHTING_RECORD_SIZE;
    }

    // Returns false when the identifier did not reach flash, so the caller can
    // put the MAC back and retry on its next sighting.
    bool appendDevice(const ThreatEvent& threat) {
        File f = LittleFS.open(DEVICES_PATH, FILE_APPEND);
        if (!f) return false;
        uint8_t rec[DEVICE_REC_SIZE];
        memset(rec, 0, sizeof(rec));
        memcpy(rec, threat.mac, 6);
        strncpy((char*)(rec + 6), threat.identifier, 39);
        rec[46] = radioTypeFromName(threat.radioType);
        bool ok = (f.write(rec, sizeof(rec)) == sizeof(rec));
        f.close();
        return ok;
    }

    uint8_t      consecutiveWriteFailures = 0;
    SegmentIndex index;
    RateLimiter  limiter;
    DeviceTable  devices;
    File         current;
    uint32_t     sinceFlush  = 0;
    uint32_t     lastFlushMs = 0;
    bool         ready       = false;
};

#endif // DETECTION_LOG_H
