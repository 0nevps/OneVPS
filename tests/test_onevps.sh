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

printf '# %d tests passed\n' "$TEST_COUNT"
