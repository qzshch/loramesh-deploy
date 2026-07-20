# ChirpStack LoRa Mesh Deployment

One-click deployment scripts for ChirpStack LoRa Mesh on Milesight gateways (UG65/UG56/EG71/UG67).

## Files

| File | Description |
|------|-------------|
| `mesh_deploy.sh` | One-click install script |
| `mesh_uninstall.sh` | Uninstall script |
| `mesh_forwarder.py` | Semtech UDP forwarder (border downlink path) |
| `web_ui_v2.py` | Flask web UI |
| `mesh_nginx.conf` | Nginx reverse proxy config |
| `band_*.toml` | Region band data-rate mappings |
| `ug56_patch.sh` | UG56-specific sysfs GPIO patch |
| `start_gateway_mesh.sh` | Gateway-mesh startup wrapper (socket wait) |

## Architecture

```
Sensor → Relay GW → LoRa Mesh (AES128) → Border GW → MQTT/UDP → ChirpStack NS
```

## Usage

```bash
curl -fsSL https://ursalink-resource-center.oss-us-west-1.aliyuncs.com/kevin/mesh_deploy.sh -o /tmp/mesh_deploy.sh
sh /tmp/mesh_deploy.sh              # relay mode (default)
sh /tmp/mesh_deploy.sh --border     # border mode
```
