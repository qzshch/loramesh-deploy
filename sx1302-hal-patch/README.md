# SX1302 HAL Patch — Board Diagnostics + STANDBY_RC/XOSC Retry

## 背景

ChirpStack concentratord 使用 upstream sx1302_hal V2.1.0r9，在 Milesight UG65 hwver=0130 硬件上
`sx1250_setup()` 的 STANDBY_RC 命令失败（10ms 等待不足以让 SX1250 SPI 接口就绪）。

## 补丁内容

### 1. STANDBY_RC/XOSC Retry（loragw_sx1250.c）
- STANDBY_RC 和 STANDBY_XOSC 各加 5 次 retry，递增等待（50ms → 250ms）
- 每次 retry 打印状态日志
- **单一二进制适配所有硬件版本**，不需要 deploy 脚本做 hwver 分支

### 2. Board Diagnostics（loragw_sx1302.c + loragw_hal.c）
- 新增 `sx1302_read_board_info()` 函数
- 在 `lgw_start()` 的 radio 校准前调用
- 读取并打印：chip version (0x5606)、GPIO input values (0x5644/0x5645)、model ID (OTP 0xD0)
- 用于诊断不同硬件版本的差异，为方案 B（移植 native 板子检测）提供数据

## 构建

```bash
# 在构建服务器上（需要 musl 交叉编译工具链 + Rust 1.89.0）
bash build_concentratord_v2.sh
```

## 文件

| 文件 | 说明 |
|------|------|
| `sx1302_hal_board_detect_v2.patch` | git diff 补丁（基于 brocaar/sx1302_hal V2.1.0r9） |
| `build_concentratord_v2.sh` | 一键构建脚本 |

## 验证

在 hwver=0130 和 hwver=0150 两种 UG65 上部署同一二进制，确认：
1. `docker logs` 中出现 `SX1302 Board Diagnostics` 日志
2. STANDBY_RC/XOSC 状态检查通过
3. 所有 concentratord 进程 RUNNING
