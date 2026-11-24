# CLAUDE.md

## Project memory

_Migrated from local Claude Code memory on 2026-11-24 so cloud sessions and other accounts have it. Keep this section current: add new facts here rather than only in local memory._

### visIOn = IoT endpoint management service for time-lapse cameras, built on the Witty Pi 4 fork, deployed to /home/pi/vision (project)

visIOn (repo `~/ClaudeSpace/visIOn`) is Inside Out Group's IoT endpoint
management service for field-deployed time-lapse cameras (Raspberry Pi +
Witty Pi 4 HAT, 3G/4G, UK-only, unattended). Step one (done 2026-07-31):
imported the hardened Witty-Pi-4 fork (firmware-rev14 line) as the base.
On-device run directory is **/home/pi/vision-service** — the runtime
scripts live directly in the service root, NO nested wittypi/ folder
(user was explicit about this). v5.37; deploy.sh auto-migrates both prior
layouts (/home/pi/wittypi and interim /home/pi/vision/wittypi), preserving
per-device state and removing the old install after a diff-verified copy.
Future modules (capture, uplink, fleet telemetry) will sit in subfolders
under the service root.

Key constraints from the imported stack: devices can lose power at any
instruction (everything must be re-runnable/crash-consistent); any shipped
change must bump `SOFTWARE_VERSION` in `Software/wittypi/utilities.sh`
(utilities.sh must stay last in UPDATE_FILES); shared I2C flock
`/var/lock/wittypi.i2c.lock` must be honoured by any new module touching
bus 1; GPIO claims BCM 4/13/14/17. Hosted at
github.com/insideoutgrp/vision-service (public, main branch — public is
required: devices deploy via unauthenticated curl of Software/deploy.sh);
deploy.sh REPO_URL points there.
