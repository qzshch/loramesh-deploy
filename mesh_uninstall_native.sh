#!/bin/sh
# ============================================================
#  LoRa Mesh 卸载脚本（native pkt_fwd 架构）
#  移除 mesh forwarder，恢复 gateway-bridge 到 1700 端口
#
#  用法: wget -qO- <OSS>/mesh_uninstall_native.sh | sh
# ============================================================

# ── CRLF self-heal ──
if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "-sh" ]; then
  if head -1 "$0" 2>/dev/null | od -c 2>/dev/null | grep -q '\\r'; then
    sed -i 's/\r$//' "$0" 2>/dev/null && exec sh "$0" "$@"
  fi
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }

BRIDGE_CONF="/etc/lora-gateway-bridge/lora-gateway-bridge.toml"

echo ""
echo "============================================"
echo " LoRa Mesh Uninstall (native pkt_fwd)"
echo "============================================"

# Step 1: Stop mesh forwarder
info "Step 1/4: Stopping mesh forwarder..."
pkill -f pkt_mesh_fwd 2>/dev/null && info "  Mesh forwarder stopped" || info "  Not running"

# Disable procd service
if [ -f /etc/init.d/mesh_forwarder ]; then
  /etc/init.d/mesh_forwarder stop 2>/dev/null
  /etc/init.d/mesh_forwarder disable 2>/dev/null
  rm -f /etc/init.d/mesh_forwarder
  info "  procd service removed"
fi

# Step 2: Restore gateway-bridge to port 1700
info "Step 2/4: Restoring gateway-bridge to port 1700..."
if [ -f "$BRIDGE_CONF" ]; then
  if grep -q "1710" "$BRIDGE_CONF"; then
    sed -i "s|:1710|:1700|g" "$BRIDGE_CONF"
    killall lora-gateway-bridge 2>/dev/null
    sleep 1
    /usr/bin/lora-gateway-bridge -c "$BRIDGE_CONF" > /dev/null 2>&1 &
    sleep 2
    info "  Bridge restored to port 1700"
  else
    info "  Bridge already on port 1700"
  fi
else
  warn "  Bridge config not found"
fi

# Step 3: Clean up files
info "Step 3/4: Cleaning up files..."
rm -f /opt/chirpstack/pkt_mesh_fwd.js
rm -f /tmp/mesh_fwd.log
info "  Files cleaned"

# Step 4: Verify pkt_fwd
info "Step 4/4: Verifying pkt_fwd..."
if ps w 2>/dev/null | grep -v grep | grep -q "[ /]lora_pkt_fwd"; then
  info "  pkt_fwd running"
else
  warn "  pkt_fwd not running — starting..."
  /etc/init.d/lora_pkt_fwd start 2>/dev/null
  sleep 5
  if ps w 2>/dev/null | grep -v grep | grep -q "[ /]lora_pkt_fwd"; then
    info "  pkt_fwd started"
  else
    warn "  pkt_fwd failed to start"
  fi
fi

echo ""
echo "============================================"
printf " ${GREEN}LoRa Mesh uninstalled${NC}\n"
echo "============================================"
echo " pkt_fwd:  $(ps w 2>/dev/null | grep -v grep | grep -q '[ /]lora_pkt_fwd' && echo 'running' || echo 'not running')"
echo " bridge:   $(ps w 2>/dev/null | grep -v grep | grep -q 'lora-gateway-bridge' && echo 'running' || echo 'not running')"
echo "============================================"
