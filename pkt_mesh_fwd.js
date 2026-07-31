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

// ── Semtech UDP ────────────────────────────────────────────────────
const PROTO = 2;
const PUSH_DATA = 0, PUSH_ACK = 1, PULL_DATA = 2, PULL_RESP = 3, PULL_ACK = 4, TX_ACK = 5;

// ── US915 DR table ─────────────────────────────────────────────────
const DATR_DR = { SF10BW125:0, SF9BW125:1, SF8BW125:2, SF7BW125:3, SF8BW500:4, SF12BW500:5, SF11BW500:6 };
const DR_DATR = {};
for (const [k,v] of Object.entries(DATR_DR)) DR_DATR[v] = k;

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
    this.stats = { rx: 0, sensor: 0, meshIn: 0, meshTx: 0, unwrap: 0, fwd: 0, dedup: 0 };

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
    });

    // Stats every 60s
    setInterval(() => {
      const s = this.stats;
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      console.log(`[${ts}] Stats: rx=${s.rx} sensor=${s.sensor} mesh_in=${s.meshIn} tx=${s.meshTx} unwrap=${s.unwrap} fwd=${s.fwd} dedup=${s.dedup}`);
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
      // ACK
      const ack = Buffer.alloc(4);
      ack[0] = PROTO; ack.writeUInt16BE(token, 1); ack[3] = PULL_ACK;
      this.lsock.send(ack, rinfo.port, rinfo.address);
      // Forward to server
      this.fsock.send(msg, SERVER_PORT, SERVER_HOST);
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

    // Relay: wrap sensors → mesh TX + forward originals
    if (ROLE === 'relay' && sensorFrames.length) {
      for (const { rx, phy } of sensorFrames) {
        this.stats.sensor++;
        this._relayWrapAndTx(phy, rx);
      }
      this._forwardSensors(sensorFrames.map(s => s.rx));
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

    this.ulCtr = (this.ulCtr + 1) & 0xFFF;
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
      // Extract DevAddr from original PHYPayload
      let devAddr = 'unknown';
      if (originalPhy.length >= 5) {
        const raw = originalPhy.slice(1, 5).toString('hex');
        devAddr = raw[6]+raw[7]+raw[4]+raw[5]+raw[2]+raw[3]+raw[0]+raw[1];
      }
      const ts = new Date().toISOString().replace('T',' ').replace(/\.\d+Z/,'');
      console.log(`[${ts}] UNWRAP relay=${relayId.toString('hex')} uid=${meta.uid} dev=${devAddr} hop=${hopCount} SF${DR_DATR[meta.dr]||'?'} freq=${rxpk.freq}MHz rssi=${meta.rssi} snr=${meta.snr} ${originalPhy.length}B → bridge`);
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
  }
}

// ── Main ───────────────────────────────────────────────────────────
const fwd = new MeshForwarder();
fwd.start();

process.on('SIGTERM', () => { console.log('SIGTERM, stopping...'); process.exit(0); });
process.on('SIGINT', () => { console.log('SIGINT, stopping...'); process.exit(0); });
