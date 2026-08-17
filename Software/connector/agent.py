"""visIOn connector — the online fleet module: telemetry up, commands down.

Runs alongside vision-service (never replaces it): telemetry is collected by
collect.sh through vision-service's own tools, and every command delegates to
vision-service scripts (camera.sh, runScript.sh). Designed for duty-cycled
devices with hard power cuts: telemetry spools to disk (atomic writes) and
drains on next connectivity; commands are idempotent and re-deliverable.
"""
import argparse
import json
import logging
import os
import random
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

log = logging.getLogger("connector")

AGENT_VERSION = "2.4"  # connector era: updates ride vision-service autoUpdate
# Fallback ingress: the dashboard host relays /v1/* to the API over a
# different network path. Used only when the primary API is unreachable
# at the connection level — survives a broken carrier<->DO route (the
# 2026-08-17 Tele2/LINX peering outage blacked the fleet out for ~105
# min while this path stayed up). Overridable via config fallback_url.
FALLBACK_URL = "https://statics-dashboard.netlify.app/relay"
SPEEDTEST_KB = 128     # ~4 MB/month/device at one test per day — SIMs pay per MB
HERE = Path(__file__).resolve().parent
LOG_FILES = {"wittyPi.log", "schedule.log", "cameraSettings.log"}  # tail allowlist
SHIP_LOG = "wittyPi.log"
SHIP_MAX = 32 * 1024


class Agent:
    def __init__(self, cfg_path: Path):
        local = yaml.safe_load(cfg_path.read_text())
        self.server = local["server_url"].rstrip("/")
        self.device_id = local["device_id"]
        self.vision_home = Path(local.get("vision_home", "/home/pi/vision-service"))
        self.interval = int(local.get("interval_s", 300))
        self.data_dir = Path(local.get("data_dir", "/var/lib/iovision"))
        self.spool = self.data_dir / "spool"
        self.spool.mkdir(parents=True, exist_ok=True)
        self.fallback = str(local.get("fallback_url", FALLBACK_URL)).rstrip("/")
        self.session = requests.Session()
        self.session.headers.update(
            {"X-Device-Id": self.device_id, "Authorization": f"Bearer {local['token']}"}
        )

    def request(self, method: str, path: str, **kw) -> requests.Response:
        """Primary API first; on a CONNECTION-level failure retry once via the
        relay. HTTP error statuses are returned as-is (the origin answered —
        the path works, the request is the problem)."""
        try:
            return self.session.request(method, f"{self.server}{path}", **kw)
        except requests.exceptions.RequestException as e:
            if not self.fallback:
                raise
            log.warning("primary API unreachable (%s) — retrying via relay",
                        e.__class__.__name__)
            return self.session.request(method, f"{self.fallback}{path}", **kw)

    # ---------------------------------------------------------- telemetry

    def collect(self) -> dict:
        report = {"reported_at": datetime.now(timezone.utc).isoformat(),
                  "agent_version": AGENT_VERSION}
        try:
            out = subprocess.run(
                ["bash", str(HERE / "collect.sh"), str(self.vision_home)],
                capture_output=True, text=True, timeout=90,
            ).stdout
            for line in out.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    report[k.strip()] = v.strip()
        except Exception as e:
            report["collect_error"] = str(e)[:200]
        snap = report.pop("camera_snapshot", "")
        if snap:
            cam = dict(re.findall(r"(\w+)='([^']*)'", snap))
            # the snapshot line is timestamped "[YYYY-MM-DD HH:MM:SS] ..." —
            # surface it so UIs can show how fresh the settings are
            m = re.match(r"^\[([^\]]+)\]", snap)
            if m:
                cam["snapshot_at"] = m.group(1)
            report["camera"] = cam
        report["log_delta"] = self._log_delta()
        # Network health piggybacked on our own traffic: timing of the previous
        # telemetry POST (continuous, costs nothing) and the latest micro
        # speed test (one-shot — reported once, not repeated every cycle).
        report.update(getattr(self, "_last_post", {}))
        if getattr(self, "_last_speedtest", None):
            report.update(self._last_speedtest)
            self._last_speedtest = None
        return report

    def _log_delta(self) -> str:
        """New wittyPi.log bytes since last successful ship (offset in state file)."""
        logf = self.vision_home / SHIP_LOG
        if not logf.exists():
            return ""
        state = self.data_dir / "log_offset"
        try:
            offset = int(state.read_text())
        except Exception:
            offset = 0
        size = logf.stat().st_size
        if size < offset:  # rotated/truncated
            offset = 0
        with open(logf, "rb") as f:
            f.seek(max(offset, size - SHIP_MAX) if size - offset > SHIP_MAX else offset)
            data = f.read(SHIP_MAX)
        self._pending_offset = size
        return data.decode("utf-8", "replace")

    def _commit_log_offset(self):
        off = getattr(self, "_pending_offset", None)
        if off is not None:
            tmp = self.data_dir / "log_offset.tmp"
            tmp.write_text(str(off))
            tmp.rename(self.data_dir / "log_offset")

    def spool_report(self, report: dict) -> None:
        tmp = self.spool / f".{uuid.uuid4().hex}.tmp"
        tmp.write_text(json.dumps(report))
        tmp.rename(self.spool / f"{report['reported_at']}.json")  # atomic — power cuts

    def drain(self) -> bool:
        files = sorted(self.spool.glob("*.json"))
        if not files:
            return True
        batch = files[-20:]  # newest matter most; older follow next round
        reports = []
        for f in batch:
            try:
                reports.append(json.loads(f.read_text()))
            except Exception:
                f.unlink()
        # Pre-encode so we know the exact byte count, and time the POST —
        # a free upload latency/throughput proxy on traffic we already pay for.
        payload = json.dumps({"reports": reports})
        t0 = time.monotonic()
        try:
            r = self.request("POST", "/v1/telemetry", data=payload,
                             headers={"Content-Type": "application/json"},
                             timeout=30)
            r.raise_for_status()
        except Exception as e:
            log.warning("telemetry send failed (%d spooled): %s", len(files), e)
            return False
        self._last_post = {"net_post_ms": round((time.monotonic() - t0) * 1000),
                           "net_post_bytes": len(payload)}
        for f in batch:
            f.unlink(missing_ok=True)
        self._commit_log_offset()
        log.info("sent %d report(s), %d still spooled", len(batch), len(files) - len(batch))
        return True

    def maybe_speedtest(self) -> None:
        """Micro download test: at most once per UTC day, fired at a random
        awake cycle (1-in-24 dice per 5-min cycle) so the timing is irregular
        and duty-cycled devices run it whenever they happen to be awake.
        128 KB/day ≈ 4 MB/month — the SIMs bill per MB, keep it small."""
        stamp = self.data_dir / "speedtest_date"
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        try:
            if stamp.read_text().strip() == today:
                return
        except Exception:
            pass
        if random.random() > 1 / 24:
            return
        try:
            t0 = time.monotonic()
            r = self.session.get(f"{self.server}/v1/speedtest?kb={SPEEDTEST_KB}",
                                 timeout=60)
            r.raise_for_status()
            elapsed = max(time.monotonic() - t0, 0.001)
            self._last_speedtest = {
                "net_dl_kbps": round(len(r.content) * 8 / 1000 / elapsed, 1)}
            stamp.write_text(today)
            log.info("speedtest: %d bytes in %.2fs (%.0f kbps)",
                     len(r.content), elapsed, self._last_speedtest["net_dl_kbps"])
        except Exception as e:
            log.warning("speedtest failed: %s", e)

    # ---------------------------------------------------------- commands

    def run_commands(self) -> None:
        try:
            r = self.request("GET", "/v1/commands", timeout=30)
            r.raise_for_status()
            data = r.json()
            commands = data["commands"]
        except Exception as e:
            log.warning("command fetch failed: %s", e)
            return
        # Relay the dashboard's one-shot update approval to autoUpdate.sh via
        # a marker file. Server-authoritative: created when approved, removed
        # when not (the server clears the flag once the new version reports).
        marker = self.vision_home / ".update_approved"
        try:
            if data.get("update_approved"):
                marker.touch()
            else:
                marker.unlink(missing_ok=True)
        except OSError as e:
            log.warning("update-approval marker: %s", e)
        for cmd in commands:
            log.info("command %s: %s %s", cmd["id"], cmd["type"], cmd.get("payload"))
            try:
                result = self.execute(cmd["type"], cmd.get("payload") or {})
                status = "done"
            except Exception as e:
                result, status = {"error": str(e)[:500]}, "failed"
            try:
                self.request("POST", f"/v1/commands/{cmd['id']}/result",
                             json={"status": status, "result": result}, timeout=30)
            except Exception as e:
                log.warning("result post failed for %s: %s", cmd["id"], e)
        if getattr(self, "_restart_pending", False):
            log.info("agent updated — exiting for systemd to restart with new code")
            sys.exit(0)

    def _vs(self, *argv, timeout=180) -> str:
        r = subprocess.run(list(argv), capture_output=True, text=True,
                           timeout=timeout, cwd=self.vision_home)
        out = (r.stdout + r.stderr).strip()
        if r.returncode != 0:
            raise RuntimeError(f"rc={r.returncode}: {out[:500]}")
        return out[:4000]

    def execute(self, ctype: str, p: dict) -> dict:
        home = self.vision_home
        if ctype == "ping":
            return {"pong": True}
        if ctype == "set_schedule":
            name = Path(p["name"]).name  # no traversal
            r = self.request("GET", f"/v1/schedules/{name}", timeout=30)
            r.raise_for_status()
            tmp = home / "schedule.wpi.new"
            tmp.write_text(r.text)
            tmp.rename(home / "schedule.wpi")
            out = self._vs("bash", str(home / "runScript.sh"), "0", "revise")
            tail = self._vs("tail", "-5", str(home / "schedule.log"))
            return {"applied": name, "runScript": out[-1000:], "schedule_log": tail}
        if ctype == "camera_get":
            arg = ["get", p["param"]] if p.get("param") else ["status"]
            return {"output": self._vs("bash", str(home / "camera.sh"), *arg)}
        if ctype == "camera_set":
            return {"output": self._vs("bash", str(home / "camera.sh"),
                                       "set", p["param"], str(p["value"]))}
        if ctype == "camera_focus":
            argv = ["bash", str(home / "camera.sh"), "focus", p["point"]]
            if p.get("af"):
                argv.append("af")
            return {"output": self._vs(*argv)}
        if ctype == "camera_logsettings":
            return {"output": self._vs("bash", str(home / "camera.sh"), "logsettings")}
        if ctype == "tail_log":
            fname = Path(p.get("file", SHIP_LOG)).name
            if fname not in LOG_FILES:
                raise ValueError(f"file not allowed: {fname}")
            n = str(min(int(p.get("lines", 100)), 500))
            return {"output": self._vs("tail", f"-{n}", str(home / fname))}
        if ctype == "camera_refresh":
            # The daily snapshot is date-guarded (one wear datapoint per day);
            # clearing the stamp lets it run immediately. Works on any
            # vision-service version — the stamp is documented per-device state.
            (home / ".camera_log_date").unlink(missing_ok=True)
            # Repair split ownership: on most devices the root cron created
            # cameraSettings.log, so pi appends get Permission denied. We can't
            # chown it, but we CAN replace it (directory write) with an
            # identical copy that both writers can append to. vision-service
            # v5.42 keeps it 666 from then on.
            logf = home / "cameraSettings.log"
            if logf.exists() and not os.access(logf, os.W_OK):
                tmp = home / "cameraSettings.log.new"
                tmp.write_bytes(logf.read_bytes())
                os.chmod(tmp, 0o666)
                tmp.rename(logf)
                log.info("camera_refresh: repaired cameraSettings.log ownership (root->pi, 666)")
            out = self._vs("bash", str(home / "camera.sh"), "logsettings", timeout=300)
            snap = ""
            logf = home / "cameraSettings.log"
            if logf.exists():
                for line in logf.read_text(errors="replace").splitlines():
                    if " model='" in line:
                        snap = line
            return {"output": out[-500:], "snapshot": snap[-1500:]}
        if ctype == "update_agent":
            raise ValueError(
                "update_agent is retired: the connector ships with vision-service "
                "and updates via autoUpdate.sh (SOFTWARE_VERSION bumps on main)")
        raise ValueError(f"unknown command type: {ctype}")

    # ---------------------------------------------------------- main loop

    def cycle(self) -> None:
        self.spool_report(self.collect())
        self.drain()
        self.maybe_speedtest()
        self.run_commands()

    def run(self) -> None:
        log.info("agent starting: device=%s server=%s interval=%ss",
                 self.device_id, self.server, self.interval)
        while True:
            started = time.monotonic()
            try:
                self.cycle()
            except Exception:
                log.exception("cycle failed")
            time.sleep(max(5, self.interval - (time.monotonic() - started)))


def main() -> None:
    ap = argparse.ArgumentParser(description="iovision management agent")
    ap.add_argument("-c", "--config", default="/etc/iovision/config.yaml", type=Path)
    ap.add_argument("--once", action="store_true", help="one cycle then exit")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    agent = Agent(args.config)
    agent.cycle() if args.once else agent.run()


if __name__ == "__main__":
    sys.exit(main())
