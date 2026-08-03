#!/usr/bin/env node
/**
 * LoRa Mesh Forwarder — native pkt_fwd edition (Node.js)
 *
 * UDP proxy: pkt_fwd ↔ gateway-bridge, with mesh (MType=111) wrapping/unwrapping.
 *   Relay:  sensor → wrap MType=111 → TX via PULL_RESP
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
const SERVER_HOST = cfg('server-host', '127.0.0.1');
const SERVER_PORT = parseInt(cfg('server-port', '1710'));
const MESH_FREQS = cfg('mesh-freqs', '903900000,904100000,904300000').split(',').map(Number);
const MESH_SF = parseInt(cfg('mesh-sf', '7'));
const MESH_BW = parseInt(cfg('mesh-bw', '125000'));
const TX_POWER = parseInt(cfg('tx-power', '27'));
const MAX_HOP = parseInt(cfg('max-hop', '1'));
// LoRaWAN JoinAccept RX1 delay (seconds). NS schedules the JoinAccept at
// uplink_tmst + JOIN_DELAY, so we use it to index pending JoinRequests.
const JOIN_DELAY = parseInt(cfg('join-delay', '5'));

// ── Semtech UDP ────────────────────────────────────────────────────
const PROTO = 2;
const PUSH_DATA = 0, PUSH_ACK = 1, PULL_DATA = 2, PULL_RESP = 3, PULL_ACK = 4, TX_ACK = 5;

// ── US915 DR table ─────────────────────────────────────────────────
const DATR_DR = { SF10BW125:0, SF9BW125:1, SF8BW125:2, SF7BW125:3, SF8BW500:4, SF12BW500:5, SF11BW500:6 };
const DR_DATR = {};
for (const [k,v] of Object.entries(DATR_DR)) DR_DATR[v] = k;

// US915 DOWNLINK data rates (RX1/RX2 are all 500kHz, DR8-DR13). The JoinAccept
// is sent on one of these, so the mesh DL must carry the downlink DR (not the
// uplink DR) or the sensor cannot decode it. Keyed by standard US915 downlink DR.
const DL_DATR_DR = { SF12BW500:8, SF11BW500:9, SF10BW500:10, SF9BW500:11, SF8BW500:12, SF7BW500:13 };
const DL_DR_DATR = {};
for (const [k,v] of Object.entries(DL_DATR_DR)) DL_DR_DATR[v] = k;

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
// byte 5: power[7:4] | delay[3:0]  (delay = raw + 1 seconds)
function encodeDownlinkMeta(uid, dr, freqHz, power, delaySec) {
  const uidClamped = uid & 0xFFF;
  const drClamped = dr & 0x0F;
  const freqEnc = Math.round(freqHz / 100) & 0xFFFFFF;
  const pwrClamped = Math.min(15, Math.max(0, power)) & 0x0F;
  const delayRaw = Math.min(15, Math.max(0, (delaySec || 1) - 1)) & 0x0F;
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
    this.stats = { rx: 0, sensor: 0, meshIn: 0, meshTx: 0, unwrap: 0, fwd: 0, dedup: 0, dlRx: 0, dlTx: 0, dlDirect: 0 };
    this.dlCtx = new DlCtxCache();
    this.uplinkTmst = new Map(); // relay: deviceKey → concentrator tmst
    this.lastRelay = null; // { relayId, uid, dr, tmst } — fallback for downlink routing
    this.lastJoinReq = null; // { relayId, uid, dr, tmst, wallMs } — last JoinRequest (for JoinAccept)
    this.joinReqs = []; // border: pending JoinRequests [{expTmst, relayId, uid, dr, wallMs}] for exact tmst match
    this.lastUplinkTmst = null; // relay: most recent uplink tmst (for RX window timing)
    this.ulTmstMap = new Map(); // relay: uplink_id → its concentrator tmst

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
    });

    // Listen for PULL_RESP from gateway bridge (downlinks)
    this.fsock.on('message', (msg) => this._onPullResp(msg));

    // Stats every 60s
    setInterval(() => {
      const s = this.stats;
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      console.log(`[${ts}] Stats: rx=${s.rx} sensor=${s.sensor} mesh_in=${s.meshIn} tx=${s.meshTx} unwrap=${s.unwrap} fwd=${s.fwd} dedup=${s.dedup} dl_rx=${s.dlRx} dl_tx=${s.dlTx} dl_dir=${s.dlDirect}`);
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
    const dr = DATR_DR[datr] !== undefined ? DATR_DR[datr] : 3;
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
    // Check payload type: uplink (0) or downlink (1)
    const mhdr = phy[0];
    const payloadType = (mhdr >> 3) & 0x03;

    // ── Downlink handling (relay only) ──
    if (payloadType === 1) {
      if (ROLE !== 'relay') return;
      if (phy.length < 15) return; // MHDR(1)+meta(6)+relay(4)+phy(1)+MIC(4)
      const frameNoMic = phy.slice(0, -4);
      const expectedMic = computeMic(SIGNING_KEY, frameNoMic);
      if (!phy.slice(-4).equals(expectedMic)) return; // bad MIC
      const relayId = phy.slice(7, 11);
      if (!this.relayId || !relayId.equals(this.relayId)) return; // not for us
      const originalPhy = phy.slice(11, -4);
      const hopCount = (mhdr & 0x07) + 1;
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');

      // Extract DownlinkMetadata: uid(12bit)+dr(4bit) | freq/100(24bit) | power(4bit)+delay(4bit)
      const meta = phy.slice(1, 7);
      const dlUid = ((meta[0] << 8) | meta[1]) >> 4;
      const dr = meta[1] & 0x0F;
      const dlFreq = (meta[2] << 16 | meta[3] << 8 | meta[4]) * 100;
      const dlPower = meta[5] >> 4;
      const delaySec = (meta[5] & 0x0F) + 1;
      // Downlink DRs are US915 DR8-13 (500kHz); fall back to the uplink table
      const dlDatr = DL_DR_DATR[dr] || DR_DATR[dr] || 'SF7BW125';

      // Use the uplink tmst for THIS uid (the JoinRequest that triggered this
      // downlink), not the most recent uplink — fallback to lastUplinkTmst
      const tmstHit = this.ulTmstMap.has(dlUid);
      let uplinkTmst = this.ulTmstMap.get(dlUid) || this.lastUplinkTmst || 0;

      // DIAGNOSTIC: recvTmst = relay concentrator time when THIS mesh downlink
      // arrived. leadTime = scheduled TX time − recvTmst. If leadTime < 0 the
      // TX timestamp is already in the past and pkt_fwd will reject it (too late).
      const recvTmst = rxpk.tmst || 0;

      // Schedule TX at uplinkTmst + delay (LoRaWAN RX window), NOT immediate
      // (immediate would fire before the sensor's RX window opens)
      let tmst = 0;
      if (uplinkTmst) {
        tmst = ((uplinkTmst + delaySec * 1e6) >>> 0); // >>> 0 = unsigned 32-bit
        // signed lead time accounting for 32-bit counter wrap
        let lead = tmst - recvTmst;
        if (lead > 0x80000000) lead -= 0x100000000;
        if (lead < -0x80000000) lead += 0x100000000;
        console.log(`[${ts}] MESH DL uid=${dlUid} ${originalPhy.length}B freq=${dlFreq/1e6}MHz ${dlDatr} pwr=${dlPower} delay=${delaySec}s | uplinkTmst=${uplinkTmst}(${tmstHit?'HIT':'MISS'}) recvTmst=${recvTmst} txTmst=${tmst} lead=${lead}us (${(lead/1e6).toFixed(2)}s) → pkt_fwd`);
      } else {
        console.log(`[${ts}] MESH DL uid=${dlUid} ${originalPhy.length}B (no uplinkTmst, immediate) recvTmst=${recvTmst} → pkt_fwd`);
      }
      const dlFreqMHz = dlFreq ? dlFreq / 1e6 : rxpk.freq;
      this._sendDirectDownlink(originalPhy, dlFreqMHz, dlDatr, dlPower, tmst, false);
      this.stats.dlTx++;
      return;
    }

    // ── Uplink handling ──
    const result = decodeMeshUplink(SIGNING_KEY, phy);
    if (!result) { this.stats.dedup++; return; }

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
        datr: DR_DATR[meta.dr] || 'SF7BW125',
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
        });
      }
      // Always update lastRelay (fallback for JoinAccept where DevAddr key ≠ JoinRequest DevEUI key)
      this.lastRelay = {
        relayId: Buffer.from(relayId),
        uid: meta.uid,
        dr: meta.dr,
        tmst: rxpk.tmst || 0,
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
        };
        // Index by the downlink tmst the NS will use for this JoinRequest's
        // JoinAccept: NS sends JoinAccept with tmst = uplink_tmst + JOIN_DELAY.
        // Multiple sensors may join concurrently, so key on the unique tmst
        // (not "last JoinRequest") to match the right one later.
        const expTmst = ((jrTmst + JOIN_DELAY * 1e6) >>> 0);
        this.joinReqs.push({ expTmst, relayId: Buffer.from(relayId), uid: meta.uid, dr: meta.dr, wallMs: Date.now() });
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
      console.log(`[${ts}] UNWRAP relay=${relayId.toString('hex')} uid=${meta.uid} dev=${devAddr} hop=${hopCount} ${DR_DATR[meta.dr]||'?'} freq=${rxpk.freq}MHz rssi=${meta.rssi} snr=${meta.snr} ${originalPhy.length}B → bridge`);
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

  _forwardSensors(rxpkList) {
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

  // ── Downlink: LGB PULL_RESP → mesh frame or direct ───────────────
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

    const phyPayload = Buffer.from(txpk.data, 'base64');
    const freq = txpk.freq || 0;
    const datr = txpk.datr || 'SF7BW125';
    // The mesh DL must carry the DOWNLINK data rate (US915 RX1/RX2 are 500kHz
    // DR8-13), not the uplink DR, or the sensor cannot decode the JoinAccept.
    const dlDr = DL_DATR_DR[datr] !== undefined ? DL_DATR_DR[datr]
               : (DATR_DR[datr] !== undefined ? DATR_DR[datr] : 8);
    const power = txpk.powe || 14;
    const tmst = txpk.tmst || 0;
    const imme = txpk.imme || false;

    const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
    console.log(`[${ts}] PULL_RESP: freq=${freq}MHz datr=${datr} ${phyPayload.length}B imme=${imme} tmst=${tmst}`);

    // Determine routing: mesh relay or direct
    const devKey = getDeviceKey(phyPayload);
    let ctx = devKey ? this.dlCtx.get(devKey) : null;
    let matchedByTmst = false;

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
        ctx = { relayId: best.relayId, uid: best.uid, dr: best.dr };
        matchedByTmst = true;
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
    // transmit. For a JoinAccept that is exactly JOIN_DELAY. For other downlinks
    // derive it from the NS tmst (both on the border concentrator time-base).
    let delaySec = JOIN_DELAY;
    if (!matchedByTmst) {
      let rxDelaySec = 0;
      if (ctx && tmst && ctx.tmst) {
        let diff = tmst - ctx.tmst;
        if (diff < 0) diff += 0x100000000; // 32-bit concentrator counter wrap
        rxDelaySec = Math.round(diff / 1e6);
      }
      delaySec = (rxDelaySec >= 1 && rxDelaySec <= 16) ? rxDelaySec : JOIN_DELAY;
      console.log(`  RX delay derived: tmst=${tmst} uplinkTmst=${ctx && ctx.tmst} -> ${rxDelaySec}s (using ${delaySec}s)`);
    }

    if (ctx && ctx.relayId) {
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
