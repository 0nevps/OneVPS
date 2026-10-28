#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../onevps.sh
source "$ROOT_DIR/onevps.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
check() { "$@" || { printf 'not ok - %s\n' "$*" >&2; exit 1; }; }
reject() { if "$@" >/dev/null 2>&1; then printf 'not ok - accepted %s\n' "$*" >&2; exit 1; fi; }
encode() { printf 'vmess://'; openssl base64 -A; printf '\n'; }
UUID=123e4567-e89b-12d3-a456-426614174000
jq --arg uuid "$UUID" '{nodes:[.nodes[1] | .type="vmess-ws" | .uuid=$uuid |
  .ws_path="/vmess-test" | del(.password) |
  .users=[{id:"alice",name:"Alice",uuid:"123e4567-e89b-12d3-a456-426614174001",
    outbound:{mode:"proxy",protocol:"socks",server:"127.0.0.1",port:1080}}]]}' \
  "$ROOT_DIR/tests/fixtures/nodes.json" > "$WORK/nodes.json"
check render_config "$WORK/nodes.json" "$WORK/config.json"
check jq -e '.inbounds[0] | .protocol == "vmess" and .listen == "127.0.0.1" and
  .streamSettings.network == "ws" and (.settings.clients|length) == 2 and
  all(.settings.clients[]; has("id") and (has("flow")|not) and (has("password")|not))' "$WORK/config.json"
check jq -e '.routing.rules[2].user | length == 1' "$WORK/config.json"
node=$(jq -c '.nodes[0]' "$WORK/nodes.json")
link=$(node_link "$node" | command grep '^vmess://')
check parse_outbound_link <<<"$link" > "$WORK/outbound.json"
check jq -e --arg uuid "$UUID" '.protocol == "vmess" and .uuid == $uuid and .port == 443 and .method == "auto" and .params.path == "/vmess-test"' "$WORK/outbound.json"
check build_proxy_outbound vmess-test < "$WORK/outbound.json" > "$WORK/proxy.json"
check jq -e '.protocol == "vmess" and .streamSettings.tlsSettings.allowInsecure == false and .settings.vnext[0].users[0].security == "auto"' "$WORK/proxy.json"
user_link=$(node_user_link "$node" alice | command grep '^vmess://')
check parse_outbound_link <<<"$user_link" > "$WORK/user.json"
check jq -e '.uuid == "123e4567-e89b-12d3-a456-426614174001"' "$WORK/user.json"
json=$(printf '%s' "${link#vmess://}" | openssl base64 -d -A)
for mutation in '.aid=1' '.tls=""' '.scy="none"' '.net="grpc"' '.insecure="1"' '.unknown="ignored"' '.id="invalid"' '.port=65536' '.port=1.5' '.type="http"' '.path="bad"' '.sni="bad\nname"' '.host=[]' '.fp="invalid"'; do
  bad=$(jq -c "$mutation" <<<"$json" | encode)
  reject parse_outbound_link <<<"$bad"
done
reject parse_outbound_link <<<"${link}=junk"
reject parse_outbound_link <<<"$link
$link"
url=${link#vmess://}; url=${url//+/-}; url=${url//\//_}; url=${url%%=*}
check parse_outbound_link <<<"vmess://$url" > "$WORK/url.json"
check cmp "$WORK/outbound.json" "$WORK/url.json"
formatted=$(jq '.port=443 | .aid=0 | .v=2' <<<"$json" | encode)
check parse_outbound_link <<<"$formatted" > "$WORK/formatted.json"
check cmp "$WORK/outbound.json" "$WORK/formatted.json"
for method in auto aes-128-gcm chacha20-poly1305; do
  tcp=$(jq -c --arg method "$method" '.net="tcp" | .host="" | .path="" | .scy=$method' <<<"$json" | encode)
  check parse_outbound_link <<<"$tcp" > "$WORK/tcp.json"
  check build_proxy_outbound tcp-test < "$WORK/tcp.json" > "$WORK/tcp-proxy.json"
done
printf 'ok - VMess rendering, user links, strict v2 parser and TLS outbounds\n'

check prepare_node_user_change "$WORK/nodes.json" "$WORK/reset.json" b2c3d4e5 reset <<< '"123e4567-e89b-12d3-a456-426614174009"'
check jq -e '.nodes[0].uuid == "123e4567-e89b-12d3-a456-426614174009" and .nodes[0].users[0].uuid == "123e4567-e89b-12d3-a456-426614174001"' "$WORK/reset.json"
reject prepare_node_user_change "$WORK/nodes.json" "$WORK/bad.json" b2c3d4e5 reset <<< '"123e4567-e89b-12d3-a456-426614174001"'
reject prepare_node_user_change "$WORK/nodes.json" "$WORK/bad.json" b2c3d4e5 reset <<< '"not-uuid"'
check prepare_node_user_change "$WORK/nodes.json" "$WORK/add.json" b2c3d4e5 add <<< '{"id":"bob","name":"Bob","uuid":"123e4567-e89b-12d3-a456-426614174002"}'
check prepare_node_user_change "$WORK/add.json" "$WORK/delete.json" b2c3d4e5 delete bob
check cmp "$WORK/nodes.json" "$WORK/delete.json"
check prepare_outbound_assignment "$WORK/nodes.json" "$WORK/assigned.json" b2c3d4e5 selected '["default"]' < "$WORK/outbound.json"
check render_config "$WORK/assigned.json" "$WORK/assigned-config.json"
check jq -e '.outbounds[2].protocol == "vmess" and .routing.rules[2].user == ["trojan-b2c3d4e5@onevps"]' "$WORK/assigned-config.json"
printf 'ok - VMess UUID lifecycle and per-user outbound assignment\n'

# Mock only host integration; exercise real route writes and transaction code.
(
  XRAY_DIR="$WORK/state"; mkdir -p "$XRAY_DIR"
  XRAY_NODES="$XRAY_DIR/nodes.json"; XRAY_CONF="$XRAY_DIR/config.json"
  XRAY_BIN="$WORK/core"
  printf '#!/bin/sh\n[ ! -f "%s/fail-validation" ]\n' "$WORK" > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
  CADDY_STATE="$WORK/caddy"; mkdir -p "$CADDY_STATE/routes/node.example.com"
  cp "$WORK/nodes.json" "$XRAY_NODES"; cp "$WORK/config.json" "$XRAY_CONF"
  caddy_domain_ensure() { mkdir -p "$CADDY_STATE/routes/$1"; }
  caddy_reload() { [[ ! -f "$WORK/fail-caddy" ]] || { rm "$WORK/fail-caddy"; return 1; }; }
  systemctl() {
    if [[ "$1" == restart && -f "$WORK/fail-restart" ]]; then rm "$WORK/fail-restart"; return 1; fi
    return 0
  }
  check caddy_add_route b2c3d4e5 node.example.com /vmess-test 20001 /unused
  cp "$CADDY_STATE/routes/node.example.com/b2c3d4e5.caddy" "$WORK/route-before"
  touch "$WORK/fail-validation"
  reject apply_vmess_change b2c3d4e5 path <<< '"/invalid-core"'
  rm "$WORK/fail-validation"
  check cmp "$WORK/nodes.json" "$XRAY_NODES"
  check cmp "$WORK/route-before" "$CADDY_STATE/routes/node.example.com/b2c3d4e5.caddy"
  collision=$(jq -c '.id="c3d4e5f6" | .tag="vmess-collision"' <<<"$node")
  reject apply_vmess_change c3d4e5f6 add <<<"$collision"
  check cmp "$WORK/nodes.json" "$XRAY_NODES"
  for failure in fail-caddy fail-restart; do
    touch "$WORK/$failure"
    reject apply_vmess_change b2c3d4e5 path <<< '"/new-path"'
    check cmp "$WORK/nodes.json" "$XRAY_NODES"
    check cmp "$WORK/config.json" "$XRAY_CONF"
    check cmp "$WORK/route-before" "$CADDY_STATE/routes/node.example.com/b2c3d4e5.caddy"
  done
  check apply_vmess_change b2c3d4e5 domain <<< '"new.example.com"'
  check test ! -e "$CADDY_STATE/routes/node.example.com/b2c3d4e5.caddy"
  check test -f "$CADDY_STATE/routes/new.example.com/b2c3d4e5.caddy"
  check apply_vmess_change b2c3d4e5 toggle <<<null
  check jq -e '.inbounds == []' "$XRAY_CONF"
  check apply_vmess_change b2c3d4e5 delete <<<null
  check test ! -e "$CADDY_STATE/routes/new.example.com/b2c3d4e5.caddy"
  check test -d "$CADDY_STATE/routes/new.example.com"
  check apply_vmess_change b2c3d4e5 add <<<"$node"
  check jq -e '.inbounds[0].protocol == "vmess"' "$XRAY_CONF"
  # Menu creation uses UUIDs, not the Trojan password prompt or public ports.
  require_xray() { :; }
  prepare_caddy_for_trojan() { :; }
  find_caddyfile() { printf '/unused\n'; }
  pause() { :; }
  rand_port() { printf '20002\n'; }
  ask() {
    case "$1" in
      'Node name') printf 'VMess menu test\n' ;;
      'Subdomain (DNS A/AAAA -> this server)') printf 'menu.example.com\n' ;;
      *UUID*) printf '123e4567-e89b-12d3-a456-426614174003\n' ;;
      *) return 1 ;;
    esac
  }
  check add_trojan_node vmess-ws
  check jq -e 'any(.nodes[]; .type == "vmess-ws" and .name == "VMess menu test" and
    .uuid == "123e4567-e89b-12d3-a456-426614174003" and (has("password")|not))' "$XRAY_NODES"
)
printf 'ok - VMess Caddy lifecycle and validation/restart rollback\n'

if [[ -n "${XRAY_TEST_BIN:-}" ]]; then
  "$XRAY_TEST_BIN" version
  for config in config assigned-config; do
    "$XRAY_TEST_BIN" run -test -config "$WORK/$config.json" > "$WORK/check.log" 2>&1 || { cat "$WORK/check.log"; exit 1; }
  done
  python3 - "$XRAY_TEST_BIN" "$WORK" <<'PY'
import json, pathlib, socket, subprocess, sys, threading, time
core, directory = sys.argv[1:]
work = pathlib.Path(directory)
processes, logs = [], []
def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]
def start(name, config):
    path = work / (name + '.json')
    path.write_text(json.dumps(config))
    log = open(work / (name + '.log'), 'w')
    logs.append(log)
    p = subprocess.Popen([core, 'run', '-config', str(path)], stdout=log, stderr=log)
    processes.append(p)
    time.sleep(.5)
    assert p.poll() is None, (work / (name + '.log')).read_text()
    return p
def echo(listener):
    while True:
        try:
            c, _ = listener.accept()
        except OSError:
            return
        with c:
            c.sendall(c.recv(4096))
try:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0)); listener.listen()
        threading.Thread(target=echo, args=(listener,), daemon=True).start()
        server = json.loads((work / 'config.json').read_text())
        server_port, gateway_port = port(), port()
        server['inbounds'][0]['port'] = server_port
        # Disposable loopback test only; production private-IP blocking stays intact.
        server['routing']['rules'] = [r for r in server['routing']['rules'] if 'ip' not in r]
        allow = {'finalRules': [{'action': 'allow', 'ip': ['127.0.0.1']}]}
        server['outbounds'][0]['settings'].update(allow)
        server['outbounds'][-1]['settings']['servers'][0]['port'] = gateway_port
        access = work / 'gateway-access.log'
        start('gateway', {'log': {'access': str(access)}, 'inbounds': [
            {'listen': '127.0.0.1', 'port': gateway_port, 'protocol': 'socks', 'settings': {'auth': 'noauth'}}],
            'outbounds': [{'protocol': 'freedom', 'settings': allow}]})
        start('server', server)
        for suffix in ('000', '001', '099'):
            local_port = port()
            outbound = json.loads((work / 'proxy.json').read_text())
            target = outbound['settings']['vnext'][0]
            target.update(address='127.0.0.1', port=server_port)
            target['users'][0]['id'] = '123e4567-e89b-12d3-a456-426614174' + suffix
            # Exercise the loopback WS backend; Caddy is the production TLS terminator.
            outbound['streamSettings']['security'] = 'none'
            outbound['streamSettings'].pop('tlsSettings')
            p = start('client-' + suffix, {'inbounds': [{'listen': '127.0.0.1', 'port': local_port,
                'protocol': 'dokodemo-door', 'settings': {'address': '127.0.0.1',
                'port': listener.getsockname()[1], 'network': 'tcp'}}], 'outbounds': [outbound]})
            received = b''
            try:
                with socket.create_connection(('127.0.0.1', local_port), timeout=4) as s:
                    s.sendall(b'onevps-vmess-proof'); received = s.recv(4096)
            except (TimeoutError, ConnectionError):
                pass
            assert (received == b'onevps-vmess-proof') == (suffix != '099'), suffix
            p.terminate(); p.wait(timeout=5); processes.remove(p)
            time.sleep(.2)
            entries = access.read_text() if access.exists() else ''
            if suffix == '000':
                assert 'accepted' not in entries, entries
            elif suffix == '001':
                assert 'accepted tcp:' in entries, entries
        print('ok - real VMess WS: two UUIDs, rejected invalid UUID, per-user SOCKS routing')
finally:
    for p in processes:
        p.terminate()
    for p in processes:
        p.wait(timeout=5)
    for log in logs:
        log.close()
PY
fi
