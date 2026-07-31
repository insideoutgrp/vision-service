#!/bin/bash
# file: utilities.sh
#
# This script provides some useful utility functions
#

export LC_ALL=en_GB.UTF-8

# v5.26 / v4.42: ensure PATH includes sbin dirs. cron runs scripts with
# PATH=/usr/bin:/bin only, which is missing i2cdetect (in /usr/sbin) —
# so any cron-spawned script (syncTime.sh, checkInternet.sh) that calls
# is_mc_connected() would silently fail with "i2cdetect: command not
# found" and assume the Witty Pi was disconnected. Idempotent: only
# appends sbin entries that aren't already present.
case ":$PATH:" in
  *":/usr/sbin:"*) ;;
  *) PATH="$PATH:/usr/sbin" ;;
esac
case ":$PATH:" in
  *":/sbin:"*) ;;
  *) PATH="$PATH:/sbin" ;;
esac
case ":$PATH:" in
  *":/usr/local/sbin:"*) ;;
  *) PATH="$PATH:/usr/local/sbin" ;;
esac
export PATH

if [ -z ${I2C_MC_ADDRESS+x} ]; then
  readonly I2C_MC_ADDRESS=0x08

  readonly I2C_BUS=1

  readonly I2C_ID=0
  readonly I2C_VOLTAGE_IN_I=1
  readonly I2C_VOLTAGE_IN_D=2
  readonly I2C_VOLTAGE_OUT_I=3
  readonly I2C_VOLTAGE_OUT_D=4
  readonly I2C_CURRENT_OUT_I=5
  readonly I2C_CURRENT_OUT_D=6
  readonly I2C_POWER_MODE=7
  readonly I2C_LV_SHUTDOWN=8
  readonly I2C_ALARM1_TRIGGERED=9
  readonly I2C_ALARM2_TRIGGERED=10
  readonly I2C_ACTION_REASON=11
  readonly I2C_FW_REVISION=12

  readonly I2C_CONF_ADDRESS=16
  readonly I2C_CONF_DEFAULT_ON=17
  readonly I2C_CONF_PULSE_INTERVAL=18
  readonly I2C_CONF_LOW_VOLTAGE=19
  readonly I2C_CONF_BLINK_LED=20
  readonly I2C_CONF_POWER_CUT_DELAY=21
  readonly I2C_CONF_RECOVERY_VOLTAGE=22
  readonly I2C_CONF_DUMMY_LOAD=23
  readonly I2C_CONF_ADJ_VIN=24
  readonly I2C_CONF_ADJ_VOUT=25
  readonly I2C_CONF_ADJ_IOUT=26

  readonly I2C_CONF_SECOND_ALARM1=27
  readonly I2C_CONF_MINUTE_ALARM1=28
  readonly I2C_CONF_HOUR_ALARM1=29
  readonly I2C_CONF_DAY_ALARM1=30
  readonly I2C_CONF_WEEKDAY_ALARM1=31

  readonly I2C_CONF_SECOND_ALARM2=32
  readonly I2C_CONF_MINUTE_ALARM2=33
  readonly I2C_CONF_HOUR_ALARM2=34
  readonly I2C_CONF_DAY_ALARM2=35
  readonly I2C_CONF_WEEKDAY_ALARM2=36

  readonly I2C_CONF_RTC_OFFSET=37
  readonly I2C_CONF_RTC_ENABLE_TC=38
  readonly I2C_CONF_FLAG_ALARM1=39
  readonly I2C_CONF_FLAG_ALARM2=40

  readonly I2C_CONF_IGNORE_POWER_MODE=41
  readonly I2C_CONF_IGNORE_LV_SHUTDOWN=42

  readonly I2C_CONF_BELOW_TEMP_ACTION=43
  readonly I2C_CONF_BELOW_TEMP_POINT=44
  readonly I2C_CONF_OVER_TEMP_ACTION=45
  readonly I2C_CONF_OVER_TEMP_POINT=46
  readonly I2C_CONF_DEFAULT_ON_DELAY=47

  readonly I2C_CONF_MISC=48
  readonly I2C_CONF_GUARANTEED_WAKE=49

  readonly I2C_LM75B_TEMPERATURE=50
  readonly I2C_LM75B_CONF=51
  readonly I2C_LM75B_THYST=52
  readonly I2C_LM75B_TOS=53

  readonly I2C_RTC_CTRL1=54
  readonly I2C_RTC_CTRL2=55
  readonly I2C_RTC_OFFSET=56
  readonly I2C_RTC_RAM_BYTE=57
  readonly I2C_RTC_SECONDS=58
  readonly I2C_RTC_MINUTES=59
  readonly I2C_RTC_HOURS=60
  readonly I2C_RTC_DAYS=61
  readonly I2C_RTC_WEEKDAYS=62
  readonly I2C_RTC_MONTHS=63
  readonly I2C_RTC_YEARS=64
  readonly I2C_RTC_SECOND_ALARM=65
  readonly I2C_RTC_MINUTE_ALARM=66
  readonly I2C_RTC_HOUR_ALARM=67
  readonly I2C_RTC_DAY_ALARM=68
  readonly I2C_RTC_WEEKDAY_ALARM=69
  readonly I2C_RTC_TIMER_VALUE=70
  readonly I2C_RTC_TIMER_MODE=71

  readonly HALT_PIN=4    # halt by GPIO-4 (BCM naming)
  readonly SYSUP_PIN=17  # output SYS_UP signal on GPIO-17 (BCM naming)
  readonly CHRG_PIN=5    # input to detect charging status
  readonly STDBY_PIN=6   # input to detect standby status

  # v5.31: HTTPS, not HTTP. Cleartext http://google.com responses can be
  # served from carrier-proxy caches on 3G with a STALE Date header, which
  # net_to_system then trusts - observed in the field as the clock stepping
  # backwards ~15 min immediately after a "successful" sync. TLS responses
  # can't be cached by middleboxes, so the Date header is always fresh.
  readonly INTERNET_SERVER='https://www.google.com' # check network accessibility and get network time

  # reasons for startup/shutdown
  readonly REASON_ALARM1='0x01'
  readonly REASON_ALARM2='0x02'
  readonly REASON_CLICK='0x03'
  readonly REASON_LOW_VOLTAGE='0x04'
  readonly REASON_VOLTAGE_RESTORE='0x05'
  readonly REASON_OVER_TEMPERATURE='0x06'
  readonly REASON_BELOW_TEMPERATURE='0x07'
  readonly REASON_ALARM1_DELAYED='0x08'
  readonly REASON_USB_5V_CONNECTED='0x09'
  readonly REASON_POWER_CONNECTED='0x0a'
  readonly REASON_REBOOT='0x0b'
  readonly REASON_GUARANTEED_WAKE='0x0c'
  readonly REASON_SYS_UP_TIMEOUT='0x0d'  # firmware Rev 15: boot watchdog power-cycled a hung boot

  # config file
  if [ "$(lsb_release -si)" == "Ubuntu" ]; then
    # Ubuntu
    readonly BOOT_CONFIG_FILE="/boot/firmware/usercfg.txt"
  else
    # Raspberry Pi OS ("$(lsb_release -si)" == "Debian") and others
    readonly BOOT_CONFIG_FILE="/boot/config.txt"
  fi

  TIME_UNKNOWN=0

  SOFTWARE_VERSION='5.37'

  readonly LOCAL_TZ='Europe/London'
fi


one_wire_confliction()
{
  if [[ $HALT_PIN -eq 4 ]]; then
    if grep -qe "^\s*dtoverlay=w1-gpio\s*$" ${BOOT_CONFIG_FILE}; then
      return 0
    fi
    if grep -qe "^\s*dtoverlay=w1-gpio-pullup\s*$" ${BOOT_CONFIG_FILE}; then
      return 0
    fi
  fi
  if grep -qe "^\s*dtoverlay=w1-gpio,gpiopin=$HALT_PIN\s*$" ${BOOT_CONFIG_FILE}; then
    return 0
  fi
  if grep -qe "^\s*dtoverlay=w1-gpio-pullup,gpiopin=$HALT_PIN\s*$" ${BOOT_CONFIG_FILE}; then
    return 0
  fi
  return 1
}

has_internet()
{
  # v5.28 / v4.44: bump connect-timeout 3s -> 15s, add max-time. 3s is too
  # short for 3G/4G negotiation on field devices (matches checkInternet.sh's
  # PING_TIMEOUT=15). max-time bounds total wait so a hung TCP doesn't
  # block the daemon boot.
  curl -s --head --connect-timeout 15 --max-time 25 "$INTERNET_SERVER" > /dev/null
  return $?
}

get_network_timestamp()
{
  local t=$(curl -sI --connect-timeout 15 --max-time 25 "$INTERNET_SERVER" | grep -i "^Date:" | sed 's/Date: //Ig' | tr -d '\r')
  if [ -n "$t" ]; then
    date -d "$t" +%s 2>/dev/null || echo -1
  else
    echo -1
  fi
}

is_mc_connected()
{
  local result=$(i2cdetect -y ${I2C_BUS})
  if [[ $result == *"$(printf '%02x' $I2C_MC_ADDRESS)"* ]] ; then
    echo 1
  else
    echo 0
  fi
}

get_pi_model()
{
  IFS= read -r -d '' model </proc/device-tree/model
  echo $model;
}

get_os()
{
  echo $(hostnamectl | grep 'Operating System:' | sed 's/.*Operating System: //')
}

get_kernel()
{
  echo $(uname -sr)
}

get_arch()
{
  echo $(dpkg --print-architecture)
}

get_sys_time()
{
  echo $(TZ=$LOCAL_TZ date +'%Y-%m-%d %H:%M:%S %Z')
}

get_sys_timestamp()
{
  echo $(date +%s)
}

rtc_has_bad_time()
{
  year=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_YEARS)
  if [[ $year -eq 0 ]]; then
    echo 1
  else
    echo 0
  fi
}

get_rtc_timestamp()
{
  # v5.29: validate every register read. A single failed read previously
  # became field value 0 (or an arithmetic error) and the composed
  # timestamp - hours wrong - was then written into the system clock by
  # rtc_to_system on offline boots. Empty output = "RTC unreadable".
  local rs=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_SECONDS)
  local rm=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_MINUTES)
  local rh=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_HOURS)
  local rd=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_DAYS)
  local rmo=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_MONTHS)
  local ry=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_YEARS)
  local r
  for r in "$rs" "$rm" "$rh" "$rd" "$rmo" "$ry"; do
    if ! [[ $r =~ ^0x[0-9a-fA-F]{2}$ ]]; then
      echo ''
      return 1
    fi
  done
  sec=$(bcd2dec $((0x7F&$rs)))
  min=$(bcd2dec $rm)
  hour=$(bcd2dec $rh)
  date=$(bcd2dec $rd)
  month=$(bcd2dec $rmo)
  year=$(bcd2dec $ry)
  echo $(date -u --date="$year-$month-$date $hour:$min:$sec" +%s 2>/dev/null)
}

get_rtc_time()
{
  local rtc_ts=$(get_rtc_timestamp)
  if [ "$rtc_ts" == "" ] ; then
    echo 'N/A'
  else
    echo $(TZ=$LOCAL_TZ date +'%Y-%m-%d %H:%M:%S %Z' -d @$rtc_ts)
  fi
}

calc()
{
  awk "BEGIN { print $*}";
}

bcd2dec()
{
  local result=$(($1/16*10+($1&0xF)))
  echo $result
}

dec2bcd()
{
  local result=$((10#$1/10*16+(10#$1%10)))
  echo $result
}

dec2hex()
{
  printf "0x%02x" $1
}

hex2dec()
{
  printf "%d" $1
}

# v5.29: alarm reads are validated - a failed i2c_read no longer silently
# becomes "0" via bcd2dec (which previously let verify_alarm_in_future act
# destructively on a phantom value). On any failed register read these
# return an empty string; callers must treat that as "unknown", not "zero".
_read_alarm_reg()
{
  local v=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $1)
  if [[ $v =~ ^0x[0-9a-fA-F]{2}$ ]]; then
    bcd2dec $v
  fi
}

get_startup_time()
{
  local sec=$(_read_alarm_reg $I2C_CONF_SECOND_ALARM1)
  local min=$(_read_alarm_reg $I2C_CONF_MINUTE_ALARM1)
  local hour=$(_read_alarm_reg $I2C_CONF_HOUR_ALARM1)
  local date=$(_read_alarm_reg $I2C_CONF_DAY_ALARM1)
  if [ -z "$sec" ] || [ -z "$min" ] || [ -z "$hour" ] || [ -z "$date" ]; then
    echo ''
  else
    printf '%02d %02d:%02d:%02d\n' $date $hour $min $sec
  fi
}

# v5.29: alarm registers are written DAY FIRST (day, hour, min, sec).
# The firmware clears its ALARM*_TRIGGERED suppression flag on the FIRST
# byte of a rewrite, and with the old sec-first order the register block
# still encoded YESTERDAY's (in-window) alarm until the day byte landed -
# a firmware tick in that window hard-cut power mid-boot. Writing the day
# byte first makes every torn intermediate state future-dated for daily
# schedules. (Firmware Rev 15 additionally pauses alarm evaluation during
# rewrites; this ordering protects the Rev 14 fleet that can't be
# reflashed remotely.)
set_startup_time()
{
  date=$(dec2bcd $1)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_DAY_ALARM1 $date
  hour=$(dec2bcd $2)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_HOUR_ALARM1 $hour
  min=$(dec2bcd $3)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_MINUTE_ALARM1 $min
  sec=$(dec2bcd $4)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_SECOND_ALARM1 $sec
}

clear_startup_time()
{
  # day first: a (0, old-time) hybrid is out of the firmware match window
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_DAY_ALARM1 0x00
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_HOUR_ALARM1 0x00
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_MINUTE_ALARM1 0x00
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_SECOND_ALARM1 0x00
}

get_shutdown_time()
{
  local sec=$(_read_alarm_reg $I2C_CONF_SECOND_ALARM2)
  local min=$(_read_alarm_reg $I2C_CONF_MINUTE_ALARM2)
  local hour=$(_read_alarm_reg $I2C_CONF_HOUR_ALARM2)
  local date=$(_read_alarm_reg $I2C_CONF_DAY_ALARM2)
  if [ -z "$sec" ] || [ -z "$min" ] || [ -z "$hour" ] || [ -z "$date" ]; then
    echo ''
  else
    printf '%02d %02d:%02d:%02d\n' $date $hour $min $sec
  fi
}

set_shutdown_time()
{
  # day first - see set_startup_time
  date=$(dec2bcd $1)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_DAY_ALARM2 $date
  hour=$(dec2bcd $2)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_HOUR_ALARM2 $hour
  min=$(dec2bcd $3)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_MINUTE_ALARM2 $min
  sec=$(dec2bcd $4)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_SECOND_ALARM2 $sec
}

get_startup_time_local()
{
  local raw=$(get_startup_time)
  if [ -z "$raw" ]; then
    echo 'N/A'
  elif [ "$raw" == "00 00:00:00" ]; then
    echo "$raw"
  else
    local utc_ts=$(date -u --date="$(date -u +%Y-%m-)$raw" +%s)
    TZ=$LOCAL_TZ date -d @$utc_ts +'%d %H:%M:%S'
  fi
}

get_shutdown_time_local()
{
  local raw=$(get_shutdown_time)
  if [ -z "$raw" ]; then
    echo 'N/A'
  elif [ "$raw" == "00 00:00:00" ]; then
    echo "$raw"
  else
    local utc_ts=$(date -u --date="$(date -u +%Y-%m-)$raw" +%s)
    TZ=$LOCAL_TZ date -d @$utc_ts +'%d %H:%M:%S'
  fi
}

clear_shutdown_time()
{
  # day first: a (0, old-time) hybrid is out of the firmware match window
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_DAY_ALARM2 0x00
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_HOUR_ALARM2 0x00
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_MINUTE_ALARM2 0x00
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_SECOND_ALARM2 0x00
}

net_to_system()
{
  local net_ts=$(get_network_timestamp)
  if [[ "$net_ts" != "-1" ]]; then
    log '  Applying network time to system...'
    # v5.28 / v4.44: briefly disable NTP, slam the clock, then re-enable
    # NTP. Without the re-enable, a prior offline-boot's rtc_to_system
    # (which calls `timedatectl set-ntp 0`) leaves NTP off persistently —
    # so systemd-timesyncd never refines the clock between cron ticks.
    # The disable+enable bracket also prevents timesyncd from fighting
    # the manual `date -s`. set-ntp 1 is idempotent and harmless if
    # timesyncd isn't installed.
    sudo timedatectl set-ntp 0 >/dev/null 2>&1
    sudo date -u -s @$net_ts >/dev/null
    sudo timedatectl set-ntp 1 >/dev/null 2>&1
    log '  Done :-)'
    return 0
  else
    log '  Can not get legit network time.'
    # v5.29: report failure so callers can SKIP system_to_rtc. Previously
    # daemon.sh/syncTime.sh wrote the (possibly stale fake-hwclock) system
    # time over a correct RTC whenever has_internet succeeded but the
    # Date header was unusable - inverting the schedule until a good sync.
    return 1
  fi
}

system_to_rtc()
{
  log '  Writing system time to RTC (as UTC)...'
  local sys_ts=$(get_sys_timestamp)
  local sec=$(date -u -d @$sys_ts +%S)
  local min=$(date -u -d @$sys_ts +%M)
  local hour=$(date -u -d @$sys_ts +%H)
  local day=$(date -u -d @$sys_ts +%u)
  local date=$(date -u -d @$sys_ts +%d)
  local month=$(date -u -d @$sys_ts +%m)
  local year=$(date -u -d @$sys_ts +%y)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS 58 $(dec2bcd $sec)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS 59 $(dec2bcd $min)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS 60 $(dec2bcd $hour)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS 61 $(dec2bcd $date)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS 62 $(dec2bcd $day)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS 63 $(dec2bcd $month)
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS 64 $(dec2bcd $year)
  TIME_UNKNOWN=2
  log '  Done :-)'
}

rtc_to_system()
{
  log '  Writing RTC time to system...'
  local rtc_ts=$(get_rtc_timestamp)
  # v5.29: never write an unreadable RTC into the system clock
  if [ -z "$rtc_ts" ]; then
    log '  RTC is unreadable - keeping current system time.'
    return 1
  fi
  # v5.28 / v4.44: re-enable NTP after the manual set. Previously this
  # function called `timedatectl set-ntp 0` (so date -s wouldn't fight
  # timesyncd) but never re-enabled, leaving systemd-timesyncd
  # permanently disabled. Combined with the every-15-min HTTP-Date
  # cron sync only giving 1s resolution and no drift discipline, that
  # left field devices unable to recover from large clock errors:
  # once NTP was off, drift accumulated faster than the cron sync
  # could catch — and if has_internet ever failed on a tick (3G
  # outage, 3s timeout, etc.) the clock just kept walking.
  sudo timedatectl set-ntp 0 >/dev/null 2>&1
  sudo date -s @$rtc_ts >/dev/null
  sudo timedatectl set-ntp 1 >/dev/null 2>&1
  TIME_UNKNOWN=0
  log '  Done :-)'
}

trim()
{
  local result=$(echo "$1" | sed -n '1h;1!H;${;g;s/^[ \t]*//g;s/[ \t]*$//g;p;}')
  echo $result
}

get_utc_offset_seconds()
{
  # Returns UTC offset in seconds for a given epoch in LOCAL_TZ
  # e.g. GMT=0, BST=3600
  local z=$(TZ=$LOCAL_TZ date -d @$1 +%z)
  local sign=${z:0:1}
  local hours=$((10#${z:1:2}))
  local mins=$((10#${z:3:2}))
  local secs=$(( hours * 3600 + mins * 60 ))
  if [ "$sign" = "-" ]; then
    secs=$((-secs))
  fi
  echo $secs
}

dst_correct()
{
  # Corrects an alarm epoch for DST drift relative to a schedule's BEGIN epoch.
  # When durations are added as fixed seconds, the local time-of-day drifts by
  # the DST offset difference. This function snaps the alarm back to the
  # intended local time.
  local begin_epoch=$1
  local alarm_epoch=$2
  local begin_off=$(get_utc_offset_seconds $begin_epoch)
  local alarm_off=$(get_utc_offset_seconds $alarm_epoch)
  echo $(( alarm_epoch + begin_off - alarm_off ))
}

enable_guaranteed_wake()
{
  # Backstop wake mechanism: instructs the firmware to wake the Pi at least
  # once every $1 hours (or days if $2='days') regardless of alarm state.
  # This is the primary recovery path for stuck alarms, drained RTC backup,
  # daemon crashes, SD corruption, and other field failures.
  #
  # Defensive: writes to register 49 (added in upstream Witty Pi 4 firmware,
  # all known revs >= 7). On older firmware the write is harmless EEPROM
  # storage with no effect; on supported firmware it provides the failsafe.
  local value=${1:-24}      # default: 24 hours
  local unit=${2:-hours}    # default: hours

  if [ "$unit" = "days" ]; then
    # bit 7 = 1 means days, bits 0-6 = count
    value=$(( (value & 0x7F) | 0x80 ))
  else
    # bit 7 = 0 means hours, bits 0-6 = count
    value=$(( value & 0x7F ))
  fi

  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_GUARANTEED_WAKE $value
  local readback=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_GUARANTEED_WAKE)
  if [ "$(($readback))" = "$value" ]; then
    log "Guaranteed wake enabled (reg49=$readback)."
  else
    log "Guaranteed wake write attempted (reg49=$readback, wanted $value). May be unsupported by older firmware."
  fi
}

enable_ignore_lv_shutdown()
{
  # Prevents a stale LV_SHUTDOWN=1 flag in EEPROM from blocking alarm1
  # startup wakes after a low-voltage event. Without this, a single
  # brownout can permanently disable scheduled wake until manual reset.
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_IGNORE_LV_SHUTDOWN 1
  local readback=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_IGNORE_LV_SHUTDOWN)
  log "Ignore LV shutdown flag set (reg42=$readback)."
}

enable_default_on()
{
  # "Any power input wakes" - sets DEFAULT_ON=1 so the Pi powers up
  # automatically whenever main DC power is connected, without requiring
  # a button press. Combined with USB-5V auto-on (L3V7 variant) and
  # guaranteed wake, this means any power source will start the system.
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_DEFAULT_ON 1
  local readback=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_DEFAULT_ON)
  log "Default-ON enabled (reg17=$readback)."
}

verify_alarm_in_future()
{
  # v5.29: rewritten to mirror the firmware's actual matching semantics.
  # The firmware compares day-of-month-relative timestamps with a backward
  # 86400s window; the old "alarm-day < today means next month" heuristic
  # classified yesterday's stale alarm (the common overnight case) as
  # next-month-future and never caught it, while the epoch check
  # mis-handled cross-month alarms.
  #
  # Policy per kind:
  #   STARTUP: armed-in-past-window, implausibly far future (>8 days -
  #     schedules never write more than ~7 days ahead), or zero -> write
  #     fallback "now + 1 hour" so the device always has a wake target.
  #   SHUTDOWN: LOG ONLY - never clear. The ALARM2_TRIGGERED suppression
  #     set at wake already prevents a stale re-fire, and runScript.sh
  #     rewrites alarm2 right after the daemon anyway. Clearing here
  #     (the old behaviour) created a rewrite-from-zeros torn state that
  #     could race the firmware into a mid-boot power cut on Rev 14.
  #   UNREADABLE (any register read failed): LOG ONLY for both kinds -
  #     never take destructive action on a value we couldn't read.
  # $1 = "startup" or "shutdown"
  local kind=$1
  local raw
  if [ "$kind" = "startup" ]; then
    raw=$(get_startup_time)
  else
    raw=$(get_shutdown_time)
  fi

  if [ -z "$raw" ]; then
    log "WARN: could not read $kind alarm registers - leaving them untouched."
    return
  fi

  if [ "$raw" = "00 00:00:00" ]; then
    # zero shutdown alarm is fine (no scheduled shutdown); zero startup
    # alarm needs a fallback so the device cycles eventually.
    if [ "$kind" = "startup" ]; then
      log "WARN: startup alarm is zero - applying fallback (now + 1 hour)."
      apply_fallback_alarm "startup"
    fi
    return
  fi

  local alarm_epoch=$(_parse_alarm_to_epoch "$raw")
  if [ -z "$alarm_epoch" ]; then
    log "WARN: could not parse $kind alarm '$raw' - leaving it untouched."
    return
  fi

  local now=$(current_timestamp)
  local overdue=$((now - alarm_epoch))

  if [ $overdue -ge -30 ] && [ $overdue -lt 86400 ]; then
    # armed in the firmware's past-window (or within 30s of firing)
    if [ "$kind" = "startup" ]; then
      log "WARN: startup alarm '$raw' is not safely in the future - applying fallback (now + 1 hour)."
      apply_fallback_alarm "startup"
    else
      log "NOTE: shutdown alarm '$raw' is stale (${overdue}s past); suppressed by firmware flag, runScript will rewrite it."
    fi
  elif [ $overdue -lt $((-8 * 86400)) ]; then
    # more than 8 days in the future - no schedule writes that far ahead
    if [ "$kind" = "startup" ]; then
      log "WARN: startup alarm '$raw' is implausibly far in the future - applying fallback (now + 1 hour)."
      apply_fallback_alarm "startup"
    else
      log "NOTE: shutdown alarm '$raw' looks implausible; leaving for runScript to rewrite."
    fi
  elif [ $overdue -ge 86400 ]; then
    # past but outside the firmware's match window - inert
    if [ "$kind" = "startup" ]; then
      log "WARN: startup alarm '$raw' is stale beyond the match window - applying fallback (now + 1 hour)."
      apply_fallback_alarm "startup"
    fi
  fi
}

apply_fallback_alarm()
{
  # Writes a "now + 1 hour" alarm of the requested kind.
  # For shutdown alarms, prefer clear_shutdown_time over this function.
  # $1 = "startup" or "shutdown"
  local kind=$1
  local target=$(( $(current_timestamp) + 3600 ))
  local d=$(date -u -d "@$target" +"%d")
  local h=$(date -u -d "@$target" +"%H")
  local m=$(date -u -d "@$target" +"%M")
  local s=$(date -u -d "@$target" +"%S")
  if [ "$kind" = "startup" ]; then
    set_startup_time $d $h $m $s
  else
    set_shutdown_time $d $h $m $s
  fi
  log "Fallback $kind alarm set to: $(TZ=$LOCAL_TZ date -d @$target +'%Y-%m-%d %H:%M:%S %Z')"
}

current_timestamp()
{
  # prefer system time (kept accurate by NTP) over RTC
  local sys_ts=$(date +%s)
  local sys_year=$(date -u -d @$sys_ts +%Y)
  if [ "$sys_year" -gt 2020 ] 2>/dev/null; then
    echo $sys_ts
  else
    # system time not initialised yet, fall back to RTC
    local rtctimestamp=$(get_rtc_timestamp)
    if [ "$rtctimestamp" == "" ] ; then
      echo $sys_ts
    else
      echo $rtctimestamp
    fi
  fi
}

wittypi_home="`dirname \"$0\"`"
wittypi_home="`( cd \"$wittypi_home\" && pwd )`"
log2file()
{
  local datetime='[xxxx-xx-xx xx:xx:xx]'
  if [ $TIME_UNKNOWN -eq 0 ]; then
    datetime=$(TZ=$LOCAL_TZ date +'[%Y-%m-%d %H:%M:%S]')
  elif [ $TIME_UNKNOWN -eq 2 ]; then
    datetime=$(TZ=$LOCAL_TZ date +'<%Y-%m-%d %H:%M:%S>')
  fi
  local msg="$datetime $1"
  echo $msg >> $wittypi_home/wittyPi.log
}

log()
{
  if [ $# -gt 1 ] ; then
    echo $2 "$1"
  else
    echo "$1"
  fi
  log2file "$1"
}

i2c_read()
{
  local retry=0
  if [ $# -gt 3 ] ; then
    retry=$4
  fi
  local result=$(i2cget -y $1 $2 $3)
  if [[ $result =~ ^0x[0-9a-fA-F]{2}$ ]] ; then
    echo $result;
  else
    retry=$(( $retry + 1 ))
    if [ $retry -eq 4 ] ; then
      # v5.29: log to FILE only. log() echoes to stdout, and callers
      # capture this function with $(...) - the error sentence became the
      # "value", word-split, and bcd2dec arithmetic silently turned it
      # into 0. A failed read now yields an empty string.
      log2file "I2C read $1 $2 $3 failed (result=$result), and no more retry."
    else
      sleep 1
      log2file "I2C read $1 $2 $3 failed (result=$result), retrying $retry ..."
      i2c_read $1 $2 $3 $retry
    fi
  fi
}

i2c_write()
{
  local retry=0
  if [ $# -gt 4 ] ; then
    retry=$5
  fi
  i2cset -y $1 $2 $3 $4
  local result=$(i2c_read $1 $2 $3)
  if [ "$result" != $(dec2hex "$4") ] ; then
    retry=$(( $retry + 1 ))
    if [ $retry -eq 4 ] ; then
      log "I2C write $1 $2 $3 $4 failed (result=$result), and no more retry."
    else
      sleep 1
      log2file "I2C write $1 $2 $3 $4 failed (result=$result), retrying $retry ..."
      i2c_write $1 $2 $3 $4 $retry
    fi
  fi
}

get_temperature()
{
  local data=$(i2cget -y $I2C_BUS $I2C_MC_ADDRESS $I2C_LM75B_TEMPERATURE w)

  #if [[ $data =~ ^0x[0-9a-fA-F]{4}$ && $data != 0xffff ]]; then
  if [[ $data =~ ^0x[0-9a-fA-F]{4}$ ]]; then
    data=$(( ((($data&0xFF)<<8)|(($data&0xFF00)>>8))>>5 ))
    if [[ $data -ge 0x400 ]] ; then
      data=$(( ($data&0x3FF)-1024 ))
    fi
    local c=$(calc $data*0.125)
    echo -n "$c$(echo $'\xc2\xb0'C)"
    if hash awk 2>/dev/null; then
      local f=$(awk "BEGIN { print $c*1.8+32 }")
      echo " / $f$(echo $'\xc2\xb0'F)"
    else
      echo ''
    fi
  else
    sleep 0.1
    get_temperature
  fi
}

clear_alarm_flags()
{
  local ctrl2=0x0
  if [ -z "$1" ]; then
    ctrl2=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_CTRL2)
  else
    ctrl2=$1
  fi
  ctrl2=$(($ctrl2&0xBF))
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_RTC_CTRL2 $ctrl2
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_FLAG_ALARM1 0
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_FLAG_ALARM2 0
}

schedule_script_interrupted()
{
  local startup_time=$(get_startup_time)
  local shutdown_time=$(get_shutdown_time)
  if [ "$startup_time" != '00 00:00:00' ] && [ "$shutdown_time" != '00 00:00:00' ] ; then
    local st_timestamp=$(_parse_alarm_to_epoch "$startup_time")
    local sd_timestamp=$(_parse_alarm_to_epoch "$shutdown_time")
    local cur_timestamp=$(date +%s)
    if [ -n "$st_timestamp" ] && [ -n "$sd_timestamp" ] \
       && [ $st_timestamp -gt $cur_timestamp ] && [ $sd_timestamp -lt $cur_timestamp ] ; then
      return 0
    fi
  fi
  return 1
}

_parse_alarm_to_epoch()
{
  # v5.29: convert a raw alarm "DD HH:MM:SS" (UTC) to the epoch of its
  # NEAREST real occurrence, mirroring the firmware's day-of-month-
  # relative matching. The old version assumed alarm-day < today always
  # meant "next month", which classified yesterday's alarm (the common
  # overnight case) as ~30 days in the future.
  #
  # Method: compute the firmware-style signed offset
  #   overdue = (today - alarm_day)*86400 + (now_tod - alarm_tod)
  # then resolve month wrap-around: schedules never write alarms more
  # than ~7 days ahead, so an "overdue" beyond +/-8 days means the alarm
  # belongs to the adjacent month. Returns empty string if parse fails.
  local raw="$1"
  if ! [[ $raw =~ ^([0-9]{2})\ ([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
    echo ''
    return 1
  fi
  local dom=$((10#${BASH_REMATCH[1]}))
  local tod=$((10#${BASH_REMATCH[2]}*3600 + 10#${BASH_REMATCH[3]}*60 + 10#${BASH_REMATCH[4]}))
  local now=$(current_timestamp)
  local today=$((10#$(date -u -d @$now +%d)))
  local now_tod=$(( 10#$(date -u -d @$now +%H)*3600 + 10#$(date -u -d @$now +%M)*60 + 10#$(date -u -d @$now +%S) ))
  local overdue=$(( (today - dom)*86400 + now_tod - tod ))
  if [ $overdue -lt $((-8 * 86400)) ]; then
    # alarm day is near month end while today is near month start:
    # it belongs to the PREVIOUS month - shift by that month's length
    local dprev=$((10#$(date -u -d "$(date -u -d @$now +%Y-%m-01) -1 day" +%d)))
    overdue=$((overdue + dprev*86400))
  elif [ $overdue -gt $((8 * 86400)) ]; then
    # today is near month end while the alarm day is small: the alarm
    # is early NEXT month - shift by the current month's length
    local dcur=$((10#$(date -u -d "$(date -u -d @$now +%Y-%m-01) +1 month -1 day" +%d)))
    overdue=$((overdue - dcur*86400))
  fi
  echo $((now - overdue))
}

get_power_mode()
{
  local mode=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_POWER_MODE)
  echo $(($mode))
}

get_input_voltage()
{
  local i=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_VOLTAGE_IN_I)
  local d=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_VOLTAGE_IN_D)
  calc $(($i))+$(($d))/100
}

get_output_voltage()
{
  local i=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_VOLTAGE_OUT_I)
  local d=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_VOLTAGE_OUT_D)
  calc $(($i))+$(($d))/100
}

get_output_current()
{
  local i=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CURRENT_OUT_I)
  local d=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CURRENT_OUT_D)
  calc $(($i))+$(($d))/100
}

get_low_voltage_threshold()
{
  local lowVolt=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_LOW_VOLTAGE)
  if [ $(($lowVolt)) == 255 ]; then
    lowVolt='disabled'
  else
    lowVolt=$(calc $(($lowVolt))/10)
    lowVolt+='V'
  fi
  echo $lowVolt;
}

get_recovery_voltage_threshold()
{
  local recVolt=$(i2c_read ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_RECOVERY_VOLTAGE)
  if [ $(($recVolt)) == 255 ]; then
    recVolt='disabled'
  else
    recVolt=$(calc $(($recVolt))/10)
    recVolt+='V'
  fi
  echo $recVolt;
}

set_low_voltage_threshold()
{
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_LOW_VOLTAGE $1
}

set_recovery_voltage_threshold()
{
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_RECOVERY_VOLTAGE $1
}

clear_low_voltage_threshold()
{
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_LOW_VOLTAGE 0xFF
}

clear_recovery_voltage_threshold()
{
  i2c_write ${I2C_BUS} $I2C_MC_ADDRESS $I2C_CONF_RECOVERY_VOLTAGE 0xFF
}

# (Rev13: temperature-action helpers removed - feature is no-op in firmware
# Rev 13+. Temperature is still readable via get_temperature() for display.)

check_sys_and_rtc_time()
{
  local rtc_ts=$(get_rtc_timestamp)
  local sys_ts=$(get_sys_timestamp)
  if [ -z "$rtc_ts" ]; then
    echo '[Warning] Could not read RTC time for the sync check.'
    return
  fi
  local delta=$((rtc_ts-sys_ts))
  if [ "${delta#-}" -gt 10 ]; then
    local rtc_t=$(TZ=$LOCAL_TZ date +'%Y-%m-%d %H:%M:%S %Z' -d @$rtc_ts)
    local sys_t=$(TZ=$LOCAL_TZ date +'%Y-%m-%d %H:%M:%S %Z' -d @$sys_ts)
    echo "[Warning] System and RTC time seems not synchronized, difference is ${delta#-}s."
    echo "System time is \"$sys_t\", while RTC time is \"$rtc_t\"."
    echo 'Please synchronize the time first.'
  fi
}
