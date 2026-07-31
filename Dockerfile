FROM node:18-alpine

# Install Python3, crypto, nginx, supervisor, bash
RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-pycryptodome \
    nginx \
    supervisor \
    bash \
    && pip3 install --break-system-packages flask \
    && rm -rf /var/cache/apk/* /root/.cache

# Remove default nginx config (alpine puts it in /etc/nginx/http.d/)
RUN rm -f /etc/nginx/http.d/default.conf

# Create working directory
RUN mkdir -p /opt/chirpstack

# Copy application files
COPY pkt_mesh_fwd.js /opt/chirpstack/pkt_mesh_fwd.js
COPY web_ui_v2.py /opt/chirpstack/web_ui.py
COPY mesh_nginx.conf /etc/nginx/http.d/mesh.conf
COPY supervisord.conf /etc/supervisord.conf

# Ports: 8080 (web HTTP), 8443 (web HTTPS), 1700 (mesh UDP)
EXPOSE 8080 8443 1700/udp

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
