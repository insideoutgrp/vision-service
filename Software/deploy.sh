#!/bin/bash
# file: deploy.sh
#
# One-liner deployment script for the visIOn Witty Pi runtime.
# Run on a Pi with:
#   curl -sSL https://raw.githubusercontent.com/insideoutgrp/vision-service/main/Software/deploy.sh | sudo bash
#
# Installs/updates the runtime at /home/pi/vision/wittypi. Devices still on
# the legacy /home/pi/wittypi layout are migrated automatically: all
# per-device state (schedule.wpi, buttonRelay.conf, logs, watchdog state)
# is carried over and the old directory is kept as wittypi.pre-vision.
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
VISION_HOME="${VISION_HOME:-$TARGET_HOME/vision}"

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

# migrate a legacy /home/pi/wittypi installation into the visIOn layout.
# Full-tree copy so all per-device state (schedule.wpi, buttonRelay.conf,
# logs, .net_* watchdog state, hook scripts, backups) carries over; the
# normal update path below then brings the scripts to the target version.
# Re-runnable: once $VISION_HOME/wittypi exists the block is skipped.
LEGACY_DIR=""
for d in "$TARGET_HOME/wittypi" /home/pi/wittypi; do
  if [ -d "$d" ] && [ -f "$d/utilities.sh" ]; then
    LEGACY_DIR="$d"
    break
  fi
done
if [ ! -d "$VISION_HOME/wittypi" ] && [ -n "$LEGACY_DIR" ]; then
  echo ">>> Migrating legacy installation: $LEGACY_DIR -> $VISION_HOME/wittypi"
  # stop the legacy daemon and any background children before copying, so
  # nothing keeps writing into the old tree (or the I2C registers) mid-move
  if [ -f /var/run/wittypi_daemon.pid ]; then
    OLD_PID=$(cat /var/run/wittypi_daemon.pid 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null || true
    fi
  fi
  pkill -f "$LEGACY_DIR/runScript.sh" 2>/dev/null || true
  pkill -f "$LEGACY_DIR/buttonRelay.sh" 2>/dev/null || true
  sleep 1
  mkdir -p "$VISION_HOME"
  cp -a "$LEGACY_DIR" "$VISION_HOME/wittypi"
  # keep the old tree as an on-device backup, renamed out of the detection
  # path; timestamp-suffix if a previous migration attempt left one behind
  # (mv into an existing directory would nest instead of rename)
  LEGACY_BACKUP="${LEGACY_DIR}.pre-vision"
  [ -e "$LEGACY_BACKUP" ] && LEGACY_BACKUP="${LEGACY_BACKUP}_$(date +%Y%m%d_%H%M%S)"
  mv "$LEGACY_DIR" "$LEGACY_BACKUP"
  echo "  Legacy tree kept at $LEGACY_BACKUP"
fi

# detect existing installation (visIOn layout)
WITTYPI_DIR=""
if [ -d "$VISION_HOME/wittypi" ] && [ -f "$VISION_HOME/wittypi/utilities.sh" ]; then
  WITTYPI_DIR="$VISION_HOME/wittypi"
fi

# regenerate the boot launcher whenever an installation is present. This is
# idempotent and runs BEFORE the version gate so a freshly-migrated device
# (or one whose deploy was interrupted between copy and init.d rewrite) is
# healed even when the software version is already current. Without this,
# /etc/init.d/wittypi could still point at the removed legacy path and the
# device would boot with no daemon - no alarms, no time sync.
if [ -n "$WITTYPI_DIR" ]; then
  sed -e "s#/home/pi/vision/wittypi#$WITTYPI_DIR#g" "$SRC_DIR/wittypi/init.sh" >/etc/init.d/wittypi
  chmod +x /etc/init.d/wittypi
  update-rc.d wittypi defaults >/dev/null 2>&1 || true
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
  UPDATE_FILES="daemon.sh runScript.sh wittyPi.sh syncTime.sh checkInternet.sh buttonRelay.sh utilities.sh"

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

  # also update install.sh in parent dir
  INSTALL_DIR="$(dirname "$WITTYPI_DIR")"
  if [ -f "$SRC_DIR/install.sh" ]; then
    cp "$SRC_DIR/install.sh" "$INSTALL_DIR/install.sh" 2>/dev/null || true
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

  # set up cron job for periodic time sync
  echo ''
  echo '>>> Setting up periodic time sync'
  CRON_CMD="$WITTYPI_DIR/syncTime.sh >> $WITTYPI_DIR/wittyPi.log 2>&1"
  # remove any existing syncTime cron entry then add the current one
  (crontab -l 2>/dev/null | grep -vF 'syncTime.sh'; echo "*/15 * * * * $CRON_CMD") | crontab -
  echo '  Cron job set: sync time every 15 minutes.'

  # set up cron job for internet connectivity check (offset from syncTime)
  echo ''
  echo '>>> Setting up internet connectivity check'
  NET_CHECK_CMD="$WITTYPI_DIR/checkInternet.sh >> $WITTYPI_DIR/wittyPi.log 2>&1"
  (crontab -l 2>/dev/null | grep -vF 'checkInternet.sh'; echo "7,22,37,52 * * * * $NET_CHECK_CMD") | crontab -
  echo '  Cron job set: check internet every 15 min (at :07/:22/:37/:52).'
  # ensure the script is present and executable on device
  chmod +x "$WITTYPI_DIR/checkInternet.sh" 2>/dev/null

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
  # install.sh anchors itself at $VISION_HOME and installs the runtime into
  # $VISION_HOME/wittypi; WITTYPI_SRC points it at the downloaded source so
  # the checkout's own wittypi/ folder is never mistaken for an install.
  echo ">>> Installing visIOn Witty Pi runtime into $VISION_HOME/wittypi"
  WITTYPI_SRC="$SRC_DIR/wittypi" VISION_HOME="$VISION_HOME" bash "$SRC_DIR/install.sh"
fi

# cleanup
rm -rf "$TMP_DIR"
