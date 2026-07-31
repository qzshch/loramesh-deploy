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
const http = require('http');

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
const CONFIG_PORT = parseInt(cfg('config-port', '8088'));

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
      console.log(`Stats: rx=${s.rx} sensor=${s.sensor} mesh_in=${s.meshIn} tx=${s.meshTx} unwrap=${s.unwrap} fwd=${s.fwd} dedup=${s.dedup}`);
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

    const meshFrame = buildMeshUplink(
      SIGNING_KEY, this.relayId, phy,
      this.ulCtr, dr,
      parseInt(rxpk.rssi || -100),
      parseInt(rxpk.lsnr || 0),
      channel
    );

    this._txPullResp(meshFrame);
    const txFreq = MESH_FREQS[(this.freqIdx - 1 + MESH_FREQS.length) % MESH_FREQS.length];
    console.log(`TX mesh: uid=${this.ulCtr} relay=${this.relayId.toString('hex')} freq=${txFreq/1e6}MHz size=${meshFrame.length}B`);
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
      console.log(`UNWRAP: relay=${relayId.toString('hex')} uid=${meta.uid} hop=${hopCount} dr=${meta.dr} rssi=${meta.rssi} snr=${meta.snr} size=${originalPhy.length}B`);
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

// ── HTTP Config Server (port 8088) ─────────────────────────────────
const CONFIG_HTML = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LoRa Mesh Config</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,sans-serif;background:#1a1a2e;color:#e0e0e0;padding:20px}
h1{color:#00d4ff;margin-bottom:20px;font-size:1.4em}
.card{background:#16213e;border-radius:8px;padding:20px;margin-bottom:16px;border:1px solid #0f3460}
.card h2{color:#00d4ff;font-size:1em;margin-bottom:12px}
.row{display:flex;gap:12px;margin-bottom:10px;flex-wrap:wrap;align-items:center}
label{min-width:120px;color:#a0a0a0;font-size:0.9em}
input,select{background:#0f3460;border:1px solid #1a5276;color:#e0e0e0;padding:8px 12px;border-radius:4px;font-size:0.9em;flex:1;min-width:150px}
input:focus,select:focus{border-color:#00d4ff;outline:none}
button{background:#00d4ff;color:#1a1a2e;border:none;padding:10px 24px;border-radius:4px;font-weight:bold;cursor:pointer;font-size:0.95em}
button:hover{background:#00b8d4}
button.danger{background:#e74c3c;color:white}
.status{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
.on{background:#2ecc71}.off{background:#e74c3c}
.stats{font-family:monospace;font-size:0.85em;color:#7f8c8d;line-height:1.6}
.msg{padding:10px;border-radius:4px;margin:10px 0;display:none}
.msg.ok{background:#1e8449;display:block}.msg.err{background:#922b21;display:block}
</style></head><body>
<h1>LoRa Mesh Forwarder</h1>
<div id="msg" class="msg"></div>
<div class="card"><h2>Mesh Configuration</h2>
<form id="cfg">
<div class="row"><label>Role</label><select name="role"><option value="relay">Relay</option><option value="border">Border</option></select></div>
<div class="row"><label>Signing Key</label><input name="signing-key" maxlength="32" placeholder="32 hex chars"></div>
<div class="row"><label>Mesh Freqs (Hz)</label><input name="mesh-freqs" placeholder="comma-separated"></div>
<div class="row"><label>SF</label><input name="mesh-sf" type="number" min="7" max="12" style="max-width:80px">
<label>BW (Hz)</label><input name="mesh-bw" type="number" style="max-width:100px"></div>
<div class="row"><label>TX Power (dBm)</label><input name="tx-power" type="number" min="1" max="30" style="max-width:80px">
<label>Max Hop</label><input name="max-hop" type="number" min="1" max="5" style="max-width:80px"></div>
<div class="row"><label>Listen Port</label><input name="listen-port" type="number" style="max-width:80px">
<label>Bridge Port</label><input name="server-port" type="number" style="max-width:80px"></div>
<div class="row" style="margin-top:16px"><button type="submit">Save & Restart</button>
<button type="button" class="danger" onclick="doAction('stop')">Stop</button>
<button type="button" onclick="doAction('start')">Start</button></div>
</form></div>
<div class="card"><h2>Status</h2><div id="stats" class="stats">Loading...</div></div>
<script>
function showMsg(text, ok) {
  const m = document.getElementById('msg');
  m.textContent = text; m.className = 'msg ' + (ok ? 'ok' : 'err');
  setTimeout(() => m.className = 'msg', 4000);
}
async function loadConfig() {
  const r = await fetch('/api/config'); const d = await r.json();
  const f = document.getElementById('cfg');
  for (const [k,v] of Object.entries(d)) {
    const el = f.elements[k]; if (el) el.value = v;
  }
}
async function loadStats() {
  const r = await fetch('/api/stats'); const d = await r.json();
  document.getElementById('stats').innerHTML =
    'Role: ' + d.role + '<br>' +
    'Gateway: ' + (d.gwId || 'learning...') + '<br>' +
    'Relay ID: ' + (d.relayId || '-') + '<br>' +
    'RX total: ' + d.rx + ' | Sensor: ' + d.sensor + ' | Mesh in: ' + d.meshIn + '<br>' +
    'Mesh TX: ' + d.meshTx + ' | Unwrap: ' + d.unwrap + ' | Fwd: ' + d.fwd + '<br>' +
    'Dedup: ' + d.dedup + ' | Uptime: ' + d.uptime + 's';
}
document.getElementById('cfg').addEventListener('submit', async e => {
  e.preventDefault();
  const fd = new FormData(e.target); const cfg = {};
  for (const [k,v] of fd) cfg[k] = v;
  const r = await fetch('/api/config', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)});
  const d = await r.json();
  showMsg(d.ok ? 'Saved! Restarting...' : 'Error: ' + d.error, d.ok);
});
async function doAction(act) {
  const r = await fetch('/api/' + act, {method:'POST'});
  const d = await r.json();
  showMsg(d.ok ? act + ' OK' : 'Error: ' + d.error, d.ok);
}
loadConfig(); loadStats(); setInterval(loadStats, 5000);
</script></body></html>`;

function saveConfig(cfg) {
  try {
    fs.mkdirSync('/opt/chirpstack', { recursive: true });
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
    return true;
  } catch (e) { return false; }
}

const startTime = Date.now();

const httpServer = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(CONFIG_HTML);
    return;
  }

  if (req.url === '/api/config' && req.method === 'GET') {
    const cfg = {
      role: ROLE,
      'signing-key': SIGNING_KEY.toString('hex'),
      'mesh-freqs': MESH_FREQS.join(','),
      'mesh-sf': String(MESH_SF),
      'mesh-bw': String(MESH_BW),
      'tx-power': String(TX_POWER),
      'max-hop': String(MAX_HOP),
      'listen-port': String(LISTEN_PORT),
      'server-port': String(SERVER_PORT),
    };
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(cfg));
    return;
  }

  if (req.url === '/api/stats' && req.method === 'GET') {
    const s = fwd.stats;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      role: ROLE,
      gwId: fwd.gwId ? fwd.gwId.toString('hex').toUpperCase() : null,
      relayId: fwd.relayId ? fwd.relayId.toString('hex') : null,
      rx: s.rx, sensor: s.sensor, meshIn: s.meshIn,
      meshTx: s.meshTx, unwrap: s.unwrap, fwd: s.fwd, dedup: s.dedup,
      uptime: Math.floor((Date.now() - startTime) / 1000),
    }));
    return;
  }

  if (req.url === '/api/config' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const newCfg = JSON.parse(body);
        if (saveConfig(newCfg)) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true }));
          // Restart after 1s
          setTimeout(() => process.exit(0), 1000);
        } else {
          throw new Error('write failed');
        }
      } catch (e) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if ((req.url === '/api/stop' || req.url === '/api/start') && req.method === 'POST') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
    if (req.url === '/api/stop') setTimeout(() => process.exit(0), 500);
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

httpServer.listen(CONFIG_PORT, () => {
  console.log(`Config UI: http://0.0.0.0:${CONFIG_PORT}`);
});

process.on('SIGTERM', () => { console.log('SIGTERM, stopping...'); process.exit(0); });
process.on('SIGINT', () => { console.log('SIGINT, stopping...'); process.exit(0); });
process.on('exit', () => { httpServer.close(); });
