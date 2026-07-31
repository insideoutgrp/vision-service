#!/bin/bash
# file: daemon.sh
#
# This script should be auto started, to support WittyPi hardware
#

# get current directory
cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# utilities
. "$cur_dir/utilities.sh"

TIME_UNKNOWN=1
log "Witty Pi daemon (v${SOFTWARE_VERSION}) is started."

# system information
os=$(get_os)
kernel=$(get_kernel)
arch=$(get_arch)
log "System: $os, Kernel: $kernel, Architecture: $arch"

# log Raspberry Pi model
pi_model=$(get_pi_model)
log "Running on $pi_model"

# verify timezone data is present - schedules will silently drift by 1h
# during BST if tzdata is missing
if [ ! -f "/usr/share/zoneinfo/$LOCAL_TZ" ]; then
  log "WARNING: tzdata for $LOCAL_TZ is missing. DST schedules will fail."
  log "  Run: sudo apt-get install -y tzdata"
fi

# check 1-wire confliction
if one_wire_confliction ; then
  log "Confliction: 1-Wire interface is enabled on GPIO-$HALT_PIN, which is also used by Witty Pi."
  log 'Witty Pi daemon can not work until you solve this confliction and reboot Raspberry Pi.'
  exit
fi

# do not run further if wiringPi is not installed
if ! hash gpio 2>/dev/null; then
  log 'Seems wiringPi is not installed, please run again the latest installation script to fix this.'
  exit
fi


# v5.29: serialise I2C access with the cron jobs (syncTime/checkInternet
# take flock -n on the same file and politely skip while we hold it).
# Their 60s uptime gate doesn't cover slow boots - the sync curls below
# alone can push our register writes past uptime 60-100s, exactly when a
# cron tick lands. Bounded wait so a stuck lock can never stall the boot.
# v5.30: create world-writable so the interactive wittyPi.sh menu (run as
# a normal user) can also lock it; fall back to a read fd when an old
# root-owned 644 file is in the way - flock works on read fds too.
LOCK=/var/lock/wittypi.i2c.lock
touch "$LOCK" 2>/dev/null && chmod 666 "$LOCK" 2>/dev/null
if [ -w "$LOCK" ]; then
  exec 9>"$LOCK"
elif [ -r "$LOCK" ]; then
  exec 9<"$LOCK"
fi
if ! flock -w 30 9 2>/dev/null; then
  log 'Could not acquire I2C lock within 30s - continuing without it.'
fi

# check if micro controller presents
has_mc=$(is_mc_connected)
for i in {1..5}; do
  if [ $has_mc == 1 ] ; then
    break;
  fi
  # wait for MCU ready
  log 'Witty Pi is not detected, retry in one second...'
  sleep 1
  has_mc=$(is_mc_connected)
done


if [ $has_mc == 1 ] ; then

  # log the I2C_CONF_RTC_OFFSET
  offset=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_RTC_OFFSET)
  log "RTC offset register has value $offset"

  # make sure register I2C_RTC_CTRL1 is 0
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_CTRL1 0
  
  # synchronize time: prefer network, then RTC as fallback
  # v5.29: only write system->RTC when network time was actually applied.
  # has_internet (curl HEAD) can succeed while the Date header is
  # unusable; system_to_rtc would then overwrite a CORRECT RTC with
  # fake-hwclock's last-shutdown time, inverting the whole schedule
  # until a later sync succeeded.
  net_synced=0
  if has_internet ; then
    log 'Internet available, syncing time from network...'
    if net_to_system ; then
      net_synced=1
      system_to_rtc
    fi
  fi
  if [ $net_synced -eq 0 ]; then
    if [ $(rtc_has_bad_time) == 1 ]; then
      log 'RTC has bad time and no usable network time, write system time into RTC'
      system_to_rtc
    else
      log 'No usable network time, using RTC time'
      rtc_to_system
    fi
  fi

  # check if system was shut down because of low-voltage
  recovery=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_LV_SHUTDOWN)
  if [ $recovery == '0x01' ]; then
    log 'System was previously shut down because of low-voltage.'
  fi
  # print out firmware ID
  firmwareID=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_ID)
  log "Firmware ID: $firmwareID"
  # print out firmware revision
  firmwareRev=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_FW_REVISION)
  log "Firmware Revison: $firmwareRev"

  # === Reliability backstops (v5.1+, requires firmware Rev 14) ===
  # Written every boot so a fresh device or one with corrupted EEPROM gets
  # the failsafes re-enabled.

  # Guaranteed Wake: force the firmware to wake the Pi at least once every
  # 24 hours regardless of alarm/RTC/LV state. Primary recovery mechanism.
  enable_guaranteed_wake 24 hours

  # Explicitly CLEAR IGNORE_LV_SHUTDOWN (previously set to 1 in v5.21+ as
  # a defensive measure). With it set, the firmware's sleep-loop LV
  # recovery condition `(LV_SHUTDOWN || LOW_VOLTAGE==255 || IGNORE_LV_SHUTDOWN)`
  # always evaluates true, forcing wake whenever Vin > RECOVERY_VOLTAGE.
  # The result: every scheduled alarm2 shutdown is followed by an
  # immediate auto-wake, looking like a power cycle instead of a real
  # sleep. We don't actually need IGNORE_LV_SHUTDOWN because the
  # firmware clears LV_SHUTDOWN on the SYS_UP signal that daemon.sh
  # sends at the end of boot.
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_IGNORE_LV_SHUTDOWN 0
  log 'Cleared IGNORE_LV_SHUTDOWN (was forcing LV-recovery wake every sleep).'

  # "Any power input wakes" - power on the Pi automatically whenever main
  # power is applied. With this set, the Pi never needs a manual button
  # press to come up after a power event.
  enable_default_on

  # Configure recovery-voltage wake behaviour by variant:
  #   - Regular Witty Pi 4: RECOVERY_VOLTAGE = 255 (disabled). The Pi
  #     will only come back online via alarm1, button, or Guaranteed
  #     Wake - exactly what we want for scheduled shutdowns to stay
  #     "down" until the next scheduled startup.
  #   - L3V7 variant (firmware ID 0x37): RECOVERY_VOLTAGE = 1, which
  #     in that variant's firmware semantics means "auto-on when USB
  #     5V is connected". That's a deliberate user-visible feature
  #     for L3V7, not the same as the generic LV recovery path.
  if [ $(($firmwareID)) -eq 55 ]; then
    i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_RECOVERY_VOLTAGE 1
    log 'L3V7: Auto-On when USB 5V connected enabled.'
  else
    i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_RECOVERY_VOLTAGE 255
    log 'LV recovery wake disabled (RECOVERY_VOLTAGE=255) - Pi stays asleep until alarm1/button/guaranteed wake.'
  fi

  # Shutdown-alarm sanity check. v5.29: LOG-ONLY for shutdown alarms -
  # verify_alarm_in_future no longer clears them. A stale alarm2 is
  # already suppressed by the firmware's ALARM2_TRIGGERED flag set at
  # wake, and runScript.sh rewrites alarm2 right after this. The old
  # clear created a rewrite-from-zeros torn state that could race the
  # Rev 14 firmware into a mid-boot power cut.
  log 'Checking shutdown alarm state...'
  verify_alarm_in_future "shutdown"

  # print out current voltages and current
  vout=$(get_output_voltage)
  iout=$(get_output_current)
  if [ $(get_power_mode) -eq 0 ]; then
    log "Current Vout=${vout}V, Iout=${iout}A"
  else
    vin=$(get_input_voltage)
    log "Current Vin=${vin}V, Vout=${vout}V, Iout=${iout}A"
  fi

  # (Rev 13: removed LM75B temperature-action initialisation - the feature
  # is no-op in firmware Rev 13+ and the registers are reserved.)
fi

# check and clear alarm flags
if [ $has_mc == 1 ] ; then
  flag1=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_FLAG_ALARM1)
  flag2=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_FLAG_ALARM2)
  if [ "$flag1" == "1" ]; then
    # woke up by alarm 1 (startup)
    log 'System startup as scheduled.'
  elif [ "$flag2" == "1" ] ; then
    # woke up by alarm 2 (shutdown) - hardware will cut power directly
    log 'Seems I was unexpectedly woken up by shutdown alarm.'
  fi
  clear_alarm_flags

  reason=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_ACTION_REASON)
  if [ "$reason" == $REASON_ALARM1 ]; then
    log 'System starts up because scheduled startup is due.'
  elif [ "$reason" == $REASON_CLICK ]; then
    log 'System starts up because the button is clicked.'
  elif [ "$reason" == $REASON_VOLTAGE_RESTORE ]; then
    log 'System starts up because the input voltage reaches the restore voltage.'
  elif [ "$reason" == $REASON_ALARM1_DELAYED ]; then
    log 'System starts up because of the scheduled startup got delayed.'
    log 'Maybe the scheduled startup was due when Pi was running, or Pi had been shut down but TXD stayed HIGH to prevent the power cut.'
  elif [ "$reason" == $REASON_USB_5V_CONNECTED ]; then
    log 'System starts up because USB 5V is connected.'
  elif [ "$reason" == $REASON_POWER_CONNECTED ]; then
    log 'System starts up because power supply is newly connected.'
  elif [ "$reason" == $REASON_REBOOT ]; then
    log 'System starts up because it previously reboot.'
  elif [ "$reason" == $REASON_GUARANTEED_WAKE ]; then
    log 'System starts up because guaranteed wake is triggered.'
  elif [ "$reason" == $REASON_SYS_UP_TIMEOUT ]; then
    log 'System starts up after the firmware boot watchdog power-cycled a hung boot (no SYS_UP within 30 min).'
  else
    log "Unknown/incorrect startup reason: $reason"
  fi

else
  log 'Witty Pi is not connected, skip I2C communications...'
  TIME_UNKNOWN=2
fi

# L3V7 only: make sure CHRG_PIN and STDBY_PIN are input with internal pull-up
if [ $(($firmwareID)) -eq 55 ]; then
  gpio -g mode $CHRG_PIN up
  gpio -g mode $CHRG_PIN in
  gpio -g mode $STDBY_PIN up
  gpio -g mode $STDBY_PIN in
fi

# run beforeScript.sh
"$cur_dir/beforeScript.sh" >> "$cur_dir/wittyPi.log" 2>&1

# run schedule script
# v5.29: close the lock fd (9>&-) in the child - runScript takes its own
# lock and would otherwise deadlock against the copy it inherited from us.
if [ $has_mc == 1 ] ; then
  "$cur_dir/runScript.sh" 0 revise >> "$cur_dir/schedule.log" 9>&- &
else
  log 'Witty Pi is not connected, skip schedule script...'
fi

# run afterStartup.sh
"$cur_dir/afterStartup.sh" >> "$cur_dir/wittyPi.log" 2>&1

# indicates system is up
log "Send out the SYS_UP signal via GPIO-$SYSUP_PIN pin."
gpio -g mode $SYSUP_PIN out
gpio -g write $SYSUP_PIN 1
sleep 0.1
gpio -g write $SYSUP_PIN 0
sleep 0.1
gpio -g write $SYSUP_PIN 1
sleep 0.1
gpio -g write $SYSUP_PIN 0
sleep 0.1
gpio -g mode $SYSUP_PIN in

# v5.32: button->relay watcher. The button line (BCM 4) is unused while
# the Pi runs on Rev 14+ firmware, so presses are free for application
# use. v5.33: enabled by DEFAULT on Rev 14+ firmware ('auto' in
# buttonRelay.conf, per-device overridable). v5.36: spawned via setsid
# with stdin detached so the watcher is in its own session - it can
# never be reaped by whatever service manager tears down this daemon's
# session/process group after we exit.
setsid "$cur_dir/buttonRelay.sh" < /dev/null >> "$cur_dir/wittyPi.log" 2>&1 9>&- &

# no GPIO-4 soft shutdown - hardware will cut power directly
log 'Daemon startup complete. Hardware handles power cut directly.'
