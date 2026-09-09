# fuf

Surveillance-camera detection on an M5Stack FIRE, plus the iPhone app that
gives its sightings a time and a place.

The detector sniffs 2.4GHz WiFi and BLE for the signatures of fixed
surveillance cameras and alerts on them. It has no GPS and no real-time clock,
so a sighting leaves the device with neither a location nor a wall-clock time.
The iOS app is the other half: it receives sightings over Bluetooth LE, stamps
each with the phone's fix and clock, stores them durably, and uploads them in
batches.

## Layout

| Path | What it is |
|---|---|
| `firmware/` | ESP32 firmware, six board variants. GPL v3 — see `firmware/NOTICE.md` |
| `ios/FlockCore/` | Swift package: wire decoding, the SQLite queue, upload batching. No hardware needed to build or test |
| `docs/design/` | Design specs |
| `docs/plans/` | Implementation plans, step by step |
| `docs/handoff/` | What is done, what is not, and the things that cost real time to learn |

## Build

**Firmware** (macOS or Linux, `arduino-cli`):

```bash
cd firmware
make build  VARIANT=m5fire
make upload VARIANT=m5fire PORT=/dev/cu.usbserial-XXXXXXXX
make test                      # host-side unit tests, no board required
```

The build path must not contain spaces — `arduino-cli` splits build properties
on whitespace before exec, and neither escaping nor quoting gets around it.

**iOS core** (any Mac with Swift 6, no Xcode or device needed):

```bash
cd ios/FlockCore
swift test
```

The Swift package is deliberately free of CoreBluetooth and CoreLocation so it
builds and tests on the command line. Anything touching those lives in the app
target, because CoreBluetooth does not exist in the iOS Simulator — it reports
`.unsupported` permanently, so a green Simulator run proves nothing about BLE.

## Configuration

The app uploads to a backend you run. The endpoint in the docs is a
placeholder (`example.com`) — set it to your own before building. Nothing here
ships a real server address, and no credentials are stored in the repo; the
bearer token lives in the Keychain.

## Status

The firmware works: voice alerts, WiFi and BLE detection, a segmented
append-only flash log that survives reboots, and a BLE peripheral that streams
sightings to a paired phone over an authenticated link.

The iOS app's hardware-independent core is complete and tested (62 tests). The
app target — CoreBluetooth, CoreLocation, the session controller and the UI —
is specified in `docs/plans/` but not yet built.

`docs/handoff/` is worth reading before touching anything. It records the
findings that were expensive to learn, including a dead SD slot on the FIRE,
why the flash log is segmented rather than a ring buffer, and why an unpaired
BLE client can subscribe to a notify characteristic no matter what permissions
the characteristic carries.

## Where the sightings go

This repo is the device and the client. It does not include a backend — the app
uploads to one you run, and mapping and reporting live there rather than on the
phone. The app was kept a thin receive-stamp-upload client deliberately, so
mapping could happen somewhere with a big screen, real compute and the full
history.

`docs/plans/2026-09-09-ios-app.md` gives the upload contract the client expects:
bearer auth, `UNIQUE (session_id, seq)` idempotency, all-or-nothing batch
validation, and a 500-record cap.

## License

`firmware/` is GPL v3, derived from **FlockSquawk** by GitHub user **f1yaw4y**.
See `firmware/LICENSE` and `firmware/NOTICE.md`.
