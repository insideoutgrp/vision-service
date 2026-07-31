#!/bin/bash
# /etc/init.d/wittypi

### BEGIN INIT INFO
# Provides:          wittypi
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Witty Pi 4 initialize script
# Description:       This service is used to manage Witty Pi 4 service
### END INIT INFO

DAEMON=/home/pi/wittypi/daemon.sh
RETRY_DELAY=15
MAX_RETRIES=3
LOG=/home/pi/wittypi/wittyPi.log

# Run the daemon, retrying on non-zero exit. Daemon naturally exits
# after startup tasks (alarm registers set, schedule revised). A
# non-zero exit (I2C glitch, missing file, etc.) gets retried so a
# transient fault doesn't leave the device with stale alarms.
run_daemon_with_retry() {
    local attempt=0
    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        $DAEMON
        local ec=$?
        if [ $ec -eq 0 ]; then
            return 0
        fi
        echo "[$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Witty Pi daemon exited with code $ec on attempt $attempt/$MAX_RETRIES, retrying in ${RETRY_DELAY}s..." >> $LOG 2>/dev/null || true
        sleep $RETRY_DELAY
    done
    echo "[$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Witty Pi daemon failed $MAX_RETRIES times. Giving up." >> $LOG 2>/dev/null || true
    return 1
}

case "$1" in
    start)
        echo "Starting Witty Pi 4 Daemon..."
        ( run_daemon_with_retry ) &
	sleep 1
	daemonPid=$(ps --ppid $! -o pid=)
	echo $daemonPid > /var/run/wittypi_daemon.pid
        ;;
    stop)
        echo "Stopping Witty Pi 4 Daemon..."
	daemonPid=$(cat /var/run/wittypi_daemon.pid)
	kill -9 $daemonPid
        ;;
    *)
        echo "Usage: /etc/init.d/wittypi start|stop"
        exit 1
        ;;
esac

exit 0
