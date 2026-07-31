# WittyPi 4 Firmware Modification — Project Context

## Project Goal

Modify the WittyPi 4 firmware (`WittyPi4.ino`) for an unattended field-deployed Raspberry Pi system. Primary requirements:
1. Reliable scheduled startup/shutdown via RTC alarms
2. Disable physical button from causing shutdown (accidental presses in the field)
3. Maintain reliability across power-loss and brownout scenarios

## Hardware

- **Board**: WittyPi 4 (UUGear) — RTC + power management HAT for Raspberry Pi
- **MCU**: ATtiny841 (AVR 8-bit, **8 KB flash**, **512 bytes SRAM**)
- **RTC**: PCF85063A (calibrated, ±2ppm)
- **Temperature sensor**: LM75B (0.125°C resolution)
- **DC/DC converter**: MP4462 (6-30V input)
- **Power switch**: AO4616 MOSFET, e-latching
- **Button**: Hardwired to **both** the ATtiny's PIN_BUTTON **and** GPIO-4 on the Pi header
- **Communication**: I2C between Pi (master) and ATtiny (slave at 0x08). Internal I2C bus connects ATtiny (master) to RTC (0x51) and LM75B (0x48).

## Key Files

| File | Purpose |
|------|---------|
| `Firmware/WittyPi4/WittyPi4.ino` | **Current firmware (Rev 14)** — canonical edit target |
| `Firmware/WittyPi4_v14/` | **Shippable Rev 14 sketch folder** — open in Arduino IDE and compile/flash |
| `Firmware/FIRMWARE_ISSUES.md` | Initial issue review document (Rev 7 audit + Rev 10 fixes) |
| `Firmware/WittyPi4_UserManual.pdf` | Official UUGear user manual |

**Note**: Rev 10 and Rev 11 are historical checkpoints described in this document and preserved in git history; they are not kept as separate files. The user's Arduino IDE compiles a separate sketch file — copy `WittyPi4/WittyPi4.ino` into the sketch folder before building.

## Firmware Architecture (Critical Context)

- `loop()` is **empty** — all logic runs in ISRs
- **WDT ISR** (`ISR(WDT_vect)`) fires every ~1 second; runs alarm checks, low voltage detection, RTC adjustment
- **Timer1 overflow ISR** (`ISR(TIM1_OVF_vect)`) handles power-cut countdown
- **PCINT0 ISR** monitors TXD (GPIO-14) for Pi shutdown detection
- **PCINT1 ISR** monitors button (PIN 1) and SYS_UP (pin 0, shared with LED)
- **PIN_LED and PIN_SYS_UP share physical pin 0** (dual-purpose hardware design)
- The button **physically connects to GPIO-4** on the Pi — pressing it pulls GPIO-4 LOW, and the Pi's daemon detects this directly via GPIO interrupt (not via I2C)

## How Shutdown Actually Works

The firmware uses `emulateButtonClick()` to drive PIN_BUTTON LOW, which:
1. Triggers the firmware's own PCINT1 ISR (state tracking)
2. **Also pulls GPIO-4 LOW** (same physical line) — the Pi daemon sees this and runs `shutdown -h now`
3. Pi shuts down → TXD goes LOW → firmware detects → Timer1 → `cutPower()` → `sleep()`

For scheduled events (alarm2, low voltage, temperature), the firmware ALSO directly sets `turningOff=true` and starts the Timer1 countdown — so power gets cut after the configured delay (default 7 seconds) regardless of whether the Pi gracefully shuts down or not.

## Revision History

### Rev 14 (2026-05-28) — Physical button shutdown removed
- **Button safety:** the physical button no longer initiates shutdown
  under any circumstances. `PCINT1_vect`'s shutdown branch is gone.
- **No firmware code touches `PIN_BUTTON` anymore** — the shared
  button/GPIO-4 line is firmware-untouched, so external noise, EMI,
  knocks, or shorts on the button cannot affect a running Pi.
- Scheduled (alarm2) and LV shutdowns drive `turningOff` + Timer1
  directly. Alarm1 wake sets `wakeupByWatchdog = false` directly.
- **Removed:** `emulateButtonClick()` function and the
  `isButtonClickEmulated` flag (now unused).
- Manual button-wake-from-sleep preserved as a maintenance override.
- `I2C_FW_REVISION` bumped to `0x0E`.

### Rev 13 (2026-05-26) — Field reliability + "any power input wakes"
Following the four-agent reliability audit (see commit history on the
`firmware-rev13` branch). Targets field-deployed devices with no
physical access.
- **Reliability:** moved `sleep()` out of Timer1 ISR — set `pendingSleep`
  flag from ISR, run sleep from `loop()`. Eliminates the stack-nesting
  risk on 512-byte SRAM (FIRMWARE_ISSUES.md #1).
- **Reliability:** added `internalBusBusy` mutex guarding `softWireMaster`
  between WDT ISR and Pi-side I²C transactions. Skips one WDT tick
  rather than corrupting an in-flight bus transfer (FIRMWARE_ISSUES.md #4).
- **Reliability:** widened the `overdue_alarm` window in
  `processAlarmIfNeeded()` from 4s to 86400s (1 day). Catches alarms
  missed due to WDT jitter or interrupted writes. Safe because Pi-side
  Guaranteed-Wake (reg 49 = 24h) supersedes anything older.
- **"Any power input wakes":** default `I2C_CONF_DEFAULT_ON = 1` so the Pi
  powers on whenever main DC is applied (no button press required).
  Pi-side daemon also writes this on every boot.
- **Stripped dormant code for flash headroom:**
  - Temperature shutdown/startup — registers 43–46 reserved (no-op).
    LM75B no longer initialised at boot.
  - Sleep-loop LED blink — saves field-deployment battery.
  - Net flash saved offsets the reliability additions.
- **Bumped `I2C_FW_REVISION` to 0x0D.**

### Rev 7 (original from GitHub)
Source: https://raw.githubusercontent.com/uugear/Witty-Pi-4/main/Firmware/WittyPi4/WittyPi4.ino

### Rev 10 — Initial deadlock safety
- Added WDT-based 36-second `turningOff` safety timeout
- Force `cutPower()` if `turningOff` stuck (does NOT call `sleep()` to avoid stack corruption — pre-existing issue #1)
- **Later removed in Rev 12** because TCNT1 reset fixes addressed the root cause

### Rev 11 — Multiple fixes
- Disabled physical button shutdown: `if (systemIsUp && isButtonClickEmulated)` in PCINT1
- Gated `forcePowerCutIfNeeded()` by `isButtonClickEmulated`
- Increased low voltage grace period from 180s to 250s (max for `byte`)
- **Fixed bug**: `skipLowVoltageDetectCount < 300` with byte variable (always true — disabled detection)
- **Fixed SYS_UP/LED race**: don't update `lastSystemUp` when guard fails so next PCINT retries
- **Fixed TXD wake**: `listenToTxd = digitalRead(PIN_TX_UP)` on sleep wake (was hardcoded to false, missing already-HIGH transitions)
- **Widened alarm window**: 2s → 4s to prevent WDT jitter misses
- **Fixed `copyAlarm`**: now writes all 5 RTC alarm registers (was 4 — missed Weekday)
- **Added missing `endTransmission()`** for LM75B CONF I2C read

### Rev 12 — Final
- **Added TCNT1 reset** to alarm2, low voltage, temperature shutdown paths for deterministic timing
- **Removed WDT timeout** (root causes addressed)
- **Removed dummy load** feature (`I2C_CONF_DUMMY_LOAD` register kept, no-op)
- **Removed temperature shutdown actions** (high/low temp shutdown/startup) — RTC temperature compensation **kept**
- **Removed `forcePowerCutIfNeeded()`** (dead code with button gating)
- **Inlined**: `turnOnAdcAndGetInputVoltage`, `getTemperature`, `offset2Value`, `value2Offset`
- **Compacted float constants**: `0.001075268817204` → `0.001075f`, temp comp constants shortened
- **Fixed button bypass**: `REASON_CLICK` only written when `!powerIsOn` (was telling Pi daemon "button pressed" even when system running)
- **Fixed power cut delay optimization**: replaced 3 `TCNT1 = getPowerCutPreloadTimer(true)` calls with `powerCutDelay = 0; TCNT1 = 65534;` to save flash — **BUT THIS MAY BYPASS THE 7s DELAY** (see Known Issues)
- **Cleared `I2C_ALARM1_TRIGGERED` and `I2C_ALARM2_TRIGGERED` in sleep()** so alarms can re-fire without daemon intervention

## Verified by Agent Testing

Rev 12 passed 22 scheduling loop tests:
- Alarm2 normal shutdown
- Alarm2 3s-late WDT (widened window catches it)
- Alarm2 with `turningOff` already set (no double-shutdown)
- Alarm1 normal wake from sleep
- Alarm1 3s-late wake
- Alarm1 blocked by low voltage (correctly silent, retryable)
- Alarm1 during active shutdown (alarm1Delayed path)
- Full cycle: startup → run → shutdown → sleep → repeat
- Rapid cycle (alarm2 5s after alarm1)
- Month boundary (correctly fails per known limitation)
- TXD shutdown, TXD reboot detection, TXD already-HIGH at boot
- SYS_UP detection during LED on (retry mechanism)
- Low voltage threshold, grace period, recovery during sleep
- Safety timeout firing and normal completion

## Known Issues / Limitations

### 1. Pi schedule script bug (NOT firmware — Pi side)
User's log shows:
```
2026-04-23 20:00:25 — Schedule script is interrupted, revising the schedule...
Schedule next shutdown at: 2026-04-23 05:59:00 BST  ← IN THE PAST
Schedule next startup at:  2026-04-23 06:00:00 BST  ← IN THE PAST
```
The schedule script on the Pi gets interrupted mid-revision by the firmware's hard power cut, leaving alarm registers with past times. System doesn't boot until something else wakes it (guaranteed wake or manual).

### 2. Power cut delay potentially bypassed
The `powerCutDelay = 0; TCNT1 = 65534;` optimization may cut power immediately (~2ms) rather than after configured delay (default 7s). Needs verification — but user accepted hard power cut as OK.

### 3. `getTimestamp()` ignores month/year
```cpp
long getTimestamp(byte date, byte hours, byte minutes, byte seconds) {
  return (long)date * 86400 + ...;
}
```
Alarms crossing month boundaries silently fail. Cannot be fixed without adding month register to API (breaking change).

### 4. Pre-existing architectural issues (not addressed)
- `sleep()` called from Timer1 ISR — risks stack corruption on 512-byte SRAM (issue #1)
- EEPROM writes in ISR context block ~3.4ms each
- I2C bus collision between WDT ISR and `requestEvent`/`receiveEvent` (no locking on `softWireMaster`)
- 250-second brownout vulnerability window at boot (low voltage detection disabled during grace period)

### 5. Daemon dependency
The Pi daemon **must** maintain alarm register state — write next alarm times before each shutdown. If interrupted (e.g., by hard power cut), alarms become stale. The firmware now clears triggered flags on sleep to mitigate, but cannot fix stale day values.

### 6. Removed features
- **Temperature-based shutdown/startup** (`I2C_CONF_OVER_TEMP_ACTION`, `I2C_CONF_BELOW_TEMP_ACTION`) — registers still exist but no-op
- **Dummy load pulsing** (`I2C_CONF_DUMMY_LOAD`) — register still exists but no-op
- **`forcePowerCutIfNeeded()`** — button hold to force power off no longer works

## Flash Size Issue

The ATtiny841 has 8KB flash. Original firmware was already near the limit. Adding the WDT timeout, TCNT1 resets, SYS_UP fix, etc. pushed it over by ~90 bytes. Required significant optimization:
- Removed dead code (`forcePowerCutIfNeeded`)
- Inlined small functions
- Removed temperature shutdown feature
- Removed dummy load feature
- Replaced function calls with direct register writes

User compiles via Arduino IDE — sketch hash in errors: `B9FB2C30D023952A88D60B16DDA95D03`. Cache location: `~/Library/Caches/arduino/sketches/B9FB2C30D023952A88D60B16DDA95D03/`

## Daemon Modifications (User to do separately)

User is modifying the Pi-side WittyPi daemon to ignore GPIO-4 button presses. This prevents accidental physical button shutdowns. **Side effect**: emulated button clicks from firmware (alarm2, low voltage) won't trigger the daemon's graceful shutdown either — firmware will hard-cut power after the Timer1 countdown.

User confirmed: **hard power cut is acceptable** for this use case.

## Outstanding Questions / Next Steps

1. **Verify power cut delay timing** — does the `TCNT1 = 65534; powerCutDelay = 0;` actually delay or cut immediately? May need to revert this optimization (but flash limit was the constraint).

2. **Make firmware more forgiving of stale alarms** — currently requires alarm time within 4 seconds of current time. Could make alarm fire if "overdue" by any amount (within same day) to recover from interrupted daemon writes.

3. **Pi-side schedule script** — needs to be made shutdown-safe so it doesn't leave alarm registers in inconsistent state.

4. **Diagnose the 09:56 wake** in user's log — was it guaranteed wake, voltage event, button, or something else? Requires reading `I2C_ACTION_REASON` (register 11) on next boot.

## I2C Register Map (Reference)

| Reg | Name | Purpose |
|-----|------|---------|
| 0 | I2C_ID | Firmware ID (0x26) |
| 1-6 | Voltage/current readings | Vin, Vout, Iout (integer + decimal) |
| 7 | I2C_POWER_MODE | 1=DC, 0=5V USB |
| 8 | I2C_LV_SHUTDOWN | 1 if shut down by low voltage |
| 9 | I2C_ALARM1_TRIGGERED | 1 if alarm1 fired |
| 10 | I2C_ALARM2_TRIGGERED | 1 if alarm2 fired |
| 11 | I2C_ACTION_REASON | 1=alarm1, 2=alarm2, 3=click, 4=LV, 5=restore, 6=overtemp, 7=belowtemp, 8=alarm1 delayed, 10=power connected, 11=reboot, 12=guaranteed wake |
| 12 | I2C_FW_REVISION | Currently 0x0C (12) |
| 16 | I2C_CONF_ADDRESS | I2C slave address (default 0x08) |
| 17 | I2C_CONF_DEFAULT_ON | Auto-power on when power connected |
| 18 | I2C_CONF_PULSE_INTERVAL | LED blink interval in sleep (default 4s) |
| 19 | I2C_CONF_LOW_VOLTAGE | Low voltage threshold ×10 (255=disabled) |
| 20 | I2C_CONF_BLINK_LED | LED on duration in ms |
| 21 | I2C_CONF_POWER_CUT_DELAY | Power cut delay ×10 (default 70=7s) |
| 22 | I2C_CONF_RECOVERY_VOLTAGE | Recovery threshold ×10 (255=disabled) |
| 27-31 | Alarm1 (startup) | BCD: second, minute, hour, day, weekday |
| 32-36 | Alarm2 (shutdown) | BCD: second, minute, hour, day, weekday |
| 37 | I2C_CONF_RTC_OFFSET | RTC frequency offset |
| 38 | I2C_CONF_RTC_ENABLE_TC | Enable temperature compensation |
| 41 | I2C_CONF_IGNORE_POWER_MODE | Bypass DC-power check for LV detection |
| 42 | I2C_CONF_IGNORE_LV_SHUTDOWN | Bypass LV shutdown flag check |
| 47 | I2C_CONF_DEFAULT_ON_DELAY | Delay before auto-power-on |
| 48 | I2C_CONF_MISC | bit-0: disable alarm1 delay |
| 49 | I2C_CONF_GUARANTEED_WAKE | bit 0-6: duration, bit 7: 0=hours, 1=days |

## Pin Map (ATtiny841)

| Pin | Purpose |
|-----|---------|
| 0 | PIN_SYS_UP (input) / PIN_LED (output) — **dual-purpose, shared** |
| 1 | PIN_BUTTON — also connects to Pi GPIO-4 |
| 2 | PIN_I_SDA (internal I2C master to RTC + LM75B) |
| 3 | PIN_CTRL — drives MOSFET to power Pi |
| 4 | PIN_SDA (I2C slave to Pi) |
| 5 | PIN_TX_UP — listens to Pi GPIO-14 (UART TX) |
| 6 | PIN_SCL (I2C slave to Pi) |
| 10 | PIN_I_SCL (internal I2C master) |
| A1 | PIN_VIN (input voltage measurement) |
| A2 | PIN_VOUT (output voltage measurement) |
| A3 | PIN_VK (cathode/current measurement) |

## Build Notes

- Target: Arduino IDE with ATtinyCore
- MCU: ATtiny841 (Internal 8 MHz)
- Compiler: avr-gcc 7.3.0 (Arduino bundled)
- After firmware changes, clear Arduino cache before recompile:
  ```
  rm -rf ~/Library/Caches/arduino/sketches/B9FB2C30D023952A88D60B16DDA95D03/
  ```
