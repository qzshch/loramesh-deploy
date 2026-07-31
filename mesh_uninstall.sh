#!/bin/sh
# ============================================================
#  ChirpStack LoRa Mesh 卸载脚本
#  适用于: Milesight UG56/UG63/UG65/UG67/EG71 网关
#
#  零操作卸载:
#    wget -qO- <OSS>/mesh_uninstall.sh | sh
#
#  移除 mesh 容器/镜像/watcher/临时文件，恢复原生 pkt_fwd。
#  Docker 本体保留（其他容器可能在用）。
# ============================================================

# ── CRLF self-heal ──
if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "-sh" ]; then
  if head -1 "$0" 2>/dev/null | od -c 2>/dev/null | grep -q '\\r'; then
    sed -i 's/\r$//' "$0" 2>/dev/null && exec sh "$0" "$@"
  fi
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
# BusyBox ash's builtin echo does not interpret \033 — printf does, everywhere.
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }

CONTAINER_NAME="chirpstack-mesh"

# ── Find Docker binary ──
DOCKER_BIN=""
for d in /usr/bin/docker/docker /overlay/docker/bin/docker; do
  [ -x "$d" ] && DOCKER_BIN="$d" && break
done
command -v docker >/dev/null 2>&1 && [ -z "$DOCKER_BIN" ] && DOCKER_BIN="docker"

if [ -z "$DOCKER_BIN" ]; then
  warn "Docker not found — nothing to uninstall"
  exit 0
fi

# ── Step 1: Stop and remove container + image ──
info "Step 1/4: Removing mesh container and image..."
if $DOCKER_BIN ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
  $DOCKER_BIN rm -f "$CONTAINER_NAME" 2>/dev/null && info "  Container removed" || warn "  Failed to remove container"
else
  info "  No mesh container found"
fi

# Remove mesh Docker image
MESH_IMG=$($DOCKER_BIN images --format "{{.ID}}" "chirpstack-mesh-gw" 2>/dev/null | head -1)
if [ -n "$MESH_IMG" ]; then
  $DOCKER_BIN rmi -f "$MESH_IMG" 2>/dev/null && info "  Mesh image removed" || warn "  Failed to remove image"
fi

# ── Step 2: Stop services ──
info "Step 2/4: Stopping services..."
if [ -f /etc/init.d/mesh_pwd_sync ]; then
  /etc/init.d/mesh_pwd_sync stop 2>/dev/null
  rm -f /etc/init.d/mesh_pwd_sync
  info "  Password sync watcher removed"
fi

# ── Step 3: Clean up all mesh-related files ──
info "Step 3/4: Cleaning up files..."
for f in \
  /etc/chirpstack-concentratord-sx1302-sysfs \
  /etc/ug56_patch.sh \
  /tmp/.mesh_container_running \
  /tmp/mesh_deploy.sh \
  /tmp/mesh_deploy.log \
  /tmp/chirpstack-mesh-gw-new.tar.gz \
  /tmp/chirpstack-mesh-gw-v4.tar.gz; do
  [ -f "$f" ] && rm -f "$f"
done
rm -rf /tmp/mesh-deploy 2>/dev/null
info "  Temp files cleaned"

# ── Step 4: Restart native packet forwarder ──
info "Step 4/4: Restoring native packet forwarder..."
RESTARTED=0

if [ -f "/etc/init.d/lora_pkt_fwd" ]; then
    # Unexport GPIOs first. The deploy script's cold start leaves reset pins
    # exported; reset_lgw.sh (called by pkt_fwd's init) fails with "Device or
    # resource busy" if ANY of its pins is still exported.
    for GPIO_DIR in /sys/class/gpio/gpio*; do
      [ -e "$GPIO_DIR" ] || continue
      GPIO_NAME=$(basename "$GPIO_DIR" 2>/dev/null)
      case "$GPIO_NAME" in gpiochip*|gpiolib*) continue ;; esac
      echo "$GPIO_NAME" | grep -q '^gpio' || continue
      NUM=$(echo "$GPIO_NAME" | sed 's/^gpio//')
      echo "$NUM" | grep -q '^[0-9][0-9]*$' || continue
      echo "$NUM" > /sys/class/gpio/unexport 2>/dev/null || true
    done

    # Re-register with procd: deploy used `ubus call service delete` to stop the
    # respawn loop, so enable+start alone would not bring the service back on
    # this boot. `ubus call service list` shows whether it is registered.
    /etc/init.d/lora_pkt_fwd enable 2>/dev/null
    /etc/init.d/lora_pkt_fwd start 2>/dev/null
    sleep 5

    # Verify it actually came up and stayed up (procd registration restored)
    if ps w 2>/dev/null | grep -v grep | grep -q "[ /]lora_pkt_fwd"; then
      info "  Started lora_pkt_fwd"
      RESTARTED=1
    else
      warn "  pkt_fwd did not start, retrying after full GPIO reset..."
      [ -f /usr/sbin/reset_lgw.sh ] && /usr/sbin/reset_lgw.sh start >/dev/null 2>&1
      sleep 2
      /etc/init.d/lora_pkt_fwd restart 2>/dev/null
      sleep 5
      if ps w 2>/dev/null | grep -v grep | grep -q "[ /]lora_pkt_fwd"; then
        info "  Started lora_pkt_fwd (after reset)"
        RESTARTED=1
      fi
    fi
fi
[ "$RESTARTED" -eq 0 ] && warn "  Native packet forwarder did not start — check /etc/init.d/lora_pkt_fwd"

# ── Done ──
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo '<gateway-ip>')
echo ""
echo "============================================"
printf " ${GREEN}LoRa Mesh uninstalled${NC}\n"
echo "============================================"
echo " Native pkt_fwd: $([ $RESTARTED -eq 1 ] && echo 'restored' || echo 'not found')"
echo " Web UI: http://${HOST_IP}"
echo "============================================"
