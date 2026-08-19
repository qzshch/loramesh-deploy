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
