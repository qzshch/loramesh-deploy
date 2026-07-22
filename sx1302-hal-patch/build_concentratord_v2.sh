#!/bin/bash
# build_concentratord_v2.sh
# 方案A: 构建带板子诊断日志的 chirpstack-concentratord（musl 静态链接）
# 用法: 在构建服务器上运行（47.243.113.250 或等效环境）
#
# 前置条件:
#   - sx1302_hal 源码（V2.1.0r9）已克隆到 /hal/sx1302_hal
#   - chirpstack-concentratord 源码已克隆
#   - musl 交叉编译工具链已安装
#   - Rust 1.89.0 + aarch64-unknown-linux-musl target

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/sx1302_hal_board_detect_v2.patch"
HAL_DIR="/hal/sx1302_hal"
CONCENTRATORD_DIR="${SCRIPT_DIR}/chirpstack-concentratord"

echo "=== 方案A 构建脚本 ==="
echo "Patch: ${PATCH_FILE}"
echo "HAL dir: ${HAL_DIR}"

# Step 1: Apply patch to HAL
echo "[1/4] Applying HAL patch..."
if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: Patch file not found: $PATCH_FILE"
    exit 1
fi

cd "$HAL_DIR"
# Reset any previous patches
git checkout -- . 2>/dev/null || true
git apply "$PATCH_FILE"
echo "  Patch applied successfully"

# Step 2: Build HAL with musl cross-compiler
echo "[2/4] Building HAL (musl cross-compile)..."
cd "$HAL_DIR"
ARCH=arm CROSS_COMPILE=aarch64-linux-musl- make libloragw 2>&1 | tail -5
echo "  HAL built: $(ls -la libloragw/libloragw.a)"

# Step 3: Install HAL to system paths
echo "[3/4] Installing HAL..."
cp libloragw/libloragw.a /usr/local/aarch64-linux-musl/lib/libloragw-sx1302.a 2>/dev/null || \
cp libloragw/libloragw.a /usr/aarch64-linux-gnu/lib/libloragw-sx1302.a 2>/dev/null || \
echo "  WARNING: Could not install to system path, using local path"

# Copy headers
cp libloragw/inc/loragw_sx1302.h /usr/local/aarch64-linux-musl/include/libloragw-sx1302/ 2>/dev/null || \
cp libloragw/inc/loragw_sx1302.h /usr/aarch64-linux-gnu/include/libloragw-sx1302/ 2>/dev/null || true

# Step 4: Build chirpstack-concentratord
echo "[4/4] Building concentratord..."
cd "$CONCENTRATORD_DIR"

# Use Docker cross-compile if available
if command -v docker &>/dev/null; then
    echo "  Using Docker cross-compile..."
    cross build --target aarch64-unknown-linux-musl --release -p chirpstack-concentratord-sx1302
    OUTPUT="target/aarch64-unknown-linux-musl/release/chirpstack-concentratord-sx1302"
else
    echo "  Using native cross-compile..."
    export LIBCLANG_PATH=/usr/lib/x86_64-linux-gnu
    cargo build --target aarch64-unknown-linux-musl --release -p chirpstack-concentratord-sx1302
    OUTPUT="target/aarch64-unknown-linux-musl/release/chirpstack-concentratord-sx1302"
fi

if [ -f "$OUTPUT" ]; then
    SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    echo "  SUCCESS: $OUTPUT ($SIZE)"
    file "$OUTPUT"
else
    echo "  ERROR: Build output not found at $OUTPUT"
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo "Binary: $CONCENTRATORD_DIR/$OUTPUT"
echo ""
echo "Deploy to gateway:"
echo "  scp $OUTPUT root@<gateway>:/tmp/"
echo "  # On gateway:"
echo "  docker cp /tmp/chirpstack-concentratord-sx1302 chirpstack-mesh-gw:/opt/concentratord/"
echo "  docker exec chirpstack-mesh-gw tar czf /opt/concentratord/concentratord.tar.gz -C /opt/concentratord chirpstack-concentratord-sx1302"
echo "  docker restart chirpstack-mesh-gw"
