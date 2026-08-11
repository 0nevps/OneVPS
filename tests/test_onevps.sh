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

printf '# %d tests passed\n' "$TEST_COUNT"
