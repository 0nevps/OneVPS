#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE="$ROOT_DIR/tests/fixtures/nodes.json"

for dependency in jq openssl; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'missing test dependency: %s\n' "$dependency" >&2
    exit 1
  }
done

# shellcheck source=../onevps.sh
source "$ROOT_DIR/onevps.sh"

TEST_COUNT=0
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %d - %s\n' "$TEST_COUNT" "$1"
}

fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'not ok %d - %s\n' "$TEST_COUNT" "$1" >&2
  shift
  (($# == 0)) || printf '  %s\n' "$*" >&2
  exit 1
}

assert_true() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label" "command returned non-zero: $*"; fi
}

assert_false() {
  local label="$1"
  shift
  if "$@"; then fail "$label" "command unexpectedly succeeded: $*"; else pass "$label"; fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label" "expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label" "missing '$needle'"
  fi
}

assert_jq() {
  local label="$1" json="$2" filter="$3"
  if jq -e "$filter" >/dev/null <<<"$json"; then
    pass "$label"
  else
    fail "$label" "jq assertion failed: $filter"
  fi
}

assert_file_jq() {
  local label="$1" file="$2" filter="$3"
  if jq -e "$filter" "$file" >/dev/null; then
    pass "$label"
  else
    fail "$label" "jq assertion failed: $filter"
  fi
}

assert_true "accepts a canonical UUID" \
  is_valid_uuid "123e4567-e89b-12d3-a456-426614174000"
assert_true "accepts uppercase UUID hex" \
  is_valid_uuid "123E4567-E89B-12D3-A456-426614174000"
assert_false "rejects a compact UUID" \
  is_valid_uuid "123e4567e89b12d3a456426614174000"
assert_false "rejects non-hex UUID characters" \
  is_valid_uuid "123e4567-e89b-12d3-a456-42661417400z"

assert_eq "normalizes URL, port, path, and case" \
  "node.example.com" "$(normalize_domain 'https://Node.Example.COM:443/path')"
assert_true "accepts a subdomain" is_valid_domain "node.example.com"
assert_false "rejects a single-label host" is_valid_domain "localhost"
assert_false "rejects repeated dots" is_valid_domain "node..example.com"
assert_false "rejects whitespace" is_valid_domain "node example.com"

assert_eq "URL-encodes reserved characters" \
  "path%20with%2Fslash%2Bplus" "$(urlenc 'path with/slash+plus')"
assert_true "short IDs are 16 lowercase hex characters" \
  bash -c '[[ "$1" =~ ^[0-9a-f]{16}$ ]]' _ "$(rand_short_id)"
assert_true "random passwords are 32 lowercase hex characters" \
  bash -c '[[ "$1" =~ ^[0-9a-f]{32}$ ]]' _ "$(rand_password)"

reality_node=$(jq -c '.nodes[] | select(.id == "a1b2c3d4")' "$FIXTURE")
trojan_node=$(jq -c '.nodes[] | select(.id == "b2c3d4e5")' "$FIXTURE")

reality_inbound=$(build_reality_inbound "$reality_node")
assert_jq "builds a public VLESS Reality inbound" "$reality_inbound" \
  '.listen == "0.0.0.0" and .port == 443 and .protocol == "vless"'
assert_jq "sets Reality target and secret fields" "$reality_inbound" \
  '.streamSettings.security == "reality"
   and .streamSettings.realitySettings.target == "www.example.com:443"
   and .streamSettings.realitySettings.privateKey == "PRIVATE_KEY_FIXTURE"
   and .streamSettings.realitySettings.shortIds == ["0123456789abcdef"]'
assert_jq "enables Vision and route-only sniffing" "$reality_inbound" \
  '.settings.clients[0].flow == "xtls-rprx-vision"
   and .sniffing.enabled == true
   and .sniffing.routeOnly == true'

trojan_inbound=$(build_trojan_inbound "$trojan_node")
assert_jq "builds a loopback-only Trojan inbound" "$trojan_inbound" \
  '.listen == "127.0.0.1" and .port == 20001 and .protocol == "trojan"'
assert_jq "sets Trojan WebSocket transport without TLS" "$trojan_inbound" \
  '.settings.clients[0].password == "test+pass@example"
   and .streamSettings.network == "ws"
   and .streamSettings.security == "none"
   and .streamSettings.wsSettings.path == "/secret path"'

# Consumed by pub_ip() in the sourced script.
# shellcheck disable=SC2034
PUBIP="203.0.113.10"
reality_link_output=$(node_link "$reality_node")
assert_contains "builds a complete VLESS share link" "$reality_link_output" \
  "vless://123e4567-e89b-12d3-a456-426614174000@203.0.113.10:443?"
assert_contains "encodes VLESS path and display name" "$reality_link_output" \
  "spx=%2F&type=tcp#Reality%20Test%20%2F%20HK"

trojan_link_output=$(node_link "$trojan_node")
assert_contains "encodes the Trojan password" "$trojan_link_output" \
  "trojan://test%2Bpass%40example@node.example.com:443?"
assert_contains "encodes the Trojan WebSocket path" "$trojan_link_output" \
  "path=%2Fsecret%20path#Trojan%20Test"

XRAY_DIR="$TEST_TMP/xray"
XRAY_CONF="$XRAY_DIR/config.json"
XRAY_NODES="$XRAY_DIR/onevps-nodes.json"
# Consumed by validation and restart guards in the sourced script.
# shellcheck disable=SC2034
XRAY_BIN="$TEST_TMP/missing-xray"
mkdir -p "$XRAY_DIR"
cp "$FIXTURE" "$XRAY_NODES"

# File ownership is covered by runtime integration; unit tests remain unprivileged.
secure_xray_files() { :; }

rebuild_config
assert_file_jq "includes only enabled nodes" "$XRAY_CONF" \
  '.inbounds | length == 2'
assert_file_jq "keeps private-network blocking" "$XRAY_CONF" \
  'any(.routing.rules[]; .ip? and (.ip | index("10.0.0.0/8")))'
assert_file_jq "keeps BitTorrent blocking" "$XRAY_CONF" \
  'any(.routing.rules[]; .protocol? == ["bittorrent"])'
assert_file_jq "blocks UDP/443 by default" "$XRAY_CONF" \
  'any(.routing.rules[]; .network? == "udp" and .port? == "443")'

jq '.settings.block_udp443 = false' "$FIXTURE" > "$XRAY_NODES"
rebuild_config
assert_file_jq "honors the UDP/443 opt-out" "$XRAY_CONF" \
  'all(.routing.rules[]; (.network? == "udp" and .port? == "443") | not)'

assert_true "realm accepts maximum port" realm_valid_port 65535
for port in 0 65536 080 -1 '22;id' ''; do
  assert_false "realm rejects invalid port '$port'" realm_valid_port "$port"
done
for host in 192.0.2.1 relay.example.com localhost ::1 2001:db8::1 1:2:3:4:5:6:7:8; do
  assert_true "realm accepts host $host" realm_valid_host "$host"
done
for host in 999.1.1.1 01.2.3.4 1.2.3 'bad host' '-bad.example' 'bad..example' \
  'example.com/path' ':::' '1::2::3' '1:2:3' '::1:' ':1::' '[::1]' '::fffff'; do
  assert_false "realm rejects host $host" realm_valid_host "$host"
done
endpoint=$(realm_endpoint 12345 2001:db8::1 443 both)
assert_jq "realm brackets IPv6 and enables UDP per endpoint" "$endpoint" \
  '.listen == "0.0.0.0:12345" and .remote == "[2001:db8::1]:443"
   and .network.use_udp and (.network.no_tcp | not)'
assert_jq "realm TCP-only endpoint" "$(realm_endpoint 12346 example.com 8443 tcp)" \
  '.remote == "example.com:8443" and (.network.use_udp | not)'
assert_false "realm rejects unsupported protocol" realm_endpoint 12345 example.com 443 udp

REALM_DIR="$TEST_TMP/realm"
# Consumed by realm installation and service generation in the sourced script.
# shellcheck disable=SC2034
REALM_BIN="$TEST_TMP/realm-bin"
REALM_SERVICE="$TEST_TMP/realm.service"
mkdir -p "$REALM_DIR"
assert_false "realm refuses unmanaged paths" realm_install
printf 'original\n' > "$REALM_SERVICE"
assert_false "realm does not own unrelated service" realm_owned
assert_eq "unmanaged service remains unchanged" original "$(cat "$REALM_SERVICE")"
touch "$REALM_DIR/.onevps-managed"
realm_write_service > "$REALM_SERVICE"
assert_true "realm recognizes managed service" realm_owned
assert_contains "realm runs as dynamic unprivileged user" "$(cat "$REALM_SERVICE")" 'DynamicUser=true'
assert_contains "realm service uses separate config" "$(cat "$REALM_SERVICE")" "$REALM_DIR/config.json"
printf '{"endpoints":[]}\n' > "$REALM_DIR/config.json"

# Exercise actual readiness checks before replacing the restart helper.
MOCK_UDP_BOUND=true
systemctl() {
  case "$1" in
    restart|is-active) return 0 ;;
    show) printf '1234\n' ;;
    *) return 1 ;;
  esac
}
sleep() { :; }
ss() {
  if [[ "$2" == -lnup ]] && ! $MOCK_UDP_BOUND; then return 0; fi
  printf 'LISTEN 0 128 0.0.0.0:12345 0.0.0.0:* users:(("realm",pid=1234,fd=5))\n'
}
jq -n --argjson endpoint "$endpoint" '{endpoints:[$endpoint]}' > "$REALM_DIR/config.json"
assert_true "realm verifies owned TCP and UDP listeners" realm_restart
MOCK_UDP_BOUND=false
assert_false "realm detects partial listener failure despite active service" realm_restart
printf '{"endpoints":[]}\n' > "$REALM_DIR/config.json"

# Mock all runtime effects; rollback must restore both data and service state.
MOCK_ACTIVE=false
MOCK_ENABLED=false
MOCK_RESTART_FAIL=false
MOCK_ENABLE_FAIL=false
MOCK_RESTARTS=0
systemctl() {
  case "$1" in
    is-active) "$MOCK_ACTIVE" ;;
    is-enabled) "$MOCK_ENABLED" ;;
    enable) if $MOCK_ENABLE_FAIL; then return 1; fi; MOCK_ENABLED=true ;;
    disable) MOCK_ENABLED=false ;;
    stop) MOCK_ACTIVE=false ;;
    *) return 1 ;;
  esac
}
realm_restart() {
  MOCK_RESTARTS=$((MOCK_RESTARTS + 1))
  if $MOCK_RESTART_FAIL; then MOCK_RESTART_FAIL=false; return 1; fi
  MOCK_ACTIVE=true
}
candidate="$REALM_DIR/candidate"
jq -n --argjson endpoint "$endpoint" '{endpoints:[$endpoint]}' > "$candidate"
assert_true "realm activates first rule" realm_apply "$candidate"
assert_eq "realm starts service" true "$MOCK_ACTIVE"
assert_eq "realm enables service" true "$MOCK_ENABLED"
before=$(cat "$REALM_DIR/config.json")
second=$(realm_endpoint 12346 example.com 443 tcp)
jq --argjson endpoint "$second" '.endpoints += [$endpoint]' "$REALM_DIR/config.json" > "$candidate"
MOCK_RESTART_FAIL=true
assert_false "realm rejects failed restart" realm_apply "$candidate"
assert_eq "realm rollback preserves previous config" "$before" "$(cat "$REALM_DIR/config.json")"
assert_eq "realm rollback restarts old active service" true "$MOCK_ACTIVE"
assert_eq "realm attempted recovery restart" 3 "$MOCK_RESTARTS"

jq --argjson endpoint "$second" '.endpoints += [$endpoint]' "$REALM_DIR/config.json" > "$candidate"
assert_true "realm adds a second rule" realm_apply "$candidate"
assert_file_jq "realm retains both protocols" "$REALM_DIR/config.json" \
  '(.endpoints | length == 2) and .endpoints[0].network.use_udp and (.endpoints[1].network.use_udp | not)'
printf '{"endpoints":[]}\n' > "$candidate"
assert_true "realm removes last rules" realm_apply "$candidate"
assert_eq "realm stops empty service" false "$MOCK_ACTIVE"
assert_eq "realm disables empty service" false "$MOCK_ENABLED"
before=$(cat "$REALM_DIR/config.json")
jq -n --argjson endpoint "$endpoint" '{endpoints:[$endpoint]}' > "$candidate"
MOCK_ENABLE_FAIL=true
assert_false "realm rolls back enable failure" realm_apply "$candidate"
assert_eq "realm restores previously stopped service" false "$MOCK_ACTIVE"
assert_eq "realm enable failure restores config" "$before" "$(cat "$REALM_DIR/config.json")"
printf 'invalid json\n' > "$candidate"
assert_false "realm rejects malformed candidate" realm_apply "$candidate"
assert_eq "malformed candidate leaves config intact" "$before" "$(cat "$REALM_DIR/config.json")"

# Legacy connection-user fields are preserved, but never validated or rendered.
cp "$FIXTURE" "$XRAY_NODES"
node_candidate="$TEST_TMP/node-candidate.json"
jq '.users = [{id:"old",outbound:{mode:"proxy",protocol:"invalid"}}] |
    .nodes[0].clients = [{user_id:"old",uuid:.nodes[0].uuid}] |
    .nodes[1].clients = [{user_id:"old",password:.nodes[1].password}] |
    .extra = {retained:true} | .settings.block_udp443 = false' "$FIXTURE" > "$XRAY_NODES"
assert_true "legacy fields do not require migration" validate_node_metadata "$XRAY_NODES"
assert_true "legacy members do not affect rendering" render_config "$XRAY_NODES" "$TEST_TMP/rendered.json"
assert_file_jq "each enabled node keeps only its default client" "$TEST_TMP/rendered.json" \
  'all(.inbounds[]; .settings.clients | length == 1) and .inbounds[0].settings.clients[0].id == "123e4567-e89b-12d3-a456-426614174000" and .inbounds[1].settings.clients[0].password == "test+pass@example"'
assert_file_jq "legacy users emit no proxies or user routes" "$TEST_TMP/rendered.json" \
  '(.outbounds|length) == 2 and all(.routing.rules[]; has("user")|not)'
assert_eq "Reality transport unchanged" "$(jq -c '.streamSettings' <<<"$reality_inbound")" \
  "$(jq -c '.inbounds[0].streamSettings' "$TEST_TMP/rendered.json")"
for mutation in '.users = false' '.users = null' '.users = "obsolete"' '.nodes[0].clients = false' '.nodes[0].clients = null' '.nodes[1].clients = {invalid:true}'; do
  jq "$mutation" "$XRAY_NODES" > "$node_candidate"
  assert_true "ignores obsolete metadata: $mutation" render_config "$node_candidate" "$TEST_TMP/rendered.json"
done
for mutation in '.nodes = null' '.nodes[0].id = ""' '.nodes[1].id = .nodes[0].id' '.nodes[0].uuid = null' '.nodes[1].password = ""'; do
  jq "$mutation" "$XRAY_NODES" > "$node_candidate"
  assert_false "rejects invalid node metadata: $mutation" validate_node_metadata "$node_candidate"
done
# Default resets no longer consult legacy members and preserve their metadata.
assert_true "default credential resets ignore old member collisions" bash -c '
  source "$1"; XRAY_NODES="$2"; XRAY_DIR=$(dirname "$2")
  secure_xray_files() { :; }; rebuild_config() { :; }; pause() { :; }
  apply_node_user_change() { jq . >/dev/null; }
  ask_uuid() { jq -r ".nodes[0].clients[0].uuid" "$XRAY_NODES"; }
  ask() { jq -r ".nodes[1].clients[0].password" "$XRAY_NODES"; }
  before=$(jq -c "{users,clients:[.nodes[].clients]}" "$2")
  reset_uuid a1b2c3d4 && reset_trojan_password b2c3d4e5 &&
  [[ "$before" == "$(jq -c "{users,clients:[.nodes[].clients]}" "$2")" ]]
' _ "$ROOT_DIR/onevps.sh" "$XRAY_NODES"

# Mock executable and service operations; never access host services.
XRAY_BIN="$TEST_TMP/mock-xray"
printf '#!/usr/bin/env bash\nif [[ "$1" == uuid ]]; then h=$(openssl rand -hex 16); printf "%%s-%%s-%%s-%%s-%%s\\n" "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"; else exit 0; fi\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
MOCK_VALIDATE_FAIL=false
validate_xray_config() { ! $MOCK_VALIDATE_FAIL; }
SERVICE_STATE="$TEST_TMP/service-state"
printf 'active\n' > "$SERVICE_STATE"
MOCK_SERVICE_MODE=ok
systemctl() {
  case "$1" in
    is-active) [[ $(cat "$SERVICE_STATE") == active ]] ;;
    restart)
      if [[ "$MOCK_SERVICE_MODE" == fail ]]; then return 1; fi
      if [[ "$MOCK_SERVICE_MODE" == once && ! -f "$TEST_TMP/restart-failed" ]]; then
        touch "$TEST_TMP/restart-failed"; return 1
      fi
      if [[ "$MOCK_SERVICE_MODE" == inactive ]]; then printf 'inactive\n' > "$SERVICE_STATE"
      else printf 'active\n' > "$SERVICE_STATE"; fi ;;
    stop) printf 'inactive\n' > "$SERVICE_STATE" ;;
    *) return 1 ;;
  esac
}
render_config "$XRAY_NODES" "$XRAY_CONF"
chmod 640 "$XRAY_NODES"
chmod 600 "$XRAY_CONF"
cp -p "$XRAY_NODES" "$TEST_TMP/before-nodes"
cp -p "$XRAY_CONF" "$TEST_TMP/before-config"
assert_true "transaction applies a node outbound" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
assert_true "transaction preserves original permission modes" bash -c '
  mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  [[ $(mode "$1") == 640 && $(mode "$2") == 600 ]]
' _ "$XRAY_NODES" "$XRAY_CONF"
assert_file_jq "transaction preserves root unknown fields and settings" "$XRAY_NODES" '.extra.retained and (.settings.block_udp443 | not)'
assert_file_jq "transaction preserves legacy metadata" "$XRAY_NODES" '.users[0].id == "old" and all(.nodes[0:2][]; .clients | length == 1) and .nodes[0].outbound.mode == "direct"'
cp "$XRAY_NODES" "$TEST_TMP/before-nodes"
cp "$XRAY_CONF" "$TEST_TMP/before-config"
MOCK_VALIDATE_FAIL=true
assert_false "validation failure leaves live files untouched" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
MOCK_VALIDATE_FAIL=false
assert_true "validation failure preserves metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
MOCK_SERVICE_MODE=once
assert_false "restart failure rolls back whole assignment" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
assert_true "restart failure restores metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
assert_true "restart failure restores runtime config" cmp "$XRAY_CONF" "$TEST_TMP/before-config"
assert_eq "rollback restores active service" active "$(cat "$SERVICE_STATE")"
MOCK_SERVICE_MODE=inactive
printf 'inactive\n' > "$SERVICE_STATE"
assert_false "inactive service after restart causes rollback" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
assert_eq "rollback restores stopped service" inactive "$(cat "$SERVICE_STATE")"
MOCK_SERVICE_MODE=ok
mv() {
  if [[ "$*" == *config.next* ]]; then return 1; fi
  command mv "$@"
}
assert_false "second file replacement failure rolls back both files" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
unset -f mv
assert_true "replacement failure restores metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
assert_true "replacement failure restores config" cmp "$XRAY_CONF" "$TEST_TMP/before-config"
mv() {
  command mv "$@" || return 1
  if [[ "$*" == *nodes.next* ]]; then bash -c 'kill -TERM "$PPID"'; fi
}
assert_false "ordinary interruption rolls back replaced metadata" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
unset -f mv
assert_true "interruption restores metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
assert_true "interruption restores runtime config" cmp "$XRAY_CONF" "$TEST_TMP/before-config"
assert_true "transaction cleanup removes secret staging directories" bash -c 'shopt -s nullglob; paths=("$1"/.transaction.*); (( ${#paths[@]} == 0 ))' _ "$XRAY_DIR"
printf 'active\n' > "$SERVICE_STATE"
MOCK_SERVICE_MODE=fail
assert_false "rollback restart failure is not reported as success" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
recovery=$(printf '%s\n' "$XRAY_DIR"/.transaction.*)
assert_true "failed rollback retains recovery files" test -f "$recovery/nodes.backup"
rm -rf "$recovery"
# Candidate snapshot owns rendered settings, never live metadata.
jq '.nodes[0].uuid = "123e4567-e89b-12d3-a456-426614174099"' "$XRAY_NODES" > "$node_candidate"
assert_true "renders isolated candidate snapshot" render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "candidate default never mixes old disk credentials" "$TEST_TMP/rendered.json" '.inbounds[0].settings.clients[0].id == "123e4567-e89b-12d3-a456-426614174099"'
assert_false "malformed candidate renderer fails" render_config "$SERVICE_STATE" "$TEST_TMP/rendered.json"
XRAY_BIN="$TEST_TMP/missing-xray"
assert_false "node transaction requires Xray binary" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'

# Outbound links: exercise the public stdin interface, never pass secrets to jq argv.
parse_test_link() { printf '%s\n' "$1" | parse_outbound_link; }
uuid='123e4567-e89b-12d3-a456-426614174000'
for method in aes-128-gcm aes-256-gcm chacha20-ietf-poly1305; do
  encoded=$(printf '%s' "$method:secret+:%password" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  parsed=$(parse_test_link "ss://$encoded@[2001:db8::1]:443/#remark")
  assert_jq "SIP002 $method preserves encoded credentials and IPv6" "$parsed" '.password == "secret+:%password" and .server == "2001:db8::1"'
  assert_jq "SS builds upstream server" "$(build_proxy_outbound test <<<"$parsed")" '.protocol == "shadowsocks" and .settings.servers[0].port == 443'
done
parsed=$(parse_test_link 'ss://aes-128-gcm:secret%40%3A%25+@proxy.example:443')
assert_jq "plain SIP002 decodes once and preserves plus" "$parsed" '.password == "secret@:%+"'
parsed=$(parse_test_link 'socks5://user%3Aname:p%40ss%3A%25+@[::1]:1080#test')
assert_jq "SOCKS percent auth round trip" "$(build_proxy_outbound socks-test <<<"$parsed")" '.settings.servers[0].users == [{user:"user:name",pass:"p@ss:%+"}]'
assert_jq "SOCKS anonymous has no users" "$(parse_test_link 'socks5://localhost:1080' | build_proxy_outbound test)" '.settings.servers[0] | has("users") | not'
for network in tcp ws grpc; do
  extra=''
  case "$network" in ws) extra='&host=cdn.example&path=%2Fws%3Fed%3D2048' ;; grpc) extra='&serviceName=service&mode=multi' ;; esac
  parsed=$(parse_test_link "vless://$uuid@proxy.example:443?security=tls&type=$network&sni=proxy.example&fp=chrome&alpn=h2,http%2F1.1$extra")
  assert_jq "VLESS TLS $network builds transport" "$(build_proxy_outbound test <<<"$parsed")" ".streamSettings.network == \"$network\" and .streamSettings.tlsSettings.allowInsecure == false"
done
parsed=$(parse_test_link "vless://$uuid@proxy.example:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&spx=%2F&type=tcp")
assert_jq "imports current Vision Reality link shape" "$(build_proxy_outbound test <<<"$parsed")" '.streamSettings.realitySettings.spiderX == "/" and .settings.vnext[0].users[0].flow == "xtls-rprx-vision"'
for bad in \
  'ss://aes-128-gcm:pw@example.com:443?plugin=obfs' \
  'ss://2022-blake3-aes-128-gcm:pw@example.com:443' \
  'ss://aes-128-gcm:%00@example.com:443' \
  'ss://aes-128-gcm:%0A@example.com:443' \
  'ss://aes-128-gcm:%GG@example.com:443' \
  'ss://YWVzLTEyOC1nY206cHc===@example.com:443' \
  'ss://YWVzLTEyOC1nY206cHcA@example.com:443' \
  'socks5://user:@example.com:1080' 'socks5://a@b@example.com:1080' \
  'socks5://example.com:0' 'socks5://example.com:65536' 'socks5://example.com:080' \
  'socks5://999.1.1.1:80' 'socks5://2001:db8::1:80' 'socks5://example.com:80/path' \
  'socks5://example.com:80?unknown=1' 'socks5://example.com:80#bad%0a' \
  "vless://$uuid@example.com:443?security=tls&security=tls" \
  "vless://$uuid@example.com:443?security=tls&unknown=1" \
  "vless://$uuid@example.com:443?security=tls&allowInsecure=1" \
  "vless://$uuid@example.com:443?security=none" \
  "vless://$uuid@example.com:443?security=tls&type=xhttp" \
  "vless://$uuid@example.com:443?security=tls&type=ws&flow=xtls-rprx-vision" \
  "vless://$uuid@example.com:443?security=tls&type=tcp&path=%2F" \
  "vless://$uuid@example.com:443?security=reality" \
  "vless://$uuid@example.com:443?security=tls&type=grpc&mode=unknown" \
  "vless://$uuid@example.com:443?security=tls&pbk=unused" \
  "vless://$uuid@example.com:443?security=tls&"; do
  assert_false "rejects unsupported or malformed link" parse_test_link "$bad"
done
assert_false "rejects multiline input" parse_test_link $'socks5://example.com:1080\nsocks5://other.example:1080'
# Every saved field, including inactive entities, must validate.
for invalid in 'null' '[]' '{"mode":"inherit"}' '{"mode":"direct","extra":1}' \
  '{"mode":"proxy","protocol":"socks","server":"example.com","port":1080,"password":"pw"}' \
  '{"mode":"proxy","protocol":"socks","server":"example.com","port":1080,"username":"a\n","password":"b"}'; do
  assert_false "rejects invalid normalized outbound" validate_outbound <<<"$invalid"
done
cp "$FIXTURE" "$XRAY_NODES"
node_proxy=$(parse_test_link 'socks5://node.example:1080')
second_proxy=$(parse_test_link 'ss://aes-256-gcm:secret@second.example:443')
assert_true "prepare node outbound does not alter live source" prepare_outbound_assignment "$XRAY_NODES" "$node_candidate" a1b2c3d4 <<<"$node_proxy"
assert_file_jq "live node remains without outbound" "$XRAY_NODES" '.nodes[0] | has("outbound") | not'
cp "$node_candidate" "$XRAY_NODES"
assert_true "prepare independent second node proxy" prepare_outbound_assignment "$XRAY_NODES" "$node_candidate" b2c3d4e5 <<<"$second_proxy"
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "direct first and security blocks precede node routes" "$TEST_TMP/rendered.json" '.outbounds[0].tag == "direct" and all(.routing.rules[0:3][]; .outboundTag == "block") and (.routing.rules|length) == 5'
assert_file_jq "two node proxies have isolated inbound routes" "$TEST_TMP/rendered.json" '(.outbounds|length) == 4 and .routing.rules[3].outboundTag == "node-out-a1b2c3d4" and .routing.rules[4].outboundTag == "node-out-b2c3d4e5" and .routing.rules[3].inboundTag != .routing.rules[4].inboundTag and all(.routing.rules[]; has("user")|not)'
cp "$node_candidate" "$XRAY_NODES"
assert_true "explicit node direct replaces only selected proxy" prepare_outbound_assignment "$XRAY_NODES" "$node_candidate" b2c3d4e5 <<<'{"mode":"direct"}'
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "node direct leaves other proxy intact" "$TEST_TMP/rendered.json" '.routing.rules[4].outboundTag == "direct" and .routing.rules[3].outboundTag == "node-out-a1b2c3d4" and (.outbounds|length) == 3'
cp "$node_candidate" "$XRAY_NODES"
prepare_outbound_assignment "$XRAY_NODES" "$node_candidate" b2c3d4e5 <<<'"inherit"'
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "reset removes saved node field" "$node_candidate" '.nodes[1]|has("outbound")|not'
assert_file_jq "reset returns node to default direct" "$TEST_TMP/rendered.json" '(.routing.rules|length) == 4 and .routing.rules[3].outboundTag == "node-out-a1b2c3d4"'
jq '.nodes[0].enabled=false' "$node_candidate" > "$TEST_TMP/disabled.json"
render_config "$TEST_TMP/disabled.json" "$TEST_TMP/rendered.json"
assert_file_jq "disabled node retains setting but emits no routes or proxy" "$TEST_TMP/rendered.json" '(.routing.rules|length) == 3 and (.outbounds|length) == 2'
jq '.nodes[0].outbound=null' "$TEST_TMP/disabled.json" > "$TEST_TMP/invalid.json"
assert_false "disabled node cannot hide corrupt outbound" render_config "$TEST_TMP/invalid.json" "$TEST_TMP/rendered.json"
# No outbound settings produce exactly the legacy two outbounds / three blocks.
render_config "$FIXTURE" "$TEST_TMP/legacy.json"
assert_file_jq "legacy render has no extra routes or outbounds" "$TEST_TMP/legacy.json" '(.routing.rules|length) == 3 and (.outbounds|length) == 2'
# Shared transaction is exercised again with actual outbound candidates.
XRAY_BIN="$TEST_TMP/mock-xray"
MOCK_SERVICE_MODE=ok
MOCK_VALIDATE_FAIL=false
render_config "$XRAY_NODES" "$XRAY_CONF"
assert_true "outbound transaction commits proxy to both files" apply_outbound_assignment b2c3d4e5 <<<"$second_proxy"
assert_file_jq "committed config contains node proxy" "$XRAY_CONF" 'any(.outbounds[]; .protocol == "shadowsocks")'
cp "$XRAY_NODES" "$TEST_TMP/before-nodes"
cp "$XRAY_CONF" "$TEST_TMP/before-config"
MOCK_VALIDATE_FAIL=true
assert_false "outbound core validation failure leaves live data unchanged" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
MOCK_VALIDATE_FAIL=false
assert_true "outbound failed validation preserves metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
rm -f "$TEST_TMP/restart-failed"
MOCK_SERVICE_MODE=once
assert_false "outbound failed restart rolls back" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
assert_true "outbound rollback restores metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
assert_true "outbound rollback restores config" cmp "$XRAY_CONF" "$TEST_TMP/before-config"
MOCK_SERVICE_MODE=ok
mv() { if [[ "$*" == *config.next* ]]; then return 1; fi; command mv "$@"; }
assert_false "outbound replacement failure rolls back" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
unset -f mv
assert_true "outbound replacement restores metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
assert_true "outbound staging directories cleaned" bash -c 'shopt -s nullglob; paths=("$1"/.transaction.*); (( ${#paths[@]} == 0 ))' _ "$XRAY_DIR"
assert_false "unknown target cannot silently succeed" prepare_outbound_assignment "$XRAY_NODES" "$node_candidate" missing <<<'{"mode":"direct"}'
# Proxy input stays visible; cancellation must not log credentials or write anything.
assert_true "cancelled outbound menu uses visible input and preserves files" bash -c '
  source "$1"; XRAY_NODES="$2"
  read() { local arg; for arg in "$@"; do [[ "$arg" != -s ]] || return 1; done; builtin read "$@"; }
  ask() { if [[ "$1" == Scope ]]; then printf "1\n"; else printf "3\n"; fi; }; confirm() { return 1; }
  before=$(cksum "$2")
  output=$(manage_outbound a1b2c3d4 <<<"socks5://secret-user:secret-password@proxy.example:1080" 2>&1)
  [[ "$output" != *secret-user* && "$output" != *secret-password* && "$before" == "$(cksum "$2")" ]]
' _ "$ROOT_DIR/onevps.sh" "$XRAY_NODES"

# Both node menus expose local user management and outbound settings.
for node_id in a1b2c3d4 b2c3d4e5; do
  printf '8\n1\n2\n0\n' > "$TEST_TMP/menu-input"
  assert_true "node menu $node_id keeps outbound 8 and local users 7" bash -c '
    source "$1"; XRAY_NODES="$2"; selected="$3"; capture="$5"
    exec 3< "$4"
    ask() { local answer; IFS= read -r answer <&3 || return 1; printf "%s\n" "$answer"; }
    require_xray() { :; }; ensure_nodes_file() { :; }; clear() { :; }; node_link() { :; }
    pick_node() { printf "%s\n" "$selected"; }; confirm() { return 0; }
    apply_outbound_assignment() { printf "%s\n" "$*" > "$capture"; command cat >> "$capture"; }
    before=$(cksum "$2")
    output=$(manage_nodes)
    [[ "$output" == *"8) Set node outbound"* && "$output" != *"Connection users"* &&
       "$(command cat "$capture")" == "$selected all []"$'"'"'\n'"'"''"'"'{"mode":"direct"}'"'"' && "$before" == "$(cksum "$2")" ]]
  ' _ "$ROOT_DIR/onevps.sh" "$XRAY_NODES" "$node_id" "$TEST_TMP/menu-input" "$TEST_TMP/menu-applied"
done
printf '11\n0\n' > "$TEST_TMP/menu-input"
assert_true "main menu removes and ignores connection-user option 11" bash -c '
  source "$1"; exec 3< "$2"
  clear() { :; }; status_line() { :; }
  ask() { local answer; IFS= read -r answer <&3 || return 1; printf "%s\n" "$answer"; }
  manage_users() { printf "REMOVED_DISPATCH\n"; }
  output=$(main_menu)
  [[ "$output" != *"Manage connection users"* && "$output" != *REMOVED_DISPATCH* ]]
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP/menu-input"
for removed in manage_users show_user_links prepare_user_assignment apply_user_assignment validate_user_metadata; do
  assert_false "removed function $removed is absent" declare -F "$removed"
done

MOCK_SERVICE_MODE=inactive
printf 'inactive\n' > "$SERVICE_STATE"
assert_false "outbound inactive restart rolls back stopped state" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
assert_eq "outbound rollback keeps stopped service stopped" inactive "$(cat "$SERVICE_STATE")"
MOCK_SERVICE_MODE=ok
mv() {
  command mv "$@" || return 1
  if [[ "$*" == *nodes.next* ]]; then bash -c 'kill -TERM "$PPID"'; fi
}
assert_false "outbound signal after replacement rolls back" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
unset -f mv
assert_true "outbound signal restores metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
assert_true "outbound signal restores config" cmp "$XRAY_CONF" "$TEST_TMP/before-config"
printf 'active\n' > "$SERVICE_STATE"
MOCK_SERVICE_MODE=fail
assert_false "outbound failed recovery preserves backups" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
recovery=$(printf '%s\n' "$XRAY_DIR"/.transaction.*)
assert_true "outbound failed rollback keeps recovery metadata" test -f "$recovery/nodes.backup"
assert_true "outbound recovery is private" bash -c '
  mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  [[ $(mode "$1") == 700 && $(mode "$1/nodes.json") == 600 ]]
' _ "$recovery"
rm -rf "$recovery"
MOCK_SERVICE_MODE=ok
assert_false "multiple JSON objects cannot bypass normalized validator" validate_outbound <<<'{"mode":"direct"} {"mode":"direct"}'
# Capture jq/openssl argv around real parsing, rendering and assignment.
# Only IDs, paths and filters may travel in external arguments.
assert_true "outbound secrets never occur in external jq or openssl argv" bash -c '
  source "$1"; XRAY_NODES="$2"; capture="$3"; output="$4"
  jq() { printf "%s\n" "$@" >> "$capture"; command jq "$@"; }
  openssl() { printf "%s\n" "$@" >> "$capture"; command openssl "$@"; }
  proxy=$(printf "%s\n" "socks5://SECRET_USERNAME:SECRET_PASSWORD@proxy.example:1080" | parse_outbound_link)
  prepare_outbound_assignment "$XRAY_NODES" "$output" a1b2c3d4 <<<"$proxy"
  render_config "$output" "$output.config"
  ! command grep -q "SECRET_USERNAME\|SECRET_PASSWORD" "$capture"
' _ "$ROOT_DIR/onevps.sh" "$XRAY_NODES" "$TEST_TMP/argv" "$TEST_TMP/secret-candidate"
# Validation logs are deliberately withheld even when the core prints a secret.
assert_true "rebuild does not echo core validation secrets" bash -c '
  source "$1"; XRAY_NODES="$2"; XRAY_DIR=$(dirname "$2")
  validate_xray_config() { printf "SECRET_CORE_OUTPUT\n" > "$2"; return 1; }
  output=$(rebuild_config 2>&1) && exit 1
  [[ "$output" != *SECRET_CORE_OUTPUT* ]]
' _ "$ROOT_DIR/onevps.sh" "$XRAY_NODES"

# Node-local identities, scoped routing, batch selection, and transactions.
cp "$FIXTURE" "$XRAY_NODES"
render_config "$XRAY_NODES" "$XRAY_CONF"
user_a='{"id":"alice","name":"Alice","uuid":"123e4567-e89b-12d3-a456-426614174011"}'
user_b='{"id":"bob","name":"Bob","uuid":"123e4567-e89b-12d3-a456-426614174012"}'
assert_true "add Reality user transaction" apply_node_user_change a1b2c3d4 add <<<"$user_a"
assert_true "add second Reality user transaction" apply_node_user_change a1b2c3d4 add <<<"$user_b"
assert_true "same user ID and name are independent across nodes" apply_node_user_change b2c3d4e5 add <<<'{"id":"alice","name":"Alice","password":"user+secret"}'
assert_file_jq "both protocols retain default and add clients" "$XRAY_CONF" '.inbounds[0].settings.clients|length == 3'
assert_contains "Reality user link uses independent credential" "$(node_user_link "$(node_by_id a1b2c3d4)" alice)" 'vless://123e4567-e89b-12d3-a456-426614174011@'
assert_contains "Trojan user link encodes independent password" "$(node_user_link "$(node_by_id b2c3d4e5)" alice)" 'trojan://user%2Bsecret@'
for mutation in '.nodes[0].users=null' '.nodes[0].users[0].id="default"' '.nodes[0].users[0].id="bad id"' '.nodes[0].users[0].name=" "' '.nodes[0].users[1].id="alice"' '.nodes[0].users[1].name="Alice"' '.nodes[0].users[0].uuid=.nodes[0].uuid' '.nodes[0].users[0].uuid="bad"' '.nodes[1].users[0].password=.nodes[1].password' '.nodes[0].default_outbound=null' '.nodes[0].users[0].outbound=null'; do
  jq "$mutation" "$XRAY_NODES" > "$node_candidate"
  assert_false "reject invalid local user metadata $mutation" validate_node_metadata "$node_candidate"
done
assert_false "duplicate user addition rejected" apply_node_user_change a1b2c3d4 add <<<"$user_a"
assert_false "default cannot be deleted" apply_node_user_change a1b2c3d4 delete default
assert_false "unknown user cannot be deleted" apply_node_user_change a1b2c3d4 delete missing
assert_false "default reset rejects local credential collision" apply_node_user_change a1b2c3d4 reset <<<'"123e4567-e89b-12d3-a456-426614174011"'
assert_false "Trojan reset rejects local credential collision" apply_node_user_change b2c3d4e5 reset <<<'"user+secret"'
assert_true "set inherited node proxy for all identities" apply_outbound_assignment a1b2c3d4 <<<"$node_proxy"
assert_true "selected batch sets default and Alice only" apply_outbound_assignment a1b2c3d4 selected '["default","alice"]' <<<"$second_proxy"
assert_file_jq "default override does not change node inheritance" "$XRAY_NODES" '.nodes[0].outbound.protocol == "socks" and .nodes[0].default_outbound.protocol == "shadowsocks" and (.nodes[0].users[1]|has("outbound")|not)'
assert_file_jq "security blocks precede scoped identity routes and fallback" "$XRAY_CONF" 'all(.routing.rules[0:3][]; .outboundTag == "block") and .routing.rules[3].user == [.inbounds[0].settings.clients[0].email] and .routing.rules[4].user == [.inbounds[0].settings.clients[1].email] and all(.routing.rules[3:5][]; .inboundTag == ["reality-a1b2c3d4"]) and (.routing.rules[5]|has("user")|not)'
for selected in '[]' '["missing"]' '["alice","missing"]' '["alice","alice"]' 'null'; do
  assert_false "invalid selection is rejected as a batch $selected" apply_outbound_assignment a1b2c3d4 selected "$selected" <<<'{"mode":"direct"}'
done
assert_true "explicit direct overrides inherited proxy" apply_outbound_assignment a1b2c3d4 selected '["alice"]' <<<'{"mode":"direct"}'
assert_true "restore selected inheritance" apply_outbound_assignment a1b2c3d4 selected '["alice"]' <<<'"inherit"'
assert_file_jq "restore selected preserves default override" "$XRAY_NODES" '(.nodes[0].users[0]|has("outbound")|not) and .nodes[0].default_outbound.mode == "proxy"'
other=$(jq -c '.nodes[1]' "$XRAY_NODES")
assert_true "all users clears every override" apply_outbound_assignment a1b2c3d4 <<<"$node_proxy"
assert_file_jq "all clears default and individual overrides" "$XRAY_NODES" '(.nodes[0]|has("default_outbound")|not) and all(.nodes[0].users[]; has("outbound")|not)'
assert_eq "other node unchanged by all users" "$other" "$(jq -c '.nodes[1]' "$XRAY_NODES")"
assert_true "future user inherits node outbound" apply_node_user_change a1b2c3d4 add <<<'{"id":"future","name":"Future","uuid":"123e4567-e89b-12d3-a456-426614174013"}'
assert_true "new user can receive dedicated outbound" apply_outbound_assignment a1b2c3d4 selected '["future"]' <<<"$second_proxy"
assert_true "deleting user removes credential and proxy" apply_node_user_change a1b2c3d4 delete future
assert_file_jq "deleted user leaves no runtime proxy or client" "$XRAY_CONF" '(.inbounds[0].settings.clients|length)==3 and (.outbounds|length)==3'
jq '.nodes[0].enabled=false' "$XRAY_NODES" > "$node_candidate"
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "disabled node emits no local identities or outbounds" "$TEST_TMP/rendered.json" '(.inbounds|length)==1 and (.outbounds|length)==2'
cp "$XRAY_NODES" "$TEST_TMP/before-nodes"
cp "$XRAY_CONF" "$TEST_TMP/before-config"
MOCK_VALIDATE_FAIL=true
assert_false "user deletion validation failure is atomic" apply_node_user_change a1b2c3d4 delete alice
MOCK_VALIDATE_FAIL=false
rm -f "$TEST_TMP/restart-failed"
MOCK_SERVICE_MODE=once
assert_false "user deletion restart failure rolls back" apply_node_user_change a1b2c3d4 delete alice
assert_true "user rollback restores metadata" cmp "$XRAY_NODES" "$TEST_TMP/before-nodes"
assert_true "user rollback restores runtime" cmp "$XRAY_CONF" "$TEST_TMP/before-config"
MOCK_SERVICE_MODE=ok
# Drive the actual menus with only service/core operations stubbed above.
(
  ask() { local answer; IFS= read -r answer || return 1; printf '%s\n' "$answer"; }
  confirm() { return 0; }; pause() { :; }
  for id in a1b2c3d4 b2c3d4e5; do
    manage_node_users "$id" <<<$'1\nMenu user\n0' >/dev/null
    count=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|(.users|length)+1' "$XRAY_NODES")
    manage_node_users "$id" <<<"$(printf '3\n%s\n0\n' "$count")" > "$TEST_TMP/menu-link"
    command grep -q 'Menu%20user' "$TEST_TMP/menu-link" || exit 1
    manage_outbound "$id" <<<$'2\n1 2\n2' >/dev/null
    jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.default_outbound.mode=="direct" and .users[0].outbound.mode=="direct"' "$XRAY_NODES" >/dev/null || exit 1
    manage_outbound "$id" <<<$'1\n1' >/dev/null
    manage_node_users "$id" <<<"$(printf '2\n%s\n0\n' "$count")" >/dev/null
  done
) || fail 'real node user and outbound menus'
pass 'real menus add/link/select multiple/all/delete on both protocols'
assert_file_jq "menu deletion preserves other users and removes all overrides" "$XRAY_NODES" 'all(.nodes[0:2][]; (has("outbound")|not) and (has("default_outbound")|not) and all(.users[]; .name != "Menu user" and (has("outbound")|not)))'

printf '# %d tests passed\n' "$TEST_COUNT"
