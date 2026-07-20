#!/bin/sh
# ============================================================
#  ChirpStack LoRa Mesh 卸载脚本
#  适用于: Milesight UG56/UG65/UG67/EG71 网关
#  用法: sh mesh_uninstall.sh
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo "${GREEN}[INFO]${NC} $1"; }
warn()  { echo "${YELLOW}[WARN]${NC} $1"; }

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

# ── Step 1: Stop and remove container ──
info "Step 1/4: Removing mesh container..."
if $DOCKER_BIN ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
  $DOCKER_BIN rm -f "$CONTAINER_NAME" 2>/dev/null && info "  Container removed" || warn "  Failed to remove container"
else
  info "  No mesh container found"
fi

# ── Step 2: Stop password sync watcher ──
info "Step 2/4: Stopping services..."
if [ -f /etc/init.d/mesh_pwd_sync ]; then
  /etc/init.d/mesh_pwd_sync stop 2>/dev/null
  rm -f /etc/init.d/mesh_pwd_sync
  info "  Password sync watcher stopped and removed"
fi

# ── Step 3: Clean up persistent files ──
info "Step 3/4: Cleaning up files..."
for f in /etc/chirpstack-concentratord-sx1302-sysfs /etc/ug56_patch.sh; do
  if [ -f "$f" ]; then
    rm -f "$f"
    info "  Removed $f"
  fi
done
rm -rf /tmp/mesh-deploy 2>/dev/null
rm -f /tmp/mesh_deploy.sh /tmp/mesh_deploy.log 2>/dev/null

# ── Step 4: Restart native packet forwarder ──
info "Step 4/4: Restoring native packet forwarder..."
RESTARTED=0
if [ -f "/etc/init.d/lora_pkt_fwd" ]; then
    # Unexport GPIOs first (container may have left them exported)
    for GPIO_DIR in /sys/class/gpio/gpio*; do
      GPIO_NAME=$(basename "$GPIO_DIR" 2>/dev/null)
      case "$GPIO_NAME" in gpiochip*|gpiolib*) continue ;; esac
      echo "$GPIO_NAME" | grep -q '^gpio' || continue
      NUM=$(echo "$GPIO_NAME" | sed 's/^gpio//')
      echo "$NUM" | grep -q '^[0-9][0-9]*$' || continue
      echo "$NUM" > /sys/class/gpio/unexport 2>/dev/null || true
    done
    /etc/init.d/lora_pkt_fwd start 2>/dev/null && info "  Started lora_pkt_fwd" && RESTARTED=1
fi
[ "$RESTARTED" -eq 0 ] && warn "  No native packet forwarder service found"

# ── Done ──
echo ""
echo "============================================"
echo " ${GREEN}LoRa Mesh uninstalled${NC}"
echo "============================================"
echo " Native pkt_fwd restored"
echo " Web UI: https://$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo '<gateway-ip>')"
echo "============================================"
