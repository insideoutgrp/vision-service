# Changelog

Two Pi-software version lines are maintained in lockstep:

- **v5.x** — requires firmware Rev 14+; from v5.37 this line lives in the
  **visIOn** repository (previously branch `firmware-rev14` of Witty-Pi-4)
- **v4.x** — firmware-agnostic (Rev 7+); remains on branch `main` of the
  legacy Witty-Pi-4 repository

Where a fix applies to both, the pair is listed together. Firmware revisions
have their own section at the end. Dates are commit dates.

---

## Pi software

### deploy.sh connector healing — 2026-08-10
(No SOFTWARE_VERSION bump: deploy-script-only change, fetched fresh each run.)
Enrolled device with connector code present but service not running (e.g. a
migration stopped the legacy agent without the new unit starting, or an
interrupted deploy) is now healed in the idempotent pre-version-gate block —
previously a deploy re-run exited "already at vX.Y" before the connector
block and could not repair this state.

### v5.44 — 2026-08-10
**Connector 2.1: snapshot timestamp in telemetry.** The camera settings dict
now includes `snapshot_at` (the `[...]` timestamp of the cameraSettings.log
line it came from), so UIs can show how fresh the displayed settings are —
"unknown values from a fresh read" and "stale snapshot" are no longer
indistinguishable.

### v5.43 — 2026-08-10
**The connector — iovision fleet module ships with the runtime**
(`Software/connector/` → `/home/pi/vision-service/connector/`). The iovision
management agent (telemetry, command queue: schedules/camera/logs) moves into
this repository and rides the standard update channel — deploy.sh/autoUpdate.sh
update it with the same atomic `.new` + syntax-gate rules (python files gated
with `py_compile`). This retires the agent's separate `update_agent` mechanism
(one field-hardened update path instead of two; the connector rejects the old
command with a pointer here).
- **Code on every device, running only where enrolled**: the connector starts
  solely where `/etc/iovision/config.yaml` exists. Enrolment (from the iovision
  dashboard) writes credentials and enables `vision-connector.service` — code
  is already present via auto-update, so enrolling is a config-drop.
- Deploy migrates pre-v5.43 enrolled devices automatically: legacy
  `iovision-agent.service` + `iovision/` dir retired, connector service
  installed and (re)started.
- New deps: `python3-requests`, `python3-yaml` (apt; installed by both
  install.sh and deploy.sh).

### v5.42 — 2026-08-09
**Camera snapshot state files writable by both writers.** `cameraSettings.log`
and `.camera_log_date` are written by the root cron AND by operator/agent runs
as `pi`; whichever created the file first locked the other out ("Permission
denied" on every append — field report: agent-triggered `logsettings` printed
its success message while the snapshot line silently failed to land, and the
snapshot only refreshed when the root cron happened to run). `settings_log_line`
and the new `stamp_today` helper now `chmod 666` the files after writing (owner-
only op, failure ignored) — same philosophy as the world-writable I2C lock.

### install.sh source validation — 2026-08-06
(No SOFTWARE_VERSION bump: changes the installer only; fresh installs fetch
it from main directly, deployed devices are unaffected.)
- `install.sh` now verifies its source tree is a genuine visIOn v5 tree
  (`utilities.sh` + `camera.sh` + `autoUpdate.sh`) before copying. Previously,
  piping the script from curl on a device with a legacy `~/wittypi` install
  resolved `SRC_DIR` to the caller's cwd and **silently installed the old v4
  tree as the runtime** (field report: chmod failures on the v5-only files,
  no schedules synced).
- With no valid local source (the curl-pipe fresh-install case), it downloads
  main from GitHub to a temp dir and re-execs from there — making
  `curl -sSL .../Software/install.sh | sudo bash` a genuine one-liner.
  Download failure aborts loudly; nothing is installed.

### v5.41 — 2026-08-02
**Shutter count + fleet auto-update.**
- `camera.sh shuttercount` reads the body's shutter actuation count
  (`/main/status/shuttercounter`); also shown in `camera.sh status` and
  the interactive-menu header, and recorded in every daily
  `cameraSettings.log` snapshot (excluded from CHANGED detection, like
  battery — wear is tracked by the daily line itself, giving frames/day
  straight from the log).
- **`autoUpdate.sh`**: devices now update themselves when a new version is
  published (= a bumped `SOFTWARE_VERSION` pushed to `main`). Cron
  attempts at :12/:27/:42/:57, date-stamped to one completed check per
  day (an offline check does not stamp — it retries next tick, so short
  wake windows still get their daily check). The remote version is probed
  by fetching raw `utilities.sh` (~30 KB); the full deploy only runs when
  versions differ, downloaded to a temp file and syntax-checked first —
  never piped from the network. deploy.sh's own version gate, atomicity
  and interrupt-safety make a mid-update power cut recoverable.
  Per-device opt-out: `AUTO_UPDATE=0` in `autoUpdate.conf`. Manual:
  `autoUpdate.sh force`.
- Note: devices at ≤ v5.40 need **one final manual deploy** to receive
  the auto-updater; from then on updates are automatic.

### v5.40 — 2026-07-31
**Daily camera-settings snapshot** (`camera.sh logsettings` + cron): one
compact `key='value'` line per day in a separate **`cameraSettings.log`**
so drift in camera/lens settings is visible over time (lens swap, knocked
mode dial, changed ISO…).
- Snapshot covers model, **lens name**, all 12 parameters, and battery
  level; when any value (battery excluded — it always drifts) differs from
  the previous snapshot, a `CHANGED` line names the keys and old→new
  values, mirrored into wittyPi.log.
- Cron attempts at :05/:20/:35/:50 with a date stamp
  (`.camera_log_date`, Europe/London): devices wake on schedule, so a
  fixed daily time would miss short wake windows; after the day's
  snapshot every further tick is a no-op statefile read. 60 s uptime gate
  keeps it out of the boot window.
- Power-state restore: if the camera was off, it is powered off again
  after the read — the logger never leaves the camera drawing power.
- Failure handling: camera absent / gphoto2 missing writes one WARN line
  and still stamps the day (no hourly relay cycling on a dead camera).
- `cameraSettings.log` + `.camera_log_date` are per-device state (deploys
  never touch them).

### v5.39 — 2026-07-31
**Focus square selection** (`camera.sh focus <point> [af]`, plus an
interactive-menu entry): moves the liveview focus square via
`eoszoomposition=x,y`.
- The coordinate space is the full sensor frame, so the grid is **computed
  from the attached body's frame size**, never hard-coded: explicit
  `CAMERA_FRAME_W/H` override (buttonRelay.conf) > model lookup
  (1300D/T6 = 5184×3456, 2000D/T7 = 6000×4000) > logged 1300D fallback.
- Nine named points on a 3×3 grid at 1/6, 1/2, 5/6 of the frame:
  top/middle/bottom × left/centre/right (e.g. centre on a 1300D =
  2592,1728; on a 2000D = 3000,2000).
- Liveview (`viewfinder=1`) is raised around the operation — the EOS only
  accepts a position while liveview is up — and dropped afterwards
  (mirror down). Optional `af` argument drives autofocus at the new point
  (`autofocusdrive=1`), with MF/no-lock failure reported.
- `camera.sh focus` with no arguments prints the detected frame size and
  the computed coordinates of all nine points.

### v5.38 — 2026-07-31
**Camera control module** (`camera.sh`): view and change capture parameters
on the attached Canon DSLR (EOS 1300D / 2000D) over USB via gphoto2 —
interactive menu plus a scriptable CLI (`status` / `list` / `get` / `set` /
`on` / `off`).
- Parameters: iso, aperture, shutter, expcomp, wb, format, metering,
  style, drive, focusmode, target, aemode. Choices are read **live from
  the camera** (aperture depends on the fitted lens), never hard-coded;
  read-only parameters (e.g. the exposure mode dial) are reported, not
  half-applied; every set is verified by read-back and logged.
- Camera power: the camera is fed through the button→relay watcher's relay
  (BCM 13 = wPi 23, from `buttonRelay.conf`; `CAMERA_RELAY_PIN` overrides).
  Before any gphoto2 command the relay is energised and the script waits
  (≤25 s) for the camera to enumerate on USB (`lsusb`, Canon vendor
  `04a9`), then confirms `gphoto2 --auto-detect` sees it. Power is left ON
  after CLI get/set so scripted sequences don't power-cycle the camera per
  command; `camera.sh off` releases the relay.
- All gphoto2 invocations run under `timeout` (wedged PTP session guard);
  gvfs gphoto2 volume monitors are released before claiming the camera.
- `gphoto2` added to install.sh deps; deploy.sh also installs it on update
  for devices provisioned before v5.38.

### v5.37 — 2026-07-31 (first visIOn release)
Imported into the **visIOn** IoT endpoint management service as its
power-management module. Packaging/layout only — **no runtime behaviour
changes**; all scripts are self-locating and unchanged apart from the
version string.
- Install target moved from `/home/pi/wittypi` to `/home/pi/vision-service`
  (`VISION_HOME` service root = run directory, runtime installed directly in
  it; future modules sit in subfolders alongside)
- `deploy.sh` retargeted at the visIOn repository (`main` branch) and now
  **migrates previous-layout installs automatically** (`/home/pi/wittypi`
  and the interim `/home/pi/vision/wittypi`): legacy
  daemon and children stopped (by pidfile and by path), full-tree copy
  preserves all per-device state (`schedule.wpi`, `buttonRelay.conf`, logs,
  `.net_*` watchdog state, hooks, backups), and the legacy install is
  **removed** after the copy is diff-verified (kept as
  `wittypi.pre-vision` only if verification fails); leftover remnants are
  reported for manual attention
- `/etc/init.d/wittypi` **and the cron entries** (time sync + connectivity
  watchdog) are regenerated idempotently on every deploy, before the
  version gate — a migrated or interrupted device is healed even when the
  software version is already current (previously stale legacy-path cron
  entries would have silently disabled time sync and the watchdog)
- `install.sh` anchors at `$VISION_HOME` regardless of invocation directory
- Upstream UUGear Web Interface (UWI) install step removed from `install.sh`
  — headless field devices; third-party curl-to-bash at provisioning was
  unwanted
- Lock (`/var/lock/wittypi.i2c.lock`), pidfiles, cron entries, log formats
  and the `/etc/init.d/wittypi` service name are unchanged

### v5.36 / v4.52 — 2026-07-31
Button-relay watcher hardening after field test: spawned via `setsid` with
stdin detached (immune to service-manager session teardown after the daemon
exits); unconditional startup breadcrumb and a log line on **every** exit
path, so a missing watcher is diagnosable from wittyPi.log alone; pid-reuse
guard — the single-instance kill now verifies `/proc/<pid>/cmdline` before
killing (a stale pidfile after reboot usually points at an innocent process).

### v5.35 / v4.51 — 2026-07-31
Fix "toggles logged but pin unchanged": watcher instances accumulated across
daemon restarts/deploys and each toggled the relay per press — two instances
cancel out. Pidfile-based single instance (newest replaces oldest);
deploy.sh kills the old watcher on update; toggle/pulse log lines now name
the pin and level.

### v5.34 / v4.50 — 2026-07-31
Relay default corrected to **BCM 13** (physical pin 33) — the requested
"gpio 23" was wiringPi numbering (wPi 23 = BCM 13). Untouched auto-created
configs from v5.32/v5.33 migrate to the new defaults; edited configs are
never touched.

### v5.33 / v4.49 — 2026-07-30
Button-relay watcher **enabled by default on firmware Rev 14+**
(`ENABLE_BUTTON_RELAY=auto`): auto-on when the firmware reports Rev 14+,
stays off (with explanatory log) on ≤ Rev 13 where the MCU pulses the button
line during alarm shutdowns. Explicit 1/0 force per device.

### v5.32 / v4.48 — 2026-07-30
**New feature: button→relay watcher** (`buttonRelay.sh`). The push button is
hardwired to BCM GPIO-4 and unused while the Pi runs on Rev 14+ firmware —
presses now drive a configurable relay GPIO (toggle or timed pulse,
active-high/low). Per-device `buttonRelay.conf` is auto-created and never
overwritten by deploys. No firmware change needed.

### v5.31 / v4.47 — 2026-07-07
Time sync over **HTTPS** (`https://www.google.com`). Field log showed the
clock stepping backwards ~15 min right after a "successful" sync: carrier
proxies on 3G can serve cleartext HTTP responses from cache with a stale
`Date:` header. TLS responses cannot be cached by middleboxes.

### v5.30 / v4.46 — 2026-07-06
I2C lock file permissions: root-created 644 lock made non-root `wittyPi.sh`
menu runs fail with "Permission denied / Bad file descriptor" and skip
locking. Lock is now created world-writable by root; a read-only fd fallback
covers pre-existing root-owned files (flock takes LOCK_EX on read fds).

### v5.29 / v4.45 — 2026-07-05 (with firmware Rev 15 on `firmware-rev14`)
**Downtime-hardening release** — fixes every confirmed finding of the
2026-07 multi-agent IoT downtime review:
- Alarm registers written **day-first**: torn rewrites are future-dated for
  daily schedules on Rev 14 (which clears its suppression flag on the first
  byte of a rewrite — the root cause of mid-boot power-cut "boot flapping")
- `verify_alarm_in_future` rewritten with firmware-matched day-of-month
  semantics; shutdown alarms log-only (never cleared); never acts on
  unreadable registers; `_parse_alarm_to_epoch` resolves nearest occurrence
  with real month lengths (verified incl. leap February)
- I2C read failures no longer silently become 0 via command substitution;
  RTC/alarm getters validate every register; `rtc_to_system` refuses an
  unreadable RTC
- daemon/runScript take the shared I2C flock; daemon spawns runScript with
  the lock fd closed
- `system_to_rtc` only runs after network time actually applied (stale
  fake-hwclock time can no longer clobber a correct RTC)
- Guaranteed-Wake wakes landing mid-OFF-window return to sleep after 5 min
  instead of staying up through the next cycle (~48 h on weekend-off
  schedules)
- Schedule engine: zero-cycle-duration guard (malformed schedules no longer
  kill the engine via division by zero with no alarms written)
- checkInternet: `grep -c` daily-cap quirk fixed
- deploy/install: `utilities.sh` (version carrier) copied **last** so an
  interrupted deploy can't lock in a mixed install; syncTime call no longer
  aborts deploy under `set -e` before cron install

### v5.28 / v4.44 — 2026-06-10
Fix time sync never correcting >1 h drift: `rtc_to_system` disabled NTP
persistently (`timedatectl set-ntp 0` with no re-enable) after any offline
boot; both manual clock-set paths now bracket with disable/enable. curl
connect timeouts 3 s → 15 s (+ `--max-time 25`) for 3G links.

### v5.27 / v4.43 — 2026-06-07
Fix BST scheduler picking an already-passed boundary on daily schedules:
boundary selection now compares DST-corrected times (with 60 s slack). Was
costing one hour of downtime at every cycle boundary during BST (invisible
in GMT).

### v5.26 / v4.42 — 2026-05-28
Cron PATH fix: cron runs with `PATH=/usr/bin:/bin`, missing `i2cdetect`
(`/usr/sbin`) — syncTime/checkInternet silently no-opped on every tick.
`firmware-rev14` additionally shipped firmware patch 5.28e (sticky
`turnOffFromTXD` — see firmware section).

### v5.25 / v4.41 — 2026-05-28
Cron boot-window safeguards: 60 s uptime gate + shared flock for cron I2C
jobs; 60 s floor on computed shutdown alarms. (`firmware-rev14` also shipped
firmware patch 5.28d — TXD boot-glitch guard + stale-alarm2 suppression.)

### v5.24 / v4.40 — 2026-05-28
Stop firmware auto-waking after scheduled shutdown: cleared
`IGNORE_LV_SHUTDOWN`, set `RECOVERY_VOLTAGE=255` (non-L3V7). A scheduled
sleep previously looked like a power cycle (immediate LV-recovery wake).

### v5.23 — 2026-05-28 (`firmware-rev14` only)
Reverted the ALARM2_TRIGGERED sleep-preservation experiment (blocked the
next scheduled shutdown whenever the daemon didn't rewrite alarm2).

### v5.22 / v4.39 — 2026-05-28
Only clear **stale** shutdown alarms at boot; valid future alarms preserved
(unconditional clearing made scheduled shutdowns fail on WAIT/ended/parse
paths).

### v5.21 / v4.38 — 2026-05-28
First round of field bug fixes post-Rev 14: gpio-shutdown overlay stripped
from boot config, reboot-loop prevention.

### v5.20 / v4.37 — 2026-05-28
Schedule sync on deploy: device `schedules/` folder made to exactly match
the repo set (obsolete files deleted, new added, changed updated; the active
`schedule.wpi` selection always preserved).

### v5.0 — 2026-05-26 (`firmware-rev14` branch created)
Firmware Rev 13 + matching Pi software. Branch split: `main` stays
firmware-agnostic.

### v4.36 — 2026-05-26
Phase-1 reliability backstops (firmware-agnostic): Guaranteed Wake written
every boot, DEFAULT_ON, alarm validation and fallbacks, tzdata check.

### v4.35 … v4.23 — 2026-04/05 (pre-split lineage)
- v4.35/v4.34: schedule catalogue curation (two new schedules; duplicate
  removed)
- v4.33: ping timeout raised for 3G devices
- v4.32: internet connectivity watchdog with auto-reboot (rate-limited)
- v4.31–v4.29: DST correction limited to daily/weekly schedules; DST drift
  fixes; network-first time sync at boot
- v4.28/v4.27: periodic network time sync via cron (15 min)
- v4.26: custom schedules added to deployment
- v4.25: GPIO-4 soft shutdown removed — hardware cuts power directly
- v4.24: **DST handling for Europe/London** (RTC stores UTC; display/
  schedule in local time) — the fork's founding change
- v4.23: network timestamp extraction hardening
- plus: one-liner remote deploy script; fresh-install fix (#2)

---

## Firmware (ATtiny841, branch `firmware-rev14`)

| Rev | I2C id | Date | Summary |
|---|---|---|---|
| **15** | `0x0F` | 2026-07-05 | Downtime-hardening: `alarmWriteHold` (pauses alarm evaluation during register rewrites — kills the torn-rewrite mid-boot power cut); SYS_UP boot watchdog (30 min, reason `0x0d` — a hung boot is power-cycled instead of holding power forever); atomic `sleep()` entry (lost-wake race); Guaranteed Wake floor (reg 49 forced to 24 h if 0); `I2C_TIMEOUT=20 ms` on the internal soft-I2C (wedged RTC bus can no longer hard-brick the MCU); TXD reboot detection re-samples ×4 (~28 s); `delay()` int16 overflow fix; EEPROM wear fix (telemetry regs no longer persisted); `alarm1Delayed` reset paths. Build now **requires** `wiremode=slave` + `millis=disabled` + **Counterclockwise pin mapping**; 8188/8192 bytes. Known residual: day-of-month alarm matching can't catch up an alarm missed on the last day of a month (bounded to ≤1 day by the GW floor). |
| **14** | `0x0E` | 2026-05-28 | Physical button shutdown removed entirely (button wakes from sleep only; firmware never touches the shared button/GPIO-4 line). Patches b–e (2026-05/06): b — revert ALARM2 sleep-preservation; c — RECOVERY_VOLTAGE default back to 255 (was auto-waking after every scheduled shutdown); d — TXD boot-glitch guard (`systemIsUp` required before TXD-low means shutdown) + stale-alarm2 suppression at wake; e — sticky `turnOffFromTXD` cleared in the Timer1 reboot branch (a detected reboot previously disabled all subsequent alarm2/LV power cuts). |
| **13** | `0x0D` | 2026-05-26 | Field-reliability release: `sleep()` moved out of Timer1 ISR (`pendingSleep`); `internalBusBusy` mutex; alarm catch-up window 4 s → 86400 s; DEFAULT_ON enforced every boot ("any power input wakes"); dormant temperature-action + sleep-LED code removed for flash headroom. |
| **12** | `0x0C` | 2026-04-14 | Deterministic power-cut delay (Timer1 reset on all shutdown paths); WDT turningOff timeout removed; dummy-load pulsing removed. |
| **11** | `0x0B` | 2026-04-11 | Button disabled from initiating shutdown while running; LV grace period 180 s → 250 s; several alarm/BCD/SYS_UP fixes (window 2 s → 4 s, `copyAlarm` 5th register, LED/SYS_UP shared-pin retry). |
| **10** | `0x0A` | 2026-04-11 | WDT-based turningOff safety timeout (36 s) against power-never-cut deadlock. |
| **7** | `0x07` | 2024-06 | Upstream baseline imported into this repo. |

Sketch folders: current = `Firmware/WittyPi4_v15/` (canonical source
`Firmware/WittyPi4/WittyPi4.ino`); previous revisions retrievable from git
history (`Firmware/WittyPi4_v14/` was removed at Rev 15).
