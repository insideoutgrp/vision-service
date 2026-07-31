# Witty Pi 4 Firmware — Revision 15

Shippable Arduino sketch folder for flashing onto Witty Pi 4 hardware.
`I2C_FW_REVISION` = `0x0F` (15).

## What's in here

| File | Purpose |
|------|---------|
| `WittyPi4_v15.ino` | The Rev 15 firmware source (includes Rev 14 patches b–e) |
| `SoftIICMaster.h`, `SoftWireMaster.h` | Software I²C master headers used by the firmware |

This is a snapshot of `Firmware/WittyPi4/WittyPi4.ino` packaged in an Arduino-compatible sketch folder (folder name must match the `.ino` name).

## Build settings — IMPORTANT, changed from Rev 14

Mirror the fleet's Arduino IDE board menu exactly
([ATTinyCore](https://github.com/SpenceKonde/ATTinyCore)):

| Menu item | Required value |
|---|---|
| Board | ATtiny441/841 (No bootloader) |
| Chip | ATtiny841 |
| Clock Source (only set on bootload) | 8 MHz (internal, **Vcc < 4.5 V**) |
| Pin Mapping | **Counterclockwise** (like old ATTinyCore and Rev. C boards) |
| LTO | Enabled |
| Wire Modes | **Slave Only** (Master Only fails to build) |
| tinyNeoPixel port | Port A (default, unused) |
| millis()/micros() | **Disabled (saves flash)** — REQUIRED for Rev 15 |
| Save EEPROM (only set on bootload) | EEPROM retained |
| B.O.D. Level (only set on bootload) | B.O.D. Enabled (2.7 V) |
| B.O.D. Mode active / sleep | Enabled / Enabled |
| Programmer | USBasp (ATTinyCore) or similar |

Notes:
- **Pin Mapping = Counterclockwise is critical.** The sketch's Arduino pin
  numbers assume it; a Clockwise build drives the wrong physical pins.
- **millis Disabled is required for flash fit** — the sketch uses no
  `millis()` and `delay()` still works. The build is 8188/8192 bytes
  (4 bytes free); with millis enabled it does not fit.

arduino-cli equivalent (compile-verified with these exact options):
```bash
arduino-cli compile --fqbn "ATTinyCore:avr:attinyx41:chip=841,clock=8internal,pinmapping=old,LTO=enable,wiremode=slave,neopixelport=porta,millis=disabled" WittyPi4_v15
```
(`clock=8internal` is the "Vcc < 4.5 V" variant; `8internal5v` is the > 4.5 V one.)

Cache clearing tip (macOS, after edits):
```bash
rm -rf ~/Library/Caches/arduino/sketches/*/
```

Detailed engineering context, register map, and pin map are in `../PROJECT_CONTEXT.md`.

## What changed (vs Rev 14 patch e)

Downtime-hardening release. All changes target failure modes found in the
2026-07 IoT downtime review (three independent reviewers + manual
verification):

| # | Fix | Failure it closes |
|---|-----|-------------------|
| 1 | `alarmWriteHold` — 5 s pause of alarm evaluation on any alarm-register write | Torn alarm rewrite: the per-byte `ALARM*_TRIGGERED` clear re-armed yesterday's in-window alarm2 mid-rewrite; a WDT tick then hard-cut power mid-boot (boot flapping, ~10–30 % of daily boots) |
| 2 | SYS_UP boot watchdog (30 min, reason 13) | Pi hangs before daemon runs → power stayed on forever, all backstops blind |
| 3 | `sleep()` entry made atomic (cli/sei) | WDT tick in a ~7 ms window consumed the alarm1 match and slept through the wake |
| 4 | Guaranteed Wake floor (reg 49 forced to 24 h if 0) | Fresh EEPROM shipped the 24 h backstop disabled |
| 5 | `I2C_TIMEOUT 20` on soft-I2C master | Wedged RTC bus spun the WDT ISR forever with power off (permanent brick) |
| 6 | TXD reboot detection re-samples up to 4× (~28 s) | Single 7 s sample of a floating line made every OS reboot a coin flip |
| 7 | `delay()` computed in 1 s chunks | DEFAULT_ON_DELAY 33–65 s overflowed int16 into a ~49.7-day dead boot |
| 8 | Telemetry regs 1–6 no longer persisted to EEPROM | ADC jitter wore the cells past the 100k spec within weeks |
| 9 | `alarm1Delayed` reset in `powerOn()` and on alarm1 rewrites | Stale value caused a spurious wake 3 s after the next shutdown |

Known residual (documented, not fixed — flash budget): an alarm missed ON
the last day of a month appears ~1 month in the future the next morning
(day-of-month-relative matching) and won't catch up via the 86400 s
window. Bounded to one lost day by the Guaranteed Wake floor.

## After flashing

Deploy the matching Pi-side software (v5.29+, also compatible with Rev 14):

```bash
curl -sSL https://raw.githubusercontent.com/insideoutgrp/Witty-Pi-4/firmware-rev14/Software/deploy.sh | sudo bash
```

The deploy script does a pre-flight `i2cget` and refuses to install on devices running firmware < Rev 14.
