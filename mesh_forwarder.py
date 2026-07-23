#!/usr/bin/env python3
"""
Semtech UDP Forwarder for ChirpStack Gateway Mesh (v2.2).

Uplink:  gateway-mesh proxy (forwarder_event socket) → Semtech UDP PUSH_DATA → LGB
Downlink: LGB PULL_RESP → protobuf DownlinkFrame → gateway-mesh proxy → concentratord
RSSI:    from forwarder_event protobuf rx_info field 3 (float, border-received RSSI)

Architecture: For built-in NS, always use Semtech UDP path (NOT mqtt-forwarder).
  Container semtech-udp-forwarder → UDP → LGB (MQTT v3.1.1) → loraserver (NS)
  mqtt-forwarder uses MQTT v5 which is incompatible with gateway mosquitto 1.4.x
"""

import zmq
import struct
import json
import socket
import base64
import time
import os
import sys
import re
import threading
import logging

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
log = logging.getLogger("semtech-udp-fwd")

CONFIG_PATH = "/opt/chirpstack/mesh_forwarder.toml"
EVENT_URL = os.environ.get("FORWARDER_EVENT_URL", "ipc:///tmp/forwarder_event")
COMMAND_URL = os.environ.get("FORWARDER_COMMAND_URL", "ipc:///tmp/forwarder_command")
MESH_LOG_PATH = "/tmp/gateway-mesh.log"

# ── Protobuf helpers ──

def _read_varint(data, pos):
    result = shift = 0
    while pos < len(data):
        b = data[pos]; result |= (b & 0x7F) << shift; pos += 1
        if not (b & 0x80): break
        shift += 7
    return result, pos

def _write_varint(value):
    buf = bytearray()
    while value > 0x7F:
        buf.append((value & 0x7F) | 0x80)
        value >>= 7
    buf.append(value & 0x7F)
    return bytes(buf)

def _write_field(fn, wt, value):
    tag = (fn << 3) | wt
    r = _write_varint(tag)
    if wt == 0: r += _write_varint(value)
    elif wt == 2:
        if isinstance(value, str): value = value.encode()
        r += _write_varint(len(value)) + value
    elif wt == 5: r += struct.pack('<I', value)
    elif wt == 1: r += struct.pack('<Q', value)
    return r

def decode_pb(data):
    fields = {}; pos = 0
    while pos < len(data):
        tag, pos = _read_varint(data, pos)
        fn = tag >> 3; wt = tag & 0x07
        if wt == 0: val, pos = _read_varint(data, pos)
        elif wt == 1: val = struct.unpack('<Q', data[pos:pos+8])[0]; pos += 8
        elif wt == 2:
            l, pos = _read_varint(data, pos); val = data[pos:pos+l]; pos += l
        elif wt == 5: val = struct.unpack('<I', data[pos:pos+4])[0]; pos += 4
        else: break
        fields.setdefault(fn, []).append((wt, val))
    return fields

def _gb(fields, n, default=b''):
    for wt, val in fields.get(n, []):
        if wt == 2: return val
    return default

def _gv(fields, n, default=0):
    for wt, val in fields.get(n, []):
        if wt == 0: return val
    return default

def _gf(fields, n, default=0.0):
    for wt, val in fields.get(n, []):
        if wt == 5: return struct.unpack('<f', struct.pack('<I', val))[0]
    return default

# ── RSSI Cache ──

class RSSICache:
    def __init__(self, max_age=10):
        self._c = {}; self._lock = threading.Lock(); self._max_age = max_age
        self.hits = 0; self.misses = 0

    def put(self, uplink_id, rssi, snr=0.0):
        with self._lock:
            self._c[uplink_id] = (rssi, snr, time.time())
            now = time.time()
            for k in [k for k, v in self._c.items() if now - v[2] > self._max_age]:
                del self._c[k]

    def get(self, uplink_id):
        with self._lock:
            e = self._c.pop(uplink_id, None)
            if e and (time.time() - e[2]) < self._max_age:
                self.hits += 1; return e[0], e[1]
            self.misses += 1; return None, None

rssi_cache = RSSICache()

# ── RSSI Log Parser ──

def mesh_log_rssi_listener():
    """Tail gateway-mesh.log, extract uplink_id + rssi from 'Mesh frame received' lines."""
    log.info("RSSI log parser starting: %s", MESH_LOG_PATH)
    pattern = re.compile(
        r'Mesh frame received.*?uplink_id:\s*(\d+).*?rssi:\s*(-?\d+).*?snr:\s*([\d.-]+)'
    )
    count = 0
    while True:
        try:
            with open(MESH_LOG_PATH) as f:
                f.seek(0, 2)  # end
                while True:
                    line = f.readline()
                    if line:
                        m = pattern.search(line)
                        if m:
                            uid = int(m.group(1))
                            rssi = int(m.group(2))
                            snr = float(m.group(3))
                            rssi_cache.put(uid, rssi, snr)
                            count += 1
                            if count % 200 == 0:
                                log.info("RSSI log: cached %d (hits=%d, misses=%d)",
                                         count, rssi_cache.hits, rssi_cache.misses)
                    else:
                        time.sleep(0.1)
        except Exception as e:
            log.error("RSSI log parser error: %s", e)
            time.sleep(2)

# ── Uplink decode ──

def decode_uplink(data):
    f = decode_pb(data)
    phy = _gb(f, 1)
    tx_raw = _gb(f, 4); tx = decode_pb(tx_raw) if tx_raw else {}
    freq = _gv(tx, 1, 0)
    sf = 7; bw = 125000; cr = "4/5"
    mod_raw = _gb(tx, 2)
    if mod_raw:
        mi = decode_pb(mod_raw); lora_raw = _gb(mi, 3)
        if lora_raw:
            lora = decode_pb(lora_raw)
            sf = _gv(lora, 2, 7); bw = _gv(lora, 1, 125000)
            cr = {0:"4/5",1:"4/6",2:"4/7",3:"4/8"}.get(_gv(lora, 5, 0), "4/5")

    rx_raw = _gb(f, 5); rx = decode_pb(rx_raw) if rx_raw else {}
    gw_id = _gb(rx, 1, b'\x00'*8)

    # uplink_id from field 2 (concentratord original uplink_id)
    uplink_id = _gv(rx, 2, 0)

    # RSSI: field 3 is float (from concentratord UplinkEvent.rssi)
    rssi = int(_gf(rx, 3, 0.0))
    snr = _gf(rx, 7, 0.0)

    # Fallback: try RSSI cache (from gateway-mesh log) if protobuf RSSI is 0
    if rssi == 0 and uplink_id:
        cr, cs = rssi_cache.get(uplink_id)
        if cr is not None:
            rssi = cr
            if cs: snr = cs

    # tmst from context (field 5 → field 4 → field 1)
    tmst = 0
    ctx_raw = _gb(rx, 5)
    if ctx_raw:
        ctx = decode_pb(ctx_raw)
        et_raw = _gb(ctx, 4)
        if et_raw:
            et = decode_pb(et_raw); tmst = _gv(et, 1, 0)

    return {"phy": phy, "freq": freq, "sf": sf, "bw": bw, "cr": cr,
            "rssi": rssi, "snr": snr, "gw_id": gw_id, "tmst": tmst, "uid": uplink_id}

# ── Semtech UDP ──

PUSH_DATA=0; PUSH_ACK=1; PULL_DATA=2; PULL_ACK=3; PULL_RESP=4; TX_ACK=5

class UDPClient:
    def __init__(self, host, port, gw_id):
        self.server = (host, port); self.gw_id = gw_id
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(5.0)
        self.token = 0; self.last_pull = 0
        self.push_n = 0; self.ack_n = 0; self.dl_n = 0; self.running = True
        self.pending_pull_resp = None

    def _hdr(self, ident, tok=None):
        if tok is None:
            self.token = (self.token + 1) & 0xFFFF
            tok = struct.pack('>H', self.token)
        return struct.pack('>B', 0x02) + tok + struct.pack('>B', ident) + self.gw_id

    def push(self, rxpk_list, stat=None):
        tok = self._next_tok()
        body = {"rxpk": rxpk_list}
        if stat: body["stat"] = stat
        self.sock.sendto(self._hdr(PUSH_DATA, tok) + json.dumps(body).encode(), self.server)
        self.push_n += 1
        try:
            r, _ = self.sock.recvfrom(4096)
            if len(r) >= 4 and r[3] == PUSH_ACK: self.ack_n += 1
            elif len(r) >= 4 and r[3] == PULL_RESP:
                self.pending_pull_resp = (r[1:3], r[4:])
        except socket.timeout: pass

    def _next_tok(self):
        self.token = (self.token + 1) & 0xFFFF
        return struct.pack('>H', self.token)

    def pull_data(self):
        self.sock.sendto(self._hdr(PULL_DATA), self.server)
        self.last_pull = time.time()

    def tx_ack(self, tok, err=""):
        pkt = struct.pack('>B', 0x02) + tok + struct.pack('>B', TX_ACK) + self.gw_id
        if err: pkt += json.dumps({"error": err}).encode()
        self.sock.sendto(pkt, self.server)

    def poll_resp(self):
        if self.pending_pull_resp:
            tok, payload = self.pending_pull_resp
            self.pending_pull_resp = None
            return tok, payload
        try:
            self.sock.settimeout(0.01)
            d, _ = self.sock.recvfrom(4096)
            if len(d) >= 4 and d[3] == PULL_RESP:
                return d[1:3], d[4:]
        except (socket.timeout, OSError): pass
        finally: self.sock.settimeout(5.0)
        return None, None

# ── Downlink ──

def encode_downlink_cmd(txpk):
    """Encode txpk → protobuf Command(DownlinkFrame) for gateway-mesh proxy."""
    phy = base64.b64decode(txpk.get("data", ""))
    freq = int(txpk.get("freq", 0) * 1e6)
    datr = txpk.get("datr", "SF7BW125")
    sf = 7; bw = 125000
    if datr.startswith("SF"):
        p = datr.split("BW"); sf = int(p[0][2:]); bw = int(p[1]) * 1000
    power = int(txpk.get("powe", 14))
    tmst = txpk.get("tmst", 0)
    imme = txpk.get("imme", False)
    cr_str = txpk.get("codr", "4/5")

    lora = _write_field(1, 0, bw) + _write_field(2, 0, sf) + _write_field(5, 2, cr_str)
    if imme:
        timing = _write_field(3, 2, b'')
    else:
        timing = _write_field(1, 2, _write_field(1, 0, tmst))

    tx_info = (_write_field(1, 0, freq) + _write_field(3, 2, lora) +
               _write_field(5, 0, power) + _write_field(6, 2, timing))
    dl_id = int(time.time()) & 0xFFFFFFFF
    dl_frame = _write_field(1, 2, phy) + _write_field(2, 2, tx_info) + _write_field(3, 0, dl_id)
    return _write_field(1, 2, dl_frame), dl_id  # Command field 1 = send_downlink_frame

def downlink_loop(udp, cmd_sock):
    log.info("Downlink handler starting")
    while udp.running:
        tok, payload = udp.poll_resp()
        if payload is None: continue
        try:
            ps = payload.decode(errors='replace').strip()
            if not ps:
                log.debug("PULL_RESP empty (no pending downlink)")
                continue
            tx_data = json.loads(ps)
            txpk = tx_data.get("txpk", {})
            log.info("PULL_RESP: freq=%.3f MHz, datr=%s, %d bytes",
                     txpk.get("freq",0), txpk.get("datr","?"),
                     len(base64.b64decode(txpk.get("data",""))))
            cmd_bytes, dl_id = encode_downlink_cmd(txpk)
            try:
                cmd_sock.send(cmd_bytes)
                resp = cmd_sock.recv()
                log.info("Downlink %d → mesh, resp: %d bytes", dl_id, len(resp))
                udp.dl_n += 1
                udp.tx_ack(tok)
            except zmq.Again:
                log.warning("Downlink %d: cmd timeout", dl_id)
                udp.tx_ack(tok, "TIMEOUT")
        except json.JSONDecodeError as e:
            log.error("PULL_RESP parse error: %s, hex: %s", e, payload[:40].hex())
            udp.tx_ack(tok, "PARSE_ERROR")
        except Exception as e:
            log.error("Downlink error: %s", e)

# ── rxpk ──

def to_rxpk(u):
    return {"tmst": u["tmst"], "freq": round(u["freq"]/1e6, 6), "chan": 0, "rfch": 0,
            "stat": 1, "modu": "LORA", "datr": f"SF{u['sf']}BW{u['bw']//1000}",
            "codr": u["cr"], "rssi": u["rssi"], "lsnr": round(u["snr"], 1),
            "size": len(u["phy"]), "data": base64.b64encode(u["phy"]).decode()}

# ── Config ──

def read_config():
    host, port = "127.0.0.1", 1700
    try:
        c = open(CONFIG_PATH).read()
        m = re.search(r'semtech_server\s*=\s*"([^"]+)"', c)
        if m:
            p = m.group(1).rsplit(":", 1)
            host = p[0]; port = int(p[1]) if len(p) == 2 else 1700
        m2 = re.search(r'semtech_port\s*=\s*(\d+)', c)
        if m2: port = int(m2.group(1))
    except Exception as e:
        log.warning("Config error: %s, defaults", e)
    return host, port

def get_gw_id():
    # Method 0: gateway_eui.txt file (written by deploy script or manually)
    try:
        eui = open("/opt/chirpstack/gateway_eui.txt").read().strip()
        if len(eui) == 16 and eui != "0"*16:
            log.info("Gateway ID from file: %s", eui)
            return bytes.fromhex(eui.lower())
    except: pass

    gw = os.environ.get("GATEWAY_EUI", "")
    if gw and len(gw) == 16 and gw != "0"*16:
        log.info("Gateway ID from env: %s", gw)
        return bytes.fromhex(gw.lower())
    for p in ["/opt/chirpstack/concentratord.toml", "/opt/chirpstack/mesh_config.toml"]:
        try:
            m = re.search(r'gateway_id\s*=\s*"([0-9a-fA-F]{16})"', open(p).read())
            if m and m.group(1) != "0"*16:
                log.info("Gateway ID from %s: %s", p, m.group(1))
                return bytes.fromhex(m.group(1).lower())
        except: continue
    try:
        for item in open("/proc/1/environ","rb").read().split(b"\x00"):
            if item.startswith(b"GATEWAY_EUI="):
                gw = item.split(b"=",1)[1].decode().strip()
                if len(gw)==16 and gw!="0"*16:
                    log.info("Gateway ID from PID1: %s", gw)
                    return bytes.fromhex(gw.lower())
    except: pass
    return b'\x00'*8

# ── Main ──

def main():
    log.info("Semtech UDP Forwarder v2.2 (RSSI from forwarder_event protobuf)")
    host, port = read_config()
    log.info("Target: %s:%d", host, port)
    gw_id = get_gw_id()
    log.info("Gateway ID: %s", gw_id.hex())

    udp = UDPClient(host, port, gw_id)
    ctx = zmq.Context()

    sub = ctx.socket(zmq.SUB)
    sub.connect(EVENT_URL); sub.setsockopt(zmq.SUBSCRIBE, b""); sub.setsockopt(zmq.RCVTIMEO, 1000)

    cmd = ctx.socket(zmq.REQ)
    cmd.connect(COMMAND_URL); cmd.setsockopt(zmq.RCVTIMEO, 5000); cmd.setsockopt(zmq.SNDTIMEO, 3000)

    time.sleep(1)

    threading.Thread(target=mesh_log_rssi_listener, daemon=True).start()
    threading.Thread(target=downlink_loop, args=(udp, cmd), daemon=True).start()

    log.info("Listening for uplinks...")
    rx_n = 0; rssi_hits = 0; last_stat = time.time(); last_log_rx = 0

    # Deferred queue: hold uplinks briefly so log parser can fill RSSI
    pending = []  # [(send_time, uplink_dict)]
    DEFER_MS = 500  # milliseconds to wait for RSSI from log
    MAX_PENDING = 50

    while udp.running:
        try:
            frames = sub.recv_multipart()
            data = frames[0] if len(frames) == 1 else (frames[1] if len(frames) >= 2 and frames[0] == b"up" else None)
            if data and len(data) >= 3 and data[0] == 0x0a:
                ulen, pos = _read_varint(data, 1)
                if pos + ulen <= len(data):
                    u = decode_uplink(data[pos:pos+ulen])
                    if u["phy"]:
                        if u["rssi"] != 0:
                            # RSSI already available, send immediately
                            udp.push([to_rxpk(u)])
                            rx_n += 1; rssi_hits += 1
                            if rx_n <= 5:
                                log.info("Uplink #%d: %.1f MHz SF%d RSSI=%d SNR=%.1f uid=%d",
                                         rx_n, u["freq"]/1e6, u["sf"], u["rssi"], u["snr"], u["uid"])
                        else:
                            # Queue for deferred send (wait for log parser RSSI)
                            pending.append((time.time(), u))
                            if len(pending) > MAX_PENDING:
                                # Flush oldest
                                _, old_u = pending.pop(0)
                                udp.push([to_rxpk(old_u)])
                                rx_n += 1

            # Process pending queue: send if RSSI found or timeout
            now = time.time()
            remaining = []
            for ts, u in pending:
                age_ms = (now - ts) * 1000
                if u["rssi"] == 0 and u["uid"]:
                    cr, cs = rssi_cache.get(u["uid"])
                    if cr is not None:
                        u["rssi"] = cr
                        if cs: u["snr"] = cs
                if u["rssi"] != 0 or age_ms > DEFER_MS:
                    udp.push([to_rxpk(u)])
                    rx_n += 1
                    if u["rssi"] != 0: rssi_hits += 1
                    if rx_n <= 5:
                        log.info("Uplink #%d: %.1f MHz SF%d RSSI=%d SNR=%.1f uid=%d (deferred)",
                                 rx_n, u["freq"]/1e6, u["sf"], u["rssi"], u["snr"], u["uid"])
                else:
                    remaining.append((ts, u))
            pending = remaining

        except zmq.Again:
            # Process pending queue even on timeout
            now = time.time()
            remaining = []
            for ts, u in pending:
                age_ms = (now - ts) * 1000
                if u["rssi"] == 0 and u["uid"]:
                    cr, cs = rssi_cache.get(u["uid"])
                    if cr is not None:
                        u["rssi"] = cr; u["snr"] = cs or u["snr"]
                if u["rssi"] != 0 or age_ms > DEFER_MS:
                    udp.push([to_rxpk(u)]); rx_n += 1
                    if u["rssi"] != 0: rssi_hits += 1
                else:
                    remaining.append((ts, u))
            pending = remaining
        except Exception as e: log.error("Error: %s", e); time.sleep(1)

        if rx_n > 0 and rx_n % 100 == 0 and rx_n != last_log_rx:
            last_log_rx = rx_n
            rate = 100.0 * rssi_hits / rx_n if rx_n else 0
            log.info("Forwarded %d uplinks (RSSI: %.0f%%)", rx_n, rate)

        if time.time() - udp.last_pull > 10: udp.pull_data()
        if time.time() - last_stat > 30:
            udp.push([], {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                          "rxnb": rx_n, "rxok": rx_n, "rxfw": rx_n,
                          "ackr": 100.0 if udp.ack_n else 0.0,
                          "dwnb": udp.dl_n, "txnb": udp.dl_n})
            last_stat = time.time()

    sub.close(); cmd.close(); ctx.term()
    log.info("Stopped. %d uplinks, %d downlinks", rx_n, udp.dl_n)

if __name__ == "__main__":
    main()
