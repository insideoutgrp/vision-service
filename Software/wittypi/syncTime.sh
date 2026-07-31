#!/bin/bash
# file: syncTime.sh
#
# Periodically syncs system clock from network time and writes to RTC.
# Intended to be called by cron every 15 minutes.
#

cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$cur_dir/utilities.sh"

TIME_UNKNOWN=0

# Don't race the daemon during the boot window. The daemon does several
# synchronous I2C writes in its first ~30 seconds and an i2c_write
# collision from this cron job can cascade into retry storms that delay
# SYS_UP past the firmware's TXD/alarm timeouts.
uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 9999)
if [ "$uptime_sec" -lt 60 ]; then
  log "Time sync: uptime ${uptime_sec}s < 60s, skipping (daemon still booting)."
  exit 0
fi

# Serialise with any other I2C-touching cron job (checkInternet.sh) so we
# never have two scripts hitting the Witty Pi I2C bus simultaneously.
# v5.30: world-writable lock shared with the interactive wittyPi.sh menu;
# read-fd fallback for a pre-existing root-owned 644 file.
LOCK=/var/lock/wittypi.i2c.lock
touch "$LOCK" 2>/dev/null && chmod 666 "$LOCK" 2>/dev/null
if [ -w "$LOCK" ]; then
  exec 9>"$LOCK"
elif [ -r "$LOCK" ]; then
  exec 9<"$LOCK"
fi
if ! flock -n 9 2>/dev/null; then
  log 'Time sync: another wittypi job is using the I2C bus, skipping this tick.'
  exit 0
fi

if [ $(is_mc_connected) -ne 1 ]; then
  log 'Time sync: Witty Pi not connected, skipping.'
  exit 1
fi

if has_internet ; then
  log 'Time sync: Internet available, syncing...'
  # v5.29: only write system->RTC when the network time actually applied
  # (net_to_system returns non-zero when the Date header was unusable -
  # writing the RTC then would copy a possibly-drifted clock into it).
  if net_to_system ; then
    system_to_rtc
    log "Time sync: Complete. RTC set to $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  else
    log 'Time sync: network time unusable, RTC left untouched.'
  fi
else
  log 'Time sync: No internet, skipping.'
fi
