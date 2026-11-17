#!/usr/bin/env python3
"""victron.py — read the nearby Victron solar charger over Bluetooth.

Run once per telemetry cycle by agent.py (as root: BlueZ's D-Bus API). One
short pass, ~20 s, no separate service and no keys:

  1. scan ~8 s for Victron advertisements (company id 0x02E1). Presence,
     product id and record type are sent in the clear, so every camera
     reports whether it can hear a controller at all.
  2. pick the controller: the one read last time if it is still heard
     (sticky — cameras sharing a compound must not flip between
     controllers), else the strongest signal.
  3. connect, pair with Victron's default PIN 000000 if not yet paired, read
     the live values over the VE.Smart GATT protocol, disconnect. Connect
     THEN pair: pairing straight off a scan drops the link on the Pi's
     mini-UART Bluetooth (proven on Barrow Luco 2026-11-17).

READ-ONLY: only GET requests and the protocol's session keep-alive are sent.
Settings writes stay in the VictronService bench toolkit.

Prints vic_* key=value lines that agent.py merges into the telemetry report.
The VE.Smart protocol is ported from VictronService victrond/vesmart.py
(CBOR messages over characteristics 306b0002-306b0004).

Deps: python3-dbus, python3-gi (Raspbian packages; deploy.sh installs them).
"""

import argparse
import json
import signal
import struct
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

VICTRON_ID = 0x02E1
SCAN_S = 8.0
DEADLINE_S = 55          # agent.py kills us at 75 s; clean up well before
CONNECT_S = 25
PAIR_S = 40
LISTEN_S = 5.0           # pushed values arrive within ~2 s of subscribing
FAILS_BEFORE_REPAIR = 3  # consecutive empty reads on a paired unit -> re-pair

BLUEZ = "org.bluez"
ADAPTER_IF = "org.bluez.Adapter1"
DEVICE_IF = "org.bluez.Device1"
CHAR_IF = "org.bluez.GattCharacteristic1"
AGENT_MGR_IF = "org.bluez.AgentManager1"
PROPS_IF = "org.freedesktop.DBus.Properties"
OM_IF = "org.freedesktop.DBus.ObjectManager"
AGENT_PATH = "/org/iovision/victron_agent"

CTRL = "306b0002-b081-4037-83dc-e59fcc3cdfd0"
LAST = "306b0003-b081-4037-83dc-e59fcc3cdfd0"
DATA = "306b0004-b081-4037-83dc-e59fcc3cdfd0"

OP_PING, OP_SUBSCRIBE, OP_GET = 1, 3, 5
REPLY_VALUE, REPLY_REFUSED = 8, 9
_ARITY = {2: 1, 13: 2}               # reply param counts; default 3
REGRANT_AFTER = 0x41                 # regrant credits every 65 received chunks
KEEPALIVE = bytes.fromhex("0600821893421027")  # session keep-alive (vreg 0x93)

# report key -> (vreg, struct fmt, divisor)
REGISTERS = {
    "vic_batt_v":    (0xED8D, "<h", 100),
    "vic_batt_a":    (0xED8F, "<h", 10),
    "vic_pv_v":      (0xEDBB, "<H", 100),
    "vic_pv_a":      (0xEDBD, "<H", 10),
    "vic_pv_w":      (0xEDBC, "<I", 100),
    "vic_yield_kwh": (0xEDD3, "<I", 100),
    "vic_state":     (0x0201, "<B", 1),
    "vic_error":     (0xEDDA, "<B", 1),
}
_NA = {"<B": 0xFF, "<H": 0xFFFF, "<I": 0xFFFFFFFF, "<h": 0x7FFF}

# Instant Readout record types (byte 4 of the advertisement, sent unencrypted)
RECORD_TYPES = {
    0x01: "solar_charger", 0x02: "battery_monitor", 0x03: "inverter",
    0x04: "dcdc_converter", 0x05: "smart_lithium", 0x08: "ac_charger",
    0x09: "smart_battery_protect", 0x0A: "lynx_smart_bms", 0x0B: "multi_rs",
    0x0C: "ve_bus", 0x0D: "dc_energy_meter", 0x0F: "orion_xs",
}


# ---------- minimal CBOR (the subset Victron uses) --------------------------

def enc_uint(n):
    if n < 24:
        return bytes([n])
    if n < 0x100:
        return bytes([0x18, n])
    if n < 0x10000:
        return bytes([0x19]) + n.to_bytes(2, "big")
    return bytes([0x1A]) + n.to_bytes(4, "big")


def enc_arr(n):
    return bytes([0x80 | n]) if n < 24 else bytes([0x98, n])


_BREAK = object()


def _dec_item(buf, pos):
    first = buf[pos]
    pos += 1
    if first == 0xFF:
        return _BREAK, pos
    major, info = first >> 5, first & 0x1F
    if info == 31:                   # indefinite-length array / byte string
        if major not in (2, 4):
            raise ValueError("indefinite major %d" % major)
        items = []
        while True:
            item, pos = _dec_item(buf, pos)
            if item is _BREAK:
                break
            items.append(item)
        return (b"".join(items) if major == 2 else items), pos
    if info < 24:
        val = info
    elif info in (24, 25, 26, 27):
        size = 1 << (info - 24)
        val = int.from_bytes(buf[pos:pos + size], "big")
        pos += size
    else:
        raise ValueError("bad cbor info %d" % info)
    if major in (0, 1):
        return (val if major == 0 else -1 - val), pos
    if major == 2:
        return bytes(buf[pos:pos + val]), pos + val
    if major == 4:
        items = []
        for _ in range(val):
            item, pos = _dec_item(buf, pos)
            items.append(item)
        return items, pos
    if major == 7:
        return ("simple", val), pos
    raise ValueError("unsupported cbor major %d" % major)


def decode_messages(chunk):
    """Split a reassembled chunk into [(opcode, params)]."""
    out, pos, n = [], 0, len(chunk)
    while pos < n:
        opcode, pos = _dec_item(chunk, pos)
        params = []
        for _ in range(_ARITY.get(opcode, 3)):
            if pos >= n:
                break
            item, pos = _dec_item(chunk, pos)
            params.append(item)
        out.append((opcode, params))
    return out


def build_get(instance, vreg):
    return bytes([OP_GET]) + enc_uint(instance) + enc_arr(1) + enc_uint(vreg)


def decode_value(fmt, divisor, raw):
    size = struct.calcsize(fmt)
    if raw is None or len(raw) < size:
        return None
    (v,) = struct.unpack(fmt, raw[:size])
    if _NA.get(fmt) == v:
        return None
    return round(v / divisor, 2) if divisor != 1 else v


def advert_info(mfr):
    """(product id, record type name) from a Victron advertisement payload
    (company id stripped, as BlueZ delivers it). Instant Readout frames start
    0x10; the product id and record type precede the encrypted part."""
    if len(mfr) >= 5 and mfr[0] == 0x10:
        return mfr[2] | (mfr[3] << 8), RECORD_TYPES.get(mfr[4], "type_0x%02x" % mfr[4])
    return None, None


def choose(candidates, sticky_mac):
    """candidates: [{mac, rssi, ...}]. The previously read controller wins
    while it is still heard; otherwise the strongest signal."""
    if not candidates:
        return None
    for c in candidates:
        if sticky_mac and c["mac"] == sticky_mac:
            return c
    return max(candidates, key=lambda c: c["rssi"] if c["rssi"] is not None else -999)


# ---------- BlueZ over D-Bus --------------------------------------------------

class Timeout(Exception):
    pass


class Ble:
    def __init__(self):
        import dbus
        import dbus.mainloop.glib
        from gi.repository import GLib
        self.dbus = dbus
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SystemBus()
        self.ctx = GLib.MainContext.default()
        self.om = dbus.Interface(self.bus.get_object(BLUEZ, "/"), OM_IF)
        self.adapter_path = None
        self.scanning = False
        self.heard = {}            # device path -> latest RSSI seen this scan
        self.char_role = {}        # characteristic path -> CTRL/LAST/DATA
        self.session = None
        self.bus.add_signal_receiver(
            self._on_props, signal_name="PropertiesChanged",
            dbus_interface=PROPS_IF, bus_name=BLUEZ, path_keyword="path")
        self.bus.add_signal_receiver(
            self._on_added, signal_name="InterfacesAdded",
            dbus_interface=OM_IF, bus_name=BLUEZ)

    # -- plumbing
    def pump(self, seconds, until=None):
        end = time.monotonic() + seconds
        while True:
            if until is not None and until():
                return True
            if time.monotonic() >= end:
                return False
            if not self.ctx.iteration(False):
                time.sleep(0.02)

    def call(self, method, *args, timeout=30):
        """Asynchronous D-Bus call, pumping the loop meanwhile — Pair() needs
        our own agent to answer BlueZ while the call is outstanding."""
        res = {}
        method(*args, reply_handler=lambda *r: res.setdefault("ok", r),
               error_handler=lambda e: res.setdefault("err", e),
               timeout=timeout)
        self.pump(timeout + 2, lambda: res)
        if "err" in res:
            raise res["err"]
        if "ok" not in res:
            raise Timeout(getattr(method, "_method_name", "call"))
        return res["ok"]

    def obj(self, path, iface):
        return self.dbus.Interface(self.bus.get_object(BLUEZ, path), iface)

    def prop(self, path, iface, name):
        try:
            return self.obj(path, PROPS_IF).Get(iface, name)
        except self.dbus.DBusException:
            return None

    def managed(self):
        return self.om.GetManagedObjects()

    # -- adapter
    def power_on(self, wait_s=10):
        def find():
            for path, ifaces in self.managed().items():
                if ADAPTER_IF in ifaces:
                    self.adapter_path = path
                    return True
            return False
        if not self.pump(wait_s, find):
            raise RuntimeError("no_adapter")
        if not self.prop(self.adapter_path, ADAPTER_IF, "Powered"):
            self.obj(self.adapter_path, PROPS_IF).Set(
                ADAPTER_IF, "Powered", self.dbus.Boolean(True))
            if not self.pump(wait_s, lambda: bool(
                    self.prop(self.adapter_path, ADAPTER_IF, "Powered"))):
                raise RuntimeError("adapter_off")

    # -- scan
    def _on_added(self, path, ifaces):
        if self.scanning and DEVICE_IF in ifaces and "RSSI" in ifaces[DEVICE_IF]:
            self.heard[str(path)] = int(ifaces[DEVICE_IF]["RSSI"])

    def _on_props(self, iface, changed, _invalidated, path=None):
        if iface == DEVICE_IF:
            if self.scanning and "RSSI" in changed:
                self.heard[str(path)] = int(changed["RSSI"])
        elif iface == CHAR_IF and "Value" in changed and self.session:
            role = self.char_role.get(str(path))
            if role:
                self.session.on_notify(role, bytes(changed["Value"]))

    def scan(self, seconds):
        adapter = self.obj(self.adapter_path, ADAPTER_IF)
        try:
            adapter.SetDiscoveryFilter({"Transport": "le",
                                        "DuplicateData": self.dbus.Boolean(True)})
        except self.dbus.DBusException:
            pass
        self.scanning = True
        try:
            adapter.StartDiscovery()
        except self.dbus.DBusException as e:
            if "InProgress" not in str(e):
                raise
        self.pump(seconds)
        self.scanning = False
        try:
            adapter.StopDiscovery()
        except self.dbus.DBusException:
            pass
        found = []
        objects = self.managed()
        for path, rssi in self.heard.items():
            dev = objects.get(self.dbus.ObjectPath(path), {}).get(DEVICE_IF)
            if not dev:
                continue
            mfr = dev.get("ManufacturerData", {})
            if VICTRON_ID not in mfr:
                continue
            pid, rtype = advert_info(bytes(mfr[VICTRON_ID]))
            found.append({"path": path, "mac": str(dev.get("Address", "")),
                          "name": str(dev.get("Alias", "")), "rssi": rssi,
                          "pid": pid, "type": rtype,
                          "paired": bool(dev.get("Paired", False)),
                          "connected": bool(dev.get("Connected", False))})
        return found

    # -- pairing agent (answers BlueZ with Victron's default PIN)
    def register_agent(self):
        dbus = self.dbus
        import dbus.service

        class Agent(dbus.service.Object):
            @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
            def RequestPasskey(self, _device):
                return dbus.UInt32(0)                      # 000000

            @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
            def RequestPinCode(self, _device):
                return "000000"

            @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
            def RequestConfirmation(self, _device, _passkey):
                return

            @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
            def RequestAuthorization(self, _device):
                return

            @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
            def AuthorizeService(self, _device, _uuid):
                return

            @dbus.service.method("org.bluez.Agent1", in_signature="ouq", out_signature="")
            def DisplayPasskey(self, _device, _passkey, _entered):
                return

            @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
            def DisplayPinCode(self, _device, _pin):
                return

            @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
            def Cancel(self):
                return

            @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
            def Release(self):
                return

        self._agent = Agent(self.bus, AGENT_PATH)
        mgr = self.obj("/org/bluez", AGENT_MGR_IF)
        mgr.RegisterAgent(AGENT_PATH, "KeyboardOnly")
        mgr.RequestDefaultAgent(AGENT_PATH)

    def unregister_agent(self):
        if getattr(self, "_agent", None) is None:
            return
        try:
            self.obj("/org/bluez", AGENT_MGR_IF).UnregisterAgent(AGENT_PATH)
        except self.dbus.DBusException:
            pass
        self._agent = None

    # -- connection
    def connect(self, path):
        dev = self.obj(path, DEVICE_IF)
        if not self.prop(path, DEVICE_IF, "Connected"):
            self.call(dev.Connect, timeout=CONNECT_S)
        if not self.pump(15, lambda: bool(self.prop(path, DEVICE_IF, "ServicesResolved"))):
            raise RuntimeError("services_unresolved")

    def pair(self, path):
        self.register_agent()
        try:
            self.call(self.obj(path, DEVICE_IF).Pair, timeout=PAIR_S)
        except self.dbus.DBusException as e:
            if "AlreadyExists" not in str(e):
                raise
        finally:
            self.unregister_agent()
        self.obj(path, PROPS_IF).Set(DEVICE_IF, "Trusted", self.dbus.Boolean(True))
        self.pump(10, lambda: bool(self.prop(path, DEVICE_IF, "ServicesResolved")))

    def disconnect(self, path):
        for cpath in list(self.char_role):
            try:
                self.obj(cpath, CHAR_IF).StopNotify()
            except self.dbus.DBusException:
                pass
        try:
            self.obj(path, DEVICE_IF).Disconnect()
        except self.dbus.DBusException:
            pass

    def remove(self, path):
        try:
            self.obj(self.adapter_path, ADAPTER_IF).RemoveDevice(self.dbus.ObjectPath(path))
        except self.dbus.DBusException:
            pass

    def characteristics(self, path):
        roles = {CTRL: "ctrl", LAST: "last", DATA: "data"}
        out = {}
        for cpath, ifaces in self.managed().items():
            ch = ifaces.get(CHAR_IF)
            if ch and str(cpath).startswith(path + "/") and str(ch.get("UUID")).lower() in roles:
                role = roles[str(ch["UUID"]).lower()]
                out[role] = str(cpath)
                self.char_role[str(cpath)] = role
        return out

    def write(self, cpath, payload):
        arr = self.dbus.Array(payload, signature="y")
        char = self.obj(cpath, CHAR_IF)
        try:
            char.WriteValue(arr, {"type": "command"})   # write without response
        except self.dbus.DBusException as e:
            if "InvalidArguments" not in str(e) and "NotSupported" not in str(e):
                raise
            char.WriteValue(arr, {})


class VeSmartSession:
    """Read-only VE.Smart session over an open, paired connection."""

    def __init__(self, ble, chars):
        self.ble, self.chars = ble, chars
        self.buf = bytearray()
        self.values, self.inst_of, self.refused = {}, {}, set()
        self.credits, self.att, self.max_inst, self.rx_chunks = 1, 20, 4, 0
        self.last_keepalive = 0.0

    def on_notify(self, role, data):
        if role == "ctrl":
            if len(data) >= 2 and data[0] == 0xF9:
                self.credits += data[1]
            return
        self.buf += data
        if role != "last":
            return
        chunk, self.buf = bytes(self.buf), bytearray()
        self.rx_chunks += 1
        try:
            for opcode, params in decode_messages(chunk):
                if opcode == REPLY_VALUE and len(params) >= 3 \
                        and isinstance(params[1], int) and isinstance(params[2], bytes):
                    self.values[params[1]] = params[2]
                    self.inst_of[params[1]] = params[0]
                elif opcode == REPLY_REFUSED and len(params) >= 2 \
                        and isinstance(params[1], int):
                    self.refused.add(params[1])
        except Exception:
            pass                     # a malformed chunk loses one push, not the read
        if self.rx_chunks % REGRANT_AFTER == 0:
            try:
                self.ble.write(self.chars["ctrl"], bytes([0xF9, REGRANT_AFTER]))
            except Exception:
                pass

    def send(self, payload):
        if self.credits <= 0:
            self.ble.pump(3.0, lambda: self.credits > 0)
        self.credits -= 1
        for i in range(0, len(payload), self.att):
            piece = payload[i:i + self.att]
            role = "last" if i + self.att >= len(payload) else "data"
            self.ble.write(self.chars[role], piece)

    def keepalive(self):
        self.send(KEEPALIVE)
        self.last_keepalive = time.monotonic()

    def open(self):
        for role in ("ctrl", "last", "data"):
            self.ble.obj(self.chars[role], CHAR_IF).StartNotify()
        info = bytes(self.ble.obj(self.chars["ctrl"], CHAR_IF).ReadValue({}))
        if len(info) >= 5:
            _flags, max_inst, max_free, _chunk = struct.unpack_from("<BHBB", info)
            self.credits = max(1, max_free)
            self.max_inst = max(1, max_inst)
            if len(info) >= 7:
                self.att = max(20, struct.unpack_from("<H", info, 5)[0])
        self.ble.write(self.chars["ctrl"], bytes.fromhex("fa80ff"))
        self.ble.write(self.chars["ctrl"], bytes.fromhex("f980"))  # grant 128 chunks
        self.send(bytes([OP_PING]))
        self.ble.pump(0.3)
        for inst in range(min(self.max_inst, 8)):    # the charger's data lives
            self.send(bytes([OP_SUBSCRIBE]) + enc_uint(inst))  # on a non-zero
            self.ble.pump(0.2)                        # instance — subscribe all
        self.keepalive()

    def primary_instance(self):
        if self.inst_of:
            return Counter(self.inst_of.values()).most_common(1)[0][0]
        return 0

    def get(self, vreg, timeout=3.0):
        if time.monotonic() - self.last_keepalive > 8:
            self.keepalive()
        self.send(build_get(self.inst_of.get(vreg, self.primary_instance()), vreg))
        self.ble.pump(timeout, lambda: vreg in self.values or vreg in self.refused)
        return self.values.get(vreg)

    def read_all(self):
        self.ble.pump(LISTEN_S)                      # take what the charger pushes
        out = {}
        for key, (vreg, fmt, div) in REGISTERS.items():
            raw = self.values.get(vreg)
            if raw is None and vreg not in self.refused:
                raw = self.get(vreg)                 # poll anything not pushed
            v = decode_value(fmt, div, raw)
            if v is not None:
                out[key] = v
        return out


# ---------- one pass ----------------------------------------------------------

def _alarm(_sig, _frame):
    raise Timeout("deadline")


def _rfkill(action):
    subprocess.run(["rfkill", action, "bluetooth"], capture_output=True, timeout=10)


def _load_state(path):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return {}


def _save_state(path, state):
    try:
        tmp = Path(str(path) + ".tmp")
        tmp.write_text(json.dumps(state))
        tmp.replace(path)
    except Exception:
        pass


def run(state_path, field):
    report = {}
    state = _load_state(state_path)
    signal.signal(signal.SIGALRM, _alarm)
    signal.alarm(DEADLINE_S)
    ble, target, linked = None, None, False
    try:
        if field:
            _rfkill("unblock")       # power-save keeps Bluetooth off in the field
        ble = Ble()
        ble.power_on()
        found = ble.scan(SCAN_S)
        report["vic_heard"] = len(found)
        target = choose(found, state.get("mac"))
        if not target:
            return report
        report.update({"vic_mac": target["mac"], "vic_rssi": target["rssi"],
                       "vic_name": target["name"],
                       "vic_type": target["type"] or "unknown"})
        if target["pid"] is not None:
            report["vic_pid"] = "0x%04X" % target["pid"]
        # Only solar chargers are read; anything else is reported, not touched.
        # No record type (Instant Readout off) -> trust the advertised name.
        is_charger = (target["type"] == "solar_charger"
                      or (target["type"] is None and "Solar" in target["name"]))
        if not is_charger:
            return report
        t0 = time.monotonic()
        ble.connect(target["path"])
        if not ble.prop(target["path"], DEVICE_IF, "Paired"):
            ble.pair(target["path"])
            report["vic_paired"] = 1
        linked = True                # connected and paired: failures from here count
        chars = ble.characteristics(target["path"])
        if set(chars) != {"ctrl", "last", "data"}:
            raise RuntimeError("no_vesmart_service")
        ble.session = VeSmartSession(ble, chars)
        ble.session.open()
        values = ble.session.read_all()
        report.update(values)
        report["vic_read_s"] = round(time.monotonic() - t0, 1)
        if values:
            state.update({"mac": target["mac"], "fails": 0, "ok_at": int(time.time())})
        else:
            raise RuntimeError("no_values")
    except Exception as e:
        dbus_name = e.get_dbus_name() if hasattr(e, "get_dbus_name") else None
        reason = (dbus_name.rsplit(".", 1)[-1] if dbus_name
                  else ("%s %s" % (type(e).__name__, e)).strip())
        report["vic_fail"] = reason[:80].replace("\n", " ")
        if linked:
            # A paired unit that keeps giving us nothing may have dropped its
            # side of the bond (e.g. reset): forget it so a later pass pairs
            # afresh. Out-of-range/connect failures don't count.
            state["fails"] = state.get("fails", 0) + 1
            if state["fails"] >= FAILS_BEFORE_REPAIR and ble and ble.adapter_path:
                ble.remove(target["path"])
                state["fails"] = 0
                report["vic_repair"] = 1
    finally:
        signal.alarm(0)
        if ble and target:
            try:
                ble.disconnect(target["path"])
            except Exception:
                pass
        if field:
            _rfkill("block")
        _save_state(state_path, state)
    return report


def _fmt(v):
    return ("%g" % v) if isinstance(v, float) else str(v)


def main():
    ap = argparse.ArgumentParser(description="read the nearby Victron solar charger (read-only)")
    ap.add_argument("--state", default="/var/lib/iovision/victron.json")
    ap.add_argument("--field", action="store_true",
                    help="unblock Bluetooth for the pass, block it again after")
    args = ap.parse_args()
    for k, v in run(args.state, args.field).items():
        print("%s=%s" % (k, _fmt(v).replace("\n", " ")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
