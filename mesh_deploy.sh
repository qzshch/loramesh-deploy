#!/bin/sh
# ============================================================
#  LoRa Mesh 一键部署脚本 (v3 — native pkt_fwd 架构)
#  适用于: Milesight UG56/UG63/UG65/UG67/EG71 网关
#
#  架构: 宿主机 native pkt_fwd + Docker 容器 (mesh forwarder + web UI)
#  无需 SPI/GPIO 设备映射，支持所有 SX1302 硬件版本。
#
#  用法:
#    wget -qO- <OSS>/mesh_deploy.sh | sh              # 自动判定角色
#    wget -qO- <OSS>/mesh_deploy.sh | sh -s -- --border
#    wget -qO- <OSS>/mesh_deploy.sh | sh -s -- --relay
# ============================================================

# ── CRLF self-heal ──
if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "-sh" ]; then
  if head -1 "$0" 2>/dev/null | od -c 2>/dev/null | grep -q '\\r'; then
    sed -i 's/\r$//' "$0" 2>/dev/null && exec sh "$0" "$@"
  fi
fi

OSS_BASE="https://ursalink-resource-center.oss-us-west-1.aliyuncs.com/kevin"
IMAGE_URL="${OSS_BASE}/chirpstack-mesh-gw.tar.gz"
DOCKER_URL="${OSS_BASE}/docker.tgz"
IMAGE_NAME="chirpstack-mesh-gw"
CONTAINER_NAME="chirpstack-mesh"
WORK_DIR="/tmp/mesh-deploy"
SIGNING_KEY="00112233445566778899aabbccddeeff"
BRIDGE_PORT=1710

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

proc_running() {
  ps w 2>/dev/null | grep -v grep | grep -q "[ /]$1"
}

download() {
  _DL_URL="$1"; _DL_OUT="$2"
  wget -qO "$_DL_OUT" "$_DL_URL" 2>/dev/null && return 0
  curl -sfL -o "$_DL_OUT" "$_DL_URL" 2>/dev/null && return 0
  return 1
}

# ── Parse arguments ──
ROLE=""
MESH_FREQS=""
for arg in "$@"; do
  case "$arg" in
    --relay)  ROLE="relay" ;;
    --border) ROLE="border" ;;
    --freqs=*) MESH_FREQS="${arg#*=}" ;;
    *) warn "Unknown arg: $arg" ;;
  esac
done

echo ""
echo "============================================"
echo " LoRa Mesh Deploy v3 (native pkt_fwd)"
echo "============================================"

# ── Step 1: Check existing container ──
info "Step 1/7: Checking existing container..."

DOCKER_BIN=""
for d in /usr/bin/docker/docker /overlay/docker/bin/docker; do
  [ -x "$d" ] && DOCKER_BIN="$d" && break
done
command -v docker >/dev/null 2>&1 && [ -z "$DOCKER_BIN" ] && DOCKER_BIN="docker"

if [ -n "$DOCKER_BIN" ]; then
  EXISTING=$($DOCKER_BIN ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null)
  if echo "$EXISTING" | grep -q "$CONTAINER_NAME"; then
    warn "Removing existing container: $(echo "$EXISTING" | grep "$CONTAINER_NAME")"
    $DOCKER_BIN rm -f "$CONTAINER_NAME" 2>/dev/null || true
  fi
fi

# ── Step 2: Install Docker if needed ──
info "Step 2/7: Checking Docker..."

if [ -z "$DOCKER_BIN" ] || ! $DOCKER_BIN info >/dev/null 2>&1; then
  info "  Installing Docker..."
  mkdir -p "$WORK_DIR"
  download "$DOCKER_URL" "$WORK_DIR/docker.tgz" || error "Docker download failed"
  tar xzf "$WORK_DIR/docker.tgz" -C /overlay/ 2>/dev/null || tar xzf "$WORK_DIR/docker.tgz" -C /usr/bin/ 2>/dev/null
  # Find docker binary
  for d in /usr/bin/docker/docker /overlay/docker/bin/docker /usr/bin/docker; do
    [ -x "$d" ] && DOCKER_BIN="$d" && break
  done
  [ -z "$DOCKER_BIN" ] && error "Docker install failed: binary not found"
  # Start dockerd if not running
  if ! $DOCKER_BIN info >/dev/null 2>&1; then
    $DOCKER_BIN -d > /tmp/dockerd.log 2>&1 &
    sleep 5
    $DOCKER_BIN info >/dev/null 2>&1 || error "dockerd failed to start"
  fi
  info "  Docker installed: $($DOCKER_BIN --version 2>/dev/null)"
else
  info "  Docker ready: $($DOCKER_BIN --version 2>/dev/null)"
fi

# ── Step 3: Download & load image ──
info "Step 3/7: Loading Mesh image (~45 MB)..."

mkdir -p "$WORK_DIR"
IMAGE_TGZ="$WORK_DIR/chirpstack-mesh-gw.tar.gz"

# Remove old image
OLD_IMG=$($DOCKER_BIN images --format "{{.ID}}" "$IMAGE_NAME" 2>/dev/null | head -1)
if [ -n "$OLD_IMG" ]; then
  $DOCKER_BIN rmi -f "$OLD_IMG" 2>/dev/null
fi

download "$IMAGE_URL" "$IMAGE_TGZ" || error "Image download failed"
_ISZ=$(wc -c < "$IMAGE_TGZ" 2>/dev/null | tr -d ' ')
[ "$_ISZ" -lt 1000000 ] 2>/dev/null && error "Image too small (${_ISZ} bytes)"

$DOCKER_BIN load -i "$IMAGE_TGZ" 2>/dev/null || error "Image load failed"
# Tag the loaded image to the expected name (buildx may use different name)
_LOADED=$($DOCKER_BIN images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep chirpstack-mesh-gw | head -1)
if [ -n "$_LOADED" ] && [ "$_LOADED" != "${IMAGE_NAME}:latest" ]; then
  $DOCKER_BIN tag "$_LOADED" "${IMAGE_NAME}:latest" 2>/dev/null
  info "  Tagged: $_LOADED → ${IMAGE_NAME}:latest"
fi
info "  Image ready: $($DOCKER_BIN images --format '{{.Size}}' "$IMAGE_NAME" 2>/dev/null | head -1)"

# ── Step 4: Detect hardware ──
info "Step 4/7: Detecting hardware..."

PRODUCT=$(urtool -g product 2>/dev/null | grep product | awk -F: '{print $2}' | tr -d ' ')
HWVER=$(urtool -g hwver 2>/dev/null | grep hwver | awk -F: '{print $2}' | tr -d ' ')
RESERVED=$(urtool -g reserved 2>/dev/null | grep reserved | head -1 | awk -F: '{print $2}' | tr -d ' ')

# Band from reserved 7th char
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

# Gateway EUI from MAC
MAC=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')
if [ -n "$MAC" ] && [ ${#MAC} -eq 12 ]; then
  GATEWAY_EUI="$(echo $MAC | cut -c1-6)fffe$(echo $MAC | cut -c7-12)"
  GATEWAY_EUI=$(echo "$GATEWAY_EUI" | tr 'a-f' 'A-F')
fi

# Default mesh frequencies per band
if [ -z "$MESH_FREQS" ]; then
  case "$GW_BAND" in
    915) MESH_FREQS="903900000,904100000,904300000" ;;
    868) MESH_FREQS="868100000,868300000,868500000" ;;
    470) MESH_FREQS="470300000,470500000,470700000" ;;
    *)   MESH_FREQS="868100000,868300000,868500000" ;;
  esac
fi

# Auto-detect role
if [ -z "$ROLE" ]; then
  if proc_running loraserver || proc_running chirpstack; then
    ROLE="border"
  else
    ROLE="relay"
  fi
fi

RELAY_BORDER="false"
[ "$ROLE" = "border" ] && RELAY_BORDER="true"

info "  Device: $GW_MODEL, hwver=$HWVER, Band=${GW_BAND}MHz"
info "  Role: $ROLE, EUI: $GATEWAY_EUI"
info "  Mesh freqs: $(echo $MESH_FREQS | sed 's/000000/MHz/g; s/,/, /g')"

# ── Step 5: Configure gateway-bridge port ──
info "Step 5/7: Configuring gateway-bridge (port $BRIDGE_PORT)..."

BRIDGE_CONF="/etc/lora-gateway-bridge/lora-gateway-bridge.toml"
if [ -f "$BRIDGE_CONF" ]; then
  # Check if bridge is already on BRIDGE_PORT
  if grep -q ":${BRIDGE_PORT}" "$BRIDGE_CONF"; then
    info "  Bridge already on port $BRIDGE_PORT"
  else
    sed -i "s|:1700|:${BRIDGE_PORT}|g" "$BRIDGE_CONF"
    killall lora-gateway-bridge 2>/dev/null
    sleep 1
    /usr/bin/lora-gateway-bridge -c "$BRIDGE_CONF" > /dev/null 2>&1 &
    sleep 2
    info "  Bridge moved to port $BRIDGE_PORT"
  fi
else
  warn "  Bridge config not found at $BRIDGE_CONF"
fi

# ── Step 6: Ensure pkt_fwd is running ──
info "Step 6/7: Checking packet forwarder..."

if proc_running lora_pkt_fwd; then
  info "  pkt_fwd running (native, on host)"
else
  warn "  pkt_fwd not running — starting..."
  /etc/init.d/lora_pkt_fwd start 2>/dev/null
  sleep 8
  proc_running lora_pkt_fwd && info "  pkt_fwd started" || warn "  pkt_fwd failed to start"
fi

# ── Step 7: Start container ──
info "Step 7/7: Starting Mesh container..."

# Pre-launch: write initial mesh config JSON
mkdir -p /opt/chirpstack
cat > /opt/chirpstack/mesh_config.json << CFGEOF
{
  "role": "$ROLE",
  "signing-key": "$SIGNING_KEY",
  "mesh-freqs": "$MESH_FREQS",
  "mesh-sf": "7",
  "mesh-bw": "125000",
  "tx-power": "27"
}
CFGEOF

$DOCKER_BIN run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  --restart unless-stopped \
  -v /etc/quagga/user_permission.conf:/etc/host_user_permission:ro \
  -v /etc/https.crt:/etc/ssl_cert:ro \
  -v /etc/https.key:/etc/ssl_key:ro \
  -v /opt/chirpstack/mesh_config.json:/opt/chirpstack/mesh_config.json \
  -e ROLE="$ROLE" \
  -e SIGNING_KEY="$SIGNING_KEY" \
  -e MESH_FREQS="$MESH_FREQS" \
  -e BRIDGE_PORT="$BRIDGE_PORT" \
  -e GATEWAY_EUI="$GATEWAY_EUI" \
  -e RELAY_BORDER="$RELAY_BORDER" \
  "$IMAGE_NAME"

sleep 5
info "Container started"

# ── Verify ──
info "Verifying services..."
for PROC in mesh-forwarder web-ui nginx; do
  STATUS=$($DOCKER_BIN exec "$CONTAINER_NAME" supervisorctl status "$PROC" 2>/dev/null | awk '{print $2}')
  if [ "$STATUS" = "RUNNING" ]; then
    info "  ✅ $PROC running"
  else
    warn "  ❌ $PROC: $STATUS"
  fi
done

# Wait for mesh forwarder to start processing
sleep 5
MESH_LOG=$($DOCKER_BIN exec "$CONTAINER_NAME" cat /tmp/mesh.log 2>/dev/null | tail -5)
if echo "$MESH_LOG" | grep -q "Mesh Forwarder"; then
  info "  ✅ Mesh forwarder initialized"
else
  warn "  Mesh forwarder log:"
  echo "$MESH_LOG" | head -3
fi

# ── Done ──
echo ""
echo "============================================"
printf " ${GREEN}LoRa Mesh deployed!${NC}\n"
echo "============================================"
echo " Role:     $ROLE"
echo " Device:   $GW_MODEL, Band ${GW_BAND}MHz"
echo " EUI:      $GATEWAY_EUI"
echo " Mesh:     $(echo $MESH_FREQS | sed 's/000000/MHz/g; s/,/, /g')"
echo " Web UI:   http://$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'):8088"
echo " HTTPS:    https://$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'):8443"
echo ""
echo " Logs:   $DOCKER_BIN logs -f $CONTAINER_NAME"
echo "============================================"
