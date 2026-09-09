# Handoff: FlockSquawk firmware — remaining work

**Location:** `~/dev/fuf/firmware` (this
repo, branch `flock-ingest`)
**Hardware:** M5Stack FIRE V2.7, on `/dev/cu.usbserial-XXXXXXXX` when attached

**The path must not contain spaces.** arduino-cli splits build properties on
whitespace before exec, so a space-containing include path is impossible to
pass — backslash-escaping and embedded quoting both fail. This is why the repo
was moved out of `~/Documents/Darkheart io/`. Do not move it back.

An archive of the original standalone clone remains at `~/dev/FlockSquawk`. It
keeps the upstream remote and the full commit history, and exists so the
upstream bug fixes below can be contributed back from a public fork without
dragging along this repo's private infrastructure docs.

Read `firmware/_FLASH-NOTES.md` first. It has the working build and
flash procedure and the several ways flashing fails on this board.

## State

Working and verified on hardware:

- Audio from internal flash (LittleFS), PSRAM enabled, voice alerts play
- WiFi + BLE detection, threat scoring, display alerts, JSON telemetry
- Segmented append-only detection log, survives reboots
- BLE GATT peripheral advertising as `FlockSquawk`, passkey pairing works
- 83 host tests passing (`make test`)

## What is left, in priority order

### 1. ~~Unpaired clients may be able to subscribe~~ — ANSWERED 2026-09-08, and fixed

**They can.** The CCCD does *not* inherit the characteristic's encryption
requirement. The device's own GATT dump shows `6f1d0002` as
`[READ|NOTIFY|READ_ENC|READ_AUTHEN]` while its descriptor registers with
`min_key_size 0`. NimBLE accepts the CCCD write unencrypted and only then calls
`startSecurity()` reactively (`NimBLEServer.cpp`, `BLE_GAP_EVENT_SUBSCRIBE`), so
a peer can subscribe and simply decline to pair.

Permission flags cannot close this. Fixed in `a2a6468` by refusing to *send*:
`BleReporter::notifyAllowed()` gates both notify paths on
`NimBLEConnInfo::isAuthenticated()`. Verified on hardware — a fresh pair reports
`bonded=1 encrypted=1 authenticated=1 keysize=16`, and `Sighting notify
delivered` only follows an authenticated link.

Note for anyone re-testing: `onAuthenticationComplete` fires on
`BLE_GAP_EVENT_ENC_CHANGE` whether encryption **succeeded or failed**, and
NimBLE does not check the status first. A "pairing complete" log line is
therefore not evidence of anything; log `isAuthenticated()` explicitly.

### 2. ~~The BLE passkey is hardcoded~~ — FIXED and flashed 2026-09-08

Now six digits from `esp_random()`, generated per boot. **Flashed and verified
on hardware** across three reboots (212944 / 995017 / 113977 — three distinct
values). The passkey is also logged at boot, so rotation can be checked without
triggering a pairing.

Bonds live in NVS and survive restarts, so an already-paired phone is
unaffected; the new value applies only to pairings made after that boot.

<details><summary>Original issue</summary>

### The BLE passkey was hardcoded to `123456`

`BleReporter::PASSKEY` in `firmware/m5stack/flocksquawk_m5fire/src/BleReporter.h`.
FlockSquawk is a public repo, so the passkey is published — anyone can pair,
which defeats the MITM protection the display-only pairing is supposed to give.

Fixed as described.

</details>

### 3. Dual-role cost — measured 2026-09-08, no degradation found

Adding the BLE peripheral to a stack already scanning as a central shares radio
time with WiFi channel hopping. Measured on hardware with an iPhone Personal
Hotspot named `Flock-A1B2C3`, matched 30-second windows either side of the
connect, skipping 10s after it so pairing and subscribe traffic is excluded:

| Window | Detections | Rate | per-10s |
|---|---|---|---|
| Advertising only (BLE disconnected) | 56 / 30s | 1.87/s | 22, 13, 21 |
| Connected + subscribed + notifying  | 58 / 30s | 1.93/s | 22, 18, 18 |

**+3.6%** (+9.2% over the full pre/post spans). No step change is visible in a
10-second bucket series across the connect point. The change is positive, i.e.
the wrong direction for radio contention, and well inside the run-to-run noise:
bucket standard deviation is ~4 counts on a mean of ~19, roughly 20%.

**Conclusion: connecting and streaming does not measurably cost detection
rate.** `ADV_INTERVAL_MIN`/`MAX` need no tuning on this evidence.

Limits of the test, which matter if you want to revisit it:

- **Strong signal.** RSSI averaged -40dBm. Contention is likeliest to show at
  the margins of range, where a missed frame is not recovered on the next sweep.
- **One target, ~2 detections/sec.** A dense environment with many tracked
  devices was not tested.
- **This compares advertising against connected, not against the peripheral
  being absent.** The device advertises in both windows, so the cost of the
  peripheral existing at all is still unmeasured; that needs a build with
  BleReporter compiled out.
- Short windows (30s matched). Enough to exclude a large regression, not a
  subtle one.

Method note: an iOS Personal Hotspot **sleeps its radio when no client is
joined**, which silently killed several earlier attempts (zero detections for
minutes). Keep a second device joined for the whole run. It also **randomises
its MAC on every power-cycle**, so each restart is a new device to the tracker
and legitimately re-alerts — do not read that as a bug.

### 4. ~~`firstDetection` re-fires for a device that never left~~ — FIXED 2026-09-08

Root cause was an unsigned underflow, not the timeout path. `loop()` captures
`now = millis()` at the top, calls `analyzeWiFiFrame()` which stamps
`lastSeenMs` from a *later* `millis()`, then calls `tick(now)` with the stale
value. `DeviceTracker::tick()` computed `nowMs - lastSeenMs > DEVICE_TIMEOUT_MS`
unsigned, so a negative delta wrapped to ~4.29e9 and departed the device on the
very iteration it was detected. The next beacon then allocated a fresh slot and
returned `EMPTY`, which is exactly `firstDetection`.

The earlier note here — "departure works correctly, so the fault is in
re-registration" — was wrong, and the heartbeat evidence cited for it was
misleading: the beep stopping after ~60s reflected `DEVICE_TIMEOUT_MS`, not
healthy departure.

Fixed in `acb4ff8` with a signed comparison, placed in the tracker so all six
variants get it. Verified: 74 detections produced 1 alert on hardware, and
replaying a captured 239-record run through the real analyzer on the host gives
1 where the device previously gave 57.

### 5. ~~LogControl is a stub~~ — REMOVED 2026-09-08

`6f1d0005` was created with `WRITE_SECURE` but had no `onWrite` handler and
nothing read the log back over BLE, so it silently accepted writes and did
nothing. Dropped from the service rather than left for a client to discover.
The service is now read/notify only, and `WRITE_SECURE` went with it — anything
writable added later needs `WRITE | WRITE_ENC | WRITE_AUTHEN`, since `WRITE_ENC`
alone is satisfied by Just Works pairing.

The UUID is retired deliberately: implementing backfill later should use a new
one so a stale client cannot bind to a characteristic that has changed meaning.

### 6. ~~Task 8 acceptance criteria never run~~ — RUN 2026-09-08, all pass

See `docs/superpowers/plans/2026-09-07-ble-detection-reporting.md` Task 8 for
per-step evidence. Two findings worth carrying:

**Segment rotation and seam recovery are sound.** With `-DFS_RECORDS_PER_SEGMENT=20`
the log rotated `seg 0→1→…→7→0` with a monotonic sequence, no failures, no
crash. After the wrap a reboot recovered `seg 7 seq 32` from on-disk headers
alone, and the record count was capped at capacity (143 of 160) where it had
held 1835 before — the oldest data is genuinely deleted.

**A full filesystem does not disable logging, and that surprised the test.**
Rotation truncates an existing segment and reuses its blocks, so it is
space-neutral, and a fresh segment is only a 12-byte header. With LittleFS
filled to 3,169,280 bytes, rotation still succeeded and detection was
unaffected. Criterion 6 therefore needs injected failure (`-DFS_FORCE_LOG_FAIL`),
under which `[Log] Cannot create segment; logging disabled` appears and the
device still detects, alerts, advertises and pairs normally.

Verification hooks now live in the sketch and are compiled out of normal builds:
`FS_RECORDS_PER_SEGMENT`, `FS_FILL_DISK`, `FS_WIPE_SEGMENTS`, `FS_FREE_DISK`,
`FS_FORCE_LOG_FAIL`.

### 7. ~~Append failure is not checked~~ — the claim was wrong; a real bug next door was fixed

**Correction.** The sighting append *does* check its write result:
`index.recordAppended()` is only reached on success, so the record count never
drifted. The earlier claim here came from a truncated read of the function and
was simply false.

Reading it properly did surface a real defect in `appendDevice`, fixed
2026-09-08. A MAC is marked observed *before* its identifier is persisted:

```cpp
if (devices.observe(threat.mac)) {   // marks it recorded, in memory
    appendDevice(threat);            // write result was discarded
}
```

`observe()` returns false for that MAC for the rest of the run, so a failed
write meant the camera was remembered as recorded while nothing reached flash —
its SSID lost permanently, with no retry possible. `appendDevice` now returns a
bool and the caller calls `DeviceTable::forgetLast()` on failure, so the
identifier is retried on that camera's next sighting.

Also made a sustained sighting-write failure visible. The count stayed correct,
but every record could be dropped while `isReady()` stayed true and the Status
characteristic reported a total that never moved. Five consecutive failures now
logs once and clears `ready`, matching how rotation failure is handled.

Verified on hardware: 40 detections with no failures, and the on-disk count went
177 -> 237 across a reboot.

## Context a fresh session cannot infer

**The SD card slot is dead.** Not "unreliable" — dead. No response at
20/10/4/1 MHz on both SPI hosts, with a card verified good on a Mac (FAT32, MBR,
checksums) and pins matching M5Stack's published v2.7 pinout. Retested after
PSRAM was enabled in case the missing psram-cache errata flags were implicated:
still 8/8 failures. Do not spend time on it. Audio and logs live in internal
flash because of this.

**LittleFS cannot do random-access writes at any useful speed.** Measured on
this board, per 20-byte record: `r+` overwrite in a 400KB file **1690 ms**;
append with the handle held open **1.1 ms**. It is log-structured and
copy-on-write. A ring buffer with random overwrites was designed, built, and
thrown away because of this. Do not reintroduce one.

**PSRAM needs two things, not one.** `PSRAM=enabled` in the FQBN *and* the
defines restored in `build.defines`, which the Makefile's `--build-property`
otherwise clobbers. Both are in the Makefile now. If `[Audio] PSRAM: 0 free of
0 total` appears at boot, one of them was lost.

**`upload-data`'s default offset corrupts firmware on this board.** The stock
`LITTLEFS_OFFSET` of `0x290000` lands inside `app0` (`0x10000`–`0x650000`). The
real filesystem partition is `0xc90000`. Also flash it at 460800 baud — the
hardcoded 921600 fails with serial corruption.

**The USB port drops when esptool toggles DTR/RTS.** Cable-sensitive. Plug
straight into the Mac. Failed uploads abort before writing, so they are safe —
just replug and retry.

**Smoke test:** a hotspot named exactly `Flock-A1B2C3` (`Flock-` plus six hex
chars). Plain `Flock` only reaches `ALERT_SUSPICIOUS` and stays silent — the
repo's own troubleshooting doc is wrong about this. iPhone hotspots default to
5GHz; **Maximize Compatibility must be ON** or the 2.4GHz-only scanner never
sees it.

**The 10-second beep is not a bug.** It is a "target still in range" heartbeat
(`ThreatAnalyzer::tick`), and it fires while any confirmed device is present.

## Not yet reported upstream

Three bugs affecting anyone building this variant via the Makefile or Docker:

1. `upload-data` writes to `0x290000`, inside `app0` on 16MB boards — corrupts firmware
2. `#if defined(ps_malloc)` is always false; it is a function declaration in
   core 3.x, not a macro, so allocations silently fell back to internal DRAM
3. PSRAM is not enabled by the Makefile build

Plus a doc bug: the troubleshooting guide says to test with SSID `Flock`, which
cannot reach `ALERT_CONFIRMED` and so never triggers audio.
