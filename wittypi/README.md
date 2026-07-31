# Witty-Pi-4 (Inside Out Group fork)

Fork of [uugear/Witty-Pi-4](https://github.com/uugear/Witty-Pi-4), hardened for
**unattended, field-deployed Raspberry Pi units** (3G/4G connected, UK sites,
no physical access). The Witty Pi 4 HAT provides an RTC and full power
management: it cuts and restores the Pi's power on a schedule, so reliability
of the alarm/wake path is everything — a missed wake means a site visit.

## Documentation

| Document | Contents |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | Complete version history: Pi software (both lines) and firmware revisions |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design: components, boot sequence, alarm lifecycle, time handling, reliability mechanisms, GPIO/register maps |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | Importing this software into a larger project: deploy endpoints, state files, version conventions, extension hooks |
| [Firmware/PROJECT_CONTEXT.md](Firmware/PROJECT_CONTEXT.md) | Firmware engineering context, register map, pin map |
| [Firmware/FIRMWARE_ISSUES.md](Firmware/FIRMWARE_ISSUES.md) | Historical firmware issue analysis |
| [Firmware/WittyPi4_v15/README.md](Firmware/WittyPi4_v15/README.md) | Rev 15 firmware: exact build settings and flashing notes |

## Release tracks

Two branches, one per firmware generation. The Pi-side software is kept in
lockstep across both (same fixes, two version numbers).

| Branch | Pi software | Firmware required | Use for |
|---|---|---|---|
| **`main`** | v4.52 | Any (Rev 7+) — firmware-agnostic | Devices in the field on stock or older firmware that cannot be reflashed remotely |
| **`firmware-rev14`** | v5.36 | Rev 14+ (Rev 15 = `0x0F` current, sketch in `Firmware/WittyPi4_v15/`) | Devices flashed with our hardened firmware |

Deploy (self-updating one-liner; safe to re-run, refuses to cross-deploy):

```bash
# Older firmware in the field:
curl -sSL https://raw.githubusercontent.com/insideoutgrp/Witty-Pi-4/main/Software/deploy.sh | sudo bash

# Rev 14+ firmware:
curl -sSL https://raw.githubusercontent.com/insideoutgrp/Witty-Pi-4/firmware-rev14/Software/deploy.sh | sudo bash
```

Check the installed version on a device:

```bash
grep "SOFTWARE_VERSION" /home/pi/wittypi/utilities.sh | head -1
```

## What this fork adds over upstream

**Scheduling correctness (UK/DST)**
- RTC stores UTC; all display and schedule maths use `Europe/London`
  (`LOCAL_TZ`), so schedules hold the same wall-clock times across GMT/BST
- DST-corrected boundary selection in the schedule engine (daily/weekly
  cycles keep their local times; short test cycles run uncorrected)

**Time integrity**
- Network time sync at boot + every 15 min (cron), over **HTTPS** (carrier
  proxies were serving stale cached `Date:` headers on cleartext HTTP)
- systemd-timesyncd (NTP) re-enabled after every manual clock set
- RTC never overwritten from an unsynced or unreadable clock; every RTC
  register read validated

**Reliability backstops** (written to the HAT every boot)
- Guaranteed Wake: hardware-level wake at least every 24 h regardless of
  alarm state (firmware Rev 15 also enforces this floor itself)
- DEFAULT_ON: any power input boots the Pi, no button press ever required
- Alarm validation with firmware-matched day-of-month semantics; fallback
  alarms so the device always has a future wake target
- Internet connectivity watchdog: 3 failed checks → reboot (rate-limited,
  2/day cap, 30-min uptime gate)

**Concurrency safety**
- Single `flock` serialises all I2C users (daemon, schedule engine, cron
  jobs, interactive menu — root and non-root)
- Alarm registers written day-first so torn writes are never in the
  firmware's match window; firmware Rev 15 additionally pauses alarm
  evaluation during rewrites

**Field operability**
- Atomic remote deploy with version gate, per-file syntax check, backup,
  schedule sync, and interrupted-deploy recovery
- Physical button shutdown removed (firmware Rev 14+); the button is
  repurposed as an application input driving a relay GPIO
  (`Software/wittypi/buttonRelay.sh`, auto-enabled on Rev 14+, per-device
  config survives deploys)
- Every failure path logs; wittyPi.log is the single diagnostic record

**Firmware (branch `firmware-rev14`, Rev 13 → 15)**
- sleep() out of ISR context, I2C bus mutex, widened alarm catch-up window
- SYS_UP boot watchdog: a Pi that hangs before its daemon runs gets
  power-cycled after 30 min instead of holding power forever
- Bounded internal-I2C waits (a wedged RTC bus can no longer brick the MCU)
- Dormant features stripped for flash headroom (8188/8192 bytes)

## Constraints and assumptions

- Timezone is **hard-set to `Europe/London`** — this fleet operates UK-only
- Target OS: Raspberry Pi OS (Bullseye tested); requires `wiringPi`,
  `i2c-tools`, `curl` (installed by `install.sh`)
- Devices shut themselves down on schedule: all tooling assumes it can be
  killed by a power cut at any instruction

---

## Upstream hardware description

Witty Pi is an add-on board that adds realtime clock and power management to
your Raspberry Pi. It can define your Raspberry Pi's ON/OFF sequence, and
significantly reduce the energy usage. Witty Pi 4 hardware resources:

*   Factory calibrated and temperature compensated realtime clock with ±2ppm accuracy.
*   Dedicated temperature sensor with 0.125 °C resolution.
*   On-board DC/DC converter that accepts up to 30V DC.
*   AVR 8-bit microcontroller (MCU) with 8 KB programmable flash.

Upstream product page and manual: https://www.uugear.com/product/witty-pi-4/
