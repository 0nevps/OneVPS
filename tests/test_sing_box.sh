#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../onevps.sh
source "$root/onevps.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

SING_BIN="$work/sing-box"
# shellcheck disable=SC2034
SING_DIR="$work/sing"
# shellcheck disable=SC2034
SING_CONF="$SING_DIR/config.json"
# shellcheck disable=SC2034
SING_NODES="$SING_DIR/onevps-nodes.json"
# shellcheck disable=SC2034
SING_SERVICE="$work/sing-box.service"
# shellcheck disable=SC2034
XRAY_BIN="$work/xray"
# shellcheck disable=SC2034
XRAY_CONF="$work/xray-config"
# shellcheck disable=SC2034
XRAY_NODES="$work/xray-nodes"
# shellcheck disable=SC2034
ARCH=amd64
mkdir -p "$SING_DIR"
cat > "$SING_BIN" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == generate && "${2:-}" == reality-keypair ]]; then
  echo 'PrivateKey: 2A1nlCd-rZYG58FRsWQ5sPaZa0m1wTR6REBBto1JK3U'
  echo 'PublicKey: 2wpfMwjkaOOdvhN5F_ik0QgyCEM6DhVyXYsaDHixuFo'
elif [[ "${1:-}" == generate ]]; then
  echo '123e4567-e89b-12d3-a456-426614174003'
else
  echo 'sing-box version 1.14.4'
  echo 'Tags: with_acme'
fi
EOF
chmod 755 "$SING_BIN"
touch "$SING_DIR/.onevps-managed"

fail() { echo "not ok - $*" >&2; exit 1; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
pk=2A1nlCd-rZYG58FRsWQ5sPaZa0m1wTR6REBBto1JK3U
pubk=2wpfMwjkaOOdvhN5F_ik0QgyCEM6DhVyXYsaDHixuFo
jq -n --arg pk "$pk" --arg pubk "$pubk" '{nodes:[{id:"a1b2c3d4",tag:"reality-a1b2c3d4",type:"vless-reality",name:"Test",
  enabled:true,port:54321,uuid:"123e4567-e89b-12d3-a456-426614174003",reality_sni:"www.cloudflare.com",
  reality_target:"www.cloudflare.com",reality_target_port:443,
  reality_private_key:$pk,reality_public_key:$pubk,reality_short_id:"0123456789abcdef",enabled:true}]}' > "$SING_NODES"
sing_render "$SING_NODES" "$SING_CONF" || fail 'valid node render'
jq -e '.inbounds[0] | .type == "vless" and .tls.reality.enabled and .users[0].flow == "xtls-rprx-vision"' "$SING_CONF" >/dev/null || fail 'VLESS Reality config'
jq -e '.route.rules[0].action == "resolve" and .route.rules[1].action == "reject" and
  .route.rules[2].action == "sniff" and .route.final == "direct"' "$SING_CONF" >/dev/null || fail 'route safety'
if [[ -n "${SING_TEST_BIN:-}" ]]; then "$SING_TEST_BIN" check -c "$SING_CONF" || fail 'real core check'; fi

# Hysteria2 uses the Caddy-deployed PEM pair, not a second ACME provider.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/hy2-key.pem" -out "$work/hy2-cert.pem" \
  -days 2 -subj /CN=example.com -addext subjectAltName=DNS:example.com >/dev/null 2>&1
jq -n --arg cert "$work/hy2-cert.pem" --arg key "$work/hy2-key.pem" \
  '{nodes:[{id:"abc12345",name:"HY2",tag:"hy2-abc12345",type:"hysteria2",domain:"example.com",
    password:"strong-password",port:24321,tls_cert:$cert,tls_key:$key,enabled:true}]}' > "$work/hy2-nodes.json"
sing_render "$work/hy2-nodes.json" "$work/hy2-config.json" || fail 'HY2 render'
jq -e '.certificate_providers == null and (.inbounds[0] | .type == "hysteria2" and
  .tls.certificate_path != null and .tls.key_path != null and .tls.alpn == ["h3"])' \
  "$work/hy2-config.json" >/dev/null || fail 'Caddy-owned HY2 TLS config'
if [[ -n "${SING_TEST_BIN:-}" ]]; then
  "$SING_TEST_BIN" check -c "$work/hy2-config.json" || fail 'HY2 real core check'
fi
jq -s '{nodes: (.[0].nodes + .[1].nodes)}' "$SING_NODES" "$work/hy2-nodes.json" > "$work/both-nodes.json"
sing_render "$work/both-nodes.json" "$work/both-config.json" || fail 'Reality and HY2 render'
if [[ -n "${SING_TEST_BIN:-}" ]]; then
  "$SING_TEST_BIN" check -c "$work/both-config.json" || fail 'multi-inbound real core check'
fi
jq -n '{nodes:[{id:"cdef1234",name:"Trojan WS",tag:"trojan-cdef1234",type:"trojan-ws",
  domain:"ws.example.com",password:"strong-password",port:24777,ws_path:"/test-ws",
  caddy_file:"/etc/caddy/Caddyfile",enabled:true}]}' > "$work/trojan-nodes.json"
sing_render "$work/trojan-nodes.json" "$work/trojan-config.json" || fail 'Trojan WS render'
jq -e '.inbounds[0] | .type == "trojan" and .listen == "127.0.0.1" and
  .listen_port == 24777 and .transport == {type:"ws",path:"/test-ws"} and
  .users[0].password == "strong-password" and (has("tls") | not)' \
  "$work/trojan-config.json" >/dev/null || fail 'loopback-only Trojan WS config'
if [[ -n "${SING_TEST_BIN:-}" ]]; then
  "$SING_TEST_BIN" check -c "$work/trojan-config.json" || fail 'Trojan WS real core check'
fi
jq -s '{nodes: (.[0].nodes + .[1].nodes)}' "$work/both-nodes.json" "$work/trojan-nodes.json" > "$work/all-nodes.json"
sing_render "$work/all-nodes.json" "$work/all-config.json" || fail 'all three inbounds render'
if [[ -n "${SING_TEST_BIN:-}" ]]; then
  "$SING_TEST_BIN" check -c "$work/all-config.json" || fail 'all-inbound real core check'
fi
jq '.nodes[2].port = .nodes[0].port' "$work/all-nodes.json" > "$work/conflicting-ports.json"
reject sing_render "$work/conflicting-ports.json" "$work/reject.json"
jq '.nodes += .nodes' "$work/trojan-nodes.json" > "$work/two-trojan.json"
reject sing_render "$work/two-trojan.json" "$work/reject.json"
jq -n '{nodes:[{id:"f1e2d3c4",name:"VMess WS",tag:"vmess-f1e2d3c4",type:"vmess-ws",
  domain:"vmess.example.com",uuid:"123e4567-e89b-12d3-a456-426614174004",port:24888,
  ws_path:"/test-vmess",caddy_file:"/etc/caddy/Caddyfile",enabled:true}]}' > "$work/vmess-nodes.json"
sing_render "$work/vmess-nodes.json" "$work/vmess-config.json" || fail 'VMess WS render'
jq -e '.inbounds[0] | .type == "vmess" and .listen == "127.0.0.1" and
  .listen_port == 24888 and .transport == {type:"ws",path:"/test-vmess"} and
  .users == [{name:"default",uuid:"123e4567-e89b-12d3-a456-426614174004",alterId:0}] and
  (has("tls") | not)' "$work/vmess-config.json" >/dev/null || fail 'loopback-only VMess AEAD WS config'
if [[ -n "${SING_TEST_BIN:-}" ]]; then
  "$SING_TEST_BIN" check -c "$work/vmess-config.json" || fail 'VMess WS real core check'
fi
jq -s '{nodes:(.[0].nodes + .[1].nodes)}' "$work/all-nodes.json" "$work/vmess-nodes.json" > "$work/four-nodes.json"
sing_render "$work/four-nodes.json" "$work/four-config.json" || fail 'four-inbound render'
if [[ -n "${SING_TEST_BIN:-}" ]]; then
  "$SING_TEST_BIN" check -c "$work/four-config.json" || fail 'four-inbound real core check'
fi
jq '.nodes += .nodes' "$work/vmess-nodes.json" > "$work/two-vmess.json"
reject sing_render "$work/two-vmess.json" "$work/reject.json"
jq '.nodes += .nodes' "$SING_NODES" > "$work/two.json"
reject sing_render "$work/two.json" "$work/reject.json"
jq '.nodes += .nodes' "$work/hy2-nodes.json" > "$work/two-hy2.json"
reject sing_render "$work/two-hy2.json" "$work/reject.json"
jq '.nodes[0].type = "trojan-ws"' "$SING_NODES" > "$work/wrong.json"
reject sing_render "$work/wrong.json" "$work/reject.json"
[[ $(sing_asset) == 'linux-amd64 699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968' ]] || fail 'release digest'
touch "$XRAY_NODES"
reject sing_install
command rm "$XRAY_NODES"
systemctl() { return 0; }
open_port() { :; }
pub_ip() { echo 127.0.0.1; }
sing_secure() { :; }
port_in_use() { return 1; }
ask() { case "$1" in 'Node name') echo Test ;; 'UUID (Enter for random)') echo 123e4567-e89b-12d3-a456-426614174003 ;; 'TCP listen port') echo 54321 ;; *) echo www.cloudflare.com ;; esac; }
sing_check() { return 0; }
printf '{"nodes":[]}\n' > "$SING_NODES"
printf '{}\n' > "$SING_CONF"
sing_add_reality > "$work/link" || fail 'node transaction'
jq -e '.nodes|length == 1' "$SING_NODES" >/dev/null || fail 'node persisted'
grep -q '^vless://' "$work/link" || fail 'share link'

# Exercise HY2 node creation with a test-owned certificate and mocked host operations.
(
  cp "$work/hy2-cert.pem" "$work/caddy-cert.pem"
  cp "$work/hy2-key.pem" "$work/caddy-key.pem"
  ACME_CERT_DIR="$work/certs"
  mkdir -p "$ACME_CERT_DIR/example.com/current"
  cp "$work/caddy-cert.pem" "$ACME_CERT_DIR/example.com/current/fullchain.pem"
  cp "$work/caddy-key.pem" "$ACME_CERT_DIR/example.com/current/key.pem"
  caddy_certificate_issue() { [[ "$1" == example.com ]]; }
  validate_hy2_certificate() { validate_hy2_pem "$@"; }
  command() { if [[ "$1" == -v && ( "$2" == ss || "$2" == runuser ) ]]; then return 0; fi; builtin command "$@"; }
  ask() {
    case "$1" in
      'TLS domain') echo example.com ;;
      'UDP listen port') echo 24321 ;;
      'Node name') echo 'HY2 test' ;;
      'Password (Enter for random)') echo strong-password ;;
      *) return 1 ;;
    esac
  }
  sing_add_hysteria > "$work/hy2-link" || fail 'HY2 node transaction'
  jq -e '(.nodes|length == 2) and .nodes[1].type == "hysteria2"' "$SING_NODES" >/dev/null || fail 'HY2 stored with REALITY'
  grep -q '^hysteria2://' "$work/hy2-link" || fail 'HY2 link'
)
(
  ACME_CERT_DIR="$work/certs"
  caddy_certificate_issue() { [[ "$1" == example.com ]]; }
  validate_hy2_certificate() { validate_hy2_pem "$@"; }
  command() { if [[ "$1" == -v && ( "$2" == ss || "$2" == runuser ) ]]; then return 0; fi; builtin command "$@"; }
  ask() {
    case "$1" in
      'TLS domain') echo example.com ;;
      'UDP listen port') echo 24321 ;;
      'Node name') echo 'HY2 test' ;;
      'Password (Enter for random)') echo strong-password ;;
      *) return 1 ;;
    esac
  }
  cp "$SING_NODES" "$work/hy2-before-nodes.json"
  cp "$SING_CONF" "$work/hy2-before-config.json"
  restart_count=0
  systemctl() {
    if [[ "$1" == restart ]]; then
      restart_count=$((restart_count+1))
      (( restart_count > 1 ))
    else return 0; fi
  }
  reject sing_add_hysteria
  cmp "$SING_NODES" "$work/hy2-before-nodes.json" || fail 'HY2 metadata rollback'
  cmp "$SING_CONF" "$work/hy2-before-config.json" || fail 'HY2 config rollback'
)

# Exercise the real Caddy route helper with mocked reload and service operations.
(
  test_root="$work"
  CADDY_STATE="$work/trojan-caddy"
  mkdir -p "$CADDY_STATE/routes"
  printf ':80 { respond "existing" }\n' > "$work/Caddyfile"
  cp "$SING_NODES" "$work/trojan-before-nodes.json"
  cp "$SING_CONF" "$work/trojan-before-config.json"
  prepare_caddy_for_trojan() { :; }
  find_caddyfile() { printf '%s\n' "$test_root/Caddyfile"; }
  caddy_domain_ensure() { mkdir -p "$CADDY_STATE/routes/$1"; }
  caddy_reload() { [[ "${RELOAD_FAIL:-0}" == 0 ]]; }
  ask() {
    case "$1" in
      'Node name') echo 'Trojan WS' ;;
      'TLS domain') echo ws.example.com ;;
      'Loopback TCP port') echo 24777 ;;
      'Password (Enter for random)') echo strong-password ;;
      *) return 1 ;;
    esac
  }
  sing_add_ws trojan-ws > "$work/trojan-link" || fail 'Trojan WS node transaction'
  jq -e '(.nodes|length == 3) and .nodes[2].type == "trojan-ws"' "$SING_NODES" >/dev/null || fail 'Trojan WS stored with REALITY and HY2'
  id=$(jq -r '.nodes[2].id' "$SING_NODES")
  route="$CADDY_STATE/routes/ws.example.com/$id.caddy"
  test -f "$route" || fail 'Caddy WS route missing'
  grep -q 'reverse_proxy 127.0.0.1:24777' "$route" || fail 'Caddy WS backend'
  grep -q '^trojan://' "$work/trojan-link" || fail 'Trojan WS share link'
  reject sing_add_ws trojan-ws
  cp "$work/trojan-before-nodes.json" "$SING_NODES"
  cp "$work/trojan-before-config.json" "$SING_CONF"
  caddy_remove_route "$id"
  restart_count=0
  systemctl() {
    if [[ "$1" == restart ]]; then
      restart_count=$((restart_count+1))
      (( restart_count > 1 ))
    else return 0; fi
  }
  reject sing_add_ws trojan-ws
  cmp "$SING_NODES" "$work/trojan-before-nodes.json" || fail 'service failure restored Trojan metadata'
  cmp "$SING_CONF" "$work/trojan-before-config.json" || fail 'service failure restored Trojan config'
  test ! -e "$CADDY_STATE/routes/ws.example.com/$id.caddy" || fail 'service failure retained Caddy route'

  systemctl() { return 0; }
  RELOAD_FAIL=1
  reject sing_add_ws trojan-ws
  cmp "$SING_NODES" "$work/trojan-before-nodes.json" || fail 'route failure restored Trojan metadata'
  cmp "$SING_CONF" "$work/trojan-before-config.json" || fail 'route failure restored Trojan config'
  test -z "$(find "$CADDY_STATE/routes" -name '*.caddy' -print)" || fail 'route failure retained a Caddy route'
)

# VMess uses the same Caddy transaction, while preserving the existing Trojan route.
(
  test_root="$work"
  CADDY_STATE="$work/vmess-caddy"
  mkdir -p "$CADDY_STATE/routes/ws.example.com"
  printf ':80 { respond "existing" }\n' > "$work/vmess-Caddyfile"
  cp "$work/trojan-nodes.json" "$work/vmess-source.json"
  jq --arg file "$work/vmess-Caddyfile" '.nodes[0].caddy_file=$file' "$work/vmess-source.json" > "$SING_NODES"
  printf '{"old":true}\n' > "$SING_CONF"
  printf 'handle /old { reverse_proxy 127.0.0.1:24777 }\n' > "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy"
  prepare_caddy_for_trojan() { :; }
  find_caddyfile() { printf '%s\n' "$test_root/vmess-Caddyfile"; }
  caddy_domain_ensure() { mkdir -p "$CADDY_STATE/routes/$1"; }
  caddy_reload() { [[ "${RELOAD_FAIL:-0}" == 0 ]]; }
  ask() {
    case "$1" in
      'Node name') echo 'VMess WS' ;;
      'TLS domain') echo vmess.example.com ;;
      'Loopback TCP port') echo 24888 ;;
      'UUID (Enter for random)') echo 123e4567-e89b-12d3-a456-426614174004 ;;
      *) return 1 ;;
    esac
  }
  sing_add_ws vmess-ws > "$work/vmess-link" || fail 'VMess WS node transaction'
  jq -e '(.nodes|length == 2) and .nodes[1].type == "vmess-ws"' "$SING_NODES" >/dev/null || fail 'VMess stored with Trojan'
  id=$(jq -r '.nodes[1].id' "$SING_NODES")
  route="$CADDY_STATE/routes/vmess.example.com/$id.caddy"
  test -f "$route" || fail 'VMess Caddy WS route missing'
  test -f "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy" || fail 'VMess touched Trojan route'
  link=$(grep '^vmess://' "$work/vmess-link")
  encoded=${link#vmess://}
  printf '%s' "$encoded" | openssl base64 -d -A | jq -e '.aid == "0" and .scy == "auto" and .path != ""' >/dev/null || fail 'VMess AEAD share link'
  reject sing_add_ws vmess-ws
  cp "$work/vmess-source.json" "$SING_NODES"
  printf '{"old":true}\n' > "$SING_CONF"
  caddy_remove_route "$id"
  restart_count=0
  systemctl() {
    if [[ "$1" == restart ]]; then restart_count=$((restart_count+1)); (( restart_count > 1 ))
    else return 0; fi
  }
  reject sing_add_ws vmess-ws
  cmp "$SING_NODES" "$work/vmess-source.json" || fail 'VMess service rollback metadata'
  jq -e '.old == true' "$SING_CONF" >/dev/null || fail 'VMess service rollback config'
  test -f "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy" || fail 'VMess rollback touched Trojan route'
  systemctl() { return 0; }
  RELOAD_FAIL=1
  reject sing_add_ws vmess-ws
  cmp "$SING_NODES" "$work/vmess-source.json" || fail 'VMess route rollback metadata'
  jq -e '.old == true' "$SING_CONF" >/dev/null || fail 'VMess route rollback config'
  test -z "$(find "$CADDY_STATE/routes/vmess.example.com" -name '*.caddy' -print)" || fail 'VMess route rollback retained route'
)

# Exercise lifecycle changes for every inbound without touching the host.
(
  lifecycle_root="$work"
  CADDY_STATE="$work/lifecycle-caddy"
  mkdir -p "$CADDY_STATE/routes/ws.example.com" "$CADDY_STATE/routes/vmess.example.com"
  printf ':80 { respond "existing" }\n' > "$work/lifecycle-Caddyfile"
  jq --arg file "$work/lifecycle-Caddyfile" '
    .nodes |= map(if .type == "trojan-ws" or .type == "vmess-ws" then .caddy_file=$file else . end)' \
    "$work/four-nodes.json" > "$SING_NODES"
  sing_render "$SING_NODES" "$SING_CONF" || fail 'lifecycle initial render'
  printf 'handle /test-ws { reverse_proxy 127.0.0.1:24777 }\n' > "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy"
  printf 'handle /test-vmess { reverse_proxy 127.0.0.1:24888 }\n' > "$CADDY_STATE/routes/vmess.example.com/f1e2d3c4.caddy"
  sing_check() {
    [[ ! -f "$lifecycle_root/lifecycle-fail-check" ]] &&
      { [[ -z "${SING_TEST_BIN:-}" ]] || "$SING_TEST_BIN" check -c "$1"; }
  }
  caddy_domain_ensure() { mkdir -p "$CADDY_STATE/routes/$1"; }
  caddy_reload() {
    if [[ -f "$lifecycle_root/lifecycle-fail-caddy" ]]; then
      command rm "$lifecycle_root/lifecycle-fail-caddy"; return 1
    fi
  }
  systemctl() {
    if [[ "$1" == restart && -f "$lifecycle_root/lifecycle-fail-restart" ]]; then
      command rm "$lifecycle_root/lifecycle-fail-restart"; return 1
    fi
    return 0
  }
  for id in a1b2c3d4 abc12345 cdef1234 f1e2d3c4; do
    sing_change_node "$id" toggle || fail "disable $id"
    jq -e --arg id "$id" 'any(.nodes[]; .id == $id and .enabled == false)' "$SING_NODES" >/dev/null || fail "disable state $id"
    jq -e --arg id "$id" 'all(.inbounds[]; .tag != ("reality-"+$id) and .tag != ("hy2-"+$id) and
      .tag != ("trojan-"+$id) and .tag != ("vmess-"+$id))' "$SING_CONF" >/dev/null || fail "disable inbound $id"
    sing_change_node "$id" toggle || fail "enable $id"
  done
  for id in cdef1234 f1e2d3c4; do
    test -f "$CADDY_STATE/routes/$(if [[ "$id" == cdef1234 ]]; then echo ws.example.com; else echo vmess.example.com; fi)/$id.caddy" || fail "WS route enable $id"
  done
  port=24998
  for id in a1b2c3d4 abc12345 cdef1234 f1e2d3c4; do
    port=$((port+1))
    printf '%s\n' "$port" | jq -R 'tonumber' | sing_change_node "$id" port || fail "port change $id"
    jq -e --arg id "$id" --argjson port "$port" 'any(.nodes[]; .id == $id and .port == $port)' "$SING_NODES" >/dev/null || fail "port state $id"
    if [[ "$id" == cdef1234 || "$id" == f1e2d3c4 ]]; then
      domain=ws.example.com; [[ "$id" == f1e2d3c4 ]] && domain=vmess.example.com
      grep -q "reverse_proxy 127.0.0.1:$port" "$CADDY_STATE/routes/$domain/$id.caddy" || fail "port route $id"
    fi
  done
  printf '"123e4567-e89b-12d3-a456-426614174099"\n' | sing_change_node a1b2c3d4 credential || fail 'REALITY credential'
  printf '"123e4567-e89b-12d3-a456-426614174098"\n' | sing_change_node f1e2d3c4 credential || fail 'VMess credential'
  printf '"new-hy2-password"\n' | sing_change_node abc12345 credential || fail 'HY2 credential'
  printf '"new-trojan-password"\n' | sing_change_node cdef1234 credential || fail 'Trojan credential'
  printf '"invalid-uuid"\n' | reject sing_change_node f1e2d3c4 credential
  printf '443\n' | reject sing_change_node cdef1234 port
  printf '25002\n' | reject sing_change_node cdef1234 port
  cp "$SING_NODES" "$work/lifecycle-before-nodes.json"
  cp "$SING_CONF" "$work/lifecycle-before-config.json"
  cp "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy" "$work/lifecycle-before-route.caddy"
  touch "$work/lifecycle-fail-check"
  reject sing_change_node cdef1234 toggle
  command rm "$work/lifecycle-fail-check"
  touch "$work/lifecycle-fail-restart"
  reject sing_change_node cdef1234 toggle
  touch "$work/lifecycle-fail-caddy"
  reject sing_change_node cdef1234 delete
  cmp "$SING_NODES" "$work/lifecycle-before-nodes.json" || fail 'lifecycle rollback nodes'
  cmp "$SING_CONF" "$work/lifecycle-before-config.json" || fail 'lifecycle rollback config'
  cmp "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy" "$work/lifecycle-before-route.caddy" || fail 'lifecycle rollback route'
  for id in a1b2c3d4 abc12345 cdef1234 f1e2d3c4; do
    touch "$work/lifecycle-fail-restart"
    reject sing_change_node "$id" delete
    cmp "$SING_NODES" "$work/lifecycle-before-nodes.json" || fail "delete rollback metadata $id"
    cmp "$SING_CONF" "$work/lifecycle-before-config.json" || fail "delete rollback config $id"
  done
  for id in a1b2c3d4 abc12345 cdef1234 f1e2d3c4; do
    sing_change_node "$id" delete || fail "delete $id"
  done
  jq -e '.nodes == []' "$SING_NODES" >/dev/null || fail 'lifecycle delete metadata'
  test ! -e "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy" || fail 'Trojan route retained after delete'
  test ! -e "$CADDY_STATE/routes/vmess.example.com/f1e2d3c4.caddy" || fail 'VMess route retained after delete'
  test -f "$work/lifecycle-Caddyfile" || fail 'Caddy site removed on node deletion'
)

# Authenticated users and their routes use the same validated sing-box transaction.
(
  users_root="$work"
  cp "$work/four-nodes.json" "$SING_NODES"
  sing_render "$SING_NODES" "$SING_CONF" || fail 'user test initial render'
  sing_check() { [[ ! -f "$users_root/fail-user-check" ]] && { [[ -z "${SING_TEST_BIN:-}" ]] || "$SING_TEST_BIN" check -c "$1"; }; }
  systemctl() {
    if [[ "$1" == restart && -f "$users_root/fail-user-restart" ]]; then
      command rm "$users_root/fail-user-restart"; return 1
    fi
    return 0
  }
  sing_secure() { :; }
  for id in a1b2c3d4 abc12345 cdef1234 f1e2d3c4; do
    if [[ "$id" == a1b2c3d4 || "$id" == f1e2d3c4 ]]; then
      credential=uuid; secret=123e4567-e89b-12d3-a456-426614174087
    else
      credential=password; secret="secret-$id"
    fi
    payload=$(jq -nc --arg id alice --arg name Alice --arg credential "$credential" --arg secret "$secret" \
      '{id:$id,name:$name} + {($credential):$secret}')
    printf '%s\n' "$payload" | sing_change_user_or_outbound sing_prepare_user "$id" add || fail "add user $id"
    jq -e --arg id "$id" --arg key "$credential" --arg secret "$secret" '
      .nodes[] | select(.id == $id) | .users[0][$key] == $secret' "$SING_NODES" >/dev/null || fail "stored user $id"
    jq -e --arg id "$id" '.inbounds[] | select(.tag | endswith($id)) | (.users|length) == 2' \
      "$SING_CONF" >/dev/null || fail "rendered two users $id"
    link=$(node_user_link "$(jq -c --arg id "$id" '.nodes[] | select(.id==$id)' "$SING_NODES")" alice)
    [[ "$link" == *"$secret"* || "$link" == *vmess://* ]] || fail "user link $id"
    printf '%s\n' "$payload" | reject sing_change_user_or_outbound sing_prepare_user "$id" add
  done
  printf '%s\n' '{"id":"bob","name":"Bob","uuid":"123e4567-e89b-12d3-a456-426614174087"}' |
    reject sing_change_user_or_outbound sing_prepare_user a1b2c3d4 add
  cp "$SING_NODES" "$work/users-before-nodes.json"
  cp "$SING_CONF" "$work/users-before-config.json"
  touch "$work/fail-user-restart"
  reject sing_change_user_or_outbound sing_prepare_user a1b2c3d4 delete alice
  cmp "$SING_NODES" "$work/users-before-nodes.json" || fail 'user restart rollback metadata'
  cmp "$SING_CONF" "$work/users-before-config.json" || fail 'user restart rollback config'
  touch "$work/fail-user-check"
  reject sing_change_user_or_outbound sing_prepare_user a1b2c3d4 delete alice
  command rm "$work/fail-user-check"
  cmp "$SING_NODES" "$work/users-before-nodes.json" || fail 'user check rollback metadata'
  outbound='{"mode":"proxy","protocol":"socks","server":"127.0.0.1","port":1080}'
  printf '%s\n' "$outbound" | sing_change_user_or_outbound sing_prepare_outbound a1b2c3d4 selected '["alice"]' || fail 'user SOCKS outbound'
  jq -e '.route.rules[0].action == "resolve" and .route.rules[1].action == "reject" and
    any(.route.rules[]; .auth_user == ["alice"] and .inbound == ["reality-a1b2c3d4"] and
      .outbound == "out-reality-a1b2c3d4-alice")' "$SING_CONF" >/dev/null || fail 'user routing priority'
  jq -e 'any(.outbounds[]; .tag == "out-reality-a1b2c3d4-alice" and .type == "socks")' "$SING_CONF" >/dev/null || fail 'SOCKS outbound generated'
  for kind in shadowsocks vless vmess; do
    case "$kind" in
      shadowsocks)
        outbound='{"mode":"proxy","protocol":"shadowsocks","server":"127.0.0.1","port":1081,"method":"aes-128-gcm","password":"proxy-secret"}' ;;
      vless)
        outbound='{"mode":"proxy","protocol":"vless","server":"example.com","port":443,"uuid":"123e4567-e89b-12d3-a456-426614174001","params":{"encryption":"none","type":"tcp","security":"tls","flow":""}}' ;;
      vmess)
        outbound='{"mode":"proxy","protocol":"vmess","server":"example.com","port":443,"uuid":"123e4567-e89b-12d3-a456-426614174001","method":"auto","params":{"encryption":"none","type":"ws","security":"tls","flow":"","path":"/upstream"}}' ;;
    esac
    printf '%s\n' "$outbound" | sing_change_user_or_outbound sing_prepare_outbound a1b2c3d4 selected '["alice"]' || fail "$kind proxy assignment"
    jq -e --arg kind "$kind" 'any(.outbounds[]; .tag == "out-reality-a1b2c3d4-alice" and .type == $kind)' "$SING_CONF" >/dev/null || fail "$kind proxy render"
  done
  unsupported='{"mode":"proxy","protocol":"vless","server":"example.com","port":443,"uuid":"123e4567-e89b-12d3-a456-426614174001","params":{"encryption":"none","type":"grpc","security":"tls","flow":"","serviceName":"upstream"}}'
  cp "$SING_NODES" "$work/unsupported-before-nodes.json"
  printf '%s\n' "$unsupported" | reject sing_change_user_or_outbound sing_prepare_outbound a1b2c3d4 selected '["alice"]'
  cmp "$SING_NODES" "$work/unsupported-before-nodes.json" || fail 'unsupported outbound changed metadata'
  printf '%s\n' '{"mode":"direct"}' | sing_change_user_or_outbound sing_prepare_outbound a1b2c3d4 selected '["default"]' || fail 'default direct override'
  jq -e 'any(.route.rules[]; .auth_user == ["default"] and .outbound == "direct")' "$SING_CONF" >/dev/null || fail 'default route override'
  printf '%s\n' '"inherit"' | sing_change_user_or_outbound sing_prepare_outbound a1b2c3d4 selected '["alice"]' || fail 'restore user inheritance'
  jq -e '[.route.rules[] | select(.auth_user? == ["alice"])] | length == 0' "$SING_CONF" >/dev/null || fail 'user inheritance route removal'
  for id in a1b2c3d4 abc12345 cdef1234 f1e2d3c4; do
    sing_change_user_or_outbound sing_prepare_user "$id" delete alice || fail "delete user $id"
  done
  jq -e 'all(.nodes[]; (.users|length) == 0)' "$SING_NODES" >/dev/null || fail 'users deleted'
)

if [[ -n "${SING_TEST_BIN:-}" ]]; then
  jq -n '{nodes:[{id:"f1e2d3c4",name:"VMess runtime",tag:"vmess-f1e2d3c4",type:"vmess-ws",
    domain:"vmess.example.com",uuid:"123e4567-e89b-12d3-a456-426614174004",port:24888,
    ws_path:"/test-vmess",caddy_file:"/etc/caddy/Caddyfile",enabled:true,
    users:[{id:"alice",name:"Alice",uuid:"123e4567-e89b-12d3-a456-426614174005",
      outbound:{mode:"proxy",protocol:"socks",server:"127.0.0.1",port:1080}}]}]}' > "$work/runtime-nodes.json"
  sing_render "$work/runtime-nodes.json" "$work/runtime-server.json" || fail 'runtime server render'
  python3 "$root/tests/sing_box_runtime.py" "$SING_TEST_BIN" "$work/runtime-server.json" "$work" || fail 'runtime authentication and routing'
fi

# Uninstall removes the owned WS route but keeps the Caddy domain and certificate state.
(
  test_root="$work"
  CADDY_STATE="$work/uninstall-caddy"
  mkdir -p "$CADDY_STATE/routes/ws.example.com"
  printf ':80 { respond "existing" }\n' > "$work/uninstall-Caddyfile"
  jq --arg file "$work/uninstall-Caddyfile" \
    '.nodes[0].caddy_file=$file' "$work/trojan-nodes.json" > "$work/uninstall-trojan.json"
  jq --arg file "$work/uninstall-Caddyfile" \
    '.nodes[0].caddy_file=$file' "$work/vmess-nodes.json" > "$work/uninstall-vmess.json"
  jq -s '{nodes:(.[0].nodes + .[1].nodes)}' "$work/uninstall-trojan.json" "$work/uninstall-vmess.json" > "$SING_NODES"
  printf 'handle /test-ws { reverse_proxy 127.0.0.1:24777 }\n' > "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy"
  mkdir -p "$CADDY_STATE/routes/vmess.example.com"
  printf 'handle /test-vmess { reverse_proxy 127.0.0.1:24888 }\n' > "$CADDY_STATE/routes/vmess.example.com/f1e2d3c4.caddy"
  confirm() { return 0; }
  systemctl() { return 0; }
  caddy_reload() { [[ "$1" == "$test_root/uninstall-Caddyfile" ]]; }
  sing_uninstall > "$work/trojan-uninstall" || fail 'Trojan WS uninstall'
  test ! -e "$CADDY_STATE/routes/ws.example.com/cdef1234.caddy" || fail 'uninstall retained Trojan route'
  test ! -e "$CADDY_STATE/routes/vmess.example.com/f1e2d3c4.caddy" || fail 'uninstall retained VMess route'
  test -f "$work/uninstall-Caddyfile" || fail 'uninstall removed Caddy site'
  test -d "$CADDY_STATE" || fail 'uninstall removed Caddy state'
)
mkdir -p "$SING_DIR"
cat > "$SING_BIN" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == generate && "${2:-}" == reality-keypair ]]; then
  echo 'PrivateKey: 2A1nlCd-rZYG58FRsWQ5sPaZa0m1wTR6REBBto1JK3U'
  echo 'PublicKey: 2wpfMwjkaOOdvhN5F_ik0QgyCEM6DhVyXYsaDHixuFo'
elif [[ "${1:-}" == generate ]]; then
  echo '123e4567-e89b-12d3-a456-426614174003'
else
  echo 'sing-box version 1.14.4'
  echo 'Tags: with_acme'
fi
EOF
chmod 755 "$SING_BIN"
touch "$SING_DIR/.onevps-managed"

# A failed service restart must restore both metadata and the generated config.
printf '{"nodes":[]}\n' > "$SING_NODES"
printf '{"original":true}\n' > "$SING_CONF"
restart_count=0
systemctl() {
  if [[ "$1" == restart ]]; then
    restart_count=$((restart_count+1))
    (( restart_count > 1 ))
  else return 0; fi
}
reject sing_add_reality
jq -e '.nodes|length == 0' "$SING_NODES" >/dev/null || fail 'node rollback'
jq -e '.original == true' "$SING_CONF" >/dev/null || fail 'config rollback'

# Install uses a digest-verified release archive and leaves no managed files on failure.
(
  SING_DIR="$work/new-sing"
  SING_BIN="$work/new-sing-box"
  SING_NODES="$SING_DIR/onevps-nodes.json"
  SING_CONF="$SING_DIR/config.json"
  SING_SERVICE="$work/new-sing-box.service"
  mkdir -p "$work/release/sing-box-$SING_VERSION-linux-amd64"
  cp "$work/sing-box" "$work/release/sing-box-$SING_VERSION-linux-amd64/sing-box"
  tar -czf "$work/release.tar.gz" -C "$work/release" "sing-box-$SING_VERSION-linux-amd64"
  archive_hash=$(openssl dgst -sha256 "$work/release.tar.gz")
  sing_asset() { printf 'linux-amd64 %s\n' "${archive_hash##* }"; }
  download_file() { cp "$work/release.tar.gz" "${!#}"; }
  ensure_deps() { :; }
  systemctl() { if [[ "$1" == cat || "$1" == restart ]]; then return 1; fi; return 0; }
  reject sing_install
  [[ ! -e "$SING_DIR" && ! -e "$SING_BIN" && ! -e "$SING_SERVICE" ]] || fail 'install cleanup'
  systemctl() { [[ "$1" == cat ]] && return 1; return 0; }
  sing_install >/dev/null || fail 'installation transaction'
  sing_owned || fail 'managed install marker'
)
echo 'ok - sing-box config, exclusivity and REALITY node transaction'
