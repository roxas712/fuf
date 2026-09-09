# Handoff: FlockSquawk iOS app (project B)

**Repo:** `~/dev/fuf`, branch `flock-ingest`. The app will live at
`ios/`.
**Spec:** `docs/superpowers/specs/2026-09-07-ios-app-design.md`.
Read it first — it is complete and approved. No implementation plan exists yet.

**Status:** designed, not started. **Blocked on project C1** for its final
integration, though most of it can be built and tested before C1 ships.

## What it is

The FlockSquawk device detects surveillance cameras and streams 20-byte sighting
records over BLE. It has no GPS and no real-time clock, so a sighting leaves it
with no location and no wall-clock time. This app supplies both, stores
sightings durably, and uploads them to your backend.

SwiftUI, iOS 17+, physical iPhone, paid Apple developer account.

## Start here

The spec covers architecture, session lifecycle, storage schema, upload
contract, error handling and acceptance criteria. The next step is an
implementation plan (`superpowers:writing-plans`), then execution.

## The dependency

**C1 must ship first for an end-to-end run.** It provides:

1. A token-issuing login. your backend's `/api/login` currently returns
   `{user, role, permissions}` and **no token**, so the app cannot authenticate.
2. `POST /api/flock/sightings`.

C1 is specced and planned in this same repo:
`docs/superpowers/specs/2026-09-07-flock-ingest-and-web-tokens-design.md` and
`docs/superpowers/plans/2026-09-07-flock-ingest-and-web-tokens.md`.

Everything except `Uploader` can be built and tested against a stub server
first. `Uploader` is deliberately the only component that knows the endpoint's
shape.

## Things that will cost you time if you do not know them

**CoreBluetooth does not exist in the iOS Simulator.** Anything BLE-touching is
physical-device-only. This is why the spec isolates `PeripheralClient` behind an
interface — `SightingStore`, `Uploader`, decoding and reboot detection all
remain simulator-testable.

**The 20-byte record is a wire contract with the firmware.** Port the absolute
byte-offset assertions from `firmware/test/test_sighting_record.cpp` into Swift tests
against the same literal bytes. Two independently written codebases will
otherwise drift, and the failure mode is silently mis-parsed RSSI, not a crash.
`radio` is an **integer** (0 wifi, 1 ble), not a string — an earlier draft of
the spec had this wrong and it was caught by cross-checking the two specs.

**iOS reduced-accuracy location is the hazard worth designing for.** Without
Precise Location, fixes are accurate to a kilometre or worse. The app would keep
working, keep uploading, and produce a map that is confidently wrong. Check
`accuracyAuthorization == .reducedAccuracy` at session start and block.

**Live sightings do not need the TimeSync clock offset.** Stamp them with the
phone's own clock on receipt. The offset matters only for backfilled records —
which are out of scope, see below.

**Backfill is deliberately excluded, and there is no longer a characteristic
for it.** A backfilled record carries a timestamp and no location; placing it
needs a track the phone may not have. Until the device has onboard GPS (project
D), backfill only covers brief BLE dropouts. `LogControl` was removed from the
service on 2026-09-08 — see the service definition below.

## The service definition (final, verified on hardware 2026-09-08)

Service `6f1d0001-b5a3-f393-e0a9-e50e24dcca9e`. All UUIDs share the
`-b5a3-f393-e0a9-e50e24dcca9e` suffix. **Read/notify only — there is nothing
writable.**

| UUID | Name | Properties | Size | Populated? |
|---|---|---|---|---|
| `6f1d0002` | Sighting | NOTIFY, READ, READ_ENC, READ_AUTHEN | 20 B | **yes**, ~2/sec per camera |
| `6f1d0003` | DeviceInfo | NOTIFY, READ, READ_ENC, READ_AUTHEN | 46 B | **yes**, once per MAC per connection |
| `6f1d0004` | TimeSync | READ, READ_ENC, READ_AUTHEN | 4 B | yes, refreshed on connect |
| `6f1d0006` | Status | READ, READ_ENC, READ_AUTHEN | 10 B | yes, refreshed at most every 5s |

`6f1d0005` (LogControl) **no longer exists** — removed 2026-09-08. The UUID is
retired; if backfill is built it gets a new one.

Taken from the device's own GATT registration dump, not from the source.

### Payload layouts

All little-endian. Byte offsets are the contract; struct padding is not.

**Sighting (20 B)** — exactly one notification at the default MTU. Do not widen
it without negotiating a larger MTU first.

```
[0..3]   msSinceBoot  uint32   wraps at ~49 days
[4..9]   mac          uint8[6]
[10]     rssi         int8     signed
[11]     channel      uint8
[12]     radio        uint8    0 = wifi, 1 = ble   (an integer, not a string)
[13..14] matchFlags   uint16   which detectors fired
[15]     certainty    uint8    0-100
[16]     alertLevel   uint8
[17..19] reserved              earmarked for a GPS-fix index (project D)
```

**DeviceInfo (46 B)** — `[0..5]` mac, `[6..44]` identifier as a null-padded
39-byte string, `[45]` zero.

**TimeSync (4 B)** — `msSinceBoot` at the moment of refresh. Pair it with the
phone's wall clock to place records in real time; the device has no RTC.

**Status (10 B)** — `[0]` `SIGHTING_FORMAT_VERSION`, `[1]` GATT interface
revision, `[2..5]` records stored, `[6..9]` capacity.

### How DeviceInfo behaves

Published **once per MAC per connection**, immediately *before* the first
Sighting for that MAC, so the app can label the camera rather than briefly
rendering a bare address. Skipped when the identifier is empty — a hidden-SSID
camera has nothing to say and the MAC already arrives via Sighting.

`announced` is cleared on every connect, so a phone joining mid-session gets
labels as devices reappear rather than being permanently unlabelled because the
device told someone else an hour ago.

**A label that cannot be delivered is retried.** The MAC is only marked
announced once the publish actually happens while the phone is subscribed to
`6f1d0003`; otherwise it rolls back and retries on the next sighting. This
matters in practice: subscribing to Sighting first and DeviceInfo second is
normal, and an implementation that announced on the first sighting regardless
would lose that camera's label for the entire session.

**Do not treat `notify()`'s return as delivery.** It returns true with no
subscriber — observed on hardware. The firmware tracks subscription state from
`onSubscribe` instead.

### Status, and why it is deliberately throttled

Refreshed where the stored count can change — after the log handles a detection,
since an append raises it and a rotation lowers it — but **rewritten at most once
every 5 seconds**, and that limit is load-bearing.

`NimBLEAttValue::setValue()` sets `m_attr_len = 0` before appending the new
bytes, with no lock. Reads are served on the NimBLE host task; the refresh runs
on the loop task. A read landing in that window returns **zero bytes**, and the
characteristic reads as empty. Refreshing per detection (~2/sec) made Status
reliably unreadable on hardware — a GATT browser showed "no value" every time,
while TimeSync, which is written from `onConnect` on the host task, always read
fine. Throttling shrinks the window to microseconds every five seconds.

**This is not fully closed.** A read can still collide with the microsecond
write. Making Status authoritative rather than indicative would mean serialising
updates onto the host task, which NimBLE does not cleanly expose. Treat the
value as a fill-level gauge, not a precise count.

**Do not add a frequently-updated readable characteristic without reading the
above.** The same trap applies to any of them.

Verified on hardware: `0x0101EB040000007D0000` — version 1, revision 1,
1259 stored, 32000 capacity.

### Security: an unpaired client CAN subscribe

The CCCD does **not** inherit the characteristic's encryption requirement. The
GATT dump shows `6f1d0002` as `[READ|NOTIFY|READ_ENC|READ_AUTHEN]` while its
descriptor registers with `min_key_size 0`. NimBLE accepts the CCCD write
unencrypted and only then calls `startSecurity()` reactively
(`NimBLEServer.cpp`, `BLE_GAP_EVENT_SUBSCRIBE`), so a peer can subscribe and
then simply decline to pair.

Permission flags cannot close this. The firmware refuses to *send* instead:
`BleReporter::notifyAllowed()` gates both notify paths on
`NimBLEConnInfo::isAuthenticated()`, set from `onAuthenticationComplete` and
cleared on every connect and disconnect. Sighting data therefore only leaves
over a MITM-protected link. **Do not remove that gate believing the
characteristic flags are doing the work — they are not.**

`READ_ENC` alone is satisfied by Just Works pairing, which made the passkey
decorative until `READ_AUTHEN` was added. If you ever add a writable
characteristic it needs `WRITE | WRITE_ENC | WRITE_AUTHEN`.

Note when re-testing: `onAuthenticationComplete` fires on
`BLE_GAP_EVENT_ENC_CHANGE` whether encryption **succeeded or failed**, and
NimBLE does not check the status first. A "pairing complete" log line proves
nothing on its own — log `isAuthenticated()` explicitly.

### Pairing and advertising

- Advertises as `FlockSquawk`, in the **scan response**, not the advertising
  packet. A scanner that only reads advertising data shows it unnamed.
- Address `AA:BB:CC:DD:EE:FF` on the current unit.
- Advertising interval ~1s (`0x0640`–`0x0680` in 0.625ms units), deliberately
  slow to share radio time with the WiFi scanner.
- **Passkey pairing, display-only.** Six digits from the hardware RNG, fresh
  each boot, shown on the device screen. Never hardcode one.
- A fresh pair reports `bonded=1 encrypted=1 authenticated=1 keysize=16`.
- **Bonds survive reboot and reflash**, so a bonded phone reconnects with no
  prompt. That is normal, not a missing requirement.
- Expect spontaneous disconnects (observed `reason 0x0208`, HCI supervision
  timeout). Reconnect silently rather than surfacing an error.
- A pair can fail if the device holds a bond the phone discarded; it succeeds on
  retry. Retry before reporting failure.

## Device-side rates and timing (measured on hardware 2026-09-08)

**Sighting notifications are not rate limited.** `BleReporter` sends one
notification per threat event. Measured **~2 notifications/sec per camera** at
close range, sustained. The app must be able to absorb that and coalesce; do
not assume one notification means one encounter.

**The on-device log and the BLE stream are not the same set.** `DetectionLog`
applies its own limit of one record per MAC per 100ms; the BLE path applies
none. At ~2/sec they coincide, but a burst faster than 10/s for one MAC streams
more than it stores. Do not treat the log as a replay of what was notified.

**Nothing on the wire says "first sighting".** `SightingRecord` carries
`mac`, `rssi`, `channel`, `radio`, `matchFlags`, `certainty` and `alertLevel` —
all per-sighting. There is no first-detection flag and no device identity
beyond the MAC, so **deduplication is the app's job**. Firmware had a bug where
a single stationary camera reported as newly-detected 57 times in 123 seconds
(fixed in acb4ff8); an app that trusted a per-sighting field as "new device"
would have uploaded 57 distinct cameras.

**Two different timing constants, and they mean different things.** If the app
shows presence, mirror these rather than inventing its own, or its UI will
disagree with the device sitting next to the user:

| Constant | Value | Meaning |
|---|---|---|
| `PRESENCE_FRESH_MS` | 20s | Heard this recently = "nearby". Drives the heartbeat beep. |
| `DEVICE_TIMEOUT_MS` | 60s | Not heard this long = departed. A return after this re-alerts. |

A gap under 60s is the same visit; a gap over it is a new one. These were one
constant until 1f0d883, which is why the device claimed a camera was nearby for
a full minute after it left.

**The heartbeat is local audio only.** A ~10s beep while a camera is nearby,
toggleable in the device's settings menu. It produces **no BLE traffic** — there
is no characteristic for it and the app neither sees nor controls it.

**iOS Personal Hotspot is a poor stand-in for a real camera** in testing: it
sleeps its radio when no client is joined (which reads as the device having
stopped detecting), and it randomises its MAC on every power-cycle, so each
restart looks like a genuinely new device. Keep a second device joined, and do
not tune dedup logic against it.

## Testing it end to end

Bring up a hotspot named exactly `Flock-A1B2C3` with **Maximize Compatibility
ON** (the scanner is 2.4GHz only). Plain `Flock` will not trigger alerts.
