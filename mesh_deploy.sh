#!/bin/sh
# ============================================================
#  ChirpStack LoRa Mesh 一键部署脚本
#  适用于: Milesight UG56/UG63/UG65/UG67/EG71 网关
#
#  零操作部署（无需任何前置或后续手工步骤）:
#    wget -qO- <OSS>/mesh_deploy.sh | sh              # 自动判定角色
#    wget -qO- <OSS>/mesh_deploy.sh | sh -s -- --border
#
#  管道执行天然规避 CRLF 问题；若下载成文件再跑，脚本会自愈行尾。
# ============================================================
# Don't use set -e: individual commands have explicit error handling

# ── CRLF self-heal: if this file has CRLF, strip and re-exec ──
if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "-sh" ]; then
  if head -1 "$0" 2>/dev/null | od -c 2>/dev/null | grep -q '\\r'; then
    sed -i 's/\r$//' "$0" 2>/dev/null && exec sh "$0" "$@"
  fi
fi

OSS_BASE="https://ursalink-resource-center.oss-us-west-1.aliyuncs.com/kevin"
IMAGE_URL="${OSS_BASE}/chirpstack-mesh-gw.tar.gz"
DOCKER_URL="${OSS_BASE}/docker.tgz"
COMPOSE_URL="${OSS_BASE}/docker-compose.tgz"
MILESIGHT_BIN_URL="${OSS_BASE}/chirpstack-concentratord-sx1302-milesight-coldstart"
IMAGE_NAME="chirpstack-mesh-gw"
CONTAINER_NAME="chirpstack-mesh"
WORK_DIR="/tmp/mesh-deploy"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /tmp)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
# BusyBox ash's builtin echo does not interpret \033 — printf does, everywhere.
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

# BusyBox-safe process check (pgrep -a unsupported; `ps w | grep -c` counts grep itself)
proc_running() {
  if command -v pidof >/dev/null 2>&1; then
    pidof "$1" >/dev/null 2>&1 && return 0
  fi
  ps w 2>/dev/null | grep -v grep | grep -q "[ /]$1"
}
download() {
  _DL_URL="$1"; _DL_OUT="$2"
  # Offline mode: check for local file in script directory
  _DL_BASE=$(basename "$_DL_URL")
  if [ -f "$SCRIPT_DIR/$_DL_BASE" ]; then
    cp "$SCRIPT_DIR/$_DL_BASE" "$_DL_OUT"
    return 0
  fi
  # Online mode. Gateways behind a cellular/NAT uplink drop out for tens of
  # seconds at a time ("Network is unreachable"), so back off progressively
  # rather than giving up after ~9s.
  _DL_OK=false
  _DL_DELAY=5
  for _DL_TRY in 1 2 3 4 5 6; do
    if command -v curl >/dev/null 2>&1; then
      curl -fSL --connect-timeout 20 --max-time 600 --retry 2 --retry-delay 5 "$_DL_URL" -o "$_DL_OUT" 2>/dev/null && { _DL_OK=true; break; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=20 --tries=2 "$_DL_URL" -O "$_DL_OUT" 2>/dev/null && { _DL_OK=true; break; }
    else
      error "Neither curl nor wget available"
    fi
    rm -f "$_DL_OUT" 2>/dev/null
    if [ "$_DL_TRY" -lt 6 ]; then
      warn "  download attempt ${_DL_TRY} failed, retrying in ${_DL_DELAY}s: $_DL_BASE"
      sleep "$_DL_DELAY"
      _DL_DELAY=$((_DL_DELAY * 2))
    fi
  done
  [ "$_DL_OK" = "true" ] || return 1
}

# Unexport every GPIO that reset_lgw.sh will export.
# reset_lgw.sh exports 3 model-specific pins; if ANY one is already exported
# its export write fails, direction never becomes "out", and the reset pulse
# silently does nothing ("write error: Device or resource busy").
gpio_unexport_all() {
  for GPIO_DIR in /sys/class/gpio/gpio*; do
    [ -e "$GPIO_DIR" ] || continue
    GPIO_NAME=$(basename "$GPIO_DIR" 2>/dev/null)
    case "$GPIO_NAME" in gpiochip*|gpiolib*) continue ;; esac
    echo "$GPIO_NAME" | grep -q '^gpio' || continue
    NUM=$(echo "$GPIO_NAME" | sed 's/^gpio//')
    echo "$NUM" | grep -q '^[0-9][0-9]*$' || continue
    echo "$NUM" > /sys/class/gpio/unexport 2>/dev/null || true
  done
}

# Full SX1302 hardware reset: clean GPIO state → reset pulse → clean again.
# Verifies the reset actually ran (reset_lgw.sh prints nothing on success but
# emits "Device or resource busy" on failure).
sx1302_hw_reset() {
  gpio_unexport_all
  if [ -f /usr/sbin/reset_lgw.sh ]; then
    _RST_OUT=$(/usr/sbin/reset_lgw.sh start 2>&1)
    if echo "$_RST_OUT" | grep -qi "busy\|error"; then
      warn "  reset_lgw.sh reported: $(echo "$_RST_OUT" | grep -i 'busy\|error' | head -1)"
      gpio_unexport_all
      sleep 1
      _RST_OUT=$(/usr/sbin/reset_lgw.sh start 2>&1)
      echo "$_RST_OUT" | grep -qi "busy\|error" && \
        warn "  SX1302 reset still failing — cold start may not wake SX1250" || \
        info "  SX1302 hardware reset OK (retry)"
    else
      info "  SX1302 hardware reset OK"
    fi
  else
    warn "  /usr/sbin/reset_lgw.sh not found — skipping hardware reset"
  fi
  sleep 1
  gpio_unexport_all
}

# Stop the native packet forwarder for good.
# init.d has "respawn retry=10000" → procd restarts it after SIGKILL unless the
# service registration is deleted via ubus.
stop_pkt_fwd() {
  # init.d has "respawn retry=10000"; procd restarts pkt_fwd after SIGKILL
  # unless the service registration is deleted. Order matters: disable first so
  # a re-registration during our work does not auto-start it.
  /etc/init.d/lora_pkt_fwd disable 2>/dev/null || true
  ubus call service delete '{"name":"lora_pkt_fwd"}' 2>/dev/null || true
  killall -9 lora_pkt_fwd station 2>/dev/null || true
  sleep 2
  # procd may re-register between our delete and now — keep knocking it down
  _PF_TRY=0
  while proc_running lora_pkt_fwd && [ "$_PF_TRY" -lt 5 ]; do
    ubus call service delete '{"name":"lora_pkt_fwd"}' 2>/dev/null || true
    killall -9 lora_pkt_fwd 2>/dev/null || true
    sleep 2
    _PF_TRY=$((_PF_TRY + 1))
  done
  if proc_running lora_pkt_fwd; then
    warn "  pkt_fwd could not be stopped after ${_PF_TRY} attempts — it holds SPI, radio will fail"
  else
    info "  Native pkt_fwd stopped and disabled"
  fi
}

# ── Parse arguments ──

ROLE=""
for arg in "$@"; do
  case "$arg" in
    --relay)  ROLE="relay" ;;
    --border) ROLE="border" ;;
  esac
done

# Auto-select role when not given: a gateway running the built-in Network Server
# is the natural Border (it has somewhere to deliver unwrapped uplinks).
if [ -z "$ROLE" ]; then
  if proc_running loraserver; then
    ROLE="border"
    info "Auto-detected role: border (built-in NS running)"
  else
    ROLE="relay"
    info "Auto-detected role: relay (no built-in NS)"
  fi
fi
RELAY_BORDER="false"
[ "$ROLE" = "border" ] && RELAY_BORDER="true"
info "Deploying as ${ROLE} gateway"

mkdir -p "$WORK_DIR"

# dockerd loads iptables .so files directly (not via the iptables CLI) and they
# live outside the default search path. Without this, NAT chains and port
# publishing (-p) silently break. Must be set before ANY dockerd start attempt,
# including the "already installed but stopped" path.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/lib/iptables"

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
    warn "Removing existing container: $EXISTING"
    $DOCKER_BIN rm -f "$CONTAINER_NAME" 2>/dev/null || true
    info "Old container removed"
  fi
else
  info "Docker not found, will install"
fi

# ── Step 2: Install Docker if needed ──

info "Step 2/9: Checking Docker..."

# Fast path: binaries already extracted but daemon is down — just start it.
# Avoids re-downloading 48 MB on a gateway that merely rebooted.
if [ -z "$DOCKER_BIN" ] || ! $DOCKER_BIN info >/dev/null 2>&1; then
  if [ -x /overlay/docker/bin/dockerd ] || [ -x /usr/bin/docker/dockerd ]; then
    info "  Docker installed but daemon not running — starting..."
    /etc/init.d/docker start 2>/dev/null
    sleep 8
    for path in /usr/bin/docker/docker /overlay/docker/bin/docker; do
      if [ -x "$path" ] && "$path" info >/dev/null 2>&1; then DOCKER_BIN="$path"; break; fi
    done
    # init.d may not export LD_LIBRARY_PATH — start dockerd directly if it failed
    if [ -z "$DOCKER_BIN" ]; then
      warn "  init.d start failed, launching dockerd directly (with iptables libs)..."
      killall dockerd containerd 2>/dev/null; sleep 2
      _DOCKERD=/overlay/docker/bin/dockerd
      [ -x "$_DOCKERD" ] || _DOCKERD=/usr/bin/docker/dockerd
      "$_DOCKERD" --config-file /etc/docker/daemon.json >/tmp/dockerd.log 2>&1 &
      sleep 10
      for path in /usr/bin/docker/docker /overlay/docker/bin/docker; do
        if [ -x "$path" ] && "$path" info >/dev/null 2>&1; then DOCKER_BIN="$path"; break; fi
      done
    fi
    [ -n "$DOCKER_BIN" ] && info "  Docker daemon started: $DOCKER_BIN"
    # Existing container may now be visible — remove it
    if [ -n "$DOCKER_BIN" ]; then
      $DOCKER_BIN ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$" && {
        warn "  Removing existing container found after daemon start"
        $DOCKER_BIN rm -f "$CONTAINER_NAME" 2>/dev/null || true
      }
    fi
  fi
fi

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
    # BusyBox tar on some UG65 firmware silently fails on full extraction to overlay fs.
    # Extract individual binaries to /tmp first, then copy (proven workaround).
    _TAR_TMP="/tmp/docker_extract_$$"
    mkdir -p "$_TAR_TMP"
    tar -xzf "${INSTALL_DIR}/docker.tgz" -C "$_TAR_TMP" 2>/dev/null
    _BIN_SRC=""
    for _d in "$_TAR_TMP/usr/bin/docker" "$_TAR_TMP/usr/bin" "$_TAR_TMP"; do
      if [ -f "$_d/dockerd" ]; then _BIN_SRC="$_d"; break; fi
    done
    if [ -n "$_BIN_SRC" ]; then
      for _f in "$_BIN_SRC"/*; do
        [ -f "$_f" ] || continue
        _bn=$(basename "$_f")
        cp "$_f" "/overlay/docker/bin/$_bn" 2>/dev/null && chmod +x "/overlay/docker/bin/$_bn"
        cp "$_f" "/usr/bin/docker/$_bn" 2>/dev/null && chmod +x "/usr/bin/docker/$_bn"
      done
      info "  Extracted $(ls /overlay/docker/bin/ | wc -w) binaries via per-file copy"
    else
      # Last resort: extract to root (tarball structure: usr/bin/docker/...)
      tar -xzf "${INSTALL_DIR}/docker.tgz" -C / 2>/dev/null
      cp -a /usr/bin/docker/* /overlay/docker/bin/ 2>/dev/null
    fi
    rm -rf "$_TAR_TMP"
    touch /overlay/docker/bin/.docker_installed 2>/dev/null

    if [ ! -f "$DOCKER_PROG" ]; then
      error "Docker installation failed — dockerd not found after extraction. Check: tail -f /etc/urlog/system.log | grep docker"
    fi
    info "  Manual extraction succeeded"
    # Create symlinks in /usr/bin so Docker binaries are in PATH
    for _f in /overlay/docker/bin/*; do
      [ -f "$_f" ] || continue
      _bn=$(basename "$_f")
      ln -sf "$_f" "/usr/bin/$_bn" 2>/dev/null
    done
    # Also symlink runc to /usr/sbin (some dockerd versions look there)
    [ -f /overlay/docker/bin/runc ] && ln -sf /overlay/docker/bin/runc /usr/sbin/runc 2>/dev/null
  fi

  # Install docker-compose if present
  if [ -f "${INSTALL_DIR}/docker-compose.tgz" ] && [ ! -f /overlay/docker/bin/docker-compose ]; then
    tar -xzf "${INSTALL_DIR}/docker-compose.tgz" -C /overlay/docker/bin 2>/dev/null
    chmod +x /overlay/docker/bin/docker-compose 2>/dev/null
  fi

  info "  Starting Docker service..."
  # CRITICAL: iptables needs libiptext.so which is not in default LD_LIBRARY_PATH.
  # Without this, dockerd fails to create NAT chains and port mapping (-p) breaks.
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/lib/iptables"
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

  # Fallback: if init.d didn't start dockerd, start directly with LD_LIBRARY_PATH
  if [ -z "$DOCKER_BIN" ] && [ -x "/overlay/docker/bin/dockerd" ]; then
    warn "  init.d docker start failed, starting dockerd directly..."
    killall dockerd containerd 2>/dev/null; sleep 2
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" /overlay/docker/bin/dockerd \
      --config-file /etc/docker/daemon.json >/tmp/dockerd.log 2>&1 &
    sleep 10
    for path in /overlay/docker/bin/docker /usr/bin/docker/docker; do
      if [ -x "$path" ] && "$path" info >/dev/null 2>&1; then
        DOCKER_BIN="$path"
        break
      fi
    done
  fi

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

info "Step 3/9: Loading Mesh image (~45 MB)..."

# Remove old mesh images to prevent overlay2 "max depth exceeded"
# (accumulated orphan layers from previous load/rmi cycles)
OLD_IMG=$($DOCKER_BIN images --format "{{.ID}}" "${IMAGE_NAME}" 2>/dev/null | head -1)
if [ -n "$OLD_IMG" ]; then
  info "  Removing old image..."
  $DOCKER_BIN rmi -f "$OLD_IMG" 2>/dev/null || true
fi

IMAGE_TGZ="${WORK_DIR}/chirpstack-mesh-gw.tar.gz"
MIN_IMAGE_SIZE=20000000

# A cached tarball from an interrupted run is often truncated and makes
# `docker load` fail with "unexpected EOF". Validate before trusting it.
if [ -f "$IMAGE_TGZ" ]; then
  _ISZ=$(wc -c < "$IMAGE_TGZ" 2>/dev/null || echo 0)
  if [ "$_ISZ" -lt "$MIN_IMAGE_SIZE" ] 2>/dev/null || ! gzip -t "$IMAGE_TGZ" 2>/dev/null; then
    warn "  Cached image is truncated/corrupt (${_ISZ} bytes) — re-downloading"
    rm -f "$IMAGE_TGZ"
  else
    info "  Using cached image (${_ISZ} bytes)"
  fi
fi

if [ ! -f "$IMAGE_TGZ" ]; then
  download "$IMAGE_URL" "$IMAGE_TGZ" || { rm -f "$IMAGE_TGZ"; error "Docker image download failed"; }
  _ISZ=$(wc -c < "$IMAGE_TGZ" 2>/dev/null || echo 0)
  if [ "$_ISZ" -lt "$MIN_IMAGE_SIZE" ] 2>/dev/null || ! gzip -t "$IMAGE_TGZ" 2>/dev/null; then
    rm -f "$IMAGE_TGZ"
    error "Downloaded image is corrupt (${_ISZ} bytes). Check connectivity to ${OSS_BASE}"
  fi
fi

_load_image() {
  $DOCKER_BIN load -i "$IMAGE_TGZ" 2>&1
}
LOAD_OUT=$(_load_image)
# Only wipe overlay2 for genuine storage-driver problems. A corrupt tarball
# ("unexpected EOF", "invalid tar header") is not fixed by deleting storage —
# and wiping it would destroy any other containers on the gateway.
if echo "$LOAD_OUT" | grep -qi "max depth\|too many links\|no space left"; then
  warn "  Docker overlay2 depth limit reached — cleaning storage..."
  $DOCKER_BIN stop $($DOCKER_BIN ps -aq) 2>/dev/null || true
  $DOCKER_BIN rm -f $($DOCKER_BIN ps -aq) 2>/dev/null || true
  /etc/init.d/docker stop 2>/dev/null
  sleep 3
  rm -rf /overlay/docker/overlay2 /overlay/docker/image /overlay/docker/containers
  /etc/init.d/docker start 2>/dev/null
  sleep 5
  DOCKER_BIN=""
  for d in /usr/bin/docker/docker /overlay/docker/bin/docker; do
    [ -x "$d" ] && DOCKER_BIN="$d" && break
  done
  [ -z "$DOCKER_BIN" ] && command -v docker >/dev/null 2>&1 && DOCKER_BIN="docker"
  [ -z "$DOCKER_BIN" ] && error "Docker not available after restart"
  LOAD_OUT=$(_load_image)
  echo "$LOAD_OUT" | grep -qi "error" && error "Docker image load failed after overlay2 cleanup: $LOAD_OUT"
elif echo "$LOAD_OUT" | grep -qi "unexpected EOF\|invalid tar\|gzip"; then
  # Corrupt archive: drop it and retry once with a fresh copy
  warn "  Image archive corrupt — re-downloading and retrying load..."
  rm -f "$IMAGE_TGZ"
  download "$IMAGE_URL" "$IMAGE_TGZ" || error "Image re-download failed"
  gzip -t "$IMAGE_TGZ" 2>/dev/null || error "Re-downloaded image still corrupt — check connectivity"
  LOAD_OUT=$(_load_image)
  echo "$LOAD_OUT" | grep -qi "error" && error "Docker image load failed: $LOAD_OUT"
elif echo "$LOAD_OUT" | grep -qi "error"; then
  error "Docker image load failed: $LOAD_OUT"
fi

# Ensure image has :latest tag (tarball may have version tag like v4-stable)
if $DOCKER_BIN images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -q "${IMAGE_NAME}:" ; then
  CURRENT_TAG=$($DOCKER_BIN images --format "{{.Tag}}" "${IMAGE_NAME}" 2>/dev/null | head -1)
  if [ "$CURRENT_TAG" != "latest" ]; then
    $DOCKER_BIN tag "${IMAGE_NAME}:${CURRENT_TAG}" "${IMAGE_NAME}:latest" 2>/dev/null
    info "  Tagged ${CURRENT_TAG} → latest"
  fi
fi

# Verify image loaded successfully
$DOCKER_BIN images --format "{{.Repository}}" 2>/dev/null | grep -q "^${IMAGE_NAME}$" || \
  error "Docker image load failed — image not found after load"
info "  Image ready: $($DOCKER_BIN images --format '{{.Tag}} {{.Size}}' ${IMAGE_NAME} 2>/dev/null | head -1)"

# ── Step 4: Detect hardware ──

info "Step 4/9: Detecting hardware..."
PRODUCT=""
RESERVED=""
HWVER=""
if command -v urtool >/dev/null 2>&1; then
  UR_OUT=$(urtool -g 2>/dev/null)
  PRODUCT=$(echo "$UR_OUT" | grep "^product" | awk -F: '{print $2}' | tr -d ' ')
  RESERVED=$(echo "$UR_OUT" | grep "^reserved" | head -1 | awk -F: '{print $2}' | tr -d ' ')
  HWVER=$(echo "$UR_OUT" | grep "^hwver" | awk -F: '{print $2}' | tr -d ' ')
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

# ── Cold start on every hardware version (M33) ──
#
# History: hwver 0130/0150/0200 used to need "hot-switch" — let native pkt_fwd
# initialize SX1302/SX1250, kill -9 it, then have concentratord inherit the
# hardware state. That was a workaround for two real bugs, both now fixed:
#
#   1. sx1302_radio_reset() was skipped in milesight_mode, so SX1250 stayed in
#      SLEEP (status 0x00) and STANDBY_RC failed.        → restored (M32)
#   2. sx1302_agc_start() read back AGC mailbox 2 (FDD) unconditionally while
#      only writing it for sx125x radios. On SX1250 it compared fdd_mode
#      against a stale value → "FDD mode of Radio A has not been set properly"
#      → AGC firmware never started. Surfaced as a phantom "Radio B hang" when
#      the stale value happened to match.                → fixed (M33)
#
# With both fixed, the cold-start binary initializes every hwver from scratch:
#   sx1302_radio_reset() wakes SX1250 (0x22) → ms_sx1250_setup() → STANDBY_XOSC
#   (0x32) → AGC Radio A + Radio B + gain stages 0x04-0x0F → RX/TX working.
#
# Requirement: a real SX1302 hardware reset (reset_lgw.sh) must happen while no
# other process holds the SPI bus — handled in Step 5/6.
#
# The binary auto-detects PA type (NEWPA/OLDPA) and duplex mode via the Semtech
# register API, so one binary covers every board revision including unknown
# future hwver (e.g. UG67 0320).
MILESIGHT_BIN="$MILESIGHT_BIN_URL"
MODEL="milesight_ug65"
info "  Cold-start binary (auto PA/duplex detect) — hwver=${HWVER:-unknown}"

# Fetch it NOW, before touching pkt_fwd or creating the container. The stock
# image binary panics with "unexpected gateway model: milesight_ug65", so a
# failed download must abort while the gateway is still in its original state
# rather than leave a half-broken deployment behind.
MILESIGHT_LOCAL="/etc/chirpstack-concentratord-sx1302-milesight-coldstart"
MIN_BIN_SIZE=1000000
if [ -f "$MILESIGHT_LOCAL" ]; then
  _SZ=$(wc -c < "$MILESIGHT_LOCAL" 2>/dev/null || echo 0)
  [ "$_SZ" -lt "$MIN_BIN_SIZE" ] 2>/dev/null && { warn "  cached binary truncated (${_SZ}B), re-downloading"; rm -f "$MILESIGHT_LOCAL"; }
fi
if [ ! -f "$MILESIGHT_LOCAL" ]; then
  info "  Downloading cold-start concentratord (~5 MB)..."
  download "$MILESIGHT_BIN" "$MILESIGHT_LOCAL" || rm -f "$MILESIGHT_LOCAL"
  _SZ=$(wc -c < "$MILESIGHT_LOCAL" 2>/dev/null || echo 0)
  if [ "$_SZ" -lt "$MIN_BIN_SIZE" ] 2>/dev/null; then
    rm -f "$MILESIGHT_LOCAL"
    error "Cold-start concentratord download failed (got ${_SZ} bytes).
       Without it concentratord panics: 'unexpected gateway model: milesight_ug65'.
       Nothing has been changed on this gateway — fix connectivity to
       ${OSS_BASE} and re-run, or place the binary at:
       ${MILESIGHT_LOCAL}"
  fi
  chmod +x "$MILESIGHT_LOCAL"
  info "  Cold-start binary ready (${_SZ} bytes)"
else
  _SZ=$(wc -c < "$MILESIGHT_LOCAL")
  info "  Cold-start binary cached (${_SZ} bytes)"
fi

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

# ── Step 5: Stop packet forwarder (it holds SPI + GPIO) ──

info "Step 5/9: Stopping native packet forwarder (SPI holder)..."
stop_pkt_fwd
# Keep NS services running: loraserver, lora_app_server, lora_gateway_bridge, postgres

# ── Step 6: SX1302 hardware reset ──
# Required for cold start: reset_lgw.sh pulses the real reset pin via sysfs and
# leaves it as input (high-Z ≈ HIGH = not held in reset). Only after this can
# concentratord's sx1302_radio_reset() wake SX1250 out of SLEEP.

info "Step 6/9: SX1302 hardware reset..."
sx1302_hw_reset

# ── Start built-in NS services BEFORE container (so web_ui can detect LGB) ──
# If loraserver is running on host, start LGB + lora_app_server now.
# Container's web_ui will detect LGB on startup and auto-configure the forwarder.
if proc_running loraserver; then
  info "  Built-in NS detected — starting host services before container..."

  if command -v mosquitto_passwd >/dev/null 2>&1; then
    mosquitto_passwd -b /etc/mosquitto/pwd loraappserver "URloraappserver123456" 2>/dev/null && \
      info "    loraappserver MQTT user synced" || true
  fi

  # LGB only bridges UDP→MQTT when /tmp/pkt_fwd_type says so, otherwise its
  # init.d script exits without starting.
  if [ -f /etc/init.d/lora_gateway_bridge ]; then
    echo "lora_gateway_bridge 1" > /tmp/pkt_fwd_type 2>/dev/null || true
    if ! proc_running lora-gateway-bridge; then
      /etc/init.d/lora_gateway_bridge start 2>/dev/null && info "    LGB started" || true
    fi
    /etc/init.d/lora_gateway_bridge enable 2>/dev/null || true
  fi

  if [ -f /etc/init.d/lora_app_server ] && ! proc_running lora-app-server; then
    /etc/init.d/lora_app_server start 2>/dev/null && info "    lora_app_server started" || true
    /etc/init.d/lora_app_server enable 2>/dev/null || true
  fi
fi

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

# Region-dependent defaults.
#
# MESH_TX_POWER: on US915/AU915 Milesight boards an external PA sits in the TX
# path, gated by pa_gain in the TX gain LUT: pa_gain=0 for <=17 dBm, pa_gain=1
# for >=18 dBm. At 16 dBm the signal passes through an UNPOWERED PA and is
# attenuated into the noise floor (measured: -146 dBm at the peer). Use 27 dBm
# so pa_gain=1 powers the PA. EU868 has no external PA — 16 dBm is correct and
# also keeps duty-cycle headroom.
case "$TMP_REGION" in
  eu868)  DEFAULT_FREQS="868100000,868300000,868500000"; CHANNELS_CFG="eu868"; MESH_TX_POWER=16 ;;
  us915)  DEFAULT_FREQS="902300000,902500000,902700000"; CHANNELS_CFG="us915_0"; MESH_TX_POWER=27 ;;
  in865)  DEFAULT_FREQS="865062500,865402500,865985000"; CHANNELS_CFG="in865"; MESH_TX_POWER=16 ;;
  au915)  DEFAULT_FREQS="915200000,915400000,915600000"; CHANNELS_CFG="au915_0"; MESH_TX_POWER=27 ;;
  as923)  DEFAULT_FREQS="923200000,923400000,923600000"; CHANNELS_CFG="as923"; MESH_TX_POWER=16 ;;
  kr920)  DEFAULT_FREQS="922100000,922300000,922500000"; CHANNELS_CFG="kr920"; MESH_TX_POWER=16 ;;
  ru864)  DEFAULT_FREQS="868900000,869100000"; CHANNELS_CFG="ru864"; MESH_TX_POWER=16 ;;
  eu433)  DEFAULT_FREQS="433175000,433375000,433575000"; CHANNELS_CFG="eu433"; MESH_TX_POWER=16 ;;
  *)      DEFAULT_FREQS="868100000,868300000,868500000"; CHANNELS_CFG="eu868"; MESH_TX_POWER=16 ;;
esac
info "  Mesh TX power: ${MESH_TX_POWER} dBm$([ "$MESH_TX_POWER" -ge 18 ] && echo ' (external PA enabled)')"

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
  -v /var/run/docker.sock:/var/run/docker.sock \
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
  -e RELAY_TX_POWER=${MESH_TX_POWER} \
  -e MQTT_SERVER=tcp://192.168.45.38:1884 \
  -e MQTT_TOPIC_PREFIX=${TMP_REGION} \
  -e MQTT_BACKEND_SOCKET=forwarder \
  -e GATEWAY_EUI=${GATEWAY_EUI} \
  -e GW_BAND=${GW_BAND} \
  -e DEBUG=INFO"

# Pre-launch: GPIO must be clean so concentratord's cdev reset (harmless pin 31)
# can claim it, and SX1250 needs a moment to settle after the hardware reset.
info "  Pre-launch GPIO cleanup..."
gpio_unexport_all
info "  Waiting 5s for SX1250 stabilization..."
sleep 5

$DOCKER_BIN run $DOCKER_OPTS ${IMAGE_NAME}
sleep 3
info "Container started"

# ── Step 8: Post-deploy configuration ──
# v4-stable image has most fixes baked in (nginx, pyzmq, pycryptodome, band data,
# supervisorctl, gateway-mesh wrapper, socket cleanup, PYTHONUNBUFFERED).
# Only runtime-specific tasks remain below.

info "Step 8/9: Post-deploy configuration (v4-stable image)..."

# Verify baked-in components are present
info "  Verifying image components..."
VERIFY_OK=true
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'command -v nginx' >/dev/null 2>&1 || { warn "  ❌ nginx missing"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'python3 -c "import zmq"' 2>/dev/null || { warn "  ❌ pyzmq missing"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'python3 -c "from Crypto.Cipher import AES"' 2>/dev/null || { warn "  ❌ pycryptodome missing"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} grep -q "start_gateway_mesh.sh" /etc/supervisord.conf 2>/dev/null || { warn "  ❌ gateway-mesh wrapper missing"; VERIFY_OK=false; }
$DOCKER_BIN exec ${CONTAINER_NAME} grep -q "program:nginx" /etc/supervisord.conf 2>/dev/null || { warn "  ❌ nginx supervisord section missing"; VERIFY_OK=false; }
if [ "$VERIFY_OK" = "true" ]; then
  info "  ✅ All image components verified"
fi

# Fix mesh frequencies to match region (image default is EU868)
info "  Setting mesh frequencies for $TMP_REGION..."
# Rewrite mesh frequencies + TX power regardless of what the image shipped with.
# Anchored on the key name, not the EU868 default value, so re-deploys and any
# image default both converge to the right region settings.
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
  "sed -i 's|^\( *\)frequencies=.*|\1frequencies=[$DEFAULT_FREQS]|; s|^\( *\)tx_power=.*|\1tx_power=$MESH_TX_POWER|' /opt/chirpstack/mesh_config.toml" 2>/dev/null
MESH_CHECK=$($DOCKER_BIN exec ${CONTAINER_NAME} sh -c "grep -E '^ *(frequencies|tx_power)=' /opt/chirpstack/mesh_config.toml | tr -d ' \n'" 2>/dev/null)
if echo "$MESH_CHECK" | grep -q "tx_power=$MESH_TX_POWER"; then
  info "    mesh config: freq=$DEFAULT_FREQS tx_power=${MESH_TX_POWER}dBm"
else
  warn "    mesh config update could not be verified: $MESH_CHECK"
fi

# Inject SSL certificates via docker cp (volume mount -v is unreliable on some firmware)
if [ -f /etc/https.crt ] && [ -f /etc/https.key ]; then
  $DOCKER_BIN cp /etc/https.crt ${CONTAINER_NAME}:/etc/ssl_cert 2>/dev/null && \
    $DOCKER_BIN cp /etc/https.key ${CONTAINER_NAME}:/etc/ssl_key 2>/dev/null && \
    info "  SSL certificates injected via docker cp" || \
    warn "  SSL cert injection failed"
else
  warn "  No SSL certs found on host (/etc/https.crt, /etc/https.key) — nginx HTTPS will fail"
fi

# Inject nginx config (image default uses /etc/ssl_cert which doesn't exist)
info "  Injecting nginx config..."
$DOCKER_BIN exec ${CONTAINER_NAME} sh -c '
cat > /etc/nginx/http.d/mesh.conf << "NGXEOF"
server {
    listen 8080;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
server {
    listen 8443 ssl;
    server_name _;
    ssl_certificate /etc/ssl_cert;
    ssl_certificate_key /etc/ssl_key;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGXEOF
rm -f /etc/nginx/http.d/default.conf /etc/nginx/conf.d/default.conf
' 2>/dev/null && info "    nginx config injected" || warn "    nginx config injection failed"

# Inject Milesight cold-start concentratord binary (auto board detect).
#
# This is NOT optional: the stock image binary has no "milesight_ug65" model and
# panics with `unexpected gateway model: milesight_ug65`. If the injection can't
# be completed, fail loudly rather than leaving a broken deployment behind.
if [ -n "$MILESIGHT_BIN" ]; then
  info "  Injecting Milesight cold-start concentratord binary (~5 MB)..."
  MILESIGHT_LOCAL="/etc/chirpstack-concentratord-sx1302-milesight-coldstart"
  MIN_BIN_SIZE=1000000

  # Discard a truncated/failed cached copy from a previous run
  if [ -f "$MILESIGHT_LOCAL" ]; then
    _SZ=$(wc -c < "$MILESIGHT_LOCAL" 2>/dev/null || echo 0)
    [ "$_SZ" -lt "$MIN_BIN_SIZE" ] 2>/dev/null && { warn "    cached binary truncated (${_SZ}B), re-downloading"; rm -f "$MILESIGHT_LOCAL"; }
  fi

  if [ ! -f "$MILESIGHT_LOCAL" ]; then
    download "$MILESIGHT_BIN" "$MILESIGHT_LOCAL" || rm -f "$MILESIGHT_LOCAL"
    _SZ=$(wc -c < "$MILESIGHT_LOCAL" 2>/dev/null || echo 0)
    if [ "$_SZ" -lt "$MIN_BIN_SIZE" ] 2>/dev/null; then
      rm -f "$MILESIGHT_LOCAL"
      error "Cold-start concentratord download failed (got ${_SZ} bytes). Without it concentratord panics on model milesight_ug65. Check network access to ${OSS_BASE}"
    fi
    chmod +x "$MILESIGHT_LOCAL"
    info "    downloaded ${_SZ} bytes to $MILESIGHT_LOCAL"
  else
    info "    using cached $(wc -c < "$MILESIGHT_LOCAL") bytes"
  fi

  $DOCKER_BIN cp "$MILESIGHT_LOCAL" ${CONTAINER_NAME}:/opt/chirpstack/binaries/chirpstack-concentratord-sx1302 \
    || error "docker cp of concentratord binary failed"
  # docker cp does NOT preserve the execute bit
  $DOCKER_BIN exec ${CONTAINER_NAME} chmod +x /opt/chirpstack/binaries/chirpstack-concentratord-sx1302 \
    || error "chmod +x on injected binary failed"

  # Verify the container really has our binary (size match), and that it knows
  # the milesight_ug65 model — a stock binary would panic instead.
  _CSZ=$($DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'wc -c < /opt/chirpstack/binaries/chirpstack-concentratord-sx1302' 2>/dev/null | tr -d ' \r')
  if [ "$_CSZ" != "$_SZ" ] && [ -n "$_CSZ" ]; then
    warn "    size mismatch after cp (host=$_SZ container=$_CSZ)"
  fi
  if $DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'strings /opt/chirpstack/binaries/chirpstack-concentratord-sx1302 2>/dev/null | grep -q milesight_ug65' 2>/dev/null; then
    info "    ✅ cold-start binary injected and verified (milesight_ug65 supported)"
  else
    warn "    could not verify milesight_ug65 support in injected binary"
  fi

  # The real reset is done by reset_lgw.sh before the container starts;
  # concentratord's own cdev reset must not touch the true reset line.
  $DOCKER_BIN exec ${CONTAINER_NAME} sed -i '/sx1302_reset/d' /opt/chirpstack/concentratord.toml 2>/dev/null && \
    info "    reset pin removed from concentratord.toml" || true
fi

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
if [ -f /etc/quagga/user_permission.conf ]; then
  $DOCKER_BIN cp /etc/quagga/user_permission.conf ${CONTAINER_NAME}:/etc/host_user_permission 2>/dev/null || true
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

# Symlink for unified log access
$DOCKER_BIN exec ${CONTAINER_NAME} ln -sf /tmp/mesh.log /tmp/gateway-mesh.log 2>/dev/null

# ── Step 9: Final restart — apply ALL injected changes ──
# This is critical: entrypoint re-copies source templates (now with band data)
# to runtime files, and supervisord picks up all config changes from a clean state
info "Step 9/9: Restarting container to apply all changes..."
# Stop container first (docker restart doesn't allow a hardware reset in between)
$DOCKER_BIN stop ${CONTAINER_NAME} >/dev/null 2>&1

# pkt_fwd may have been respawned by procd during Steps 7-8; it would hold SPI
# and leave SX1250 unreachable after the reset.
if proc_running lora_pkt_fwd; then
  warn "  pkt_fwd respawned during deployment — stopping it again"
  stop_pkt_fwd
fi

# Hardware reset between stop and start — SX1250 must be reset from a state where
# nothing holds the SPI bus, otherwise it stays in SLEEP and STANDBY_RC fails.
sx1302_hw_reset

info "  Waiting 5s for SX1250 stabilization..."
sleep 5

$DOCKER_BIN start ${CONTAINER_NAME} >/dev/null 2>&1
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

# ── Cold-start retry: SX1250 stuck in SLEEP ──
# If concentratord failed with SX1250 status 0x00, the SX1302 hardware reset did
# not take effect (usually a leftover exported GPIO made reset_lgw.sh fail, or
# pkt_fwd was respawned by procd and grabbed the SPI bus again). Retry the whole
# cold-start sequence once, from a clean state.
CONC_STATUS=$($DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl status concentratord 2>/dev/null | awk '{print $2}')
CONC_LOG=$($DOCKER_BIN exec ${CONTAINER_NAME} cat /tmp/mesh.log 2>/dev/null | tail -40)
if [ "$CONC_STATUS" = "FATAL" ] || echo "$CONC_LOG" | grep -qi "failed STANDBY_RC\|lgw_start failed"; then
  warn "  ⚠️ SX1250 did not wake (status 0x00) — retrying cold start..."
  $DOCKER_BIN stop ${CONTAINER_NAME} >/dev/null 2>&1
  stop_pkt_fwd
  sx1302_hw_reset
  sleep 5
  $DOCKER_BIN start ${CONTAINER_NAME} >/dev/null 2>&1
  info "    Waiting 30s for concentratord..."
  sleep 30
  CONC_STATUS2=$($DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl status concentratord 2>/dev/null | awk '{print $2}')
  CONC_LOG2=$($DOCKER_BIN exec ${CONTAINER_NAME} cat /tmp/mesh.log 2>/dev/null | tail -30)
  if [ "$CONC_STATUS2" = "RUNNING" ] && ! echo "$CONC_LOG2" | grep -qi "failed STANDBY_RC"; then
    info "    ✅ Cold start succeeded on retry"
    $DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl restart gateway-mesh 2>/dev/null
    sleep 5
    WAIT_OK=true
  else
    warn "    ❌ SX1250 still not waking — check that no process holds SPI"
    WAIT_OK=false
  fi
fi

# ── Verify the radio actually came up (M33) ──
# supervisorctl RUNNING is NOT sufficient: concentratord stays alive after
# lgw_start() fails, so a gateway can show 4/4 processes running with a dead
# radio (SX1250 in SLEEP, Gateway ID all-zero, rx_received=0 forever).
RADIO_OK=true
RADIO_LOG=$($DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'tail -300 /tmp/mesh.log 2>/dev/null' 2>/dev/null)

if echo "$RADIO_LOG" | grep -q "failed STANDBY_RC\|lgw_start failed"; then
  warn "  ❌ SX1250 did not wake (STANDBY_RC status 0x00) — radio is dead"
  RADIO_OK=false
fi
if echo "$RADIO_LOG" | grep -q "FDD mode of Radio\|failed to start AGC firmware"; then
  warn "  ❌ AGC firmware errors — concentratord binary may predate the mailbox-2 fix (M33)"
  RADIO_OK=false
fi

# Gateway ID of all zeros (or the 0x05 repeat pattern) means OTP read failed,
# which only happens when lgw_start() did not complete.
GW_ID=$($DOCKER_BIN exec ${CONTAINER_NAME} sh -c "grep -a 'Gateway ID retrieved' /tmp/mesh.log 2>/dev/null | tail -1" 2>/dev/null | grep -oE '[0-9a-f]{16}' | tail -1)
case "$GW_ID" in
  0000000000000000|0505050505050505)
    warn "  ❌ Invalid Gateway ID ($GW_ID) — SX1302 OTP not readable, lgw_start incomplete"
    RADIO_OK=false ;;
  "") warn "  ⚠️ Gateway ID not found in log yet" ;;
  *)  info "  Gateway ID: $GW_ID" ;;
esac

if [ "$RADIO_OK" = "true" ]; then
  info "  ✅ Radio initialized (SX1250 awake, AGC clean, valid Gateway ID)"
else
  # Almost always caused by something else holding SPI/GPIO — usually procd
  # having respawned pkt_fwd. Retry the whole cold start once.
  warn "  Attempting radio recovery..."
  if proc_running lora_pkt_fwd; then
    warn "    pkt_fwd is running again (procd respawn) — stopping it"
  fi
  $DOCKER_BIN stop ${CONTAINER_NAME} >/dev/null 2>&1
  stop_pkt_fwd
  sx1302_hw_reset
  sleep 5
  $DOCKER_BIN start ${CONTAINER_NAME} >/dev/null 2>&1
  info "    Waiting 40s for concentratord..."
  sleep 40
  RADIO_LOG2=$($DOCKER_BIN exec ${CONTAINER_NAME} sh -c 'tail -200 /tmp/mesh.log 2>/dev/null' 2>/dev/null)
  GW_ID2=$($DOCKER_BIN exec ${CONTAINER_NAME} sh -c "grep -a 'Gateway ID retrieved' /tmp/mesh.log 2>/dev/null | tail -1" 2>/dev/null | grep -oE '[0-9a-f]{16}' | tail -1)
  if echo "$RADIO_LOG2" | grep -q "failed STANDBY_RC" || \
     [ "$GW_ID2" = "0000000000000000" ] || [ "$GW_ID2" = "0505050505050505" ]; then
    warn "  ❌ Radio still dead after recovery (Gateway ID: ${GW_ID2:-none})"
    warn "     Check that nothing else holds SPI: ps w | grep lora_pkt_fwd"
    WAIT_OK=false
  else
    info "  ✅ Radio recovered (Gateway ID: $GW_ID2)"
    $DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl restart gateway-mesh 2>/dev/null
    sleep 5
  fi
fi

# Border mode: connect to the built-in NS.
# MUST use Semtech UDP, never mqtt-forwarder: ChirpStack v4 mqtt-forwarder speaks
# MQTT v5 while the gateway's mosquitto 1.4.15 only supports v3.1.1 ("Invalid
# protocol version 5"). The UDP path goes forwarder → LGB → loraserver.
if [ "$RELAY_BORDER" = "true" ]; then
  if proc_running loraserver; then
    info "  Built-in NS detected — using Semtech UDP path (mqtt-forwarder stays off)"
    $DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl stop mqtt-forwarder 2>/dev/null || true
    $DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
      'printf "semtech_server = \"172.17.0.1\"\nsemtech_port = 1700\n" > /opt/chirpstack/mesh_forwarder.toml' 2>/dev/null
    $DOCKER_BIN exec ${CONTAINER_NAME} sh -c \
      'printf "protocol = \"udp\"\nsemtech_server = \"172.17.0.1\"\nsemtech_port = 1700\n" > /opt/chirpstack/forwarder_state.toml' 2>/dev/null
    info "    forwarder configured for local NS (172.17.0.1:1700)"
  fi
  info "  Starting semtech-udp-forwarder..."
  $DOCKER_BIN exec ${CONTAINER_NAME} supervisorctl restart semtech-udp-forwarder 2>/dev/null \
    && info "  ✅ semtech-udp-forwarder started" \
    || warn "  ⚠️ semtech-udp-forwarder failed to start"
fi

# ── Deployment summary ──
sleep 2
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}')

if [ "$WAIT_OK" = "true" ]; then
  echo ""
  echo "============================================"
  printf " ${GREEN}ChirpStack LoRa Mesh deployed!${NC}\n"
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
  printf " ${RED}Deployment INCOMPLETE — check logs${NC}\n"
  echo "============================================"
  echo " Device:  ${GW_MODEL}, Band ${GW_BAND}MHz"
  echo " Logs:    ${DOCKER_BIN} logs --tail 50 ${CONTAINER_NAME}"
  echo " Procs:   ${DOCKER_BIN} exec ${CONTAINER_NAME} ps w"
  echo "============================================"
  exit 1
fi
