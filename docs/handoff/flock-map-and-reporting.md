# Handoff: FlockSquawk map and reporting

**Repo:** `~/dev/fuf`
**Status:** not designed. No spec exists.
**Depends on:** C1 (ingest), which creates the tables this reads.

## What it is

Sightings of surveillance cameras arrive from a phone and land in Postgres.
This project turns them into something you can look at: a map of where cameras
are, and reporting over what has been seen.

your backend owns this deliberately. The iOS app was kept a thin
receive-stamp-upload client specifically so mapping could live somewhere with a
big screen, real compute, and the full history — rather than being rebuilt on a
phone.

## The data you will have

Created by C1 (`backend/models/flock.py`):

```
flock_sessions   id, user_id, device_id, started_at, ended_at
flock_sightings  session_id, seq, observed_at, mac, rssi, channel, radio,
                 match_flags, certainty, alert_level,
                 lat, lon, horiz_acc, speed
```

**These are raw sightings, not camera positions.** That is the central design
decision to understand before building anything here.

## Why raw sightings, and what that means for you

A single detection tells you only "a camera was somewhere within radio range" —
which can be a hundred metres. But **signal strength peaks as you drive past**,
so a sequence of RSSI values with positions places the camera far better than
any single fix. Repeat drive-bys down the same road improve the estimate
further.

So the position estimation is **this project's job**, and it was deliberately
kept out of ingest so the algorithm can improve without re-ingesting anything.
Expect many sightings per camera: one stationary device produced 137 detections
in about 30 seconds during firmware testing, and the device rate-limits to one
record per MAC per 100ms.

Two fields exist purely to serve this and are worth using:

- **`horiz_acc`** — GPS accuracy in metres. Weight a fix taken in a tunnel
  differently from one under open sky.
- **`speed`** — constrains how far the phone travelled between samples.

**`lat`/`lon` are nullable.** A sighting can arrive before the phone has a fix.
Those records are kept deliberately rather than dropped — interpolate from the
surrounding track rather than discarding a real detection.

## Things that will surprise you

**MAC addresses are not stable identities.** iOS randomises hotspot MACs per
session, and the test hotspot appeared as three different MACs across a single
afternoon. Real Flock cameras may or may not rotate theirs. Clustering by
position will likely matter more than grouping by MAC.

**`alert_level` is a tier, not a score.** 3 = confirmed, 2 = suspicious,
1 = info. It comes from *which detectors matched*, not from `certainty`.
`match_flags` is the bitmask of which fired — see `firmware/common/Detectors.h` for what each bit means.

**Alert counts over-count.** There is an unexplained firmware bug where
`firstDetection` re-fires for a device that never left range — 19 alerts for one
stationary MAC in one capture. Do not build reporting that treats an alert as a
distinct encounter until that is fixed (see the firmware handoff).

**Timestamps come from a phone.** C1 rejects anything more than 24 hours in the
future, but a phone with a modestly wrong clock still gets through. Sessions are
a useful grouping precisely because they bound a contiguous run.

**`ended_at` may be null.** If the app is killed mid-session it is never set;
treat `max(observed_at)` as the effective end rather than an error.

## Suggested first step

Brainstorm a spec. The interesting questions are what the position-estimation
algorithm actually is, whether estimates are computed on write or on read,
whether cameras get stable identities across sessions, and what the map is for —
personal recall, or something shareable.
