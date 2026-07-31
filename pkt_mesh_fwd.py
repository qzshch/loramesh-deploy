#!/usr/bin/env python3
"""
LoRa Mesh Forwarder — native pkt_fwd edition.

UDP proxy between pkt_fwd and gateway-bridge, adding mesh (MType=111) support:
  Relay:  sensor → wrap MType=111 → TX via PULL_RESP → also forward to NS
  Border: unwrap MType=111 → forward original PHYPayload to NS

Deploy:
  1. Copy to gateway: cp pkt_mesh_fwd.py /opt/chirpstack/
  2. Modify pkt_fwd server to 127.0.0.1:1701 (mesh forwarder listen port)
  3. Run: python3 /opt/chirpstack/pkt_mesh_fwd.py --role relay

Architecture:
  pkt_fwd --PUSH_DATA/PULL_DATA--> mesh_fwd (UDP:1701) --PUSH_DATA--> gw_bridge (UDP:1700)
                                    |
                                    +-- PULL_RESP --> pkt_fwd --> RF TX mesh frame
"""

import argparse
import base64
import json
import logging
import os
import signal
import socket
import struct
import subprocess
import sys
import time
from collections import deque

# ── Crypto (pycryptodome preferred, fallback to built-in) ──────────
try:
    from Crypto.Cipher import AES as _AES
    from Crypto.Hash import CMAC as _CMAC
    HAS_PYCRYPTODOME = True
except ImportError:
    HAS_PYCRYPTODOME = False

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%H:%M:%S'
)
log = logging.getLogger('mesh-fwd')

# ── Semtech UDP Protocol ───────────────────────────────────────────
PROTO = 2
PUSH_DATA, PUSH_ACK, PULL_DATA, PULL_ACK, PULL_RESP, TX_ACK = 0, 1, 2, 3, 4, 5
# Note: Semtech spec has PULL_ACK=4, PULL_RESP=3 — we follow pkt_fwd convention

# ── US915 DR table ─────────────────────────────────────────────────
DATR_TO_DR = {
    'SF10BW125': 0, 'SF9BW125': 1, 'SF8BW125': 2, 'SF7BW125': 3,
    'SF8BW500': 4, 'SF12BW500': 5, 'SF11BW500': 6,
}
DR_TO_DATR = {v: k for k, v in DATR_TO_DR.items()}

# ── Mesh constants ─────────────────────────────────────────────────
MTYPE_PROP = 0x07  # MType bits [7:5] = 111 (Proprietary)
PT_UPLINK, PT_DOWNLINK, PT_EVENT, PT_COMMAND = 0, 1, 2, 3
DEDUP_SIZE = 512

# ═══════════════════════════════════════════════════════════════════
#  AES-CMAC (built-in fallback when pycryptodome unavailable)
# ═══════════════════════════════════════════════════════════════════

if not HAS_PYCRYPTODOME:
    _SBOX = [
        0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
        0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
        0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
        0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
        0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
        0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
        0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
        0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
        0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
        0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
        0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
        0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
        0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
        0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
        0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
        0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
    ]
    _RCON = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]

    def _xtime(a):
        return ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else (a << 1) & 0xff

    def _aes128_block(key, pt):
        """Single-block AES-128 encrypt (pure Python)."""
        rk = list(key)
        for i in range(4, 44):
            t = rk[(i-1)*4:i*4]
            if i % 4 == 0:
                t = [_SBOX[b] for b in t[1:]+t[:1]]
                t[0] ^= _RCON[i//4 - 1]
            rk.extend(a^b for a,b in zip(rk[(i-4)*4:(i-3)*4], t))
        s = list(pt)
        for i in range(16): s[i] ^= rk[i]
        for r in range(1, 10):
            for i in range(16): s[i] = _SBOX[s[i]]
            s[1],s[5],s[9],s[13] = s[5],s[9],s[13],s[1]
            s[2],s[6],s[10],s[14] = s[10],s[14],s[2],s[6]
            s[3],s[7],s[11],s[15] = s[15],s[3],s[7],s[11]
            for c in range(4):
                a0,a1,a2,a3 = s[c*4],s[c*4+1],s[c*4+2],s[c*4+3]
                t = a0^a1^a2^a3
                s[c*4]   ^= t ^ _xtime(a0^a1)
                s[c*4+1] ^= t ^ _xtime(a1^a2)
                s[c*4+2] ^= t ^ _xtime(a2^a3)
                s[c*4+3] ^= t ^ _xtime(a3^a0)
            for i in range(16): s[i] ^= rk[r*16+i]
        for i in range(16): s[i] = _SBOX[s[i]]
        s[1],s[5],s[9],s[13] = s[5],s[9],s[13],s[1]
        s[2],s[6],s[10],s[14] = s[10],s[14],s[2],s[6]
        s[3],s[7],s[11],s[15] = s[15],s[3],s[7],s[11]
        for i in range(16): s[i] ^= rk[160+i]
        return bytes(s)

    def _dbl(b):
        r = bytearray(16)
        carry = 0
        for i in range(15, -1, -1):
            r[i] = ((b[i] << 1) | carry) & 0xff
            carry = (b[i] >> 7) & 1
        if b[0] & 0x80: r[15] ^= 0x87
        return bytes(r)

    def aes_cmac(key, msg):
        L = _aes128_block(key, b'\x00'*16)
        K1, K2 = _dbl(L), _dbl(_dbl(L))
        n = max(1, (len(msg) + 15) // 16)
        if len(msg) % 16 == 0 and len(msg) > 0:
            last = bytes(a^b for a,b in zip(K1, msg[(n-1)*16:]))
        else:
            pad = msg[(n-1)*16:] + b'\x80' + b'\x00'*(15 - len(msg[(n-1)*16:]))
            last = bytes(a^b for a,b in zip(K2, pad))
        x = b'\x00'*16
        for i in range(n-1):
            block = msg[i*16:(i+1)*16]
            x = _aes128_block(key, bytes(a^b for a,b in zip(x, block)))
        return _aes128_block(key, bytes(a^b for a,b in zip(x, last)))


def compute_mic(signing_key, data):
    """AES-128-CMAC → first 4 bytes."""
    if HAS_PYCRYPTODOME:
        m = _CMAC.new(signing_key, ciphermod=_AES)
        m.update(data)
        return m.digest()[:4]
    return aes_cmac(signing_key, data)[:4]


# ═══════════════════════════════════════════════════════════════════
#  Mesh Frame Encoding / Decoding
# ═══════════════════════════════════════════════════════════════════

class UplinkMeta:
    """5-byte uplink metadata in mesh frame."""
    __slots__ = ('uplink_id', 'dr', 'rssi', 'snr', 'channel')

    def __init__(self, uplink_id=0, dr=3, rssi=-100, snr=0, channel=0):
        self.uplink_id = uplink_id & 0xFFF
        self.dr = dr & 0x0F
        self.rssi = rssi
        self.snr = snr
        self.channel = channel & 0xFF

    def encode(self):
        uid = self.uplink_id << 4
        snr_enc = (self.snr + 64) if self.snr < 0 else self.snr
        return bytes([
            (uid >> 8) & 0xFF,
            (uid & 0xF0) | (uid & 0x0F) | self.dr,
            (-self.rssi) & 0xFF,
            snr_enc & 0x3F,
            self.channel,
        ])

    @classmethod
    def decode(cls, b):
        uid = ((b[0] << 8) | b[1]) >> 4
        dr = b[1] & 0x0F
        rssi = -(b[2] & 0xFF)
        sr = b[3] & 0x3F
        snr = sr - 64 if sr >= 32 else sr
        return cls(uid, dr, rssi, snr, b[4])


def is_mesh_frame(phy):
    """Check if PHYPayload is MType=111 (Proprietary)."""
    return len(phy) > 0 and (phy[0] >> 5) == MTYPE_PROP


def build_mesh_uplink(signing_key, relay_id, phy_payload, uplink_id, dr, rssi, snr, channel):
    """Build a complete mesh uplink frame: MHDR + Meta(5) + relay_id(4) + phy + MIC(4)."""
    mhdr_byte = (MTYPE_PROP << 5) | (PT_UPLINK << 3) | 0  # hop_count=1 → stored as 0
    meta = UplinkMeta(uplink_id, dr, rssi, snr, channel)
    frame = bytes([mhdr_byte]) + meta.encode() + relay_id + phy_payload
    mic = compute_mic(signing_key, frame)
    return frame + mic


def decode_mesh_uplink(signing_key, phy):
    """Decode mesh uplink. Returns (meta, relay_id, original_phy) or None."""
    if len(phy) < 14:  # MHDR(1) + meta(5) + relay(4) + phy(1+) + MIC(4) minimum
        return None
    frame_no_mic = phy[:-4]
    expected_mic = compute_mic(signing_key, frame_no_mic)
    if phy[-4:] != expected_mic:
        return None
    meta = UplinkMeta.decode(phy[1:6])
    relay_id = phy[6:10]
    original_phy = phy[10:-4]
    hop_count = (phy[0] & 0x07) + 1
    return meta, relay_id, original_phy, hop_count


# ═══════════════════════════════════════════════════════════════════
#  Semtech UDP Helpers
# ═══════════════════════════════════════════════════════════════════

def parse_udp(data):
    """Returns (ver, token, pkt_id, gw_mac, payload) or None."""
    if len(data) < 4:
        return None
    ver = data[0]; token = struct.unpack('!H', data[1:3])[0]; pkt_id = data[3]
    gw_mac = b''
    payload = data[4:]
    if pkt_id in (PUSH_DATA, PULL_DATA) and len(data) >= 12:
        gw_mac = data[4:12]
        payload = data[12:]
    return ver, token, pkt_id, gw_mac, payload


# ═══════════════════════════════════════════════════════════════════
#  Mesh Forwarder (UDP Proxy)
# ═══════════════════════════════════════════════════════════════════

class MeshForwarder:
    def __init__(self, args):
        self.role = args.role
        self.signing_key = bytes.fromhex(args.signing_key)
        self.listen_port = args.listen_port
        self.server_host = args.server_host
        self.server_port = args.server_port
        self.mesh_freqs = [int(f) for f in args.mesh_freqs.split(',')]
        self.mesh_sf = args.mesh_sf
        self.mesh_bw = args.mesh_bw
        self.tx_power = args.tx_power
        self.max_hop = args.max_hop

        # State
        self.freq_idx = 0
        self.uplink_ctr = 0
        self.dedup = deque(maxlen=DEDUP_SIZE)
        self.last_pull_token = 0
        self.last_pull_addr = None
        self.gw_id = None      # auto-learn from pkt_fwd
        self.relay_id = None   # derived from gw_id
        self.running = True

        # Stats
        self.s = {'rx': 0, 'sensor': 0, 'mesh_in': 0, 'mesh_tx': 0,
                  'unwrap': 0, 'fwd': 0, 'dedup': 0, 'drop': 0}

        # Sockets
        self.lsock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.lsock.bind(('0.0.0.0', self.listen_port))
        self.lsock.settimeout(1.0)

        self.fsock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

        log.info("=" * 50)
        log.info("Mesh Forwarder (native pkt_fwd edition)")
        log.info("Role: %s", self.role)
        log.info("Listen: 0.0.0.0:%d  →  Server: %s:%d",
                 self.listen_port, self.server_host, self.server_port)
        log.info("Mesh: SF%dBW%d @ %d dBm, freqs=%s MHz",
                 self.mesh_sf, self.mesh_bw//1000, self.tx_power,
                 [f/1e6 for f in self.mesh_freqs])
        log.info("Signing key: %s...", args.signing_key[:8])
        log.info("=" * 50)

    def run(self):
        last_stats = time.time()
        while self.running:
            try:
                data, addr = self.lsock.recvfrom(4096)
                p = parse_udp(data)
                if not p:
                    continue
                ver, token, pkt_id, gw_mac, payload = p

                if pkt_id == PUSH_DATA:
                    self._on_push_data(data, addr, token, gw_mac, payload)
                elif pkt_id == PULL_DATA:
                    self._on_pull_data(data, addr, token, gw_mac)
                elif pkt_id == TX_ACK:
                    pass

            except socket.timeout:
                pass
            except Exception as e:
                log.error("Loop error: %s", e)

            now = time.time()
            if now - last_stats >= 60:
                s = self.s
                log.info("Stats: rx=%d sensor=%d mesh_in=%d tx=%d unwrap=%d fwd=%d dedup=%d",
                         s['rx'], s['sensor'], s['mesh_in'], s['mesh_tx'],
                         s['unwrap'], s['fwd'], s['dedup'])
                last_stats = now

    # ── PUSH_DATA (uplinks from pkt_fwd) ─────────────────────────

    def _on_push_data(self, raw, addr, token, gw_mac, payload):
        # ACK immediately
        self.lsock.sendto(struct.pack('!BHB', PROTO, token, PUSH_ACK), addr)

        # Auto-learn gateway ID
        if self.gw_id is None and len(gw_mac) == 8:
            self.gw_id = gw_mac
            self.relay_id = gw_mac[4:8]
            log.info("Gateway ID: %s  Relay ID: %s",
                     gw_mac.hex().upper(), self.relay_id.hex())

        try:
            msg = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return

        rxpk_list = msg.get('rxpk', [])
        self.s['rx'] += len(rxpk_list)

        mesh_frames = []
        sensor_frames = []

        for rx in rxpk_list:
            if rx.get('stat') != 1:
                continue
            phy = base64.b64decode(rx.get('data', ''))
            if not phy:
                continue
            if is_mesh_frame(phy):
                mesh_frames.append((rx, phy))
            else:
                sensor_frames.append((rx, phy))

        # ── Handle mesh frames ──
        for rx, phy in mesh_frames:
            self.s['mesh_in'] += 1
            self._on_mesh_rx(phy, rx)

        # ── Relay: wrap sensors → mesh TX + forward originals ──
        if self.role == 'relay' and sensor_frames:
            for rx, phy in sensor_frames:
                self.s['sensor'] += 1
                self._relay_wrap_and_tx(phy, rx)
            self._forward_sensors([rx for rx, _ in sensor_frames])

        # ── Border: forward sensors to NS ──
        if self.role == 'border' and sensor_frames:
            self.s['sensor'] += len(sensor_frames)
            self._forward_sensors([rx for rx, _ in sensor_frames])

        # Forward stat-only packets
        if not rxpk_list and 'stat' in msg:
            self.fsock.sendto(raw, (self.server_host, self.server_port))

    # ── PULL_DATA (keepalive from pkt_fwd) ───────────────────────

    def _on_pull_data(self, raw, addr, token, gw_mac):
        # Store for PULL_RESP
        self.last_pull_token = token
        self.last_pull_addr = addr
        # PULL_ACK to pkt_fwd
        self.lsock.sendto(struct.pack('!BHB', PROTO, token, PULL_ACK), addr)
        # Forward to real server
        self.fsock.sendto(raw, (self.server_host, self.server_port))

    # ── Relay: wrap sensor → mesh TX ─────────────────────────────

    def _relay_wrap_and_tx(self, phy, rxpk):
        if self.last_pull_addr is None:
            return

        self.uplink_ctr = (self.uplink_ctr + 1) & 0xFFF

        datr = rxpk.get('datr', 'SF7BW125')
        dr = DATR_TO_DR.get(datr, 3)
        freq = rxpk.get('freq', 0)
        channel = int(freq * 10) & 0xFF

        mesh_frame = build_mesh_uplink(
            self.signing_key, self.relay_id, phy,
            uplink_id=self.uplink_ctr, dr=dr,
            rssi=int(rxpk.get('rssi', -100)),
            snr=int(rxpk.get('lsnr', 0)),
            channel=channel,
        )

        self._tx_pull_resp(mesh_frame)
        log.info("TX mesh: uid=%d relay=%s freq=%.1f size=%dB",
                 self.uplink_ctr, self.relay_id.hex(),
                 self.mesh_freqs[(self.freq_idx - 1) % len(self.mesh_freqs)] / 1e6,
                 len(mesh_frame))

    def _tx_pull_resp(self, mesh_frame):
        """Send mesh frame to pkt_fwd via PULL_RESP."""
        if self.last_pull_addr is None:
            return

        freq_hz = self.mesh_freqs[self.freq_idx]
        self.freq_idx = (self.freq_idx + 1) % len(self.mesh_freqs)

        txpk = {
            "txpk": {
                "imme": True,
                "freq": round(freq_hz / 1e6, 6),
                "rfch": 0,
                "powe": self.tx_power,
                "modu": "LORA",
                "datr": f"SF{self.mesh_sf}BW{self.mesh_bw // 1000}",
                "codr": "4/5",
                "ipol": False,
                "size": len(mesh_frame),
                "data": base64.b64encode(mesh_frame).decode(),
            }
        }

        token = (self.last_pull_token + 1) & 0xFFFF
        pkt = struct.pack('!BHB', PROTO, token, PULL_RESP) + json.dumps(txpk).encode()
        self.lsock.sendto(pkt, self.last_pull_addr)
        self.s['mesh_tx'] += 1

    # ── Border: unwrap mesh → forward original ───────────────────

    def _on_mesh_rx(self, phy, rxpk):
        result = decode_mesh_uplink(self.signing_key, phy)
        if result is None:
            self.s['drop'] += 1
            return

        meta, relay_id, original_phy, hop_count = result

        # Self-loop
        if self.relay_id and relay_id == self.relay_id:
            return

        # Dedup
        key = (meta.uplink_id, relay_id.hex())
        if key in self.dedup:
            self.s['dedup'] += 1
            return
        self.dedup.append(key)

        if self.role == 'border':
            self.s['unwrap'] += 1
            # Reconstruct rxpk with original PHYPayload
            new_rx = {
                "time": rxpk.get('time', ''),
                "tmst": rxpk.get('tmst', 0),
                "chan": meta.channel,
                "rfch": 0,
                "freq": rxpk.get('freq', 0),
                "stat": 1,
                "modu": "LORA",
                "datr": DR_TO_DATR.get(meta.dr, 'SF7BW125'),
                "codr": "4/5",
                "rssi": meta.rssi,
                "lsnr": float(meta.snr),
                "size": len(original_phy),
                "data": base64.b64encode(original_phy).decode(),
            }
            log.info("UNWRAP: relay=%s uid=%d hop=%d dr=%d rssi=%d snr=%d size=%dB",
                     relay_id.hex(), meta.uplink_id, hop_count,
                     meta.dr, meta.rssi, meta.snr, len(original_phy))
            self._forward_sensors([new_rx])
            self.s['fwd'] += 1

        elif self.role == 'relay':
            # Re-relay with incremented hop count
            if hop_count >= self.max_hop:
                return
            new_mhdr = (MTYPE_PROP << 5) | (PT_UPLINK << 3) | hop_count  # hop_count stored as N-1, so hop_count is already (old_hop - 1 + 1) = old_hop
            new_frame = bytes([new_mhdr]) + phy[1:-4]
            new_mic = compute_mic(self.signing_key, new_frame)
            self._tx_pull_resp(new_frame + new_mic)

    # ── Forward to real server ───────────────────────────────────

    def _forward_sensors(self, rxpk_list):
        gw = self.gw_id or b'\x00' * 8
        body = json.dumps({
            "rxpk": rxpk_list,
            "stat": {"time": time.strftime("%Y-%m-%d %H:%M:%S GMT", time.gmtime())}
        }).encode()
        token = int(time.time() * 1000) & 0xFFFF
        pkt = struct.pack('!BHB', PROTO, token, PUSH_DATA) + gw + body
        try:
            self.fsock.sendto(pkt, (self.server_host, self.server_port))
        except Exception as e:
            log.error("Forward error: %s", e)


# ═══════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════

def detect_gw_eui():
    """Try to read gateway EUI from common locations."""
    # Try file
    for path in ['/opt/chirpstack/gateway_eui.txt', '/tmp/gateway_eui.txt']:
        try:
            eui = open(path).read().strip()
            if len(eui) == 16:
                return eui
        except Exception:
            pass
    # Try MAC → EUI-64
    try:
        mac = open('/sys/class/net/eth0/address').read().strip().replace(':', '')
        return (mac[:6] + 'fffe' + mac[6:]).upper()
    except Exception:
        pass
    return None


def main():
    ap = argparse.ArgumentParser(description='LoRa Mesh Forwarder (native pkt_fwd)')
    ap.add_argument('--role', choices=['relay', 'border'], required=True)
    ap.add_argument('--signing-key', default='00112233445566778899aabbccddeeff')
    ap.add_argument('--listen-port', type=int, default=1701,
                    help='UDP port for pkt_fwd (default: 1701)')
    ap.add_argument('--server-host', default='127.0.0.1',
                    help='Gateway bridge host (default: 127.0.0.1)')
    ap.add_argument('--server-port', type=int, default=1700,
                    help='Gateway bridge port (default: 1700)')
    ap.add_argument('--mesh-freqs', default='902300000,902500000,902700000')
    ap.add_argument('--mesh-sf', type=int, default=7)
    ap.add_argument('--mesh-bw', type=int, default=125000)
    ap.add_argument('--tx-power', type=int, default=27)
    ap.add_argument('--max-hop', type=int, default=1)
    args = ap.parse_args()

    eui = detect_gw_eui()
    if eui:
        log.info("Detected Gateway EUI: %s", eui)

    fwd = MeshForwarder(args)

    signal.signal(signal.SIGTERM, lambda *_: setattr(fwd, 'running', False))
    signal.signal(signal.SIGINT, lambda *_: setattr(fwd, 'running', False))

    fwd.run()
    log.info("Stopped.")


if __name__ == '__main__':
    main()
