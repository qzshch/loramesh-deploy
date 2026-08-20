#!/usr/bin/env node
/**
 * LoRa Mesh Forwarder — native pkt_fwd edition (Node.js)
 *
 * UDP proxy: pkt_fwd ↔ gateway-bridge, with mesh (MType=111) wrapping/unwrapping.
 *   Relay:  sensor → wrap MType=111 → TX via PULL_RESP
 *           mesh downlink not addressed to us → hop+1 re-broadcast (multi-hop)
 *   Border: unwrap MType=111 → forward original PHYPayload
 */

'use strict';
const dgram = require('dgram');
const crypto = require('crypto');
const fs = require('fs');

// ── Config (JSON file → CLI args → defaults) ───────────────────────
const CONFIG_PATH = '/opt/chirpstack/mesh_config.json';
const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.indexOf('--' + name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
}

// Load persistent config
let fileCfg = {};
try { fileCfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch {}

function cfg(name, fallback) {
  // Priority: CLI arg > file config > fallback
  const cliVal = arg(name, null);
  if (cliVal !== null) return cliVal;
  // Map CLI names to file config keys
  const fileKey = name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
  if (fileCfg[name] !== undefined) return String(fileCfg[name]);
  if (fileCfg[fileKey] !== undefined) return String(fileCfg[fileKey]);
  return fallback;
}

const ROLE = cfg('role', 'relay');
const SIGNING_KEY = Buffer.from(cfg('signing-key', '00112233445566778899aabbccddeeff'), 'hex');
const LISTEN_PORT = parseInt(cfg('listen-port', '1700'));
// NS backend target. With backend='mqtt', the forwarder publishes ChirpStack v4
// gateway events directly to the broker and SERVER_HOST/SERVER_PORT (UDP LGB) are
// not used. With backend='udp' (default) the Semtech UDP PUSH_DATA path is used.
const BACKEND = cfg('backend', 'udp');
const SERVER_HOST = cfg('server-host', '127.0.0.1');
const SERVER_PORT = parseInt(cfg('server-port', '1710'));
const MESH_FREQS = cfg('mesh-freqs', '903900000,904100000,904300000').split(',').map(Number);
const MESH_SF = parseInt(cfg('mesh-sf', '7'));
const MESH_BW = parseInt(cfg('mesh-bw', '125000'));
const TX_POWER = parseInt(cfg('tx-power', '27'));
// Web UI saves this as "max-hop-count"; accept both spellings so the UI setting
// actually takes effect (previously only 'max-hop' was read → always 1 hop).
const MAX_HOP = parseInt(cfg('max-hop-count', cfg('max-hop', '1')));
// Multi-hop downlink timing compensation: the border derives the mesh-DL delay
// from ITS OWN receive tmst of the mesh uplink, which is later than the
// first-hop relay's receive tmst by the mesh multi-hop forwarding time.
// Add a per-hop estimate (ms) so the addressed relay still transmits inside the
// sensor's RX window. Semtech-UDP backend only; ChirpStack MQTT delay is
// relative to the uplink and needs no compensation.
const MESH_HOP_MS = parseInt(cfg('mesh-hop-ms', '200'));
// LoRaWAN JoinAccept RX1 delay (seconds). NS schedules the JoinAccept at
// uplink_tmst + JOIN_DELAY, so we use it to index pending JoinRequests.
const JOIN_DELAY = parseInt(cfg('join-delay', '5'));
// Border-only: drop direct (non-mesh) uplinks so all traffic rides the mesh.
// Web UI saves this as "border-ignore-direct" in mesh_config.json.
const IGNORE_DIRECT = cfg('border-ignore-direct', 'false') === 'true';

// ── Heartbeat (network topology management) ─────────────────────────
// Relay gateways emit an Event/heartbeat frame every HEARTBEAT_INTERVAL;
// relays that relay it append their own {relay_id, rssi, snr} to the
// relay_path; the border terminates it, caches topology and (optionally)
// reports a MeshEvent to the NS over MQTT. Accepts "60"/"5m"/"300s"/"1h".
function parseInterval(v, def) {
  const s = String(v || '').trim();
  if (!s) return def;
  const m = s.match(/^(\d+)\s*([smhd]?)$/i);
  if (!m) return def;
  const mult = { s: 1, m: 60, h: 3600, d: 86400 }[(m[2] || 's').toLowerCase()] || 1;
  return parseInt(m[1], 10) * mult;
}
const HEARTBEAT_INTERVAL = parseInterval(cfg('heartbeat-interval', '5m'), 300);
// Border → NS MeshEvent reporting (optional; requires mqtt in the image).
const MQTT_ENABLE = cfg('mqtt-enable', 'false') === 'true';
const MQTT_SERVER = cfg('mqtt-server', 'localhost:1883');
const MQTT_PREFIX = cfg('mqtt-prefix', '');
const MQTT_USERNAME = cfg('mqtt-username', '');
const MQTT_PASSWORD = cfg('mqtt-password', '');

// ── Semtech UDP ────────────────────────────────────────────────────
const PROTO = 2;
const PUSH_DATA = 0, PUSH_ACK = 1, PULL_DATA = 2, PULL_RESP = 3, PULL_ACK = 4, TX_ACK = 5;

// ── Region-agnostic DR <-> 4-bit mesh-metadata field ───────────────
// LoRaWAN DR numbers are region-specific (US915 DR0-3 up / DR8-13 down, EU868
// DR0-5, etc.), so a DR-index lookup table only ever works for one band.
// Instead encode the ACTUAL modulation into the 4-bit field so the same code
// works for every region:
//   bits[3:1] = SF index  (SF7=0 ... SF12=5)
//   bit[0]    = bandwidth (0 = 125 kHz, 1 = 500 kHz)
// Values 0-11 are all distinct and round-trip losslessly for SF7-SF12 x BW125/500.
function datrToDrField(datr) {
  const m = String(datr).match(/^SF(\d+)BW(\d+)/);
  if (!m) return null;
  const sfIdx = parseInt(m[1], 10) - 7;             // SF7..SF12 -> 0..5
  if (sfIdx < 0 || sfIdx > 7) return null;
  const bwBit = parseInt(m[2], 10) >= 500 ? 1 : 0;  // 125->0, 500->1
  return ((sfIdx & 0x07) << 1) | bwBit;
}
function drFieldToDatr(drField) {
  const sf = ((drField >> 1) & 0x07) + 7;
  if (sf < 7 || sf > 12) return null;
  const bw = (drField & 1) ? 500 : 125;
  return `SF${sf}BW${bw}`;
}

// ── AES-128-CMAC (RFC 4493) ───────────────────────────────────────
function aes128Block(key, input) {
  const c = crypto.createCipheriv('aes-128-ecb', key, null);
  c.setAutoPadding(false);
  return Buffer.concat([c.update(input), c.final()]);
}

function dbl(buf) {
  const r = Buffer.alloc(16);
  let carry = 0;
  for (let i = 15; i >= 0; i--) {
    r[i] = ((buf[i] << 1) | carry) & 0xff;
    carry = (buf[i] >> 7) & 1;
  }
  if (buf[0] & 0x80) r[15] ^= 0x87;
  return r;
}

function aesCmac(key, msg) {
  const L = aes128Block(key, Buffer.alloc(16));
  const K1 = dbl(L), K2 = dbl(K1);
  const n = Math.max(1, Math.ceil(msg.length / 16));
  let last;
  if (msg.length > 0 && msg.length % 16 === 0) {
    last = Buffer.alloc(16);
    msg.copy(last, 0, (n-1)*16);
    for (let i = 0; i < 16; i++) last[i] ^= K1[i];
  } else {
    const padded = Buffer.alloc(16);
    const tail = msg.slice((n-1)*16);
    tail.copy(padded);
    padded[tail.length] = 0x80;
    for (let i = 0; i < 16; i++) padded[i] ^= K2[i];
    last = padded;
  }
  let x = Buffer.alloc(16);
  for (let i = 0; i < n - 1; i++) {
    const block = Buffer.alloc(16);
    msg.copy(block, 0, i*16, (i+1)*16);
    for (let j = 0; j < 16; j++) x[j] ^= block[j];
    x = aes128Block(key, x);
  }
  for (let j = 0; j < 16; j++) x[j] ^= last[j];
  return aes128Block(key, x);
}

function computeMic(key, data) {
  return aesCmac(key, data).slice(0, 4);
}

// ── Mesh Frame ─────────────────────────────────────────────────────
const MTYPE_PROP = 7; // MType bits = 111

function encodeUplinkMeta(uid, dr, rssi, snr, channel) {
  const uidShift = uid << 4;
  const snrEnc = snr < 0 ? (snr + 64) & 0x3F : snr & 0x3F;
  return Buffer.from([
    (uidShift >> 8) & 0xFF,
    (uidShift & 0xFF) | (dr & 0x0F),
    (-rssi) & 0xFF,
    snrEnc,
    channel & 0xFF,
  ]);
}

function decodeUplinkMeta(buf) {
  const uid = ((buf[0] << 8) | buf[1]) >> 4;
  const dr = buf[1] & 0x0F;
  const rssi = -(buf[2] & 0xFF);
  const sr = buf[3] & 0x3F;
  const snr = sr >= 32 ? sr - 64 : sr;
  const channel = buf[4];
  return { uid, dr, rssi, snr, channel };
}

function buildMeshUplink(signingKey, relayId, phyPayload, uid, dr, rssi, snr, channel) {
  const mhdr = (MTYPE_PROP << 5) | (0 << 3) | 0; // PT=UPLINK, hop=1 (stored as 0)
  const meta = encodeUplinkMeta(uid, dr, rssi, snr, channel);
  const frame = Buffer.concat([Buffer.from([mhdr]), meta, relayId, phyPayload]);
  const mic = computeMic(signingKey, frame);
  return Buffer.concat([frame, mic]);
}

function decodeMeshUplink(signingKey, phy) {
  if (phy.length < 14) return null; // MHDR(1)+meta(5)+relay(4)+phy(1)+MIC(4)
  const frameNoMic = phy.slice(0, -4);
  const expectedMic = computeMic(signingKey, frameNoMic);
  if (!phy.slice(-4).equals(expectedMic)) return null;
  const mhdr = phy[0];
  const hopCount = (mhdr & 0x07) + 1;
  const meta = decodeUplinkMeta(phy.slice(1, 6));
  const relayId = phy.slice(6, 10);
  const originalPhy = phy.slice(10, -4);
  return { meta, relayId, originalPhy, hopCount };
}

function isMeshFrame(phy) {
  return phy.length > 0 && (phy[0] >> 5) === MTYPE_PROP;
}

// ── Event / Heartbeat frames (network topology management) ──────────
// Payload layout follows chirpstack-gateway-mesh packets.rs:
//   MHDR | timestamp(4B BE s) | source_relay_id(4B) | events...
//   event = tag(1B, 0x00=heartbeat) + len(1B) + relay_path
//   RelayPath(6B each): relay_id(4B) | rssi(1B, stored +ve) | snr(1B, bits5-0 signed)
// Signed with AES-128-CMAC (same as uplink/downlink, no payload encryption).

function encodeHeartbeatFrame(signingKey, sourceRelayId, relayPath, hopCount) {
  const pathBuf = Buffer.alloc(relayPath.length * 6);
  relayPath.forEach((p, i) => {
    p.relayId.copy(pathBuf, i * 6);
    pathBuf[i * 6 + 4] = (-p.rssi) & 0xFF;
    const snrEnc = p.snr < 0 ? (p.snr + 64) : p.snr;
    pathBuf[i * 6 + 5] = (snrEnc & 0x3F);
  });
  const tsBuf = Buffer.alloc(4);
  tsBuf.writeUInt32BE(Math.floor(Date.now() / 1000) & 0xFFFFFFFF, 0);
  const eventBody = Buffer.concat([Buffer.from([0x00, pathBuf.length]), pathBuf]);
  const body = Buffer.concat([tsBuf, sourceRelayId, eventBody]);
  const mhdr = (MTYPE_PROP << 5) | (2 << 3) | ((hopCount - 1) & 0x07);
  const frame = Buffer.concat([Buffer.from([mhdr]), body]);
  return Buffer.concat([frame, computeMic(signingKey, frame)]);
}

function decodeHeartbeatFrame(phy) {
  // Returns { sourceRelayId, timestamp, path:[{relayId,rssi,snr}] } or null.
  if (phy.length < 13) return null; // MHDR + ts(4) + relay(4) + tag/len(2) + MIC(4)
  const sourceRelayId = phy.slice(5, 9);
  const timestamp = phy.readUInt32BE(1);
  const path = [];
  let pos = 9;
  while (pos + 2 <= phy.length - 4) {
    const tag = phy[pos];
    const len = phy[pos + 1];
    if (tag === 0x00) {
      for (let i = 0; i + 6 <= len; i += 6) {
        const o = pos + 2 + i;
        const snrRaw = phy[o + 5] & 0x3F;
        path.push({
          relayId: phy.slice(o, o + 4),
          rssi: -(phy[o + 4]),
          snr: snrRaw > 31 ? snrRaw - 64 : snrRaw,
        });
      }
    }
    pos += 2 + len;
  }
  return { sourceRelayId, timestamp, path };
}

// ── NS backend conversions (Semtech UDP rxpk ↔ ChirpStack gw protobuf-JSON) ──
function modToDatr(mod) {
  if (!mod || !mod.lora) return 'SF7BW125';
  const bw = mod.lora.bandwidth || 125000;
  const sf = mod.lora.spreadingFactor || 7;
  return `SF${sf}BW${bw / 1000}`;
}

function parseDelay(s) {
  const m = String(s).match(/([\d.]+)\s*([smh]?)/i);
  if (!m) return 1;
  const mult = { s: 1, m: 60, h: 3600 }[(m[2] || 's').toLowerCase()] || 1;
  return Math.max(1, Math.round(parseFloat(m[1]) * mult));
}

// rxpk (Semtech UDP) → ChirpStack gw.UplinkFrame (protobuf-JSON mapping).
// Byte fields (phyPayload, context) are base64; gatewayId is hex; JSON
// detection is "payload contains 'gatewayId'".
function rxpkToUplinkFrame(rxpk, gwId, uplinkId) {
  const m = /^SF(\d+)BW(\d+)/.exec(rxpk.datr || '');
  const sf = m ? parseInt(m[1], 10) : 7;
  const bw = m ? parseInt(m[2], 10) * 1000 : 125000;
  const cr = String(rxpk.codr || '4/5').replace('/', '_');
  const tmstBuf = Buffer.alloc(4);
  tmstBuf.writeUInt32BE((rxpk.tmst || 0) >>> 0, 0);
  return {
    phyPayload: rxpk.data,
    txInfo: {
      frequency: Math.round((rxpk.freq || 0) * 1e6),
      modulation: { lora: { bandwidth: bw, spreadingFactor: sf, codeRate: 'CR_' + cr } },
    },
    rxInfo: {
      gatewayId: gwId,
      uplinkId,
      time: rxpk.time || new Date().toISOString(),
      rssi: rxpk.rssi || 0,
      snr: rxpk.lsnr || 0,
      channel: rxpk.chan || 0,
      rfChain: rxpk.rfch || 0,
      board: 0,
      antenna: 0,
      context: tmstBuf.toString('base64'),
    },
  };
}

// ── LoRaWAN frame parsing (for downlink routing) ──────────────────
function isJoinRequest(phy) {
  return phy.length >= 23 && (phy[0] >> 5) === 0; // MType=000
}

function reverseBytes(buf) {
  const r = Buffer.alloc(buf.length);
  for (let i = 0; i < buf.length; i++) r[i] = buf[buf.length - 1 - i];
  return r;
}

function getDeviceKey(phy) {
  if (phy.length < 5) return null;
  const mtype = phy[0] >> 5;
  if (mtype === 0 && phy.length >= 23) {
    // JoinRequest: DevEUI at bytes 1-8 (LSB first)
    return 'jr:' + reverseBytes(phy.slice(1, 9)).toString('hex');
  }
  if ((mtype === 2 || mtype === 4) && phy.length >= 5) {
    // Unconfirmed/Confirmed Data Up: DevAddr at bytes 1-4 (LSB first)
    return 'da:' + reverseBytes(phy.slice(1, 5)).toString('hex');
  }
  return null;
}

// ── Downlink Metadata (6 bytes, matches gateway-mesh Rust) ─────────
// byte 0: uid[11:4]
// byte 1: uid[3:0] | dr[3:0]
// byte 2-4: freq / 100 (24-bit, 100Hz resolution)
// byte 5: power[7:4] | delay[3:0]
//   delay raw = 0      -> transmit IMMEDIATELY (Class-C / imme downlink)
//   delay raw = 1..15  -> transmit that many seconds after the uplink tmst
function encodeDownlinkMeta(uid, dr, freqHz, power, delaySec) {
  const uidClamped = uid & 0xFFF;
  const drClamped = dr & 0x0F;
  const freqEnc = Math.round(freqHz / 100) & 0xFFFFFF;
  const pwrClamped = Math.min(15, Math.max(0, power)) & 0x0F;
  const delayRaw = (!delaySec || delaySec <= 0) ? 0
                 : Math.min(15, Math.max(1, Math.round(delaySec))) & 0x0F;
  return Buffer.from([
    (uidClamped >> 4) & 0xFF,
    ((uidClamped & 0x0F) << 4) | drClamped,
    (freqEnc >> 16) & 0xFF,
    (freqEnc >> 8) & 0xFF,
    freqEnc & 0xFF,
    (pwrClamped << 4) | delayRaw,
  ]);
}

// ── Downlink Context Cache (border: device → relay mapping) ────────
class DlCtxCache {
  constructor(max = 256) { this.map = new Map(); this.max = max; }
  get(key) {
    if (!this.map.has(key)) return null;
    const v = this.map.get(key);
    // Move to end (LRU)
    this.map.delete(key);
    this.map.set(key, v);
    return v;
  }
  set(key, val) {
    if (this.map.has(key)) this.map.delete(key);
    this.map.set(key, val);
    if (this.map.size > this.max) {
      this.map.delete(this.map.keys().next().value);
    }
  }
}

// ── Dedup Cache ────────────────────────────────────────────────────
class DedupCache {
  constructor(size = 512) { this.set = new Set(); this.queue = []; this.max = size; }
  has(key) { return this.set.has(key); }
  add(key) {
    if (this.set.has(key)) return false;
    this.set.add(key); this.queue.push(key);
    if (this.queue.length > this.max) { this.set.delete(this.queue.shift()); }
    return true;
  }
}

// ── Mesh Forwarder ─────────────────────────────────────────────────
class MeshForwarder {
  constructor() {
    this.gwId = null;
    this.relayId = null;
    this.freqIdx = 0;
    this.ulCtr = 0;
    this.dedup = new DedupCache();
    this.lastPullToken = 0;
    this.lastPullAddr = null;
    this.stats = { rx: 0, sensor: 0, meshIn: 0, meshTx: 0, unwrap: 0, fwd: 0, dedup: 0, dlRx: 0, dlTx: 0, dlDirect: 0, dlRelay: 0, ignoredDirect: 0, hbTx: 0, hbRx: 0 };
    this.dlCtx = new DlCtxCache();
    this.uplinkTmst = new Map(); // relay: deviceKey → concentrator tmst
    this.lastRelay = null; // { relayId, uid, dr, tmst } — fallback for downlink routing
    this.lastJoinReq = null; // { relayId, uid, dr, tmst, wallMs } — last JoinRequest (for JoinAccept)
    this.joinReqs = []; // border: pending JoinRequests [{expTmst, relayId, uid, dr, wallMs}] for exact tmst match
    this.lastUplinkTmst = null; // relay: most recent uplink tmst (for RX window timing)
    this.ulTmstMap = new Map(); // relay: uplink_id → its concentrator tmst
    this.meshTopo = new Map(); // border: sourceRelayId(hex) → { path, lastSeen, hop }
    this.mqttClient = null; // border: NS MeshEvent reporter

    // Listen socket (receives from pkt_fwd)
    this.lsock = dgram.createSocket('udp4');
    // Forward socket (sends to gateway bridge)
    this.fsock = dgram.createSocket('udp4');
  }

  start() {
    this.lsock.on('message', (msg, rinfo) => this._onMessage(msg, rinfo));
    this.lsock.bind(LISTEN_PORT, () => {
      console.log(`[${new Date().toISOString()}] Mesh Forwarder (${ROLE})`);
      console.log(`  Listen: 0.0.0.0:${LISTEN_PORT}  →  Server: ${SERVER_HOST}:${SERVER_PORT}`);
      console.log(`  Mesh: SF${MESH_SF}BW${MESH_BW/1000} @ ${TX_POWER} dBm`);
      console.log(`  Freqs: ${MESH_FREQS.map(f => f/1e6)} MHz`);
      console.log(`  Downlinks: enabled`);
      console.log(`  Heartbeat: ${ROLE === 'relay' ? 'every ' + HEARTBEAT_INTERVAL + 's (TX)' : (HEARTBEAT_INTERVAL > 0 ? 'topology (RX)' : 'disabled')}`);
      if (MQTT_ENABLE) console.log(`  MQTT report: ${MQTT_SERVER}`);
    });

    // Listen for PULL_RESP from gateway bridge (downlinks)
    this.fsock.on('message', (msg) => this._onPullResp(msg));

    // Heartbeat: relay emits every interval; border initializes MQTT reporter.
    if (ROLE === 'relay' && HEARTBEAT_INTERVAL > 0) {
      setInterval(() => this._sendHeartbeat(), HEARTBEAT_INTERVAL * 1000);
    }
    if (ROLE === 'border' && (MQTT_ENABLE || BACKEND === 'mqtt')) this._initMqtt();

    // Stats every 60s
    setInterval(() => {
      const s = this.stats;
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      console.log(`[${ts}] Stats: rx=${s.rx} sensor=${s.sensor} mesh_in=${s.meshIn} tx=${s.meshTx} unwrap=${s.unwrap} fwd=${s.fwd} dedup=${s.dedup} dl_rx=${s.dlRx} dl_tx=${s.dlTx} dl_dir=${s.dlDirect} dl_rly=${s.dlRelay} ign=${s.ignoredDirect} hb_tx=${s.hbTx} hb_rx=${s.hbRx}`);
      // MQTT backend: report gateway stats so NS tracks gateway online state.
      if (BACKEND === 'mqtt' && ROLE === 'border' && this.mqttClient && this.mqttClient.connected) {
        const gwId = this.gwId ? this.gwId.toString('hex') : '';
        if (gwId) {
          const st = `${MQTT_PREFIX ? MQTT_PREFIX + '/' : ''}gateway/${gwId}/event/stats`;
          this.mqttClient.publish(st, JSON.stringify({
            gatewayId: gwId,
            time: new Date().toISOString(),
            rxPacketsReceived: s.rx,
            rxPacketsReceivedOk: s.rx,
            txPacketsReceived: s.dlRx,
            txPacketsEmitted: s.dlTx + s.meshTx,
          }));
        }
      }
    }, 60000);
  }

  _onMessage(msg, rinfo) {
    if (msg.length < 4) return;
    const ver = msg[0], token = msg.readUInt16BE(1), pktId = msg[3];

    if (pktId === PUSH_DATA) {
      const gwMac = msg.slice(4, 12);
      const payload = msg.slice(12);
      this._onPushData(rinfo, token, gwMac, payload);
      // ACK
      const ack = Buffer.alloc(4);
      ack[0] = PROTO; ack.writeUInt16BE(token, 1); ack[3] = PUSH_ACK;
      this.lsock.send(ack, rinfo.port, rinfo.address);
    } else if (pktId === PULL_DATA) {
      const gwMac = msg.slice(4, 12);
      this.lastPullToken = token;
      this.lastPullAddr = rinfo;
      console.log(`[${new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'')}] PULL_DATA from ${rinfo.address}:${rinfo.port} token=${token}`);
      // ACK
      const ack = Buffer.alloc(4);
      ack[0] = PROTO; ack.writeUInt16BE(token, 1); ack[3] = PULL_ACK;
      this.lsock.send(ack, rinfo.port, rinfo.address);
      // Only border forwards PULL_DATA to server (relay must NOT — it would
      // overwrite the border's address mapping in LGB, causing PULL_RESP to
      // be sent to the relay instead of the border)
      if (ROLE === 'border') {
        this.fsock.send(msg, SERVER_PORT, SERVER_HOST);
      }
      // Auto-learn gateway ID
      if (!this.gwId) {
        this.gwId = gwMac;
        this.relayId = gwMac.slice(4, 8);
        console.log(`Gateway ID: ${gwMac.toString('hex').toUpperCase()}  Relay ID: ${this.relayId.toString('hex')}`);
        // MQTT backend: subscribe NS downlink commands once gwId is known.
        if (BACKEND === 'mqtt' && this.mqttClient) {
          const sub = `${MQTT_PREFIX ? MQTT_PREFIX + '/' : ''}gateway/${gwMac.toString('hex')}/command/down`;
          this.mqttClient.subscribe(sub, { qos: 0 });
          console.log(`MQTT: subscribed ${sub}`);
        }
      }
    }
    // TX_ACK: ignore
  }

  _onPushData(rinfo, token, gwMac, payload) {
    let msg;
    try { msg = JSON.parse(payload.toString()); } catch { return; }

    const rxpkList = msg.rxpk || [];
    this.stats.rx += rxpkList.length;

    const meshFrames = [];
    const sensorFrames = [];

    for (const rx of rxpkList) {
      if (rx.stat !== 1) continue;
      const phy = Buffer.from(rx.data || '', 'base64');
      if (!phy.length) continue;
      if (isMeshFrame(phy)) meshFrames.push({ rx, phy });
      else sensorFrames.push({ rx, phy });
    }

    // Handle mesh frames
    for (const { rx, phy } of meshFrames) {
      this.stats.meshIn++;
      this._onMeshRx(phy, rx);
    }

    // Relay: wrap sensors → mesh TX only (do NOT forward to LGB — duplicates
    // arrive via border unwrap, and relay PUSH_DATA overwrites border's address
    // in LGB, causing PULL_RESP to be sent to relay instead of border)
    if (ROLE === 'relay' && sensorFrames.length) {
      for (const { rx, phy } of sensorFrames) {
        this.stats.sensor++;
        this._relayWrapAndTx(phy, rx);
      }
    }

    // Border: forward sensors to NS
    if (ROLE === 'border' && sensorFrames.length) {
      this.stats.sensor += sensorFrames.length;
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      if (IGNORE_DIRECT) {
        // border-ignore-direct=true: drop direct uplinks, only mesh rides through
        this.stats.ignoredDirect += sensorFrames.length;
        for (const { rx, phy } of sensorFrames) {
          let devAddr = 'unknown';
          if (phy.length >= 5) {
            const raw = phy.slice(1, 5).toString('hex');
            devAddr = raw[6]+raw[7]+raw[4]+raw[5]+raw[2]+raw[3]+raw[0]+raw[1];
          }
          console.log(`[${ts}] IGNO direct dev=${devAddr} freq=${rx.freq}MHz ${rx.datr} rssi=${rx.rssi} snr=${rx.lsnr} ${phy.length}B`);
        }
      } else {
        for (const { rx, phy } of sensorFrames) {
          let devAddr = 'unknown';
          if (phy.length >= 5) {
            const raw = phy.slice(1, 5).toString('hex');
            devAddr = raw[6]+raw[7]+raw[4]+raw[5]+raw[2]+raw[3]+raw[0]+raw[1];
          }
          console.log(`[${ts}] RX direct dev=${devAddr} freq=${rx.freq}MHz ${rx.datr} rssi=${rx.rssi} snr=${rx.lsnr} ${phy.length}B`);
        }
        this._forwardSensors(sensorFrames.map(s => s.rx));
      }
    }

    // Forward stat-only packets (no rxpk, just gateway stats)
    if (!rxpkList.length && msg.stat) {
      // Skip stat-only forwarding (bridge will get stats from mesh frames)
    }
  }

  _relayWrapAndTx(phy, rxpk) {
    if (!this.lastPullAddr || !this.relayId) return;

    // Cache uplink timestamp for downlink timing
    const devKey = getDeviceKey(phy);
    if (devKey && rxpk.tmst) {
      this.uplinkTmst.set(devKey, rxpk.tmst);
    }
    if (rxpk.tmst) {
      this.lastUplinkTmst = rxpk.tmst;
    }

    this.ulCtr = (this.ulCtr + 1) & 0xFFF;
    // Map uplink id → concentrator tmst (for precise RX window scheduling)
    if (rxpk.tmst) {
      this.ulTmstMap.set(this.ulCtr, rxpk.tmst);
    }
    // DIAGNOSTIC: trace JoinRequest uplink (start of the downlink timing chain)
    if (phy.length >= 23 && (phy[0] >> 5) === 0 && rxpk.tmst) {
      const jts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      console.log(`[${jts}] RELAY JoinReq RX uid=${this.ulCtr} tmst=${rxpk.tmst} freq=${rxpk.freq}MHz`);
    }
    const datr = rxpk.datr || 'SF7BW125';
    const drField0 = datrToDrField(datr);
    const dr = drField0 !== null ? drField0 : 0; // fallback SF7BW125
    const freq = rxpk.freq || 0;
    const channel = Math.floor(freq * 10) & 0xFF;

    // Extract DevAddr from PHYPayload (bytes 1-4 of MAC header)
    let devAddr = 'unknown';
    if (phy.length >= 5) {
      devAddr = phy.slice(1, 5).toString('hex');
      devAddr = devAddr[6]+devAddr[7]+devAddr[4]+devAddr[5]+devAddr[2]+devAddr[3]+devAddr[0]+devAddr[1];
    }

    const meshFrame = buildMeshUplink(
      SIGNING_KEY, this.relayId, phy,
      this.ulCtr, dr,
      parseInt(rxpk.rssi || -100),
      parseInt(rxpk.lsnr || 0),
      channel
    );

    this._txPullResp(meshFrame);
    const txFreq = MESH_FREQS[(this.freqIdx - 1 + MESH_FREQS.length) % MESH_FREQS.length];
    const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
    console.log(`[${ts}] TX mesh uid=${this.ulCtr} relay=${this.relayId.toString('hex')} dev=${devAddr} freq=${txFreq/1e6}MHz SF${MESH_SF} ${meshFrame.length}B rssi=${rxpk.rssi} snr=${rxpk.lsnr}`);
  }

  _txPullResp(meshFrame) {
    if (!this.lastPullAddr) return;

    const freqHz = MESH_FREQS[this.freqIdx];
    this.freqIdx = (this.freqIdx + 1) % MESH_FREQS.length;

    const txpk = {
      txpk: {
        imme: true,
        freq: Math.round(freqHz / 1e6 * 1e6) / 1e6,
        rfch: 0,
        powe: TX_POWER,
        modu: 'LORA',
        datr: `SF${MESH_SF}BW${MESH_BW / 1000}`,
        codr: '4/5',
        ipol: false,
        size: meshFrame.length,
        data: meshFrame.toString('base64'),
      }
    };

    const token = (this.lastPullToken + 1) & 0xFFFF;
    const header = Buffer.alloc(4);
    header[0] = PROTO; header.writeUInt16BE(token, 1); header[3] = PULL_RESP;
    const pkt = Buffer.concat([header, Buffer.from(JSON.stringify(txpk))]);
    this.lsock.send(pkt, this.lastPullAddr.port, this.lastPullAddr.address);
    this.stats.meshTx++;
  }

  _onMeshRx(phy, rxpk) {
    // Check payload type: uplink (0), downlink (1) or event/heartbeat (2)
    const mhdr = phy[0];
    const payloadType = (mhdr >> 3) & 0x03;

    // ── Event handling (heartbeat, topology management) ──
    if (payloadType === 2) {
      this._onMeshEvent(phy, rxpk);
      return;
    }

    // ── Downlink handling (relay only, multi-hop) ──
    if (payloadType === 1) {
      if (ROLE !== 'relay') return;
      if (phy.length < 15) return; // MHDR(1)+meta(6)+relay(4)+phy(1)+MIC(4)
      const frameNoMic = phy.slice(0, -4);
      const expectedMic = computeMic(SIGNING_KEY, frameNoMic);
      if (!phy.slice(-4).equals(expectedMic)) return; // bad MIC
      const relayId = phy.slice(7, 11);
      const hopCount = (mhdr & 0x07) + 1;
      const meta = phy.slice(1, 7);
      const dlUid = ((meta[0] << 8) | meta[1]) >> 4;
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');

      // Multi-hop: mesh downlink frames are broadcast on the mesh channel, so
      // dedup the (relayId, uplink uid) pair — each relay handles a frame exactly
      // once, which also cuts broadcast loops. 'dl:' prefix keeps this out of the
      // uplink dedup key space (same uid+relayId appears once per uplink AND once
      // per downlink; a shared cache would drop the second).
      const dlKey = `dl:${relayId.toString('hex')}:${dlUid}`;
      if (!this.dedup.add(dlKey)) return;

      // Not addressed to us → relay onward (hop+1, re-signed) up to MAX_HOP.
      if (!this.relayId || !relayId.equals(this.relayId)) {
        if (hopCount >= MAX_HOP) {
          console.log(`[${ts}] DL DROP relay=${relayId.toString('hex')} uid=${dlUid} hop=${hopCount} >= max=${MAX_HOP}`);
          return;
        }
        const newMhdr = (MTYPE_PROP << 5) | (1 << 3) | hopCount; // hop stored as N-1
        const newFrame = Buffer.concat([Buffer.from([newMhdr]), phy.slice(1, -4)]);
        const newMic = computeMic(SIGNING_KEY, newFrame);
        this._txPullResp(Buffer.concat([newFrame, newMic]));
        this.stats.dlRelay++;
        console.log(`[${ts}] DL RELAY relay=${relayId.toString('hex')} uid=${dlUid} hop=${hopCount}->${hopCount+1} ${phy.length}B -> mesh`);
        return;
      }

      const originalPhy = phy.slice(11, -4);

      // Extract DownlinkMetadata: uid(12bit)+dr(4bit) | freq/100(24bit) | power(4bit)+delay(4bit)
      const dr = meta[1] & 0x0F;
      const dlFreq = (meta[2] << 16 | meta[3] << 8 | meta[4]) * 100;
      const dlPower = meta[5] >> 4;
      // delayRaw: 0 = immediate (Class-C / NS imme=true), 1..15 = seconds
      const delayRaw = meta[5] & 0x0F;
      // Region-agnostic: the 4-bit field carries SF+BW directly
      const dlDatr = drFieldToDatr(dr) || 'SF7BW125';

      // Use the uplink tmst for THIS uid (the uplink that triggered this
      // downlink), not the most recent uplink — fallback to lastUplinkTmst
      const tmstHit = this.ulTmstMap.has(dlUid);
      let uplinkTmst = this.ulTmstMap.get(dlUid) || this.lastUplinkTmst || 0;

      // DIAGNOSTIC: recvTmst = relay concentrator time when THIS mesh downlink
      // arrived. leadTime = scheduled TX time − recvTmst. If leadTime < 0 the
      // TX timestamp is already in the past and pkt_fwd will reject it (too late).
      const recvTmst = rxpk.tmst || 0;

      let tmst = 0;
      let imme = false;
      if (delayRaw === 0) {
        // NS said "immediate" (Class C): transmit now, following the NS instruction.
        imme = true;
        console.log(`[${ts}] MESH DL uid=${dlUid} IMMEDIATE ${originalPhy.length}B freq=${dlFreq/1e6}MHz ${dlDatr} pwr=${dlPower} | recvTmst=${recvTmst} → pkt_fwd`);
      } else if (uplinkTmst) {
        // NS provided a tmst → schedule at uplinkTmst + delay (RX window).
        tmst = ((uplinkTmst + delayRaw * 1e6) >>> 0); // >>> 0 = unsigned 32-bit
        // signed lead time accounting for 32-bit counter wrap
        let lead = tmst - recvTmst;
        if (lead > 0x80000000) lead -= 0x100000000;
        if (lead < -0x80000000) lead += 0x100000000;
        console.log(`[${ts}] MESH DL uid=${dlUid} ${originalPhy.length}B freq=${dlFreq/1e6}MHz ${dlDatr} pwr=${dlPower} delay=${delayRaw}s | uplinkTmst=${uplinkTmst}(${tmstHit?'HIT':'MISS'}) recvTmst=${recvTmst} txTmst=${tmst} lead=${lead}us (${(lead/1e6).toFixed(2)}s) → pkt_fwd`);
      } else {
        console.log(`[${ts}] MESH DL uid=${dlUid} ${originalPhy.length}B (no uplinkTmst, immediate) recvTmst=${recvTmst} → pkt_fwd`);
        imme = true;
      }
      const dlFreqMHz = dlFreq ? dlFreq / 1e6 : rxpk.freq;
      this._sendDirectDownlink(originalPhy, dlFreqMHz, dlDatr, dlPower, tmst, imme);
      this.stats.dlTx++;
      return;
    }

    // ── Uplink handling ──
    const result = decodeMeshUplink(SIGNING_KEY, phy);
    if (!result) {
      // Distinguish BAD MIC (signing-key mismatch) from malformed/short frame
      // so key-function tests are visible in the log, not hidden in dedup count.
      const badMic = phy.length >= 14 && !computeMic(SIGNING_KEY, phy.slice(0, -4)).equals(phy.slice(-4));
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      console.log(`[${ts}] BAD MESH ${badMic ? 'MIC(key?)' : 'short'} ${phy.length}B freq=${rxpk.freq}MHz`);
      this.stats.dedup++;
      return;
    }

    const { meta, relayId, originalPhy, hopCount } = result;

    // Self-loop
    if (this.relayId && relayId.equals(this.relayId)) return;

    // Dedup
    const key = `${meta.uid}:${relayId.toString('hex')}`;
    if (!this.dedup.add(key)) { this.stats.dedup++; return; }

    if (ROLE === 'border') {
      this.stats.unwrap++;
      const newRx = {
        time: rxpk.time || '',
        tmst: rxpk.tmst || 0,
        chan: meta.channel,
        rfch: 0,
        freq: rxpk.freq || 0,
        stat: 1,
        modu: 'LORA',
        datr: drFieldToDatr(meta.dr) || 'SF7BW125',
        codr: '4/5',
        rssi: meta.rssi,
        lsnr: meta.snr,
        size: originalPhy.length,
        data: originalPhy.toString('base64'),
      };
      // Cache relay mapping for downlink routing
      const devKey = getDeviceKey(originalPhy);
      if (devKey) {
        this.dlCtx.set(devKey, {
          relayId: Buffer.from(relayId),
          uid: meta.uid,
          dr: meta.dr,
          tmst: rxpk.tmst || 0,
          hop: hopCount, // mesh hops the uplink travelled → downlink timing compensation
        });
      }
      // Always update lastRelay (fallback for JoinAccept where DevAddr key ≠ JoinRequest DevEUI key)
      this.lastRelay = {
        relayId: Buffer.from(relayId),
        uid: meta.uid,
        dr: meta.dr,
        tmst: rxpk.tmst || 0,
        hop: hopCount,
      };
      // Track JoinRequests separately so a later JoinAccept can derive the RX
      // delay from the NS downlink tmst instead of hardcoding it.
      // JoinRequest = MType 000 (phyPayload[0]>>5 == 0), len >= 23.
      if (originalPhy.length >= 23 && (originalPhy[0] >> 5) === 0) {
        const jrTmst = rxpk.tmst || 0;
        this.lastJoinReq = {
          relayId: Buffer.from(relayId),
          uid: meta.uid,
          dr: meta.dr,
          tmst: jrTmst,
          wallMs: Date.now(),
          hop: hopCount,
        };
        // Index by the downlink tmst the NS will use for this JoinRequest's
        // JoinAccept: NS sends JoinAccept with tmst = uplink_tmst + JOIN_DELAY.
        // Multiple sensors may join concurrently, so key on the unique tmst
        // (not "last JoinRequest") to match the right one later.
        const expTmst = ((jrTmst + JOIN_DELAY * 1e6) >>> 0);
        this.joinReqs.push({ expTmst, tmst: jrTmst, relayId: Buffer.from(relayId), uid: meta.uid, dr: meta.dr, wallMs: Date.now(), hop: hopCount });
        // Prune entries older than 60s
        const cutoff = Date.now() - 60000;
        this.joinReqs = this.joinReqs.filter(j => j.wallMs > cutoff);
      }
      // Extract DevAddr from original PHYPayload
      let devAddr = 'unknown';
      if (originalPhy.length >= 5) {
        const raw = originalPhy.slice(1, 5).toString('hex');
        devAddr = raw[6]+raw[7]+raw[4]+raw[5]+raw[2]+raw[3]+raw[0]+raw[1];
      }
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      console.log(`[${ts}] UNWRAP relay=${relayId.toString('hex')} uid=${meta.uid} dev=${devAddr} hop=${hopCount} ${drFieldToDatr(meta.dr)||'?'} freq=${rxpk.freq}MHz rssi=${meta.rssi} snr=${meta.snr} ${originalPhy.length}B → bridge`);
      this._forwardSensors([newRx]);
      this.stats.fwd++;
    } else if (ROLE === 'relay') {
      if (hopCount >= MAX_HOP) return;
      // Re-relay with incremented hop
      const newMhdr = (MTYPE_PROP << 5) | (0 << 3) | hopCount; // hop stored as N-1
      const newFrame = Buffer.concat([Buffer.from([newMhdr]), phy.slice(1, -4)]);
      const newMic = computeMic(SIGNING_KEY, newFrame);
      this._txPullResp(Buffer.concat([newFrame, newMic]));
    }
  }

  // ── Heartbeat / Event handling ────────────────────────────────────
  _sendHeartbeat() {
    if (!this.relayId || !this.lastPullAddr) return;
    const frame = encodeHeartbeatFrame(SIGNING_KEY, this.relayId, [], 1);
    this._txPullResp(frame);
    this.stats.hbTx++;
    const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
    console.log(`[${ts}] HB TX relay=${this.relayId.toString('hex')} path=[]`);
  }

  _onMeshEvent(phy, rxpk) {
    if (phy.length < 13) return;
    const frameNoMic = phy.slice(0, -4);
    if (!phy.slice(-4).equals(computeMic(SIGNING_KEY, frameNoMic))) return; // bad MIC
    const hb = decodeHeartbeatFrame(phy);
    if (!hb) return;
    const mhdr = phy[0];
    const hopCount = (mhdr & 0x07) + 1;
    const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
    const fmtPath = p => p.map(x => `${x.relayId.toString('hex')}(${x.rssi},${x.snr})`).join('→') || '(direct)';

    if (ROLE === 'border') {
      // Terminal: cache topology, persist for web UI, optionally report to NS.
      this.stats.hbRx++;
      this.meshTopo.set(hb.sourceRelayId.toString('hex'), {
        path: hb.path.map(p => ({ relayId: p.relayId.toString('hex'), rssi: p.rssi, snr: p.snr })),
        lastSeen: Date.now(),
        hop: hopCount,
      });
      const cutoff = Date.now() - HEARTBEAT_INTERVAL * 3000;
      for (const [k, v] of this.meshTopo) if (v.lastSeen < cutoff) this.meshTopo.delete(k);
      this._writeTopo();
      console.log(`[${ts}] HB RX src=${hb.sourceRelayId.toString('hex')} path=${fmtPath(hb.path)} hop=${hopCount}`);
      this._mqttPublishHeartbeat(hb, hopCount);
      return;
    }

    // Relay: append self to relay_path and re-broadcast (until MAX_HOP).
    if (hopCount >= MAX_HOP) return;
    const key = `hb:${hb.sourceRelayId.toString('hex')}:${hb.timestamp}`;
    if (!this.dedup.add(key)) return;
    const path = [...hb.path, {
      relayId: Buffer.from(this.relayId),
      rssi: parseInt(rxpk.rssi || -100),
      snr: parseInt(rxpk.lsnr || 0),
    }];
    const frame = encodeHeartbeatFrame(SIGNING_KEY, hb.sourceRelayId, path, hopCount + 1);
    this._txPullResp(frame);
    this.stats.hbTx++;
    console.log(`[${ts}] HB RELAY src=${hb.sourceRelayId.toString('hex')} path=${fmtPath(path)} hop=${hopCount + 1}`);
  }

  _writeTopo() {
    const data = {
      border: this.gwId ? this.gwId.toString('hex').toUpperCase() : '',
      updated: new Date().toISOString(),
      intervalSec: HEARTBEAT_INTERVAL,
      relays: Array.from(this.meshTopo.entries()).map(([id, v]) => ({
        relay_id: id.toUpperCase(),
        path: v.path,
        hop: v.hop,
        last_seen: new Date(v.lastSeen).toISOString(),
        online: (Date.now() - v.lastSeen) < HEARTBEAT_INTERVAL * 2000,
      })).sort((a, b) => a.relay_id.localeCompare(b.relay_id)),
    };
    try { fs.writeFileSync('/opt/chirpstack/mesh_topo.json', JSON.stringify(data, null, 2)); } catch {}
  }

  _initMqtt() {
    try { this.mqtt = require('mqtt'); } catch (e) { console.log('MQTT: mqtt module not in image'); return; }
    const url = MQTT_SERVER.startsWith('mqtt://') || MQTT_SERVER.startsWith('mqtts://')
      ? MQTT_SERVER : 'mqtt://' + MQTT_SERVER;
    const opts = {};
    if (MQTT_USERNAME) { opts.username = MQTT_USERNAME; opts.password = MQTT_PASSWORD; }
    this.mqttClient = this.mqtt.connect(url, opts);
    this.mqttClient.on('connect', () => console.log(`MQTT: connected ${url}`));
    this.mqttClient.on('error', (e) => console.log(`MQTT: error ${e.message}`));
    this.mqttClient.on('reconnect', () => console.log('MQTT: reconnecting'));
    this.mqttClient.on('message', (topic, payload) => this._onMqttMessage(topic, payload));
  }

  _mqttPublishHeartbeat(hb, hopCount) {
    if (!this.mqttClient || !this.mqttClient.connected) return;
    const gwId = this.gwId ? this.gwId.toString('hex') : '';
    const topic = `${MQTT_PREFIX ? MQTT_PREFIX + '/' : ''}gateway/${gwId}/event/mesh`;
    const payload = {
      gatewayId: gwId,
      relayId: hb.sourceRelayId.toString('hex'),
      time: new Date().toISOString(),
      events: [{ heartbeat: { relayPath: hb.path.map(p => ({
        relayId: p.relayId.toString('hex'), rssi: p.rssi, snr: p.snr })) } }],
    };
    const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
    this.mqttClient.publish(topic, JSON.stringify(payload), {}, (e) => {
      console.log(`[${ts}] MQTT PUB ${topic} ${e ? 'ERR ' + e.message : 'OK'}`);
    });
  }

  _forwardSensors(rxpkList) {
    if (BACKEND === 'mqtt') {
      this._mqttUplink(rxpkList);
      return;
    }
    const gw = this.gwId || Buffer.alloc(8);
    const body = JSON.stringify({
      rxpk: rxpkList,
      stat: { time: new Date().toISOString().replace('T',' ').replace(/\.\d+Z/, ' GMT') }
    });
    const token = Date.now() & 0xFFFF;
    const header = Buffer.alloc(4);
    header[0] = PROTO; header.writeUInt16BE(token, 1); header[3] = PUSH_DATA;
    const pkt = Buffer.concat([header, gw, Buffer.from(body)]);
    this.fsock.send(pkt, SERVER_PORT, SERVER_HOST);

    // Border: also send PULL_DATA so LGB always has our address for downlinks
    // (pkt_fwd's own PULL_DATA is only every ~30s — too slow for JoinAccept)
    if (ROLE === 'border') {
      const pullHdr = Buffer.alloc(4);
      pullHdr[0] = PROTO; pullHdr.writeUInt16BE((token + 1) & 0xFFFF, 1); pullHdr[3] = PULL_DATA;
      this.fsock.send(Buffer.concat([pullHdr, gw]), SERVER_PORT, SERVER_HOST);
    }
  }

  // ── MQTT backend (ChirpStack v4 gateway MQTT) ─────────────────────
  _mqttUplink(rxpkList) {
    if (!this.mqttClient || !this.mqttClient.connected) return;
    const gwId = this.gwId ? this.gwId.toString('hex') : '';
    if (!gwId) return;
    const topic = `${MQTT_PREFIX ? MQTT_PREFIX + '/' : ''}gateway/${gwId}/event/up`;
    for (const rxpk of rxpkList) {
      this.ulCtr = (this.ulCtr + 1) & 0xFFF;
      const frame = rxpkToUplinkFrame(rxpk, gwId, this.ulCtr);
      this.mqttClient.publish(topic, JSON.stringify(frame));
    }
  }

  _mqttAck(token) {
    if (!this.mqttClient || !this.mqttClient.connected) return;
    const gwId = this.gwId ? this.gwId.toString('hex') : '';
    if (!gwId) return;
    const topic = `${MQTT_PREFIX ? MQTT_PREFIX + '/' : ''}gateway/${gwId}/event/ack`;
    this.mqttClient.publish(topic, JSON.stringify({ gatewayId: gwId, token: token || 0, error: '' }));
  }

  _onMqttMessage(topic, payload) {
    if (topic.endsWith('/command/down')) this._onMqttDown(topic, payload);
  }

  _onMqttDown(topic, payload) {
    let cmd;
    try { cmd = JSON.parse(payload.toString()); } catch { return; }
    if (!cmd.items || !cmd.items.length) return;
    const item = cmd.items[0];
    if (!item.phyPayload) return;
    const txInfo = item.txInfo || {};
    const txpk = {
      data: item.phyPayload,
      freq: (txInfo.frequency || 0) / 1e6,
      powe: txInfo.power || 14,
      datr: modToDatr(txInfo.modulation),
      imme: txInfo.timing === 'IMMEDIATELY',
    };
    // ChirpStack MQTT downlink carries delay as relative duration (e.g. "1s"),
    // not an absolute concentrator tmst. Pass it to _handleTxpk which derives
    // the mesh-DL delay from it (relay does the precise RX-window timing).
    if (txInfo.timing === 'DELAY' && txInfo.delayTimingInfo && txInfo.delayTimingInfo.delay) {
      txpk.chirpstackDelaySec = parseDelay(txInfo.delayTimingInfo.delay);
    }
    this._handleTxpk(txpk);
    this._mqttAck(cmd.token || 0);
  }

  // ── Downlink: PULL_RESP / ChirpStack downlink → mesh frame or direct ──
  _onPullResp(msg) {
    if (msg.length < 4) return;
    const ver = msg[0], token = msg.readUInt16BE(1), pktId = msg[3];
    if (ver !== PROTO || pktId !== PULL_RESP) return;
    if (msg.length <= 4) return;

    this.stats.dlRx++;
    let txData;
    try {
      txData = JSON.parse(msg.slice(4).toString());
    } catch { return; }

    const txpk = txData.txpk;
    if (!txpk || !txpk.data) return;

    this._handleTxpk(txpk);
  }

  // Shared downlink handler: routes a txpk (LGB PULL_RESP or ChirpStack MQTT
  // downlink) to a mesh-downlink frame (via relay) or direct PULL_RESP.
  _handleTxpk(txpk) {
    const phyPayload = Buffer.from(txpk.data, 'base64');
    const freq = txpk.freq || 0;
    const datr = txpk.datr || 'SF7BW125';
    // The mesh DL must carry the DOWNLINK data rate (not the uplink DR) or the
    // sensor cannot decode the frame. Encoded region-agnostically as SF+BW.
    const dlDrField0 = datrToDrField(datr);
    const dlDr = dlDrField0 !== null ? dlDrField0 : datrToDrField('SF7BW125');
    const power = txpk.powe || 14;
    const tmst = txpk.tmst || 0;
    const imme = txpk.imme || false;

    const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
    console.log(`[${ts}] PULL_RESP: freq=${freq}MHz datr=${datr} ${phyPayload.length}B imme=${imme} tmst=${tmst}`);

    // Determine routing: mesh relay or direct
    const devKey = getDeviceKey(phyPayload);
    let ctx = devKey ? this.dlCtx.get(devKey) : null;

    // For a JoinAccept, match the originating JoinRequest EXACTLY by tmst.
    // NS sends the JoinAccept with tmst = joinreq_uplink_tmst + JOIN_DELAY, the
    // expTmst we indexed. Robust even with many sensors joining concurrently
    // (a plain "last JoinRequest" would pick the wrong sensor's request).
    if (!ctx && tmst && this.joinReqs.length) {
      let best = null, bestDiff = Infinity;
      for (const j of this.joinReqs) {
        let d = Math.abs(tmst - j.expTmst);
        if (d > 0x80000000) d = 0x100000000 - d; // 32-bit wrap
        if (d < bestDiff) { bestDiff = d; best = j; }
      }
      if (best && bestDiff <= 2e6) { // within 2s counts as a match
        ctx = { relayId: best.relayId, uid: best.uid, dr: best.dr, tmst: best.tmst, hop: best.hop || 0 };
        console.log(`  JoinAccept matched JoinReq by tmst (uid=${best.uid}, diff=${bestDiff}us, joinReqs=${this.joinReqs.length})`);
      }
    }

    // Fallback for JoinAccept: its DevAddr key differs from the JoinRequest's
    // DevEUI key, so dlCtx won't match. Route via the most recent JoinRequest
    // (NS answers a JoinRequest within ~1s, so it is still fresh).
    if (!ctx && this.lastJoinReq && (Date.now() - this.lastJoinReq.wallMs) < 15000) {
      ctx = this.lastJoinReq;
      const ageMs = Date.now() - this.lastJoinReq.wallMs;
      console.log(`  JoinAccept routed via lastJoinReq FALLBACK (uid=${ctx.uid}, age=${ageMs}ms)`);
    } else if (!ctx && this.lastRelay) {
      ctx = this.lastRelay;
      console.log(`  Using lastRelay fallback for ${devKey || 'unknown'}`);
    }

    // The mesh DL "delay" tells the relay how long after ITS OWN uplink tmst to
    // transmit. It is NOT hardcoded — it follows the NS timing:
    //   imme=true  -> delay 0 (transmit immediately; Class C sensor always listening)
    //   imme=false -> delay = NS downlink tmst − reported uplink tmst (both on the
    //                 border concentrator time-base, so the difference is relative
    //                 and clock-independent). This is the RX1/RX2 offset.
    let delaySec = imme ? 0 : null;
    if (txpk.chirpstackDelaySec) {
      // ChirpStack MQTT downlink carries a relative delay (e.g. "1s"); use it
      // directly for the mesh-DL delay (relay does precise RX-window timing).
      delaySec = Math.max(1, Math.min(15, txpk.chirpstackDelaySec));
    } else if (!imme && ctx && tmst && ctx.tmst) {
      let diff = tmst - ctx.tmst;
      if (diff < 0) diff += 0x100000000; // 32-bit concentrator counter wrap
      // ctx.tmst is the BORDER's receive tmst of the mesh uplink, which is later
      // than the first-hop relay's own receive tmst by the mesh forwarding time.
      // Add (hops-1)*MESH_HOP_MS so the relay still hits the sensor's RX window.
      const hopComp = ((ctx.hop || 1) - 1) * MESH_HOP_MS * 1e3;
      delaySec = Math.round((diff + hopComp) / 1e6);
      delaySec = Math.max(1, Math.min(15, delaySec));
      console.log(`  RX delay derived: tmst=${tmst} uplinkTmst=${ctx.tmst} hop=${ctx.hop||1} +${Math.round(hopComp/1e6)}s comp -> ${delaySec}s`);
    } else if (!imme) {
      // No timing info to derive from — cannot schedule a timed downlink.
      console.log(`  WARN: timed downlink without tmst/ctx, cannot schedule (devKey=${devKey||'?'})`);
    }

    if (ctx && ctx.relayId && delaySec !== null) {
      // Build mesh downlink frame
      this.ulCtr = (this.ulCtr + 1) & 0xFFF;
      const meta = encodeDownlinkMeta(ctx.uid, dlDr, Math.round(freq * 1e6), power, delaySec);
      const mhdr = (MTYPE_PROP << 5) | (1 << 3) | 0; // MType=111, PT=Downlink, hop=1
      const frame = Buffer.concat([
        Buffer.from([mhdr]), meta, ctx.relayId, phyPayload
      ]);
      const mic = computeMic(SIGNING_KEY, frame);
      const meshFrame = Buffer.concat([frame, mic]);

      let devAddr = 'unknown';
      if (phyPayload.length >= 5) {
        devAddr = reverseBytes(phyPayload.slice(1, 5)).toString('hex');
      }
      console.log(`[${ts}] TX mesh DL: relay=${ctx.relayId.toString('hex')} dev=${devAddr} uid=${ctx.uid} ${meshFrame.length}B`);
      this._txPullResp(meshFrame);
    } else {
      // Direct downlink to pkt_fwd
      console.log(`[${ts}] TX direct DL: ${phyPayload.length}B (no relay context for ${devKey || 'unknown'})`);
      this._sendDirectDownlink(phyPayload, freq, datr, power, tmst, imme);
      this.stats.dlDirect++;
    }
  }

  // ── Send PULL_RESP directly to pkt_fwd ───────────────────────────
  _sendDirectDownlink(phyPayload, freq, datr, power, tmst, imme) {
    if (!this.lastPullAddr) {
      console.log(`[${new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'')}] DL: NO lastPullAddr — cannot send downlink`);
      return;
    }

    datr = datr || 'SF7BW125';
    power = power || 14;

    const txpk = {
      imme: imme === true,  // FIX: false || true = true bug — preserve false
      freq: freq,
      rfch: 0,
      powe: power,
      modu: 'LORA',
      datr: datr,
      codr: '4/5',
      ipol: true,
      size: phyPayload.length,
      data: phyPayload.toString('base64'),
    };
    if (tmst && !txpk.imme) txpk.tmst = tmst;

    // Use the same token scheme as _txPullResp (which pkt_fwd accepts):
    // pkt_fwd expects the PULL_RESP token = lastPullToken + 1.
    const token = (this.lastPullToken + 1) & 0xFFFF;
    const header = Buffer.alloc(4);
    header[0] = PROTO;
    header.writeUInt16BE(token, 1);
    header[3] = PULL_RESP;

    const pkt = Buffer.concat([header, Buffer.from(JSON.stringify({ txpk }))]);
    const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
    console.log(`[${ts}] DL send ${pkt.length}B to ${this.lastPullAddr.address}:${this.lastPullAddr.port} token=${token} freq=${freq} ${datr} imme=${txpk.imme} tmst=${txpk.tmst || 0}`);
    this.lsock.send(pkt, this.lastPullAddr.port, this.lastPullAddr.address, (err) => {
      const nts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      if (err) console.log(`[${nts}] DL send ERROR: ${err.message}`);
      else console.log(`[${nts}] DL send OK (udp delivered to kernel)`);
    });
    this.stats.dlTx++;
  }
}

// ── Main ───────────────────────────────────────────────────────────
const fwd = new MeshForwarder();
fwd.start();

process.on('SIGTERM', () => { console.log('SIGTERM, stopping...'); process.exit(0); });
process.on('SIGINT', () => { console.log('SIGINT, stopping...'); process.exit(0); });
