# FlockSquawk iOS App — Design

**Date:** 2026-09-07
**Target:** iPhone, iOS 17+, SwiftUI, paid Apple developer account
**Status:** Approved for planning
**Project:** B, of the decomposition in `2026-09-07-ble-detection-reporting-design.md`

## Problem

The FlockSquawk device detects surveillance devices and streams 20-byte sighting
records over BLE, but it has neither GPS nor a real-time clock. A sighting
without a location or a wall-clock time cannot be mapped.

This app is the missing half: it receives sightings, stamps them with the
phone's GPS fix and clock, stores them durably, and uploads them to
your backend, which owns mapping and reporting.

## Scope

**In scope:**

- BLE: scan, connect, passkey pairing, subscribe, unattended reconnection,
  CoreBluetooth state restoration
- Location: Always authorization, background updates, precise-accuracy enforcement
- Durable local queue surviving app termination
- Batched upload with retry, bearer authentication against your backend
- Manual session start/stop, with a live view of the current session

**Out of scope:**

- Mapping and reporting. your backend owns these (project C). The app is a
  receive-stamp-upload client, not a mapping application.
- The `/api/flock/sightings` endpoint itself (project C).
- Token issuance for website accounts (project C). **This app cannot
  authenticate until that exists** — see Authentication below.
- Onboard GPS on the device (project D).
- Backfill of the device's flash log. See "Backfill" below.

## Decisions and rationale

### Background and foreground both

The phone may be mounted with the app open, or pocketed and locked. This
requires `bluetooth-central` and `location` background modes, Always location
authorization, and CoreBluetooth state restoration.

Location is started **before** BLE, deliberately. The location background mode
keeps the app alive, which makes BLE notification delivery reliable. Depending
on BLE-only background wakeups, which iOS throttles, would be fragile.

### Manual session start/stop

Continuous GPS plus BLE costs roughly 10-15% battery per hour. A session is
started and stopped explicitly so that cost is spent deliberately. Automatic
start on driving detection (CoreMotion) was considered and rejected as
complexity that is not yet earned; the failure mode of the manual approach is
forgetting to start, which is recoverable.

### Local-first, batched upload

Every sighting is persisted the instant it arrives, then uploaded in batches
when the network allows. Driving means dead zones, and a detection lost to a
failed request is unrecoverable. Sightings are small — 10,000 is well under a
megabyte — so retention is cheap.

### Live sightings do not need the clock offset

An earlier draft treated the TimeSync clock offset as central. It is not, for
live sightings: when a notification arrives, the phone stamps it with its own
wall clock and current fix immediately. The offset matters only for **backfilled**
records read from the device's flash log, which carry `msSinceBoot` alone.

### Authentication: the your backend website account

Sightings belong to the **website account** (`users` table, `models/user.py`) --
the one used to log in to your backend. Not the game account. The launcher and
games are a separate project with its own accounts, and its
`game_accounts` table is a different identity. Tying sightings to it would
attach them to the wrong person and be painful to migrate once data exists.

**This creates a dependency on project C.** The website login issues no token:

```python
@auth_bp.post("/api/login")          # routes/auth.py
    return jsonify({"user": ..., "role": ..., "permissions": ...})
```

That response is session-shaped, with nothing an app could present on a later
request. So project C must add a token-issuing endpoint for website users before
this app can authenticate at all. The app itself is unaffected by how that is
built -- it posts credentials once, receives a bearer token, stores it in the
Keychain, and sends it on every request.

The machinery already exists to reuse: `make_token(sub, username, ttl)` and
`read_token()` in `services/launcher_security.py` are generic HMAC-signed
tokens carrying `sub`, `u` and `exp`.

**Hazard to hand to project C: token confusion.** Both account systems would
then issue structurally identical tokens signed with the same secret. A
game-account token would verify successfully at a website-account endpoint and
vice versa, because nothing in the claims distinguishes them -- an account in
one namespace would authenticate as the same id in the other. The claims need an
explicit audience field (`"t": "web"` versus `"t": "game"`) checked on every
read, or a separate signing secret per system. This is cheap to get right now
and unpleasant to retrofit.

`User.VALID_FEATURES` already implements per-feature permissions, so a `"flock"`
key fits the existing pattern for scoping who may submit sightings.

## Architecture

Five components with defined interfaces. The UI observes `SessionController` and
makes no CoreBluetooth or CoreLocation calls of its own — that boundary is what
keeps the lifecycle logic testable.

| Component | Responsibility | Depends on |
|---|---|---|
| `PeripheralClient` | Scan, connect, pair, subscribe, reconnect, state restoration | CoreBluetooth |
| `LocationProvider` | Always auth, background updates, current fix and accuracy | CoreLocation |
| `SightingStore` | Decode, stamp, persist, mark uploaded | SQLite |
| `Uploader` | Batch, POST with bearer token, retry, handle auth expiry | URLSession, Store |
| `SessionController` | Start/stop; owns the other four; publishes state | all |

### Testability splits along a hardware line

CoreBluetooth does not exist in the iOS Simulator. Anything BLE-touching is
device-only, which is precisely why `PeripheralClient` is isolated behind an
interface.

| Component | Simulator-testable |
|---|---|
| `SightingRecord` decode | yes |
| `SightingStore` | yes |
| `Uploader` batching and retry | yes, with a mocked URLSession |
| Reboot detection | yes |
| `LocationProvider` | partly, with simulated locations |
| `PeripheralClient` | **no — physical device only** |

### Shared wire-format test vectors

`SightingRecord` is a 20-byte contract between two independently written
codebases. The absolute byte-offset assertions in `test/test_sighting_record.cpp`
are ported to Swift against the same literal bytes, so a change on either side
fails loudly rather than silently mis-parsing RSSI.

## Session lifecycle

**Start:** request Always authorization (iOS forces two prompts — When In Use,
then Always), verify precise accuracy, enable `allowsBackgroundLocationUpdates`
and begin updates, then scan and connect.

**Reconnection is CoreBluetooth's job.** `connect(peripheral)` with no timeout
leaves a standing request; iOS reconnects whenever the device reappears,
including after it goes out of range or is power-cycled. With
`CBCentralManagerOptionRestoreIdentifierKey` and `willRestoreState`, iOS can
relaunch the app after termination and hand back the live peripheral. This is
what makes the pocketed-phone case work.

**Mid-session device reboot.** `millis()` resets to zero on the device, so a
stale offset would misplace every subsequent backfilled record. Detection is
cheap: when an incoming sighting's `msSinceBoot` is *lower* than the previous
one, the device restarted — increment `boot_epoch`, re-read TimeSync, begin a
new offset epoch.

**Stop:** end location updates, cancel the connection, flush the queue.

**One session at a time.** Starting while a session is active is a no-op rather
than an error; the UI reflects the running session. A session left running when
the app is terminated is closed on next launch, with `ended_at` set from the
last sighting's `observed_at` rather than the relaunch time — otherwise a
session interrupted overnight would appear to have run for hours.

## Storage

SQLite. The queue needs transactional writes, a cheap pending query, and
survival across termination.

```sql
CREATE TABLE sightings (
  id INTEGER PRIMARY KEY, session_id TEXT, seq INTEGER,
  observed_at REAL,                  -- phone wall clock at receipt
  ms_since_boot INTEGER, boot_epoch INTEGER,
  mac BLOB, rssi INTEGER, channel INTEGER, radio INTEGER,
  match_flags INTEGER, certainty INTEGER, alert_level INTEGER,
  lat REAL, lon REAL, horiz_acc REAL, speed REAL,
  uploaded_at REAL                   -- NULL = pending
);
CREATE INDEX idx_pending ON sightings(uploaded_at) WHERE uploaded_at IS NULL;

CREATE TABLE devices (mac BLOB PRIMARY KEY, label TEXT, radio INTEGER, first_seen REAL);
CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL, ended_at REAL);
```

`horiz_acc` and `speed` exist to serve the RSSI-peak position estimation chosen
in the firmware spec: accuracy lets the server weight a fix taken in a tunnel
differently from one under open sky, and speed constrains how far the phone
travelled between samples.

**Location is nullable, deliberately.** A sighting can arrive before GPS has a
fix — cold start, parking garage. Dropping it would lose a real detection. The
record is stored with null coordinates and the server interpolates from the
surrounding track.

## Upload contract

```
POST /api/flock/sightings
Authorization: Bearer <token>
Content-Type: application/json

{ "session_id": "...", "device_id": "AA:BB:CC:DD:EE:FF",
  "sightings": [ { "seq": 1, "observed_at": 1757260000.123,
                   "mac": "b6:99:f0:51:45:a4", "rssi": -73, "channel": 8,
                   "radio": 0, "match_flags": 321, "certainty": 100,
                   "alert_level": 3, "lat": 35.1, "lon": -85.2,
                   "horiz_acc": 5.0, "speed": 13.4 } ] }

-> 200 { "accepted": 42, "duplicates": 0 }
```

**Idempotency on `(session_id, seq)`**, not a per-sighting UUID: compact, and it
makes a lost response harmless because resending is a no-op the server
recognises. `models/game_idempotency.py` is precedent for this pattern.

`radio` is an integer (0 = wifi, 1 = ble), matching the firmware's uint8 field
and the local schema — not a string.

`session_id` is a UUID generated at session start. `seq` is a per-session
counter starting at 1. `device_id` is the peripheral's BLE address, which
distinguishes devices if more than one is ever used.

Batches of **200 sightings** per request, oldest first. Exponential backoff on
failure, capped at 5 minutes between attempts.

### Retention

Uploaded records are pruned **30 days** after `uploaded_at`, so the database does
not grow without bound. Records that have never uploaded are **never pruned** —
losing un-uploaded detections to a retention sweep would defeat the local-first
design. If un-uploaded records exceed 100,000, the app surfaces a warning rather
than silently discarding; that state means uploading has been broken for a long
time and needs attention, not garbage collection.

## Error handling

**Reduced-accuracy location is the hazard worth designing for.** iOS 14+ allows
location authorization without Precise Location, yielding fixes accurate to a
kilometre or worse. The app would keep working, keep uploading, and produce a
map of camera positions that is confidently wrong. `accuracyAuthorization ==
.reducedAccuracy` is checked at session start and surfaced as a **blocking**
warning. Silent garbage is worse than a refusal.

| Failure | Behavior |
|---|---|
| Device out of range | Standing connect request; iOS reconnects, no user action |
| Bluetooth off or unauthorized | Surface state, keep queue, resume when restored |
| Pairing revoked | Surface a re-pair prompt — the one case needing the user |
| No network | Queue grows; normal operation, not an error |
| 401 | Re-login prompt, queue preserved |
| 5xx | Exponential backoff |
| 4xx on a batch | Quarantine that batch and surface it; never retry a malformed payload forever |
| Disk full | Stop accepting, warn loudly |

## Backfill

The device *used to* expose `LogControl` for reading its flash log; it was removed on 2026-09-08, having never been implemented. **Not implemented in
this project.** A backfilled record carries a timestamp and no location; placing
it requires the phone to have been recording its own track at that moment. Until
the device has onboard GPS (project D), backfill only usefully covers brief BLE
dropouts the phone can fill from recent location history. Implementing it now
would be building against a capability that does not yet exist.

## Acceptance criteria

1. A sighting decoded from BLE matches the firmware's byte layout, verified
   against shared test vectors.
2. The queue survives app termination — kill the app mid-session, records persist.
3. Background delivery works with the phone locked and the app backgrounded.
4. The device can be power-cycled mid-session and reconnects with no user action.
5. A session collected in airplane mode uploads completely when network returns.
6. Reduced-accuracy location is detected and blocks the session with a clear message.
7. A mid-session device reboot increments `boot_epoch` and does not corrupt timestamps.
8. Simulator-testable components pass unit tests without hardware.

## Dependency on project C — SATISFIED 2026-09-09

Both blockers shipped and are live on your backend.

**`POST /api/login`** now returns `{token, exp, user, role, permissions}`.

**`POST /api/flock/sightings`** exists. The real contract, read from
`backend/routes/flock.py` rather than restated from the design:

```
POST /api/flock/sightings          Authorization: Bearer <web token>
{
  "session_id":  <string, required>        // client-generated, one per session
  "device_id":   <string, optional>
  "started_at":  <epoch seconds, optional>
  "ended_at":    <epoch seconds, optional>
  "sightings": [ {
      "seq":         <int, REQUIRED>       // unique within the session
      "observed_at": <epoch seconds, REQUIRED>
      "mac":         <string, REQUIRED>
      "rssi":        <int, REQUIRED>       // -128..0
      "channel":     0..14      "radio":       0..1
      "certainty":   0..100     "alert_level": 0..3
      "lat": -90..90            "lon": -180..180
      "match_flags": <int>      "horiz_acc": <float>   "speed": <float>
  } ]
}
-> 200 {"accepted": <int>, "duplicates": <int>}
```

Facts that shape the client, each of which would otherwise be discovered the
hard way:

- **Idempotency is `UNIQUE (session_id, seq)` with `ON CONFLICT DO NOTHING`.**
  Re-sending a batch after a lost response is a database-enforced no-op, so the
  uploader may retry freely. `seq` must be stable for a given sighting — derive
  it from a per-session counter assigned at capture, never at upload time.
- **`MAX_BATCH` is 500.** Larger batches are refused outright, not truncated.
- **`observed_at` more than 24h in the future is rejected** for the whole batch,
  not just that record — a phone with a wrong clock poisons the map.
- **Validation is all-or-nothing.** The first invalid sighting returns 400 with
  its `index` and `field`, and *nothing* in the batch is stored. A single bad
  record blocks its whole batch, so validate client-side before sending.
- **A session belongs to one user.** A batch naming another user's `session_id`
  is refused 403 rather than merged.
- **`/api/flock/sightings` requires the `flock` permission**, and an `admin`
  passes regardless of their `permissions` list (`User.has_permission`).
- Optional fields are stored as `None` when absent; only `seq`, `observed_at`,
  `mac` and `rssi` are mandatory.

**The device's BLE contract is in `docs/handoff/ios-app.md`**, which is the
authority — it was corrected against the firmware's own GATT dump on
2026-09-08/09 and carries the notification rates, the dedup requirement, and the
security gate. Read it before `PeripheralClient` or `SightingStore`.

## Open questions

None blocking. Deferred: mapping and reporting are project C; onboard GPS and
true standalone logging are project D.
