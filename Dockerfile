FROM node:18-alpine

# Install Python3, crypto, supervisor, bash
RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-pycryptodome \
    supervisor \
    bash \
    && pip3 install --break-system-packages flask \
    && rm -rf /var/cache/apk/* /root/.cache

# Create working directory
RUN mkdir -p /opt/chirpstack

# MQTT client for border MeshEvent reporting (heartbeat → NS)
RUN cd /opt/chirpstack && npm install mqtt --silent && rm -rf /root/.npm

# Copy application files
COPY pkt_mesh_fwd.js /opt/chirpstack/pkt_mesh_fwd.js
COPY web_ui_v2.py /opt/chirpstack/web_ui.py
COPY supervisord.conf /etc/supervisord.conf

# Ports: 8088 (web UI HTTP), 1700 (mesh UDP)
EXPOSE 8088 1700/udp

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
