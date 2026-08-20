// Multi-hop downlink logic verification (no network; mocks sockets and fs).
// Loads pkt_mesh_fwd.js function definitions via vm (main section stripped) with
// a stubbed config (max-hop-count=3), instantiates MeshForwarder without
// start(), and exercises _onMeshRx's Downlink branch:
//   addressed → direct TX; not-addressed → hop+1 re-broadcast;
//   duplicate → dedup drop; hop >= MAX_HOP → drop.
'use strict';
const vm = require('vm');
const assert = require('assert');
const fs = require('fs');

const configJson = JSON.stringify({
  role: 'relay',
  'signing-key': '00112233445566778899aabbccddeeff',
  'max-hop-count': 3,
});
const fsStub = { readFileSync: () => configJson };
const sandbox = {
  require: (m) => (m === 'fs' ? fsStub : require(m)),
  Buffer, console,
  process: { argv: [] },
  setTimeout, clearTimeout, setInterval, clearInterval,
};

const src = fs.readFileSync(__dirname + '/pkt_mesh_fwd.js', 'utf8');
const body = src.split('// ── Main ──')[0]; // stop before main
vm.createContext(sandbox);
const refs = vm.runInNewContext(body + '\n; ({ MeshForwarder, encodeDownlinkMeta, computeMic })', sandbox, { filename: 'pkt_mesh_fwd.js' });
const { MeshForwarder, encodeDownlinkMeta, computeMic } = refs;

const KEY = Buffer.from('00112233445566778899aabbccddeeff', 'hex');

function makeRelay(relayIdHex) {
  const fwd = new MeshForwarder();
  fwd.relayId = Buffer.from(relayIdHex, 'hex');
  fwd.lastPullAddr = { address: '127.0.0.1', port: 1701 };
  fwd.sent = [];
  fwd.direct = [];
  fwd._txPullResp = (frame) => fwd.sent.push(frame);
  fwd._sendDirectDownlink = (phy, freq, datr, pwr, tmst, imme) => fwd.direct.push({ phy, freq, datr, pwr, tmst, imme });
  return fwd;
}

// Build a mesh downlink frame the way the border does (_handleTxpk path).
function buildMeshDl(relayIdHex, uid, freqMHz, delaySec, hopStored = 0) {
  const meta = encodeDownlinkMeta(uid, 0, Math.round(freqMHz * 1e6), 16, delaySec);
  const mhdr = (7 << 5) | (1 << 3) | (hopStored & 0x07); // PT=Downlink, hop stored N-1
  const frame = Buffer.concat([Buffer.from([mhdr]), meta, Buffer.from(relayIdHex, 'hex'), Buffer.from('0102030405060708', 'hex')]);
  return Buffer.concat([frame, computeMic(KEY, frame)]);
}

let pass = 0;
function check(name, cond) { assert(cond, name); console.log('  PASS ' + name); pass++; }

console.log('Test 1: addressed relay → direct TX');
{
  const relay = makeRelay('aabbccdd');
  relay.ulTmstMap.set(7, 5000000); // uplink uid=7 tmst
  const frame = buildMeshDl('aabbccdd', 7, 903.9, 2);
  relay._onMeshRx(frame, { tmst: 1000000 });
  check('direct TX called once', relay.direct.length === 1);
  check('no re-broadcast', relay.sent.length === 0);
  check('delay 2s → txTmst = uplink 5000000 + 2e6 = 7000000', relay.direct[0].tmst === 7000000);
  relay._onMeshRx(frame, { tmst: 1000000 });
  check('duplicate dropped (no 2nd direct TX)', relay.direct.length === 1);
}

console.log('Test 2: relay B (not addressed) → hop+1 re-broadcast');
{
  const relayB = makeRelay('11223344'); // B ≠ first-hop A
  const frame = buildMeshDl('aabbccdd', 7, 903.9, 2);
  relayB._onMeshRx(frame, { tmst: 1000000 });
  check('re-broadcast once', relayB.sent.length === 1);
  check('no direct TX', relayB.direct.length === 0);
  const newFrame = relayB.sent[0];
  check('MHDR PT still Downlink', ((newFrame[0] >> 3) & 0x03) === 1);
  check('hop stored 1 → decodes to 2', ((newFrame[0] & 0x07) + 1) === 2);
  check('relayId preserved (first-hop A)', newFrame.slice(7, 11).toString('hex') === 'aabbccdd');
  check('MIC valid after re-sign', newFrame.slice(-4).equals(computeMic(KEY, newFrame.slice(0, -4))));
  relayB._onMeshRx(frame, { tmst: 1000000 });
  relayB._onMeshRx(newFrame, { tmst: 2000000 });
  check('loop cut (still 1 re-broadcast)', relayB.sent.length === 1);
}

console.log('Test 3: 3-relay chain — B forwards, C forwards, A gets it and TXes direct');
{
  const relayB = makeRelay('11223344'); // hop 1 → 2
  const relayC = makeRelay('55667788'); // hop 2 → 3
  const relayA = makeRelay('aabbccdd'); // addressed
  relayA.ulTmstMap.set(7, 5000000);
  const frame = buildMeshDl('aabbccdd', 7, 903.9, 2);
  relayB._onMeshRx(frame, { tmst: 1000000 });          // B relays (hop→2)
  relayC._onMeshRx(relayB.sent[0], { tmst: 2000000 }); // C relays (hop→3)
  relayA._onMeshRx(relayC.sent[0], { tmst: 3000000 }); // A TXes direct
  check('B forwarded', relayB.sent.length === 1);
  check('C forwarded', relayC.sent.length === 1);
  check('A direct TX once', relayA.direct.length === 1);
  check('A did not re-forward', relayA.sent.length === 0);
}

console.log('Test 4: hop >= MAX_HOP (3) → drop');
{
  const relayC = makeRelay('55667788');
  const frame = buildMeshDl('aabbccdd', 7, 903.9, 2, 2); // hop stored 2 → hopCount 3
  relayC._onMeshRx(frame, { tmst: 2000000 });
  check('hop3 >= max3 → dropped (no relay, no direct)', relayC.sent.length === 0 && relayC.direct.length === 0);
}

console.log('Test 5: bad MIC → dropped silently');
{
  const relayB = makeRelay('11223344');
  const frame = buildMeshDl('aabbccdd', 7, 903.9, 2);
  frame[frame.length - 1] ^= 0xFF; // corrupt MIC
  relayB._onMeshRx(frame, { tmst: 1000000 });
  check('bad MIC dropped', relayB.sent.length === 0 && relayB.direct.length === 0);
}

console.log(`\nALL PASS (${pass} checks)`);
