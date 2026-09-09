# Handoff: onboard GPS and standalone operation (project D)

**Location:** `~/dev/fuf/firmware`, branch `flock-ingest`
**Status:** hardware purchased, nothing designed or built. No spec exists.

## Why this exists

Today the device cannot record where it was. The iOS app supplies location, so
the device is only useful with a phone connected. This project adds a GPS module
so it logs geotagged sightings on its own — leave it in the car, drive, pull the
data off later.

## Hardware already bought

**2× Teyleten ATGM336H GPS+BDS modules**, each with a ceramic patch antenna on
an IPEX/u.FL pigtail and an unsoldered 5-pin header.

Notably, **M5Stack's own GPS Module v2.1 uses the same ATGM336H chip**, so this
is the same silicon at a fraction of the price.

Pinout on the board: `VCC / GND / TX / RX / PPS`. PPS is a precision timing pulse
this project does not need.

## The constraint that decides the wiring

**Port C — the obvious Grove UART port — is unusable on the FIRE.** M5Stack's own
v2.7 docs:

> GPIO 16 / 17 in FIRE is connected to PSRAM by default, so when connecting or
> stacking other functional modules, be careful to avoid conflicts with these two
> pins

Port C **is** GPIO 16/17. And PSRAM is not optional here — the firmware needs it
for WAV buffers, and getting it enabled took real effort (see the firmware
handoff).

This is why a bare module beats a stacking one: ESP32 routes UART2 to any GPIO
through the matrix, so you are not stuck with whatever pins a module hardwires.

**Use Port B — GPIO 26 and GPIO 36:**

| Signal | Pin | Note |
|---|---|---|
| GPS TX → ESP32 RX | GPIO 36 | Input-only, which is fine — RX only receives |
| ESP32 TX → GPS RX | GPIO 26 | Only needed to reconfigure baud/update rate |
| GND | Grove GND | |
| VCC | **verify first** | see below |

## Two things to check before powering it

**Voltage.** The board is minimal — chip, u.FL connector, five pads, no visible
regulator. That suggests **3.3V only** (the ATGM336H is 2.7–3.6V). M5Stack's
Grove ports supply **5V**. If the board has no regulator, Grove 5V destroys it.
Meter it or ask the seller; if 3.3V-only, tap 3.3V from the M-BUS header instead.

**Soldering.** The 5-pin header is not attached.

## Design notes for whoever specs this

**Default fix rate is 1 Hz.** At 30 mph that is one position every 13 metres,
coarse for the RSSI-peak positioning this data feeds. The chip supports faster;
plan on 5–10 Hz. That is the reason to wire GPIO 26 rather than RX alone.

**The storage format already has room.** `SightingRecord` (20 bytes, in
`firmware/common/SightingRecord.h`) reserves bytes 17–19 explicitly for a GPS-fix index,
and segment files carry a format version byte. Adding location need not orphan
existing logs. Do not widen the record past 20 bytes without deliberately moving
to a negotiated larger BLE MTU — 20 is exactly one default-MTU notification.

**Time becomes solvable.** The device has no RTC, which is why `msSinceBoot` is
all it can stamp today. GPS provides real UTC. That would make backfill genuinely
useful — currently excluded from the iOS app precisely because backfilled
records have no location and no absolute time.

**Do not plan to log to SD.** The slot on this board is dead: no response at
20/10/4/1 MHz on both SPI hosts with a known-good card. Logs live in the
LittleFS segmented log.

## Suggested first step

Brainstorm a spec (`superpowers:brainstorming`). The interesting questions are
how GPS fixes attach to sightings (per-sighting copy versus a fix table the
reserved index points at), what happens to sightings recorded before first fix,
and whether the device should keep logging when no fix is available.
