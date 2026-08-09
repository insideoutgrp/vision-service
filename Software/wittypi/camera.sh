[ -z $BASH ] && { exec bash "$0" "$@" || exit; }
#!/bin/bash
# file: camera.sh
#
# visIOn camera control: view and change capture parameters on the attached
# Canon DSLR (EOS 1300D / 2000D) over USB via gphoto2.
#
# The camera has no independent power: it is fed through the relay driven
# by the button->relay watcher (BCM 13 by default = physical pin 33 =
# wiringPi 23, configured in buttonRelay.conf). Any camera operation must
# therefore first energise the relay, then wait for the camera to enumerate
# on USB (lsusb, Canon vendor 04a9) before issuing gphoto2 commands.
#
# Usage:
#   camera.sh                 interactive menu (view + change parameters)
#   camera.sh status          power/detection state + all current values
#   camera.sh list            list supported parameter names
#   camera.sh get <param>     show current value and available choices
#   camera.sh set <param> <value>   set a parameter (value or choice index)
#   camera.sh focus           list the 9 focus points and frame size
#   camera.sh focus <point> [af]    move the focus square (optionally AF there)
#   camera.sh logsettings     daily settings snapshot to cameraSettings.log
#                             (cron-driven; no-op if already logged today)
#   camera.sh shuttercount    read the body's shutter actuation count
#   camera.sh on | off        camera power relay control
#
# Notes:
# - Choices are read live from the camera, not hard-coded: aperture depends
#   on the fitted lens, and available ranges differ between bodies.
# - The mode dial gates what is settable (e.g. aperture requires M/Av);
#   read-only parameters are reported as such rather than half-applied.
# - Power is left ON after get/set so scripted sequences don't power-cycle
#   the camera per command; call `camera.sh off` when done.

cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$cur_dir/utilities.sh"

TIME_UNKNOWN=0

# ---------------------------------------------------------------- parameters
# name|gphoto2 config path|short description
# Paths verified against Canon EOS 1300D / 2000D gphoto2 trees.
PARAMS='
iso|/main/imgsettings/iso|ISO speed
aperture|/main/capturesettings/aperture|Aperture (f-number)
shutter|/main/capturesettings/shutterspeed|Shutter speed
expcomp|/main/capturesettings/exposurecompensation|Exposure compensation
wb|/main/imgsettings/whitebalance|White balance
format|/main/imgsettings/imageformat|Image format / quality
metering|/main/capturesettings/meteringmode|Metering mode
style|/main/capturesettings/picturestyle|Picture style
drive|/main/capturesettings/drivemode|Drive mode
focusmode|/main/capturesettings/focusmode|Focus mode
target|/main/settings/capturetarget|Capture target (RAM / card)
aemode|/main/capturesettings/autoexposuremode|Exposure mode (dial - usually read-only)
'

param_path()  { echo "$PARAMS" | grep "^$1|" | cut -d'|' -f2; }
param_desc()  { echo "$PARAMS" | grep "^$1|" | cut -d'|' -f3; }
param_names() { echo "$PARAMS" | grep -v '^$' | cut -d'|' -f1; }

# ------------------------------------------------------------- focus points
# The liveview focus square is moved with eoszoomposition=x,y in FULL-FRAME
# pixel coordinates, so the grid must be computed from the sensor
# resolution of the attached body - never hard-coded (1300D: 5184x3456,
# 2000D: 6000x4000). Nine common points on a 3x3 grid at 1/6, 1/2 and 5/6
# of the frame: name|x-sixths|y-sixths.
FOCUS_POINTS='
top-left|1|1
top-centre|3|1
top-right|5|1
middle-left|1|3
centre|3|3
middle-right|5|3
bottom-left|1|5
bottom-centre|3|5
bottom-right|5|5
'
focus_names() { echo "$FOCUS_POINTS" | grep -v '^$' | cut -d'|' -f1; }

# sets FRAME_W / FRAME_H. Order: explicit override (CAMERA_FRAME_W/H in
# buttonRelay.conf) > model lookup > logged 1300D fallback. Globals rather
# than echo so the model-unknown path can log without polluting the result.
camera_frame_size()
{
  if [ -n "$CAMERA_FRAME_W" ] && [ -n "$CAMERA_FRAME_H" ]; then
    FRAME_W=$CAMERA_FRAME_W
    FRAME_H=$CAMERA_FRAME_H
    return
  fi
  local model=$(timeout $GPHOTO2_TIMEOUT gphoto2 --auto-detect 2>/dev/null | sed -n '3p')
  case "$model" in
    *2000D*|*'Rebel T7'*|*'Kiss X90'*)
      FRAME_W=6000; FRAME_H=4000 ;;
    *1300D*|*'Rebel T6'*|*'Kiss X80'*)
      FRAME_W=5184; FRAME_H=3456 ;;
    *)
      FRAME_W=5184; FRAME_H=3456
      log "Camera: WARN - unrecognised model for frame size ('${model:-none}'); assuming ${FRAME_W}x${FRAME_H}. Set CAMERA_FRAME_W/CAMERA_FRAME_H in buttonRelay.conf to override."
      ;;
  esac
}

# ---------------------------------------------------------------- camera power
# The camera is powered through the button->relay watcher's relay. Reuse its
# per-device config so both features always agree on the pin and polarity;
# CAMERA_RELAY_PIN in buttonRelay.conf overrides if the camera ever moves to
# its own relay channel.
RELAY_PIN=13
RELAY_ACTIVE=1
[ -f "$cur_dir/buttonRelay.conf" ] && . "$cur_dir/buttonRelay.conf"
CAMERA_RELAY_PIN="${CAMERA_RELAY_PIN:-$RELAY_PIN}"
RELAY_OFF=$((1 - RELAY_ACTIVE))

CAMERA_USB_ID='04a9'                              # Canon Inc. USB vendor id
CAMERA_BOOT_TIMEOUT="${CAMERA_BOOT_TIMEOUT:-25}"  # secs to wait for USB after power-on
GPHOTO2_TIMEOUT="${GPHOTO2_TIMEOUT:-30}"          # secs per gphoto2 call (wedged PTP guard)

camera_power_state()
{
  gpio -g mode $CAMERA_RELAY_PIN out 2>/dev/null
  local level=$(gpio -g read $CAMERA_RELAY_PIN 2>/dev/null)
  if [ "$level" = "$RELAY_ACTIVE" ]; then echo 'on'; else echo 'off'; fi
}

camera_usb_detected()
{
  lsusb 2>/dev/null | grep -qi "ID $CAMERA_USB_ID"
}

camera_power_on()
{
  gpio -g mode $CAMERA_RELAY_PIN out
  if [ "$(camera_power_state)" = "on" ]; then
    if camera_usb_detected; then
      return 0
    fi
    # relay already energised but no camera on USB yet - fall through to wait
  else
    gpio -g write $CAMERA_RELAY_PIN $RELAY_ACTIVE
    log "Camera: relay (BCM $CAMERA_RELAY_PIN) energised - powering camera up."
  fi
  local waited=0
  while [ $waited -lt $CAMERA_BOOT_TIMEOUT ]; do
    if camera_usb_detected; then
      log "Camera: detected on USB after ${waited}s."
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "Camera: WARN - not detected on USB ${CAMERA_BOOT_TIMEOUT}s after power-on (relay BCM $CAMERA_RELAY_PIN active, lsusb shows no $CAMERA_USB_ID device)."
  return 1
}

camera_power_off()
{
  gpio -g mode $CAMERA_RELAY_PIN out
  gpio -g write $CAMERA_RELAY_PIN $RELAY_OFF
  log "Camera: relay (BCM $CAMERA_RELAY_PIN) released - camera powered off."
}

# gvfs' gphoto2 volume monitor (desktop images only) grabs the camera the
# moment it enumerates and gphoto2 then fails with "Could not claim the USB
# device". Harmless no-op on Raspberry Pi OS Lite.
release_usb_claims()
{
  pkill -f gvfs-gphoto2-volume-monitor 2>/dev/null || true
  pkill -f gvfsd-gphoto2 2>/dev/null || true
}

# power on + verify gphoto2 can actually talk to the camera
ensure_camera_ready()
{
  if ! hash gphoto2 2>/dev/null; then
    echo 'ERROR: gphoto2 is not installed. Re-run the installation script.'
    exit 1
  fi
  if ! hash gpio 2>/dev/null; then
    echo 'ERROR: wiringPi (gpio) is not installed. Re-run the installation script.'
    exit 1
  fi
  if ! camera_power_on; then
    echo "ERROR: camera did not appear on USB within ${CAMERA_BOOT_TIMEOUT}s of relay power-on."
    echo '       Check the relay wiring, camera power coupler and USB cable.'
    exit 1
  fi
  release_usb_claims
  if ! timeout $GPHOTO2_TIMEOUT gphoto2 --auto-detect 2>/dev/null | grep -qi usb; then
    log 'Camera: WARN - on USB but gphoto2 --auto-detect does not list it.'
    echo 'ERROR: camera is on USB but gphoto2 cannot see it (busy or unsupported?).'
    exit 1
  fi
}

# ---------------------------------------------------------------- gphoto2 I/O
# get_config <path>: prints the raw gphoto2 block (Label/Readonly/Current/
# Choice lines) for one parameter
get_config()
{
  timeout $GPHOTO2_TIMEOUT gphoto2 --get-config "$1" 2>/dev/null
}

# set_config <name> <path> <value>: resolves the value against the camera's
# live choice list (exact match preferred, else a bare index), sets it, and
# verifies by reading back. Returns non-zero with a message on any failure.
set_config()
{
  local name="$1" path="$2" want="$3"
  local block=$(get_config "$path")
  if [ -z "$block" ]; then
    echo "  ERROR: could not read $name from the camera."
    return 1
  fi
  if echo "$block" | grep -q '^Readonly: 1'; then
    echo "  $name is read-only right now (set by the mode dial on the camera)."
    return 1
  fi
  local index=$(echo "$block" | sed -n "s/^Choice: \([0-9]*\) $(echo "$want" | sed 's/[]\/$*.^[]/\\&/g')\$/\1/p" | head -1)
  if [ -z "$index" ] && [[ "$want" =~ ^[0-9]+$ ]]; then
    # no choice text matched - accept a bare choice index
    if echo "$block" | grep -q "^Choice: $want "; then
      index="$want"
    fi
  fi
  if [ -z "$index" ]; then
    echo "  ERROR: '$want' is not an available choice for $name. Valid choices:"
    echo "$block" | sed -n 's/^Choice: /    /p'
    return 1
  fi
  if ! timeout $GPHOTO2_TIMEOUT gphoto2 --set-config-index "$path=$index" 2>/dev/null; then
    echo "  ERROR: gphoto2 failed setting $name (mode dial may not allow it)."
    log "Camera: FAILED setting $name (index $index)."
    return 1
  fi
  # verify: read back and compare
  local now=$(get_config "$path" | sed -n 's/^Current: //p')
  local wanted_text=$(echo "$block" | sed -n "s/^Choice: $index //p")
  if [ "$now" = "$wanted_text" ]; then
    echo "  $name set to: $now"
    log "Camera: $name set to '$now'."
    return 0
  else
    echo "  ERROR: set appeared to succeed but read-back shows '$now' (wanted '$wanted_text')."
    log "Camera: $name set verify FAILED - read back '$now', wanted '$wanted_text'."
    return 1
  fi
}

# print "name = current" for every parameter. One gphoto2 call per
# parameter - slower than batching, but a parameter missing on a given
# body/mode then shows as <unreadable> instead of misaligning the rest.
show_all_current()
{
  local n cur
  for n in $(param_names); do
    cur=$(get_config "$(param_path $n)" | sed -n 's/^Current: //p')
    printf '  %-11s %-24s %s\n' "$n" "${cur:-<unreadable>}" "($(param_desc $n))"
  done
}

# set_focus_point <name> [af]: move the liveview focus square to a named
# grid point; with 'af', also drive autofocus there. Assumes
# ensure_camera_ready has run. The EOS only accepts a zoom/focus position
# while liveview is up, so the viewfinder is raised around the operation
# and dropped again afterwards (mirror down, saves battery and heat).
set_focus_point()
{
  local name="$1" do_af="$2"
  [ "$name" = "center" ] && name='centre'
  local row=$(echo "$FOCUS_POINTS" | grep "^$name|")
  if [ -z "$row" ]; then
    echo "  Unknown focus point '$name'. Points:"
    focus_names | sed 's/^/    /'
    return 1
  fi
  camera_frame_size
  local xs=$(echo "$row" | cut -d'|' -f2)
  local ys=$(echo "$row" | cut -d'|' -f3)
  local x=$((FRAME_W * xs / 6))
  local y=$((FRAME_H * ys / 6))
  # liveview up - without it the body rejects/ignores the position
  if ! timeout $GPHOTO2_TIMEOUT gphoto2 --set-config viewfinder=1 2>/dev/null; then
    log 'Camera: WARN - could not raise liveview (viewfinder=1); trying to set focus point anyway.'
  fi
  if timeout $GPHOTO2_TIMEOUT gphoto2 --set-config eoszoomposition=$x,$y 2>/dev/null; then
    echo "  Focus square set to $name ($x,$y of ${FRAME_W}x${FRAME_H})."
    log "Camera: focus square set to $name ($x,$y of ${FRAME_W}x${FRAME_H})."
  else
    echo "  ERROR: failed setting focus square (is liveview available in this mode?)."
    log "Camera: FAILED setting focus square to $name ($x,$y)."
    timeout $GPHOTO2_TIMEOUT gphoto2 --set-config viewfinder=0 2>/dev/null
    return 1
  fi
  if [ "$do_af" = "af" ]; then
    if timeout $GPHOTO2_TIMEOUT gphoto2 --set-config autofocusdrive=1 2>/dev/null; then
      echo '  Autofocus driven at the new point.'
      log "Camera: autofocus driven at $name."
    else
      echo '  WARN: autofocus drive failed (lens on MF, or no focus lock).'
      log "Camera: WARN - autofocus drive at $name failed."
    fi
  fi
  # liveview back down
  timeout $GPHOTO2_TIMEOUT gphoto2 --set-config viewfinder=0 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- CLI actions
shutter_count()
{
  get_config /main/status/shuttercounter | sed -n 's/^Current: //p'
}

do_status()
{
  echo "  Power relay:  $(camera_power_state) (BCM $CAMERA_RELAY_PIN)"
  if camera_usb_detected; then
    echo "  USB:          detected ($(lsusb | grep -i "ID $CAMERA_USB_ID" | head -1 | sed 's/^.*ID /ID /'))"
  else
    echo '  USB:          not detected'
    return 0
  fi
  ensure_camera_ready
  echo "  Lens:         $(get_config /main/status/lensname | sed -n 's/^Current: //p')"
  echo "  Shutter count: $(shutter_count)"
  echo '  Current settings:'
  show_all_current
}

do_shuttercount()
{
  ensure_camera_ready
  local sc=$(shutter_count)
  if [ -z "$sc" ]; then
    echo '  ERROR: could not read the shutter counter from the camera.'
    exit 1
  fi
  echo "  Shutter count: $sc"
  log "Camera: shutter count $sc."
}

do_get()
{
  local name="$1"
  local path=$(param_path "$name")
  if [ -z "$path" ]; then
    echo "Unknown parameter '$name'. Use: camera.sh list"
    exit 1
  fi
  ensure_camera_ready
  local block=$(get_config "$path")
  if [ -z "$block" ]; then
    echo "ERROR: could not read $name from the camera."
    exit 1
  fi
  echo "  $name ($(param_desc $name))"
  echo "$block" | sed -n 's/^Current: /  Current: /p'
  [ "$(echo "$block" | sed -n 's/^Readonly: //p')" = "1" ] && echo '  (read-only right now)'
  echo '  Choices:'
  echo "$block" | sed -n 's/^Choice: /    /p'
}

do_set()
{
  local name="$1" value="$2"
  local path=$(param_path "$name")
  if [ -z "$path" ]; then
    echo "Unknown parameter '$name'. Use: camera.sh list"
    exit 1
  fi
  if [ -z "$value" ]; then
    echo "Usage: camera.sh set $name <value>"
    exit 1
  fi
  ensure_camera_ready
  set_config "$name" "$path" "$value"
}

do_list()
{
  echo '  Parameters:'
  local n
  for n in $(param_names); do
    printf '    %-11s %s\n' "$n" "$(param_desc $n)"
  done
  echo '  Focus points (camera.sh focus <point> [af]):'
  focus_names | sed 's/^/    /'
}

do_focus()
{
  local name="$1" do_af="$2"
  if [ -z "$name" ]; then
    ensure_camera_ready
    camera_frame_size
    echo "  Frame size: ${FRAME_W}x${FRAME_H}"
    echo '  Focus points (3x3 grid at 1/6, 1/2, 5/6 of the frame):'
    local p
    for p in $(focus_names); do
      local xs=$(echo "$FOCUS_POINTS" | grep "^$p|" | cut -d'|' -f2)
      local ys=$(echo "$FOCUS_POINTS" | grep "^$p|" | cut -d'|' -f3)
      printf '    %-14s %s,%s\n' "$p" "$((FRAME_W * xs / 6))" "$((FRAME_H * ys / 6))"
    done
    echo "  Usage: $0 focus <point> [af]"
    return 0
  fi
  ensure_camera_ready
  set_focus_point "$name" "$do_af"
}

# ---------------------------------------------------------------- interactive
interactive_menu()
{
  echo '================================================================================'
  echo '|                                                                              |'
  echo '|   visIOn - Camera Control (Canon EOS via gphoto2)                            |'
  echo '|                                                                              |'
  echo "|                              < Version ${SOFTWARE_VERSION} >                                |"
  echo '|                                                                              |'
  echo '================================================================================'
  ensure_camera_ready
  local model=$(timeout $GPHOTO2_TIMEOUT gphoto2 --auto-detect 2>/dev/null | sed -n '3p' | sed 's/  *usb.*//')
  [ -n "$model" ] && echo "  Camera: $model (shutter count: $(shutter_count))"
  while true; do
    echo ''
    echo '  Current settings:'
    local names=($(param_names))
    local i=1
    local n
    for n in "${names[@]}"; do
      local cur=$(get_config "$(param_path $n)" | sed -n 's/^Current: //p')
      printf '  %2d. %-11s %-24s %s\n' $i "$n" "${cur:-<unreadable>}" "($(param_desc $n))"
      i=$((i + 1))
    done
    echo '   f. Focus square (3x3 grid)'
    echo '   p. Power camera off and exit'
    echo '   q. Quit (leave camera powered)'
    read -p '  Choose a parameter to change: ' choice
    case "$choice" in
      q) exit 0 ;;
      p) camera_power_off; exit 0 ;;
      f)
        camera_frame_size
        echo "  Focus points (frame ${FRAME_W}x${FRAME_H}):"
        local pts=($(focus_names))
        local j=1
        local p
        for p in "${pts[@]}"; do
          printf '    %d. %s\n' $j "$p"
          j=$((j + 1))
        done
        read -p '  Focus point (number, empty to cancel): ' fsel
        [ -z "$fsel" ] && continue
        if ! [[ "$fsel" =~ ^[1-9]$ ]] || [ "$fsel" -gt "${#pts[@]}" ]; then
          echo '  Invalid choice.'
          continue
        fi
        read -p '  Drive autofocus at the new point? (y/N) ' faf
        local afarg=''
        [[ "$faf" =~ ^[Yy]$ ]] && afarg='af'
        set_focus_point "${pts[$((fsel - 1))]}" "$afarg"
        continue
        ;;
      ''|*[!0-9]*) echo '  Invalid choice.'; continue ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#names[@]}" ]; then
      echo '  Invalid choice.'
      continue
    fi
    local name="${names[$((choice - 1))]}"
    local path=$(param_path "$name")
    local block=$(get_config "$path")
    if [ -z "$block" ]; then
      echo "  ERROR: could not read $name from the camera."
      continue
    fi
    if echo "$block" | grep -q '^Readonly: 1'; then
      echo "  $name is read-only right now (set by the mode dial on the camera)."
      continue
    fi
    echo "  $name - current: $(echo "$block" | sed -n 's/^Current: //p')"
    echo '  Choices:'
    echo "$block" | sed -n 's/^Choice: \([0-9]*\) \(.*\)/    \1. \2/p'
    read -p '  New value (choice number, empty to cancel): ' sel
    [ -z "$sel" ] && continue
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || ! echo "$block" | grep -q "^Choice: $sel "; then
      echo '  Invalid choice number.'
      continue
    fi
    set_config "$name" "$path" "$sel"
  done
}

# ------------------------------------------------------- daily settings log
# One snapshot line per day in cameraSettings.log so drift in camera/lens
# settings is visible over time (lens swap, knocked mode dial, changed ISO).
# Cron calls this every 15 min; the date stamp makes all but the first
# successful (or first failed) run of the day a no-op, so short wake
# windows still get their snapshot without hourly relay cycling.
SETTINGS_LOG="$cur_dir/cameraSettings.log"
SETTINGS_STAMP="$cur_dir/.camera_log_date"

settings_log_line()
{
  echo "[$(TZ=$LOCAL_TZ date +'%Y-%m-%d %H:%M:%S')] $1" >> "$SETTINGS_LOG"
  # Two writers share these state files: the root cron and operator/agent runs
  # as pi. Whoever creates them must leave them writable for the other, or the
  # loser gets "Permission denied" on every append (same philosophy as the
  # world-writable I2C lock). chmod only works for the owner - ignore failure.
  chmod 666 "$SETTINGS_LOG" 2>/dev/null
}

stamp_today()
{
  echo "$1" > "$SETTINGS_STAMP"
  chmod 666 "$SETTINGS_STAMP" 2>/dev/null
}

# extract_val "<line>" <key>: value of key='...' in a snapshot line
extract_val()
{
  echo " $1" | sed -n "s/.* $2='\([^']*\)'.*/\1/p"
}

do_logsettings()
{
  local today=$(TZ=$LOCAL_TZ date +%Y-%m-%d)
  [ "$(cat "$SETTINGS_STAMP" 2>/dev/null)" = "$today" ] && exit 0
  # stay out of the boot window (daemon startup, schedule engine)
  local up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 999)
  [ "$up" -lt 60 ] && exit 0   # no stamp - retry on the next cron tick
  if ! hash gphoto2 2>/dev/null || ! hash gpio 2>/dev/null; then
    stamp_today "$today"
    settings_log_line 'WARN gphoto2/gpio not installed - no settings snapshot today.'
    exit 0
  fi
  local prev_power=$(camera_power_state)
  # on failure: stamp anyway, one failure line per day. Retrying hourly on
  # a dead/absent camera would just cycle the relay and drain the battery.
  if ! camera_power_on; then
    stamp_today "$today"
    settings_log_line 'WARN camera not detected on USB - no settings snapshot today.'
    log 'Camera: daily settings snapshot skipped - camera not detected.'
    [ "$prev_power" = "off" ] && camera_power_off
    exit 0
  fi
  release_usb_claims
  local model=$(timeout $GPHOTO2_TIMEOUT gphoto2 --auto-detect 2>/dev/null | sed -n '3p' | sed 's/  *usb.*//;s/  *$//')
  local lens=$(get_config /main/status/lensname | sed -n 's/^Current: //p')
  local batt=$(get_config /main/status/batterylevel | sed -n 's/^Current: //p')
  local sc=$(shutter_count)
  local pairs="model='${model:-?}' lens='${lens:-?}'"
  local n cur
  for n in $(param_names); do
    cur=$(get_config "$(param_path $n)" | sed -n 's/^Current: //p')
    pairs="$pairs $n='${cur:-?}'"
  done
  # shuttercount + battery last and excluded from change detection - both
  # move naturally every day (shutter wear is tracked BY the daily line)
  settings_log_line "$pairs shuttercount='${sc:-?}' battery='${batt:-?}'"
  stamp_today "$today"
  log 'Camera: daily settings snapshot written to cameraSettings.log.'
  # change detection vs the previous snapshot (ignore WARN/CHANGED lines)
  local prev=$(grep " model='" "$SETTINGS_LOG" | tail -2 | head -1 | sed 's/^\[[^]]*\] //')
  if [ -n "$prev" ] && [ "$(echo "$prev" | sed "s/ shuttercount='[^']*'//;s/ battery='[^']*'//")" != "$pairs" ]; then
    local changed='' k pv cv
    for k in model lens $(param_names); do
      pv=$(extract_val "$prev" "$k")
      cv=$(extract_val "$pairs" "$k")
      [ "$pv" != "$cv" ] && changed="$changed $k:'$pv'->'$cv'"
    done
    if [ -n "$changed" ]; then
      settings_log_line "CHANGED since previous snapshot:$changed"
      log "Camera: settings changed since previous snapshot:$changed"
    fi
  fi
  [ "$prev_power" = "off" ] && camera_power_off
  exit 0
}

# ---------------------------------------------------------------- entry point
case "$1" in
  '')       interactive_menu ;;
  status)   do_status ;;
  list)     do_list ;;
  get)      do_get "$2" ;;
  set)      do_set "$2" "$3" ;;
  focus)    do_focus "$2" "$3" ;;
  logsettings) do_logsettings ;;
  shuttercount) do_shuttercount ;;
  on)       ensure_camera_ready && echo '  Camera powered and ready.' ;;
  off)      camera_power_off ;;
  *)
    echo "Usage: $0 [status|list|get <param>|set <param> <value>|focus [<point>] [af]|logsettings|shuttercount|on|off]"
    echo "       $0            (no arguments: interactive menu)"
    exit 1
    ;;
esac
