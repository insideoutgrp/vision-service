#!/bin/bash
# file: checkInternet.sh
#
# Pings a remote server to check internet connectivity. If this fails
# for $FAIL_THRESHOLD consecutive runs, logs a warning and reboots the
# Raspberry Pi. Intended to be called by cron, at an offset schedule
# (not on-the-hour) to avoid clashing with other periodic jobs.
#

cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$cur_dir/utilities.sh"

TIME_UNKNOWN=0

# Don't race the daemon during the boot window. Note: this script doesn't
# itself touch I2C heavily (only is_mc_connected indirectly), but we keep
# the gate for consistency and to avoid I2C pings competing with the
# daemon's startup writes.
uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 9999)
if [ "$uptime_sec" -lt 60 ]; then
  log "Internet check: uptime ${uptime_sec}s < 60s, skipping (daemon still booting)."
  exit 0
fi

# Serialise with syncTime.sh so we never have two scripts hitting the
# Witty Pi I2C bus simultaneously.
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
  log 'Internet check: another wittypi job is using the I2C bus, deferring.'
  exit 0
fi

# configurable
readonly PING_TARGETS=('8.8.8.8' '1.1.1.1' 'www.google.com')
readonly PING_TIMEOUT=15   # seconds - generous to accommodate 3G links
readonly PING_COUNT=2      # attempts per target
readonly FAIL_THRESHOLD=3
readonly STATE_FILE="$cur_dir/.net_fail_count"

# Reboot loop protection: prevents a genuinely-offline device (3G outage,
# dead SIM, ISP down) from rebooting forever and draining the battery.
readonly REBOOT_LOG="$cur_dir/.net_reboot_log"   # one date stamp per line
readonly MAX_REBOOTS_PER_DAY=2
readonly MIN_UPTIME_SECONDS=1800   # don't reboot if uptime < 30 min

# load previous failure count (0 if first run or reset)
fail_count=0
if [ -f "$STATE_FILE" ]; then
  fail_count=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  [[ "$fail_count" =~ ^[0-9]+$ ]] || fail_count=0
fi

# try each ping target; success on any clears the counter
online=0
for target in "${PING_TARGETS[@]}"; do
  if ping -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
    online=1
    break
  fi
done

if [ $online -eq 1 ]; then
  if [ "$fail_count" -gt 0 ]; then
    log "Internet check: connectivity restored after $fail_count failed attempt(s)."
  fi
  echo 0 > "$STATE_FILE"
else
  fail_count=$((fail_count + 1))
  echo "$fail_count" > "$STATE_FILE"
  log "Internet check: FAILED ($fail_count/$FAIL_THRESHOLD). Targets unreachable: ${PING_TARGETS[*]}"

  if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
    # Uptime gate: if we just rebooted, give the network a chance to come up
    uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    if [ "$uptime_sec" -lt "$MIN_UPTIME_SECONDS" ]; then
      log "Internet check: would reboot, but uptime is ${uptime_sec}s (< ${MIN_UPTIME_SECONDS}s). Skipping."
    else
      # Daily reboot cap: count today's reboots in $REBOOT_LOG
      today=$(date -u +%Y-%m-%d)
      if [ -f "$REBOOT_LOG" ]; then
        # v5.29: no `|| echo 0` - grep -c already prints 0 (while exiting
        # 1), so the fallback produced the two-line string "0\n0" which
        # made the -ge test below error out. Sanitise instead.
        reboots_today=$(grep -c "^$today" "$REBOOT_LOG" 2>/dev/null)
        [[ "$reboots_today" =~ ^[0-9]+$ ]] || reboots_today=0
      else
        reboots_today=0
      fi
      if [ "$reboots_today" -ge "$MAX_REBOOTS_PER_DAY" ]; then
        log "Internet check: reached $FAIL_THRESHOLD failures, but already rebooted $reboots_today time(s) today. Skipping to avoid loop."
      else
        log "Internet check: reached $FAIL_THRESHOLD consecutive failures. Rebooting (today's reboot #$((reboots_today + 1)))..."
        # log the reboot attempt and prune old entries (keep last 14 days)
        ( grep -h "^[0-9]" "$REBOOT_LOG" 2>/dev/null | tail -50 ; echo "$today $(date -u +%H:%M:%S)" ) > "$REBOOT_LOG.new"
        mv "$REBOOT_LOG.new" "$REBOOT_LOG"
        # reset failure counter so we don't immediately reboot again on next boot
        echo 0 > "$STATE_FILE"
        sync
        shutdown -r now
      fi
    fi
  fi
fi
