#!/usr/bin/env python3
"""ChirpStack LoRa Mesh - Log & Config Web UI (single-gateway view, with auth)"""

import os, re, json, subprocess, threading, time, collections, hashlib, struct, secrets
from flask import Flask, request, jsonify, Response, session, redirect

app = Flask(__name__)
app.secret_key = secrets.token_hex(16)

# Suppress Flask access logs (they flood shared /tmp/mesh.log)
import logging
log = logging.getLogger('werkzeug')
log.setLevel(logging.WARNING)
app.logger.setLevel(logging.WARNING)

# ── Auth ──

AUTH_CONFIG_PATH = "/opt/chirpstack/.user_permission"
AES_KEY = b"4829173051647823"  # Same as native gateway Web UI
AES_IV  = b"7603912845091736"

def _load_auth_config():
    """Load superuser name and password hash from user_permission config.
    Source: /etc/quagga/user_permission.conf (mounted from host).
    Format:
        superuser name admin
        superuser password $1$...
    """
    username = "admin"
    pw_hash = None
    paths = [
        AUTH_CONFIG_PATH,
        "/etc/host_user_permission",    # Mounted: -v /etc/quagga/user_permission.conf:/etc/host_user_permission:ro
        "/etc/quagga/user_permission.conf",  # Direct access (if container has it)
    ]
    for path in paths:
        try:
            for line in open(path):
                line = line.strip()
                if line.startswith("superuser name"):
                    username = line.split()[-1]
                elif line.startswith("superuser password"):
                    pw_hash = line.split()[-1]
            if pw_hash and "$" in pw_hash:
                return username, pw_hash
        except Exception:
            continue
    # Fallback: SHADOW_HASH env var (legacy support)
    h = os.environ.get("SHADOW_HASH", "").strip()
    if h and "$" in h:
        return "admin", h
    return None, None

def _aes_cbc_decrypt(ciphertext_b64):
    """AES-128-CBC decrypt using pycryptodome."""
    import base64
    try:
        from Crypto.Cipher import AES
        raw = base64.b64decode(ciphertext_b64)
        cipher = AES.new(AES_KEY, AES.MODE_CBC, AES_IV)
        padded = cipher.decrypt(raw)
        # Remove PKCS7 padding
        pad_len = padded[-1]
        if pad_len < 1 or pad_len > 16:
            return None
        return padded[:-pad_len].decode("utf-8", errors="replace")
    except Exception:
        return None

def _verify_password(username, password):
    """Verify password against gateway's user_permission config."""
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        import crypt
    valid_user, pw_hash = _load_auth_config()
    if not pw_hash or not valid_user:
        return False
    if username != valid_user:
        return False
    try:
        computed = crypt.crypt(password, pw_hash)
        return computed == pw_hash
    except Exception:
        return False

def _is_authenticated():
    """Check if current session is authenticated."""
    return session.get("authenticated", False) is True

# ── Auth endpoints ──

@app.route("/api/login", methods=["POST"])
def api_login():
    data = request.get_json(silent=True) or {}
    username = data.get("username", "")
    enc_password = data.get("password", "")

    # Decrypt AES-encrypted password
    password = _aes_cbc_decrypt(enc_password)
    if password is None:
        # Try plaintext (for testing)
        password = enc_password

    if _verify_password(username, password):
        session["authenticated"] = True
        session["username"] = username
        return jsonify({"status": 0, "message": "ok"})
    return jsonify({"status": -1, "message": "Invalid credentials"}), 401

@app.route("/api/logout", methods=["POST"])
def api_logout():
    session.clear()
    return jsonify({"status": 0})

@app.route("/api/islogin", methods=["GET", "POST"])
def api_islogin():
    return jsonify({"login": "true" if _is_authenticated() else "false"})

# ── Auth middleware ──

@app.before_request
def check_auth():
    """Require authentication for all routes except login/static."""
    allowed = ["/api/login", "/api/islogin", "/login", "/favicon.ico"]
    if request.path in allowed or request.path.startswith("/static"):
        return None
    if not _is_authenticated():
        if request.path.startswith("/api/"):
            return jsonify({"status": -2, "message": "Not authenticated"}), 401
        return redirect("/login")

MESH_CONFIG_PATH = "/opt/chirpstack/mesh_config.json"
MQTT_CONFIG_PATH = "/opt/chirpstack/mqtt_forwarder.toml"
IS_BORDER = os.environ.get("RELAY_BORDER", "false") == "true"

DOCKER_BRIDGE_IP = "172.17.0.1"
FORWARDER_STATE_PATH = "/opt/chirpstack/forwarder_state.toml"

def read_forwarder_state():
    """Read persistent forwarder state. Returns dict with protocol, semtech_server, semtech_port."""
    state = {"protocol": "mqtt", "semtech_server": DOCKER_BRIDGE_IP, "semtech_port": 1700}
    try:
        c = open(FORWARDER_STATE_PATH).read()
        m = re.search(r'protocol\s*=\s*"([^"]+)"', c)
        if m: state["protocol"] = m.group(1)
        m = re.search(r'semtech_server\s*=\s*"([^"]+)"', c)
        if m: state["semtech_server"] = m.group(1)
        m = re.search(r'semtech_port\s*=\s*(\d+)', c)
        if m: state["semtech_port"] = int(m.group(1))
    except FileNotFoundError:
        pass
    return state

def write_forwarder_state(**kwargs):
    """Write persistent forwarder state. Merges with existing values."""
    state = read_forwarder_state()
    state.update(kwargs)
    with open(FORWARDER_STATE_PATH, "w") as f:
        f.write(f'protocol = "{state["protocol"]}"\n')
        f.write(f'semtech_server = "{state["semtech_server"]}"\n')
        f.write(f'semtech_port = {state["semtech_port"]}\n')

def detect_local_ns():
    """Detect if built-in NS is running on host.
    Checks if mosquitto is reachable on Docker bridge IP:1883 (TCP).
    Mosquitto on Docker bridge is always present when loraserver is running.

    IMPORTANT: Built-in NS always uses Semtech UDP path (not mqtt-forwarder),
    because ChirpStack v4 mqtt-forwarder uses MQTT v5 which is incompatible
    with gateway mosquitto v1.4.x (only supports v3.1.1).
    """
    import socket as _sock
    try:
        s = _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM)
        s.settimeout(2)
        s.connect((DOCKER_BRIDGE_IP, 1883))
        s.close()
        return True
    except Exception:
        return False

def configure_local_ns_forwarder():
    """Auto-configure semtech-udp-forwarder for local NS.
    Creates mesh_forwarder.toml pointing to LGB on Docker bridge.
    Writes persistent state so entrypoint can restore on restart.
    """
    cfg_path = "/opt/chirpstack/mesh_forwarder.toml"
    try:
        with open(cfg_path, "w") as f:
            f.write(f'semtech_server = "{DOCKER_BRIDGE_IP}"\nsemtech_port = 1700\n')
        write_forwarder_state(protocol="udp", semtech_server=DOCKER_BRIDGE_IP, semtech_port=1700)
        log.info("Local NS detected: configured semtech-udp-forwarder → %s:1700 (state saved)", DOCKER_BRIDGE_IP)
        return True
    except Exception as e:
        log.warning("Failed to configure local NS forwarder: %s", e)
        return False
# Also check mesh_config.json (source of truth) in case env var is stale
try:
    _mc = json.loads(open(MESH_CONFIG_PATH).read())
    if _mc.get("role") == "border":
        IS_BORDER = True
except Exception:
    pass
GW_LABEL = "Border" if IS_BORDER else "Relay"

def is_border():
    """Dynamic check: reads mesh_config.json each time (supports runtime role switching)."""
    try:
        mc = json.loads(open(MESH_CONFIG_PATH).read())
        return mc.get("role") == "border"
    except Exception:
        pass
    return IS_BORDER  # fallback to startup value

_buf  = collections.deque(maxlen=2000)
_lock = threading.Lock()
_gen  = 0
SKIP  = ["gps_ref_valid", "Could not get GPS"]

def _push(line, level="INFO"):
    global _gen
    ts = time.strftime("%H:%M:%S")
    with _lock:
        _gen += 1
        _buf.append({"ts": ts, "line": line.rstrip(), "level": level, "_seq": _gen})

def _skip(line):
    if any(s in line for s in SKIP):
        return True
    # Filter Flask/HTTP noise (access logs, startup banners)
    if any(s in line for s in [
        '"GET /api/', '"POST /api/', '"GET / ', '"GET /login',
        '"GET /favicon', 'Serving Flask', 'Debug mode',
        'Running on http', 'Press CTRL+C', 'WARNING: This is a development',
        '\x1b[',  # ANSI color codes from werkzeug
    ]):
        return True
    return False

def _tail_mesh_log():
    """Tail /tmp/mesh.log (all supervisord process output)."""
    while True:
        try:
            p = subprocess.Popen(["tail", "-F", "-n", "500", "/tmp/mesh.log"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            for raw in p.stdout:
                line = raw.decode("utf-8", errors="replace").rstrip()
                if line and not _skip(line):
                    level = "ERROR" if "ERROR" in line else "WARN" if "WARN" in line else "INFO"
                    _push(line, level)
            p.wait()
        except Exception as e:
            _push(f"[stream error] {e}", "ERROR")
        time.sleep(3)

threading.Thread(target=_tail_mesh_log, daemon=True).start()

# ── Config helpers ──

def _tv(c, k):
    m = re.search(rf"^\s*{re.escape(k)}\s*=\s*(.+?)\s*$", c, re.MULTILINE)
    if not m: return None
    v = m.group(1).strip()
    return v[1:-1] if (v.startswith('"') and v.endswith('"')) else v

def _sv(c, k, val):
    pat = rf"^(\s*{re.escape(k)}\s*=\s*).+$"
    if isinstance(val, bool):
        rep = r"\g<1>" + ("true" if val else "false")
    elif isinstance(val, (int, float)):
        rep = r"\g<1>" + str(val)
    elif isinstance(val, str) and val.startswith("["):
        rep = r"\g<1>" + val
    else:
        rep = r'\g<1>"' + val + '"'
    return re.sub(pat, rep, c, count=1, flags=re.MULTILINE)

def read_mesh_cfg():
    try:
        cfg = json.loads(open(MESH_CONFIG_PATH).read())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    role = cfg.get("role", "relay")
    freqs_str = cfg.get("mesh-freqs", "")
    freqs = [f.strip() for f in freqs_str.split(",") if f.strip()] if freqs_str else []
    return {
        "signing_key": cfg.get("signing-key", ""),
        "border_gateway": role == "border",
        "heartbeat_interval": cfg.get("heartbeat-interval", "5m"),
        "max_hop_count": int(cfg.get("max-hop-count", 1)),
        "border_ignore_direct": cfg.get("border-ignore-direct", False),
        "frequencies": freqs,
        "tx_power": int(cfg.get("tx-power", 16)),
        "spreading_factor": int(cfg.get("mesh-sf", 7)),
        "bandwidth": int(cfg.get("mesh-bw", 125000)),
    }

def write_mesh_cfg(cfg):
    try:
        existing = json.loads(open(MESH_CONFIG_PATH).read())
    except (FileNotFoundError, json.JSONDecodeError):
        existing = {}
    role = "border" if cfg.get("border_gateway", False) else "relay"
    freqs = cfg.get("frequencies", [])
    out = {
        "role": role,
        "signing-key": cfg.get("signing_key", existing.get("signing-key", "")),
        "mesh-freqs": ",".join(str(f) for f in freqs),
        "mesh-sf": str(int(cfg.get("spreading_factor", 7))),
        "mesh-bw": str(int(cfg.get("bandwidth", 125000))),
        "tx-power": str(int(cfg.get("tx_power", 16))),
    }
    # Preserve optional fields if present in request or existing config
    for old_key, new_key in [
        ("heartbeat_interval", "heartbeat-interval"),
        ("max_hop_count", "max-hop-count"),
        ("border_ignore_direct", "border-ignore-direct"),
    ]:
        val = cfg.get(old_key)
        if val is not None:
            out[new_key] = val if not isinstance(val, (int, float, bool)) else val
        elif new_key in existing:
            out[new_key] = existing[new_key]
    with open(MESH_CONFIG_PATH, "w") as f:
        json.dump(out, f, indent=2)
    return True

def read_mqtt_cfg():
    """Read MQTT forwarder config (Border only)."""
    try: c = open(MQTT_CONFIG_PATH).read()
    except FileNotFoundError: return {}
    server = _tv(c, "server") or "tcp://192.168.45.38:1884"
    # server may be quoted
    if server.startswith('"'): server = server.strip('"')
    return {
        "mqtt_server": server,
        "mqtt_topic_prefix": _tv(c, "topic_prefix") or "eu868",
        "mqtt_username": _tv(c, "username") or "",
        "mqtt_password": _tv(c, "password") or "",
        "mqtt_qos": int(_tv(c, "qos") or 0),
        "mqtt_json": _tv(c, "json") == "true",
    }

def write_mqtt_cfg(cfg):
    try: c = open(MQTT_CONFIG_PATH).read()
    except FileNotFoundError: return False
    c = _sv(c, "server",       cfg.get("mqtt_server", "tcp://192.168.45.38:1884"))
    c = _sv(c, "topic_prefix", cfg.get("mqtt_topic_prefix", "eu868"))
    c = _sv(c, "username",     cfg.get("mqtt_username", ""))
    c = _sv(c, "password",     cfg.get("mqtt_password", ""))
    c = _sv(c, "qos",          int(cfg.get("mqtt_qos", 0)))
    c = _sv(c, "json",         cfg.get("mqtt_json", False))
    open(MQTT_CONFIG_PATH, "w").write(c)
    return True

def svc_status():
    try:
        out = subprocess.run(
            ["supervisorctl", "-c", "/etc/supervisord.conf", "status"],
            capture_output=True, timeout=5).stdout.decode()
        s = {}
        for line in out.strip().split("\n"):
            p = line.split()
            if len(p) >= 2:
                s[p[0]] = {"state": p[1], "pid": None}
                for x in p[2:]:
                    if x.startswith("pid"): s[p[0]]["pid"] = x.replace("pid", "").strip(",")
        return s
    except Exception as e:
        return {"error": str(e)}

def restart_svc(name):
    try:
        subprocess.check_output(
            ["supervisorctl", "-c", "/etc/supervisord.conf", "restart", name],
            stderr=subprocess.STDOUT, timeout=10)
        return True
    except Exception:
        return False

# ── HTML ──

HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en" translate="no">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LoRa Mesh Monitor</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Helvetica Neue",Helvetica,Arial,"PingFang SC","Microsoft YaHei",sans-serif;background:#f7f8f8;color:#333;display:flex;flex-direction:column;height:100vh;overflow:hidden;-webkit-font-smoothing:antialiased}
.hdr{background:#fff;border-bottom:1px solid #e0e0e0;padding:0 20px;height:50px;display:flex;align-items:center;gap:10px;flex-shrink:0;box-shadow:0 1px 4px rgba(0,0,0,.08)}
.hdr h1{font-size:16px;font-weight:600;color:#3b5675}
.badge{padding:2px 10px;border-radius:10px;font-size:11px;font-weight:600}
.bok{background:#52c41a;color:#fff}.bwarn{background:#d98f42;color:#fff}
.brole{background:#1f82c1;color:#fff}
.nav{display:flex;background:#fff;border-bottom:2px solid #e0e0e0;padding:0 20px;flex-shrink:0}
.nb{padding:10px 18px;cursor:pointer;border-bottom:2px solid transparent;font-size:14px;color:#666;background:none;border-top:none;border-left:none;border-right:none;margin-bottom:-2px}
.nb.act{border-bottom-color:#1f82c1;color:#1f82c1;font-weight:600}
.content{flex:1;overflow:hidden;display:flex;flex-direction:column;min-height:0}
.pane{display:none;flex:1;overflow-y:auto;padding:16px 20px;min-height:0}
.pane.act{display:block}
#pane-logs.act{display:flex;flex-direction:column;padding:12px}

/* log pane — keep terminal dark */
.log-wrap{display:flex;flex-direction:column;flex:1;border:1px solid #d0d5dd;border-radius:4px;overflow:hidden}
.log-hdr{padding:8px 12px;font-size:13px;font-weight:600;display:flex;align-items:center;gap:8px;border-bottom:1px solid #444;flex-shrink:0;background:#3b5675;color:#fff}
.log-hdr .dot{width:8px;height:8px;border-radius:50%;background:#52c41a}
.log-hdr .dot.paused{background:#d98f42}
.log-toolbar{display:flex;gap:6px;margin-left:auto}
.log-toolbar button{background:rgba(255,255,255,.15);border:1px solid rgba(255,255,255,.25);color:#fff;padding:4px 10px;border-radius:3px;cursor:pointer;font-size:11px;font-weight:600}
.log-toolbar button:hover{background:rgba(255,255,255,.25)}
.log-toolbar button.active{background:#d98f42;border-color:#d98f42}
.lb{flex:1;overflow-y:auto;padding:6px 8px;font-family:Monaco,Menlo,Consolas,monospace;font-size:12px;background:#1e2a3a;color:#c8d6e5;line-height:1.6}
.lb .ts{color:#5a6a7a;margin-right:5px;user-select:none;font-size:11px}
.l-err{color:#f33737}.l-warn{color:#d98f42}
.l-relay{color:#48bde9;background:rgba(31,130,193,.12)}
.l-up{color:#52c41a}.l-hb{color:#d98f42}
.log-footer{padding:4px 12px;font-size:11px;color:#999;background:#f0f2f3;border-top:1px solid #d0d5dd;display:flex;justify-content:space-between;flex-shrink:0}

/* config — UG65 light cards */
.card{background:#fff;border:1px solid #d0d5dd;border-radius:4px;margin-bottom:14px;overflow:hidden}
.ch{padding:10px 14px;border-bottom:1px solid #e0e0e0;font-size:14px;font-weight:600;color:#3b5675;background:#f0f2f3}
.cb{padding:16px}
.fg{display:flex;flex-direction:column;gap:4px;margin-bottom:12px}
.fg label{font-size:12px;color:#3e5066;font-weight:600}
.fg input,.fg select{background:#fff;border:1px solid #8a949c;color:#333;padding:5px 8px;border-radius:2px;font-size:13px;height:30px}
.fg input:focus,.fg select:focus{outline:none;border-color:#1f82c1}
.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.full{grid-column:1/-1}
.btn{padding:6px 16px;border:none;border-radius:3px;cursor:pointer;font-size:13px;font-weight:600}
.btn-p{background:#1f82c1;color:#fff}.btn-p:hover{background:#2c97dc}
.btn-d{background:#d9534f;color:#fff}.btn-d:hover{background:#c9302c}
.btn-s{background:#fff;color:#3b5675;border:1px solid #8a949c}.btn-s:hover{background:#f0f2f3}
.brow{display:flex;gap:8px;margin-top:14px}
.sw{position:relative;width:44px;height:26px;display:inline-block}
.sw input{opacity:0;width:0;height:0}
.sl{position:absolute;cursor:pointer;inset:0;background:#b6bbc6;border-radius:26px;transition:.2s}
.sl:before{content:"";position:absolute;height:22px;width:22px;left:2px;bottom:2px;background:#fff;border-radius:50%;transition:.2s;box-shadow:0 1px 3px rgba(0,0,0,.2)}
.sw input:checked+.sl{background:#2382bf}
.sw input:checked+.sl:before{transform:translateX(18px)}
.sg{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
.si{background:#fff;border:1px solid #d0d5dd;border-radius:4px;padding:12px}
.si .n{font-size:13px;font-weight:600;color:#3b5675}.si .s{font-size:12px;margin-top:4px}
.sRUN{color:#52c41a}.sSTO,.sFAT{color:#f33737}
.hint{font-size:11px;color:#999;margin-top:2px}
.toast{position:fixed;top:14px;right:14px;padding:10px 18px;border-radius:4px;color:#fff;font-size:13px;z-index:999;display:none;box-shadow:0 2px 8px rgba(0,0,0,.15)}
.tok{background:#48bde9}.terr{background:#f33737}
.btn.loading{opacity:.6;pointer-events:none}
.btn.loading::after{content:"";display:inline-block;width:12px;height:12px;margin-left:6px;border:2px solid #fff;border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite;vertical-align:middle}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="hdr">
  <svg width="22" height="22" viewBox="0 0 24 24" fill="#1f82c1"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
  <h1>LoRa Mesh Monitor</h1>
  <span class="badge brole" id="roleBadge"></span>
  <span style="font-size:12px;color:#666;font-family:monospace" id="euiLabel"></span>
  <span class="badge bok" id="bdg">Loading</span>
</div>
<div class="nav">
  <button class="nb act" onclick="showPane('logs',this)">Logs</button>
  <button class="nb" onclick="showPane('config',this)">Config</button>
  <button class="nb" onclick="showPane('status',this)">Status</button>
</div>
<div class="content">

<!-- LOG PANE -->
<div class="pane act" id="pane-logs">
  <div class="log-wrap">
    <div class="log-hdr">
      <span class="dot" id="logDot"></span>
      <span id="logTitle">Gateway Logs</span>
      <div class="log-toolbar">
        <button id="btnPause" onclick="togglePause()">⏸ Pause</button>
        <button onclick="downloadLogs()">⬇ Download</button>
        <button onclick="clearLogs()">✕ Clear</button>
      </div>
    </div>
    <div class="lb" id="logBox"></div>
    <div class="log-footer">
      <span id="logCount">0 lines</span>
      <span id="logStatus">polling...</span>
    </div>
  </div>
</div>

<!-- CONFIG PANE -->
<div class="pane" id="pane-config">
  <!-- Mesh config (both roles) -->
  <div class="card">
    <div class="ch">Mesh Configuration</div>
    <div class="cb">
      <form onsubmit="saveMeshCfg(event)">
        <div class="row">
          <div class="fg"><label>Role</label>
            <select id="role"><option value="relay">Relay Gateway</option><option value="border">Border Gateway</option></select>
            <span class="hint">Border forwards to NS via MQTT; Relay forwards to next hop via LoRa Mesh. Services auto-managed on switch.</span>
          </div>
          <div class="fg"><label>Max Hop Count</label>
            <input type="number" id="hops" min="1" max="8" value="1">
            <span class="hint">Max relay hops before Border rejects (1-8)</span>
          </div>
        </div>
        <div class="fg"><label>Signing Key (AES128 HEX)</label>
          <input id="skey" maxlength="32" pattern="[0-9a-fA-F]{32}" placeholder="00112233445566778899aabbccddeeff">
          <span class="hint">32 hex characters (0-9, a-f). Must match on every Mesh node</span>
        </div>
        <div class="fg"><label>Mesh Frequencies (Hz, comma-separated)</label>
          <input id="freqs" placeholder="868100000,868300000,868500000" pattern="[0-9,\s]+">
          <span class="hint">Mesh relay frequencies. Independent from sensor RX channels — changing these does not affect sensor reception</span>
        </div>
        <div class="row">
          <div class="fg"><label>TX Power (dBm)</label>
            <input type="number" id="txpow" min="0" max="27" step="1">
            <span class="hint">0-27 dBm EIRP</span>
          </div>
          <div class="fg"><label>Heartbeat Interval</label>
            <input id="hb" placeholder="5m" pattern="[0-9]+[smh]">
            <span class="hint">e.g. 30s, 5m, 1h</span>
          </div>
          <div class="fg"><label>Spreading Factor</label>
            <select id="sf"><option value="7">SF7</option><option value="8">SF8</option><option value="9">SF9</option><option value="10">SF10</option><option value="11">SF11</option><option value="12">SF12</option></select>
          </div>
          <div class="fg"><label>Bandwidth</label>
            <select id="bw"><option value="125000">125 kHz</option><option value="250000">250 kHz</option><option value="500000">500 kHz</option></select>
          </div>
        </div>
        <!-- Border-only: ignore direct -->
        <div id="borderDirectBlock" class="fg" style="flex-direction:row;align-items:center;gap:10px;margin-top:8px;display:none">
          <label class="sw"><input type="checkbox" id="ign"><span class="sl"></span></label>
          <div>
            <div style="font-size:13px">Ignore Direct Uplinks</div>
            <div class="hint">Border only processes frames relayed via Mesh nodes</div>
          </div>
        </div>
        <div class="brow">
          <button type="submit" class="btn btn-p" id="meshSaveBtn">Save &amp; Restart Mesh</button>
          <button type="button" class="btn btn-s" onclick="loadAllCfg()">Reset</button>
        </div>
      </form>
    </div>
  </div>

  <!-- Forwarding config (Border only) -->
  <div class="card" id="mqttCard" style="display:none">
    <div class="ch">Forwarding Protocol (Border → Network Server)</div>
    <div class="cb">
      <div class="fg"><label>Protocol</label>
        <select id="fwdProto" onchange="onProtoChange(this.value)">
          <option value="mqtt">ChirpStack MQTT</option>
          <option value="udp">Semtech UDP</option>
        </select>
        <span class="hint">ChirpStack MQTT for ChirpStack v4 NS. Semtech UDP for TTN, built-in NS, or any Semtech-compatible server.</span>
      </div>

      <!-- MQTT fields -->
      <div id="mqttFields">
        <form onsubmit="saveMqttCfg(event)">
          <div class="row">
            <div class="fg"><label>MQTT Server</label>
              <input id="mqttServer" placeholder="tcp://192.168.45.38:1884">
            </div>
            <div class="fg"><label>Topic Prefix</label>
              <input id="mqttPrefix" placeholder="eu868">
              <span class="hint">e.g. eu868 → eu868/gateway/{id}/event/up</span>
            </div>
          </div>
          <div class="row">
            <div class="fg"><label>Username (optional)</label><input id="mqttUser" placeholder=""></div>
            <div class="fg"><label>Password (optional)</label><input id="mqttPass" type="password" placeholder=""></div>
          </div>
          <div class="row">
            <div class="fg"><label>QoS</label>
              <select id="mqttQos"><option value="0">0 — At most once</option><option value="1">1 — At least once</option><option value="2">2 — Exactly once</option></select>
            </div>
            <div class="fg" style="flex-direction:row;align-items:center;gap:10px;margin-top:18px">
              <label class="sw"><input type="checkbox" id="mqttJson"><span class="sl"></span></label>
              <div>
                <div style="font-size:13px">JSON Payload</div>
                <div class="hint">Use JSON instead of Protobuf</div>
              </div>
            </div>
          </div>
          <div class="brow">
            <button type="submit" class="btn btn-p" id="mqttSaveBtn">Save &amp; Restart Forwarder</button>
            <button type="button" class="btn btn-s" onclick="loadAllCfg()">Reset</button>
          </div>
        </form>
      </div>

      <!-- Semtech UDP fields -->
      <div id="udpFields" style="display:none">
        <form onsubmit="saveUdpCfg(event)">
          <div class="row">
            <div class="fg"><label>UDP Server</label>
              <input id="udpServer" placeholder="192.168.x.x">
              <span class="hint">Host gateway IP for built-in NS (e.g. 192.168.44.201). Forwarder runs inside Docker, so 127.0.0.1 won't reach the host.</span>
            </div>
            <div class="fg"><label>UDP Port</label>
              <input type="number" id="udpPort" value="1700" min="1" max="65535">
              <span class="hint">Standard Semtech UDP port: 1700</span>
            </div>
          </div>
          <div class="brow">
            <button type="submit" class="btn btn-p" id="udpSaveBtn">Save &amp; Restart Forwarder</button>
            <button type="button" class="btn btn-s" onclick="loadAllCfg()">Reset</button>
          </div>
        </form>
      </div>
    </div>
  </div>
</div>

<!-- STATUS PANE -->
<div class="pane" id="pane-status">
  <div class="card">
    <div class="ch">Services</div>
    <div class="cb">
      <div class="sg" id="svcGrid"></div>
      <div class="brow">
        <button class="btn btn-s" onclick="loadSvc()">Refresh</button>
        <button class="btn btn-d" onclick="restartAll()">Restart All</button>
      </div>
    </div>
  </div>
  <div class="card">
    <div class="ch">Mesh Topology</div>
    <div class="cb">
      <div id="topoEmpty" style="color:#888;font-size:13px;margin:6px 0">No relays seen yet (border only)</div>
      <table id="topoTable" style="width:100%;border-collapse:collapse;font-size:13px;display:none">
        <thead><tr style="text-align:left;color:#888">
          <th style="padding:4px 6px">Relay</th><th style="padding:4px 6px">Path</th>
          <th style="padding:4px 6px">Hop</th><th style="padding:4px 6px">Last Seen</th><th style="padding:4px 6px">Status</th>
        </tr></thead>
        <tbody id="topoBody"></tbody>
      </table>
      <div class="brow"><button class="btn btn-s" onclick="loadTopo()">Refresh</button></div>
    </div>
  </div>
</div>

</div>
<div class="toast" id="toast"></div>

<script>
const MAX_LINES = 500;
const IS_BORDER = __IS_BORDER__;
let lastIdx = 0;
let lineCount = 0;
let paused = false;
let polling = false;
let allLines = [];  // for download

function showPane(id, btn) {
  document.querySelectorAll(".pane").forEach(p => p.classList.remove("act"));
  document.querySelectorAll(".nb").forEach(b => b.classList.remove("act"));
  document.getElementById("pane-"+id).classList.add("act");
  btn.classList.add("act");
}

function toast(msg, ok) {
  const t = document.getElementById("toast");
  t.textContent = msg;
  t.className = "toast " + (ok ? "tok" : "terr");
  t.style.display = "block";
  setTimeout(() => t.style.display = "none", 3000);
}

function colorize(line) {
  const l = line.toLowerCase();
  if (l.includes("error") || l.includes("panic") || l.includes("fatal")) return "l-err";
  if (l.includes("warn")) return "l-warn";
  if (l.includes("proxying lorawan") || l.includes("mesh frame received") || l.includes("sending mesh frame")) return "l-relay";
  if (l.includes("sending uplink event") || l.includes("received uplink frame")) return "l-up";
  if (l.includes("heartbeat") || l.includes("state/conn")) return "l-hb";
  return "";
}

function esc(s) {
  return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

function appendLines(items) {
  const box = document.getElementById("logBox");
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  items.forEach(item => {
    allLines.push(item.ts + " " + item.line);
    const d = document.createElement("div");
    const cls = colorize(item.line);
    if (cls) d.classList.add(cls);
    d.innerHTML = "<span class='ts'>" + item.ts + "</span>" + esc(item.line);
    box.appendChild(d);
  });
  while (box.children.length > MAX_LINES) box.removeChild(box.firstChild);
  if (allLines.length > MAX_LINES * 2) allLines = allLines.slice(-MAX_LINES);
  lineCount += items.length;
  document.getElementById("logCount").textContent = lineCount + " lines";
  if (atBottom) box.scrollTop = box.scrollHeight;
}

async function pollLogs() {
  if (paused || polling) return;
  polling = true;
  try {
    const res = await fetch("/api/logs/stream?since=" + lastIdx);
    const data = await res.json();
    lastIdx = data.next;
    if (data.entries.length) {
      appendLines(data.entries);
      document.getElementById("logDot").classList.remove("paused");
    }
    document.getElementById("logStatus").textContent = "last poll: " + new Date().toLocaleTimeString();
  } catch(e) {
    document.getElementById("logStatus").textContent = "error: " + e.message;
  }
  polling = false;
}

function togglePause() {
  paused = !paused;
  const btn = document.getElementById("btnPause");
  const dot = document.getElementById("logDot");
  if (paused) {
    btn.textContent = "▶ Resume";
    btn.classList.add("active");
    dot.classList.add("paused");
    document.getElementById("logStatus").textContent = "paused";
  } else {
    btn.textContent = "⏸ Pause";
    btn.classList.remove("active");
    dot.classList.remove("paused");
  }
}

function downloadLogs() {
  const content = allLines.join("\n");
  const blob = new Blob([content], {type: "text/plain"});
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "mesh-log-" + new Date().toISOString().slice(0,10) + ".txt";
  a.click();
  URL.revokeObjectURL(url);
  toast("Downloaded " + allLines.length + " lines", true);
}

function clearLogs() {
  document.getElementById("logBox").innerHTML = "";
  allLines = [];
  lineCount = 0;
  document.getElementById("logCount").textContent = "0 lines";
}

// ── Config ──

async function loadMeshCfg() {
  const r = await fetch("/api/config/mesh");
  const c = await r.json();
  const isBorder = c.border_gateway;
  document.getElementById("role").value = isBorder ? "border" : "relay";
  document.getElementById("roleBadge").textContent = isBorder ? "Border" : "Relay";
  document.getElementById("skey").value = c.signing_key || "";
  document.getElementById("hops").value = c.max_hop_count || 1;
  document.getElementById("freqs").value = (c.frequencies||[]).join(",");
  document.getElementById("txpow").value = c.tx_power || 16;
  document.getElementById("hb").value = c.heartbeat_interval || "5m";
  document.getElementById("sf").value = String(c.spreading_factor||7);
  document.getElementById("bw").value = String(c.bandwidth||125000);
  // Show border-specific options based on config, not just env
  if (c.border_gateway) {
    document.getElementById("borderDirectBlock").style.display = "flex";
    document.getElementById("ign").checked = c.border_ignore_direct||false;
  }
}

async function loadBackendCfg() {
  try {
    const r = await fetch("/api/config/backend");
    const c = await r.json();
    document.getElementById("fwdProto").value = c.backend || "udp";
    onProtoChange(c.backend || "udp");
    document.getElementById("udpServer").value = c.server_host || "";
    document.getElementById("udpPort").value = c.server_port || 1700;
    document.getElementById("mqttServer").value = c.mqtt_server || "";
    document.getElementById("mqttPrefix").value = c.mqtt_prefix || "";
    document.getElementById("mqttUser").value = c.mqtt_username || "";
    document.getElementById("mqttPass").value = c.mqtt_password || "";
  } catch(e) {}
}

function loadAllCfg() { loadMeshCfg(); loadBackendCfg(); }

function setLoading(btnId, loading) {
  const btn = document.getElementById(btnId);
  if (loading) { btn.classList.add("loading"); btn.disabled = true; }
  else { btn.classList.remove("loading"); btn.disabled = false; }
}

async function saveMeshCfg(e) {
  e.preventDefault();
  const skey = document.getElementById("skey").value;
  if (skey && !/^[0-9a-fA-F]{32}$/.test(skey)) {
    toast("Signing Key must be exactly 32 hex characters (0-9, a-f)", false);
    return;
  }
  const freqs = document.getElementById("freqs").value.split(",").map(s=>s.trim()).filter(Boolean);
  if (freqs.some(f => !/^\d+$/.test(f))) {
    toast("Frequencies must be numeric (Hz), e.g. 868100000", false);
    return;
  }
  const hb = document.getElementById("hb").value;
  if (hb && !/^\d+[smh]$/.test(hb)) {
    toast("Heartbeat interval must be a number followed by s/m/h, e.g. 30s, 5m", false);
    return;
  }
  const txpow = parseInt(document.getElementById("txpow").value);
  if (isNaN(txpow) || txpow < 0 || txpow > 27) {
    toast("TX Power must be 0-27 dBm", false);
    return;
  }
  const hops = parseInt(document.getElementById("hops").value);
  if (isNaN(hops) || hops < 1 || hops > 8) {
    toast("Max Hop Count must be 1-8", false);
    return;
  }
  const isBorder = document.getElementById("role").value === "border";
  const cfg = {
    border_gateway: isBorder,
    signing_key: skey,
    max_hop_count: hops,
    frequencies: freqs,
    tx_power: txpow,
    heartbeat_interval: hb,
    spreading_factor: parseInt(document.getElementById("sf").value),
    bandwidth: parseInt(document.getElementById("bw").value),
  };
  if (isBorder) cfg.border_ignore_direct = document.getElementById("ign").checked;
  setLoading("meshSaveBtn", true);
  try {
    const r = await fetch("/api/config/mesh",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(cfg)});
    const d = await r.json();
    if (d.ok) toast("Mesh config saved & mesh-forwarder restarted", true);
    else toast("Error: "+(d.error||"unknown"), false);
  } catch(e) {
    toast("Request failed: "+e.message, false);
  }
  setLoading("meshSaveBtn", false);
}

async function saveMqttCfg(e) {
  e.preventDefault();
  const server = document.getElementById("mqttServer").value;
  if (!server) { toast("MQTT Server is required", false); return; }
  setLoading("mqttSaveBtn", true);
  try {
    const cfg = {
      backend: "mqtt",
      mqtt_server: server,
      mqtt_username: document.getElementById("mqttUser").value,
      mqtt_password: document.getElementById("mqttPass").value,
      mqtt_prefix: document.getElementById("mqttPrefix").value,
    };
    const r = await fetch("/api/config/backend",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(cfg)});
    const d = await r.json();
    if (d.ok) toast("ChirpStack MQTT backend saved & forwarder restarted", true);
    else toast("Error: "+(d.error||"unknown"), false);
  } catch(e) {
    toast("Request failed: "+e.message, false);
  }
  setLoading("mqttSaveBtn", false);
}

function onProtoChange(proto) {
  document.getElementById("mqttFields").style.display = proto === "mqtt" ? "block" : "none";
  document.getElementById("udpFields").style.display = proto === "udp" ? "block" : "none";
}

async function saveUdpCfg(e) {
  e.preventDefault();
  const server = document.getElementById("udpServer").value;
  const port = parseInt(document.getElementById("udpPort").value);
  if (!server) { toast("UDP Server is required", false); return; }
  if (isNaN(port) || port < 1 || port > 65535) { toast("Port must be 1-65535", false); return; }
  setLoading("udpSaveBtn", true);
  try {
    const r = await fetch("/api/config/backend",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({backend:"udp", server_host:server, server_port:port})});
    const d = await r.json();
    if (d.ok) toast("Semtech UDP backend saved & forwarder restarted", true);
    else toast("Error: "+(d.error||"unknown"), false);
  } catch(e) {
    toast("Request failed: "+e.message, false);
  }
  setLoading("udpSaveBtn", false);
}

async function loadSvc() {
  const r = await fetch("/api/status");
  const d = await r.json();
  const g = document.getElementById("svcGrid");
  const bdg = document.getElementById("bdg");
  let ok = true;
  g.innerHTML = "";
  const optionalStopped = ["semtech-udp-forwarder", "mqtt-forwarder"];
  for (const [n,i] of Object.entries(d)) {
    if (n==="error") { ok=false; g.innerHTML += "<div class='si'><div class='n'>"+n+"</div><div class='s sERR'>Error</div></div>"; continue; }
    if (i.state !== "RUNNING" && !optionalStopped.includes(n)) ok=false;
    g.innerHTML += "<div class='si'><div class='n'>"+n+"</div><div class='s s"+i.state.slice(0,3)+"'>"+i.state+(i.pid?" ("+i.pid+")":"")+"</div></div>";
  }
  bdg.textContent = ok ? "All Running" : "Issues";
  bdg.className = "badge " + (ok ? "bok" : "bwarn");
}

async function restartAll() {
  await fetch("/api/restart/all",{method:"POST"});
  toast("Restarting services...", true);
  setTimeout(loadSvc, 4000);
}

async function loadTopo() {
  let d;
  try { const r = await fetch("/api/mesh-topology"); d = await r.json(); } catch(e) { return; }
  const t = document.getElementById("topoTable");
  const b = document.getElementById("topoBody");
  const empty = document.getElementById("topoEmpty");
  const relays = d.relays || [];
  if (!relays.length) { t.style.display = "none"; empty.style.display = "block"; return; }
  t.style.display = "table"; empty.style.display = "none";
  b.innerHTML = relays.map(r => {
    const pathStr = r.path.length
      ? r.path.map(p => p.relayId + " (" + p.rssi + "dBm," + p.snr + "dB)").join(" &rarr; ")
      : "direct";
    const st = r.online ? "<span style='color:#16a34a'>online</span>" : "<span style='color:#dc2626'>offline</span>";
    const ls = r.last_seen ? new Date(r.last_seen).toLocaleTimeString() : "-";
    return "<tr><td style='padding:4px 6px;font-family:monospace'>" + r.relay_id + "</td>" +
      "<td style='padding:4px 6px;font-family:monospace'>" + pathStr + "</td>" +
      "<td style='padding:4px 6px'>" + r.hop + "</td>" +
      "<td style='padding:4px 6px'>" + ls + "</td>" +
      "<td style='padding:4px 6px'>" + st + "</td></tr>";
  }).join("");
}

// Init
document.getElementById("mqttCard").style.display = IS_BORDER ? "block" : "none";

// Load gateway EUI
(async function() {
  try {
    const r = await fetch("/api/gateway-info");
    const d = await r.json();
    if (d.eui) document.getElementById("euiLabel").textContent = "EUI: " + d.eui;
  } catch(e) {}
})();

// Toggle border-specific UI when role changes
document.getElementById("role").addEventListener("change", function() {
  const isBorder = this.value === "border";
  document.getElementById("roleBadge").textContent = isBorder ? "Border" : "Relay";
  document.getElementById("mqttCard").style.display = isBorder ? "block" : "none";
  document.getElementById("borderDirectBlock").style.display = isBorder ? "flex" : "none";
  document.getElementById("mqttCard").style.display = isBorder ? "block" : "none";
});

loadAllCfg();
loadSvc();
loadTopo();
setInterval(pollLogs, 1500);
setInterval(loadSvc, 15000);
setInterval(loadTopo, 15000);
pollLogs();
</script>
</body>
</html>"""

# Replace placeholders
HTML_PAGE = HTML_PAGE.replace("__GW_LABEL__", GW_LABEL)
HTML_PAGE = HTML_PAGE.replace("__IS_BORDER__", "true" if is_border() else "false")

# ── Login page ──

LOGIN_PAGE = r"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LoRa Mesh - Login</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;background:#1e2a3a;display:flex;align-items:center;justify-content:center;height:100vh}
.card{background:#fff;border-radius:8px;padding:32px;width:340px;box-shadow:0 4px 24px rgba(0,0,0,.3)}
.card h2{color:#3b5675;margin-bottom:20px;font-size:18px;text-align:center}
.fg{margin-bottom:14px}
.fg label{display:block;font-size:12px;color:#666;margin-bottom:4px;font-weight:600}
.fg input{width:100%;padding:8px 10px;border:1px solid #d0d5dd;border-radius:4px;font-size:14px}
.fg input:focus{outline:none;border-color:#1f82c1}
.btn{width:100%;padding:10px;background:#1f82c1;color:#fff;border:none;border-radius:4px;font-size:14px;font-weight:600;cursor:pointer}
.btn:hover{background:#2c97dc}
.err{color:#e74c3c;font-size:12px;margin-top:8px;text-align:center;display:none}
</style></head><body>
<div class="card">
<h2>LoRa Mesh Monitor</h2>
<form id="f">
<div class="fg"><label>Username</label><input id="u" value="admin" autocomplete="username"></div>
<div class="fg"><label>Password</label><input id="p" type="password" autocomplete="current-password"></div>
<button class="btn" type="submit">Login</button>
<div class="err" id="e"></div>
</form></div>
<script>
// AES-128-CBC encrypt (pure JS, works over HTTP unlike WebCrypto)
const AES_KEY=[0x34,0x38,0x32,0x39,0x31,0x37,0x33,0x30,0x35,0x31,0x36,0x34,0x37,0x38,0x32,0x33];
const AES_IV=[0x37,0x36,0x30,0x33,0x39,0x31,0x32,0x38,0x34,0x35,0x30,0x39,0x31,0x37,0x33,0x36];
// Minimal AES-128-CBC encrypt using SubtleCrypto when available, fallback to server-side
async function encryptPwd(pwd){
  // Try WebCrypto first (works on HTTPS/localhost)
  if(window.crypto&&crypto.subtle){
    try{
      const ck=await crypto.subtle.importKey("raw",new Uint8Array(AES_KEY),{name:"AES-CBC"},false,["encrypt"]);
      const enc=await crypto.subtle.encrypt({name:"AES-CBC",iv:new Uint8Array(AES_IV)},ck,new TextEncoder().encode(pwd));
      return btoa(String.fromCharCode(...new Uint8Array(enc)));
    }catch(e){}
  }
  // Fallback: send plaintext (server will try direct verification)
  return pwd;
}
document.getElementById("f").onsubmit=async(e)=>{
  e.preventDefault();
  const u=document.getElementById("u").value;
  const p=document.getElementById("p").value;
  const ep=await encryptPwd(p);
  try{
    const r=await fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({username:u,password:ep})});
    const d=await r.json();
    if(d.status===0){window.location.href="/";}
    else{const el=document.getElementById("e");el.textContent=d.message||"Login failed";el.style.display="block";}
  }catch(err){document.getElementById("e").textContent="Network error";document.getElementById("e").style.display="block";}
};
</script></body></html>"""

# ── Routes ──

@app.route("/login")
def login_page():
    if _is_authenticated():
        return redirect("/")
    return LOGIN_PAGE, 200

@app.route("/")
def index():
    return HTML_PAGE, 200, {
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Expires": "0"
    }

@app.route("/api/logs/stream")
def api_stream():
    since = request.args.get("since", 0, type=int)
    with _lock:
        entries = [{"ts": e["ts"], "line": e["line"], "level": e["level"]}
                    for e in _buf if e["_seq"] > since]
        next_seq = _gen
    return jsonify({"next": next_seq, "entries": entries})

@app.route("/api/config/mesh", methods=["GET"])
def api_get_mesh():
    return jsonify(read_mesh_cfg())

@app.route("/api/config/mesh", methods=["POST"])
def api_set_mesh():
    data = request.json or {}
    skey = data.get("signing_key", "")
    if skey and not re.match(r'^[0-9a-fA-F]{32}$', skey):
        return jsonify({"ok": False, "error": "signing_key must be exactly 32 hex characters"}), 400
    ok = write_mesh_cfg(data)
    if ok:
        new_border = data.get("border_gateway", False)
        sc = ["supervisorctl", "-c", "/etc/supervisord.conf"]
        try:
            subprocess.run(sc + ["restart", "mesh-forwarder"], timeout=10)
        except Exception:
            pass
        # Auto-manage forwarder services based on role
        if new_border:
            # Border: detect local NS and choose appropriate forwarder
            local_ns = detect_local_ns()
            if local_ns:
                # Local NS detected: ALWAYS use Semtech UDP path
                # (mqtt-forwarder uses MQTT v5, incompatible with gateway mosquitto 1.4.x)
                configure_local_ns_forwarder()
                subprocess.run(sc + ["start", "semtech-udp-forwarder"], timeout=5, capture_output=True)
                subprocess.run(sc + ["stop", "mqtt-forwarder"], timeout=5, capture_output=True)
                _write_forwarder_protocol("udp")
            else:
                # External NS: use saved protocol preference
                try:
                    proto = open("/opt/chirpstack/.forwarder_protocol").read().strip()
                except Exception:
                    proto = "mqtt"
                if proto == "udp":
                    subprocess.run(sc + ["start", "semtech-udp-forwarder"], timeout=5, capture_output=True)
                    subprocess.run(sc + ["stop", "mqtt-forwarder"], timeout=5, capture_output=True)
                else:
                    subprocess.run(sc + ["start", "mqtt-forwarder"], timeout=5, capture_output=True)
                    subprocess.run(sc + ["stop", "semtech-udp-forwarder"], timeout=5, capture_output=True)
        else:
            # Relay: stop all forwarders
            for svc in ["mqtt-forwarder", "semtech-udp-forwarder"]:
                subprocess.run(sc + ["stop", svc], timeout=5, capture_output=True)
            write_forwarder_state(protocol="none")
    return jsonify({"ok": ok})

@app.route("/api/config/mqtt", methods=["GET"])
def api_get_mqtt():
    if not is_border():
        return jsonify({"error": "MQTT config only available on Border"}), 403
    return jsonify(read_mqtt_cfg())

@app.route("/api/config/mqtt", methods=["POST"])
def api_set_mqtt():
    if not is_border():
        return jsonify({"error": "Forwarding config only available on Border"}), 403
    ok = write_mqtt_cfg(request.json)
    if ok:
        _write_forwarder_protocol("mqtt")
        try:
            subprocess.run(["supervisorctl", "-c", "/etc/supervisord.conf", "stop", "semtech-udp-forwarder"], timeout=5)
        except Exception:
            pass
        try:
            subprocess.run(["supervisorctl", "-c", "/etc/supervisord.conf", "restart", "mqtt-forwarder"], timeout=10)
        except Exception:
            pass
    return jsonify({"ok": ok})

@app.route("/api/config/udp", methods=["GET"])
def api_get_udp():
    cfg = _read_forwarder_cfg()
    return jsonify(cfg)

@app.route("/api/config/udp", methods=["POST"])
def api_set_udp():
    if not is_border():
        return jsonify({"error": "Forwarding config only available on Border"}), 403
    data = request.json or {}
    ok = _write_udp_cfg(data)
    if ok:
        _write_forwarder_protocol("udp")
        # Stop mqtt-forwarder, start semtech-udp-forwarder
        try:
            subprocess.run(["supervisorctl", "-c", "/etc/supervisord.conf", "stop", "mqtt-forwarder"], timeout=10)
        except Exception:
            pass
        try:
            subprocess.run(["supervisorctl", "-c", "/etc/supervisord.conf", "restart", "semtech-udp-forwarder"], timeout=10)
        except Exception:
            pass
    return jsonify({"ok": ok})

# ── NS backend config (Semtech UDP or ChirpStack MQTT) ──────────────
@app.route("/api/config/backend", methods=["GET"])
def api_get_backend():
    try:
        mc = json.loads(open(MESH_CONFIG_PATH).read())
    except Exception:
        mc = {}
    return jsonify({
        "backend": mc.get("backend", "udp"),
        "server_host": mc.get("server-host", "127.0.0.1"),
        "server_port": int(mc.get("server-port", 1710)),
        "mqtt_server": mc.get("mqtt-server", "127.0.0.1:1883"),
        "mqtt_username": mc.get("mqtt-username", ""),
        "mqtt_password": mc.get("mqtt-password", ""),
        "mqtt_prefix": mc.get("mqtt-prefix", ""),
    })

@app.route("/api/config/backend", methods=["POST"])
def api_set_backend():
    if not is_border():
        return jsonify({"error": "Forwarding config only available on Border"}), 403
    data = request.get_json(silent=True) or {}
    try:
        mc = json.loads(open(MESH_CONFIG_PATH).read())
    except Exception:
        mc = {}
    backend = data.get("backend", "udp")
    mc["backend"] = backend
    if backend == "udp":
        mc["server-host"] = data.get("server_host", mc.get("server-host", "127.0.0.1"))
        mc["server-port"] = str(int(data.get("server_port", int(mc.get("server-port", 1710)))))
    else:
        # Strip scheme — pkt_mesh_fwd.js adds mqtt:// itself.
        ms = data.get("mqtt_server", mc.get("mqtt-server", "127.0.0.1:1883"))
        ms = re.sub(r'^(tcp|mqtt|ssl|mqtts)://', '', ms)
        mc["mqtt-server"] = ms
        mc["mqtt-username"] = data.get("mqtt_username", mc.get("mqtt-username", ""))
        mc["mqtt-password"] = data.get("mqtt_password", mc.get("mqtt-password", ""))
        mc["mqtt-prefix"] = data.get("mqtt_prefix", mc.get("mqtt-prefix", ""))
    try:
        open(MESH_CONFIG_PATH, "w").write(json.dumps(mc, indent=2))
    except Exception:
        return jsonify({"ok": False})
    try:
        subprocess.run(["supervisorctl", "-c", "/etc/supervisord.conf", "restart", "mesh-forwarder"], timeout=10, capture_output=True)
    except Exception:
        pass
    return jsonify({"ok": True})

def _read_forwarder_cfg():
    """Read forwarder protocol config."""
    # Try to detect host gateway IP as default (Docker default route = host)
    default_ip = ""
    try:
        import subprocess
        r = subprocess.run(["ip", "route", "show", "default"], capture_output=True, timeout=3)
        parts = r.stdout.decode().split()
        if "via" in parts:
            default_ip = parts[parts.index("via") + 1]
    except Exception:
        pass
    cfg = {"protocol": "mqtt", "semtech_server": default_ip, "semtech_port": 1700}
    try:
        c = open("/opt/chirpstack/mesh_forwarder.toml").read()
        m = re.search(r'semtech_server\s*=\s*"([^"]+)"', c)
        if m: cfg["semtech_server"] = m.group(1)
        m = re.search(r'semtech_port\s*=\s*(\d+)', c)
        if m: cfg["semtech_port"] = int(m.group(1))
        m = re.search(r'forwarder_protocol\s*=\s*"([^"]+)"', c)
        if m: cfg["protocol"] = m.group(1)
    except Exception:
        pass
    return cfg

def _write_forwarder_protocol(proto):
    """Set active protocol in mesh_forwarder.toml and persist to state file."""
    path = "/opt/chirpstack/mesh_forwarder.toml"
    try:
        c = open(path).read()
        if "forwarder_protocol" in c:
            c = _sv(c, "forwarder_protocol", proto)
        else:
            c += f'\nforwarder_protocol="{proto}"\n'
        open(path, "w").write(c)
    except Exception:
        pass
    # Persist to state file so entrypoint can restore on restart
    write_forwarder_state(protocol=proto)

def _write_udp_cfg(data):
    """Write Semtech UDP config to mesh_forwarder.toml."""
    path = "/opt/chirpstack/mesh_forwarder.toml"
    server = data.get("semtech_server", "")
    port = int(data.get("semtech_port", 1700))
    try:
        c = open(path).read() if os.path.exists(path) else ""
        # Update or append semtech_server and semtech_port
        if "semtech_server" in c:
            c = _sv(c, "semtech_server", server)
        else:
            c += f'\nsemtech_server="{server}"\n'
        if "semtech_port" in c:
            c = re.sub(r'semtech_port\s*=\s*\d+', f'semtech_port={port}', c)
        else:
            c += f'semtech_port={port}\n'
        open(path, "w").write(c)
        return True
    except Exception:
        return False

@app.route("/api/status")
def api_status():
    return jsonify(svc_status())

@app.route("/api/gateway-info")
def api_gateway_info():
    """Return gateway EUI and other identifying info."""
    eui = ""
    try:
        eui = open("/opt/chirpstack/gateway_eui.txt").read().strip().upper()
    except Exception:
        pass
    if not eui:
        eui = os.environ.get("GATEWAY_EUI", "").upper()
    return jsonify({"eui": eui, "role": "border" if is_border() else "relay"})

@app.route("/api/mesh-topology")
def api_mesh_topology():
    """Mesh topology as reported by border's heartbeat aggregation."""
    try:
        data = json.loads(open("/opt/chirpstack/mesh_topo.json").read())
        return jsonify(data)
    except Exception:
        return jsonify({"border": "", "updated": "", "intervalSec": 300, "relays": []})

@app.route("/api/restart/<name>", methods=["POST"])
def api_restart(name):
    if name == "all":
        procs = ["mesh-forwarder"]
        if is_border():
            procs.append("mqtt-forwarder")
        for p in procs:
            restart_svc(p)
        return jsonify({"ok": True})
    return jsonify({"ok": restart_svc(name)})

if __name__ == "__main__":
    # Restore forwarder state on startup
    sc = ["supervisorctl", "-c", "/etc/supervisord.conf"]
    state = read_forwarder_state()
    proto = state.get("protocol", "")

    if proto == "udp":
        # Saved state: use Semtech UDP
        try:
            # Ensure mesh_forwarder.toml has correct target
            cfg_path = "/opt/chirpstack/mesh_forwarder.toml"
            c = open(cfg_path).read() if os.path.exists(cfg_path) else ""
            if state["semtech_server"] not in c:
                with open(cfg_path, "w") as f:
                    f.write(f'semtech_server = "{state["semtech_server"]}"\n')
                    f.write(f'semtech_port = {state["semtech_port"]}\n')
            subprocess.run(sc + ["start", "semtech-udp-forwarder"], timeout=5, capture_output=True)
            subprocess.run(sc + ["stop", "mqtt-forwarder"], timeout=5, capture_output=True)
        except Exception:
            pass
    elif proto == "none":
        # Saved state: relay mode, no forwarders
        for svc in ["mqtt-forwarder", "semtech-udp-forwarder"]:
            try:
                subprocess.run(sc + ["stop", svc], timeout=5, capture_output=True)
            except Exception:
                pass
    elif is_border() and not proto:
        # No saved state + border mode: auto-detect local NS
        if detect_local_ns():
            configure_local_ns_forwarder()
            try:
                subprocess.run(sc + ["start", "semtech-udp-forwarder"], timeout=5, capture_output=True)
                subprocess.run(sc + ["stop", "mqtt-forwarder"], timeout=5, capture_output=True)
            except Exception:
                pass

    # Flask runs directly on 0.0.0.0:8088 (no nginx proxy needed).
    app.run(host="0.0.0.0", port=8088, debug=False, use_reloader=False)
