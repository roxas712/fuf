# FlockSquawk — M5Stack FIRE V2.7 — WORKING CONFIG

Verified working 2026-09-07: voice alerts + RF detection confirmed on hardware.
All local changes live on branch `littlefs-audio`; `git checkout main` = stock upstream.

## No SD card needed

The FIRE's TF slot would not enumerate at ANY clock (25/10/4/1 MHz) on EITHER
SPI host (HSPI and VSPI), with a card proven good in the Mac: FAT32, MBR
(FDisk_partition_scheme), correct checksums, pins verified against M5Stack's
official v2.7 pinout (MOSI 23 / MISO 19 / CLK 18 / CS 4). Presumed bad slot.

Audio and config were moved to the on-board LittleFS partition. Leave the slot
empty. Settings now live in flash alongside the WAVs.

## Build + flash

```
make build  VARIANT=m5fire
make upload VARIANT=m5fire PORT=/dev/cu.usbserial-XXXX
make upload-data-m5fire PORT=/dev/cu.usbserial-XXXX \
     LITTLEFS_OFFSET=0xc90000 LITTLEFS_SIZE=0x360000
```

Data upload only needed once, or after changing the WAVs. It wipes saved
settings (same partition).

**Flash the data image at 0xc90000, never the Makefile's 0x290000 default** --
that offset sits inside app0 (0x10000-0x650000) on this 16MB board and will
overwrite the firmware. Board's real table:

```
nvs      0x9000    20K
otadata  0xe000     8K
app0     0x10000  6400K
app1     0x650000 6400K
spiffs   0xc90000 3456K   <- LittleFS lives here
coredump 0xff0000   64K
```

Re-derive with: `python3 <core>/tools/gen_esp32part.py .build/m5fire/*.partitions.bin`

## Four upstream bugs fixed locally

1. **SD slot** — hardware; bypassed via LittleFS.
2. **`upload-data` offset 0x290000** — lands in app0 on 16MB boards, corrupts firmware.
3. **`#if defined(ps_malloc)`** — always false; `ps_malloc` is a function
   declaration in core 3.x (esp32-hal-psram.h:38), not a macro. Silently fell
   back to internal DRAM, so 135KB WAVs could never allocate. Now uses
   `heap_caps_malloc(size, MALLOC_CAP_SPIRAM)` with a malloc fallback.
4. **PSRAM never enabled by the Makefile** — needs BOTH:
   - `PSRAM=enabled` explicitly in the FQBN, and
   - the PSRAM defines restored in `build.defines`, which the Makefile's
     `--build-property "build.defines=-I.../common"` was clobbering
     (`-DBOARD_HAS_PSRAM -mfix-esp32-psram-cache-issue
     -mfix-esp32-psram-cache-strategy=memw`).

   Healthy boot now reports: `PSRAM: 4191656 free of 4194304 total`.

Bugs 2-4 affect anyone building this variant via the Makefile or Docker.
Not yet reported upstream.

## Flashing gotchas

- USB port drops mid-flash when esptool asserts DTR/RTS. Cable-sensitive;
  plug straight into the Mac. Failed uploads abort before writing -- safe.
- `upload-data`'s hardcoded 921600 baud fails ("serial noise or corruption").
  460800 works: `esptool --chip esp32 --port PORT --baud 460800 \
  write_flash 0xc90000 .build/m5fire/littlefs.bin`
- Docker builds need Docker Desktop running; the native arduino-cli path
  works regardless and is what's actually used for flashing (no USB in Docker).

## Smoke test

Hotspot named **`Flock-A1B2C3`** -- literally `Flock-` + exactly 6 hex chars.
Plain `Flock` (what the repo's troubleshooting doc says) only trips the keyword
detector -> ALERT_SUSPICIOUS, and `shouldAlert` requires ALERT_CONFIRMED, so it
logs telemetry but stays silent. The `Flock-` + 6-hex form hits detectSsidFormat
(weight 75) -> CONFIRMED -> audio.

iPhone hotspots default to 5GHz; the scanner is 2.4GHz only (channels 1-13).
Turn ON **Maximize Compatibility** or the device will never see it.

Alerts fire once per MAC (`firstDetection`); reset the board to re-test.

## Open item

Repeated `should_alert:true` for a single MAC that never left range (19 in one
capture). Mechanism is the tracker aging slots to DEPARTED after
DEVICE_TIMEOUT_MS (60s) and re-registering them as new -- but not yet explained
why it triggers while the device is continuously visible. Unresolved.
