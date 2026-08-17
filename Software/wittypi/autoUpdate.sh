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
# API-side cached mirror of the same payloads (v5.57). Preferred: a whole
# bench fleet probing GitHub from one NAT IP got that IP 429-banned; the
# mirror makes GitHub see one droplet fetch per 5 min regardless of fleet
# size. GitHub direct remains the fallback so a droplet outage never
# strands a device.
API_SW='https://api.insideoutgroup.co.uk/v1/sw'

STAMP="$cur_dir/.autoupdate_date"
CONF="$cur_dir/autoUpdate.conf"
# One-shot dashboard approval (written by the connector). Without it a newer
# published version is logged but NOT applied - fleet-wide silent updates
# are opt-in per device from v5.53. `force` keeps working regardless.
APPROVAL="$cur_dir/.update_approved"

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
  # approval bypasses the daily stamp so an approved update applies at the
  # next cron tick, not tomorrow
  if [ ! -f "$APPROVAL" ]; then
    [ "$(cat "$STAMP" 2>/dev/null)" = "$today" ] && exit 0
  fi
  # stay out of the boot window (daemon startup, schedule engine, deploys
  # triggered at boot would fight the daemon over the I2C registers)
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 999)
  [ "$up" -lt 120 ] && exit 0
else
  today=$(TZ=$LOCAL_TZ date +%Y-%m-%d)
fi

# cheap remote version probe before any heavy download — mirror first
# (strict format check: an error page must never look like a version)
remote=$(curl -s --max-time 25 "$API_SW/version" \
         | grep -oE '^[0-9]+\.[0-9]+$' | head -1)
if [ -z "$remote" ]; then
  remote=$(curl -s --max-time 25 "$REPO_RAW/Software/wittypi/utilities.sh" \
           | grep "SOFTWARE_VERSION=" | head -1 | grep -o "'[^']*'" | tr -d "'")
fi
if [ -z "$remote" ]; then
  # offline or both sources unreachable - no stamp, retry on the next cron tick
  exit 0
fi

# a completed check counts for the day, whether or not an update follows
echo "$today" > "$STAMP"

if [ "$remote" = "$SOFTWARE_VERSION" ]; then
  log "AutoUpdate: check complete - already at v$SOFTWARE_VERSION."
  exit 0
fi

if [ "$1" != "force" ] && [ ! -f "$APPROVAL" ]; then
  log "AutoUpdate: v$remote published (installed v$SOFTWARE_VERSION) - holding until approved from the dashboard."
  exit 0
fi
log "AutoUpdate: published version v$remote differs from installed v$SOFTWARE_VERSION - deploying."
tmp=$(mktemp)
fetched=""
for src in "$API_SW/deploy.sh" "$REPO_RAW/Software/deploy.sh"; do
  if curl -sSL --max-time 120 "$src" -o "$tmp" && bash -n "$tmp" 2>/dev/null; then
    fetched=1; break
  fi
done
if [ -z "$fetched" ]; then
  rm -f "$tmp"
  log 'AutoUpdate: WARN - could not fetch a valid deploy.sh from mirror or GitHub; will retry tomorrow.'
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
