[ -z $BASH ] && { exec bash "$0" "$@" || exit; }
#!/bin/bash
# file: install.sh
#
# This script installs the visIOn Witty Pi power-management runtime and its
# system dependencies. The install target is fixed at $VISION_HOME/wittypi
# (default /home/pi/vision/wittypi) regardless of where it is run from.
#

# check if sudo is used
if [ "$(id -u)" != 0 ]; then
  echo 'Sorry, you need to run this script with sudo'
  exit 1
fi

# install target: the wittypi module inside the visIOn service root.
# visIOn deploys as a unit to /home/pi/vision (override with VISION_HOME);
# the Witty Pi power-management runtime lives at $VISION_HOME/wittypi and
# future service modules sit alongside it. The target is deliberately NOT
# derived from the script location, otherwise installs run from a source
# checkout would target the checkout.
VISION_HOME="${VISION_HOME:-/home/pi/vision}"
DIR="$VISION_HOME/wittypi"
# resolve the script's own directory BEFORE changing cwd - a relative
# invocation path (e.g. `sudo bash Software/install.sh`) would resolve
# wrongly after the cd below
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
mkdir -p "$VISION_HOME" || { echo "Cannot create $VISION_HOME"; exit 1; }
# the rest of this script uses paths relative to the service root
cd "$VISION_HOME" || exit 1

# error counter
ERR=0

# config file
if [ "$(lsb_release -si)" == "Ubuntu" ]; then
  # Ubuntu
  BOOT_CONFIG_FILE="/boot/firmware/usercfg.txt"
else
  # Raspberry Pi OS ("$(lsb_release -si)" == "Debian") and others
  if [ -e /boot/firmware/config.txt ] ; then
    BOOT_CONFIG_FILE="/boot/firmware/config.txt"
  else
    BOOT_CONFIG_FILE="/boot/config.txt"
  fi
fi

echo '================================================================================'
echo '|                                                                              |'
echo '|                   Witty Pi Software Installation Script                      |'
echo '|                                                                              |'
echo '================================================================================'

# enable I2C on Raspberry Pi
echo '>>> Enable I2C'
if grep -q 'i2c-bcm2708' /etc/modules; then
  echo 'Seems i2c-bcm2708 module already exists, skip this step.'
else
  echo 'i2c-bcm2708' >> /etc/modules
fi
if grep -q 'i2c-dev' /etc/modules; then
  echo 'Seems i2c-dev module already exists, skip this step.'
else
  echo 'i2c-dev' >> /etc/modules
fi

i2c1=$(grep 'dtparam=i2c1=on' ${BOOT_CONFIG_FILE})
i2c1=$(echo -e "$i2c1" | sed -e 's/^[[:space:]]*//')
if [[ -z "$i2c1" || "$i2c1" == "#"* ]]; then
  echo 'dtparam=i2c1=on' >> ${BOOT_CONFIG_FILE}
else
  echo 'Seems i2c1 parameter already set, skip this step.'
fi

i2c_arm=$(grep 'dtparam=i2c_arm=on' ${BOOT_CONFIG_FILE})
i2c_arm=$(echo -e "$i2c_arm" | sed -e 's/^[[:space:]]*//')
if [[ -z "$i2c_arm" || "$i2c_arm" == "#"* ]]; then
  echo 'dtparam=i2c_arm=on' >> ${BOOT_CONFIG_FILE}
else
  echo 'Seems i2c_arm parameter already set, skip this step.'
fi

miniuart=$(grep 'dtoverlay=miniuart-bt' ${BOOT_CONFIG_FILE})
miniuart=$(echo -e "$miniuart" | sed -e 's/^[[:space:]]*//')
if [[ -z "$miniuart" || "$miniuart" == "#"* ]]; then
  echo 'dtoverlay=miniuart-bt' >> ${BOOT_CONFIG_FILE}
else
  echo 'Seems setting Bluetooth to use mini-UART is done already, skip this step.'
fi

if [ -f /etc/modprobe.d/raspi-blacklist.conf ]; then
  sed -i 's/^blacklist spi-bcm2708/#blacklist spi-bcm2708/' /etc/modprobe.d/raspi-blacklist.conf
  sed -i 's/^blacklist i2c-bcm2708/#blacklist i2c-bcm2708/' /etc/modprobe.d/raspi-blacklist.conf
else
  echo 'File raspi-blacklist.conf does not exist, skip this step.'
fi

# install i2c-tools
echo '>>> Install i2c-tools'
if hash i2cget 2>/dev/null; then
  echo 'Seems i2c-tools is installed already, skip this step.'
else
  apt install -y i2c-tools || ((ERR++))
fi

# make sure en_GB.UTF-8 locale is installed
echo '>>> Make sure en_GB.UTF-8 locale is installed'
locale_commentout=$(sed -n 's/\(#\).*en_GB.UTF-8 UTF-8/1/p' /etc/locale.gen)
if [[ $locale_commentout -ne 1 ]]; then
  echo 'Seems en_GB.UTF-8 locale has been installed, skip this step.'
else
  sed -i.bak 's/^.*\(en_GB.UTF-8[[:blank:]]\+UTF-8\)/\1/' /etc/locale.gen
  locale-gen
fi

# install wiringPi
if hash gpio 2>/dev/null; then
  echo 'Seems wiringPi has been installed, skip this step.'
else
  os=$(lsb_release -r | grep 'Release:' | sed 's/Release:\s*//')
  if [ $os -le 10 ]; then
    apt install -y wiringpi || ((ERR++))
  elif [ $os -eq 11 ]; then
    wget https://github.com/WiringPi/WiringPi/releases/download/3.2/wiringpi_3.2-bullseye_armhf.deb -O wiringpi.deb || ((ERR++))
    apt install -y ./wiringpi.deb || ((ERR++))
    rm wiringpi.deb
  else
    arch=$(dpkg --print-architecture)
    if [ "$arch" == "arm64" ]; then
      wget https://github.com/WiringPi/WiringPi/releases/download/3.2/wiringpi_3.2_arm64.deb -O wiringpi.deb || ((ERR++))
    else
      wget https://github.com/WiringPi/WiringPi/releases/download/3.2/wiringpi_3.2_armhf.deb -O wiringpi.deb || ((ERR++))
    fi
    apt install -y ./wiringpi.deb || ((ERR++))
    rm wiringpi.deb
  fi
fi

# source directory: the wittypi folder to install FROM. Defaults to the
# wittypi/ shipped alongside this script, but callers (e.g. deploy.sh) can
# override it with WITTYPI_SRC so the source is never confused with the
# install target ($DIR).
SRC_DIR="${WITTYPI_SRC:-$SCRIPT_DIR/wittypi}"

# scripts that carry the DST fix (v4.24)
# v5.29: utilities.sh last - it carries SOFTWARE_VERSION, and copying it
# first meant an interrupted update looked "already up to date" on rerun
# while the other scripts were still the old version.
UPDATE_FILES="daemon.sh runScript.sh wittyPi.sh syncTime.sh checkInternet.sh buttonRelay.sh utilities.sh"

# Sync $src_dir/*.wpi into $dst_dir/, exactly:
#   - removes .wpi files on device not present in source
#   - adds source files not on device
#   - updates files whose content differs
#   - preserves schedule.wpi (the user's active selection)
sync_schedules() {
  local src_dir="$1"
  local dst_dir="$2"
  if [ ! -d "$src_dir" ]; then
    echo '  No source schedules directory found, skipping.'
    return 0
  fi
  mkdir -p "$dst_dir"
  local added=0 updated=0 removed=0 unchanged=0
  if [ -d "$dst_dir" ]; then
    for existing in "$dst_dir"/*.wpi; do
      [ -e "$existing" ] || continue
      local name=$(basename "$existing")
      [ "$name" = "schedule.wpi" ] && continue
      if [ ! -f "$src_dir/$name" ]; then
        rm -f "$existing"
        echo "  Removed: $name"
        removed=$((removed + 1))
      fi
    done
  fi
  for src in "$src_dir"/*.wpi; do
    [ -e "$src" ] || continue
    local name=$(basename "$src")
    if [ -f "$dst_dir/$name" ]; then
      if ! cmp -s "$src" "$dst_dir/$name"; then
        cp "$src" "$dst_dir/$name"
        echo "  Updated: $name"
        updated=$((updated + 1))
      else
        unchanged=$((unchanged + 1))
      fi
    else
      cp "$src" "$dst_dir/$name"
      echo "  Added:   $name"
      added=$((added + 1))
    fi
  done
  echo "  Total: $added added, $updated updated, $removed removed, $unchanged unchanged."
}

# install or update wittyPi
if [ $ERR -eq 0 ]; then
  if [ -d "$DIR" ] && [ -f "$DIR/utilities.sh" ]; then
    # --- existing installation: update scripts ---
    CURRENT_VER=$(grep "SOFTWARE_VERSION=" "wittypi/utilities.sh" | head -1 | grep -o "'[^']*'" | tr -d "'")
    TARGET_VER=$(grep "SOFTWARE_VERSION=" "$SRC_DIR/utilities.sh" | head -1 | grep -o "'[^']*'" | tr -d "'")
    echo ">>> Existing Witty Pi installation found (v${CURRENT_VER:-unknown})"
    if [ "$CURRENT_VER" = "$TARGET_VER" ]; then
      echo "  Already at v${TARGET_VER}, no update needed."
    else
      echo "  Updating to v${TARGET_VER}..."

      # backup current scripts
      BACKUP_DIR="wittypi/backup_v${CURRENT_VER:-old}_$(date +%Y%m%d_%H%M%S)"
      echo "  Creating backup in $BACKUP_DIR"
      mkdir -p "$BACKUP_DIR"
      for f in $UPDATE_FILES; do
        if [ -f "wittypi/$f" ]; then
          cp "wittypi/$f" "$BACKUP_DIR/$f"
        fi
      done

      # copy updated scripts
      for f in $UPDATE_FILES; do
        if [ -f "$SRC_DIR/$f" ]; then
          cp "$SRC_DIR/$f" "wittypi/$f" || ((ERR++))
          chmod +x "wittypi/$f"
          echo "  Updated $f"
        fi
      done

      # sync schedules (existing install path)
      SCHED_SRC="$(dirname "$SRC_DIR")/../Schedules"
      echo '  Syncing schedules...'
      sync_schedules "$SCHED_SRC" "wittypi/schedules"

      chown -R $SUDO_USER:$(id -g -n $SUDO_USER) "$VISION_HOME" || ((ERR++))

      # restart daemon so new code takes effect
      if [ -f /var/run/wittypi_daemon.pid ]; then
        OLD_PID=$(cat /var/run/wittypi_daemon.pid 2>/dev/null)
        if [ ! -z "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
          kill "$OLD_PID" 2>/dev/null
          sleep 1
          echo '  Stopped old daemon.'
        fi
      fi
      "$DIR/daemon.sh" &
      sleep 1
      DAEMON_PID=$(ps --ppid $! -o pid= 2>/dev/null)
      if [ ! -z "$DAEMON_PID" ]; then
        echo "$DAEMON_PID" > /var/run/wittypi_daemon.pid
        echo "  Daemon restarted (PID: $DAEMON_PID)."
      fi

      echo ''
      echo '  RTC will be migrated to UTC automatically.'
      echo '  If offline, run wittyPi.sh and choose option 1 (Write system time to RTC)'
      echo '  after verifying your system clock is correct.'
      echo ''
      echo "  To rollback: sudo cp $BACKUP_DIR/* wittypi/ && sudo reboot"
    fi
  else
    # --- fresh installation ---
    echo '>>> Install wittypi'
    if [ -d "$SRC_DIR" ] && [ -f "$SRC_DIR/utilities.sh" ]; then
      # install from the local source tree
      rm -rf wittypi
      cp -r "$SRC_DIR" wittypi || ((ERR++))
    else
      # The upstream fallback (download stock software from UUGear) was
      # removed for visIOn: stock software lacks every fork hardening
      # (UTC RTC, DST engine, reliability registers, flock) and would
      # silently degrade a field device. Fail loudly instead.
      echo "ERROR: source tree not found at $SRC_DIR - nothing installed."
      echo '       Run via Software/deploy.sh, or set WITTYPI_SRC.'
      exit 1
    fi
    cd wittypi
    chmod +x wittyPi.sh
    chmod +x daemon.sh
    chmod +x runScript.sh
    chmod +x beforeScript.sh
    chmod +x afterStartup.sh
    chmod +x beforeShutdown.sh
    sed -e "s#/home/pi/vision/wittypi#$DIR#g" init.sh >/etc/init.d/wittypi
    chmod +x /etc/init.d/wittypi
    update-rc.d wittypi defaults || ((ERR++))
    touch wittyPi.log
    touch schedule.log
    # sync custom schedules (fresh install path - cwd is the wittypi install dir)
    SCHED_SRC="$(dirname "$SRC_DIR")/../Schedules"
    echo '  Syncing schedules...'
    sync_schedules "$SCHED_SRC" "schedules"
    cd ..
    chown -R $SUDO_USER:$(id -g -n $SUDO_USER) "$VISION_HOME" || ((ERR++))
    sleep 2
  fi
fi

# set up cron job for periodic time sync
echo '>>> Setting up periodic time sync'
CRON_CMD="$DIR/syncTime.sh >> $DIR/wittyPi.log 2>&1"
# remove any existing syncTime cron entry then add the current one
(crontab -l 2>/dev/null | grep -vF 'syncTime.sh'; echo "*/15 * * * * $CRON_CMD") | crontab -
echo '  Cron job set: sync time every 15 minutes.'

# set up cron job for internet connectivity check (offset so it doesn't
# overlap with syncTime.sh at :00/:15/:30/:45)
echo '>>> Setting up internet connectivity check'
NET_CHECK_CMD="$DIR/checkInternet.sh >> $DIR/wittyPi.log 2>&1"
(crontab -l 2>/dev/null | grep -vF 'checkInternet.sh'; echo "7,22,37,52 * * * * $NET_CHECK_CMD") | crontab -
echo '  Cron job set: check internet every 15 min (at :07/:22/:37/:52).'

# NOTE: the upstream UUGear Web Interface (UWI) install step was removed for
# visIOn — these are headless, unattended field devices and piping a
# third-party installer from the network at provisioning time is neither
# needed nor wanted. Install UWI manually if a bench device ever needs it.

echo
if [ $ERR -eq 0 ]; then
  echo '>>> All done. Please reboot your Pi :-)'
else
  echo '>>> Something went wrong. Please check the messages above :-('
fi
