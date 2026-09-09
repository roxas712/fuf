#ifndef SEGMENT_INDEX_H
#define SEGMENT_INDEX_H

#include <Arduino.h>

// One segment as found on disk during a boot scan.
struct SegmentState {
    bool     present;
    uint32_t sequence;   // higher is newer; meaningless when !present
    uint32_t records;
};

// Bookkeeping for a segmented append-only log: which segment is current, when
// to rotate, and which segment to sacrifice when rotating.
//
// This replaced a fixed-slot ring buffer. LittleFS is copy-on-write, so
// random-access overwrites cost ~1690ms per 20-byte record on this hardware
// versus ~1.1ms to append. Rotation of whole files is the workable shape.
//
// Sequence numbers rather than timestamps identify the newest segment, because
// millis() resets on reboot and cannot order segments across a power cycle.
class SegmentIndex {
public:
    static constexpr uint8_t MAX_SEGMENTS = 8;

    void initialize(uint8_t segmentCount, uint32_t recordsPerSegment) {
        segCount   = (segmentCount == 0) ? 1
                   : (segmentCount > MAX_SEGMENTS ? MAX_SEGMENTS : segmentCount);
        perSegment = (recordsPerSegment == 0) ? 1 : recordsPerSegment;
        current    = 0;
        inCurrent  = 0;
        nextSeq    = 1;
        total      = 0;
        for (uint8_t i = 0; i < MAX_SEGMENTS; i++) {
            seg[i].present  = false;
            seg[i].sequence = 0;
            seg[i].records  = 0;
        }
    }

    // Adopt the result of a boot scan. The segment with the highest sequence
    // becomes current; if none are present the index stays fresh.
    void restore(const SegmentState* states, uint8_t count) {
        uint8_t n = (count > segCount) ? segCount : count;
        total = 0;
        uint32_t bestSeq = 0;
        bool any = false;
        for (uint8_t i = 0; i < n; i++) {
            seg[i] = states[i];
            if (seg[i].present) {
                total += seg[i].records;
                if (!any || seg[i].sequence > bestSeq) {
                    bestSeq = seg[i].sequence;
                    current = i;
                    any     = true;
                }
            }
        }
        if (!any) {
            current   = 0;
            inCurrent = 0;
            nextSeq   = 1;
        } else {
            inCurrent = seg[current].records;
            nextSeq   = bestSeq + 1;
        }
    }

    uint8_t  currentSegment()    const { return current; }
    uint32_t currentSequence()   const { return seg[current].sequence; }
    bool     currentExists()     const { return seg[current].present; }
    uint32_t recordsInCurrent()  const { return inCurrent; }
    uint32_t totalRecords()      const { return total; }
    uint8_t  segmentCount()      const { return segCount; }
    uint32_t recordsPerSegment() const { return perSegment; }
    uint32_t nextSequence()      const { return nextSeq; }
    bool     needsRotation()     const { return inCurrent >= perSegment; }

    // Advance to a fresh segment and return the index the caller must
    // (re)create on disk. Prefers an absent slot; otherwise sacrifices the
    // lowest sequence, which is the oldest data. Choosing by sequence rather
    // than (current + 1) % count stays correct when a segment is missing or
    // was skipped because its header would not parse.
    uint8_t rotate() {
        uint8_t target = 0;
        bool    found  = false;
        for (uint8_t i = 0; i < segCount; i++) {
            if (!seg[i].present) { target = i; found = true; break; }
        }
        if (!found) {
            uint32_t lowest = UINT32_MAX;
            for (uint8_t i = 0; i < segCount; i++) {
                if (seg[i].sequence < lowest) {
                    lowest = seg[i].sequence;
                    target = i;
                }
            }
            total -= seg[target].records;   // evicted records are gone
        }
        seg[target].present  = true;
        seg[target].sequence = nextSeq;
        seg[target].records  = 0;
        nextSeq++;
        current   = target;
        inCurrent = 0;
        return target;
    }

    void recordAppended() {
        inCurrent++;
        seg[current].records = inCurrent;
        total++;
    }

private:
    SegmentState seg[MAX_SEGMENTS];
    uint8_t  segCount   = 1;
    uint32_t perSegment = 1;
    uint8_t  current    = 0;
    uint32_t inCurrent  = 0;
    uint32_t nextSeq    = 1;
    uint32_t total      = 0;
};

#endif // SEGMENT_INDEX_H
