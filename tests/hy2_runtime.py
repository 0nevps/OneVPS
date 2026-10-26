"""Loopback-only real Xray HY2 TCP/UDP, authentication and user routing proof."""
import contextlib
import json
import pathlib
import socket
import subprocess
import sys
import threading
import time

core, config_path, work = sys.argv[1:]
work = pathlib.Path(work)
processes = []
logs = []


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(type=kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start(name, config):
    path = work / (name + ".json")
    path.write_text(json.dumps(config))
    log = open(work / (name + ".log"), "w")
    logs.append(log)
    proc = subprocess.Popen([core, "run", "-config", str(path)], stdout=log, stderr=log)
    processes.append(proc)
    time.sleep(0.4)
    if proc.poll() is not None:
        raise AssertionError(f"{name} failed: {(work / (name + '.log')).read_text()}")
    return proc


def stop(proc):
    proc.terminate()
    proc.wait(timeout=5)
    processes.remove(proc)


def tcp_echo(listener):
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        with conn:
            conn.sendall(conn.recv(4096))


def udp_echo(listener):
    while True:
        try:
            data, peer = listener.recvfrom(4096)
        except OSError:
            return
        listener.sendto(data, peer)


try:
    with contextlib.ExitStack() as stack:
        tcp = stack.enter_context(socket.socket())
        tcp.bind(("127.0.0.1", 0))
        tcp.listen()
        udp = stack.enter_context(socket.socket(type=socket.SOCK_DGRAM))
        udp.bind(("127.0.0.1", 0))
        threading.Thread(target=tcp_echo, args=(tcp,), daemon=True).start()
        threading.Thread(target=udp_echo, args=(udp,), daemon=True).start()
        server = json.loads(pathlib.Path(config_path).read_text())
        server_port = free_port(socket.SOCK_DGRAM)
        server["log"] = {"loglevel": "debug"}
        server["inbounds"][0]["port"] = server_port
        server["inbounds"][0]["listen"] = "127.0.0.1"
        # Only the disposable test config permits private destinations for echo servers.
        server["routing"]["rules"] = [r for r in server["routing"]["rules"] if "ip" not in r]
        server["outbounds"][0]["settings"]["finalRules"] = [{"action": "allow", "ip": ["127.0.0.1"]}]
        gateway_port = free_port()
        server["outbounds"][-1]["settings"]["servers"][0]["port"] = gateway_port
        access = str(work / "gateway-access.log")
        start("gateway", {
            "log": {"access": access, "loglevel": "debug"},
            "inbounds": [{"listen": "127.0.0.1", "port": gateway_port, "protocol": "socks",
                          "settings": {"auth": "noauth", "udp": True}}],
            "outbounds": [{"protocol": "freedom", "settings": {"finalRules": [{"action": "allow", "ip": ["127.0.0.1"]}]}}],
        })
        start("server", server)
        for auth in ("default+pass:@", "alice-secret", "incorrect-password"):
            tcp_port, udp_port = free_port(), free_port(socket.SOCK_DGRAM)
            client = {
                "log": {"loglevel": "debug"},
                "inbounds": [
                    {"listen": "127.0.0.1", "port": tcp_port, "protocol": "dokodemo-door",
                     "settings": {"address": "127.0.0.1", "port": tcp.getsockname()[1], "network": "tcp"}},
                    {"listen": "127.0.0.1", "port": udp_port, "protocol": "dokodemo-door",
                     "settings": {"address": "127.0.0.1", "port": udp.getsockname()[1], "network": "udp"}},
                ],
                "outbounds": [{"protocol": "hysteria", "settings": {
                    "version": 2, "address": "127.0.0.1", "port": server_port},
                    "streamSettings": {"network": "hysteria", "security": "tls",
                        "tlsSettings": {"serverName": "localhost", "alpn": ["h3"],
                            "certificates": [{"usage": "verify", "certificateFile": str(work / "cert.pem")}]},
                        "hysteriaSettings": {"version": 2, "auth": auth}}}],
            }
            proc = start("client", client)
            for transport, port in (("tcp", tcp_port), ("udp", udp_port)):
                payload = b"onevps-hy2-runtime-proof"
                received = b""
                try:
                    with socket.socket(type=socket.SOCK_STREAM if transport == "tcp" else socket.SOCK_DGRAM) as sock:
                        sock.settimeout(10)
                        sock.connect(("127.0.0.1", port))
                        sock.sendall(payload)
                        received = sock.recv(4096)
                except (TimeoutError, ConnectionError):
                    pass
                expected = auth != "incorrect-password"
                assert (received == payload) == expected, f"{auth}: {transport} authentication/echo failed: " + "\n".join(p.read_text() for p in work.glob("*.log"))
                print(f"ok - real HY2 {transport}: {'authenticated echo' if expected else 'reject bad password'}")
            stop(proc)
            time.sleep(0.1)
            gateway_log = pathlib.Path(access).read_text() if pathlib.Path(access).exists() else ""
            if auth == "default+pass:@":
                assert "accepted" not in gateway_log, "default user unexpectedly used Alice's outbound"
            elif auth == "alice-secret":
                assert "accepted tcp:" in gateway_log and "accepted udp:" in gateway_log, gateway_log
                print("ok - real HY2 per-user SOCKS routing for TCP and UDP; default stays direct")
finally:
    for process in processes:
        process.terminate()
    for process in processes:
        process.wait(timeout=5)
    for log in logs:
        log.close()
