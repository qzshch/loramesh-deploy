#!/bin/sh
# ============================================================
#  LoRa Mesh 一键部署脚本（native pkt_fwd + Node.js 架构）
#  适用于: Milesight UG56/UG63/UG65/UG67/EG71 网关
#
#  架构: pkt_fwd (native) ↔ mesh_forwarder (Node.js) ↔ gateway-bridge
#  无需 Docker，无需自定义 concentratord binary。
#
#  用法:
#    wget -qO- <OSS>/mesh_deploy_native.sh | sh              # auto role
#    wget -qO- <OSS>/mesh_deploy_native.sh | sh -s -- --relay
#    wget -qO- <OSS>/mesh_deploy_native.sh | sh -s -- --border
# ============================================================

# ── CRLF self-heal ──
if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "-sh" ]; then
  if head -1 "$0" 2>/dev/null | od -c 2>/dev/null | grep -q '\\r'; then
    sed -i 's/\r$//' "$0" 2>/dev/null && exec sh "$0" "$@"
  fi
fi

OSS_BASE="https://ursalink-resource-center.oss-us-west-1.aliyuncs.com/kevin"
MESH_FWD_URL="${OSS_BASE}/pkt_mesh_fwd.js"
MESH_FWD_PATH="/opt/chirpstack/pkt_mesh_fwd.js"
BRIDGE_CONF="/etc/lora-gateway-bridge/lora-gateway-bridge.toml"
PKT_FWD_CONF="/etc/quagga/lora/global_conf.json"
MESH_PORT=1700
BRIDGE_PORT=1710
SIGNING_KEY="00112233445566778899aabbccddeeff"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

# ── Parse arguments ──
ROLE=""
MESH_FREQS=""
MESH_SF=7
MESH_BW=125000
TX_POWER=27

for arg in "$@"; do
  case "$arg" in
    --relay)  ROLE="relay" ;;
    --border) ROLE="border" ;;
    --freqs=*) MESH_FREQS="${arg#*=}" ;;
    --sf=*)    MESH_SF="${arg#*=}" ;;
    --bw=*)    MESH_BW="${arg#*=}" ;;
    --tx-power=*) TX_POWER="${arg#*=}" ;;
    --signing-key=*) SIGNING_KEY="${arg#*=}" ;;
    *) warn "Unknown arg: $arg" ;;
  esac
done

# ── Auto-detect role ──
if [ -z "$ROLE" ]; then
  # If gateway has a built-in NS (loraserver), it's a natural border
  if pgrep -f loraserver >/dev/null 2>&1 || [ -f /etc/init.d/loraserver ]; then
    ROLE="border"
    info "Auto-detected role: border (built-in NS)"
  else
    ROLE="relay"
    info "Auto-detected role: relay"
  fi
fi

echo ""
echo "============================================"
echo " LoRa Mesh Deploy (native pkt_fwd edition)"
echo "============================================"
echo " Role:    $ROLE"
echo " Signing: ${SIGNING_KEY:0:8}..."
echo ""

# ── Step 1: Check prerequisites ──
info "Step 1/6: Checking prerequisites..."

# Node.js
NODE_BIN=""
for p in /usr/bin/node /usr/local/bin/node; do
  [ -x "$p" ] && NODE_BIN="$p" && break
done
command -v node >/dev/null 2>&1 && [ -z "$NODE_BIN" ] && NODE_BIN="node"

if [ -z "$NODE_BIN" ]; then
  error "Node.js not found. This architecture requires Node.js (pre-installed on Milesight gateways)."
fi
NODE_VER=$($NODE_BIN --version 2>/dev/null)
info "  Node.js: $NODE_VER ($NODE_BIN)"

# Native pkt_fwd
if ! ps w 2>/dev/null | grep -v grep | grep -q "[ /]lora_pkt_fwd"; then
  warn "  pkt_fwd not running — will start after deploy"
  PKT_FWD_NEEDS_START=1
else
  info "  pkt_fwd: running"
  PKT_FWD_NEEDS_START=0
fi

# ── Step 2: Detect hardware ──
info "Step 2/6: Detecting hardware..."

PRODUCT=$(urtool -g product 2>/dev/null | grep product | awk -F: '{print $2}' | tr -d ' ')
HWVER=$(urtool -g hwver 2>/dev/null | grep hwver | awk -F: '{print $2}' | tr -d ' ')
RESERVED=$(urtool -g reserved 2>/dev/null | grep reserved | head -1 | awk -F: '{print $2}' | tr -d ' ')
BAND_CODE=$(echo "$RESERVED" | cut -c7)

case "$BAND_CODE" in
  1) GW_BAND="433" ;; 2) GW_BAND="470" ;; 3) GW_BAND="868" ;; 4) GW_BAND="915" ;;
  *) GW_BAND="868" ;;
esac

case "$PRODUCT" in
  56) GW_MODEL="UG56" ;; 63) GW_MODEL="UG63" ;; 65) GW_MODEL="UG65" ;;
  67) GW_MODEL="UG67" ;; 71) GW_MODEL="EG71" ;; 50) GW_MODEL="SG50" ;;
  *)  GW_MODEL="Unknown($PRODUCT)" ;;
esac

info "  Device: $GW_MODEL, hwver=$HWVER, band=${GW_BAND}MHz"

# ── Step 3: Set mesh frequencies ──
info "Step 3/6: Configuring mesh frequencies..."

if [ -z "$MESH_FREQS" ]; then
  case "$GW_BAND" in
    915) MESH_FREQS="903900000,904100000,904300000" ;;
    868) MESH_FREQS="868100000,868300000,868500000" ;;
    470) MESH_FREQS="470300000,470500000,470700000" ;;
    433) MESH_FREQS="433175000,433375000,433575000" ;;
    *)   MESH_FREQS="868100000,868300000,868500000" ;;
  esac
fi

info "  Mesh freqs: $(echo $MESH_FREQS | sed 's/000000/MHz/g; s/,/, /g')"
info "  Mesh TX: SF${MESH_SF}BW$((MESH_BW/1000)) @ ${TX_POWER} dBm"

# ── Step 4: Stop existing mesh forwarder + Docker container ──
info "Step 4/6: Stopping existing services..."

# Kill old mesh forwarder
pkill -f pkt_mesh_fwd 2>/dev/null && info "  Old mesh forwarder stopped"

# Stop Docker mesh container if running
DOCKER_BIN=""
for d in /usr/bin/docker/docker /overlay/docker/bin/docker; do
  [ -x "$d" ] && DOCKER_BIN="$d" && break
done
command -v docker >/dev/null 2>&1 && [ -z "$DOCKER_BIN" ] && DOCKER_BIN="docker"

if [ -n "$DOCKER_BIN" ]; then
  if $DOCKER_BIN ps 2>/dev/null | grep -q chirpstack-mesh; then
    $DOCKER_BIN rm -f chirpstack-mesh 2>/dev/null
    info "  Docker mesh container removed"
  fi
fi

# ── Step 5: Move gateway-bridge to BRIDGE_PORT ──
info "Step 5/6: Configuring gateway-bridge (port $BRIDGE_PORT)..."

if [ -f "$BRIDGE_CONF" ]; then
  # Check current bind port
  CURRENT_BIND=$(grep -o 'udp_bind.*=.*"[^"]*"' "$BRIDGE_CONF" | grep -o '[0-9]*$' | tr -d '"')

  if [ "$CURRENT_BIND" = "$MESH_PORT" ]; then
    # Change bridge to BRIDGE_PORT
    sed -i "s|:1700|:${BRIDGE_PORT}|g" "$BRIDGE_CONF"
    info "  Bridge config: port $MESH_PORT → $BRIDGE_PORT"
  elif [ "$CURRENT_BIND" = "$BRIDGE_PORT" ]; then
    info "  Bridge already on port $BRIDGE_PORT"
  else
    warn "  Bridge on unexpected port $CURRENT_BIND, changing to $BRIDGE_PORT"
    sed -i "s|:[0-9]*\"|:${BRIDGE_PORT}\"|g" "$BRIDGE_CONF"
  fi

  # Restart bridge
  killall lora-gateway-bridge 2>/dev/null
  sleep 1
  /usr/bin/lora-gateway-bridge -c "$BRIDGE_CONF" > /dev/null 2>&1 &
  sleep 2

  if ps w 2>/dev/null | grep -v grep | grep -q "lora-gateway-bridge"; then
    info "  Bridge restarted on port $BRIDGE_PORT"
  else
    warn "  Bridge failed to start — check $BRIDGE_CONF"
  fi
else
  warn "  Bridge config not found at $BRIDGE_CONF"
  warn "  mesh forwarder will forward to port $BRIDGE_PORT (start bridge manually)"
fi

# ── Step 6: Install and start mesh forwarder ──
info "Step 6/6: Installing mesh forwarder..."

mkdir -p /opt/chirpstack

# Download
wget -qO "$MESH_FWD_PATH" "$MESH_FWD_URL" 2>/dev/null
if [ ! -f "$MESH_FWD_PATH" ] || [ $(wc -c < "$MESH_FWD_PATH") -lt 1000 ]; then
  error "Failed to download mesh forwarder from $MESH_FWD_URL"
fi
info "  Downloaded: $(wc -c < "$MESH_FWD_PATH") bytes"

# Start mesh forwarder
MESH_LOG="/tmp/mesh_fwd.log"
echo "" > "$MESH_LOG"

FWD_ARGS="--role $ROLE --listen-port $MESH_PORT --server-host 127.0.0.1 --server-port $BRIDGE_PORT"
FWD_ARGS="$FWD_ARGS --mesh-freqs $MESH_FREQS --mesh-sf $MESH_SF --mesh-bw $MESH_BW"
FWD_ARGS="$FWD_ARGS --tx-power $TX_POWER --signing-key $SIGNING_KEY"

$NODE_BIN "$MESH_FWD_PATH" $FWD_ARGS >> "$MESH_LOG" 2>&1 &
sleep 3

# Verify
if ps w 2>/dev/null | grep -v grep | grep -q "pkt_mesh_fwd"; then
  info "  Mesh forwarder running (PID: $(pgrep -f pkt_mesh_fwd | head -1))"
else
  warn "  Mesh forwarder failed to start!"
  cat "$MESH_LOG"
fi

# Restart pkt_fwd if needed (to connect to mesh forwarder on MESH_PORT)
if [ "$PKT_FWD_NEEDS_START" = "1" ]; then
  info "  Starting pkt_fwd..."
  /etc/init.d/lora_pkt_fwd start 2>/dev/null
  sleep 5
fi

# ── Gateway EUI ──
GW_EUI=""
if [ -f /opt/chirpstack/gateway_eui.txt ]; then
  GW_EUI=$(cat /opt/chirpstack/gateway_eui.txt 2>/dev/null)
fi
if [ -z "$GW_EUI" ]; then
  MAC=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')
  if [ -n "$MAC" ] && [ ${#MAC} -eq 12 ]; then
    GW_EUI="$(echo $MAC | cut -c1-6)fffe$(echo $MAC | cut -c7-12)"
  fi
fi

# ── Create startup script ──
cat > /etc/init.d/mesh_forwarder << 'INITEOF'
#!/bin/sh /etc/rc.common
START=65
STOP=65
USE_PROCD=1

start_service() {
  MESH_ARGS="__MESH_ARGS__"
  procd_open_instance
  procd_set_param command /usr/bin/node /opt/chirpstack/pkt_mesh_fwd.js $MESH_ARGS
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param respawn 3600 5 5
  procd_close_instance
}
INITEOF

# Replace placeholder with actual args
sed -i "s|__MESH_ARGS__|$FWD_ARGS|g" /etc/init.d/mesh_forwarder
chmod +x /etc/init.d/mesh_forwarder
/etc/init.d/mesh_forwarder enable 2>/dev/null

info "  Startup script: /etc/init.d/mesh_forwarder (procd respawn)"

# ── Done ──
echo ""
echo "============================================"
printf " ${GREEN}LoRa Mesh deployed!${NC}\n"
echo "============================================"
echo " Role:      $ROLE"
echo " Device:    $GW_MODEL, Band ${GW_BAND}MHz"
echo " Mesh Freq: $(echo $MESH_FREQS | sed 's/000000/MHz/g; s/,/, /g')"
echo " Mesh TX:   SF${MESH_SF}BW$((MESH_BW/1000)) @ ${TX_POWER} dBm"
[ -n "$GW_EUI" ] && echo " GW EUI:    $GW_EUI"
echo " Ports:     pkt_fwd→${MESH_PORT} mesh_fwd→${BRIDGE_PORT} bridge"
echo ""
echo " Logs:   cat /tmp/mesh_fwd.log"
echo " Status: ps w | grep pkt_mesh_fwd"
echo " Restart: /etc/init.d/mesh_forwarder restart"
echo "============================================"
