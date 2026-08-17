#!/bin/bash
# iovision telemetry collector — polite guest of vision-service.
# Prints key=value lines. I2C reads go through utilities.sh under the shared
# flock (same pattern as syncTime.sh); if the lock is busy we skip I2C and
# still report everything else. Never writes to hardware.
VISION_HOME="${1:-/home/pi/vision-service}"

echo "collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
echo "disk_free_mb=$(df -m / | awk 'NR==2{print $4}')"
echo "kernel=$(uname -r)"
echo "pi_model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
echo "os_release=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
# Data usage: kernel interface counters (bytes since boot, all traffic —
# including Teleport uploads, which dominate). The server diffs consecutive
# readings into per-day usage and flags budget overruns.
net_rx=0; net_tx=0
for ifc in eth0 wlan0; do
  r=$(cat /sys/class/net/$ifc/statistics/rx_bytes 2>/dev/null) && net_rx=$((net_rx + r))
  t=$(cat /sys/class/net/$ifc/statistics/tx_bytes 2>/dev/null) && net_tx=$((net_tx + t))
done
echo "net_rx_bytes=$net_rx"
echo "net_tx_bytes=$net_tx"

# Test-bench detection + field power savings (v5.52).
# Bench (office SSID visible): HDMI/wifi/bluetooth ON for troubleshooting,
# scan every cycle so leaving the office is noticed quickly.
# Field: HDMI + wifi + bluetooth OFF (~50-80 mA); wifi wakes once a day
# just long enough to scan, then blocks again. Profiles are idempotent and
# re-applied every cycle, so a reboot self-heals within 5 minutes.
BENCH_STATE="$VISION_HOME/.bench_state"       # bench|field (last good scan)
BENCH_STAMP="$VISION_HOME/.bench_scan_date"   # daily stamp for field scans
bench_state=$(cat "$BENCH_STATE" 2>/dev/null)
scan_today=$(date -u +%Y-%m-%d)

do_scan=0
if [ "$bench_state" != "field" ]; then
  do_scan=1   # bench or unknown: scan every cycle
elif [ "$(cat "$BENCH_STAMP" 2>/dev/null)" != "$scan_today" ]; then
  do_scan=1   # field: once per day
fi

if [ "$do_scan" = "1" ] && command -v iw >/dev/null 2>&1; then
  sudo -n rfkill unblock wifi 2>/dev/null
  sudo -n ip link set wlan0 up 2>/dev/null
  scan_out=$(sudo -n iw dev wlan0 scan 2>&1)
  if ! echo "$scan_out" | grep -q 'SSID:'; then
    sleep 2   # scans transiently fail while the radio settles / iface busy
    scan_out=$(sudo -n iw dev wlan0 scan 2>&1)
  fi
  if echo "$scan_out" | grep -q 'SSID:'; then
    echo "$scan_today" > "$BENCH_STAMP"
    if echo "$scan_out" | grep -q 'SSID: InsideOut'; then
      echo "office_ssid_visible=1"
      echo bench > "$BENCH_STATE"
    else
      echo "office_ssid_visible=0"
      echo field > "$BENCH_STATE"
    fi
  else
    # can't scan: report it and leave the radio alone (never block wifi on
    # a device whose scan is broken — it could never detect the bench again)
    echo "office_scan_error=$(echo "$scan_out" | head -1 | tr -d "\"'" | cut -c1-60)"
  fi
elif ! command -v iw >/dev/null 2>&1; then
  echo "office_scan_error=iw_not_installed"
fi

# apply the power profile for the (possibly just-updated) state
bench_state=$(cat "$BENCH_STATE" 2>/dev/null)
if [ "$bench_state" = "field" ]; then
  sudo -n vcgencmd display_power 0 >/dev/null 2>&1 || sudo -n tvservice -o >/dev/null 2>&1
  sudo -n rfkill block wifi 2>/dev/null
  sudo -n rfkill block bluetooth 2>/dev/null
  echo "powersave=1"
elif [ "$bench_state" = "bench" ]; then
  sudo -n vcgencmd display_power 1 >/dev/null 2>&1 || sudo -n tvservice -p >/dev/null 2>&1
  sudo -n rfkill unblock wifi 2>/dev/null
  sudo -n rfkill unblock bluetooth 2>/dev/null
  echo "powersave=0"
fi

# Primary internal IP — the server maps subnet -> router type (site network).
ip_addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -z "$ip_addr" ] && ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$ip_addr" ] && echo "internal_ip=$ip_addr"

# Teleport capture health (v5.55). The tssvc journal narrates the frame
# pipeline: "Next frm" (frame due + interval), "Got frm" (captured, size +
# shoot time), "Up frm" (uploaded). Parse the latest of each so the dashboard
# can show capture status and flag missed frames. Read-only; skipped where
# tssvc isn't installed. Timestamps are epoch seconds UTC.
godur_ms() {  # Go duration ("10m0s", "4.106s", "982ms", "1h2m3s") -> ms
  local d="$1" ms=0
  [[ $d =~ ([0-9]+)h ]] && ms=$((ms + BASH_REMATCH[1] * 3600000))
  [[ $d =~ ([0-9]+)m([0-9]|$) ]] && ms=$((ms + BASH_REMATCH[1] * 60000))
  if [[ $d =~ ([0-9]+(\.[0-9]+)?)ms ]]; then
    ms=$((ms + $(awk -v n="${BASH_REMATCH[1]}" 'BEGIN{printf "%d", n}')))
  elif [[ $d =~ ([0-9]+(\.[0-9]+)?)s ]]; then
    ms=$((ms + $(awk -v n="${BASH_REMATCH[1]}" 'BEGIN{printf "%d", n*1000}')))
  fi
  echo "$ms"
}
if [ "$(systemctl show tssvc -p LoadState --value 2>/dev/null)" = "loaded" ]; then
  echo "cap_svc=$(systemctl is-active tssvc 2>/dev/null)"
  # short-unix prefixes each line with epoch seconds — no timezone games.
  JCTL="journalctl"
  jlog=$($JCTL -u tssvc -n 400 -o short-unix --no-pager 2>/dev/null)
  if [ -z "$jlog" ]; then
    JCTL="sudo -n journalctl"
    jlog=$($JCTL -u tssvc -n 400 -o short-unix --no-pager 2>/dev/null)
  fi
  if [ -z "$jlog" ]; then
    echo "cap_log_error=journal_unreadable"
  else
    next_line=$(echo "$jlog" | grep -F 'Next frm,' | tail -1)
    if [ -n "$next_line" ]; then
      ts=$(echo "$next_line" | sed -n 's/.*TS: \([^,]*\).*/\1/p')
      due=$(date -u -d "$ts" +%s 2>/dev/null) && echo "cap_due_at=$due"
      ci=$(echo "$next_line" | sed -n 's/.*CI: \([^,]*\).*/\1/p')
      [ -n "$ci" ] && echo "cap_interval_s=$(( $(godur_ms "$ci") / 1000 ))"
    fi
    got_line=$(echo "$jlog" | grep -F 'Got frm,' | tail -1)
    if [ -n "$got_line" ]; then
      ts=$(echo "$got_line" | sed -n 's/.*TS: \([^,]*\).*/\1/p')
      got=$(date -u -d "$ts" +%s 2>/dev/null) && echo "cap_last_at=$got"
      size=$(echo "$got_line" | sed -n 's/.*S: \([^,]*\).*/\1/p')
      kb=$(echo "$size" | awk '{v=$0+0; if (index($0,"GiB")) v*=1048576;
        else if (index($0,"MiB")) v*=1024; else if (index($0,"KiB")) v+=0;
        else v/=1024; printf "%d", v}')
      [ -n "$size" ] && echo "cap_size_kb=$kb"
      fst=$(echo "$got_line" | sed -n 's/.*FST: \([^,]*\).*/\1/p')
      [ -n "$fst" ] && echo "cap_shoot_ms=$(godur_ms "$fst")"
    fi
    up_line=$(echo "$jlog" | grep -F 'Up frm,' | tail -1)
    if [ -n "$up_line" ]; then
      echo "cap_up_at=$(echo "$up_line" | awk '{printf "%d", $1}')"
      fut=$(echo "$up_line" | sed -n 's/.*FUT: \([^,]*\).*/\1/p')
      [ -n "$fut" ] && echo "cap_up_ms=$(godur_ms "$fut")"
    fi
    method=$(echo "$jlog" | grep -F 'captureMethod:' | tail -1 |
             sed 's/.*captureMethod: *//' | cut -c1-40)
    [ -n "$method" ] && echo "cap_method=$method"
    # Teleport feed id + publish state. tssvc logs periodic status lines:
    #   "<ts> Offline, Feed unchanged, State: ..., Fid: fejy6df8thki, Ch: default"
    # Fid: is THIS station's configured feed; the leading word is whether
    # it is actually publishing to it. Both matter: a re-staged bench unit
    # still configured with its old site feed reports "Offline" — the
    # dashboard must not show that site's live image as this device's
    # (found on the 2026-08-17 re-staged batch). Cache survives journal
    # rotation on long uptimes.
    FEED_CACHE="$VISION_HOME/.teleport_feed"
    fid_line=$($JCTL -u tssvc -b -o cat --no-pager 2>/dev/null |
               grep -E 'Fid: fe[a-z0-9]{10}' | tail -1)
    feed=$(echo "$fid_line" | grep -oE 'Fid: fe[a-z0-9]{10}' | cut -d' ' -f2)
    if [ -n "$fid_line" ]; then
      state=$(echo "$fid_line" | sed -n 's|^[0-9/]* [0-9:]* \([A-Za-z]*\),.*|\1|p')
      [ -n "$state" ] && echo "cap_feed_state=$state"
    fi
    if [ -z "$feed" ]; then
      # fallback: any feed-shaped token in the boot journal (pre-status-line
      # tssvc builds), else the cached value
      feed=$($JCTL -u tssvc -b -o cat --no-pager 2>/dev/null |
             grep -oE '\bfe[a-z0-9]{10}\b' | tail -1)
    fi
    if [ -n "$feed" ]; then
      echo "$feed" > "$FEED_CACHE" 2>/dev/null
    else
      feed=$(cat "$FEED_CACHE" 2>/dev/null)
    fi
    [ -n "$feed" ] && echo "cap_feed=$feed"
  fi
fi

cd "$VISION_HOME" 2>/dev/null || { echo "vision_service=missing"; exit 0; }

echo "sw_version=$(grep -m1 "SOFTWARE_VERSION=" utilities.sh 2>/dev/null | cut -d\' -f2)"
# Last connectivity-watchdog reboot (checkInternet.sh stamps one line per
# reboot, UTC) — lets the server attribute 0x0b boots to failed network pings.
[ -f .net_reboot_log ] && echo "net_reboot_last=$(tail -1 .net_reboot_log)"
# Identify the active schedule by content hash — the server maps hash -> catalogue name.
[ -f schedule.wpi ] && echo "schedule_md5=$(md5sum schedule.wpi | cut -d' ' -f1)"
# Latest camera settings snapshot (written daily by camera.sh logsettings).
if [ -f cameraSettings.log ]; then
  echo "camera_snapshot=$(grep " model='" cameraSettings.log | tail -1)"
fi

LOCK=/var/lock/wittypi.i2c.lock
exec 9>"$LOCK" 2>/dev/null || exec 9<"$LOCK" 2>/dev/null || { echo "i2c=no_lockfile"; exit 0; }
if flock -w 20 9 2>/dev/null; then
  . ./utilities.sh 2>/dev/null
  if is_mc_connected; then
    echo "fw_rev=$(i2c_read $I2C_BUS $I2C_MC_ADDRESS $I2C_FW_REVISION)"
    echo "boot_reason=$(i2c_read $I2C_BUS $I2C_MC_ADDRESS $I2C_ACTION_REASON)"
    echo "input_voltage=$(get_input_voltage)"
    echo "output_current=$(get_output_current)"
    # get_temperature prints "36.125°C / 97.025°F" — take the leading number
    # only (tr -dc mashed both scales together: "36.12597.025").
    echo "temperature_c=$(get_temperature | grep -oE '^-?[0-9]+\.?[0-9]*' | head -1)"
    echo "next_startup=$(get_startup_time_local 2>/dev/null)"
    echo "next_shutdown=$(get_shutdown_time_local 2>/dev/null)"
  else
    echo "i2c=wittypi_missing"
  fi
  flock -u 9
else
  echo "i2c=lock_busy"
fi
