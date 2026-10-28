"""Loopback VMess user authentication and per-user SOCKS routing proof."""
import contextlib
import json
import pathlib
import socket
import subprocess
import sys
import threading
import time

core, server_path, work_path = sys.argv[1:]
work = pathlib.Path(work_path)
processes = []
logs = []
gateway_hits = []


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def listener():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen()
    return sock


def echo_loop(sock):
    while True:
        try:
            conn, _ = sock.accept()
        except OSError:
            return
        with conn:
            conn.sendall(conn.recv(4096))


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("SOCKS connection closed")
        data += chunk
    return data


def gateway_loop(sock):
    while True:
        try:
            conn, _ = sock.accept()
        except OSError:
            return
        threading.Thread(target=gateway_client, args=(conn,), daemon=True).start()


def gateway_client(conn):
    with conn:
        try:
            conn.settimeout(5)
            greeting = recv_exact(conn, 2)
            recv_exact(conn, greeting[1])
            conn.sendall(b"\x05\x00")
            header = recv_exact(conn, 4)
            assert header[:3] == b"\x05\x01\x00" and header[3] == 1
            target = socket.inet_ntoa(recv_exact(conn, 4))
            destination = int.from_bytes(recv_exact(conn, 2), "big")
            with socket.create_connection((target, destination), timeout=5) as remote:
                gateway_hits.append(destination)
                conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                remote.sendall(conn.recv(4096))
                conn.sendall(remote.recv(4096))
        except (AssertionError, OSError, ConnectionError):
            pass


def start(name, config):
    path = work / f"{name}.json"
    path.write_text(json.dumps(config))
    log = open(work / f"{name}.log", "w")
    logs.append(log)
    proc = subprocess.Popen([core, "run", "-c", str(path)], stdout=log, stderr=log)
    processes.append(proc)
    time.sleep(0.35)
    if proc.poll() is not None:
        raise AssertionError(f"{name} exited: {(work / f'{name}.log').read_text()}")
    return proc


def try_user(label, uuid, server_port, destination, expected):
    client_port = port()
    client = {
        "log": {"level": "warn"},
        "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": client_port}],
        "outbounds": [{"type": "vmess", "tag": "server", "server": "127.0.0.1",
                       "server_port": server_port, "uuid": uuid, "security": "auto",
                       "alter_id": 0, "transport": {"type": "ws", "path": "/test-vmess"}}],
        "route": {"final": "server"},
    }
    proc = start(label, client)
    received = b""
    try:
        with socket.create_connection(("127.0.0.1", client_port), timeout=5) as conn:
            conn.settimeout(3)
            conn.sendall(b"\x05\x01\x00")
            assert recv_exact(conn, 2) == b"\x05\x00"
            conn.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + destination.to_bytes(2, "big"))
            assert recv_exact(conn, 2) == b"\x05\x00"
            recv_exact(conn, 8)
            conn.sendall(b"onevps-sing-box-runtime")
            received = conn.recv(4096)
    except (TimeoutError, OSError, ConnectionError, AssertionError):
        pass
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        processes.remove(proc)
    assert (received == b"onevps-sing-box-runtime") == expected, label


try:
    with contextlib.ExitStack() as stack:
        echo = stack.enter_context(listener())
        gateway = stack.enter_context(listener())
        threading.Thread(target=echo_loop, args=(echo,), daemon=True).start()
        threading.Thread(target=gateway_loop, args=(gateway,), daemon=True).start()
        server = json.loads(pathlib.Path(server_path).read_text())
        server_port = port()
        server["inbounds"][0]["listen"] = "127.0.0.1"
        server["inbounds"][0]["listen_port"] = server_port
        # Only this disposable fixture removes the production private-IP block.
        server["route"]["rules"] = [rule for rule in server["route"]["rules"] if "ip_cidr" not in rule]
        server["outbounds"][-1]["server_port"] = gateway.getsockname()[1]
        start("server", server)
        destination = echo.getsockname()[1]
        for label, suffix, expected, hits in (("default", "004", True, 0),
                                              ("alice", "005", True, 1),
                                              ("invalid", "099", False, 1)):
            try_user(label, "123e4567-e89b-12d3-a456-426614174" + suffix,
                     server_port, destination, expected)
            assert len(gateway_hits) == hits, f"{label}: unexpected gateway traffic"
        print("ok - real sing-box VMess users: direct, SOCKS route and invalid UUID")
finally:
    for proc in processes:
        proc.terminate()
    for proc in processes:
        proc.wait(timeout=5)
    for log in logs:
        log.close()
