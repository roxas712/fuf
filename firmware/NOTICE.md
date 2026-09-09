# Origin and license

This firmware is a derivative work of **FlockSquawk** by GitHub user
**f1yaw4y**, licensed under the **GNU General Public License v3**.

- Upstream: https://github.com/f1yaw4y/FlockSquawk
- Forked from commit `461ff60` ("Merge pull request #9 from dougborg/pr/07-power-aware")
- Upstream's `LICENSE` (GPL v3) is retained in this directory and applies to
  this subtree.

The GPL applies to **this directory**. Anything outside it —
the Flask backend, the frontend, and the other components — are separate
programs that communicate with this firmware over BLE and HTTP. They are not
derivative works of it.

GPL obligations attach to *distribution*. This repository is private, so
nothing here obliges publication. If any of it is ever distributed, the source
of this subtree must accompany it.

## Local modifications

Made against `461ff60`, all verified on M5Stack FIRE V2.7 hardware:

- Audio moved from the SD card to the on-board LittleFS partition. This board's
  TF slot does not enumerate at any clock on either SPI host.
- PSRAM enabled for the Makefile build. It requires both `PSRAM=enabled` in the
  FQBN and the PSRAM defines restored in `build.defines`, which the Makefile's
  `--build-property` was clobbering.
- WAV buffers allocated via `heap_caps_malloc(MALLOC_CAP_SPIRAM)`. The upstream
  `#if defined(ps_malloc)` guard is always false on ESP32 core 3.x, where
  `ps_malloc` is a function declaration rather than a macro, so allocations
  silently fell back to internal DRAM and a 135KB WAV could never fit.
- A segmented append-only detection log (`DetectionLog`) with per-MAC rate
  limiting and reboot-safe recovery.
- A NimBLE GATT peripheral (`BleReporter`) streaming sightings to a paired
  phone, with passkey pairing shown on the display.
- `radioTypeFromName()` — upstream compares `radioType` against `"ble"` while
  `ThreatAnalyzer` sets `"bluetooth"`, so every Bluetooth sighting was recorded
  as WiFi.
- Host-side unit tests for the new pure units (83 cases total).

## Worth contributing upstream

Three of these are bugs affecting anyone building via the Makefile or Docker,
and one will corrupt firmware:

1. `upload-data` writes the filesystem image to `0x290000`, which is inside
   `app0` on 16MB boards.
2. `#if defined(ps_malloc)` is never true on ESP32 core 3.x.
3. The Makefile build does not enable PSRAM.

Plus a documentation bug: the troubleshooting guide says to test with an SSID
of `Flock`, which only reaches `ALERT_SUSPICIOUS` and therefore never triggers
audio. The format detector needs `Flock-` plus exactly six hex characters.

Contributing these back needs a public fork. The archive clone at
`~/dev/FlockSquawk` retains the upstream remote and the full commit history for
that purpose, separated from this repository's private infrastructure docs.
