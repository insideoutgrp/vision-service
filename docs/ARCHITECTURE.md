# Architecture

System design reference for the Inside Out Group Witty Pi 4 stack. For the
firmware register map and pin map see
[`Firmware/PROJECT_CONTEXT.md`](../Firmware/PROJECT_CONTEXT.md).

## System overview

```
             DC in (up to 30 V)
                   |
        +----------v-----------+           +---------------------------+
        |  Witty Pi 4 HAT      |  5 V out  |  Raspberry Pi             |
        |  ATtiny841 firmware  +----------->  Raspberry Pi OS          |
        |  PCF85063A RTC (UTC) |  (PIN_CTRL)  wittypi shell software   |
        +--+----------------+--+           +--+---------------------+--+
           |    I2C 0x08    |                 |                     |
           +<---------------)------ bus 1 ----+  daemon.sh (boot)   |
                            |                    runScript.sh       |
     button ----+-----------+                    syncTime.sh (cron) |
                |  (shared line)                 checkInternet.sh   |
                +------------------- BCM 4 ----> buttonRelay.sh ----+--> relay (BCM 13)
```

- The **HAT is the sole power source** for the Pi. The ATtiny firmware
  decides when 5 V is applied (alarm1/startup) and cut (alarm2/shutdown).
- The Pi side is **pure bash**, communicating with the firmware over I2C
  (address `0x08`, bus 1) via `i2cget`/`i2cset` wrappers with retries.
- The RTC stores **UTC**. All human-facing times and schedule maths use
  `LOCAL_TZ='Europe/London'` (hard-coded; this fleet is UK-only).

## Components (Software/wittypi/)

| File | Role | Runs |
|---|---|---|
| `utilities.sh` | Shared library: I2C wrappers, alarm get/set (day-first writes), time sync, alarm validation, constants, `SOFTWARE_VERSION` | sourced by everything |
| `daemon.sh` | Boot orchestrator: time sync, reliability registers, alarm validation, spawns schedule engine + watcher, pulses SYS_UP | once per boot (init) |
| `runScript.sh` | Schedule engine: parses `schedule.wpi`, computes next shutdown (alarm2) + startup (alarm1), DST-corrected, writes them to the HAT | per boot (async from daemon), or from the menu |
| `syncTime.sh` | Network→system→RTC time sync | cron `*/15` |
| `checkInternet.sh` | Connectivity watchdog: 3 consecutive failures → reboot (capped 2/day, 30-min uptime gate) | cron `:07/:22/:37/:52` |
| `buttonRelay.sh` | Button (BCM 4) → relay (default BCM 13) watcher; per-device `buttonRelay.conf` | daemon-spawned, detached, single instance |
| `camera.sh` | Canon DSLR (1300D/2000D) parameter control via gphoto2: relay power-up → USB detect → get/set with verify; focus-square selection (3×3 grid, resolution-aware); shutter count; daily settings snapshot → `cameraSettings.log` | manual / scripted / cron `:05/:20/:35/:50` (date-guarded) |
| `autoUpdate.sh` | Daily self-update: probes the published `SOFTWARE_VERSION` on GitHub (raw utilities.sh) and runs the standard deploy when it differs; per-device `autoUpdate.conf` opt-out | cron `:12/:27/:42/:57` (date-guarded) |
| `wittyPi.sh` | Interactive menu (schedule choice, times, config) | manual |
| `beforeScript.sh` / `afterStartup.sh` / `beforeShutdown.sh` | User extension hooks | daemon boot sequence |
| `schedules/` | Deployed `.wpi` schedule catalogue (synced by deploy) | — |

Deployment: `Software/deploy.sh` (remote one-liner) and
`Software/install.sh` (fresh install). Both update the same file list with
per-file syntax checks; `utilities.sh` is copied last (version carrier).

## Boot sequence

1. Firmware applies power (alarm1 match, DEFAULT_ON on power connect,
   button wake, or Guaranteed Wake).
2. OS boots; init starts `daemon.sh`, which:
   1. takes the shared I2C flock (bounded 30 s wait)
   2. syncs time: network (HTTPS `Date:` + NTP re-enable) → RTC; falls back
      to RTC→system when offline; never writes an unsynced clock into the RTC
   3. writes reliability registers: Guaranteed Wake 24 h (reg 49),
      `IGNORE_LV_SHUTDOWN=0`, DEFAULT_ON=1, `RECOVERY_VOLTAGE=255`
      (L3V7 variant: 1)
   4. validates the shutdown alarm (log-only for stale; firmware suppression
      + rewrite handle it)
   5. logs the wake reason (reg 11)
   6. runs `beforeScript.sh`, spawns `runScript.sh 0 revise` (async, lock fd
      closed), runs `afterStartup.sh`
   7. pulses **SYS_UP** (GPIO 17) — tells the firmware the boot completed
      (arms TXD shutdown detection; disarms the Rev 15 boot watchdog)
   8. spawns `buttonRelay.sh` via `setsid` (detached) and exits
3. `runScript.sh` computes and writes the next alarm pair.

## Alarm lifecycle

- Alarms live in HAT registers 27–31 (alarm1/startup) and 32–36
  (alarm2/shutdown), BCD, **UTC**, day-of-month + h/m/s (no month).
- The firmware's 1 Hz watchdog tick compares day-relative timestamps with a
  **backward 86400 s match window** (Rev 13+; 4 s on older revisions), so a
  wake missed by seconds or hours still fires the same day.
- `ALARM{1,2}_TRIGGERED` flags (regs 9/10) suppress refire; cleared when an
  alarm block is rewritten. **Writes are day-register-first** on the Pi side
  so a torn write is never an in-window value; Rev 15 firmware additionally
  holds alarm evaluation for ~5 s around any alarm-register write.
- Shutdowns are **hard power cuts** (no OS shutdown handshake): alarm2/LV
  set `turningOff` and fire Timer1 within milliseconds. OS-initiated
  shutdowns/reboots are detected via the TXD line (with multi-sample reboot
  grace on Rev 15).

### Schedule format (`.wpi`)

```
BEGIN 2022-01-03 07:00:00      # local wall-clock anchor
END   2030-01-01 00:00:00
ON    H4 M45                   # durations: D/H/M/S
OFF   M15
```
The engine walks cycle boundaries from BEGIN; for daily/weekly cycles
(multiple of 24 h) each boundary is DST-corrected so ON/OFF times stay at
the same *local* wall-clock time year-round. Sub-daily test schedules run
in raw time. A `WAIT` suffix defers that alarm to external control.

## Time handling

| Mechanism | Detail |
|---|---|
| RTC | Stores UTC; validated field-by-field on read; never written from an unverified source |
| Network sync | HTTPS `Date:` header from `https://www.google.com` (middlebox-cache-proof), 15 s/25 s curl timeouts for 3G |
| NTP | systemd-timesyncd re-enabled after every manual `date -s` (bracket pattern) |
| DST | `dst_correct()` shifts daily/weekly alarm epochs by the BEGIN-vs-alarm UTC-offset delta; boundary *selection* also compares corrected times |
| Fallbacks | Offline boot: RTC→system. RTC unreadable: keep current clock. Bad RTC + no net: system→RTC (best effort) |

## Reliability mechanisms (defence in depth)

| Layer | Mechanism | Recovers from |
|---|---|---|
| Firmware | Guaranteed Wake (reg 49, 24 h; Rev 15 enforces floor) | any lost alarm while asleep |
| Firmware | DEFAULT_ON enforced every boot | any power interruption |
| Firmware Rev 15 | SYS_UP boot watchdog (30 min → power-cycle, reason `0x0d`) | Pi hangs before daemon runs (previously: powered-but-dead forever) |
| Firmware Rev 15 | `alarmWriteHold` | torn alarm rewrites firing stale alarms |
| Firmware Rev 15 | `I2C_TIMEOUT` on internal bus | wedged RTC bus hard-bricking the MCU |
| Pi | day-first alarm writes + firmware-matched validation + `now+1h` fallbacks | torn/failed writes, garbage reads |
| Pi | shared flock (`/var/lock/wittypi.i2c.lock`) across all I2C users | bus contention retry storms |
| Pi | connectivity watchdog reboot (capped) | hung network stack / modem |
| Pi | GW-wake return-to-sleep | battery drain from backstop wakes mid-OFF-window |

Known residuals (accepted, documented): day-of-month alarm matching cannot
catch up an alarm missed **on the last day of a month** (bounded to ≤1 lost
day by Guaranteed Wake); firmware flash is at 8188/8192 bytes.

## Concurrency model

- **One lock**: `/var/lock/wittypi.i2c.lock` (world-writable; read-fd
  fallback for legacy perms). Daemon (30 s wait), runScript (120 s wait),
  cron jobs (`-n`, skip politely), all serialised.
- Cron jobs additionally gate on 60 s uptime to stay out of the boot window.
- Pidfiles: `/var/run/wittypi_daemon.pid`, `/var/run/wittypi_buttonrelay.pid`
  (watcher enforces single instance with a cmdline-verified kill).

## GPIO map (BCM)

| BCM | Direction | Use |
|---|---|---|
| 2/3 | — | I2C bus 1 (HAT at 0x08) |
| 4 | in | Push button (shared with MCU); watched by `buttonRelay.sh`. Keep 1-Wire off this pin |
| 13 | out | Relay output (default; configurable in `buttonRelay.conf`; physical pin 33). Feeds the camera's power coupler — `camera.sh` drives it high before any gphoto2 traffic |
| 14 | — | UART TXD — firmware watches it for OS shutdown/reboot detection (keep `enable_uart=1`) |
| 17 | out (pulsed) | SYS_UP handshake to firmware |
| 5/6 | in | L3V7 battery variant only (charge/standby status) |

## Firmware build (Rev 15)

ATtiny841 via ATTinyCore, **exact settings required** (see
[`Firmware/WittyPi4_v15/README.md`](../Firmware/WittyPi4_v15/README.md)):
Counterclockwise pin mapping, Slave-Only wire mode, millis/micros disabled,
8 MHz internal (Vcc < 4.5 V), LTO on. `I2C_FW_REVISION` reads `0x0F`.
