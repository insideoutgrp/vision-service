[ -z $BASH ] && { exec bash "$0" "$@" || exit; }
#!/bin/bash
# file: autoUpdate.sh
#
# visIOn self-update: checks GitHub once per day and applies a newly
# published version automatically by running the standard deploy.
#
# Design (field constraints first):
# - Cron attempts every 15 min (:12/:27/:42/:57); a date stamp makes all
#   ticks after the day's first COMPLETED check a no-op, so devices with
#   short wake windows still get their daily check. A check that cannot
#   reach GitHub does NOT stamp - it retries on the next tick.
# - The remote version is probed by fetching raw utilities.sh (~30 KB) and
#   comparing SOFTWARE_VERSION - the full deploy (tarball download, script
#   swap, daemon restart) only runs when the versions differ. Publishing a
#   release = pushing a bumped SOFTWARE_VERSION to the branch below.
# - deploy.sh is downloaded to a temp file and syntax-checked before
#   execution - never piped straight from the network.
# - deploy.sh itself is version-gated, atomic, and safe to interrupt, so a
#   power cut mid-update is recovered by the next day's check.
# - Per-device opt-out: AUTO_UPDATE=0 in autoUpdate.conf (state file,
#   never overwritten by deploys).
#
# Usage: autoUpdate.sh          (cron; date-guarded)
#        autoUpdate.sh force    (manual: skip the date and uptime guards)

cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$cur_dir/utilities.sh"

TIME_UNKNOWN=0

# must match where this repository is hosted; deploy.sh pins the same branch
REPO_RAW='https://raw.githubusercontent.com/insideoutgrp/vision-service/main'

STAMP="$cur_dir/.autoupdate_date"
CONF="$cur_dir/autoUpdate.conf"

if [ "$(id -u)" != 0 ]; then
  echo 'autoUpdate.sh must run as root (deploy needs it).'
  exit 1
fi

# per-device config, created on first run (deploys never touch it)
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<'CONFEOF'
# visIOn auto-update configuration.
# This file is per-device state: deploys never overwrite it.

# 1 = check GitHub daily and apply newly published versions automatically.
# 0 = never update automatically (manual deploys only).
AUTO_UPDATE=1
CONFEOF
  chmod 644 "$CONF"
  log 'AutoUpdate: created default autoUpdate.conf (enabled).'
fi
. "$CONF"
if [ "$AUTO_UPDATE" != "1" ]; then
  exit 0
fi

if [ "$1" != "force" ]; then
  today=$(TZ=$LOCAL_TZ date +%Y-%m-%d)
  [ "$(cat "$STAMP" 2>/dev/null)" = "$today" ] && exit 0
  # stay out of the boot window (daemon startup, schedule engine, deploys
  # triggered at boot would fight the daemon over the I2C registers)
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 999)
  [ "$up" -lt 120 ] && exit 0
else
  today=$(TZ=$LOCAL_TZ date +%Y-%m-%d)
fi

# cheap remote version probe before any heavy download
remote=$(curl -s --max-time 25 "$REPO_RAW/Software/wittypi/utilities.sh" \
         | grep "SOFTWARE_VERSION=" | head -1 | grep -o "'[^']*'" | tr -d "'")
if [ -z "$remote" ]; then
  # offline or GitHub unreachable - no stamp, retry on the next cron tick
  exit 0
fi

# a completed check counts for the day, whether or not an update follows
echo "$today" > "$STAMP"

if [ "$remote" = "$SOFTWARE_VERSION" ]; then
  log "AutoUpdate: check complete - already at v$SOFTWARE_VERSION."
  exit 0
fi

log "AutoUpdate: published version v$remote differs from installed v$SOFTWARE_VERSION - deploying."
tmp=$(mktemp)
if ! curl -sSL --max-time 120 "$REPO_RAW/Software/deploy.sh" -o "$tmp" \
   || ! bash -n "$tmp" 2>/dev/null; then
  rm -f "$tmp"
  log 'AutoUpdate: WARN - could not fetch a valid deploy.sh; will retry tomorrow.'
  exit 1
fi
rc=0
bash "$tmp" >> "$cur_dir/wittyPi.log" 2>&1 || rc=$?
rm -f "$tmp"

# report against what is now on disk (this shell still runs the old code)
newv=$(grep "SOFTWARE_VERSION=" "$cur_dir/utilities.sh" | head -1 | grep -o "'[^']*'" | tr -d "'")
if [ "$newv" = "$remote" ]; then
  log "AutoUpdate: updated v$SOFTWARE_VERSION -> v$newv."
else
  log "AutoUpdate: WARN - deploy exited rc=$rc but installed version is v${newv:-unknown} (expected v$remote); will retry tomorrow."
fi
exit 0
