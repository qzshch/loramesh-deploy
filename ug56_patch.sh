#!/bin/sh
# UG56 patch script - sourced by entrypoint.sh before supervisord starts
# Handles: sysfs GPIO, supervisord.conf, gateway_eui.txt, symlinks

cd /opt/chirpstack

# === sysfs GPIO override for concentratord.toml ===
echo '' >> concentratord.toml
echo 'sx1302_reset_chip="sysfs"' >> concentratord.toml
echo 'sx1302_reset_pin=40' >> concentratord.toml
echo 'sx1261_reset_chip="sysfs"' >> concentratord.toml
echo 'sx1261_reset_pin=42' >> concentratord.toml

# === Rewrite supervisord.conf with correct priorities and retries ===
cat > /etc/supervisord.conf << 'SUPEOF'
[supervisord]
nodaemon=true
logfile=/var/log/supervisord.log
pidfile=/var/run/supervisord.pid

[program:concentratord]
priority=100
command=bash /opt/chirpstack/start_concentratord.sh
directory=/opt/chirpstack
autostart=true
autorestart=true
stdout_logfile=/tmp/mesh.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=1
stderr_logfile=/tmp/mesh.log
stderr_logfile_maxbytes=0
redirect_stderr=true

[program:gateway-mesh]
priority=200
command=/opt/chirpstack/chirpstack-gateway-mesh -c /opt/chirpstack/mesh_config.toml -c /opt/chirpstack/region.toml
directory=/opt/chirpstack
autostart=true
autorestart=true
startsecs=5
startretries=50
stdout_logfile=/tmp/mesh.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/mesh.log
stderr_logfile_maxbytes=0
redirect_stderr=true

[program:mqtt-forwarder]
priority=300
command=bash -c 'for i in $(seq 1 20); do [ -S /tmp/concentratord_command ] && break; sleep 1; done; sleep 8; exec bash /opt/chirpstack/start_mqtt_forwarder.sh'
directory=/opt/chirpstack
autostart=true
autorestart=true
startsecs=3
startretries=20
stdout_logfile=/tmp/mesh.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/mesh.log
stderr_logfile_maxbytes=0
redirect_stderr=true

[program:semtech-udp-forwarder]
priority=300
command=python3 /opt/chirpstack/mesh_forwarder.py
directory=/opt/chirpstack
autostart=true
autorestart=true
startsecs=3
stdout_logfile=/tmp/mesh.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/mesh.log
stderr_logfile_maxbytes=0
redirect_stderr=true
environment=PYTHONUNBUFFERED="1"

[program:nginx]
priority=50
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/tmp/nginx.log
stderr_logfile=/tmp/nginx_error.log
redirect_stderr=false

[program:web-ui]
priority=50
command=python3 /opt/chirpstack/web_ui.py
directory=/opt/chirpstack
autostart=true
autorestart=true
stdout_logfile=/tmp/web_ui.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=1
stderr_logfile=/tmp/web_ui.log
stderr_logfile_maxbytes=0
redirect_stderr=true
SUPEOF

# === Relay mode: disable MQTT server to avoid connection overhead ===
if [ "${RELAY_BORDER}" != "true" ]; then
  sed -i 's|server="tcp://.*"|server=""|' /opt/chirpstack/mqtt_forwarder.toml 2>/dev/null
fi

# === gateway_eui.txt + symlinks ===
# Use GATEWAY_EUI env var if set (from docker run -e); skip if empty to preserve deploy-written value
if [ -n "${GATEWAY_EUI}" ]; then
  echo "${GATEWAY_EUI}" | tr 'A-F' 'a-f' > /opt/chirpstack/gateway_eui.txt
fi
ln -sf /tmp/mesh.log /tmp/gateway-mesh.log 2>/dev/null
