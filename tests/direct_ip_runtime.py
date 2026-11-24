"""Exercise rendered direct routes with real Xray and local dual-stack TCP/UDP echoes."""

import contextlib
import json
import pathlib
import socket
import subprocess
import sys
import threading
import time


def echo(listener, transport, family):
    while True:
        try:
            if transport == "tcp":
                conn, _ = listener.accept()
                with conn:
                    try:
                        data = conn.recv(4096)
                        if data:
                            conn.sendall(family + data)
                    except ConnectionError:
                        pass
            else:
                data, peer = listener.recvfrom(4096)
                listener.sendto(family + data, peer)
        except OSError:
            return


core, config_file, work = sys.argv[1:]
work = pathlib.Path(work)
config = json.loads(pathlib.Path(config_file).read_text())
config["log"]["loglevel"] = "debug"
config["routing"]["rules"] = [rule for rule in config["routing"]["rules"] if "ip" not in rule]
config["dns"] = {"hosts": {"dual.test": ["127.0.0.1", "::1"], "four.test": "127.0.0.1", "six.test": "::1"}}
config["inbounds"] = []
targets = {"127.0.0.1": b"4", "::1": b"6", "dual.test": b"46", "four.test": b"4", "six.test": b"6"}
modes = {"ipv4": b"4", "ipv6": b"6", "dual": b"46"}
payload = b"onevps-direct-ip"
cases = []

with contextlib.ExitStack() as stack:
    with contextlib.ExitStack() as held_ports:
        for transport, kind in (("tcp", socket.SOCK_STREAM), ("udp", socket.SOCK_DGRAM)):
            port = 0
            for address, sock_family, family in (("127.0.0.1", socket.AF_INET, b"4"), ("::1", socket.AF_INET6, b"6")):
                listener = stack.enter_context(socket.socket(sock_family, kind))
                listener.bind((address, port))
                port = listener.getsockname()[1]
                if transport == "tcp":
                    listener.listen()
                threading.Thread(target=echo, args=(listener, transport, family), daemon=True).start()
            for mode, allowed in modes.items():
                for target, families in targets.items():
                    reservation = held_ports.enter_context(socket.socket(type=kind))
                    reservation.bind(("127.0.0.1", 0))
                    inbound_port = reservation.getsockname()[1]
                    tag = f"{mode}-{len(cases)}"
                    config["inbounds"].append({
                        "listen": "127.0.0.1", "port": inbound_port, "tag": tag, "protocol": "dokodemo-door",
                        "settings": {"address": target, "port": port, "network": transport},
                    })
                    for rule in config["routing"]["rules"]:
                        if mode in rule.get("inboundTag", []):
                            rule["inboundTag"].append(tag)
                    expected = {bytes([family]) + payload for family in set(families) & set(allowed)} or {b""}
                    cases.append((transport, kind, mode, target, inbound_port, expected))
        config_path = work / "direct-ip-runtime.json"
        config_path.write_text(json.dumps(config))

    log_path = work / "direct-ip-runtime.log"
    with log_path.open("w") as log, subprocess.Popen(
        [core, "run", "-config", str(config_path)], stdout=log, stderr=log
    ) as process:
        try:
            deadline = time.monotonic() + 5
            while " started" not in log_path.read_text():
                assert process.poll() is None, log_path.read_text()
                assert time.monotonic() < deadline, log_path.read_text()
                time.sleep(0.05)
            for transport, kind, mode, target, port, expected in cases:
                received = b""
                try:
                    with socket.socket(type=kind) as client:
                        client.settimeout(0.5 if expected == {b""} else 2)
                        client.connect(("127.0.0.1", port))
                        client.sendall(payload)
                        if transport == "tcp":
                            with client.makefile("rb") as reader:
                                received = reader.read(len(payload) + 1)
                        else:
                            received = client.recv(4096)
                except (TimeoutError, ConnectionError):
                    pass
                assert received in expected, f"{transport} {mode} → {target}: {received!r}\n{log_path.read_text()}"
                print(f"ok - real Xray {transport} {mode} → {target}")
        finally:
            if process.poll() is None:
                process.terminate()
