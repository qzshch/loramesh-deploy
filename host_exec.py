#!/usr/bin/env python3
"""Host command executor via Docker socket.
Creates a one-shot privileged container with --pid=host to run commands on the host.
Usage: python3 host_exec.py "shell command"
"""
import http.client
import json
import socket
import sys
import os
import time

SOCK_PATH = "/var/run/docker.sock"
IMAGE = os.environ.get("HOST_EXEC_IMAGE", "chirpstack-mesh-gw:latest")

class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost")
        self.path = path
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)

def api(method, path, body=None):
    conn = UnixHTTPConnection(SOCK_PATH)
    headers = {"Content-Type": "application/json"} if body else {}
    conn.request(method, path, body=json.dumps(body) if body else None, headers=headers)
    resp = conn.getresponse()
    data = resp.read().decode()
    conn.close()
    return resp.status, data

def host_exec(cmd, timeout=15):
    """Run a command on the host via one-shot privileged container."""
    # Create container
    config = {
        "Image": IMAGE,
        "Cmd": ["sh", "-c", cmd],
        "Entrypoint": ["/bin/sh", "-c"],
        "HostConfig": {
            "Binds": ["/:/host_root"],
            "PidMode": "host",
            "Privileged": True,
            "NetworkMode": "none",
            "AutoRemove": True,
        },
    }
    status, data = api("POST", "/v1.41/containers/create?name=mesh-host-exec", config)
    if status not in (200, 201):
        # Container might exist from previous failed run
        api("DELETE", "/v1.41/containers/mesh-host-exec?force=true")
        status, data = api("POST", "/v1.41/containers/create?name=mesh-host-exec", config)
        if status not in (200, 201):
            print(f"Create failed: {status} {data}", file=sys.stderr)
            return False

    cid = json.loads(data)["Id"][:12]

    # Start container
    status, _ = api("POST", f"/v1.41/containers/{cid}/start")
    if status != 204:
        print(f"Start failed: {status}", file=sys.stderr)
        return False

    # Wait for completion
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, data = api("GET", f"/v1.41/containers/{cid}/json")
        if status == 200:
            info = json.loads(data)
            state = info.get("State", {})
            if not state.get("Running", True):
                exit_code = state.get("ExitCode", -1)
                return exit_code == 0
        time.sleep(0.5)

    # Timeout — cleanup
    api("DELETE", f"/v1.41/containers/{cid}?force=true")
    return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: host_exec.py <command>")
        sys.exit(1)

    cmd = " ".join(sys.argv[1:])
    if not os.path.exists(SOCK_PATH):
        print(f"Docker socket not found: {SOCK_PATH}", file=sys.stderr)
        sys.exit(2)

    ok = host_exec(cmd)
    sys.exit(0 if ok else 1)
