"""Loopback-only forwarding tests; never install or change host services."""

import copy
import http.client
import http.server
import json
import pathlib
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time


CORE, BASE, WORK = sys.argv[1:]
WORK = pathlib.Path(WORK)


def free_port():
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def http_server(marker, context=None):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(marker)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if context is not None:
        server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


processes = []
logs = []


def start(name, config, port):
    # Fail closed: no runtime process may initialize a public ACME provider.
    assert not config.get("certificate_providers"), "ACME configs are check-only"
    assert all("certificate_provider" not in item.get("tls", {}) for item in config.get("inbounds", []))
    path = WORK / (name + ".json")
    path.write_text(json.dumps(config))
    subprocess.run([CORE, "check", "-c", str(path)], check=True, capture_output=True)
    log = (WORK / (name + ".log")).open("wb")
    logs.append(log)
    process = subprocess.Popen([CORE, "run", "-c", str(path)], stdout=log, stderr=log)
    processes.append(process)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(name + " exited during startup")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(name + " did not open its loopback listener")


def udp_request(proxy_port, destination_port):
    def receive(connection, size):
        result = b""
        while len(result) < size:
            part = connection.recv(size - len(result))
            if not part:
                raise OSError("SOCKS handshake closed")
            result += part
        return result

    with socket.create_connection(("127.0.0.1", proxy_port), timeout=4) as control:
        control.sendall(b"\x05\x01\x00")
        assert receive(control, 2) == b"\x05\x00"
        control.sendall(b"\x05\x03\x00\x01" + bytes(6))
        header = receive(control, 4)
        assert header[:2] == b"\x05\x00"
        if header[3] == 1:
            host = socket.inet_ntop(socket.AF_INET, receive(control, 4))
        elif header[3] == 4:
            host = socket.inet_ntop(socket.AF_INET6, receive(control, 16))
        else:
            host = receive(control, receive(control, 1)[0]).decode()
        port = struct.unpack("!H", receive(control, 2))[0]
        if host in ("0.0.0.0", "::"):
            host = "127.0.0.1"
        packet = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", destination_port)
        payload = b"onevps-udp-forwarding"
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as datagram:
            datagram.settimeout(4)
            datagram.sendto(packet + payload, (host, port))
            response, _ = datagram.recvfrom(4096)
            assert response[:3] == bytes(3) and response.endswith(payload)
            return response


def request(proxy_port, destination_port):
    # http.client uses explicit CONNECT, avoiding environment NO_PROXY bypasses.
    connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=4)
    connection.set_tunnel("127.0.0.1", destination_port)
    try:
        connection.request("GET", "/")
        return connection.getresponse().read()
    finally:
        connection.close()


servers = []
try:
    direct = http_server(b"direct")
    upstream = http_server(b"upstream")
    servers.extend([direct, upstream])
    destination_port = direct.server_port
    relay_port, server_port = free_port(), free_port()
    relay = {
        "inbounds": [{"type": "socks", "tag": "relay", "listen": "127.0.0.1", "listen_port": relay_port}],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"rules": [{"action": "route", "outbound": "direct", "override_address": "127.0.0.1", "override_port": upstream.server_port}]},
    }
    start("relay", relay, relay_port)
    generated = json.loads(pathlib.Path(BASE).read_text())
    inbound = next(item for item in generated["inbounds"] if item["type"] == "trojan")
    inbound["listen_port"] = server_port
    default_user, alice = inbound["users"]
    generated["inbounds"] = [inbound]
    proxy = next(item for item in generated["outbounds"] if item["type"] == "socks")
    proxy["server_port"] = relay_port
    # Exercise generated identity rules, not hand-written replicas. Loopback is allowed
    # only in this functional fixture; generated security rules are tested below.
    generated["route"]["rules"] = [
        rule for rule in generated["route"]["rules"]
        if rule.get("action") not in ("sniff", "reject")
    ]
    start("server", generated, server_port)

    def client(name, password, target=server_port):
        port = free_port()
        config = {
            "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": port}],
            "outbounds": [{"type": "trojan", "tag": "proxy", "server": "127.0.0.1", "server_port": target,
                           "password": password, "transport": copy.deepcopy(inbound["transport"])}],
        }
        start(name, config, port)
        return port

    default_port = client("default-client", default_user["password"])
    alice_port = client("alice-client", alice["password"])
    assert request(default_port, destination_port) == b"upstream", "default user missed node proxy"
    assert request(alice_port, destination_port) == b"direct", "user direct override missed"
    print("ok - Trojan WS credentials select isolated default and user routes")
    wrong_port = client("wrong-client", "invalid-disposable-password")
    try:
        result = request(wrong_port, destination_port)
    except (OSError, http.client.HTTPException):
        pass
    else:
        raise AssertionError("invalid password forwarded data: " + repr(result))
    print("ok - invalid Trojan password cannot forward")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as echo:
        echo.bind(("127.0.0.1", 0))
        echo.settimeout(6)

        def echo_once():
            data, address = echo.recvfrom(4096)
            echo.sendto(data, address)

        worker = threading.Thread(target=echo_once, daemon=True)
        worker.start()
        udp_request(alice_port, echo.getsockname()[1])
        worker.join(timeout=6)
    print("ok - Trojan WS forwards UDP through explicit direct user route")

    # A local TLS 1.3 HTTP/2 target avoids relying on public Reality handshake sites.
    certificate, key = WORK / "target.crt", WORK / "target.key"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                    "-keyout", str(key), "-out", str(certificate)],
                   check=True, capture_output=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2"])
    context.load_cert_chain(certificate, key)
    target = http_server(b"reality-target", context)
    servers.append(target)
    reality = json.loads(pathlib.Path(BASE).read_text())
    reality_inbound = next(item for item in reality["inbounds"] if item["type"] == "vless")
    reality_port, reality_client_port = free_port(), free_port()
    reality_inbound["listen"] = "127.0.0.1"
    reality_inbound["listen_port"] = reality_port
    reality_inbound["tls"]["server_name"] = "localhost"
    reality_inbound["tls"]["reality"]["handshake"] = {"server": "127.0.0.1", "server_port": target.server_port}
    reality["inbounds"] = [reality_inbound]
    reality["outbounds"] = [{"type": "direct", "tag": "direct"}]
    reality["route"]["rules"] = []
    start("reality-server", reality, reality_port)
    public_key = json.loads((WORK / "key-values.json").read_text())[1]
    reality_client = {
        "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": reality_client_port}],
        "outbounds": [{"type": "vless", "server": "127.0.0.1", "server_port": reality_port,
                       "uuid": reality_inbound["users"][0]["uuid"], "flow": "xtls-rprx-vision",
                       "tls": {"enabled": True, "server_name": "localhost",
                               "utls": {"enabled": True, "fingerprint": "chrome"},
                               "reality": {"enabled": True, "public_key": public_key,
                                           "short_id": reality_inbound["tls"]["reality"]["short_id"][0]}}}],
    }
    start("reality-client", reality_client, reality_client_port)
    assert request(reality_client_port, destination_port) == b"direct"
    print("ok - VLESS Reality Vision completes a real local handshake and forwards TCP")

    blocked = copy.deepcopy(generated)
    blocked_port = free_port()
    blocked["inbounds"][0]["listen_port"] = blocked_port
    original = json.loads(pathlib.Path(BASE).read_text())
    security = [rule for rule in original["route"]["rules"] if rule.get("action") in ("sniff", "reject")]
    assert any("127.0.0.0/8" in rule.get("ip_cidr", []) for rule in security)
    blocked["route"]["rules"] = security + blocked["route"]["rules"]
    start("blocked-server", blocked, blocked_port)
    blocked_client = client("blocked-client", default_user["password"], blocked_port)
    try:
        result = request(blocked_client, destination_port)
    except (OSError, http.client.HTTPException):
        pass
    else:
        raise AssertionError("private-address guard forwarded data: " + repr(result))
    print("ok - generated private-address rejection precedes outbound routing")

    def hy2_server(name, fixture="runtime-hy2.json", guard=False):
        config = json.loads((WORK / fixture).read_text())
        node = next(item for item in config["inbounds"] if item["type"] == "hysteria2")
        assert node["tls"]["certificate_provider"] == "acme-hy2.example.com"
        config.pop("certificate_providers")
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            node["listen_port"] = reservation.getsockname()[1]
        node["listen"] = "127.0.0.1"
        node["tls"] = {"enabled": True, "server_name": "localhost",
                       "certificate_path": str(certificate), "key_path": str(key)}
        readiness = free_port()
        # QUIC listens on UDP; never mistake it for a TCP readiness endpoint.
        config["inbounds"] = [node, {"type": "mixed", "tag": "readiness",
                                    "listen": "127.0.0.1", "listen_port": readiness}]
        for outbound in config["outbounds"]:
            if outbound["type"] == "socks":
                outbound["server_port"] = relay_port
        if not guard:
            config["route"]["rules"] = [rule for rule in config["route"]["rules"]
                                        if rule.get("action") not in ("sniff", "reject")]
        else:
            assert any("127.0.0.0/8" in rule.get("ip_cidr", []) for rule in config["route"]["rules"])
        start(name, config, readiness)
        return node

    def hy2_client(name, node, password, tls_name="localhost", obfs=None):
        port = free_port()
        outbound = {"type": "hysteria2", "server": "127.0.0.1", "server_port": node["listen_port"],
                    "password": password, "tls": {"enabled": True, "server_name": tls_name,
                                                   "certificate_path": str(certificate)}}
        if obfs is not None:
            outbound["obfs"] = {"type": "salamander", "password": obfs}
        start(name, {"inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": port}],
                     "outbounds": [outbound]}, port)
        return port

    def cannot_forward(port, label):
        try:
            result = request(port, destination_port)
        except (OSError, http.client.HTTPException):
            pass
        else:
            raise AssertionError(label + " forwarded data: " + repr(result))
        print("ok - HY2 " + label + " cannot forward")

    hy2 = hy2_server("hy2-server")
    hy2_default, hy2_alice, hy2_bob = hy2["users"]
    assert len({user["name"] for user in hy2["users"]}) == 3
    hy2_ports = [hy2_client("hy2-" + label, hy2, user["password"])
                 for label, user in zip(("default", "alice", "bob"), hy2["users"])]
    for port, expected in zip(hy2_ports, (b"upstream", b"direct", b"upstream")):
        assert request(port, destination_port) == expected, "HY2 auth_user route isolation failed"
    print("ok - HY2 trusted TLS TCP: default and inherited user proxy, explicit user direct")

    # UDP markers distinguish direct routing from the node's SOCKS relay as well.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as direct_udp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as upstream_udp:
        direct_udp.bind(("127.0.0.1", 0))
        upstream_udp.bind(("127.0.0.1", upstream.server_port))
        stop_udp = threading.Event()

        def udp_echo(endpoint, marker):
            endpoint.settimeout(0.2)
            while not stop_udp.is_set():
                try:
                    data, address = endpoint.recvfrom(4096)
                    endpoint.sendto(marker + data, address)
                except socket.timeout:
                    continue

        workers = [threading.Thread(target=udp_echo, args=(endpoint, marker), daemon=True)
                   for endpoint, marker in ((direct_udp, b"direct:"), (upstream_udp, b"upstream:"))]
        for worker in workers:
            worker.start()
        try:
            for port, marker in zip(hy2_ports, (b"upstream:", b"direct:", b"upstream:")):
                assert udp_request(port, direct_udp.getsockname()[1]).endswith(marker + b"onevps-udp-forwarding")
        finally:
            stop_udp.set()
            for worker in workers:
                worker.join(timeout=2)
    print("ok - HY2 UDP preserves default, inherited and overridden auth_user routes")

    cannot_forward(hy2_client("hy2-wrong-password", hy2, "invalid-disposable"), "wrong password")
    cannot_forward(hy2_client("hy2-wrong-name", hy2, hy2_alice["password"], "wrong.localhost"), "wrong TLS name")
    obfuscated = hy2_server("hy2-obfs-server", "runtime-hy2-obfs.json")
    obfs_password = obfuscated["obfs"]["password"]
    matching = hy2_client("hy2-obfs-matching", obfuscated, hy2_alice["password"], obfs=obfs_password)
    assert request(matching, destination_port) == b"direct"
    print("ok - HY2 matching salamander forwards TCP")
    cannot_forward(hy2_client("hy2-obfs-mismatch", obfuscated, hy2_alice["password"], obfs="wrong-salamander"), "mismatched salamander")
    guarded = hy2_server("hy2-guarded-server", guard=True)
    cannot_forward(hy2_client("hy2-guarded-client", guarded, hy2_alice["password"]), "private CIDR rejection")
    deleted = hy2_server("hy2-deleted-server", "runtime-hy2-deleted.json")
    survivor = hy2_client("hy2-surviving-client", deleted, hy2_bob["password"])
    assert request(survivor, destination_port) == b"upstream"
    cannot_forward(hy2_client("hy2-deleted-client", deleted, hy2_alice["password"]), "deleted user on new connection")
except Exception:
    for path in sorted(WORK.glob("*.log")):
        print(path.name + ":\n" + path.read_text(errors="replace")[-4000:], file=sys.stderr)
    raise
finally:
    for process in reversed(processes):
        process.terminate()
    for process in reversed(processes):
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for log in logs:
        log.close()
    for server in servers:
        server.shutdown()
        server.server_close()
