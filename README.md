# ChirpStack LoRa Mesh — Milesight 网关部署

在 Milesight 网关（UG65/UG56/EG71/UG67）上部署 ChirpStack LoRa Mesh，实现 Border/Relay 架构的 LoRaWAN 数据包中继。一键安装/卸载，支持运行时角色切换。

## 架构（M34 起）

射频层全部交给网关原生的 `lora_pkt_fwd`，容器不直接碰 SX1302。这样绕开了 M21-M33 期间所有 concentratord 硬件兼容问题（STANDBY_RC / 外部 PA / board detect / 冷启动）。

```
传感器 ──LoRa RF──► lora_pkt_fwd（原生固件，SPI 直连 SX1302）
                       │  ▲ UDP:1700  ▲  ▼ PULL_RESP
                       └──┼───────────┼──┘  （--network host）
              ┌──────────┴── Docker 容器 chirpstack-mesh-gw ──────────┐
              │  supervisord 只管 2 个进程：                            │
              │  ① pkt_mesh_fwd.js (Node.js，全部 mesh 逻辑)           │
              │     Relay:  传感器帧 → 包成 MType=111 mesh 帧 → PULL_RESP 发射
              │     Border: 解包 mesh 帧 → 恢复原帧 → 转发给 NS          │
              │     下行:   精确 RX 时序，跟随 NS tmst                  │
              │     心跳:   Event payload + relay_path 拓扑上报          │
              │     NS 双后端: backend=udp / backend=mqtt                │
              │  ② web_ui (Flask :8088)                                 │
              └──────────┬──────────────────────────────────────────────┘
                         │
           ┌─────────────┴──────────────┐
   backend=udp（默认）          backend=mqtt
   → LGB → 内置 loraserver      → ChirpStack v4 NS
```

## 工作机制（对应 `pkt_mesh_fwd.js`）

### 角色怎么定

`pkt_mesh_fwd.js:38` 读 `/opt/chirpstack/mesh_config.json` 的 `"role"` 字段（`--role` CLI 参数覆盖，默认 `relay`）。部署脚本写入：`--relay` / `--border` 显式指定；不带参数时自动检测——网关有 loraserver（内置 NS）→ border，否则 relay。一台网关同时只扮演一个角色，Web UI 可运行时切换。

| 角色 | 位置 | 干的事 |
|------|------|--------|
| **relay** | 传感器侧 | 收到传感器 LoRa 帧 → 包成 MType=111 mesh 帧 → PULL_RESP 让本地 pkt_fwd 在 mesh 频点广播。**不转发给 LGB**（会让 border 收不到上行） |
| **border** | NS 侧 | 收到 mesh 帧 → 解包恢复原始 PHYPayload → 上报 NS。**转发 PULL_DATA 给 LGB**（relay 不转发，否则会覆盖 LGB 里 border 的地址映射，下行会发错网关） |

### 组网：无线洪泛 + 去重 + 跳数上限

- 所有网关在 mesh 频点（如 US915 `903.9/904.1/904.3 MHz`）上监听同一信道
- **上行洪泛**：relay 包好 mesh 帧广播；中间 relay 收到后把 MHDR 的 hop 字段 +1、重算 MIC 重广播，到 `max-hop-count` 停；border 收到即终止
- **去重**：key = `uid:relayId`（uid 是 relay 侧 12-bit 递增计数），防环；`relayId == 自己` 的自环帧直接丢
- **下行是单跳**：mesh 下行帧只带目标 `relayId`，只有匹配的 relay 发射，中间 relay 直接丢弃（当前不支持下行多跳，mesh 下行帧里没有 hop 转发逻辑）
- **心跳组网**：relay 每 `heartbeat-interval` 发一个 Event/heartbeat 帧，中间 relay 把自己的 `{relay_id, rssi, snr}` 追加到 `relay_path`，border 缓存拓扑写 `/opt/chirpstack/mesh_topo.json`（Web UI 拓扑卡片）。心跳只用于监控，**不参与下行选路**

### 怎么认出是哪个 relay 的包

mesh 帧里带 4 字节 `relayId` = 网关 EUI 的后 4 字节（`gwMac.slice(4,8)`）。border 解包时取出，日志打 `UNWRAP relay=xxx`，并按设备 key 缓存映射供下行路由用：

| 帧类型 | 设备 key | 来源 |
|--------|----------|------|
| JoinRequest | `jr:<DevEUI>` | `phy.slice(1,9)` 反转 |
| 数据上行 | `da:<DevAddr>` | `phy.slice(1,5)` 反转 |

### Border 上行：mesh 帧解包上报

```
relay 传感器帧 → 包 mesh 帧 → relay 的 pkt_fwd 广播
border 的 pkt_fwd 收到 mesh 帧（当普通射频包）→ PUSH_DATA 127.0.0.1:1700 → pkt_mesh_fwd.js
  isMeshFrame()：phy[0]>>5 == 7（MType=111 专有帧）→ 判为 mesh 帧
  → decodeMeshUplink：MIC 校验 + 取 relayId + originalPhy
  → unwrap 重构 rxpk（rssi/snr 用 mesh meta 里 relay 封装的传感器原始信号）
  → backend=udp:   PUSH_DATA 127.0.0.1:1710 → LGB → MQTT → NS
  → backend=mqtt:  ChirpStack v4 gateway/+/event/up
```

border 直接收到的普通传感器帧（非 mesh）：`border-ignore-direct=true` 时丢弃；否则也照常上报（那个设备直连 border，不经 mesh）。

### Border 下行：本机直发 vs 组 mesh（关键判定）

判定依据是 **`dlCtx` 缓存里有没有这个设备的 relay 记录**——即这个设备上行是不是走 mesh 上来的：

1. 每次 unwrap 上行时，border 按设备 key 记下 `device → {relayId, uid, dr, tmst}`（`dlCtx`）
2. NS 下行进 `_handleTxpk`：
   - **查得到 ctx（设备走过 mesh）→ 组 mesh 下行帧**：meta 6 字节带 `ctx.relayId + uid + freq + power + delay`，PULL_RESP 给本地 pkt_fwd 在 mesh 频点广播。目标 relay 收到后 `relayId == 自己` 才按 meta 的 freq/dr/`上行tmst+delay` 精确发射给传感器
   - **查不到 ctx（设备直连 border）→ 本机直发**：原帧按 NS 给的 freq/datr 直接 PULL_RESP 射频发出
3. JoinAccept 特殊处理：JoinAccept 的 key（DevAddr）和 JoinRequest 的 key（DevEUI）对不上，border 用 NS 下行 `tmst` 精确匹配 `joinReqs[]`（`expTmst = 上行tmst + join-delay`），匹配不到再 fallback 最近一次 JoinRequest

下行 delay 不硬编码：`imme=true`（Class C）→ delay=0 立即发；`imme=false` → delay = NS 下行 tmst − 上行 tmst（border 本地时基差值，时钟无关），或 ChirpStack MQTT 下行的相对延迟（如 `"1s"`）。relay 端用 `ulTmstMap[uid]` 查回精确上行 tmst。

## 目录

### 当前核心

| 文件 | 职责 |
|------|------|
| `pkt_mesh_fwd.js` | 全部 mesh 逻辑（中继/解包/下行时序/心跳/NS 双后端），唯一改 mesh 行为的地方 |
| `web_ui_v2.py` | Flask Web UI（:8088，直连无 nginx） |
| `Dockerfile` | 镜像构建（node:18-alpine + python3/flask/supervisor） |
| `supervisord.conf` | 只跑 `mesh-forwarder` + `web-ui` 两个进程 |
| `mesh_deploy.sh` / `mesh_uninstall.sh` | 一键部署 / 卸载（Docker 容器线） |

### 旧架构遗留（M34 前，已废弃，不维护）

| 文件 | 说明 |
|------|------|
| `mesh_forwarder.py` / `pkt_mesh_fwd.py` | 被 `pkt_mesh_fwd.js` 取代 |
| `chirpstack-concentratord-sx1302-milesight-nofd` | 旧 concentratord 二进制（容器已不跑 concentratord） |
| `sx1302-hal-patch/` | M21-M33 的 HAL patch / 构建产物 |
| `band_*.toml` × 8 | 旧 gateway-mesh 的 region 映射，新架构不读 |
| `ug56_patch.sh` / `mesh_cgi.sh` / `host_exec.py` / `gw_ssh.py` | 旧架构辅助 |
| `mesh_deploy_native.sh` / `mesh_uninstall_native.sh` | 无 Docker 纯宿主机部署线（与主线并存，非默认） |

## 部署

```bash
curl -fsSL https://ursalink-resource-center.oss-us-west-1.aliyuncs.com/kevin/mesh_deploy.sh -o /tmp/mesh_deploy.sh
sh /tmp/mesh_deploy.sh --relay      # Relay 角色
sh /tmp/mesh_deploy.sh --border     # Border 角色
```

不带参数时自动检测：网关有 loraserver（内置 NS）→ border，否则 relay。

卸载：

```bash
curl -fsSL https://ursalink-resource-center.oss-us-west-1.aliyuncs.com/kevin/mesh_uninstall.sh -o /tmp/mesh_uninstall.sh
sh /tmp/mesh_uninstall.sh
```

## 配置

容器内 `/opt/chirpstack/mesh_config.json`（bind mount，Web UI 也在改它）：

```json
{
  "role": "relay",
  "signing-key": "00112233445566778899aabbccddeeff",
  "mesh-freqs": "903900000,904100000,904300000",
  "mesh-sf": "7",
  "mesh-bw": "125000",
  "tx-power": "27",
  "backend": "udp",
  "server-host": "127.0.0.1",
  "server-port": "1710",
  "max-hop-count": "1",
  "join-delay": "5"
}
```

- `signing-key` 两端必须一致，否则 Border 丢弃签名校验失败的帧
- `tx-power` US915/AU915 建议 27（≥18 dBm 才启用外部 PA）
- `backend=mqtt` 时 `server-host`/`server-port` 不生效，需配 `mqtt-server`/`mqtt-username`/`mqtt-password`/`mqtt-prefix`
- Web UI Config 页的角色 / 协议 / 心跳等修改实时写回此文件

## 历史

| 阶段 | 内容 |
|------|------|
| M1-M33 | 自装 concentratord + gateway-mesh（Rust）。硬件兼容问题缠斗：STANDBY_RC、外部 PA、board detect、冷启动。已废弃 |
| M34 (07-31) | 重构：native pkt_fwd + Node.js `pkt_mesh_fwd.js`，容器不再碰 SX1302 |
| M35 (08-03) | 下行链路修复：tmst 精确匹配、全频段 DR 编码、时序跟随 NS |
| M36 | border-ignore-direct、max-hop-count 键名修复 |
| M37 | heartbeat 网络管理（Event payload + relay_path 拓扑，MQTT 上报 + Web UI 拓扑卡片） |
| M38 | NS 对接层：Semtech UDP + ChirpStack v4 MQTT 双后端；实网对接 45.38 验证 + 镜像重建 |

详细演进记录见项目记忆 `project_lora_mesh.md`。
