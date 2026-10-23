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

# macOS lacks util-linux flock. Match its inherited-descriptor locking for tests.
if ! command -v flock >/dev/null 2>&1; then
  mkdir "$TEST_TMP/bin"
  printf '%s\n' '#!/usr/bin/env python3' 'import fcntl, sys' \
    'try: fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)' \
    'except OSError: sys.exit(1)' > "$TEST_TMP/bin/flock"
  chmod +x "$TEST_TMP/bin/flock"
  export PATH="$TEST_TMP/bin:$PATH"
fi

# Tests not exercising readiness explicitly mock it; production always checks.
mock_singbox_readiness() { wait_singbox_ready() { systemctl is-active --quiet onevps-sing-box; }; }
export -f mock_singbox_readiness

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

assert_true "port inspection filters local TCP and UDP sockets and fails closed" bash -c '
  source "$1"
  ss() {
    [[ "$1" == -H && "$3" == "sport = :443" ]] || return 99
    case "$2" in
      -ltn) printf "LISTEN 0 128 [::]:443 [::]:*\n" ;;
      -lun) printf "UNCONN 0 0 0.0.0.0:443 0.0.0.0:*\n" ;;
      *) return 99 ;;
    esac
  }
  port_in_use 443 tcp && port_in_use 443 udp || exit 1
  ss() { :; }; if port_in_use 443; then exit 1; fi
  ss() { return 1; }; port_in_use 443
' _ "$ROOT_DIR/onevps.sh"

assert_true "readiness rejects transient active and foreign listeners" bash -c '
  source "$1"
  counter="$2/ready-count"; printf "0\n" > "$counter"
  mode=ok
  sleep() { :; }
  systemctl() {
    if [[ "$1" == is-active ]]; then
      count=$(<"$counter"); printf "%s\n" "$((count + 1))" > "$counter"
      [[ "$mode" != crash || "$count" == 0 ]]
    elif [[ "$mode" == churn ]]; then printf "%s\n" "$(<"$counter")"
    else printf "42\n"; fi
  }
  ss() {
    [[ "$mode" != missing ]] || return 0
    if [[ "$mode" == foreign ]]; then printf "LISTEN users:((other,pid=43,fd=3))\n"
    elif [[ "$mode" == churn ]]; then printf "LISTEN users:((sing-box,pid=%s,fd=3))\n" "$(<"$counter")"
    else printf "LISTEN users:((sing-box,pid=42,fd=3))\n"; fi
  }
  wait_singbox_ready "$3" || exit 1
  [[ $(<"$counter") == 3 ]] || exit 1
  for mode in crash foreign missing churn; do
    printf "0\n" > "$counter"
    if wait_singbox_ready "$3"; then exit 1; fi
  done
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

assert_true "firewall failures propagate and cleanup never deletes shared rules" bash -c '
  source "$1"
  calls="$2/firewall-calls"; mode=ok
  ufw() {
    printf "%s\n" "$*" >> "$calls"
    if [[ "$1" == status ]]; then printf "Status: active\n"; return 0; fi
    [[ "$mode" != ufw-fail ]]
  }
  firewall-cmd() {
    printf "%s\n" "$*" >> "$calls"
    [[ "$1" != --reload || "$mode" != reload-fail ]]
  }
  open_port 443 tcp || exit 1
  mode=ufw-fail; if open_port 443 tcp; then exit 1; fi
  mode=reload-fail; if open_port 443 udp; then exit 1; fi
  ufw() { return 1; }; if open_port 443 tcp; then exit 1; fi
  : > "$calls"; close_port 443 tcp
  [[ ! -s "$calls" ]]
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP"

assert_true "configuration install and uninstall share a nonblocking process lock" bash -c '
  source "$1"
  SINGBOX_DIR="$2/locking"; mkdir "$SINGBOX_DIR"
  SINGBOX_NODES="$SINGBOX_DIR/nodes.json"; SINGBOX_CONF="$SINGBOX_DIR/config.json"
  SINGBOX_BIN="$SINGBOX_DIR/core"
  cp "$3" "$SINGBOX_NODES"; render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
  printf "#!/bin/sh\nexit 0\n" > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  systemctl() { :; }; mock_singbox_readiness
  hysteria2_preflight() { :; }; verify_hysteria2_nodes() { :; }; open_port() { :; }; ensure_deps() { :; }
  mkfifo "$SINGBOX_DIR/ready" "$SINGBOX_DIR/release"
  first_prepare() {
    printf "ready\n" > "$SINGBOX_DIR/ready"
    read -r release < "$SINGBOX_DIR/release"
    jq ".concurrent.first=true" "$1" > "$2"
  }
  apply_candidate_transaction first_prepare & first=$!
  trap '\''kill "$first" 2>/dev/null || true'\'' EXIT
  read -r ready < "$SINGBOX_DIR/ready"
  if jq_update_nodes ".concurrent.second=true"; then exit 1; fi
  if install_singbox; then exit 1; fi
  if uninstall; then exit 1; fi
  printf "release\n" > "$SINGBOX_DIR/release"
  wait "$first" || exit 1; trap - EXIT
  jq_update_nodes ".concurrent.second=true" || exit 1
  jq -e ".concurrent.first and .concurrent.second" "$SINGBOX_NODES" >/dev/null
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

assert_true "readiness failure restores old metadata and running service" bash -c '
  source "$1"
  SINGBOX_DIR="$2/ready-rollback"; mkdir "$SINGBOX_DIR"
  SINGBOX_NODES="$SINGBOX_DIR/nodes.json"; SINGBOX_CONF="$SINGBOX_DIR/config.json"; SINGBOX_BIN="$SINGBOX_DIR/core"
  cp "$3" "$SINGBOX_NODES"; render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
  cp "$SINGBOX_NODES" "$SINGBOX_DIR/before-nodes"; cp "$SINGBOX_CONF" "$SINGBOX_DIR/before-config"
  printf "#!/bin/sh\nexit 0\n" > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  systemctl() { :; }; hysteria2_preflight() { :; }; open_port() { :; }
  wait_singbox_ready() { if [[ ! -e "$SINGBOX_DIR/failed-once" ]]; then touch "$SINGBOX_DIR/failed-once"; return 1; fi; }
  if jq_update_nodes ".nodes[0].port=8443"; then exit 1; fi
  cmp "$SINGBOX_NODES" "$SINGBOX_DIR/before-nodes" && cmp "$SINGBOX_CONF" "$SINGBOX_DIR/before-config"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

assert_true "firewall failure leaves old port configuration untouched" bash -c '
  source "$1"
  SINGBOX_DIR="$2/firewall-transaction"; mkdir "$SINGBOX_DIR"
  SINGBOX_NODES="$SINGBOX_DIR/nodes.json"; SINGBOX_CONF="$SINGBOX_DIR/config.json"; SINGBOX_BIN="$SINGBOX_DIR/core"
  cp "$3" "$SINGBOX_NODES"; render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
  cp "$SINGBOX_NODES" "$SINGBOX_DIR/before-nodes"; cp "$SINGBOX_CONF" "$SINGBOX_DIR/before-config"
  printf "#!/bin/sh\nexit 0\n" > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  hysteria2_preflight() { :; }; open_port() { return 1; }
  systemctl() { [[ "$1" == is-active ]]; }
  if jq_update_nodes ".nodes[0].port=8443"; then exit 1; fi
  cmp "$SINGBOX_NODES" "$SINGBOX_DIR/before-nodes" && cmp "$SINGBOX_CONF" "$SINGBOX_DIR/before-config"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

assert_true "UUID retry emits only the corrected UUID on stdout" bash -c '
  source "$1"; rand_uuid() { printf "123e4567-e89b-12d3-a456-426614174000\n"; }
  result=$(ask_uuid <<<$'"'"'invalid\n123e4567-e89b-12d3-a456-426614174099'"'"')
  [[ "$result" == 123e4567-e89b-12d3-a456-426614174099 ]]
' _ "$ROOT_DIR/onevps.sh"

assert_true "public address lookup validates responses and refuses broken links" bash -c '
  source "$1"; PUBIP=""
  curl() { if [[ "$*" == *api.ipify.org* ]]; then printf "not an IP\n"; else printf "203.0.113.10\n"; fi; }
  [[ $(pub_ip) == 203.0.113.10 ]] || exit 1
  for bad in "" 999.1.1.1 01.2.3.4 "203.0.113.10 garbage"; do
    if is_valid_ipv4 "$bad"; then exit 1; fi
  done
  curl() { return 1; }
  n=$(jq -c ".nodes[0]" "$2")
  if node_link "$n" > "$3/missing-address"; then exit 1; fi
  [[ ! -s "$3/missing-address" ]] || exit 1
  SINGBOX_NODES="$2"; require_singbox() { :; }; pause() { :; }; clear() { :; }
  pick_node() { printf "a1b2c3d4\n"; }; ask() { printf "0\n"; }
  manage_nodes >/dev/null || exit 1
  show_links >/dev/null || exit 1
  PUBIP=203.0.113.10; [[ $(pub_ip) == "$PUBIP" ]]
' _ "$ROOT_DIR/onevps.sh" "$FIXTURE" "$TEST_TMP"

assert_true "CA dependency checks reject directories empty and invalid bundles" bash -c '
  source "$1"
  mkdir "$2/empty-certs"; : > "$2/empty-bundle"; printf "invalid\n" > "$2/invalid-bundle"
  for path in "$2/empty-certs" "$2/empty-bundle" "$2/invalid-bundle"; do
    if has_ca_bundle "$path"; then exit 1; fi
  done
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=unit-test \
    -keyout "$2/test-ca-key" -out "$2/test-bundle" >/dev/null 2>&1 || exit 1
  has_ca_bundle "$2/test-bundle" || exit 1
  has_ca_bundle() { return 1; }; PKG=apt
  # Capture the dependency list without invoking a package manager.
  pkg_install() { printf "%s\n" "$*" > "$packages"; }
  packages="$2/packages"; ensure_deps >/dev/null
  grep -q ca-certificates "$packages"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP"

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

reality_inbound=$(build_reality_inbound "$reality_node")
assert_jq "builds a public VLESS Reality inbound" "$reality_inbound" \
  '.listen == "0.0.0.0" and .listen_port == 443 and .type == "vless"'
assert_jq "sets Reality target and secret fields" "$reality_inbound" \
  '.tls.enabled and .tls.reality.enabled
   and .tls.reality.handshake.server == "www.example.com"
   and .tls.reality.handshake.server_port == 443
   and .tls.reality.private_key == "PRIVATE_KEY_FIXTURE"
   and .tls.reality.short_id == ["0123456789abcdef"]'
assert_jq "enables Vision on native TCP" "$reality_inbound" \
  '.users[0].flow == "xtls-rprx-vision" and (has("transport") | not)'

# Hysteria 2 uses native ACME, scoped passwords and protocol-aware ports.
hy2_node='{"id":"hy2-test","type":"hysteria2","name":"HY2 / Test","tag":"hy2-test","domain":"hy2.example.com","port":443,"password":"test+pass@hy2","enabled":true,"users":[{"id":"alice","name":"Alice","password":"alice-password"}]}'
jq --argjson node "$hy2_node" '.nodes += [$node]' "$FIXTURE" > "$TEST_TMP/hy2.json"
assert_true "HY2 UDP/443 coexists with Reality TCP/443" validate_node_metadata "$TEST_TMP/hy2.json"
render_config "$TEST_TMP/hy2.json" "$TEST_TMP/hy2-config.json"
assert_file_jq "native ACME uses HTTP-01 only and persistent storage" "$TEST_TMP/hy2-config.json" \
  '.certificate_providers | length == 1 and .[0].type == "acme" and .[0].provider == "letsencrypt" and .[0].disable_tls_alpn_challenge and (.[0].disable_http_challenge|not) and .[0].data_directory == "/var/lib/onevps-acme"'
assert_file_jq "HY2 TLS references shared provider and preserves identities" "$TEST_TMP/hy2-config.json" \
  '[.inbounds[] | select(.tag == "hy2-test")][0] | .tls.certificate_provider == "acme-hy2.example.com" and .tls.enabled and (.users|length)==2 and .users[0].name == "hy2-test@onevps"'
assert_contains "HY2 link encodes password and name" "$(node_link "$hy2_node")" \
  'hysteria2://test%2Bpass%40hy2@hy2.example.com:443/?sni=hy2.example.com#HY2%20%2F%20Test'
assert_contains "HY2 user link selects independent password" "$(node_user_link "$hy2_node" alice)" \
  'hysteria2://alice-password@'
hy2_obfs=$(jq -c '.obfs_password="obfs+secret"' <<<"$hy2_node")
assert_jq "HY2 salamander is optional" "$(build_hysteria2_inbound "$hy2_obfs")" '.obfs.type=="salamander" and .obfs.password=="obfs+secret"'
assert_contains "HY2 link encodes obfuscation password" "$(node_link "$hy2_obfs")" 'obfs=salamander&obfs-password=obfs%2Bsecret'
for mutation in '.nodes[-1].domain="../bad.example"' '.nodes[-1].domain="-bad.example"' '.nodes[-1].obfs_password=""' '.nodes[-1].users[0].password=.nodes[-1].password' '.nodes[0].port=80'; do
  jq "$mutation" "$TEST_TMP/hy2.json" > "$TEST_TMP/hy2-invalid.json"
  assert_false "rejects HY2 metadata $mutation" validate_node_metadata "$TEST_TMP/hy2-invalid.json"
done
jq '.nodes += [(.nodes[-1] | .id="hy2-second" | .tag="hy2-second" | .port=8443)]' "$TEST_TMP/hy2.json" > "$TEST_TMP/hy2-shared.json"
render_config "$TEST_TMP/hy2-shared.json" "$TEST_TMP/hy2-config.json"
assert_file_jq "HY2 nodes share one provider per domain" "$TEST_TMP/hy2-config.json" '(.certificate_providers|length)==1'
assert_true "HY2 nodes share a domain without email" validate_node_metadata "$TEST_TMP/hy2-shared.json"
assert_file_jq "ACME provider omits email" "$TEST_TMP/hy2-config.json" \
  '(.certificate_providers|length)==1 and (.certificate_providers[0]|has("email")|not)'
jq '.nodes[-1].port=443' "$TEST_TMP/hy2-shared.json" > "$TEST_TMP/hy2-invalid.json"
assert_false "same UDP port cannot belong to two nodes" validate_node_metadata "$TEST_TMP/hy2-invalid.json"
jq '(.nodes[] | select(.type=="hysteria2")).enabled=false' "$TEST_TMP/hy2-shared.json" > "$TEST_TMP/hy2-disabled.json"
render_config "$TEST_TMP/hy2-disabled.json" "$TEST_TMP/hy2-config.json"
assert_file_jq "disabled HY2 emits neither inbound nor unused provider" "$TEST_TMP/hy2-config.json" '(has("certificate_providers")|not) and all(.inbounds[]; .type!="hysteria2")'
assert_true "HY2 ports are scoped by transport" bash -c '
  source "$1"; SINGBOX_NODES="$2"
  port_taken_by_node 443 udp && port_taken_by_node 443 tcp &&
    port_taken_by_node 20001 udp && ! port_taken_by_node 443 udp hy2-test
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP/hy2.json"

assert_true "ACME readiness failure rolls back both live files" bash -c '
  source "$1"
  SINGBOX_DIR="$2/rollback-hy2"; mkdir "$SINGBOX_DIR"
  SINGBOX_NODES="$SINGBOX_DIR/nodes.json"; SINGBOX_CONF="$SINGBOX_DIR/config.json"
  SINGBOX_BIN="$SINGBOX_DIR/core"; SINGBOX_SERVICE="$SINGBOX_DIR/service"
  cp "$3" "$SINGBOX_NODES"; render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
  cp "$SINGBOX_NODES" "$SINGBOX_DIR/before-nodes"; cp "$SINGBOX_CONF" "$SINGBOX_DIR/before-config"
  printf "#!/bin/sh\nexit 0\n" > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  systemctl() { return 0; }; hysteria2_preflight() { return 0; }; open_port() { :; }
  mock_singbox_readiness
  verify_hysteria2_nodes() { return 1; }
  ! jq_update_nodes ".nodes[-1].name = \"Changed\"" &&
    cmp "$SINGBOX_NODES" "$SINGBOX_DIR/before-nodes" && cmp "$SINGBOX_CONF" "$SINGBOX_DIR/before-config"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$TEST_TMP/hy2.json"
assert_true "HY2 preflight rejects HTTP listener owned by another process" bash -c '
  source "$1"; SINGBOX_BIN="$2/preflight-core"; SINGBOX_SERVICE="$2/preflight-service"
  printf "#!/bin/sh\nprintf '\''sing-box version 1.14.3\\nTags: with_acme,with_quic\\n'\''\n" > "$SINGBOX_BIN"
  chmod +x "$SINGBOX_BIN"; write_service > "$SINGBOX_SERVICE"
  ss() { printf "LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:((nginx,pid=55,fd=3))\n"; }
  systemctl() { printf "42\n"; }
  ! hysteria2_preflight "$3"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$TEST_TMP/hy2.json"

# Consumed by pub_ip() in the sourced script.
# shellcheck disable=SC2034
PUBIP="203.0.113.10"
# Snell has one PSK, no synthetic default user or per-user routing.
snell_node='{"id":"snell-test","type":"snell","name":"Snell Test","tag":"snell-snell-test","port":20001,"enabled":true,"version":5,"psk":"0123456789abcdef0123456789abcdef"}'
jq --argjson node "$snell_node" '.nodes += [$node]' "$FIXTURE" > "$TEST_TMP/snell.json"
assert_true "Snell TCP coexists with HY2 UDP on the same port" validate_node_metadata "$TEST_TMP/snell.json"
assert_eq "Snell listener uses TCP" tcp "$(node_network snell)"
assert_jq "Snell inbound preserves v5 PSK without users or TLS" "$(build_snell_inbound "$snell_node")" \
  '.type == "snell" and .version == 5 and .psk == "0123456789abcdef0123456789abcdef" and .listen == "0.0.0.0" and .listen_port == 20001 and (has("users")|not) and (has("tls")|not)'
assert_contains "Snell exports Surge version 4, not the core version" "$(node_link "$snell_node")" \
  'snell-snell-test = snell, 203.0.113.10, 20001, psk=0123456789abcdef0123456789abcdef, version=4'
assert_eq "Snell export uses stable tag rather than injectable display name" "$(node_link "$snell_node")" \
  "$(node_link "$(jq -c '.name="Injected, version=6\nOther = direct"' <<<"$snell_node")")"
for mutation in '.nodes[-1].tag="wrong-tag"' 'del(.nodes[-1].psk)' '.nodes[-1].psk=""' '.nodes[-1].psk="0123456789ABCDEF0123456789ABCDEF"' \
  '.nodes[-1].psk="0123456789abcdef0123456789abcde"' '.nodes[-1].psk="0123456789abcdef0123456789abcdef0"' \
  '.nodes[-1].psk="g123456789abcdef0123456789abcdef"' '.nodes[-1].psk=123' \
  'del(.nodes[-1].version)' '.nodes[-1].version=4' '.nodes[-1].version="5"' \
  '.nodes[-1].users=[]' '.nodes[-1].users=null' '.nodes[-1].default_outbound={mode:"direct"}' \
  '.nodes[-1].default_outbound=null' '.nodes[-1].port=443'; do
  jq "$mutation" "$TEST_TMP/snell.json" > "$TEST_TMP/snell-invalid.json"
  assert_false "rejects Snell metadata $mutation" validate_node_metadata "$TEST_TMP/snell-invalid.json"
  assert_false "refuses invalid Snell render $mutation" render_config "$TEST_TMP/snell-invalid.json" "$TEST_TMP/snell-config.json"
done
snell_proxy='{"mode":"proxy","protocol":"socks","server":"127.0.0.1","port":1080}'
assert_true "Snell supports node outbound assignment" prepare_outbound_assignment "$TEST_TMP/snell.json" "$TEST_TMP/snell-proxy.json" snell-test <<<"$snell_proxy"
render_config "$TEST_TMP/snell-proxy.json" "$TEST_TMP/snell-config.json"
assert_file_jq "Snell node route follows safety rules without auth_user" "$TEST_TMP/snell-config.json" \
  '.route.rules[0].action == "sniff" and .route.rules[1].action == "resolve" and all(.route.rules[2:4][]; .action == "reject") and .route.rules[4].inbound == ["snell-snell-test"] and .route.rules[4].outbound == "node-out-snell-test" and all(.route.rules[]; has("auth_user")|not) and any(.outbounds[]; .tag == "node-out-snell-test" and .type == "socks")'
assert_file_jq "Snell assignment never introduces users" "$TEST_TMP/snell-proxy.json" '.nodes[-1] | (has("users")|not) and (has("default_outbound")|not)'
for selection in '["default"]' '["alice"]'; do
  assert_false "Snell rejects selected assignment $selection" prepare_outbound_assignment "$TEST_TMP/snell.json" "$TEST_TMP/snell-invalid.json" snell-test selected "$selection" <<<'{"mode":"direct"}'
done
for action in add reset delete; do
  assert_false "Snell rejects user operation $action" prepare_node_user_change "$TEST_TMP/snell.json" "$TEST_TMP/snell-invalid.json" snell-test "$action" alice <<<'"disposable-password"'
done
assert_true "Snell explicit direct replaces node proxy" prepare_outbound_assignment "$TEST_TMP/snell-proxy.json" "$TEST_TMP/snell-direct.json" snell-test <<<'{"mode":"direct"}'
render_config "$TEST_TMP/snell-direct.json" "$TEST_TMP/snell-config.json"
assert_file_jq "Snell direct emits no unused proxy" "$TEST_TMP/snell-config.json" '(.outbounds|length)==1 and .route.rules[4].outbound=="direct"'
assert_true "Snell can restore inherited direct" prepare_outbound_assignment "$TEST_TMP/snell-proxy.json" "$TEST_TMP/snell-inherit.json" snell-test <<<'"inherit"'
render_config "$TEST_TMP/snell-inherit.json" "$TEST_TMP/snell-config.json"
assert_file_jq "Snell inherit removes outbound and route" "$TEST_TMP/snell-inherit.json" '.nodes[-1]|has("outbound")|not'
assert_file_jq "Snell inherited route uses global direct" "$TEST_TMP/snell-config.json" '(.route.rules|length)==4 and (.outbounds|length)==1'
jq '.nodes[-1].enabled=false' "$TEST_TMP/snell-proxy.json" > "$TEST_TMP/snell-disabled.json"
render_config "$TEST_TMP/snell-disabled.json" "$TEST_TMP/snell-config.json"
assert_file_jq "disabled Snell omits inbound route and proxy" "$TEST_TMP/snell-config.json" 'all(.inbounds[]; .type!="snell") and (.route.rules|length)==4 and (.outbounds|length)==1'
jq '.nodes[-1].port=20003' "$TEST_TMP/snell-proxy.json" > "$TEST_TMP/snell-port.json"
render_config "$TEST_TMP/snell-port.json" "$TEST_TMP/snell-config.json"
assert_file_jq "Snell port update reaches inbound" "$TEST_TMP/snell-config.json" 'any(.inbounds[]; .type=="snell" and .listen_port==20003)'
jq 'del(.nodes[-1])' "$TEST_TMP/snell-proxy.json" > "$TEST_TMP/snell-deleted.json"
render_config "$TEST_TMP/snell-deleted.json" "$TEST_TMP/snell-config.json"
assert_file_jq "Snell deletion removes inbound and node proxy" "$TEST_TMP/snell-config.json" 'all(.inbounds[]; .type!="snell") and (.route.rules|length)==4 and (.outbounds|length)==1'
assert_true "Snell rotation validation and restart failures roll back both files" bash -c '
  source "$1"; SINGBOX_DIR="$2/snell-rollback"; mkdir "$SINGBOX_DIR"
  SINGBOX_NODES="$SINGBOX_DIR/nodes.json"; SINGBOX_CONF="$SINGBOX_DIR/config.json"; SINGBOX_BIN="$SINGBOX_DIR/core"
  printf "#!/bin/sh\nexit 0\n" > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  cp "$3" "$SINGBOX_NODES"; render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
  cp "$SINGBOX_NODES" "$SINGBOX_DIR/nodes.before"; cp "$SINGBOX_CONF" "$SINGBOX_DIR/config.before"
  hysteria2_preflight() { :; }; verify_hysteria2_nodes() { :; }; open_port() { :; }; mock_singbox_readiness
  mode=validate
  validate_singbox_config() { [[ "$mode" != validate ]]; }
  systemctl() {
    if [[ "$1" == restart && "$mode" == restart && ! -e "$SINGBOX_DIR/failed" ]]; then touch "$SINGBOX_DIR/failed"; return 1; fi
    return 0
  }
  for mode in validate restart; do
    if printf "%s\n" abcdef0123456789abcdef0123456789 | apply_candidate_transaction prepare_snell_rotation snell-test; then exit 1; fi
    cmp "$SINGBOX_NODES" "$SINGBOX_DIR/nodes.before" && cmp "$SINGBOX_CONF" "$SINGBOX_DIR/config.before" || exit 1
  done
  mode=ok
  printf "%s\n" abcdef0123456789abcdef0123456789 | apply_candidate_transaction prepare_snell_rotation snell-test || exit 1
  jq -e '\''.nodes[-1].psk=="abcdef0123456789abcdef0123456789"'\'' "$SINGBOX_NODES" >/dev/null &&
    jq -e '\''any(.inbounds[]; .type=="snell" and .psk=="abcdef0123456789abcdef0123456789")'\'' "$SINGBOX_CONF" >/dev/null
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$TEST_TMP/snell-proxy.json"

new_psk=abcdef0123456789abcdef0123456789
assert_true "Snell rotates raw PSK from stdin" prepare_snell_rotation "$TEST_TMP/snell-proxy.json" "$TEST_TMP/snell-rotated.json" snell-test <<<"$new_psk"
assert_eq "Snell rotation changes only PSK" "$(jq -cS 'del(.nodes[-1].psk)' "$TEST_TMP/snell-proxy.json")" "$(jq -cS 'del(.nodes[-1].psk)' "$TEST_TMP/snell-rotated.json")"
assert_file_jq "Snell source keeps old PSK" "$TEST_TMP/snell-proxy.json" '.nodes[-1].psk=="0123456789abcdef0123456789abcdef"'
render_config "$TEST_TMP/snell-rotated.json" "$TEST_TMP/snell-config.json"
assert_file_jq "Snell rotation reaches rendered inbound" "$TEST_TMP/snell-config.json" 'any(.inbounds[]; .type=="snell" and .psk=="abcdef0123456789abcdef0123456789")'
assert_contains "Snell rotation reaches Surge export" "$(node_link "$(jq -c '.nodes[-1]' "$TEST_TMP/snell-rotated.json")")" "psk=$new_psk"
for bad_psk in '' invalid 0123456789ABCDEF0123456789ABCDEF "$new_psk"$'\n'"$new_psk"; do
  assert_false "Snell rotation rejects malformed PSK" prepare_snell_rotation "$TEST_TMP/snell.json" "$TEST_TMP/snell-invalid.json" snell-test <<<"$bad_psk"
done
for id in missing a1b2c3d4 b2c3d4e5; do
  assert_false "Snell rotation rejects non-Snell target $id" prepare_snell_rotation "$TEST_TMP/snell.json" "$TEST_TMP/snell-invalid.json" "$id" <<<"$new_psk"
done

assert_true "Snell rotation keeps raw credentials out of external argv" bash -c '
  source "$1"; capture="$4"
  jq() { printf "%s\n" "$@" >> "$capture"; command jq "$@"; }
  openssl() { printf "%s\n" "$@" >> "$capture"; command openssl "$@"; }
  printf "%s\n" abcdef0123456789abcdef0123456789 | prepare_snell_rotation "$2" "$3" snell-test || exit 1
  render_config "$3" "$3.config" || exit 1
  PUBIP=203.0.113.10
  node_link "$(command jq -c ".nodes[-1]" "$3")" >/dev/null || exit 1
  ! command grep -Eq "abcdef0123456789abcdef0123456789|0123456789abcdef0123456789abcdef" "$capture"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP/snell-proxy.json" "$TEST_TMP/snell-secret.json" "$TEST_TMP/snell-argv"

reality_link_output=$(node_link "$reality_node")
assert_contains "builds a complete VLESS share link" "$reality_link_output" \
  "vless://123e4567-e89b-12d3-a456-426614174000@203.0.113.10:443?"
assert_contains "encodes VLESS display name" "$reality_link_output" \
  "type=tcp#Reality%20Test%20%2F%20HK"
assert_false "share link omits unsupported spider path" \
  bash -c '[[ "$1" == *spx=* ]]' _ "$reality_link_output"

SINGBOX_DIR="$TEST_TMP/singbox"
SINGBOX_CONF="$SINGBOX_DIR/config.json"
SINGBOX_NODES="$SINGBOX_DIR/onevps-nodes.json"
# Consumed by validation and restart guards in the sourced script.
# shellcheck disable=SC2034
SINGBOX_BIN="$TEST_TMP/initial-mock-singbox"
mkdir -p "$SINGBOX_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SINGBOX_BIN"
chmod +x "$SINGBOX_BIN"
cp "$FIXTURE" "$SINGBOX_NODES"
render_config "$SINGBOX_NODES" "$SINGBOX_CONF"

# File ownership is covered by runtime integration; unit tests remain unprivileged.
secure_singbox_files() { :; }
validate_singbox_config() { :; }
systemctl() { :; }
mock_singbox_readiness
hysteria2_preflight() { :; }
verify_hysteria2_nodes() { :; }
open_port() { :; }

rebuild_config
assert_file_jq "includes only enabled nodes" "$SINGBOX_CONF" \
  '.inbounds | length == 2'
assert_file_jq "keeps private-network blocking" "$SINGBOX_CONF" \
  'any(.route.rules[]; .action == "reject" and (.ip_cidr // [] | index("10.0.0.0/8")))'
assert_file_jq "keeps BitTorrent blocking" "$SINGBOX_CONF" \
  'any(.route.rules[]; .protocol? == ["bittorrent"])'
assert_file_jq "does not block UDP/443 by default" "$SINGBOX_CONF" \
  'all(.route.rules[]; (.network? == "udp" and .port? == "443") | not)'

for legacy_udp443 in true false; do
  jq --argjson legacy "$legacy_udp443" '.settings.block_udp443 = $legacy' "$FIXTURE" > "$SINGBOX_NODES"
  rebuild_config
  assert_file_jq "ignores legacy UDP/443 setting $legacy_udp443" "$SINGBOX_CONF" \
    'all(.route.rules[]; (.network? == "udp" and .port? == "443") | not)'
  assert_file_jq "preserves legacy metadata $legacy_udp443" "$SINGBOX_NODES" \
    ".settings.block_udp443 == $legacy_udp443"
done

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

# Fresh installations use schema 1 and reject legacy credentials explicitly.
node_candidate="$TEST_TMP/node-candidate.json"
jq '.extra = {retained:true} | .settings.block_udp443 = false' "$FIXTURE" > "$SINGBOX_NODES"
assert_true "accepts schema 1 metadata" validate_node_metadata "$SINGBOX_NODES"
assert_true "renders schema 1 default identities" render_config "$SINGBOX_NODES" "$TEST_TMP/rendered.json"
assert_file_jq "each enabled node keeps only its default identity" "$TEST_TMP/rendered.json" \
  'all(.inbounds[]; .users | length == 1) and .inbounds[0].users[0].uuid == "123e4567-e89b-12d3-a456-426614174000" and .inbounds[1].users[0].password == "test+pass@example"'
assert_file_jq "defaults emit one direct outbound without user routes" "$TEST_TMP/rendered.json" \
  '(.outbounds|length) == 1 and .outbounds[0].type == "direct" and all(.route.rules[]; has("auth_user")|not)'
assert_eq "Reality TLS unchanged" "$(jq -c '.tls' <<<"$reality_inbound")" \
  "$(jq -c '.inbounds[0].tls' "$TEST_TMP/rendered.json")"
for mutation in 'del(.schema_version)' '.schema_version = 0' '.schema_version = 2' '.schema_version = "1"' \
  '.users = []' '.users = false' '.users = null' '.users = "obsolete"' '.clients = []' \
  '.nodes[0].spider_x = "/"' '.nodes[2].clients = []' '.nodes[0].clients = []' '.nodes[0].clients = false' '.nodes[0].clients = null' '.nodes[1].clients = {invalid:true}'; do
  jq "$mutation" "$SINGBOX_NODES" > "$node_candidate"
  assert_false "rejects old or incompatible metadata: $mutation" validate_node_metadata "$node_candidate"
  assert_false "refuses to render incompatible metadata: $mutation" render_config "$node_candidate" "$TEST_TMP/rendered.json"
done
for mutation in '.nodes[1].type = "unsupported"' '.nodes = null' '.nodes[0].id = ""' '.nodes[1].id = .nodes[0].id' '.nodes[0].uuid = null' '.nodes[1].password = ""'; do
  jq "$mutation" "$SINGBOX_NODES" > "$node_candidate"
  assert_false "rejects invalid node metadata: $mutation" validate_node_metadata "$node_candidate"
done

# Mock executable and service operations; never access host services.
SINGBOX_BIN="$TEST_TMP/mock-singbox"
printf '#!/usr/bin/env bash\nif [[ "$1 $2" == "generate uuid" ]]; then h=$(openssl rand -hex 16); printf "%%s-%%s-%%s-%%s-%%s\\n" "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"; else exit 0; fi\n' > "$SINGBOX_BIN"
chmod +x "$SINGBOX_BIN"
MOCK_VALIDATE_FAIL=false
validate_singbox_config() { ! $MOCK_VALIDATE_FAIL; }
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
render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
chmod 640 "$SINGBOX_NODES"
chmod 600 "$SINGBOX_CONF"
cp -p "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
cp -p "$SINGBOX_CONF" "$TEST_TMP/before-config"
assert_true "transaction applies a node outbound" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
assert_true "transaction preserves original permission modes" bash -c '
  mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  [[ $(mode "$1") == 640 && $(mode "$2") == 600 ]]
' _ "$SINGBOX_NODES" "$SINGBOX_CONF"
assert_file_jq "transaction preserves root unknown fields and settings" "$SINGBOX_NODES" '.extra.retained and (.settings.block_udp443 | not)'
assert_file_jq "transaction preserves fresh schema" "$SINGBOX_NODES" '.schema_version == 1 and (has("users")|not) and all(.nodes[]; has("clients")|not) and .nodes[0].outbound.mode == "direct"'
cp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
cp "$SINGBOX_CONF" "$TEST_TMP/before-config"
MOCK_VALIDATE_FAIL=true
assert_false "validation failure leaves live files untouched" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
MOCK_VALIDATE_FAIL=false
assert_true "validation failure preserves metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
MOCK_SERVICE_MODE=once
assert_false "restart failure rolls back whole assignment" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
assert_true "restart failure restores metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
assert_true "restart failure restores runtime config" cmp "$SINGBOX_CONF" "$TEST_TMP/before-config"
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
assert_true "replacement failure restores metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
assert_true "replacement failure restores config" cmp "$SINGBOX_CONF" "$TEST_TMP/before-config"
mv() {
  command mv "$@" || return 1
  if [[ "$*" == *nodes.next* ]]; then bash -c 'kill -TERM "$PPID"'; fi
}
assert_false "ordinary interruption rolls back replaced metadata" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
unset -f mv
assert_true "interruption restores metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
assert_true "interruption restores runtime config" cmp "$SINGBOX_CONF" "$TEST_TMP/before-config"
assert_true "transaction cleanup removes secret staging directories" bash -c 'shopt -s nullglob; paths=("$1"/.transaction.*); (( ${#paths[@]} == 0 ))' _ "$SINGBOX_DIR"
printf 'active\n' > "$SERVICE_STATE"
MOCK_SERVICE_MODE=fail
assert_false "rollback restart failure is not reported as success" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'
recovery=$(printf '%s\n' "$SINGBOX_DIR"/.transaction.*)
assert_true "failed rollback retains recovery files" test -f "$recovery/nodes.backup"
rm -rf "$recovery"
# Candidate snapshot owns rendered settings, never live metadata.
jq '.nodes[0].uuid = "123e4567-e89b-12d3-a456-426614174099"' "$SINGBOX_NODES" > "$node_candidate"
assert_true "renders isolated candidate snapshot" render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "candidate default never mixes old disk credentials" "$TEST_TMP/rendered.json" '.inbounds[0].users[0].uuid == "123e4567-e89b-12d3-a456-426614174099"'
assert_false "malformed candidate renderer fails" render_config "$SERVICE_STATE" "$TEST_TMP/rendered.json"
SINGBOX_BIN="$TEST_TMP/missing-singbox"
assert_false "node transaction requires sing-box binary" apply_outbound_assignment b2c3d4e5 <<<'{"mode":"direct"}'

# Outbound links: exercise the public stdin interface, never pass secrets to jq argv.
parse_test_link() { printf '%s\n' "$1" | parse_outbound_link; }
uuid='123e4567-e89b-12d3-a456-426614174000'
for method in aes-128-gcm aes-256-gcm chacha20-ietf-poly1305; do
  encoded=$(printf '%s' "$method:secret+:%password" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  parsed=$(parse_test_link "ss://$encoded@[2001:db8::1]:443/#remark")
  assert_jq "SIP002 $method preserves encoded credentials and IPv6" "$parsed" '.password == "secret+:%password" and .server == "2001:db8::1"'
  outbound=$(build_proxy_outbound test <<<"$parsed")
  assert_jq "SS builds upstream server and password" "$outbound" '.type == "shadowsocks" and .server_port == 443 and .server == "2001:db8::1" and .password == "secret+:%password"'
  assert_eq "SS retains $method cipher" "$method" "$(jq -r '.method' <<<"$outbound")"
done
parsed=$(parse_test_link 'ss://aes-128-gcm:secret%40%3A%25+@proxy.example:443')
assert_jq "plain SIP002 decodes once and preserves plus" "$parsed" '.password == "secret@:%+"'
parsed=$(parse_test_link 'socks5://user%3Aname:p%40ss%3A%25+@[::1]:1080#test')
assert_jq "SOCKS percent auth round trip" "$(build_proxy_outbound socks-test <<<"$parsed")" '.type == "socks" and .version == "5" and .username == "user:name" and .password == "p@ss:%+"'
assert_jq "SOCKS anonymous has no users" "$(parse_test_link 'socks5://localhost:1080' | build_proxy_outbound test)" 'has("username") | not'
for network in tcp ws grpc; do
  extra=''
  case "$network" in ws) extra='&host=cdn.example&path=%2Fws%3Fed%3D2048' ;; grpc) extra='&serviceName=service&mode=gun' ;; esac
  parsed=$(parse_test_link "vless://$uuid@proxy.example:443?security=tls&type=$network&sni=proxy.example&fp=chrome&alpn=h2,http%2F1.1$extra")
  outbound=$(build_proxy_outbound test <<<"$parsed")
  assert_jq "VLESS TLS $network enables verified TLS" "$outbound" '.type == "vless" and .tls.enabled and (.tls.insecure // false | not) and .tls.server_name == "proxy.example" and .tls.alpn == ["h2","http/1.1"]'
  case "$network" in
    tcp) assert_jq "VLESS TCP omits transport" "$outbound" 'has("transport")|not' ;;
    ws) assert_jq "VLESS WS preserves path and Host" "$outbound" '.transport.type == "ws" and .transport.path == "/ws?ed=2048" and .transport.headers.Host == "cdn.example"' ;;
    grpc) assert_jq "VLESS gRPC preserves service name" "$outbound" '.transport.type == "grpc" and .transport.service_name == "service"' ;;
  esac
done
parsed=$(parse_test_link "vless://$uuid@proxy.example:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&type=tcp")
assert_jq "imports current Vision Reality link shape" "$(build_proxy_outbound test <<<"$parsed")" '.tls.reality.enabled and .tls.reality.public_key == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" and .tls.reality.short_id == "0123456789abcdef" and .flow == "xtls-rprx-vision" and .uuid == "123e4567-e89b-12d3-a456-426614174000" and (has("transport")|not)'
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
  "vless://$uuid@example.com:443?security=tls&type=grpc&mode=multi" \
  "vless://$uuid@example.com:443?security=reality&sni=www.example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&spx=%2F" \
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
cp "$FIXTURE" "$SINGBOX_NODES"
node_proxy=$(parse_test_link 'socks5://node.example:1080')
second_proxy=$(parse_test_link 'ss://aes-256-gcm:secret@second.example:443')
assert_true "prepare node outbound does not alter live source" prepare_outbound_assignment "$SINGBOX_NODES" "$node_candidate" a1b2c3d4 <<<"$node_proxy"
assert_file_jq "live node remains without outbound" "$SINGBOX_NODES" '.nodes[0] | has("outbound") | not'
cp "$node_candidate" "$SINGBOX_NODES"
assert_true "prepare independent second node proxy" prepare_outbound_assignment "$SINGBOX_NODES" "$node_candidate" b2c3d4e5 <<<"$second_proxy"
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "direct first and resolved security blocks precede node routes" "$TEST_TMP/rendered.json" '.outbounds[0].tag == "direct" and .outbounds[0].type == "direct" and .route.rules[0].action == "sniff" and .route.rules[1] == {action:"resolve",server:"local"} and all(.route.rules[2:4][]; .action == "reject") and (.route.rules|length) == 6'
assert_file_jq "two node proxies have isolated inbound routes" "$TEST_TMP/rendered.json" '(.outbounds|length) == 3 and .route.rules[4].outbound == "node-out-a1b2c3d4" and .route.rules[5].outbound == "node-out-b2c3d4e5" and .route.rules[4].inbound != .route.rules[5].inbound and all(.route.rules[]; has("auth_user")|not)'
cp "$node_candidate" "$SINGBOX_NODES"
assert_true "explicit node direct replaces only selected proxy" prepare_outbound_assignment "$SINGBOX_NODES" "$node_candidate" b2c3d4e5 <<<'{"mode":"direct"}'
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "node direct leaves other proxy intact" "$TEST_TMP/rendered.json" '.route.rules[5].outbound == "direct" and .route.rules[4].outbound == "node-out-a1b2c3d4" and (.outbounds|length) == 2'
cp "$node_candidate" "$SINGBOX_NODES"
prepare_outbound_assignment "$SINGBOX_NODES" "$node_candidate" b2c3d4e5 <<<'"inherit"'
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "reset removes saved node field" "$node_candidate" '.nodes[1]|has("outbound")|not'
assert_file_jq "reset returns node to default direct" "$TEST_TMP/rendered.json" '(.route.rules|length) == 5 and .route.rules[4].outbound == "node-out-a1b2c3d4"'
jq '.nodes[0].enabled=false' "$node_candidate" > "$TEST_TMP/disabled.json"
render_config "$TEST_TMP/disabled.json" "$TEST_TMP/rendered.json"
assert_file_jq "disabled node retains setting but emits no routes or proxy" "$TEST_TMP/rendered.json" '(.route.rules|length) == 4 and (.outbounds|length) == 1'
jq '.nodes[0].outbound=null' "$TEST_TMP/disabled.json" > "$TEST_TMP/invalid.json"
assert_false "disabled node cannot hide corrupt outbound" render_config "$TEST_TMP/invalid.json" "$TEST_TMP/rendered.json"
# No outbound settings produce one direct outbound and three security rules.
render_config "$FIXTURE" "$TEST_TMP/default.json"
assert_file_jq "fresh render has no extra routes or outbounds" "$TEST_TMP/default.json" '(.route.rules|length) == 4 and (.outbounds|length) == 1'
# Shared transaction is exercised again with actual outbound candidates.
SINGBOX_BIN="$TEST_TMP/mock-singbox"
MOCK_SERVICE_MODE=ok
MOCK_VALIDATE_FAIL=false
render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
assert_true "outbound transaction commits proxy to both files" apply_outbound_assignment b2c3d4e5 <<<"$second_proxy"
assert_file_jq "committed config contains node proxy" "$SINGBOX_CONF" 'any(.outbounds[]; .type == "shadowsocks")'
cp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
cp "$SINGBOX_CONF" "$TEST_TMP/before-config"
MOCK_VALIDATE_FAIL=true
assert_false "outbound core validation failure leaves live data unchanged" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
MOCK_VALIDATE_FAIL=false
assert_true "outbound failed validation preserves metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
rm -f "$TEST_TMP/restart-failed"
MOCK_SERVICE_MODE=once
assert_false "outbound failed restart rolls back" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
assert_true "outbound rollback restores metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
assert_true "outbound rollback restores config" cmp "$SINGBOX_CONF" "$TEST_TMP/before-config"
MOCK_SERVICE_MODE=ok
mv() { if [[ "$*" == *config.next* ]]; then return 1; fi; command mv "$@"; }
assert_false "outbound replacement failure rolls back" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
unset -f mv
assert_true "outbound replacement restores metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
assert_true "outbound staging directories cleaned" bash -c 'shopt -s nullglob; paths=("$1"/.transaction.*); (( ${#paths[@]} == 0 ))' _ "$SINGBOX_DIR"
assert_false "unknown target cannot silently succeed" prepare_outbound_assignment "$SINGBOX_NODES" "$node_candidate" missing <<<'{"mode":"direct"}'
# Proxy input stays visible; cancellation must not log credentials or write anything.
assert_true "cancelled outbound menu uses visible input and preserves files" bash -c '
  source "$1"; SINGBOX_NODES="$2"
  read() { local arg; for arg in "$@"; do [[ "$arg" != -s ]] || return 1; done; builtin read "$@"; }
  ask() { if [[ "$1" == Scope ]]; then printf "1\n"; else printf "3\n"; fi; }; confirm() { return 1; }
  before=$(cksum "$2")
  output=$(manage_outbound a1b2c3d4 <<<"socks5://secret-user:secret-password@proxy.example:1080" 2>&1)
  [[ "$output" != *secret-user* && "$output" != *secret-password* && "$before" == "$(cksum "$2")" ]]
' _ "$ROOT_DIR/onevps.sh" "$SINGBOX_NODES"

# Both node menus expose local user management and outbound settings.
for node_id in a1b2c3d4 b2c3d4e5; do
  outbound_action=8; [[ "$node_id" != b2c3d4e5 ]] || outbound_action=6
  printf '%s\n1\n2\n0\n' "$outbound_action" > "$TEST_TMP/menu-input"
  assert_true "node menu $node_id exposes outbound and local users" bash -c '
    source "$1"; SINGBOX_NODES="$2"; selected="$3"; capture="$5"
    exec 3< "$4"
    ask() { local answer; IFS= read -r answer <&3 || return 1; printf "%s\n" "$answer"; }
    require_singbox() { :; }; ensure_nodes_file() { :; }; clear() { :; }; node_link() { :; }
    pick_node() { printf "%s\n" "$selected"; }; confirm() { return 0; }
    apply_outbound_assignment() { printf "%s\n" "$*" > "$capture"; command cat >> "$capture"; }
    before=$(cksum "$2")
    output=$(manage_nodes)
    [[ "$output" == *"Set node outbound"* && "$output" != *"Connection users"* &&
       "$(command cat "$capture")" == "$selected all []"$'"'"'\n'"'"''"'"'{"mode":"direct"}'"'"' && "$before" == "$(cksum "$2")" ]]
  ' _ "$ROOT_DIR/onevps.sh" "$SINGBOX_NODES" "$node_id" "$TEST_TMP/menu-input" "$TEST_TMP/menu-applied"
done
printf '3\n0\n' > "$TEST_TMP/menu-input"
assert_true "main menu dispatches Hysteria 2 without restoring global users" bash -c '
  source "$1"; exec 3< "$2"
  clear() { :; }; status_line() { :; }
  ask() { local answer; IFS= read -r answer <&3 || return 1; printf "%s\n" "$answer"; }
  manage_users() { printf "REMOVED_DISPATCH\n"; }
  add_hysteria2_node() { printf "HY2_DISPATCH\n"; }
  output=$(main_menu)
  [[ "$output" == *HY2_DISPATCH* && "$output" != *"Manage connection users"* && "$output" != *REMOVED_DISPATCH* ]]
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP/menu-input"
printf '%s\n' {1..11} 0 > "$TEST_TMP/menu-input"
assert_true "main menu displays and dispatches consecutive grouped options" bash -c '
  source "$1"; exec 3< "$2"
  clear() { :; }; status_line() { :; }; pause() { :; }
  ask() { local answer; IFS= read -r answer <&3 || exit 1; printf "%s\n" "$answer"; }
  install_singbox() { echo DISPATCH:install; }
  add_reality_node() { echo DISPATCH:reality; }
  add_hysteria2_node() { echo DISPATCH:hysteria2; }
  add_snell_node() { echo DISPATCH:snell; }
  manage_nodes() { echo DISPATCH:manage; }
  show_links() { echo DISPATCH:links; }
  realm_menu() { echo DISPATCH:realm; }
  enable_bbr() { echo DISPATCH:bbr; }
  optimize_system() { echo DISPATCH:tcp; }
  restart_service() { echo DISPATCH:restart; }
  uninstall() { echo DISPATCH:uninstall; }
  output=$(main_menu) || exit 1
  expected=$(printf "DISPATCH:%s\n" install reality hysteria2 snell manage links realm bbr tcp restart uninstall)
  [[ "$(printf "%s\n" "$output" | command grep "^DISPATCH:")" == "$expected" ]] || exit 1
  displayed=$(printf "%s\n" "$output" | sed -n "/^  [0-9][0-9]*) /p" | head -n 12)
  expected=$(printf "  %s\n" \
    "1) Install / update sing-box-core" \
    "2) Add node - VLESS + Reality + Vision + uTLS" \
    "3) Add node - Hysteria 2 + native ACME" \
    "4) Add node - Snell (Surge v4)" \
    "5) Manage nodes" \
    "6) Show default node links / client configurations" \
    "7) Realm relay" "8) BBR acceleration" "9) TCP optimization" \
    "10) Restart service" "11) Uninstall" "0) Exit")
  [[ "$displayed" == "$expected" && "$output" == *"Core installation"* &&
     "$output" == *"Node management"* && "$output" == *"Relay and optimization"* &&
     "$output" == *"Service maintenance"* ]]
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
assert_true "outbound signal restores metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
assert_true "outbound signal restores config" cmp "$SINGBOX_CONF" "$TEST_TMP/before-config"
printf 'active\n' > "$SERVICE_STATE"
MOCK_SERVICE_MODE=fail
assert_false "outbound failed recovery preserves backups" apply_outbound_assignment a1b2c3d4 <<<'{"mode":"direct"}'
recovery=$(printf '%s\n' "$SINGBOX_DIR"/.transaction.*)
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
  source "$1"; SINGBOX_NODES="$2"; capture="$3"; output="$4"
  jq() { printf "%s\n" "$@" >> "$capture"; command jq "$@"; }
  openssl() { printf "%s\n" "$@" >> "$capture"; command openssl "$@"; }
  proxy=$(printf "%s\n" "socks5://SECRET_USERNAME:SECRET_PASSWORD@proxy.example:1080" | parse_outbound_link)
  prepare_outbound_assignment "$SINGBOX_NODES" "$output" a1b2c3d4 <<<"$proxy"
  render_config "$output" "$output.config"
  ! command grep -q "SECRET_USERNAME\|SECRET_PASSWORD" "$capture"
' _ "$ROOT_DIR/onevps.sh" "$SINGBOX_NODES" "$TEST_TMP/argv" "$TEST_TMP/secret-candidate"
assert_true "creation rotation and encoded links keep credentials out of jq argv" bash -c '
  source "$1"; root="$2/secret-menus"; mkdir "$root"
  SINGBOX_NODES="$root/nodes.json"; cp "$3" "$SINGBOX_NODES"; capture="$root/argv"
  jq() { printf "%s\n" "$@" >> "$capture"; command jq "$@"; }
  openssl() { printf "%s\n" "$@" >> "$capture"; command openssl "$@"; }
  require_singbox() { :; }; ensure_nodes_file() { :; }; pause() { :; }; confirm() { return 0; }
  port_taken_by_node() { return 1; }; port_in_use() { return 1; }; check_hysteria2_dns() { :; }
  pick_reality_target() { printf "www.example.com\n"; }
  ask_uuid() { printf "123e4567-e89b-12d3-a456-426614174099\n"; }
  gen_x25519() { printf "SECRET_PRIVATE_KEY PUBLIC_KEY\n"; }; rand_password() { printf "SECRET_PASSWORD\n"; }
  ask() { case "$1" in
    "Node name") printf "test\n" ;;
    "Listen port"|"Hysteria 2 UDP port") printf "8443\n" ;;
    "Certificate domain") printf "new.example.com\n" ;;
    "ACME contact email") touch "$root/unexpected-email-prompt"; return 1 ;;
  esac; }
  apply_candidate_transaction() {
    local prepare="$1"; shift
    "$prepare" "$SINGBOX_NODES" "$root/candidate" "$@" || return 1
    cp "$root/candidate" "$SINGBOX_NODES"
  }
  PUBIP=203.0.113.10
  add_reality_node > "$root/reality-output" || exit 1
  command jq -e '\''.nodes[-1].uuid == "123e4567-e89b-12d3-a456-426614174099" and .nodes[-1].reality_private_key == "SECRET_PRIVATE_KEY"'\'' "$SINGBOX_NODES" >/dev/null || exit 1
  rotate_reality_secret a1b2c3d4 >/dev/null || exit 1
  command jq -e '\''.nodes[0].reality_private_key == "SECRET_PRIVATE_KEY"'\'' "$SINGBOX_NODES" >/dev/null || exit 1
  add_hysteria2_node > "$root/hy2-output" || exit 1
  [[ ! -e "$root/unexpected-email-prompt" ]] || exit 1
  command jq -e '\''.nodes[-1] | has("acme_email") | not'\'' "$SINGBOX_NODES" >/dev/null || exit 1
  command jq -e '\''.nodes[-1].password == "SECRET_PASSWORD" and .nodes[-1].obfs_password == "SECRET_PASSWORD"'\'' "$SINGBOX_NODES" >/dev/null || exit 1
  ! grep -q "SECRET_PRIVATE_KEY\|SECRET_PASSWORD\|123e4567-e89b-12d3-a456-426614174099" "$capture"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

# Validation logs are deliberately withheld even when the core prints a secret.
assert_true "rebuild does not echo core validation secrets" bash -c '
  source "$1"; SINGBOX_NODES="$2"; SINGBOX_DIR=$(dirname "$2"); SINGBOX_BIN="$3"; SINGBOX_CONF="$4"
  hysteria2_preflight() { :; }
  validate_singbox_config() { touch "$SINGBOX_DIR/validator-called"; printf "SECRET_CORE_OUTPUT\n" > "$2"; return 1; }
  output=$(rebuild_config 2>&1) && exit 1
  [[ -f "$SINGBOX_DIR/validator-called" && "$output" != *SECRET_CORE_OUTPUT* ]]
' _ "$ROOT_DIR/onevps.sh" "$SINGBOX_NODES" "$SINGBOX_BIN" "$SINGBOX_CONF"

# Node-local identities, scoped routing, batch selection, and transactions.
cp "$FIXTURE" "$SINGBOX_NODES"
render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
user_a='{"id":"alice","name":"Alice","uuid":"123e4567-e89b-12d3-a456-426614174011"}'
user_b='{"id":"bob","name":"Bob","uuid":"123e4567-e89b-12d3-a456-426614174012"}'
assert_true "add Reality user transaction" apply_node_user_change a1b2c3d4 add <<<"$user_a"
assert_true "add second Reality user transaction" apply_node_user_change a1b2c3d4 add <<<"$user_b"
assert_true "same user ID and name are independent across nodes" apply_node_user_change b2c3d4e5 add <<<'{"id":"alice","name":"Alice","password":"user+secret"}'
assert_file_jq "both protocols retain default and add users" "$SINGBOX_CONF" '(.inbounds[0].users|length) == 3 and (.inbounds[1].users|length) == 2'
assert_file_jq "runtime names retain stable node-scoped authentication identities" "$SINGBOX_CONF" \
  '.inbounds[0].users[0].name == "reality-a1b2c3d4@onevps" and
   .inbounds[1].users[0].name == "hy2-b2c3d4e5@onevps" and
   .inbounds[0].users[1].name == ((["a1b2c3d4","alice"]|tojson|@base64) + "@onevps-user") and
   .inbounds[0].users[1].name != .inbounds[1].users[1].name and
   all(.inbounds[].users[]; (has("email")|not) and (has("id")|not))'
assert_contains "Reality user link uses independent credential" "$(node_user_link "$(node_by_id a1b2c3d4)" alice)" 'vless://123e4567-e89b-12d3-a456-426614174011@'
assert_contains "HY2 user link encodes independent password" "$(node_user_link "$(node_by_id b2c3d4e5)" alice)" 'hysteria2://user%2Bsecret@'
for mutation in '.nodes[0].users=null' '.nodes[0].users[0].id="default"' '.nodes[0].users[0].id="bad id"' '.nodes[0].users[0].name=" "' '.nodes[0].users[1].id="alice"' '.nodes[0].users[1].name="Alice"' '.nodes[0].users[0].uuid=.nodes[0].uuid' '.nodes[0].users[0].uuid="bad"' '.nodes[1].users[0].password=.nodes[1].password' '.nodes[0].default_outbound=null' '.nodes[0].users[0].outbound=null'; do
  jq "$mutation" "$SINGBOX_NODES" > "$node_candidate"
  assert_false "reject invalid local user metadata $mutation" validate_node_metadata "$node_candidate"
done
assert_false "duplicate user addition rejected" apply_node_user_change a1b2c3d4 add <<<"$user_a"
assert_false "default cannot be deleted" apply_node_user_change a1b2c3d4 delete default
assert_false "unknown user cannot be deleted" apply_node_user_change a1b2c3d4 delete missing
assert_false "default reset rejects local credential collision" apply_node_user_change a1b2c3d4 reset <<<'"123e4567-e89b-12d3-a456-426614174011"'
assert_false "HY2 reset rejects local credential collision" apply_node_user_change b2c3d4e5 reset <<<'"user+secret"'
assert_true "set inherited node proxy for all identities" apply_outbound_assignment a1b2c3d4 <<<"$node_proxy"
assert_true "selected batch sets default and Alice only" apply_outbound_assignment a1b2c3d4 selected '["default","alice"]' <<<"$second_proxy"
assert_file_jq "default override does not change node inheritance" "$SINGBOX_NODES" '.nodes[0].outbound.protocol == "socks" and .nodes[0].default_outbound.protocol == "shadowsocks" and (.nodes[0].users[1]|has("outbound")|not)'
assert_file_jq "security blocks precede scoped identity routes and fallback" "$SINGBOX_CONF" '.route.rules[0].action == "sniff" and .route.rules[1].action == "resolve" and all(.route.rules[2:4][]; .action == "reject") and .route.rules[4].auth_user == [.inbounds[0].users[0].name] and .route.rules[5].auth_user == [.inbounds[0].users[1].name] and all(.route.rules[4:6][]; .inbound == ["reality-a1b2c3d4"]) and (.route.rules[6]|has("auth_user")|not)'
for selected in '[]' '["missing"]' '["alice","missing"]' '["alice","alice"]' 'null'; do
  assert_false "invalid selection is rejected as a batch $selected" apply_outbound_assignment a1b2c3d4 selected "$selected" <<<'{"mode":"direct"}'
done
assert_true "explicit direct overrides inherited proxy" apply_outbound_assignment a1b2c3d4 selected '["alice"]' <<<'{"mode":"direct"}'
assert_true "restore selected inheritance" apply_outbound_assignment a1b2c3d4 selected '["alice"]' <<<'"inherit"'
assert_file_jq "restore selected preserves default override" "$SINGBOX_NODES" '(.nodes[0].users[0]|has("outbound")|not) and .nodes[0].default_outbound.mode == "proxy"'
other=$(jq -c '.nodes[1]' "$SINGBOX_NODES")
assert_true "all users clears every override" apply_outbound_assignment a1b2c3d4 <<<"$node_proxy"
assert_file_jq "all clears default and individual overrides" "$SINGBOX_NODES" '(.nodes[0]|has("default_outbound")|not) and all(.nodes[0].users[]; has("outbound")|not)'
assert_eq "other node unchanged by all users" "$other" "$(jq -c '.nodes[1]' "$SINGBOX_NODES")"
assert_true "future user inherits node outbound" apply_node_user_change a1b2c3d4 add <<<'{"id":"future","name":"Future","uuid":"123e4567-e89b-12d3-a456-426614174013"}'
assert_true "new user can receive dedicated outbound" apply_outbound_assignment a1b2c3d4 selected '["future"]' <<<"$second_proxy"
assert_true "deleting user removes credential and proxy" apply_node_user_change a1b2c3d4 delete future
assert_file_jq "deleted user leaves no runtime proxy or client" "$SINGBOX_CONF" '(.inbounds[0].users|length)==3 and (.outbounds|length)==2'
jq '.nodes[0].enabled=false' "$SINGBOX_NODES" > "$node_candidate"
render_config "$node_candidate" "$TEST_TMP/rendered.json"
assert_file_jq "disabled node emits no local identities or outbounds" "$TEST_TMP/rendered.json" '(.inbounds|length)==1 and (.outbounds|length)==1'
cp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
cp "$SINGBOX_CONF" "$TEST_TMP/before-config"
MOCK_VALIDATE_FAIL=true
assert_false "user deletion validation failure is atomic" apply_node_user_change a1b2c3d4 delete alice
MOCK_VALIDATE_FAIL=false
rm -f "$TEST_TMP/restart-failed"
MOCK_SERVICE_MODE=once
assert_false "user deletion restart failure rolls back" apply_node_user_change a1b2c3d4 delete alice
assert_true "user rollback restores metadata" cmp "$SINGBOX_NODES" "$TEST_TMP/before-nodes"
assert_true "user rollback restores runtime" cmp "$SINGBOX_CONF" "$TEST_TMP/before-config"
MOCK_SERVICE_MODE=ok
# Drive the actual menus with only service/core operations stubbed above.
(
  ask() { local answer; IFS= read -r answer || return 1; printf '%s\n' "$answer"; }
  confirm() { return 0; }; pause() { :; }
  for id in a1b2c3d4 b2c3d4e5; do
    manage_node_users "$id" <<<$'1\nMenu user\n0' >/dev/null
    count=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|(.users|length)+1' "$SINGBOX_NODES")
    manage_node_users "$id" <<<"$(printf '3\n%s\n0\n' "$count")" > "$TEST_TMP/menu-link"
    command grep -q 'Menu%20user' "$TEST_TMP/menu-link" || exit 1
    manage_outbound "$id" <<<$'2\n1 2\n2' >/dev/null
    jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.default_outbound.mode=="direct" and .users[0].outbound.mode=="direct"' "$SINGBOX_NODES" >/dev/null || exit 1
    manage_outbound "$id" <<<$'1\n1' >/dev/null
    manage_node_users "$id" <<<"$(printf '2\n%s\n0\n' "$count")" >/dev/null
  done
) || fail 'real node user and outbound menus'
pass 'real menus add/link/select multiple/all/delete on both protocols'
assert_file_jq "menu deletion preserves other users and removes all overrides" "$SINGBOX_NODES" 'all(.nodes[0:2][]; (has("outbound")|not) and (has("default_outbound")|not) and all(.users[]; .name != "Menu user" and (has("outbound")|not)))'

# Shared password reset and node deletion retain transactional safety on both protocols.
assert_true "password reset and node deletion preserve shared state and rollback" bash -c '
  source "$1"
  SINGBOX_DIR="$2/node-lifecycle"; mkdir -p "$SINGBOX_DIR"
  SINGBOX_NODES="$SINGBOX_DIR/nodes.json"; SINGBOX_CONF="$SINGBOX_DIR/config.json"
  SINGBOX_BIN="$SINGBOX_DIR/core"
  printf "#!/bin/sh\nexit 0\n" > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  cp "$3" "$SINGBOX_NODES"; render_config "$SINGBOX_NODES" "$SINGBOX_CONF"
  pause() { :; }; confirm() { return 0; }; ask() { printf "new-default-password\n"; }
  hysteria2_preflight() { :; }; verify_hysteria2_nodes() { :; }; open_port() { :; }
  mock_singbox_readiness
  close_port() { printf "%s\n" "$*" >> "$SINGBOX_DIR/closed"; }
  fail_restart=false
  systemctl() {
    if [[ "$1" == restart ]] && $fail_restart && [[ ! -e "$SINGBOX_DIR/failed" ]]; then
      touch "$SINGBOX_DIR/failed"; return 1
    fi
    return 0
  }
  reset_node_password b2c3d4e5 || exit 1
  jq -e ".nodes[1].password == \"new-default-password\"" "$SINGBOX_NODES" >/dev/null || exit 1
  jq -e ".inbounds[1].users[0].password == \"new-default-password\"" "$SINGBOX_CONF" >/dev/null || exit 1
  SINGBOX_ACME_DIR="$SINGBOX_DIR/acme"
  mkdir "$SINGBOX_ACME_DIR"; printf "keep certificate\n" > "$SINGBOX_ACME_DIR/certificate"
  for id in a1b2c3d4 b2c3d4e5; do
    cp "$SINGBOX_NODES" "$SINGBOX_DIR/nodes.before"; cp "$SINGBOX_CONF" "$SINGBOX_DIR/config.before"
    fail_restart=true; rm -f "$SINGBOX_DIR/failed"
    if del_node "$id"; then exit 1; fi
    cmp "$SINGBOX_NODES" "$SINGBOX_DIR/nodes.before" && cmp "$SINGBOX_CONF" "$SINGBOX_DIR/config.before" || exit 1
    [[ ! -e "$SINGBOX_DIR/closed" ]] || exit 1
  done
  fail_restart=false
  del_node b2c3d4e5 || exit 1
  jq -e "all(.nodes[]; .id != \"b2c3d4e5\")" "$SINGBOX_NODES" >/dev/null || exit 1
  jq -e "all(.inbounds[]; .type != \"hysteria2\") and (has(\"certificate_providers\")|not)" "$SINGBOX_CONF" >/dev/null || exit 1
  [[ ! -e "$SINGBOX_DIR/closed" && $(<"$SINGBOX_DIR/acme/certificate") == "keep certificate" ]] || exit 1
  del_node a1b2c3d4 || exit 1
  [[ $(<"$SINGBOX_DIR/closed") == "443 tcp" ]]
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

# Core validation must invoke the real check interface, even on a fresh install.
assert_true "real validator rejects missing core and propagates check failures" bash -c '
  source "$1"
  SINGBOX_BIN="$2/core"; SINGBOX_CONF="$2/config.json"
  printf "{}\n" > "$SINGBOX_CONF"
  if validate_singbox_config "$SINGBOX_CONF" "$2/check.log"; then exit 1; fi
  printf "#!/usr/bin/env bash\n[[ \$1 == check && \$2 == -c && -f \$3 ]] || exit 99\nprintf SECRET_CORE_OUTPUT\\\\n\nexit 7\n" > "$SINGBOX_BIN"
  chmod +x "$SINGBOX_BIN"
  if validate_singbox_config "$SINGBOX_CONF" "$2/check.log"; then exit 1; fi
  grep -q SECRET_CORE_OUTPUT "$2/check.log"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP"

assert_true "sing-box download progress respects terminals and preserves verification" bash -c '
  root="$2/download-progress"; mkdir -p "$root"
  cat > "$root/check.sh" <<'\''CHECK'\''
set -euo pipefail
source "$1"
root="$2"; mode="$3"; expected="$4"
ARCH=amd64
asset="sing-box-${SINGBOX_VERSION#v}-linux-$ARCH.tar.gz"
mkdir -p "$root/fixture/${asset%.tar.gz}" "$root/dest"
printf "#!/bin/sh\nprintf '\''sing-box version %s\\n'\''\n" "${SINGBOX_VERSION#v}" > "$root/fixture/${asset%.tar.gz}/sing-box"
tar -czf "$root/archive.tar.gz" -C "$root/fixture" "${asset%.tar.gz}/sing-box"
fixture_digest=$(openssl dgst -sha256 "$root/archive.tar.gz"); fixture_digest=${fixture_digest##* }
[[ "$mode" != checksum ]] || fixture_digest=$(printf "%064d" 0)
curl() {
  if [[ "$*" == *api.github.com* ]]; then
    jq -n --arg version "$SINGBOX_VERSION" --arg asset "$asset" --arg digest "sha256:$fixture_digest" \
      '\''{tag_name:$version,assets:[{name:$asset,digest:$digest,browser_download_url:("https://github.com/SagerNet/sing-box/releases/download/"+$version+"/"+$asset)}]}'\''
    return
  fi
  printf "%s\n" "$@" > "$root/curl-args"
  [[ "$mode" != failure ]] || return 22
  local output=""
  while (( $# )); do
    if [[ "$1" == -o ]]; then output="$2"; break; fi
    shift
  done
  cp "$root/archive.tar.gz" "$output"
}
status=0
download_singbox "$root/dest" || status=$?
grep -qx -- "$expected" "$root/curl-args"
if [[ "$expected" == --silent ]]; then
  ! grep -qx -- --progress-bar "$root/curl-args"
else
  ! grep -qx -- --silent "$root/curl-args"
fi
if [[ "$mode" == success ]]; then
  [[ "$status" == 0 && -x "$root/dest/sing-box" ]]
else
  [[ "$status" != 0 && ! -e "$root/dest/sing-box" ]]
fi
CHECK
  python3 - "$1" "$root" <<'\''PY'\''
import os
import pathlib
import pty
import select
import subprocess
import sys

source, root = sys.argv[1:]
for terminal_stdout, terminal_stderr in [(False, False), (True, True), (False, True), (True, False)]:
    for mode in ["success", "failure", "checksum"]:
        work = pathlib.Path(root) / f"{terminal_stdout}-{terminal_stderr}-{mode}"
        work.mkdir()
        master, slave = pty.openpty()
        expected = "--progress-bar" if terminal_stdout and terminal_stderr else "--silent"
        try:
            result = subprocess.run(
                ["bash", str(pathlib.Path(root) / "check.sh"), source, str(work), mode, expected],
                stdout=slave if terminal_stdout else subprocess.PIPE,
                stderr=slave if terminal_stderr else subprocess.PIPE,
                timeout=30,
            )
            output = result.stdout or b""
            errors = result.stderr or b""
            # Drain before closing the slave: macOS may discard unread PTY data.
            while select.select([master], [], [], 0.1)[0]:
                chunk = os.read(master, 4096)
                if not chunk:
                    break
                output += chunk
        finally:
            os.close(slave)
            os.close(master)
        assert result.returncode == 0, (work, output, errors)
        assert b"downloading sing-box" in output, (work, output)
        assert (b"download complete; verifying" in output) == (mode != "failure"), (work, output)
        if mode == "checksum":
            assert b"SHA-256 mismatch" in output + errors, (work, output, errors)
PY
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP"

# Every install path and runtime effect is isolated; no host services are touched.
assert_true "fresh installation checks only OneVPS conflicts and verifies ownership" bash -c '
  source "$1"
  root="$2/install-ownership"; mkdir -p "$root"
  SINGBOX_DIR="$root/config"; SINGBOX_BIN="$root/core"
  SINGBOX_CONF="$SINGBOX_DIR/config.json"; SINGBOX_NODES="$SINGBOX_DIR/nodes.json"
  SINGBOX_SERVICE="$root/core.service"
  conflict=""; failed_query=""
  missing_status=0; failed_output=""
  systemctl() {
    [[ "$*" == "show -p LoadState --value onevps-sing-box.service" ]] || {
      printf "unexpected service query: %s\n" "$*" >&2; return 99;
    }
    [[ "$1" != "$failed_query" ]] || { printf "%s" "$failed_output"; return 1; }
    if [[ -n "$conflict" ]]; then printf "loaded\n"; else printf "not-found\n"; return "$missing_status"; fi
  }
  check_singbox_conflicts || exit 1
  missing_status=1
  check_singbox_conflicts || exit 1
  # Exercise first-run orchestration in a fresh shell with errexit enabled.
  export -f systemctl
  export conflict failed_query failed_output missing_status
  bash -c '\''
    source "$1"
    SINGBOX_DIR="$2/config"; SINGBOX_BIN="$2/core"
    SINGBOX_CONF="$SINGBOX_DIR/config.json"; SINGBOX_NODES="$SINGBOX_DIR/nodes.json"
    SINGBOX_SERVICE="$2/core.service"
    confirm() { return 0; }
    install_singbox() { printf "install reached\n"; }
    ask() { printf "0\n"; }
    first_run
    printf "startup continued\n"
  '\'' _ "$1" "$root" > "$root/startup.log" || exit 1
  grep -qx "install reached" "$root/startup.log" || exit 1
  grep -qx "startup continued" "$root/startup.log" || exit 1
  conflict=onevps-sing-box.service
  if check_singbox_conflicts; then exit 1; fi
  conflict=""
  failed_query=show
  for failed_output in "" loaded error $'\''not-found\nerror'\''; do
    if check_singbox_conflicts 2> "$root/query-error"; then exit 1; fi
    grep -q "failed to query" "$root/query-error" || exit 1
  done
  failed_output=""
  failed_query=""
  for path in "$SINGBOX_DIR" "$SINGBOX_BIN" "$SINGBOX_SERVICE"; do
    printf "unmanaged\n" > "$path"
    if check_singbox_conflicts; then exit 1; fi
    [[ $(<"$path") == unmanaged ]] || exit 1
    rm "$path"
  done
  mkdir "$SINGBOX_DIR"
  cp "$3" "$SINGBOX_NODES"; printf "{}\n" > "$SINGBOX_CONF"
  printf "#!/bin/sh\nexit 0\n" > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  printf "OneVPS sing-box schema 1\n" > "$SINGBOX_DIR/.onevps-managed"
  if singbox_owned; then exit 1; fi
  write_service > "$SINGBOX_SERVICE"
  singbox_owned && check_singbox_conflicts || exit 1
  grep -q "User=nobody" "$SINGBOX_SERVICE" || exit 1
  grep -Fq "run -c $SINGBOX_CONF" "$SINGBOX_SERVICE" || exit 1
  for path in "$SINGBOX_BIN" "$SINGBOX_CONF" "$SINGBOX_NODES" "$SINGBOX_SERVICE" "$SINGBOX_DIR/.onevps-managed"; do
    mv "$path" "$path.original"; ln -s "$path.original" "$path"
    if singbox_owned; then exit 1; fi
    rm "$path"; mv "$path.original" "$path"
  done
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

assert_true "installation is atomic across download validation enable and restart failures" bash -c '
  source "$1"
  root="$2/install-transaction"; mkdir -p "$root"
  SINGBOX_DIR="$root/config"; SINGBOX_BIN="$root/core"
  SINGBOX_CONF="$SINGBOX_DIR/config.json"; SINGBOX_NODES="$SINGBOX_DIR/nodes.json"
  SINGBOX_SERVICE="$root/core.service"
  state="$root/state"; enabled_file="$root/enabled"; calls="$root/calls"
  printf "inactive\n" > "$state"; printf "false\n" > "$enabled_file"
  failure=none
  ensure_deps() { :; }; secure_singbox_files() { :; }
  hysteria2_preflight() { :; }; verify_hysteria2_nodes() { :; }; open_port() { :; }
  mock_singbox_readiness
  installed_version() { printf "test-version\n"; }
  wait_singbox_ready() {
    if [[ "$failure" == readiness && ! -e "$root/failed-once" ]]; then touch "$root/failed-once"; return 1; fi
    systemctl is-active --quiet onevps-sing-box
  }
  systemctl() {
    printf "%s\n" "$*" >> "$calls"
    case "$1" in
      show) printf "not-found\n" ;;
      list-unit-files|list-units) return 0 ;;
      is-active) [[ $(<"$state") == active ]] ;;
      is-enabled) [[ $(<"$enabled_file") == true ]] ;;
      daemon-reload) return 0 ;;
      enable) [[ "$failure" != enable ]] || return 1; printf "true\n" > "$enabled_file" ;;
      disable) printf "false\n" > "$enabled_file" ;;
      stop) printf "inactive\n" > "$state" ;;
      restart)
        if [[ "$failure" == restart && ! -e "$root/failed-once" ]]; then touch "$root/failed-once"; return 1; fi
        printf "active\n" > "$state" ;;
      *) return 99 ;;
    esac
  }
  download_singbox() {
    [[ "$failure" != download ]] || return 1
    if [[ "$failure" == validate ]]; then
      printf "#!/bin/sh\nexit 1\n" > "$1/sing-box"
    else
      printf "#!/bin/sh\nexit 0\n" > "$1/sing-box"
    fi
    chmod +x "$1/sing-box"
  }
  for failure in download validate enable restart readiness; do
    rm -f "$root/failed-once"
    if install_singbox; then exit 1; fi
    [[ ! -e "$SINGBOX_DIR" && ! -e "$SINGBOX_BIN" && ! -e "$SINGBOX_SERVICE" ]] || exit 1
    [[ $(<"$state") == inactive && $(<"$enabled_file") == false ]] || exit 1
  done
  failure=none
  install_singbox && singbox_owned || exit 1
  jq -e ".schema_version == 1 and .nodes == []" "$SINGBOX_NODES" >/dev/null || exit 1
  jq -e "(.outbounds|length)==1 and .outbounds[0].type==\"direct\" and .route.rules[0].action==\"sniff\"" "$SINGBOX_CONF" >/dev/null || exit 1
  [[ $(<"$state") == active && $(<"$enabled_file") == true ]] || exit 1
  cp "$3" "$SINGBOX_NODES"
  render_config "$SINGBOX_NODES" "$SINGBOX_CONF" || exit 1
  printf "#!/bin/sh\n# original core\nexit 0\n" > "$SINGBOX_BIN"
  for path in "$SINGBOX_BIN" "$SINGBOX_SERVICE" "$SINGBOX_CONF" "$SINGBOX_NODES"; do cp -p "$path" "$path.before"; done
  for failure in download validate restart readiness; do
    rm -f "$root/failed-once"
    if install_singbox; then exit 1; fi
    for path in "$SINGBOX_BIN" "$SINGBOX_SERVICE" "$SINGBOX_CONF" "$SINGBOX_NODES"; do cmp "$path" "$path.before" || exit 1; done
    [[ $(<"$state") == active && $(<"$enabled_file") == true ]] || exit 1
  done
  printf "inactive\n" > "$state"; printf "false\n" > "$enabled_file"
  failure=restart; rm -f "$root/failed-once"
  if install_singbox; then exit 1; fi
  [[ $(<"$state") == inactive && $(<"$enabled_file") == false ]] || exit 1
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP" "$FIXTURE"

# Isolate all host tuning operations and paths, including child shells.
(
  TUNE_CONF="$TEST_TMP/tune.conf"
  BBR_CONF="$TEST_TMP/bbr.conf"
  pause() { :; }
  confirm() { return 0; }
  MOCK_RMEM='4096 131072 6291456'
  MOCK_WMEM='8192 262144 4194304'
  MOCK_LOAD=0
  MOCK_READ=0
  sysctl() {
    if [[ "$1" == -p ]]; then
      [[ "$2" == "$TUNE_CONF" || "$2" == "$BBR_CONF" ]] || return 99
      return "$MOCK_LOAD"
    fi
    case "$2" in
      net.ipv4.tcp_rmem) printf '%s\n' "$MOCK_RMEM"; return "$MOCK_READ" ;;
      net.ipv4.tcp_wmem) printf '%s\n' "$MOCK_WMEM"; return "$MOCK_READ" ;;
      net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
      net.core.default_qdisc) printf 'fq\n' ;;
      *) return 99 ;;
    esac
  }
  write_tune_conf > "$TEST_TMP/tune-output"
  command grep -qx 'net.ipv4.tcp_rmem = 4096 131072 67108864' "$TUNE_CONF" || exit 1
  command grep -qx 'net.ipv4.tcp_wmem = 8192 262144 67108864' "$TUNE_CONF" || exit 1
  if command grep -Eq 'swappiness|conntrack|slow_start_after_idle|fin_timeout' "$TUNE_CONF"; then exit 1; fi
  cp "$TUNE_CONF" "$TEST_TMP/tune-original"
  for MOCK_RMEM in 'garbage' '1 2' '1 2 3 4' '0 2 3' '4 2 6' '1 8 6' \
    '1 67108865 99999999' '99999999999999999999999999 2 3' $'1 2 3\n1 2 3'; do
    if write_tune_conf > "$TEST_TMP/tune-output" 2>&1; then exit 1; fi
    cmp "$TUNE_CONF" "$TEST_TMP/tune-original" || exit 1
  done
  MOCK_RMEM='0004096 00087380 67108864'
  write_tune_conf >/dev/null
  command grep -qx 'net.ipv4.tcp_rmem = 4096 87380 67108864' "$TUNE_CONF" || exit 1
  MOCK_WMEM='1 67108864 67108864'
  write_tune_conf >/dev/null
  MOCK_WMEM='invalid'
  cp "$TUNE_CONF" "$TEST_TMP/tune-original"
  if write_tune_conf >/dev/null 2>&1; then exit 1; fi
  cmp "$TUNE_CONF" "$TEST_TMP/tune-original" || exit 1
  MOCK_WMEM='8192 262144 4194304'
  MOCK_READ=1
  if write_tune_conf >/dev/null 2>&1; then exit 1; fi
  cmp "$TUNE_CONF" "$TEST_TMP/tune-original" || exit 1
  MOCK_READ=0
  MOCK_LOAD=1
  if write_tune_conf > "$TEST_TMP/tune-output" 2>&1; then exit 1; fi
  if command grep -q 'TCP tuning applied' "$TEST_TMP/tune-output"; then exit 1; fi
  optimize_system > "$TEST_TMP/tune-output" 2>&1
  command grep -q 'configuration file exists' "$TEST_TMP/tune-output" || exit 1
  command grep -q 'TCP tuning failed' "$TEST_TMP/tune-output" || exit 1
  if command grep -q 'already applied' "$TEST_TMP/tune-output"; then exit 1; fi
  MOCK_LOAD=0
  TUNE_CONF="$TEST_TMP/nonexistent/tune.conf"
  if write_tune_conf > "$TEST_TMP/tune-output" 2>&1; then exit 1; fi
  if command grep -q 'TCP tuning applied' "$TEST_TMP/tune-output"; then exit 1; fi
  # Missing sysctl must fail even inside an if (where errexit is disabled).
  command() { if [[ "$*" == '-v sysctl' ]]; then return 1; fi; builtin command "$@"; }
  if apply_sysctl_file "$TUNE_CONF" >/dev/null 2>&1; then exit 1; fi
  unset -f command

  MOCK_QUEUE='qdisc fq 0: root refcnt 2'
  MOCK_QUERY=0
  MOCK_REPLACE=0
  MOCK_FILTER=''
  ip() { printf '1.1.1.1 dev eth0 src 192.0.2.1\n'; }
  tc() {
    if [[ "$1 $2" == 'qdisc show' ]]; then printf '%s\n' "$MOCK_QUEUE"; return "$MOCK_QUERY"; fi
    if [[ "$1 $2" == 'filter show' ]]; then printf '%s' "$MOCK_FILTER"; return 0; fi
    if [[ "$*" == 'qdisc replace dev eth0 root fq' ]]; then
      printf 'replace\n' >> "$TEST_TMP/tc-calls"; return "$MOCK_REPLACE"
    fi
    return 99
  }
  : > "$TEST_TMP/tc-calls"
  for MOCK_QUEUE in 'qdisc fq 0: root refcnt 2' 'qdisc mq 0: root' \
    'qdisc fq_codel 0: root' 'qdisc noqueue 0: root' 'qdisc htb 1: root' \
    'qdisc pfifo_fast 1: root' 'unrecognized' \
    $'qdisc pfifo_fast 0: root\nqdisc fq_codel 1: parent 0:1'; do
    apply_fq_qdisc >/dev/null || exit 1
    [[ ! -s "$TEST_TMP/tc-calls" ]] || exit 1
  done
  MOCK_QUEUE='qdisc pfifo_fast 0: root refcnt 2 bands 3 priomap 1 2 2'
  MOCK_QUERY=1
  if apply_fq_qdisc >/dev/null 2>&1; then exit 1; fi
  [[ ! -s "$TEST_TMP/tc-calls" ]] || exit 1
  MOCK_QUERY=0
  MOCK_FILTER='filter protocol ip pref 1'
  apply_fq_qdisc >/dev/null
  [[ ! -s "$TEST_TMP/tc-calls" ]] || exit 1
  MOCK_FILTER=''
  apply_fq_qdisc >/dev/null
  [[ $(wc -l < "$TEST_TMP/tc-calls") -eq 1 ]] || exit 1
  MOCK_REPLACE=1
  if apply_fq_qdisc >/dev/null 2>&1; then exit 1; fi
  : > "$TEST_TMP/tc-calls"
  enable_bbr >/dev/null
  [[ ! -s "$TEST_TMP/tc-calls" && ! -e "$BBR_CONF" ]] || exit 1
  bbr_status > "$TEST_TMP/bbr-status"
  command grep -q 'default qdisc: fq  interface qdisc: qdisc pfifo_fast' "$TEST_TMP/bbr-status" || exit 1
) || fail 'isolated TCP tuning and qdisc safety regressions'
pass 'isolated TCP tuning and qdisc safety regressions'

# A direct call under ordinary set -e must stop before claiming success.
if bash -c '
  source "$1"
  TUNE_CONF="$2"; BBR_CONF="$3"
  sysctl() { if [[ "$1" == -n ]]; then printf "4096 65536 4194304\n"; else return 1; fi; }
  write_tune_conf
  printf "unreachable\n"
' _ "$ROOT_DIR/onevps.sh" "$TEST_TMP/errexit-tune" "$TEST_TMP/errexit-bbr" > "$TEST_TMP/errexit-output" 2>&1; then
  fail 'direct sysctl failure obeys errexit'
fi
assert_false 'failed direct call never reports success or continues' \
  command grep -Eq 'TCP tuning applied|unreachable' "$TEST_TMP/errexit-output"

printf '# %d tests passed\n' "$TEST_COUNT"
