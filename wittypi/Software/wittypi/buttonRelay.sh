#!/bin/bash
# file: buttonRelay.sh
#
# Watches the Witty Pi 4 push button and drives a relay GPIO in response.
# Entirely Pi-side - NO firmware change required.
#
# How it works: the Witty Pi 4 button is hardwired to BOTH the on-board
# microcontroller AND BCM GPIO-4 on the Pi header; pressing it pulls the
# line LOW. Since firmware Rev 14 the button is inert while the Pi is
# running (the MCU only uses it to wake the device from sleep) and the
# firmware never drives the line, so presses are free for application use.
#
# Configuration lives in buttonRelay.conf next to this script. The conf
# file is created on first run and is NOT in the deploy file list, so
# per-device settings survive fleet updates. Default (v5.34+): 'auto' -
# ENABLED on firmware Rev 14+ (clean button line), disabled on older
# firmware. Default relay pin: BCM 13 (physical pin 33, wiringPi 23),
# toggle mode.
#
# CAUTION - firmware Rev <= 13: the microcontroller PULSES this same line
# during alarm / low-voltage shutdowns (emulateButtonClick), which this
# watcher would see as presses. A runtime warning is logged when firmware
# below Rev 14 is detected. Upgrade to Rev 14+ for clean operation.
#
# CAUTION - presses while the device is asleep: the firmware wakes the Pi
# (maintenance override, unchangeable without reflashing). That pre-boot
# press does not reach this watcher; set RELAY_ON_WAKE_CLICK=1 to have
# the boot-time press fire the relay action once after startup instead.

cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$cur_dir/utilities.sh"

TIME_UNKNOWN=0

# v5.36: unconditional startup breadcrumb - if this line is missing from
# wittyPi.log after a daemon start, the spawn itself never happened
# (stale daemon.sh on the device); every exit below also logs its reason,
# so "watcher not running" is always diagnosable from the log alone.
log "ButtonRelay: starting (pid $$)."

CONF="$cur_dir/buttonRelay.conf"

# v5.33: one-time migration. The v5.32 default conf shipped disabled with
# RELAY_PIN=27; if the device's conf is still byte-identical to that old
# default (never edited), replace it with the new defaults (auto-enable
# on Rev 14+, RELAY_PIN=23). Any edited conf is left untouched.
old_default=$(cat <<'OLDCONFEOF'
# Witty Pi button->relay watcher configuration.
# This file is per-device state: deploys never overwrite it.

# Master switch: set to 1 to enable the watcher.
ENABLE_BUTTON_RELAY=0

# BCM pin driving the relay module (default 27 = physical pin 13; free on
# Witty Pi 4 - the HAT itself uses BCM 2/3 (I2C), 4 (button), 14 (TXD),
# 17 (SYS_UP)). Use a relay MODULE with a transistor/opto input, never a
# bare relay coil - Pi GPIO cannot drive a coil and has no flyback diode.
RELAY_PIN=27

# 'toggle' = each press flips the relay state.
# 'pulse'  = each press energises the relay for PULSE_SECONDS.
RELAY_MODE=toggle
PULSE_SECONDS=2

# 1 if the relay module is active-HIGH, 0 if active-LOW.
RELAY_ACTIVE=1

# Fire the relay action once at startup when this boot was caused by a
# button press while the device was asleep (wake reason = click).
RELAY_ON_WAKE_CLICK=0
OLDCONFEOF
)
# v5.34: the short-lived v5.33 default used RELAY_PIN=23 (a wiringPi
# number given in error - the intended pin was BCM 13). Migrate that
# untouched default too.
old_default2=$(cat <<'OLD2CONFEOF'
# Witty Pi button->relay watcher configuration.
# This file is per-device state: deploys never overwrite it.

# Master switch:
#   auto = enabled when the Witty Pi runs firmware Rev 14+ (the button
#          line is clean there; on Rev <= 13 the MCU pulses it during
#          alarm shutdowns, so auto stays off)
#   1    = always on (any firmware - expect false triggers on Rev <= 13)
#   0    = always off
ENABLE_BUTTON_RELAY=auto

# BCM pin driving the relay module (default 23 = physical pin 16; free on
# Witty Pi 4 - the HAT itself uses BCM 2/3 (I2C), 4 (button), 14 (TXD),
# 17 (SYS_UP)). Use a relay MODULE with a transistor/opto input, never a
# bare relay coil - Pi GPIO cannot drive a coil and has no flyback diode.
RELAY_PIN=23

# 'toggle' = each press flips the relay state.
# 'pulse'  = each press energises the relay for PULSE_SECONDS.
RELAY_MODE=toggle
PULSE_SECONDS=2

# 1 if the relay module is active-HIGH, 0 if active-LOW.
RELAY_ACTIVE=1

# Fire the relay action once at startup when this boot was caused by a
# button press while the device was asleep (wake reason = click).
RELAY_ON_WAKE_CLICK=0
OLD2CONFEOF
)
cur_conf=$(cat "$CONF" 2>/dev/null)
if [ -f "$CONF" ] && { [ "$cur_conf" = "$old_default" ] || [ "$cur_conf" = "$old_default2" ]; }; then
  rm -f "$CONF"
  log 'ButtonRelay: migrating untouched default config to current defaults.'
fi

# v5.35: single-instance enforcement. The daemon spawns a watcher on
# every boot AND on every deploy-triggered restart - without this,
# watchers accumulate and EACH one toggles the relay per press. Two
# instances with out-of-phase state cancel each other: the log shows
# toggles but the pin never (reliably) changes. The newest instance
# always replaces the oldest so config changes take effect immediately.
PIDFILE=/var/run/wittypi_buttonrelay.pid
if ! touch "$PIDFILE" 2>/dev/null; then
  PIDFILE=/tmp/wittypi_buttonrelay.pid   # non-root fallback
fi
oldpid=$(cat "$PIDFILE" 2>/dev/null)
# v5.36: only kill the old pid if it really is a buttonRelay instance.
# After a reboot the stale pidfile usually points at a REUSED pid owned
# by some unrelated boot process - killing it blindly was a real hazard.
if [[ "$oldpid" =~ ^[0-9]+$ ]] && [ "$oldpid" != "$$" ] && kill -0 "$oldpid" 2>/dev/null \
   && grep -qa buttonRelay /proc/$oldpid/cmdline 2>/dev/null; then
  # reap the blocked `gpio wfi` child first, then the old watcher
  pkill -P "$oldpid" 2>/dev/null
  kill "$oldpid" 2>/dev/null
  log "ButtonRelay: replaced previous watcher (pid $oldpid)."
fi
echo $$ > "$PIDFILE" 2>/dev/null

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<'CONFEOF'
# Witty Pi button->relay watcher configuration.
# This file is per-device state: deploys never overwrite it.

# Master switch:
#   auto = enabled when the Witty Pi runs firmware Rev 14+ (the button
#          line is clean there; on Rev <= 13 the MCU pulses it during
#          alarm shutdowns, so auto stays off)
#   1    = always on (any firmware - expect false triggers on Rev <= 13)
#   0    = always off
ENABLE_BUTTON_RELAY=auto

# BCM pin driving the relay module (default 13 = physical pin 33, i.e.
# wiringPi pin 23; free on Witty Pi 4 - the HAT itself uses BCM 2/3
# (I2C), 4 (button), 14 (TXD), 17 (SYS_UP)). Use a relay MODULE with a
# transistor/opto input, never a bare relay coil - Pi GPIO cannot drive
# a coil and has no flyback diode.
RELAY_PIN=13

# 'toggle' = each press flips the relay state.
# 'pulse'  = each press energises the relay for PULSE_SECONDS.
RELAY_MODE=toggle
PULSE_SECONDS=2

# 1 if the relay module is active-HIGH, 0 if active-LOW.
RELAY_ACTIVE=1

# Fire the relay action once at startup when this boot was caused by a
# button press while the device was asleep (wake reason = click).
RELAY_ON_WAKE_CLICK=0
CONFEOF
  chmod 644 "$CONF"
  log 'ButtonRelay: created default buttonRelay.conf (auto - enabled on Rev 14+ firmware).'
fi
. "$CONF"

BUTTON_PIN=4   # BCM - hardwired to the Witty Pi push button

# read the firmware revision once - drives both the auto-enable decision
# and the old-firmware warning
fw=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_FW_REVISION)
fw_rev=-1
if [[ $fw =~ ^0x[0-9a-fA-F]{2}$ ]]; then
  fw_rev=$(($fw))
fi

case "$ENABLE_BUTTON_RELAY" in
  auto)
    if [ $fw_rev -ge 14 ]; then
      log "ButtonRelay: auto-enabled (firmware Rev $fw_rev)."
    elif [ $fw_rev -ge 0 ]; then
      log "ButtonRelay: auto mode - firmware Rev $fw_rev pulses the button line during alarm shutdowns; staying disabled (set ENABLE_BUTTON_RELAY=1 to force)."
      exit 0
    else
      log 'ButtonRelay: auto mode - firmware revision unreadable; staying disabled this boot.'
      exit 0
    fi
    ;;
  1)
    if [ $fw_rev -ge 0 ] && [ $fw_rev -lt 14 ]; then
      log "ButtonRelay: WARNING - firmware Rev $fw_rev pulses the button line during alarm shutdowns; expect false relay triggers. Rev 14+ recommended."
    fi
    ;;
  *)
    log "ButtonRelay: disabled by config (ENABLE_BUTTON_RELAY=$ENABLE_BUTTON_RELAY)."
    exit 0
    ;;
esac

RELAY_OFF=$((1 - RELAY_ACTIVE))

gpio -g mode $BUTTON_PIN in
gpio -g mode $BUTTON_PIN up
gpio -g mode $RELAY_PIN out
gpio -g write $RELAY_PIN $RELAY_OFF
relay_state=$RELAY_OFF

fire_relay()
{
  if [ "$RELAY_MODE" = "pulse" ]; then
    gpio -g write $RELAY_PIN $RELAY_ACTIVE
    sleep $PULSE_SECONDS
    gpio -g write $RELAY_PIN $RELAY_OFF
    log "ButtonRelay: relay (BCM $RELAY_PIN) pulse fired (${PULSE_SECONDS}s)."
  else
    relay_state=$((1 - relay_state))
    gpio -g write $RELAY_PIN $relay_state
    local st='OFF'
    [ $relay_state -eq $RELAY_ACTIVE ] && st='ON'
    log "ButtonRelay: relay (BCM $RELAY_PIN) toggled $st (level $relay_state)."
  fi
}

log "ButtonRelay: watching button (BCM $BUTTON_PIN) -> relay (BCM $RELAY_PIN), mode=$RELAY_MODE."

# if this boot itself was a button-wake, optionally count it as a press
if [ "$RELAY_ON_WAKE_CLICK" = "1" ]; then
  reason=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_ACTION_REASON)
  if [ "$reason" == "$REASON_CLICK" ]; then
    log 'ButtonRelay: this boot was a button wake - firing relay action once.'
    fire_relay
  fi
fi

# main loop: block on a falling edge via wiringPi's wait-for-interrupt;
# if this gpio build lacks wfi (exits fast with an error), poll instead.
wfi_ok=1
while true; do
  if [ $wfi_ok -eq 1 ]; then
    t0=$SECONDS
    if ! gpio -g wfi $BUTTON_PIN falling 2>/dev/null; then
      if [ $((SECONDS - t0)) -lt 2 ]; then
        wfi_ok=0
        log 'ButtonRelay: gpio wfi unavailable - using polling fallback.'
      fi
      continue
    fi
  else
    while [ "$(gpio -g read $BUTTON_PIN)" = "1" ]; do
      sleep 0.2
    done
  fi

  # debounce: confirm still pressed after 50ms
  sleep 0.05
  if [ "$(gpio -g read $BUTTON_PIN)" != "0" ]; then
    continue
  fi

  fire_relay

  # wait for release + settle so a held button fires exactly once
  while [ "$(gpio -g read $BUTTON_PIN)" = "0" ]; do
    sleep 0.1
  done
  sleep 0.2
done
