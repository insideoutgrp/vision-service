#!/bin/bash
# file: runScript.sh
#
# This script will run automatically after startup, and make next schedule
# according to the "schedule.wpi" script file
#

# delay if first argument exists
if [ ! -z "$1" ]; then
  sleep $1
fi

# get current directory and schedule file path
cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
schedule_file="$cur_dir/schedule.wpi"

# utilities
. "$cur_dir/utilities.sh"

# pending until system time gets initialized
while [[ "$(date +%Y)" == *"1969"* ]] || [[ "$(date +%Y)" == *"1970"* ]]; do
  sleep 1
done

# v5.29: serialise our alarm-register writes with the cron I2C jobs.
# A syncTime/checkInternet tick interleaving with a 4-register alarm
# write produced retry storms and torn alarm values. Generous timeout
# (the daemon may briefly hold the lock at boot); on timeout continue -
# a torn write is recoverable, a never-written alarm is worse.
# v5.30: the lock is shared between root (daemon/cron) and the
# interactive user running wittyPi.sh. Root creates it world-writable;
# if it already exists root-owned without write access for us, fall
# back to a read-only fd - flock(2) takes an exclusive lock on a read
# fd just as well. (Previously the failed exec printed "Permission
# denied" + "flock: Bad file descriptor" and skipped locking.)
LOCK=/var/lock/wittypi.i2c.lock
touch "$LOCK" 2>/dev/null && chmod 666 "$LOCK" 2>/dev/null
if [ -w "$LOCK" ]; then
  exec 9>"$LOCK"
elif [ -r "$LOCK" ]; then
  exec 9<"$LOCK"
fi
if ! flock -w 120 9 2>/dev/null; then
  log 'runScript: could not acquire I2C lock within 120s - continuing without it.'
fi

# get current timestamp
cur_time=$(current_timestamp)
echo "--------------- $(TZ=$LOCAL_TZ date -d @$cur_time +'%Y-%m-%d %H:%M:%S') ---------------"

# v5.29: remember why this boot happened - a Guaranteed Wake landing in
# the middle of an OFF window gets special handling after scheduling
# (see the return-to-sleep block below).
wake_reason=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_ACTION_REASON)
current_on_start=''

extract_timestamp()
{
  IFS=' ' read -r point date timestr <<< $1
  local date_reg='(20[1-9][0-9])-([0-9][0-9])-([0-3][0-9])'
  local time_reg='([0-2][0-9]):([0-5][0-9]):([0-5][0-9])'
  if [[ $date =~ $date_reg ]] && [[ $timestr =~ $time_reg ]] ; then
    echo $(TZ=$LOCAL_TZ date -d "$date $timestr" +%s)
  else
    echo 0
  fi
}

extract_duration()
{
  local duration=0
  local day_reg='D([0-9]+)'
  local hour_reg='H([0-9]+)'
  local min_reg='M([0-9]+)'
  local sec_reg='S([0-9]+)'
  IFS=' ' read -a parts <<< $*
  for part in "${parts[@]}"
  do
    if [[ $part =~ $day_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}*86400))
    elif [[ $part =~ $hour_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}*3600))
    elif [[ $part =~ $min_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}*60))
    elif [[ $part =~ $sec_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}))
    fi
  done
  echo $duration
}

setup_off_state()
{
  local res=$(check_sys_and_rtc_time)
  if [ ! -z "$res" ]; then
    log "$res"
  fi
  # only apply DST correction for daily/weekly schedules (cycle >= 24h and
  # a multiple of 24h) where times represent wall-clock hours.
  # Short interval schedules (e.g. 15-min cycles) are left uncorrected.
  local alarm_ts=$1
  if [ $script_duration -gt 0 ] && [ $((script_duration % 86400)) -eq 0 ]; then
    alarm_ts=$(dst_correct $begin $1)
  fi
  log "Schedule next startup at:  $(TZ=$LOCAL_TZ date -d @$alarm_ts +'%Y-%m-%d %H:%M:%S %Z')"
  local date=$(date -u -d "@$alarm_ts" +"%d")
  local hour=$(date -u -d "@$alarm_ts" +"%H")
  local minute=$(date -u -d "@$alarm_ts" +"%M")
  local second=$(date -u -d "@$alarm_ts" +"%S")
  set_startup_time $date $hour $minute $second
}

setup_on_state()
{
  local res=$(check_sys_and_rtc_time)
  if [ ! -z "$res" ]; then
    log "$res"
  fi
  local alarm_ts=$1
  if [ $script_duration -gt 0 ] && [ $((script_duration % 86400)) -eq 0 ]; then
    alarm_ts=$(dst_correct $begin $1)
  fi
  # Floor at now + 60s. If the schedule engine computed an alarm2 closer
  # than that to "now" (short-cycle schedules, RTC-fallback bad time,
  # boot-time race), writing it could cause Timer1 to cut power before
  # the daemon finishes booting. Push it to at least 60s out so the
  # boot can complete and the next iteration of the schedule loop
  # produces a sensible alarm.
  local now_ts=$(current_timestamp)
  if [ $alarm_ts -lt $((now_ts + 60)) ]; then
    local original_ts=$alarm_ts
    alarm_ts=$((now_ts + 60))
    log "WARN: computed shutdown alarm was too close to now ($(TZ=$LOCAL_TZ date -d @$original_ts +'%H:%M:%S %Z')); floored to $(TZ=$LOCAL_TZ date -d @$alarm_ts +'%H:%M:%S %Z')."
  fi
  log "Schedule next shutdown at: $(TZ=$LOCAL_TZ date -d @$alarm_ts +'%Y-%m-%d %H:%M:%S %Z')"
  local date=$(date -u -d "@$alarm_ts" +"%d")
  local hour=$(date -u -d "@$alarm_ts" +"%H")
  local minute=$(date -u -d "@$alarm_ts" +"%M")
  local second=$(date -u -d "@$alarm_ts" +"%S")
  set_shutdown_time $date $hour $minute $second
}

if [ -f $schedule_file ]; then

  if [[ -z $(grep '[^[:space:]]' $schedule_file) ]] ; then
    log 'The schedule script file is empty, clear scheduled startup and shutdown time.'
    clear_startup_time
    clear_shutdown_time
    exit
  fi

  begin=0
  end=0
  count=0
  while IFS='' read -r line || [[ -n "$line" ]]; do
    cpos=`expr index "$line" \#`
    if [ $cpos != 0 ]; then
      line=${line:0:$cpos-1}
    fi
    line=$(trim "$line")
    if [[ $line == BEGIN* ]]; then
      begin=$(extract_timestamp "$line")
    elif [[ $line == END* ]]; then
      end=$(extract_timestamp "$line")
    elif [ "$line" != "" ]; then
      states[$count]=$(echo $line)
      count=$((count+1))
    fi
  done < $schedule_file

  if [ $begin == 0 ] ; then
    log 'I can not find the begin time in the script...'
  elif [ $end == 0 ] ; then
    log 'I can not find the end time in the script...'
  elif [ $count == 0 ] ; then
    log 'I can not find any state defined in the script.'
  else
    if [ $((cur_time < begin)) == '1' ] ; then
      cur_time=$begin
    fi
    if [ $((cur_time >= end)) == '1' ] ; then
      log 'The schedule script has ended already.'
    else
      schedule_script_interrupted
      interrupted=$?	# should be 0 if scheduled startup is in the future and shutdown is in the pass
      if [ ! -z "$2" ] && [ $interrupted == 0 ] ; then
        log 'Schedule script is interrupted, revising the schedule...'
      fi
      index=0
      found_states=0
      check_time=$begin
      script_duration=0
      found_off=0
      found_on=0
      while [ $found_states != 2 ] && [ $((check_time < end)) == '1' ] ;
      do
        duration=$(extract_duration ${states[$index]})
        check_time=$((check_time+duration))
        if [ $found_off == 0 ] && [[ ${states[$index]} == OFF* ]] ; then
          found_off=1
        fi
        if [ $found_on == 0 ] && [[ ${states[$index]} == ON* ]] ; then
          found_on=1
        fi
        # v5.27 / v4.43: compare against the DST-corrected boundary, not raw
        # epoch. The loop walks check_time in raw seconds; setup_*_state
        # applies dst_correct() at the very end. During BST, raw boundaries
        # land 1h ahead of the intended local clock — so the comparison
        # `check_time >= cur_time` picks the just-passed boundary, then
        # dst_correct shifts the alarm 1h into the past. Net effect on
        # daily schedules in BST: each cycle boundary loses an hour, and
        # boots near a boundary trigger floor/fallback to "now + 1h",
        # silently swallowing the segment we were supposed to be running.
        # The +60s slack absorbs the common case of the daemon firing a
        # few seconds after a boundary; it's well under any segment
        # duration in the bundled schedules (min = 5 min heartbeat).
        # First-cycle iterations have script_duration=0 so are left
        # uncorrected, matching the existing setup_*_state behaviour.
        effective_ct=$check_time
        if [ $script_duration -gt 0 ] && [ $((script_duration % 86400)) -eq 0 ]; then
          effective_ct=$(dst_correct $begin $check_time)
        fi
        # find the current ON state and incoming OFF state
        if [ $((effective_ct + 60 >= cur_time)) == '1' ] && ([ $found_states == 1 ] || [[ ${states[$index]} == ON* ]]) ; then
          found_states=$((found_states+1))
          if [[ ${states[$index]} == ON* ]]; then
            if [ -z "$current_on_start" ]; then
              # start of the ON segment this boundary belongs to (raw epoch)
              current_on_start=$((check_time-duration))
            fi
            if [[ ${states[$index]} == *WAIT ]]; then
              log 'Skip scheduling next shutdown, which should be done externally.'
            else
              if [ ! -z "$2" ] && [ $interrupted == 0 ] ; then
                # schedule a shutdown 1 minute before next startup
                setup_on_state $((check_time-duration-60))
              else
                setup_on_state $check_time
              fi
            fi
          elif [[ ${states[$index]} == OFF* ]] ; then
            if [[ ${states[$index]} == *WAIT ]]; then
              log 'Skip scheduling next startup, which should be done externally.'
            else
              if [ ! -z "$2" ] && [ $interrupted == 0 ] && [ $index != 0 ] ; then
                # jump back to previous OFF state 
                prev_state=${states[$((index-1))]}
                prev_duration=$(extract_duration $prev_state)
                setup_off_state $((check_time-duration-prev_duration))
              else
                setup_off_state $check_time
              fi
            fi
          else
            log "I can not recognize this state: ${states[$index]}"
          fi
        fi
        index=$((index+1))
        if [ $index == $count ] ; then
          index=0
          if [ $script_duration == 0 ] ; then
            if [ $found_off == 0 ] ; then
              log 'I need at least one OFF state in the script.'
              check_time=$end     # skip all remaining cycles
            elif [ $found_on == 0 ] ; then
              log 'I need at least one ON state in the script.'
              check_time=$end     # skip all remaining cycles
            else
              script_duration=$((check_time-begin))
              # v5.29: guard against zero cycle duration (malformed
              # durations, e.g. lowercase units, parse to 0). The modulo
              # below would be a division by zero, killing this script
              # with NO alarms written and no fallback applied.
              if [ $script_duration -le 0 ]; then
                log 'ERROR: schedule cycle duration is zero (bad ON/OFF durations?) - applying fallback wake.'
                apply_fallback_alarm "startup"
                break
              fi
              skip=$((cur_time-check_time))
              skip=$((skip-skip%script_duration))
              check_time=$((check_time+skip))  # skip some useless cycles
            fi
          fi
        fi
      done

      # Safety backstop: after the schedule loop, verify both alarms are in
      # the future. If a write was interrupted or the schedule produced a
      # past-time alarm, fall back to "now + 1 hour" so the device always
      # has a valid future wake/sleep target. Field devices cannot tolerate
      # stale alarms left from interrupted runs.
      verify_alarm_in_future "startup"
      verify_alarm_in_future "shutdown"

      # v5.29: Guaranteed-Wake return-to-sleep. If the 24h backstop fired
      # in the middle of a scheduled OFF window, the normal scheduling
      # above keeps the device powered through the remainder of the OFF
      # window plus the entire next ON window (up to ~48h unscheduled
      # uptime on weekend-off schedules - a battery killer). Instead:
      # sleep again in 5 minutes (enough for the boot-time time sync and
      # log flush) and wake at the true start of the next ON period.
      # Applies only to daemon-spawned runs ($2 set) woken by the
      # Guaranteed Wake reason - button and power-connected wakes keep
      # the stay-up behaviour (an operator may be present).
      if [ ! -z "$2" ] && [ "$wake_reason" == "$REASON_GUARANTEED_WAKE" ] && [ -n "$current_on_start" ]; then
        eff_on_start=$current_on_start
        if [ $script_duration -gt 0 ] && [ $((script_duration % 86400)) -eq 0 ]; then
          eff_on_start=$(dst_correct $begin $current_on_start)
        fi
        now_ts=$(current_timestamp)
        if [ $eff_on_start -gt $((now_ts + 600)) ]; then
          log 'Guaranteed Wake landed inside an OFF window - returning to sleep in 5 minutes.'
          d=$(date -u -d "@$eff_on_start" +"%d")
          h=$(date -u -d "@$eff_on_start" +"%H")
          m=$(date -u -d "@$eff_on_start" +"%M")
          s=$(date -u -d "@$eff_on_start" +"%S")
          log "Schedule next startup at:  $(TZ=$LOCAL_TZ date -d @$eff_on_start +'%Y-%m-%d %H:%M:%S %Z')"
          set_startup_time $d $h $m $s
          off_ts=$((now_ts + 300))
          d=$(date -u -d "@$off_ts" +"%d")
          h=$(date -u -d "@$off_ts" +"%H")
          m=$(date -u -d "@$off_ts" +"%M")
          s=$(date -u -d "@$off_ts" +"%S")
          log "Schedule next shutdown at: $(TZ=$LOCAL_TZ date -d @$off_ts +'%Y-%m-%d %H:%M:%S %Z')"
          set_shutdown_time $d $h $m $s
        fi
      fi
    fi
  fi
else
  log "File \"schedule.wpi\" not found, skip running schedule script."
  # Even without a schedule, ensure there's a wake within 1 hour so the
  # device cycles and gets another chance to recover.
  apply_fallback_alarm "startup"
fi

echo '---------------------------------------------------'
