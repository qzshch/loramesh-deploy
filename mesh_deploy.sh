#!/bin/sh
# ============================================================
#  ChirpStack LoRa Mesh 一键部署脚本
#  适用于: Milesight UG56/UG65/UG67/EG71 网关
#  用法: sh mesh_deploy.sh [--border|--relay]
# ============================================================
set -e

OSS_BASE="https://ursalink-resource-center.oss-us-west-1.aliyuncs.com/kevin"
IMAGE_URL="${OSS_BASE}/chirpstack-mesh-gw.tar.gz"
WEBUI_URL="${OSS_BASE}/web_ui_v2.py"
FWD_URL="${OSS_BASE}/mesh_forwarder.py"
DOCKER_URL="${OSS_BASE}/docker.tgz"
COMPOSE_URL="${OSS_BASE}/docker-compose.tgz"
IMAGE_NAME="chirpstack-mesh-gw"
CONTAINER_NAME="chirpstack-mesh"
WORK_DIR="/tmp/mesh-deploy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo "${GREEN}[INFO]${NC} $1"; }
warn()  { echo "${YELLOW}[WARN]${NC} $1"; }
error() { echo "${RED}[ERROR]${NC} $1"; exit 1; }
download() {
  _DL_URL="$1"; _DL_OUT="$2"
  # Offline mode: check for local file in script directory
  _DL_BASE=$(basename "$_DL_URL")
  if [ -f "$SCRIPT_DIR/$_DL_BASE" ]; then
    cp "$SCRIPT_DIR/$_DL_BASE" "$_DL_OUT"
    return 0
  fi
  # Online mode: download from OSS with retry
  _DL_OK=false
  for _DL_TRY in 1 2 3; do
    if command -v curl >/dev/null 2>&1; then
      curl -fSL --connect-timeout 15 --retry 2 --retry-delay 3 "$_DL_URL" -o "$_DL_OUT" 2>/dev/null && { _DL_OK=true; break; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=15 --tries=2 "$_DL_URL" -O "$_DL_OUT" 2>/dev/null && { _DL_OK=true; break; }
    else
      error "Neither curl nor wget available"
    fi
    [ "$_DL_TRY" -lt 3 ] && sleep 3
  done
  [ "$_DL_OK" = "true" ] || return 1
}

# ── Parse arguments ──

ROLE="relay"
for arg in "$@"; do
  case "$arg" in
    --relay)  ROLE="relay" ;;
    --border) ROLE="border" ;;
  esac
done
RELAY_BORDER="false"
[ "$ROLE" = "border" ] && RELAY_BORDER="true"
info "Deploying as ${ROLE} gateway"

mkdir -p "$WORK_DIR"

# ── Step 1: Check for existing container ──

info "Step 1/9: Checking existing container..."
DOCKER_BIN=""
if [ -x "/usr/bin/docker/docker" ]; then
  DOCKER_BIN="/usr/bin/docker/docker"
elif [ -x "/overlay/docker/bin/docker" ]; then
  DOCKER_BIN="/overlay/docker/bin/docker"
elif command -v docker >/dev/null 2>&1; then
  DOCKER_BIN="docker"
fi

if [ -n "$DOCKER_BIN" ]; then
  EXISTING=$($DOCKER_BIN ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Names}} {{.Status}}" 2>/dev/null || echo "")
  if echo "$EXISTING" | grep -q "$CONTAINER_NAME"; then
    warn "Existing container found: $EXISTING"
    if [ -t 0 ]; then
      printf "  Remove and redeploy? [y/N]: "
      read confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        $DOCKER_BIN rm -f "$CONTAINER_NAME" 2>/dev/null || true
        info "Old container removed"
      else
        info "Keeping existing container. Exiting."
        exit 0
      fi
    else
      $DOCKER_BIN rm -f "$CONTAINER_NAME" 2>/dev/null || true
      info "Old container removed"
    fi
  fi
else
  info "Docker not found, will install"
fi

# ── Step 2: Install Docker if needed ──

info "Step 2/9: Checking Docker..."
if [ -z "$DOCKER_BIN" ] || ! $DOCKER_BIN info >/dev/null 2>&1; then
  info "Docker not running or not installed. Installing..."

  # Check if docker init.d service exists
  if [ ! -f /etc/init.d/docker ]; then
    error "Docker init.d service not found. Firmware may not support Docker."
  fi

  INSTALL_DIR="/home/admin/docker_install"
  mkdir -p "$INSTALL_DIR"

  # Download docker.tgz if not present
  if [ ! -f "${INSTALL_DIR}/docker.tgz" ]; then
    info "  Downloading docker.tgz (~48 MB)..."
    download "$DOCKER_URL" "${INSTALL_DIR}/docker.tgz" || error "docker.tgz download failed"
  fi

  # Download docker-compose.tgz if not present
  if [ ! -f "${INSTALL_DIR}/docker-compose.tgz" ]; then
    info "  Downloading docker-compose.tgz (~8 MB)..."
    download "$COMPOSE_URL" "${INSTALL_DIR}/docker-compose.tgz" || error "docker-compose.tgz download failed"
  fi

  info "  Installing Docker..."
  /etc/init.d/docker stop 2>/dev/null || true

  # Try docker_ctl install (it extracts to /overlay/docker/bin/ then tries to
  # copy to MMC for persistence — MMC copy fails on gateways without SD card,
  # but the extraction itself succeeds)
  /etc/init.d/docker_ctl install "$INSTALL_DIR" 2>&1 | tail -5

  # Wait for procd-based install to complete (it runs asynchronously)
  sleep 25

  # If docker_ctl failed (usually MMC copy error), do manual install as fallback
  DOCKER_PROG="/overlay/docker/bin/dockerd"
  if [ ! -f "$DOCKER_PROG" ]; then
    info "  docker_ctl install failed, doing manual extraction..."
    mkdir -p /overlay/docker/bin /usr/bin/docker
    # Extract to root (tarball structure: usr/bin/docker/{docker,dockerd,...})
    tar -xzf "${INSTALL_DIR}/docker.tgz" -C / 2>/dev/null
    # Also copy to /overlay for persistence across reboots
    cp -a /usr/bin/docker/* /overlay/docker/bin/ 2>/dev/null
    # Handle flat tarball structure as fallback
    if [ -d /overlay/docker/bin/docker ]; then
      mv /overlay/docker/bin/docker/* /overlay/docker/bin/ 2>/dev/null
      rmdir /overlay/docker/bin/docker 2>/dev/null
    fi
    chmod +x /overlay/docker/bin/* /usr/bin/docker/* 2>/dev/null
    touch /overlay/docker/bin/.docker_installed 2>/dev/null

    if [ ! -f "$DOCKER_PROG" ]; then
      error "Docker installation failed — dockerd not found after extraction. Check: tail -f /etc/urlog/system.log | grep docker"
    fi
    info "  Manual extraction succeeded"
  fi

  # Install docker-compose if present
  if [ -f "${INSTALL_DIR}/docker-compose.tgz" ] && [ ! -f /overlay/docker/bin/docker-compose ]; then
    tar -xzf "${INSTALL_DIR}/docker-compose.tgz" -C /overlay/docker/bin 2>/dev/null
    chmod +x /overlay/docker/bin/docker-compose 2>/dev/null
  fi

  info "  Starting Docker service..."
  /etc/init.d/docker start
  sleep 10

  # Verify — try multiple paths and wait for daemon
  DOCKER_BIN=""
  for attempt in 1 2 3; do
    for path in /usr/bin/docker/docker /overlay/docker/bin/docker; do
      if [ -x "$path" ] && "$path" info >/dev/null 2>&1; then
        DOCKER_BIN="$path"
        break 2
      fi
    done
    if [ -z "$DOCKER_BIN" ]; then
      info "  Waiting for Docker daemon (attempt $attempt)..."
      sleep 5
    fi
  done

  if [ -z "$DOCKER_BIN" ]; then
    # Last resort: check if docker binary exists but daemon not ready
    for path in /usr/bin/docker/docker /overlay/docker/bin/docker; do
      if [ -x "$path" ]; then
        warn "  Docker binary found at $path but daemon not responding"
        warn "  Check: tail -f /etc/urlog/system.log | grep docker"
        break
      fi
    done
    error "Docker installation failed — daemon not available. Check syslog."
  fi

  info "Docker installed: $($DOCKER_BIN version 2>/dev/null | head -2 | tail -1)"
else
  info "Docker ready: $($DOCKER_BIN version 2>/dev/null | head -2 | tail -1)"
fi

# ── Step 3: Download & load image ──

info "Step 3/9: Downloading Mesh image (~39 MB)..."
if ! $DOCKER_BIN images --format "{{.Repository}}" 2>/dev/null | grep -q "^${IMAGE_NAME}$"; then
  if [ ! -f "${WORK_DIR}/chirpstack-mesh-gw.tar.gz" ]; then
    download "$IMAGE_URL" "${WORK_DIR}/chirpstack-mesh-gw.tar.gz" || error "Docker image download failed"
  fi
  info "  Loading image..."
  $DOCKER_BIN load -i "${WORK_DIR}/chirpstack-mesh-gw.tar.gz" 2>/dev/null || \
    gunzip -c "${WORK_DIR}/chirpstack-mesh-gw.tar.gz" | $DOCKER_BIN load || \
    error "Docker image load failed"
  info "  Image loaded"
else
  info "Image already present, skipping"
fi

# ── Step 4: Detect hardware ──

info "Step 4/9: Detecting hardware..."
PRODUCT=""
RESERVED=""
if command -v urtool >/dev/null 2>&1; then
  UR_OUT=$(urtool -g 2>/dev/null)
  PRODUCT=$(echo "$UR_OUT" | grep "^product" | awk -F: '{print $2}' | tr -d ' ')
  RESERVED=$(echo "$UR_OUT" | grep "^reserved" | head -1 | awk -F: '{print $2}' | tr -d ' ')
fi
# Fallback: model marker files
[ -z "$PRODUCT" ] && [ -f /tmp/71 ] && PRODUCT="71"
[ -z "$PRODUCT" ] && [ -f /tmp/67 ] && PRODUCT="67"
[ -z "$PRODUCT" ] && [ -f /tmp/63 ] && PRODUCT="63"
[ -z "$PRODUCT" ] && [ -f /tmp/56 ] && PRODUCT="56"
[ -z "$PRODUCT" ] && PRODUCT="65"

# Gateway model name (for display banner)
case "$PRODUCT" in
  71) GW_MODEL="EG71" ;; 56) GW_MODEL="UG56" ;;
  67) GW_MODEL="UG67" ;; 63) GW_MODEL="UG63" ;;
  65) GW_MODEL="UG65" ;;  *) GW_MODEL="UG65" ;;
esac

# Hardware band from reserved field (7th char)
GW_BAND="868"
if [ -n "$RESERVED" ] && [ ${#RESERVED} -ge 7 ]; then
  BAND_CODE=$(echo "$RESERVED" | cut -c7)
  case "$BAND_CODE" in
    1) GW_BAND="433" ;; 2) GW_BAND="470" ;; 3) GW_BAND="868" ;; 4) GW_BAND="915" ;;
  esac
fi

# GPIO mapping by product model
# These are the REAL hardware reset pins (used by reset_lgw.sh via sysfs).
# concentratord uses a HARMLESS pin (see override below) — the real reset is
# done externally by reset_lgw.sh before the container starts.
GPIO_CHIP_DEV=""
SX1302_REAL_PIN=0    # Real SX1302 reset pin (for reset_lgw.sh reference)
SX1261_REAL_PIN=0    # Real SX126X reset pin
MODEL="rak_2287"

case "$PRODUCT" in
  71)
    GPIO_CHIP_DEV="/dev/gpiochip2"
    SX1302_REAL_PIN=22
    SX1261_REAL_PIN=23
    info "EG71: gpiochip2, SX1302 reset=pin22, SX1261 reset=pin23"
    ;;
  56)
    GPIO_CHIP_DEV="/dev/gpiochip1"
    SX1302_REAL_PIN=8
    SX1261_REAL_PIN=10
    info "UG56: gpiochip1, SX1302 reset=pin8, SX1261 reset=pin10"
    ;;
  67)
    GPIO_CHIP_DEV="/dev/gpiochip4"
    SX1302_REAL_PIN=0    # gpio-128 = pin 0 on gpiochip4
    SX1261_REAL_PIN=1    # gpio-129 = pin 1
    info "UG67: gpiochip4, SX1302 reset=pin0, SX1261 reset=pin1"
    ;;
  65|*)
    GPIO_CHIP_DEV="/dev/gpiochip4"
    SX1302_REAL_PIN=11   # gpio-139 = pin 11 on gpiochip4
    SX1261_REAL_PIN=13   # gpio-141 = pin 13
    info "UG65: gpiochip4, SX1302 reset=pin11, SX1261 reset=pin13"
    ;;
esac

# Override: use harmless pin 31 for concentratord's internal cdev reset (Bug #49 fix)
#
# concentratord's gpiochip cdev reset leaves the GPIO LOW after reset.
# If it uses the REAL SX1302 reset pin → chip held in reset → TX fails.
# If it toggles certain pins on some hwver → SPI bus disrupted → chip version 0x00.
#
# Solution: use pin 31 (unconnected on ALL Milesight models) for concentratord's
# cdev reset. The REAL hardware reset is done by reset_lgw.sh (Step 6) using
# sysfs, which correctly sets the pin to input (high-Z) after reset.
#
# With v3 binary (reset.rs fix): pin 31 ends HIGH after reset (extra safety).
# With stock binary: pin 31 ends LOW after reset (harmless, pin is unconnected).
SX1302_RESET_GPIO=31
info "Product=$PRODUCT, Band=${GW_BAND}MHz, concentratord reset=pin${SX1302_RESET_GPIO} (harmless)"

# UG56: download prerequisite files if missing
if [ "$PRODUCT" = "56" ]; then
  UG56_BIN="/etc/chirpstack-concentratord-sx1302-sysfs"
  UG56_PATCH="/etc/ug56_patch.sh"
  if [ ! -f "$UG56_BIN" ]; then
    info "  UG56: downloading custom concentratord binary (~5MB)..."
    download "${OSS_BASE}/chirpstack-concentratord-sx1302-sysfs" "$UG56_BIN" && \
      chmod +x "$UG56_BIN" && info "    saved to $UG56_BIN" || error "Failed to download concentratord binary"
  fi
  if [ ! -f "$UG56_PATCH" ]; then
    info "  UG56: downloading patch script..."
    download "${OSS_BASE}/ug56_patch.sh" "$UG56_PATCH" && \
      chmod +x "$UG56_PATCH" && info "    saved to $UG56_PATCH" || error "Failed to download ug56_patch.sh"
  fi
fi

# ── Step 5: Stop packet forwarder only (it's the only SPI holder) ──

info "Step 5/9: Stopping native packet forwarder (SPI holder)..."
if [ -f "/etc/init.d/lora_pkt_fwd" ]; then
  /etc/init.d/lora_pkt_fwd stop 2>/dev/null && info "  Stopped lora_pkt_fwd" || true
  /etc/init.d/lora_pkt_fwd disable 2>/dev/null && info "  Disabled lora_pkt_fwd auto-start" || true
fi
killall -9 lora_pkt_fwd station 2>/dev/null || true
# Keep NS services running: loraserver, lora_app_server, lora_gateway_bridge, postgres
sleep 2

# Install lora_pkt_fwd watchdog via cron — kills native pkt_fwd if re-enabled while mesh runs
info "  Installing lora_pkt_fwd watchdog (cron, every 1 min)..."
WATCHDOG_CRON='* * * * * [ -f /tmp/.mesh_container_running ] && pgrep -x lora_pkt_fwd >/dev/null && { /etc/init.d/lora_pkt_fwd stop; killall -9 lora_pkt_fwd; } 2>/dev/null'
# Use file-based crontab install (pipe `| crontab -` hangs on some BusyBox firmware)
CRON_TMP="${WORK_DIR}/crontab_tmp"
(crontab -l 2>/dev/null | grep -v mesh_container_running; echo "$WATCHDOG_CRON") > "$CRON_TMP" 2>/dev/null
crontab "$CRON_TMP" 2>/dev/null && info "    crontab installed via file" || warn "    crontab install failed (watchdog disabled)"
rm -f "$CRON_TMP"
/etc/init.d/cron enable 2>/dev/null || true
touch /tmp/.mesh_container_running
info "  lora_pkt_fwd watchdog installed"

# ── Step 6: Initialize GPIO ──

info "Step 6/9: Initializing SX1302 GPIO..."
# Unexport GPIOs BEFORE reset_lgw.sh (it re-exports them for reset)
for GPIO_DIR in /sys/class/gpio/gpio*; do
  GPIO_NAME=$(basename "$GPIO_DIR" 2>/dev/null)
  case "$GPIO_NAME" in gpiochip*|gpiolib*) continue ;; esac
  echo "$GPIO_NAME" | grep -q '^gpio' || continue
  NUM=$(echo "$GPIO_NAME" | sed 's/^gpio//')
  echo "$NUM" | grep -q '^[0-9][0-9]*$' || continue
  echo "$NUM" > /sys/class/gpio/unexport 2>/dev/null || true
done

# Run reset script (exports, toggles, may or may not unexport)
if [ -f /usr/sbin/reset_lgw.sh ]; then
  /usr/sbin/reset_lgw.sh start 2>/dev/null && info "  reset_lgw.sh done" || warn "  reset_lgw.sh skipped"
fi

# Wait for kernel to release GPIO resources after reset
sleep 1

# Unexport AGAIN after reset (reset_lgw.sh leaves GPIOs exported)
for GPIO_DIR in /sys/class/gpio/gpio*; do
  GPIO_NAME=$(basename "$GPIO_DIR" 2>/dev/null)
  case "$GPIO_NAME" in gpiochip*|gpiolib*) continue ;; esac
  echo "$GPIO_NAME" | grep -q '^gpio' || continue
  NUM=$(echo "$GPIO_NAME" | sed 's/^gpio//')
  echo "$NUM" | grep -q '^[0-9][0-9]*$' || continue
  echo "$NUM" > /sys/class/gpio/unexport 2>/dev/null || true
done
info "  GPIO cleanup done"

# ── Step 7: Start container ──

info "Step 7/9: Starting Mesh container..."

# Phase 1: Temporary start to get real Gateway EUI from SX1302 hardware
info "  Phase 1: Determining Gateway EUI..."

# Map hardware band to region for temp container
case "$GW_BAND" in
  433) TMP_REGION="eu433" ;; 470) TMP_REGION="cn470" ;;
  915) TMP_REGION="us915" ;; *)   TMP_REGION="eu868" ;;
esac

# Map region to channels config file (US915/AU915 have no channels_xx.toml, only sub-band variants)
case "$TMP_REGION" in
  us915) TMP_CHANNELS="us915_0" ;; au915) TMP_CHANNELS="au915_0" ;;
  *)     TMP_CHANNELS="$TMP_REGION" ;;
esac

# Use MAC-derived EUI (matches built-in NS auto-registration)
MAC=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | tr 'a-f' 'A-F')
if [ -n "$MAC" ] && [ ${#MAC} -eq 12 ]; then
  GATEWAY_EUI="$(echo $MAC | cut -c1-6)FFFE$(echo $MAC | cut -c7-12)"
  info "  Gateway EUI (MAC-derived): $GATEWAY_EUI"
else
  warn "  Could not read eth0 MAC, falling back to SX1302 hardware EUI"
  # Start concentratord temporarily to read SX1302 EUI
  $DOCKER_BIN run -d --name ${CONTAINER_NAME}_tmp --rm \
    --device /dev/spidev0.0:/dev/spidev0.0 \
    --device /dev/spidev0.1:/dev/spidev0.1 \
    --device ${GPIO_CHIP_DEV}:/dev/gpiochip0 \
    -e MODEL=${MODEL} \
    -e GW_MODEL=${GW_MODEL} \
    -e REGION=${TMP_REGION} \
    -e CHANNELS=${TMP_CHANNELS} \
    -e HAS_GPS=0 \
    -e RESET_GPIO=${SX1302_RESET_GPIO} \
    ${IMAGE_NAME} >/dev/null 2>&1

  GATEWAY_EUI=""
  for i in $(seq 1 30); do
    sleep 1
    EUI_LINE=$($DOCKER_BIN logs ${CONTAINER_NAME}_tmp 2>&1 | grep "Gateway ID retrieved" | tail -1)
    if [ -n "$EUI_LINE" ]; then
      GATEWAY_EUI=$(echo "$EUI_LINE" | grep -oE '[0-9a-f]{16}' | tail -1)
      if [ -n "$GATEWAY_EUI" ] && [ ${#GATEWAY_EUI} -eq 16 ]; then
        GATEWAY_EUI=$(echo "$GATEWAY_EUI" | tr 'a-f' 'A-F')
        info "  EUI from SX1302 at ${i}s: $GATEWAY_EUI"
        break
      fi
      GATEWAY_EUI=""
    fi
  done

  $DOCKER_BIN stop ${CONTAINER_NAME}_tmp >/dev/null 2>&1 || true
  $DOCKER_BIN rm -f ${CONTAINER_NAME}_tmp >/dev/null 2>&1 || true

  if [ -z "$GATEWAY_EUI" ] || [ ${#GATEWAY_EUI} -ne 16 ]; then
    GATEWAY_EUI="0000000000000000"
    warn "  Failed to read EUI, using fallback"
  fi
fi
info "  Gateway EUI: $GATEWAY_EUI"

# Region-dependent defaults
case "$TMP_REGION" in
  eu868)  DEFAULT_FREQS="868100000,868300000,868500000"; CHANNELS_CFG="eu868" ;;
  us915)  DEFAULT_FREQS="902300000,902500000,902700000"; CHANNELS_CFG="us915_0" ;;
  in865)  DEFAULT_FREQS="865062500,865402500,865985000"; CHANNELS_CFG="in865" ;;
  au915)  DEFAULT_FREQS="915200000,915400000,915600000"; CHANNELS_CFG="au915_0" ;;
  as923)  DEFAULT_FREQS="923200000,923400000,923600000"; CHANNELS_CFG="as923" ;;
  kr920)  DEFAULT_FREQS="922100000,922300000,922500000"; CHANNELS_CFG="kr920" ;;
  ru864)  DEFAULT_FREQS="868900000,869100000"; CHANNELS_CFG="ru864" ;;
  eu433)  DEFAULT_FREQS="433175000,433375000,433575000"; CHANNELS_CFG="eu433" ;;
  *)      DEFAULT_FREQS="868100000,868300000,868500000"; CHANNELS_CFG="eu868" ;;
esac

# UG56 special handling: no gpiochip device, needs --privileged + sysfs GPIO
UG56_OPTS=""
GPIO_DEVICE_MAP="--device ${GPIO_CHIP_DEV}:/dev/gpiochip0"
if [ "$PRODUCT" = "56" ]; then
  info "  UG56 detected: using --privileged + sysfs GPIO (no gpiochip cdev)"
  UG56_OPTS="--privileged -v /sys/class/gpio:/sys/class/gpio:rw"
  GPIO_DEVICE_MAP=""
  # UG56 uses sysfs reset (not gpiochip), so disable entrypoint's RESET_GPIO logic
  SX1302_RESET_GPIO=0
fi


DOCKER_OPTS="-d --name $CONTAINER_NAME --restart unless-stopped \
  --device /dev/spidev0.0:/dev/spidev0.0 \
  --device /dev/spidev0.1:/dev/spidev0.1 \
  ${GPIO_DEVICE_MAP} \
  ${UG56_OPTS} \
  -v /etc/quagga/user_permission.conf:/etc/host_user_permission:ro \
  -v /etc/https.crt:/etc/ssl_cert:ro \
  -v /etc/https.key:/etc/ssl_key:ro \
  -p 8088:8080 -p 8443:8443 \
  -e MODEL=${MODEL} \
  -e GW_MODEL=${GW_MODEL} \
  -e REGION=${TMP_REGION} \
  -e CHANNELS=${CHANNELS_CFG} \
  -e HAS_GPS=0 \
  -e RESET_GPIO=${SX1302_RESET_GPIO} \
  -e RELAY_BORDER=${RELAY_BORDER} \
  -e RELAY_SIGNING_KEY=00112233445566778899aabbccddeeff \
  -e RELAY_FREQUENCIES=${DEFAULT_FREQS} \
  -e RELAY_SF=7 \
  -e RELAY_TX_POWER=16 \
  -e MQTT_SERVER=tcp://192.168.45.38:1884 \
  -e MQTT_TOPIC_PREFIX=${TMP_REGION} \
  -e MQTT_BACKEND_SOCKET=forwarder \
  -e GATEWAY_EUI=${GATEWAY_EUI} \
  -e GW_BAND=${GW_BAND} \
  -e DEBUG=INFO"

# Final GPIO cleanup before main container launch
info "  Pre-launch GPIO cleanup..."
for GPIO_DIR in /sys/class/gpio/gpio*; do
  GPIO_NAME=$(basename "$GPIO_DIR" 2>/dev/null)
  case "$GPIO_NAME" in gpiochip*|gpiolib*) continue ;; esac
  echo "$GPIO_NAME" | grep -q '^gpio' || continue
  NUM=$(echo "$GPIO_NAME" | sed 's/^gpio//')
  echo "$NUM" | grep -q '^[0-9][0-9]*$' || continue
  echo "$NUM" > /sys/class/gpio/unexport 2>/dev/null || true
done

$DOCKER_BIN run $DOCKER_OPTS ${IMAGE_NAME}
sleep 3
info "Container started"

# ── Step 8: Post-deploy injection ──

info "Step 8/9: Injecting latest files..."
download "$WEBUI_URL" "${WORK_DIR}/web_ui_v2.py" && \
  $DOCKER_BIN cp "${WORK_DIR}/web_ui_v2.py" ${CONTAINER_NAME}:/opt/chirpstack/web_ui.py && \
  info "  web_ui_v2.py injected" || error "web_ui_v2.py download/inject failed"

download "$FWD_URL" "${WORK_DIR}/mesh_forwarder.py" && \
  $DOCKER_BIN cp "${WORK_DIR}/mesh_forwarder.py" ${CONTAINER_NAME}:/opt/chirpstack/mesh_forwarder.py && \
  info "  mesh_forwarder.py injected" || error "mesh_forwarder.py download/inject failed"

# Add semtech-udp-forwarder to supervisord
$DOCKER_BIN exec ${CONTAINER_NAME} grep -q "semtech-udp-forwarder" /etc/supervisord.conf 2>/dev/null || \
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'cat >> /etc/supervisord.conf << "EOF"

[program:semtech-udp-forwarder]
command=python3 /opt/chirpstack/mesh_forwarder.py
directory=/opt/chirpstack
autostart=false
autorestart=true
startsecs=3
stdout_logfile=/tmp/mesh.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/mesh.log
stderr_logfile_maxbytes=0
redirect_stderr=true
EOF'

# Install pyzmq + pycryptodome (for Web UI auth) — critical, abort if missing
info "  Checking Python dependencies..."
for PKG in "zmq:pyzmq" "Crypto.Cipher.AES:pycryptodome"; do
  IMPORT="${PKG%%:*}"
  PIP_NAME="${PKG##*:}"
  if $DOCKER_BIN exec ${CONTAINER_NAME} python3 -c "import ${IMPORT}" 2>/dev/null; then
    info "    ${PIP_NAME} ✓"
  else
    info "    Installing ${PIP_NAME}..."
    $DOCKER_BIN exec ${CONTAINER_NAME} pip3 install ${PIP_NAME} --break-system-packages -q && \
      info "    ${PIP_NAME} installed" || error "${PIP_NAME} install failed — container has no PyPI access"
  fi
done

# Sync MQTT credentials from host configs to mosquitto (host-level operation)
if [ -f /etc/lora-gateway-bridge/lora-gateway-bridge.toml ] && command -v mosquitto_passwd >/dev/null 2>&1; then
  LGB_USER=$(grep '^username' /etc/lora-gateway-bridge/lora-gateway-bridge.toml 2>/dev/null | head -1 | cut -d'"' -f2)
  LGB_PASS=$(grep '^password' /etc/lora-gateway-bridge/lora-gateway-bridge.toml 2>/dev/null | head -1 | cut -d'"' -f2)
  if [ -n "$LGB_USER" ] && [ -n "$LGB_PASS" ]; then
    mosquitto_passwd -b /etc/mosquitto/pwd "$LGB_USER" "$LGB_PASS" 2>/dev/null && \
      info "  MQTT user '$LGB_USER' synced to mosquitto" || true
  fi
  # Also sync loraserver credentials
  NS_USER=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/loraserver/loraserver.json 2>/dev/null | head -1 | cut -d'"' -f4)
  NS_PASS=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/loraserver/loraserver.json 2>/dev/null | head -1 | cut -d'"' -f4)
  if [ -n "$NS_USER" ] && [ -n "$NS_PASS" ]; then
    mosquitto_passwd -b /etc/mosquitto/pwd "$NS_USER" "$NS_PASS" 2>/dev/null && \
      info "  MQTT user '$NS_USER' synced to mosquitto" || true
  fi
  # Restart mosquitto to pick up new credentials
  /etc/init.d/mosquitto restart 2>/dev/null || true
fi

# Fix 1: Region hardcoding in supervisord.conf
# Docker image ships with region_eu868.toml hardcoded in gateway-mesh command;
# replace with region.toml (the canonical name created by entrypoint's cp command).
# Do NOT use region_${TMP_REGION}.toml — that file doesn't exist at runtime.
info "  Fixing supervisord region config..."
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
  "sed -i 's|region_[a-z0-9_]*\.toml|region.toml|g' /etc/supervisord.conf" && \
  info "    region -> region.toml" || error "Fix 1 failed: region sed replacement"

# Fix 1b: gateway-mesh startup race — wait for concentratord ZMQ socket
# Two problems:
# 1. docker restart preserves /tmp → stale socket files from previous run
#    fool gateway-mesh into thinking concentratord is ready
# 2. concentratord needs ~3s to initialize SX1302 and create ZMQ sockets
# Fix: clean stale sockets in entrypoint + wrapper waits for fresh socket
info "  Fixing gateway-mesh startup race (socket wait)..."
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c '
# Clean stale sockets on entrypoint startup (before supervisord)
if ! grep -q "rm -f /tmp/concentratord_" /opt/chirpstack/entrypoint.sh; then
  sed -i "/^exec.*supervisord/i rm -f /tmp/concentratord_* /tmp/forwarder_* 2>/dev/null" \
    /opt/chirpstack/entrypoint.sh
fi
# Create wrapper that waits for fresh ZMQ socket
cat > /opt/chirpstack/start_gateway_mesh.sh << "GWEOF"
#!/bin/sh
cd /opt/chirpstack
SOCK="/tmp/${SOCKET_NAME:-concentratord}_event"
i=0
while [ $i -lt 30 ]; do
  [ -S "$SOCK" ] && break
  sleep 0.3
  i=$((i+1))
done
exec ./chirpstack-gateway-mesh "$@"
GWEOF
chmod +x /opt/chirpstack/start_gateway_mesh.sh
sed -i "s|command=/opt/chirpstack/chirpstack-gateway-mesh -c|command=/opt/chirpstack/start_gateway_mesh.sh -c|" /etc/supervisord.conf
' && info "    socket cleanup + wrapper installed" || error "Fix 1b failed: gateway-mesh wrapper"

# Fix 1c: supervisord.conf missing supervisorctl sections
# Docker image's supervisord.conf only has [supervisord] and [program:*],
# missing [unix_http_server], [supervisorctl], [rpcinterface:supervisor]
# — without these, supervisorctl returns errors and Web UI Status page is empty
info "  Adding supervisorctl sections to supervisord.conf..."
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c '
  grep -q "unix_http_server" /etc/supervisord.conf || cat >> /etc/supervisord.conf << "EOF"

[unix_http_server]
file=/var/run/supervisor.sock

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
EOF
' && info "    supervisorctl enabled" || error "Fix 1c failed: supervisorctl sections"

# Fix 1d: Inject v3 concentratord binary (if available)
# v3 binary includes reset.rs fix: SX130x reset pin set HIGH after reset
# sequence (Active→Inactive→Active), preventing Bug #49 at the source.
# This allows using the correct reset pin without the pin-stays-LOW problem.
# Without v3: stock binary + pin 31 (harmless) still works fine.
V3_BIN="$SCRIPT_DIR/chirpstack-concentratord-sx1302-musl-v3"
if [ -f "$V3_BIN" ]; then
  info "  Injecting v3 concentratord binary (reset fix)..."
  $DOCKER_BIN cp "$V3_BIN" ${CONTAINER_NAME}:/opt/chirpstack/binaries/chirpstack-concentratord-sx1302 && \
    $DOCKER_BIN exec ${CONTAINER_NAME} chmod +x /opt/chirpstack/binaries/chirpstack-concentratord-sx1302 && \
    $DOCKER_BIN exec ${CONTAINER_NAME} sh -c "cd /opt/chirpstack/binaries && tar czf chirpstack-concentratord-sx1302.tar.gz chirpstack-concentratord-sx1302" && \
    info "    v3 binary injected" || warn "    v3 binary injection failed, using stock"
fi

# Fix 2: Python stdout buffering — add PYTHONUNBUFFERED to supervisord
# Without this, gateway-mesh and forwarder produce NO log output in Docker
info "  Fixing Python stdout buffering..."
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c '
  # Add environment=PYTHONUNBUFFERED="1" to gateway-mesh section if missing
  if ! grep -q "PYTHONUNBUFFERED" /etc/supervisord.conf; then
    sed -i "/\[program:gateway-mesh\]/,/\[program:/{
      /^command=/a environment=PYTHONUNBUFFERED=\"1\"
    }" /etc/supervisord.conf
    sed -i "/\[program:semtech-udp-forwarder\]/,/\[program:/{
      /^command=/a environment=PYTHONUNBUFFERED=\"1\"
    }" /etc/supervisord.conf
  fi
' 2>/dev/null && info "    PYTHONUNBUFFERED=1 added" || true

# Fix 3: Relay mode — clear MQTT server to avoid connection overhead
if [ "$RELAY_BORDER" != "true" ]; then
  $DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
    'sed -i '"'"'s|server="tcp://.*"|server=""|'"'"' /opt/chirpstack/mqtt_forwarder.toml 2>/dev/null' && \
    info "    Relay mode: MQTT server cleared" || true
fi

# Fix 5: Banner — show gateway model (UG65/EG71/etc.) instead of radio module name
# MODEL env var must stay as radio module (rak_2287) for concentratord config;
# inject literal gateway name directly into entrypoint banner.
info "  Fixing entrypoint banner model display..."
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
  "sed -i 's|.*echo \" Model:.*|echo \" Model:         ${GW_MODEL}\"|' /opt/chirpstack/entrypoint.sh 2>/dev/null" && \
  info "    banner -> ${GW_MODEL}" || true

# Fix 4: Add data-rate mapping to ALL region templates
# Docker image only has [gateway.beacon], missing [gateway.band] data-rate mapping
# Gateway-mesh needs this to map SF/BW to LoRaWAN DR index
# Inject into SOURCE templates so entrypoint copies them on every restart
info "  Injecting data-rate mappings for all regions..."
BAND_OK=0; BAND_FAIL=0; BAND_TOTAL=0
# Download active region first (most critical)
BAND_ORDER="$TMP_REGION"
for BAND_R in eu868 us915 in865 au915 as923 as923_2 as923_3 as923_4 kr920 ru864 eu433; do
  [ "$BAND_R" != "$TMP_REGION" ] && BAND_ORDER="$BAND_ORDER $BAND_R"
done
for BAND_R in $BAND_ORDER; do
  BAND_TOTAL=$((BAND_TOTAL + 1))
  BAND_FILE="${WORK_DIR}/band_${BAND_R}.toml"
  if download "${OSS_BASE}/band_${BAND_R}.toml" "$BAND_FILE" 2>/dev/null; then
    if $DOCKER_BIN cp "$BAND_FILE" ${CONTAINER_NAME}:/tmp/band.toml 2>/dev/null && \
       $DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
         "REGION_FILE=/opt/chirpstack/configs/chirpstack-concentratord-sx1302/region_${BAND_R}.toml; \
          [ -f \"\$REGION_FILE\" ] || touch \"\$REGION_FILE\"; \
          grep -q '\\[mappings\\]' \"\$REGION_FILE\" 2>/dev/null || \
          cat /tmp/band.toml >> \"\$REGION_FILE\"; rm -f /tmp/band.toml" 2>/dev/null; then
      BAND_OK=$((BAND_OK + 1))
    else
      BAND_FAIL=$((BAND_FAIL + 1))
    fi
  else
    BAND_FAIL=$((BAND_FAIL + 1))
  fi
done
info "    ${BAND_OK}/${BAND_TOTAL} regions injected (${BAND_FAIL} unavailable)"
# Active region band data is critical — check it was injected
if ! echo "$TMP_REGION" | grep -q "cn470"; then
  ACTIVE_INJECTED=false
  for OK_R in eu868 us915 in865 au915 as923 as923_2 as923_3 as923_4 kr920 ru864 eu433; do
    [ "$TMP_REGION" = "$OK_R" ] && ACTIVE_INJECTED=true && break
  done
  if [ "$ACTIVE_INJECTED" = "true" ] && [ "$BAND_FAIL" -gt 0 ]; then
    # Re-check specifically: did our region's band file succeed?
    if ! $DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
      "grep -q '\[mappings\]' /opt/chirpstack/configs/chirpstack-concentratord-sx1302/region_${TMP_REGION}.toml 2>/dev/null"; then
      error "Band data for active region '${TMP_REGION}' injection failed"
    fi
  fi
fi

# Setup nginx for HTTP+HTTPS reverse proxy to Flask web UI
# Retry apk add (container network may be slow to stabilize after start)
info "  Setting up nginx reverse proxy..."
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c '
  if ! command -v nginx >/dev/null 2>&1; then
    for i in 1 2 3; do
      apk add --no-cache nginx 2>/dev/null && break
      echo "apk attempt $i failed, retrying in 5s..."
      sleep 5
    done
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    echo "NGINX_INSTALL_FAILED"
    exit 1
  fi
  # Write nginx site config
  cat > /etc/nginx/http.d/mesh.conf << "NGINXEOF"
server {
    listen 8080;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
server {
    listen 8443 ssl;
    server_name _;
    ssl_certificate /etc/ssl_cert;
    ssl_certificate_key /etc/ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINXEOF
  rm -f /etc/nginx/http.d/default.conf
  # Add nginx to supervisord if not already present
  grep -q "program:nginx" /etc/supervisord.conf || cat >> /etc/supervisord.conf << "SUPEOF"

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
startsecs=1
stdout_logfile=/tmp/nginx.log
stderr_logfile=/tmp/nginx.log
redirect_stderr=true
SUPEOF
' 2>/dev/null && info "    nginx installed + configured" || warn "    nginx install failed — Web UI only accessible via docker exec. Rebuild image with nginx baked in."

# UG56: inject custom concentratord binary with sysfs GPIO support + patch entrypoint
if [ "$PRODUCT" = "56" ]; then
  info "  UG56: injecting custom concentratord (sysfs GPIO)..."

  # Remove tarball to prevent start_concentratord.sh from overwriting our custom binary
  $DOCKER_BIN exec ${CONTAINER_NAME} rm -f /opt/chirpstack/binaries/chirpstack-concentratord-sx1302.tar.gz

  # Check local persistent path first, then try download
  LOCAL_BIN="/etc/chirpstack-concentratord-sx1302-sysfs"
  if [ -f "$LOCAL_BIN" ]; then
    $DOCKER_BIN cp "$LOCAL_BIN" ${CONTAINER_NAME}:/opt/chirpstack/binaries/chirpstack-concentratord-sx1302 && \
      info "    using local binary: $LOCAL_BIN"
  else
    CONCENTRATORD_URL="${OSS_BASE}/chirpstack-concentratord-sx1302-sysfs"
    download "$CONCENTRATORD_URL" "${WORK_DIR}/chirpstack-concentratord-sx1302-sysfs" && \
      $DOCKER_BIN cp "${WORK_DIR}/chirpstack-concentratord-sx1302-sysfs" ${CONTAINER_NAME}:/opt/chirpstack/binaries/chirpstack-concentratord-sx1302 && \
      cp "${WORK_DIR}/chirpstack-concentratord-sx1302-sysfs" "$LOCAL_BIN" && \
      info "    downloaded and cached binary" || error "UG56 concentratord binary download failed"
  fi
  $DOCKER_BIN exec ${CONTAINER_NAME} chmod +x /opt/chirpstack/binaries/chirpstack-concentratord-sx1302 2>/dev/null

  # Write UG56 patch script (copy from persistent host path, download if missing)
  info "  UG56: writing patch script..."
  HOST_PATCH="/etc/ug56_patch.sh"
  if [ ! -f "$HOST_PATCH" ]; then
    PATCH_URL="${OSS_BASE}/ug56_patch.sh"
    download "$PATCH_URL" "$HOST_PATCH" && \
      info "    downloaded ug56_patch.sh from OSS" || \
      error "UG56 ug56_patch.sh download failed"
  fi
  if [ -f "$HOST_PATCH" ]; then
    $DOCKER_BIN cp "$HOST_PATCH" ${CONTAINER_NAME}:/opt/chirpstack/ug56_patch.sh && \
      $DOCKER_BIN exec ${CONTAINER_NAME} chmod +x /opt/chirpstack/ug56_patch.sh && \
      info "    patch script injected"
  else
    error "    ug56_patch.sh not available — UG56 cannot function without it"
  fi

  # Patch entrypoint to source the patch script before exec supervisord
  # Use awk (reliable across BusyBox versions — sed \n may not work)
  info "  UG56: patching entrypoint..."
  $DOCKER_BIN exec ${CONTAINER_NAME} sh -c '
    if ! grep -q "ug56_patch" /opt/chirpstack/entrypoint.sh; then
      awk "/^exec \/usr\/bin\/supervisord/{print \"source \/opt\/chirpstack\/ug56_patch.sh\"} {print}" \
        /opt/chirpstack/entrypoint.sh > /tmp/ep_patched && \
        mv /tmp/ep_patched /opt/chirpstack/entrypoint.sh && \
        chmod +x /opt/chirpstack/entrypoint.sh
    fi
  ' 2>/dev/null && info "    entrypoint patched" || error "UG56 entrypoint patch failed"
fi

# Password sync watcher: background process that copies user_permission.conf when changed
# (skip docker cp if already volume-mounted)
if [ -f /etc/quagga/user_permission.conf ]; then
  # Only copy if not already volume-mounted
  $DOCKER_BIN cp /etc/quagga/user_permission.conf ${CONTAINER_NAME}:/etc/host_user_permission 2>/dev/null || true
  # Start a background watcher on the host (runs as a procd service)
  cat > /etc/init.d/mesh_pwd_sync << 'PWDEOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=99
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c '
        CONTAINER=chirpstack-mesh
        SRC=/etc/quagga/user_permission.conf
        DST=/etc/host_user_permission
        LAST=""
        while true; do
            if [ -f "$SRC" ]; then
                CUR=$(md5sum "$SRC" 2>/dev/null | cut -d" " -f1)
                if [ "$CUR" != "$LAST" ] && [ -n "$CUR" ]; then
                    LAST="$CUR"
                    for DBIN in /overlay/docker/bin/docker /usr/bin/docker/docker; do
                        if [ -x "$DBIN" ]; then
                            $DBIN cp "$SRC" "$CONTAINER:$DST" 2>/dev/null && break
                        fi
                    done
                fi
            fi
            sleep 5
        done
    '
    procd_set_param respawn
    procd_close_instance
}
PWDEOF
  chmod +x /etc/init.d/mesh_pwd_sync
  /etc/init.d/mesh_pwd_sync start 2>/dev/null
  info "  Password sync watcher started"
fi

# Write gateway_eui.txt for semtech-udp-forwarder
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c "echo ${GATEWAY_EUI} | tr 'A-F' 'a-f' > /opt/chirpstack/gateway_eui.txt" 2>/dev/null \
  && info "  gateway_eui.txt written (${GATEWAY_EUI})" \
  || error "gateway_eui.txt write failed"
$DOCKER_BIN exec ${CONTAINER_NAME} ln -sf /tmp/mesh.log /tmp/gateway-mesh.log 2>/dev/null

# ── Pre-restart verification: confirm all critical fixes were applied ──
info "Verifying all fixes applied..."
VERIFY_OK=true
SUPERVISORD=$($DOCKER_BIN exec ${CONTAINER_NAME} cat /etc/supervisord.conf 2>/dev/null)
ENTRYPOINT=$($DOCKER_BIN exec ${CONTAINER_NAME} cat /opt/chirpstack/entrypoint.sh 2>/dev/null)

echo "$SUPERVISORD" | grep -q "region\.toml" || { warn "  ❌ region.toml not in supervisord.conf"; VERIFY_OK=false; }
echo "$SUPERVISORD" | grep -q "start_gateway_mesh.sh" || { warn "  ❌ gateway-mesh wrapper not in supervisord.conf"; VERIFY_OK=false; }
echo "$SUPERVISORD" | grep -q "unix_http_server" || { warn "  ❌ supervisorctl section missing"; VERIFY_OK=false; }
echo "$SUPERVISORD" | grep -q "program:nginx" || { warn "  ❌ nginx not in supervisord.conf"; VERIFY_OK=false; }
echo "$ENTRYPOINT" | grep -q "rm -f /tmp/concentratord_" || { warn "  ❌ socket cleanup not in entrypoint"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} test -x /opt/chirpstack/start_gateway_mesh.sh || { warn "  ❌ wrapper script missing"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'command -v nginx' >/dev/null 2>&1 || { warn "  ❌ nginx binary not installed"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'python3 -c "import zmq"' 2>/dev/null || { warn "  ❌ pyzmq not installed"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'python3 -c "from Crypto.Cipher import AES"' 2>/dev/null || { warn "  ❌ pycryptodome not installed"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} test -s /opt/chirpstack/gateway_eui.txt || { warn "  ❌ gateway_eui.txt missing or empty"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} grep -q "mesh context aware" /opt/chirpstack/mesh_forwarder.py 2>/dev/null || { warn "  ❌ mesh_forwarder.py v2.2 not injected (check OSS version)"; VERIFY_OK=false; }

if [ "$VERIFY_OK" = "true" ]; then
  info "  ✅ All fixes verified"
else
  warn "Pre-restart verification had warnings — continuing anyway (check warnings above)"
fi

# ── Step 9: Final restart — apply ALL injected changes ──
# This is critical: entrypoint re-copies source templates (now with band data)
# to runtime files, and supervisord picks up all config changes from a clean state
info "Step 9/9: Restarting container to apply all changes..."
$DOCKER_BIN restart ${CONTAINER_NAME}
info "  Waiting for services to initialize (polling up to 90s)..."

# Poll critical processes via supervisorctl until all RUNNING or timeout
WAIT_OK=true
for PROC in concentratord gateway-mesh nginx web-ui; do
  ELAPSED=0
  PROC_OK=false
  while [ $ELAPSED -lt 90 ]; do
    STATUS=$($DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl status "$PROC" 2>/dev/null)
    case "$(echo "$STATUS" | awk '{print $2}')" in
      RUNNING)
        info "  ✅ $PROC running (${ELAPSED}s)"
        PROC_OK=true
        break
        ;;
      FATAL)
        if [ $ELAPSED -lt 60 ]; then
          warn "  ⚠️ $PROC FATAL at ${ELAPSED}s, restarting..."
          $DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl restart "$PROC" 2>/dev/null
        fi
        ;;
    esac
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done
  if [ "$PROC_OK" = "false" ]; then
    warn "  ❌ $PROC not running after 90s"
    WAIT_OK=false
  fi
done

# Border mode: start semtech-udp-forwarder for local NS connectivity
if [ "$RELAY_BORDER" = "true" ]; then
  info "  Starting semtech-udp-forwarder (border → local NS via Semtech UDP)..."
  $DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl start semtech-udp-forwarder 2>/dev/null \
    && info "  ✅ semtech-udp-forwarder started" \
    || warn "  ⚠️ semtech-udp-forwarder failed to start (check pyzmq installation)"
fi

# ── Deployment summary ──
sleep 2
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}')

if [ "$WAIT_OK" = "true" ]; then
  echo ""
  echo "============================================"
  echo " ${GREEN}ChirpStack LoRa Mesh deployed!${NC}"
  echo "============================================"
  echo " Role:     ${ROLE}"
  echo " Device:   ${GW_MODEL}, Band ${GW_BAND}MHz"
  echo " GPIO:     ${GPIO_CHIP_DEV} pin ${SX1302_RESET_GPIO}"
  echo " EUI:      ${GATEWAY_EUI}"
  echo " Mesh Freq: $(echo $DEFAULT_FREQS | tr ',' '/')"
  echo " Web UI:   http://${HOST_IP:-<gateway-ip>}:8088"
  echo " HTTPS:    https://${HOST_IP:-<gateway-ip>}:8443"
  echo ""
  echo " Logs:   ${DOCKER_BIN} logs -f ${CONTAINER_NAME}"
  echo "============================================"
else
  echo ""
  echo "============================================"
  echo " ${RED}Deployment INCOMPLETE — check logs${NC}"
  echo "============================================"
  echo " Device:  ${GW_MODEL}, Band ${GW_BAND}MHz"
  echo " Logs:    ${DOCKER_BIN} logs --tail 50 ${CONTAINER_NAME}"
  echo " Procs:   ${DOCKER_BIN} exec ${CONTAINER_NAME} ps w"
  echo "============================================"
  exit 1
fi
