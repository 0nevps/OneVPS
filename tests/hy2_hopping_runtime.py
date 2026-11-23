"""Prove a single TCP stream survives QUIC port hopping across a veth pair."""
import json
import pathlib
import socket
import struct
import subprocess
import sys
import threading
import time


def exercise_stream():
    deadline = time.monotonic() + 10
    while True:
        try:
            stream = socket.create_connection(("127.0.0.1", 10808), timeout=5)
            break
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)
    with stream:
        for sequence in range(240):
            payload = bytes([sequence])
            stream.sendall(payload)
            assert stream.recv(1) == payload, "the original stream stopped echoing"
            print(sequence, flush=True)
            time.sleep(0.25)


if sys.argv[1] == "--stream":
    exercise_stream()
    sys.exit(0)

namespace, core, directory = sys.argv[1:]
work = pathlib.Path(directory)
ports_seen = set()


def observe(sniffer):
    while True:
        packet = sniffer.recv(65535)
        if len(packet) < 42 or packet[12:14] != b"\x08\x00" or packet[23] != 17:
            continue
        if packet[30:34] == socket.inet_aton("192.0.2.1"):
            offset = 14 + 4 * (packet[14] & 15) + 2
            port = struct.unpack_from("!H", packet, offset)[0]
            if 21001 <= port <= 21008:
                ports_seen.add(port)


def echo(listener):
    conn, _ = listener.accept()
    with conn:
        while data := conn.recv(4096):
            conn.sendall(data)


with socket.socket() as listener, socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3)) as capture:
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    capture.bind(("ingress", 0))
    threading.Thread(target=echo, args=(listener,), daemon=True).start()
    threading.Thread(target=observe, args=(capture,), daemon=True).start()
    node = json.loads((work / "nodes.json").read_text())["nodes"][0]
    client = {
        "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "dokodemo-door",
                      "settings": {"address": "127.0.0.1", "port": listener.getsockname()[1], "network": "tcp"}}],
        "outbounds": [{"protocol": "hysteria", "settings": {"version": 2, "address": "192.0.2.1", "port": 21001},
                       "streamSettings": {"network": "hysteria", "security": "tls",
                           "tlsSettings": {"serverName": "localhost", "alpn": ["h3"], "certificates": [
                               {"usage": "verify", "certificateFile": node["tls_cert"]}]},
                           "hysteriaSettings": {"version": 2, "auth": node["password"]},
                           "finalmask": {"udp": [{"type": "udphop", "settings": {"interval": 5,
                               "mode": "intervalLocal,intervalRemote", "remotePorts": node["hopping"]["ports"]}}]}}}]
    }
    (work / "client.json").write_text(json.dumps(client))
    prefix = ["ip", "netns", "exec", namespace]
    with (work / "client.log").open("w") as log:
        proc = subprocess.Popen(prefix + [core, "run", "-config", str(work / "client.json")], stdout=log, stderr=log)
        try:
            stream = subprocess.Popen(prefix + [sys.executable, __file__, "--stream"], stdout=subprocess.PIPE, text=True)
            try:
                for line in stream.stdout:
                    if int(line) >= 24 and len(ports_seen) >= 2:
                        print("ok - same TCP stream echoed across observed HY2 UDP ports:", sorted(ports_seen))
                        break
                else:
                    raise AssertionError(f"did not sustain one stream across a hop: {sorted(ports_seen)}")
            finally:
                stream.terminate()
                stream.wait(timeout=5)
        finally:
            proc.terminate()
            proc.wait(timeout=5)
