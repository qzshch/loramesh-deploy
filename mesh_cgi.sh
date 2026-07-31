#!/bin/sh
# Mesh Config CGI — served by uhttpd on port 17080 (via nginx /)
# Access: http://<gateway>/cgi-bin/mesh

CONFIG="/opt/chirpstack/mesh_config.json"

# Read current config
if [ -f "$CONFIG" ]; then
  ROLE=$(cat "$CONFIG" | grep -o '"role":"[^"]*"' | cut -d'"' -f4)
  SKEY=$(cat "$CONFIG" | grep -o '"signing-key":"[^"]*"' | cut -d'"' -f4)
  FREQS=$(cat "$CONFIG" | grep -o '"mesh-freqs":"[^"]*"' | cut -d'"' -f4)
  SF=$(cat "$CONFIG" | grep -o '"mesh-sf":"[^"]*"' | cut -d'"' -f4)
  BW=$(cat "$CONFIG" | grep -o '"mesh-bw":"[^"]*"' | cut -d'"' -f4)
  TXPWR=$(cat "$CONFIG" | grep -o '"tx-power":"[^"]*"' | cut -d'"' -f4)
fi
ROLE=${ROLE:-relay}
SKEY=${SKEY:-00112233445566778899aabbccddeeff}
FREQS=${FREQS:-903900000,904100000,904300000}
SF=${SF:-7}
BW=${BW:-125000}
TXPWR=${TXPWR:-27}

# Handle POST (save config)
if [ "$REQUEST_METHOD" = "POST" ]; then
  read -r POST_DATA
  # Parse form data
  NEW_ROLE=$(echo "$POST_DATA" | sed 's/.*role=\([^&]*\).*/\1/')
  NEW_SKEY=$(echo "$POST_DATA" | sed 's/.*signing.key=\([^&]*\).*/\1/')
  NEW_FREQS=$(echo "$POST_DATA" | sed 's/.*mesh.freqs=\([^&]*\).*/\1/')
  NEW_SF=$(echo "$POST_DATA" | sed 's/.*mesh.sf=\([^&]*\).*/\1/')
  NEW_BW=$(echo "$POST_DATA" | sed 's/.*mesh.bw=\([^&]*\).*/\1/')
  NEW_TXPWR=$(echo "$POST_DATA" | sed 's/.*tx.power=\([^&]*\).*/\1/')

  # Write config
  mkdir -p /opt/chirpstack
  cat > "$CONFIG" << CFGEOF
{
  "role": "$NEW_ROLE",
  "signing-key": "$NEW_SKEY",
  "mesh-freqs": "$NEW_FREQS",
  "mesh-sf": "$NEW_SF",
  "mesh-bw": "$NEW_BW",
  "tx-power": "$NEW_TXPWR"
}
CFGEOF

  # Restart mesh forwarder via procd
  killall node 2>/dev/null
  sleep 1
  # procd respawn will restart it

  printf "Content-Type: text/html\r\n\r\n"
  echo "<html><body style='font-family:sans-serif;background:#1a1a2e;color:#e0e0e0;padding:20px'>"
  echo "<h2 style='color:#2ecc71'>Config Saved!</h2>"
  echo "<p>Role: $NEW_ROLE | Freqs: $NEW_FREQS | SF$NEW_SF BW$NEW_BW TX${NEW_TXPWR}dBm</p>"
  echo "<p>Mesh forwarder restarting...</p>"
  echo "<p><a href='/cgi-bin/mesh' style='color:#00d4ff'>Back to Config</a></p>"
  echo "</body></html>"
  exit 0
fi

# Serve config page (GET)
printf "Content-Type: text/html\r\n\r\n"
cat << 'HTMLEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LoRa Mesh Config</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,sans-serif;background:#1a1a2e;color:#e0e0e0;padding:20px}
h1{color:#00d4ff;margin-bottom:20px}
.card{background:#16213e;border-radius:8px;padding:20px;margin-bottom:16px;border:1px solid #0f3460}
.row{display:flex;gap:12px;margin-bottom:10px;align-items:center;flex-wrap:wrap}
label{min-width:130px;color:#a0a0a0}
input,select{background:#0f3460;border:1px solid #1a5276;color:#e0e0e0;padding:8px 12px;border-radius:4px;flex:1;min-width:120px}
button{background:#00d4ff;color:#1a1a2e;border:none;padding:10px 24px;border-radius:4px;font-weight:bold;cursor:pointer}
.stats{font-family:monospace;color:#7f8c8d;line-height:1.8}
a{color:#00d4ff}
</style></head><body>
<h1>LoRa Mesh Forwarder</h1>
<div class="card"><h2>Mesh Configuration</h2>
<form method="POST" action="/cgi-bin/mesh">
HTMLEOF

echo "<div class='row'><label>Role</label>"
echo "<select name='role'>"
[ "$ROLE" = "relay" ] && echo "<option value='relay' selected>Relay</option><option value='border'>Border</option>" || echo "<option value='relay'>Relay</option><option value='border' selected>Border</option>"
echo "</select></div>"

echo "<div class='row'><label>Signing Key</label><input name='signing-key' value='$SKEY' maxlength='32'></div>"
echo "<div class='row'><label>Mesh Freqs (Hz)</label><input name='mesh-freqs' value='$FREQS'></div>"
echo "<div class='row'><label>SF</label><input name='mesh-sf' value='$SF' type='number' min='7' max='12' style='max-width:80px'>"
echo "<label>BW (Hz)</label><input name='mesh-bw' value='$BW' type='number' style='max-width:120px'></div>"
echo "<div class='row'><label>TX Power (dBm)</label><input name='tx-power' value='$TXPWR' type='number' min='1' max='30' style='max-width:80px'></div>"

cat << 'HTMLEOF2'
<div class="row" style="margin-top:16px"><button type="submit">Save & Restart</button></div>
</form></div>
<div class="card"><h2>Status</h2><div class="stats">
HTMLEOF2

# Show process status
PID=$(pgrep -f pkt_mesh_fwd 2>/dev/null | head -1)
if [ -n "$PID" ]; then
  echo "Process: running (PID $PID)<br>"
  UPTIME=$(ps -o etimes= -p "$PID" 2>/dev/null)
  echo "Uptime: ${UPTIME:-?}s<br>"
else
  echo "Process: <span style='color:#e74c3c'>not running</span><br>"
fi

# Show recent log
if [ -f /tmp/mesh_fwd.log ]; then
  TX_COUNT=$(grep -c "TX mesh" /tmp/mesh_fwd.log 2>/dev/null)
  UNWRAP_COUNT=$(grep -c "UNWRAP" /tmp/mesh_fwd.log 2>/dev/null)
  echo "Mesh TX: $TX_COUNT<br>"
  echo "Unwrap: $UNWRAP_COUNT<br>"
fi

cat << 'HTMLEOF3'
</div></div>
<div class="card"><h2>Actions</h2>
<div class="row">
<a href="/cgi-bin/mesh"><button style="background:#3498db">Refresh</button></a>
<a href="/"><button style="background:#95a5a6">Gateway Home</button></a>
</div></div>
</body></html>
HTMLEOF3
