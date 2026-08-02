# Integration guide

How to consume this software from another project — how to reference it,
what to import, what to preserve on devices, and where the extension
points are.

> **History:** this repository is itself the product of such an import —
> the Witty-Pi-4 fork's `firmware-rev14` line became the visIOn
> `Software/wittypi/` runtime, deployed directly into
> `/home/pi/vision-service` (v5.37+). The camera-control module
> (`camera.sh`, v5.38+) was added on top.

## Referencing this repo from another project

Pick one, in order of preference:

1. **Pin a release tag** (recommended). Releases are tagged `vX.Y`
   matching `SOFTWARE_VERSION`. Source archive URL (stable, unauthenticated):
   `https://github.com/insideoutgrp/vision-service/archive/refs/tags/vX.Y.tar.gz`
2. **git submodule** — tracks this repo without copying code:
   `git submodule add https://github.com/insideoutgrp/vision-service vendor/vision-service`
   (then pin: `cd vendor/vision-service && git checkout vX.Y`)
3. **git subtree / vendor copy** — copy the tree in (the way this repo
   imported Witty-Pi-4). Keep the import commit verbatim, adapt in
   separate commits, and record the source tag in the commit message.

Devices themselves don't need any of this — they consume the repo
directly via the deploy one-liner:
```
curl -sSL https://raw.githubusercontent.com/insideoutgrp/vision-service/main/Software/deploy.sh | sudo bash
```
A parent project with its own fleet mechanism should instead replicate
the behaviours listed under "Rolling your own deploy" below.

## What to import

| Path | What it is | Import? |
|---|---|---|
| `Software/wittypi/` | The complete Pi-side runtime (bash, self-contained): power management, time sync, watchdogs, button→relay, **camera control (`camera.sh`, needs gphoto2)** | Yes — vendor as a unit; scripts resolve paths relative to their own directory |
| `Software/deploy.sh` | Remote updater (version-gated; atomic; migrates legacy layouts) | Yes, or replace with your own fleet mechanism (see "Rolling your own deploy") |
| `Software/install.sh` | Fresh-install: apt deps (i2c-tools, wiringPi, gphoto2), I2C enable, cron, init | Yes for new device provisioning |
| `Schedules/*.wpi` | Schedule catalogue (synced verbatim to devices) | Yes — this folder is the source of truth for device `schedules/` |
| `Firmware/WittyPi4/` + `Firmware/WittyPi4_v15/` | Canonical firmware source + flashable sketch | Only needed for flashing; not deployed to Pis |
| `README.md`, `CHANGELOG.md`, `docs/`, `Firmware/*.md` | Documentation | Recommended |

**Firmware requirement**: this software line (v5.x) requires Witty Pi
firmware Rev 14+ (check: `i2cget -y 1 0x08 12` → `0x0e`/`0x0f`). Devices
on older firmware stay on the legacy
[Witty-Pi-4](https://github.com/insideoutgrp/Witty-Pi-4) `main` branch
(v4.x line).

## Version conventions

- The single source of truth is `SOFTWARE_VERSION='x.y'` in
  `Software/wittypi/utilities.sh` (v5.x = rev14 line, v4.x = main line).
- `deploy.sh` compares this string for its already-up-to-date check —
  **any change you ship must bump it** or deployed devices will skip the
  update.
- `utilities.sh` must remain the **last** file in `UPDATE_FILES` (it carries
  the version; copying it earlier re-introduces the interrupted-deploy
  version-lock bug).
- Remote version check:
  `grep "SOFTWARE_VERSION" /home/pi/vision-service/utilities.sh`.
  Firmware revision: `i2cget -y 1 0x08 12`.

## Per-device state — never overwrite these

Deploys update code only. The following device files are state and must
survive any import/migration:

| File (in `/home/pi/vision-service/`) | Contents |
|---|---|
| `schedule.wpi` | The device's **active** schedule selection |
| `buttonRelay.conf` | Button→relay per-device config (auto-created; deploy never touches it) |
| `wittyPi.log`, `schedule.log` | Diagnostic history — the primary field forensics record |
| `cameraSettings.log`, `.camera_log_date` | Daily camera-settings snapshots (drift detection) and its once-per-day stamp |
| `.net_fail_count`, `.net_reboot_log` | Connectivity-watchdog state (failure counter, daily reboot cap) |
| `backup_v*/` | Pre-update script backups made by deploy |

## System integration surface

**Cron entries** (installed by deploy/install; re-installed idempotently):
```
*/15 * * * *      /home/pi/vision-service/syncTime.sh      >> .../wittyPi.log 2>&1
7,22,37,52 * * * * /home/pi/vision-service/checkInternet.sh >> .../wittyPi.log 2>&1
5,20,35,50 * * * * /home/pi/vision-service/camera.sh logsettings >> .../wittyPi.log 2>&1
```

**Shared resources** a parent project must respect:
- `/var/lock/wittypi.i2c.lock` — take this flock (LOCK_EX) around any I2C
  traffic your project adds on bus 1; every wittypi component honours it
- `/var/run/wittypi_daemon.pid`, `/var/run/wittypi_buttonrelay.pid`
- GPIO claims: BCM 4 (input only — never drive it), 13 (relay default —
  shared by the button watcher AND camera power, `camera.sh` reads the
  live pin level so external toggles are tolerated), 14 (UART must stay
  enabled), 17. Do not enable 1-Wire on BCM 4.
- I2C address `0x08` on bus 1 (plus RTC/sensor behind the MCU — never
  address them directly; use the virtual registers)
- The USB camera: gphoto2 claims it **exclusively**. The daily settings
  snapshot (cron `:05/:20/:35/:50`, first success of the day only)
  briefly claims it — a capture module running gphoto2 concurrently must
  tolerate a transient claim failure or coordinate around those minutes.

**Extension hooks** (empty user scripts, survive updates):
- `beforeScript.sh` — before the schedule engine runs at boot
- `afterStartup.sh` — after scheduling, before SYS_UP (keep it fast:
  on Rev 15 the firmware power-cycles a boot that takes >30 min to SYS_UP)
- `beforeShutdown.sh` — legacy hook; note that scheduled shutdowns are
  **hard power cuts** — do not rely on shutdown-time hooks for durable
  writes; design for crash-consistency instead

**Consuming the button→relay feature from an application**: rather than
parsing logs, either point `RELAY_PIN` at a GPIO your application reads, or
replace `fire_relay()` in `buttonRelay.sh` with a call into your stack. The
watcher guarantees single-instance, debounced, one-event-per-press
semantics.

**Log format**: `[YYYY-MM-DD HH:MM:SS] message` (Europe/London), appended to
`wittyPi.log`; angle brackets `<...>` mark entries written while the system
clock had just been set from the network. Grep keys used in the field:
`"ButtonRelay"`, `"Time sync"`, `"Internet check"`, `"daemon (v"`,
`"Schedule next"`, `"WARN"`, `"System starts up"`.

## Rolling your own deploy

If the parent project has its own fleet updater, replicate these behaviours
from `deploy.sh` — each one exists because its absence caused a field
incident:
1. Version gate on `SOFTWARE_VERSION` (skip when equal), version file last
2. Per-file `bash -n` syntax check; write to `.new` then `mv` (atomic)
3. Backup the previous scripts before replacing
4. Firmware gate: refuse v5.x software on firmware < Rev 14
5. Kill the old daemon **and** its background children (`runScript.sh`,
   `buttonRelay.sh`) before restarting
6. Sync `schedules/` to the catalogue, preserving `schedule.wpi`
7. Never let a failing post-step abort before cron entries are installed
8. Expect to be killed at any line (devices power off on schedule) — every
   step must be re-runnable

## Firmware flashing (bench only)

Rev 15 cannot be flashed remotely. Sketch: `Firmware/WittyPi4_v15/`;
programmer USBasp via ATTinyCore with the **exact board menu in that
folder's README** (Counterclockwise pin mapping and millis-disabled are
mandatory). After flashing, deploy the `firmware-rev14` branch software.
The v5.x software runs correctly on Rev 14 (`0x0E`) and Rev 15 (`0x0F`);
Rev 15 closes the remaining hung-boot / wedged-bus / torn-write failure
classes (see CHANGELOG).

## Support knowledge worth keeping

- `wittyPi.log` is the diagnostic backbone: every subsystem logs every
  decision, including why something *didn't* run.
- The field-debugging history (what failed, why, and the fix) is preserved
  in [CHANGELOG.md](../CHANGELOG.md) and in unusually verbose commit
  messages — `git log` on either branch reads as an incident journal.
- Known-residual limitations are listed at the end of
  [ARCHITECTURE.md](ARCHITECTURE.md) and in the Rev 15 README.
