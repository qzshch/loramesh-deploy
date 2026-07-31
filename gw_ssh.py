#!/usr/bin/env python3
"""SSH helper for LoRa Mesh gateways - bypasses MCP SSH caching issues."""
import paramiko
import sys

GATEWAYS = {
    'relay': ('192.168.44.67', 'LoRaWAN@2018'),
    'border': ('192.168.44.203', 'LoRaWAN@2018'),
}

def ssh_exec(host, password, cmd, timeout=30):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username='root', password=password,
              look_for_keys=False, allow_agent=False, timeout=10)
    _, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode()
    err = stderr.read().decode()
    rc = stdout.channel.recv_exit_status()
    c.close()
    return out, err, rc

def main():
    if len(sys.argv) < 3:
        print("Usage: gw_ssh.py <relay|border|both> <command>")
        sys.exit(1)

    target = sys.argv[1]
    cmd = ' '.join(sys.argv[2:])

    targets = {}
    if target == 'both':
        targets = GATEWAYS
    elif target in GATEWAYS:
        targets = {target: GATEWAYS[target]}
    else:
        print(f"Unknown target: {target}. Use: relay, border, both")
        sys.exit(1)

    for name, (host, pwd) in targets.items():
        print(f"=== {name} ({host}) ===")
        try:
            out, err, rc = ssh_exec(host, pwd, cmd)
            if out.strip():
                print(out.rstrip())
            if err.strip():
                print(f"STDERR: {err.rstrip()}")
            print(f"EXIT: {rc}")
        except Exception as e:
            print(f"ERROR: {e}")
        print()

if __name__ == '__main__':
    main()
