# connector — the online fleet module

Connects the device to the iovision platform (`api.insideoutgroup.co.uk`):
telemetry every 5 min while awake (Witty Pi voltage/current/temperature, boot
reason, firmware/software versions, camera settings snapshot incl. shutter
count, wittyPi.log deltas) and a polled command queue (`set_schedule`,
`camera_*`, `tail_log`) — all delegating to the vision-service runtime and
honouring its I2C flock and USB claim rules.

- **Code** deploys to `/home/pi/vision-service/connector/` on EVERY device via
  deploy.sh / autoUpdate.sh (same atomic, syntax-gated rules as the runtime).
- **It only runs where enrolled**: enrolment (from the iovision dashboard —
  `curl .../enrol.sh | sudo bash -s -- <id> <token>`) writes
  `/etc/iovision/config.yaml` and enables `vision-connector.service`.
  Unenrolled devices carry the code inert.
- State: `/var/lib/iovision/` (telemetry spool, log-ship offset). Crash-safe:
  spool survives hard power cuts, drains on next wake.
- Deps: `python3-requests`, `python3-yaml` (apt; installed by install.sh /
  deploy.sh).
- **Victron solar charger** (v5.67, `victron.py`): each cycle scans ~8 s for
  Victron Bluetooth adverts, connects to the controller (the one read last
  time if still heard, else the strongest signal), pairs with Victron's
  default PIN 000000 on first contact, reads battery/PV values over the
  VE.Smart GATT protocol and disconnects — ~20 s, no keys. Read-only (GET +
  session keep-alive only). Reported as `vic_*` fields; `vic_heard=0` means
  no controller in range. Runs as root via `sudo -n` (BlueZ D-Bus); in the
  field Bluetooth is switched on only for the pass. Needs `python3-dbus` and
  `python3-gi`. Server setting `victron_enabled` turns it off fleet-wide.
- Versioning: rides `SOFTWARE_VERSION` — no separate update channel.
  (`AGENT_VERSION` in agent.py tracks connector protocol revisions and is
  reported in telemetry.)
