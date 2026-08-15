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
# Test-bench detection: if the office SSID is visible on a wifi scan the
# unit is physically at the office. Scan only (never connects); needs
# passwordless sudo (fleet default) — silently absent otherwise, and the
# server treats missing data as "not bench".
if command -v iw >/dev/null 2>&1; then
  # v5.51: unblock/raise the radio first (old fleet builds soft-block wifi),
  # capture stderr, and report scan FAILURES instead of staying silent —
  # a device that can't scan should say so, not just never flag.
  sudo -n rfkill unblock wifi 2>/dev/null
  sudo -n ip link set wlan0 up 2>/dev/null
  scan_out=$(sudo -n iw dev wlan0 scan 2>&1)
  if ! echo "$scan_out" | grep -q 'SSID:'; then
    sleep 2   # scans transiently fail while the radio settles / iface busy
    scan_out=$(sudo -n iw dev wlan0 scan 2>&1)
  fi
  if echo "$scan_out" | grep -q 'SSID:'; then
    if echo "$scan_out" | grep -q 'SSID: InsideOut'; then
      echo "office_ssid_visible=1"
    else
      echo "office_ssid_visible=0"
    fi
  else
    echo "office_scan_error=$(echo "$scan_out" | head -1 | tr -d "\"'" | cut -c1-60)"
  fi
else
  echo "office_scan_error=iw_not_installed"
fi

# Primary internal IP — the server maps subnet -> router type (site network).
ip_addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -z "$ip_addr" ] && ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$ip_addr" ] && echo "internal_ip=$ip_addr"

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
