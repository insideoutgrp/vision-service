#!/bin/bash
# file: deploy.sh
#
# One-liner deployment script for the visIOn Witty Pi runtime.
# Run on a Pi with:
#   curl -sSL https://raw.githubusercontent.com/insideoutgrp/vision-service/main/Software/deploy.sh | sudo bash
#
# Installs/updates the runtime at /home/pi/vision-service (the run
# directory IS the service root - no nested wittypi/ folder). Devices on a
# previous layout (/home/pi/wittypi, or the interim /home/pi/vision/wittypi)
# are migrated automatically: all per-device state (schedule.wpi,
# buttonRelay.conf, logs, watchdog state) is carried over, cron entries and
# /etc/init.d/wittypi are repointed, and the old install is removed once
# the copy is verified.
#

set -e

if [ "$(id -u)" != 0 ]; then
  echo 'Sorry, you need to run this script with sudo'
  exit 1
fi

# NOTE: must match where this repository is hosted
REPO_URL="https://github.com/insideoutgrp/vision-service"
BRANCH="main"
MIN_FW_REVISION=14   # firmware Rev 14 required for v5.1+ Pi software
TMP_DIR=$(mktemp -d)

# Sync $src_dir/*.wpi into $dst_dir/, exactly:
#   - removes .wpi files on device not present in source
#   - adds source files not on device
#   - updates files whose content differs
#   - preserves schedule.wpi (the user's active selection)
sync_schedules() {
  local src_dir="$1"
  local dst_dir="$2"
  if [ ! -d "$src_dir" ]; then
    echo '  No source schedules directory found, skipping.'
    return 0
  fi
  mkdir -p "$dst_dir"
  local added=0 updated=0 removed=0 unchanged=0
  # Phase 1: remove device schedules not in source (skip active schedule.wpi)
  if [ -d "$dst_dir" ]; then
    for existing in "$dst_dir"/*.wpi; do
      [ -e "$existing" ] || continue
      local name=$(basename "$existing")
      [ "$name" = "schedule.wpi" ] && continue
      if [ ! -f "$src_dir/$name" ]; then
        rm -f "$existing"
        echo "  Removed: $name"
        removed=$((removed + 1))
      fi
    done
  fi
  # Phase 2: add or update from source
  for src in "$src_dir"/*.wpi; do
    [ -e "$src" ] || continue
    local name=$(basename "$src")
    if [ -f "$dst_dir/$name" ]; then
      if ! cmp -s "$src" "$dst_dir/$name"; then
        cp "$src" "$dst_dir/$name"
        echo "  Updated: $name"
        updated=$((updated + 1))
      else
        unchanged=$((unchanged + 1))
      fi
    else
      cp "$src" "$dst_dir/$name"
      echo "  Added:   $name"
      added=$((added + 1))
    fi
  done
  echo "  Total: $added added, $updated updated, $removed removed, $unchanged unchanged."
}

echo '================================================================================'
echo '|                                                                              |'
echo '|          visIOn - Witty Pi runtime (Rev14+ firmware) - Remote Deploy         |'
echo '|                                                                              |'
echo '================================================================================'
echo ''
echo 'This software requires firmware Revision 14 or later. Devices still on'
echo 'older firmware must use the legacy Witty-Pi-4 "main" branch instead.'
echo ''

# Pre-flight firmware version check
if command -v i2cget >/dev/null 2>&1; then
  fw_hex=$(i2cget -y 1 0x08 12 2>/dev/null || echo "")
  if [ -n "$fw_hex" ]; then
    fw_rev=$((fw_hex))
    if [ "$fw_rev" -lt "$MIN_FW_REVISION" ]; then
      echo "ERROR: detected firmware Rev ${fw_rev} - this branch requires Rev ${MIN_FW_REVISION}+."
      echo "       Use the main branch instead:"
      echo "         curl -sSL https://raw.githubusercontent.com/insideoutgrp/Witty-Pi-4/main/Software/deploy.sh | sudo bash"
      exit 1
    fi
    echo ">>> Firmware Rev ${fw_rev} detected - OK."
    echo ''
  fi
fi

# resolve the visIOn service root for the target (non-root) user
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
  TARGET_HOME='/home/pi'
fi
VISION_HOME="${VISION_HOME:-$TARGET_HOME/vision-service}"

# download the repo
echo ">>> Downloading from $REPO_URL"
wget -q "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" -O "$TMP_DIR/vision.tar.gz" || {
  echo 'Error: Failed to download. Check your internet connection.'
  rm -rf "$TMP_DIR"
  exit 1
}
tar -xzf "$TMP_DIR/vision.tar.gz" -C "$TMP_DIR"
# the tarball's top-level directory is <repo-name>-<branch>; derive it rather
# than hard-coding the repo name
SRC_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)/Software"
if [ ! -f "$SRC_DIR/wittypi/utilities.sh" ]; then
  echo 'Error: downloaded archive does not contain Software/wittypi.'
  rm -rf "$TMP_DIR"
  exit 1
fi
echo '  Done.'
echo ''

# migrate a previous-layout installation into the visIOn layout. Two known
# prior layouts: /home/pi/wittypi (original) and /home/pi/vision/wittypi
# (interim). Full-tree copy so all per-device state (schedule.wpi,
# buttonRelay.conf, logs, .net_* watchdog state, hook scripts, backups)
# carries over; the normal update path below then brings the scripts to the
# target version. After a verified copy the legacy install is REMOVED so
# nothing can ever launch or write to the old path again. Re-runnable: once
# $VISION_HOME holds a runtime the block is skipped.
# candidate legacy locations (deduplicated - the pairs collapse to one path
# when the target user is pi)
LEGACY_CANDIDATES="$TARGET_HOME/vision/wittypi $TARGET_HOME/wittypi"
if [ "$TARGET_HOME" != "/home/pi" ]; then
  LEGACY_CANDIDATES="$LEGACY_CANDIDATES /home/pi/vision/wittypi /home/pi/wittypi"
fi
LEGACY_DIR=""
for d in $LEGACY_CANDIDATES; do
  if [ -d "$d" ] && [ -f "$d/utilities.sh" ]; then
    LEGACY_DIR="$d"
    break
  fi
done
if [ ! -f "$VISION_HOME/utilities.sh" ] && [ -n "$LEGACY_DIR" ]; then
  echo ">>> Migrating legacy installation: $LEGACY_DIR -> $VISION_HOME"
  # stop the legacy daemon and any background children before copying, so
  # nothing keeps writing into the old tree (or the I2C registers) mid-move.
  # The daemon is killed by pidfile AND by path - the pidfile can be stale
  # or missing after an unclean power cut.
  if [ -f /var/run/wittypi_daemon.pid ]; then
    OLD_PID=$(cat /var/run/wittypi_daemon.pid 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null || true
    fi
  fi
  pkill -f "$LEGACY_DIR/daemon.sh" 2>/dev/null || true
  pkill -f "$LEGACY_DIR/runScript.sh" 2>/dev/null || true
  pkill -f "$LEGACY_DIR/buttonRelay.sh" 2>/dev/null || true
  # cron-spawned one-shots can be mid-run and appending to the legacy log
  pkill -f "$LEGACY_DIR/syncTime.sh" 2>/dev/null || true
  pkill -f "$LEGACY_DIR/checkInternet.sh" 2>/dev/null || true
  # drop legacy cron entries immediately so cron cannot spawn the old
  # scripts mid-migration (the current entries are re-installed below)
  (crontab -l 2>/dev/null | grep -vF 'syncTime.sh' | grep -vF 'checkInternet.sh' | grep -vF 'logsettings') | crontab - || true
  sleep 1
  mkdir -p "$VISION_HOME"
  # contents copy (trailing /.) - the runtime lands directly in the
  # service root, no nested folder
  cp -a "$LEGACY_DIR"/. "$VISION_HOME"/
  # verify the copy before deleting the original; one re-copy attempt in
  # case something appended to a log between copy and verify
  if ! diff -rq "$LEGACY_DIR" "$VISION_HOME" >/dev/null 2>&1; then
    cp -a "$LEGACY_DIR"/. "$VISION_HOME"/
  fi
  if diff -rq "$LEGACY_DIR" "$VISION_HOME" >/dev/null 2>&1; then
    rm -rf "$LEGACY_DIR"
    # the interim layout nested the runtime under a vision/ parent; remove
    # that parent too if the migration left it empty
    rmdir "$(dirname "$LEGACY_DIR")" 2>/dev/null || true
    echo "  State copied and verified; legacy install $LEGACY_DIR removed."
  else
    # copy could not be verified - keep the original out of the way rather
    # than deleting data; the vision-service tree is still the live install
    LEGACY_BACKUP="${LEGACY_DIR}.pre-vision"
    [ -e "$LEGACY_BACKUP" ] && LEGACY_BACKUP="${LEGACY_BACKUP}_$(date +%Y%m%d_%H%M%S)"
    mv "$LEGACY_DIR" "$LEGACY_BACKUP"
    echo "  WARN: copy verification failed; legacy tree kept at $LEGACY_BACKUP"
    echo "        (inspect and remove manually once satisfied)"
  fi
fi

# report any leftover legacy remnants that were NOT auto-removed (a second
# install under a different home, or a .pre-vision backup from a failed
# verification) - flagged for manual attention rather than deleted blind
for d in $LEGACY_CANDIDATES; do
  if [ -f "$VISION_HOME/utilities.sh" ] && [ -d "$d" ] && [ -f "$d/utilities.sh" ]; then
    echo "  WARN: another legacy install remains at $d - remove it manually."
  fi
  for b in "$d".pre-vision*; do
    [ -d "$b" ] && echo "  NOTE: old migration backup present at $b (safe to remove)."
  done
done

# detect existing installation (visIOn layout: runtime directly in the root)
WITTYPI_DIR=""
if [ -f "$VISION_HOME/utilities.sh" ]; then
  WITTYPI_DIR="$VISION_HOME"
fi

# regenerate the boot launcher and cron entries whenever an installation is
# present. This is idempotent and runs BEFORE the version gate so a
# freshly-migrated device (or one whose deploy was interrupted midway) is
# healed even when the software version is already current. Without this:
# - /etc/init.d/wittypi could still point at the removed legacy path and
#   the device would boot with no daemon - no alarms, no time sync
# - the root crontab could still run the legacy-path syncTime.sh /
#   checkInternet.sh, i.e. no time sync and no connectivity watchdog
if [ -n "$WITTYPI_DIR" ]; then
  sed -e "s#/home/pi/vision-service#$WITTYPI_DIR#g" "$SRC_DIR/wittypi/init.sh" >/etc/init.d/wittypi
  chmod +x /etc/init.d/wittypi
  update-rc.d wittypi defaults >/dev/null 2>&1 || true

  echo '>>> Setting up cron entries (time sync + connectivity watchdog + camera log)'
  chmod +x "$WITTYPI_DIR/syncTime.sh" "$WITTYPI_DIR/checkInternet.sh" "$WITTYPI_DIR/camera.sh" 2>/dev/null || true
  CRON_CMD="$WITTYPI_DIR/syncTime.sh >> $WITTYPI_DIR/wittyPi.log 2>&1"
  NET_CHECK_CMD="$WITTYPI_DIR/checkInternet.sh >> $WITTYPI_DIR/wittyPi.log 2>&1"
  CAM_LOG_CMD="$WITTYPI_DIR/camera.sh logsettings >> $WITTYPI_DIR/wittyPi.log 2>&1"
  # remove any existing entries (whatever path they point at) then add the
  # current ones; all three offsets chosen so no two jobs ever coincide.
  # The camera snapshot is date-guarded internally - it runs to completion
  # once per day and is a no-op statefile read the rest of the time.
  (crontab -l 2>/dev/null | grep -vF 'syncTime.sh' | grep -vF 'checkInternet.sh' | grep -vF 'logsettings'; \
   echo "*/15 * * * * $CRON_CMD"; \
   echo "7,22,37,52 * * * * $NET_CHECK_CMD"; \
   echo "5,20,35,50 * * * * $CAM_LOG_CMD") | crontab -
  echo '  Cron set: time sync every 15 min; internet check at :07/:22/:37/:52;'
  echo '            daily camera settings snapshot (attempts at :05/:20/:35/:50).'
  echo ''
fi

if [ ! -z "$WITTYPI_DIR" ] && [ -f "$WITTYPI_DIR/utilities.sh" ]; then
  # --- UPDATE existing installation ---
  CURRENT_VER=$(grep "SOFTWARE_VERSION=" "$WITTYPI_DIR/utilities.sh" | head -1 | grep -o "'[^']*'" | tr -d "'")
  TARGET_VER=$(grep "SOFTWARE_VERSION=" "$SRC_DIR/wittypi/utilities.sh" | head -1 | grep -o "'[^']*'" | tr -d "'")
  echo ">>> Existing installation found at $WITTYPI_DIR (v${CURRENT_VER:-unknown})"

  if [ "$CURRENT_VER" = "$TARGET_VER" ]; then
    echo "  Already at v${TARGET_VER}, no update needed."
    rm -rf "$TMP_DIR"
    exit 0
  fi

  echo "  Updating to v${TARGET_VER}..."
  # v5.29: utilities.sh is copied LAST because it carries SOFTWARE_VERSION,
  # which the already-at-target check above reads. If the deploy is
  # interrupted mid-loop (these devices power off on schedule), a
  # version-first order left new utilities + old scripts and every rerun
  # said "already up to date" - locking the mixed install in permanently.
  # With version-last, an interrupted deploy simply reruns.
  UPDATE_FILES="daemon.sh runScript.sh wittyPi.sh syncTime.sh checkInternet.sh buttonRelay.sh camera.sh utilities.sh"

  # backup
  BACKUP_DIR="$WITTYPI_DIR/backup_v${CURRENT_VER:-old}_$(date +%Y%m%d_%H%M%S)"
  echo "  Backup: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  for f in $UPDATE_FILES; do
    [ -f "$WITTYPI_DIR/$f" ] && cp "$WITTYPI_DIR/$f" "$BACKUP_DIR/$f"
  done

  # copy updated scripts atomically: write to a .new file then mv into
  # place. If a reboot or kill interrupts the copy, the daemon will still
  # find the previous (valid) version on disk instead of a half-written
  # file that fails syntax checks at the next source.
  for f in $UPDATE_FILES; do
    if [ -f "$SRC_DIR/wittypi/$f" ]; then
      cp "$SRC_DIR/wittypi/$f" "$WITTYPI_DIR/$f.new"
      chmod +x "$WITTYPI_DIR/$f.new"
      # syntax check before swapping in - protects against bad pushes
      if bash -n "$WITTYPI_DIR/$f.new" 2>/dev/null; then
        mv "$WITTYPI_DIR/$f.new" "$WITTYPI_DIR/$f"
        echo "  Updated $f"
      else
        rm -f "$WITTYPI_DIR/$f.new"
        echo "  SKIPPED $f (syntax check failed - keeping previous version)"
        ((ERR++)) 2>/dev/null || true
      fi
    fi
  done

  # sync schedules: make the device's schedules/ folder match the repo's
  # Schedules/ exactly. Removes obsolete .wpi files, adds new ones, updates
  # changed ones. The active selection (schedule.wpi) is preserved as user
  # state and never auto-deleted.
  if [ -d "$SRC_DIR/../Schedules" ]; then
    echo ''
    echo '>>> Syncing schedules'
    sync_schedules "$SRC_DIR/../Schedules" "$WITTYPI_DIR/schedules"
  fi

  # keep a current copy of the installer on the device, inside the service
  # root (the parent would be the user's home - don't litter it)
  if [ -f "$SRC_DIR/install.sh" ]; then
    cp "$SRC_DIR/install.sh" "$WITTYPI_DIR/install.sh" 2>/dev/null || true
  fi

  # v5.38: camera.sh needs gphoto2; updates never run install.sh, so pull
  # the dependency in here for devices installed before it existed. The
  # device is online (this deploy just downloaded from GitHub).
  if ! command -v gphoto2 >/dev/null 2>&1; then
    echo ''
    echo '>>> Installing gphoto2 (camera control dependency)'
    apt install -y gphoto2 || echo '  WARN: gphoto2 install failed - camera.sh needs it; rerun deploy or install manually.'
  fi

  # fix ownership
  if [ ! -z "$SUDO_USER" ]; then
    chown -R $SUDO_USER:$(id -g -n $SUDO_USER) "$WITTYPI_DIR" 2>/dev/null
  fi

  # restart daemon: kill the daemon and ANY backgrounded child (runScript.sh)
  # that may still be writing to I2C alarm registers. Two concurrent writers
  # could otherwise leave registers in an inconsistent state.
  echo ''
  echo '>>> Restarting daemon'
  if [ -f /var/run/wittypi_daemon.pid ]; then
    OLD_PID=$(cat /var/run/wittypi_daemon.pid 2>/dev/null)
    if [ ! -z "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null
      sleep 1
      echo '  Stopped old daemon.'
    fi
  fi
  # also kill any orphaned runScript.sh from the previous daemon's background launch
  pkill -f "$WITTYPI_DIR/runScript.sh" 2>/dev/null && echo '  Stopped any active runScript.sh.'
  # v5.35: also stop the button->relay watcher; the restarted daemon spawns
  # a fresh one. Without this, watchers accumulated across deploys and each
  # toggled the relay per press (two instances = no net pin change).
  pkill -f "$WITTYPI_DIR/buttonRelay.sh" 2>/dev/null && echo '  Stopped old buttonRelay watcher.'
  sleep 1
  "$WITTYPI_DIR/daemon.sh" &
  sleep 1
  DAEMON_PID=$(ps --ppid $! -o pid= 2>/dev/null)
  if [ ! -z "$DAEMON_PID" ]; then
    echo "$DAEMON_PID" > /var/run/wittypi_daemon.pid
    echo "  Daemon restarted (PID: $DAEMON_PID)."
  else
    echo '  Daemon will start on next reboot.'
  fi

  # immediate time sync to migrate RTC to UTC
  # v5.29: `|| true` - this script runs under `set -e`, and syncTime.sh
  # legitimately exits non-zero when the just-restarted daemon holds the
  # I2C lock or the MCU probe races it. That abort previously killed the
  # deploy BEFORE the cron entries below were installed, leaving fresh
  # conversions with no time-sync and no connectivity watchdog at all.
  echo ''
  echo '>>> Syncing time and migrating RTC to UTC'
  SYNC_RC=0
  "$WITTYPI_DIR/syncTime.sh" >> "$WITTYPI_DIR/wittyPi.log" 2>&1 || SYNC_RC=$?
  if [ $SYNC_RC -eq 0 ]; then
    echo '  RTC migrated to UTC.'
  else
    echo '  No internet - RTC will be migrated on next sync.'
  fi

  # NOTE: cron entries (time sync + connectivity watchdog) are installed in
  # the idempotent pre-version-gate block above, so they are refreshed even
  # when the software is already at the target version.

  # Strip any gpio-shutdown dtoverlay configured for GPIO-4 from the boot
  # config. The Witty Pi button is hardwired to both PIN_BUTTON on the
  # ATtiny AND GPIO-4 on the Pi header. If a prior UUGear install (or
  # someone configuring gpio-shutdown manually) left this overlay in
  # place, pressing the button drives GPIO-4 low which makes systemd
  # immediately shutdown the Pi - regardless of firmware Rev 14's
  # button-disable behaviour. Strip it so the button cannot trigger
  # shutdown via the kernel either.
  echo ''
  echo '>>> Checking /boot/config.txt for gpio-shutdown overlay'
  CFG=''
  if [ -f /boot/firmware/config.txt ]; then
    CFG=/boot/firmware/config.txt
  elif [ -f /boot/config.txt ]; then
    CFG=/boot/config.txt
  fi
  if [ -n "$CFG" ]; then
    if grep -Eq '^\s*dtoverlay=gpio-shutdown' "$CFG"; then
      cp "$CFG" "${CFG}.bak"
      sed -i.tmp '/^\s*dtoverlay=gpio-shutdown/d' "$CFG"
      rm -f "${CFG}.tmp"
      echo "  Removed gpio-shutdown overlay from $CFG (backup: ${CFG}.bak)."
      echo '  Effective on next reboot.'
    else
      echo '  No gpio-shutdown overlay found.'
    fi
  else
    echo '  No /boot/config.txt found, skipping.'
  fi

  # NOTE: BCM2835 hardware watchdog enablement was REMOVED in v4.38/v5.21
  # after a field-device reboot loop. The schedule/alarm pipeline already
  # has multiple independent failsafes (firmware Guaranteed Wake,
  # runScript fallback alarms, daemon retry, cron-based time/internet
  # checks). If a previous deploy enabled the watchdog, strip the setting
  # as a precaution so it can't compound any boot-time issues.
  if [ -f /etc/systemd/system.conf ]; then
    if grep -qE '^\s*RuntimeWatchdogSec=' /etc/systemd/system.conf; then
      sed -i.bak '/^\s*RuntimeWatchdogSec=/d' /etc/systemd/system.conf
      systemctl daemon-reexec 2>/dev/null || true
      echo '  Disabled previously-configured RuntimeWatchdogSec (precaution).'
    fi
  fi

  echo ''
  echo '================================================================================'
  echo "  Update complete! v${CURRENT_VER} -> v${TARGET_VER}"
  echo ''
  echo '  RTC will be migrated to UTC automatically.'
  echo '  If offline, run wittyPi.sh and choose option 1 after verifying system time.'
  echo ''
  echo "  Rollback: sudo cp $BACKUP_DIR/* $WITTYPI_DIR/ && sudo reboot"
  echo '================================================================================'

else
  # --- FRESH installation ---
  echo '>>> No existing installation found. Running full install...'
  # install.sh anchors itself at $VISION_HOME and installs the runtime
  # directly into it; WITTYPI_SRC points it at the downloaded source so the
  # checkout's own wittypi/ folder is never mistaken for an install.
  echo ">>> Installing visIOn runtime into $VISION_HOME"
  WITTYPI_SRC="$SRC_DIR/wittypi" VISION_HOME="$VISION_HOME" bash "$SRC_DIR/install.sh"
fi

# cleanup
rm -rf "$TMP_DIR"
