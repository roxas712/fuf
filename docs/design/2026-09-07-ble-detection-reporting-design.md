# BLE Detection Reporting — Design

**Date:** 2026-09-07
**Target:** M5Stack FIRE V2.7 variant (`m5stack/flocksquawk_m5fire`)
**Status:** Approved for planning

## Problem

FlockSquawk detects surveillance devices and alerts locally, but nothing leaves
the device. A detection is announced and then lost. The goal is to *report*
discovered cameras — ultimately onto a map — which requires each detection to
carry a location and to survive past the moment it happened.

The FIRE has no GPS and no real-time clock. This design gets location from a
paired iPhone rather than adding hardware, and defers standalone operation.

## Scope

**In scope — firmware only:**

- A BLE GATT peripheral that streams detections to a connected phone
- A durable on-device log of raw sightings in LittleFS
- Passkey pairing using the FIRE's display

**Out of scope — each gets its own spec:**

- **B.** iOS app: BLE receive, CoreLocation stamping, upload
- **C.** your backend: ingest API, map, reporting
- **D.** Onboard GPS module for standalone operation

Downstream context, recorded so format decisions are traceable: sightings
eventually reach your backend, which owns mapping and reporting. The iOS app is
therefore a thin receive-stamp-upload client, not a mapping application.

## Decisions and rationale

### Raw sightings, not aggregated records

Every detection is logged with its RSSI, not condensed to one row per camera.
Signal strength peaks as you drive past a device, so a sequence of RSSI values
with positions places the camera far better than any single fix. Aggregating on
the device would discard exactly the data that makes accuracy possible, and
would prevent repeat drive-bys from improving the estimate.

### Location comes from the phone, correlated by clock offset

The FIRE has no RTC and only knows `millis()` since boot. On connect, the phone
reads the `TimeSync` characteristic and pairs the returned `ms_since_boot` with
its own wall clock. That single pair converts every record in the log to real
time, with no drift accumulating over a drive and nothing for the operator to
note down manually.

### Direct calls, not EventBus

`EventBus::subscribeThreat()` assigns a single handler (`threatHandler = handler`)
rather than appending to a list. Adding subscribers would silently displace the
existing one. New components are therefore invoked directly alongside
`reporter.handleThreatDetection()` in the existing `threatPending` block, which
is how `TelemetryReporter` is already wired. This avoids refactoring shared code
used by all six hardware variants.

### 20-byte records

The default BLE ATT MTU is 23 bytes, leaving 20 usable in a notification. A
20-byte sighting record is exactly one notification: no fragmentation, no
reassembly, no partial-record handling on the phone. If the record ever needs to
grow, that should be a deliberate move to a negotiated larger MTU rather than
accidental fragmentation.

## Architecture

Two new components, each following the existing `TelemetryReporter` shape —
`initialize()` plus `handleThreatDetection(const ThreatEvent&)`:

| Component | Responsibility | Depends on |
|---|---|---|
| `DetectionLog` | Append sightings to rotating LittleFS segments; expose read/export | LittleFS |
| `BleReporter` | NimBLE peripheral; notify connected phone; passkey pairing | NimBLE, M5 display |

Neither knows about the other. Both are driven from one place, in
`flocksquawk_m5fire.ino` around line 1195:

```c
if (threatPending) {
    ThreatEvent threatCopy;
    /* ... existing critical-section copy ... */
    reporter.handleThreatDetection(threatCopy);       // existing
    detectionLog.handleThreatDetection(threatCopy);   // new
    bleReporter.handleThreatDetection(threatCopy);    // new
    /* ... existing alert handling ... */
}
```

### Testable units

Index math and rate limiting are kept as pure units with no `File` and no
NimBLE, so they are testable on the host in the existing doctest suite. They are
deliberately not folded into `DetectionLog`.

| Unit | Pure | Tested |
|---|---|---|
| `SightingRecord` encode/decode | yes | host: round-trip, boundaries, negative RSSI |
| `SegmentIndex` rotation and recovery | yes | host: fresh, restore-by-sequence, rotation target, fill |
| `RateLimiter` per-MAC | yes | host: burst, expiry, many MACs |
| `DeviceTable` dedupe | yes | host: repeat MACs, capacity limit |
| `DetectionLog` | no | on-device |
| `BleReporter` | no | on-device, via LightBlue on iPhone |

## Storage format

> **Revised 2026-09-07 after hardware measurement.** The original design was a
> fixed-slot ring with random-access overwrites. That does not work on this
> hardware and was replaced. See "Why not a ring buffer" below — the measured
> numbers are kept because they explain a decision that otherwise looks odd.

Segmented append-only log in the existing LittleFS partition (`0xc90000`,
3456K, ~328KB used by audio).

```
/seg0.bin .. /seg7.bin   8 rotating segments, 4000 records each
/devices.bin             append-only, one record per unique MAC, capped at 512
```

Each segment carries an 8-byte header — a magic number and a monotonically
increasing **sequence number** — followed by fixed 20-byte records. The
sequence number is what makes the log self-describing: `millis()` resets on
reboot, so timestamps cannot identify the newest segment across a power cycle,
but sequence numbers can. On boot, the segment with the highest sequence is the
current one, and its record count is `(fileSize - 8) / 20`.

**Capacity: ~32,000 records** (8 x 4000). Roughly 600+ camera passes at the
20-50 records per pass observed in testing.

**Rotation.** When the current segment fills, it is closed and the next segment
is opened fresh, deleting whatever was there. The rotation target is any absent
segment, else the lowest-sequence one — robust to gaps, unlike blind
`(current + 1) % count`. This preserves oldest-overwrites, at segment
granularity: the log holds between 28,000 and 32,000 records rather than
exactly 32,000.

**The write handle stays open**, with a flush every 20 records and also on a
2-second timer. That bounds power-cut loss to at most 20 records or 2 seconds
of detections, whichever comes first.

### Sighting record (20 bytes) — unchanged

| Field | Bytes | Notes |
|---|---|---|
| `ms_since_boot` | 4 | uint32, wraps at 49 days |
| `mac` | 6 | |
| `rssi` | 1 | int8 — drives position estimation |
| `channel` | 1 | |
| `radio` | 1 | 0 = wifi, 1 = ble |
| `matchFlags` | 2 | which detectors fired |
| `certainty` | 1 | |
| `alertLevel` | 1 | |
| reserved | 3 | pad to 20; reserved for a GPS-fix index in project D |

SSID and device name stay out, for the original reason: they are constant per
MAC, and one device produced 137 sightings in testing.

**Rate limit per MAC:** at most one record per 100ms per device, gating both the
log write and the BLE notification so the two never disagree. At 30mph that is
~1.3m of travel, far finer than GPS resolves.

### Why not a ring buffer

Measured on the target hardware, writing one 20-byte record:

| Approach | Per record |
|---|---|
| `r+` random overwrite, 400KB file | **1,690 ms** |
| open / append / close | 42 ms |
| **append, handle held open, flush every 20** | **1.1 ms** |
| delete a segment file (rotation) | 12 ms, one-off |

LittleFS is log-structured and copy-on-write. Overwriting 20 bytes in place is
not a thing it does: it allocates a fresh 4KB block, copies it, applies the
change, and cascades CTZ skip-list pointer updates. A 2MB ring additionally
exhausted free space during *overwrites* and failed with `no more free space`.
Filling the partition completely also loses the file entirely, because the final
metadata commit has no block to allocate.

Appending is the filesystem's fast path, and 1.1 ms is ~10x faster than the rate
limiter can generate records, so flash I/O is never the bottleneck.

**The SD card is not an option on this board.** The TF slot fails to enumerate
at 20/10/4/1 MHz on both SPI hosts, with a card verified good on a host machine
and pins matching M5Stack's published v2.7 pinout. Retested after PSRAM was
enabled, in case the missing psram-cache errata flags were implicated: still
dead, 8/8. The same firmware mounts LittleFS and reports 4MB of PSRAM in the
same boot, so the board is otherwise healthy.

### File headers

Each file carries a format version byte, so adding lat/lon fields in project D
does not orphan logs written now.

## BLE interface

One custom GATT service, five characteristics:

| Characteristic | Type | Purpose |
|---|---|---|
| `Sighting` | notify | One 20-byte record per detection, live |
| `DeviceInfo` | notify | MAC → SSID/name, once per new MAC |
| `TimeSync` | read | Current `ms_since_boot` for clock correlation |
| ~~`LogControl`~~ | ~~write~~ | ~~Request backfill from a given index~~ — **removed 2026-09-08**: declared but never implemented, so it accepted writes and did nothing. UUID retired. |
| `Status` | read | Firmware version, format version, records stored |

`Sighting` and `DeviceInfo` are separate because identity arrives once per device
while sightings arrive continuously.

**Advertising interval: ~1 second.** The phone connects once per drive. Every
advertising event costs radio time that the scanner needs. This is the primary
tuning lever if dual-role proves expensive.

**Pairing: passkey, displayed on the FIRE's screen.** The log reveals where the
operator has been and what was found, so an open connection is not acceptable.
The device already has a display, making passkey entry cheap to implement.

### Backfill is dropout resilience, not standalone operation

A backfilled sighting carries a timestamp and no location. The phone can only
place it by looking up where *it* was at that moment, which requires the phone to
have been recording its own track. In this design the log's job is to survive
**brief BLE dropouts** — seconds to minutes, filled from the phone's recent
location history. True standalone operation requires onboard GPS (project D).

## Error handling

Logging is secondary to detection and must never take it down.

| Failure | Behaviour |
|---|---|
| LittleFS will not mount | Logging disabled; detection and alerts continue; reported on screen and serial |
| A segment header is corrupt or unreadable | Treat that segment as absent; it becomes the next rotation target. Its records are lost, the device works |
| `/devices.bin` at capacity | Stop recording names; sightings still log (MAC is in the record). Labels lost, data retained |
| Phone disconnects | Keep logging, resume advertising, no stalling on a dead connection |
| BLE dual-role degrades scanning | Back off advertising interval first; batch notifications second |

## Risks

**Power-cut loss window.** The write handle is held open and flushed every 20
records or 2 seconds. A power cut loses whatever is unflushed. This is a
deliberate trade: flushing per record costs 42ms instead of 1.1ms. Losing the
last second or two of a drive is acceptable; losing 40x throughput is not.

**BLE dual-role contention.** NimBLE currently runs as a central (scanning for
advertisements). Adding a peripheral role shares radio time on a chip already
splitting the antenna with WiFi channel-hopping. NimBLE supports concurrent
roles, but the cost must be measured rather than assumed. If degradation is
severe, the design changes — advertise only when a phone is nearby, or batch
notifications — rather than merely tuning a constant.

## Acceptance criteria

1. **Detection rate does not measurably drop** with the BLE peripheral active,
   measured as sightings-per-minute against a known beacon, before and after.
2. **Rotation does not brick the device.** Fill a segment deliberately; confirm it rotates, deletes the oldest, and keeps logging.
3. Passkey pairing succeeds from an iPhone; an unpaired device cannot subscribe.
4. Clock correlation places a known detection within one second of true time.
5. Host-side tests pass for all four pure units.
6. LittleFS mount failure leaves detection and audio fully functional.

## Known issue inherited from existing code

`DeviceTracker` re-registers a MAC that never left range, so `firstDetection`
(and therefore `shouldAlert`) fires repeatedly for one device — 19 times for a
single stationary MAC in testing. The mechanism is slots aging to `DEPARTED`
after `DEVICE_TIMEOUT_MS`, but why it triggers while the device is continuously
visible is unexplained.

This does **not** affect the log format: sightings record `matchFlags`,
`certainty` and `alertLevel`, none of which depend on `firstDetection`. It is
noted here so it is not mistaken for a defect introduced by this work, and
because a consumer counting alerts would over-count. Fixing it is out of scope.

## Open questions

None blocking. Deferred to their own specs: iOS app structure (B), your backend
ingest schema and map (C), onboard GPS and standalone logging (D).
