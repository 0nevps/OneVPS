#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../onevps.sh
source "$ROOT_DIR/onevps.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
check() { local label="$1"; shift; "$@" || fail "$label"; printf 'ok - %s\n' "$label"; }
reject() { local label="$1"; shift; if "$@"; then fail "$label"; fi; printf 'ok - %s\n' "$label"; }
node='{"id":"hy2","type":"hysteria2","tag":"hy2-test","name":"HY2 / test","domain":"localhost","port":24443,"password":"default+pass:@","tls_cert":"/etc/hy2/cert.pem","tls_key":"/etc/hy2/key.pem","enabled":true,"users":[{"id":"alice","name":"Alice","password":"alice-secret","outbound":{"mode":"direct"}}]}'
jq -n --argjson node "$node" '{nodes:[$node]}' > "$TEST_TMP/nodes.json"
check 'HY2 metadata' validate_node_metadata "$TEST_TMP/nodes.json"
render_config "$TEST_TMP/nodes.json" "$TEST_TMP/config.json"
check 'native protocol, transport, TLS, h3 and users' jq -e '.inbounds[0] | .protocol == "hysteria" and .settings.version == 2 and .settings.users[0].auth == "default+pass:@" and .settings.users[1].auth == "alice-secret" and .streamSettings.network == "hysteria" and .streamSettings.security == "tls" and .streamSettings.tlsSettings.alpn == ["h3"]' "$TEST_TMP/config.json"
check 'per-user route generated' jq -e 'any(.routing.rules[]; .user? == ["WyJoeTIiLCJhbGljZSJd@onevps-user"] and .outboundTag == "direct")' "$TEST_TMP/config.json"
link=$(node_link "$node")
[[ "$link" == *'hysteria2://default%2Bpass%3A%40@localhost:24443/?sni=localhost#HY2%20%2F%20test'* && "$link" != *insecure* ]] || fail 'encoded secure share link'
check 'additional user share link' bash -c '[[ "$1" == *"hysteria2://alice-secret@"* ]]' _ "$(node_user_link "$node" alice)"
for field in password domain tls_cert tls_key; do
  jq --arg field "$field" '.nodes[0][$field]=""' "$TEST_TMP/nodes.json" > "$TEST_TMP/bad.json"
  reject "reject empty $field" validate_node_metadata "$TEST_TMP/bad.json"
done
jq '.nodes[0].port=65536' "$TEST_TMP/nodes.json" > "$TEST_TMP/bad.json"
reject 'invalid port' validate_node_metadata "$TEST_TMP/bad.json"
check 'add HY2 user' prepare_node_user_change "$TEST_TMP/nodes.json" "$TEST_TMP/users.json" hy2 add <<< '{"id":"bob","name":"Bob","password":"bob-secret"}'
reject 'duplicate credential' prepare_node_user_change "$TEST_TMP/nodes.json" "$TEST_TMP/bad.json" hy2 add <<< '{"id":"bob","name":"Bob","password":"alice-secret"}'
check 'reset default credential' prepare_node_user_change "$TEST_TMP/users.json" "$TEST_TMP/reset.json" hy2 reset <<< '"new-secret"'
check 'delete HY2 user' prepare_node_user_change "$TEST_TMP/users.json" "$TEST_TMP/delete.json" hy2 delete alice
check 'toggle node' prepare_hy2_change "$TEST_TMP/nodes.json" "$TEST_TMP/off.json" hy2 toggle
render_config "$TEST_TMP/off.json" "$TEST_TMP/off-config.json"
check 'disabled HY2 omitted' jq -e '.inbounds == []' "$TEST_TMP/off-config.json"
check 'delete node' prepare_hy2_change "$TEST_TMP/nodes.json" "$TEST_TMP/delete.json" hy2 delete
XRAY_NODES="$TEST_TMP/nodes.json"
check 'UDP port conflict' port_taken_by_node 24443 udp
reject 'TCP can share HY2 UDP number' port_taken_by_node 24443 tcp
reject 'exclude current node' port_taken_by_node 24443 udp hy2
ss() { [[ "$1" != -unl ]] || printf 'Netid State Recv-Q Send-Q Local Peer\nudp UNCONN 0 0 0.0.0.0:24443 0.0.0.0:*\n'; }
check 'UDP socket conflict' port_in_use 24443 udp
reject 'TCP socket independent' port_in_use 24443 tcp
unset -f ss
# No host services, permissions or firewall changes in unit tests.
# shellcheck disable=SC2034
XRAY_DIR="$TEST_TMP"
XRAY_CONF="$TEST_TMP/live.json"
cp "$TEST_TMP/config.json" "$XRAY_CONF"
printf '#!/usr/bin/env bash\nprintf "Xray 26.10.21\\n"\n' > "$TEST_TMP/core"
chmod +x "$TEST_TMP/core"
XRAY_BIN="$TEST_TMP/core"
check 'supported core version' require_hy2_core
cat > "$TEST_TMP/core" <<'CORE'
#!/usr/bin/env bash
printf 'Xray 26.10.21\n'
for ((i=0; i<10000; i++)); do
  printf 'additional version output line %s\n' "$i"
done
CORE
check 'large multiline version output does not trigger SIGPIPE' require_hy2_core
printf '#!/usr/bin/env bash\nprintf "loader failure\\n" >&2\nexit 42\n' > "$TEST_TMP/core"
reject 'version command failure rejected' require_hy2_core 2> "$TEST_TMP/version-error"
check 'version command failure includes original diagnostic' grep -q 'loader failure' "$TEST_TMP/version-error"
check 'version command failure includes exit status' grep -q 'exit 42' "$TEST_TMP/version-error"
printf '#!/usr/bin/env bash\nprintf "unexpected version\\n"\n' > "$TEST_TMP/core"
reject 'unrecognized version rejected' require_hy2_core 2> "$TEST_TMP/version-error"
check 'unrecognized version has actionable diagnostic' grep -q 'Cannot parse Xray version: unexpected version' "$TEST_TMP/version-error"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/core"
reject 'empty version rejected' require_hy2_core 2> "$TEST_TMP/version-error"
check 'empty version has diagnostic' grep -q 'Cannot parse Xray version: <empty output>' "$TEST_TMP/version-error"
printf '#!/usr/bin/env bash\nprintf "Xray 26.3.27\\n"\n' > "$TEST_TMP/core"
reject 'older core rejected' require_hy2_core
printf '#!/usr/bin/env bash\nprintf "Xray 26.10.21\\n"\n' > "$TEST_TMP/core"
restart_count=0
systemctl() {
  case "$1" in
    is-active) return 0 ;;
    restart) restart_count=$((restart_count + 1)); (( restart_count > 1 )) ;;
    *) return 0 ;;
  esac
}
cp "$XRAY_NODES" "$TEST_TMP/before.json"
reject 'failed HY2 restart rolls back' apply_candidate_transaction prepare_hy2_change hy2 port 24444
check 'metadata restored' cmp "$XRAY_NODES" "$TEST_TMP/before.json"
check 'config restored' cmp "$XRAY_CONF" "$TEST_TMP/config.json"
unset -f systemctl
systemctl() { return 0; }
pause() { :; }
confirm() { return 0; }
open_port() { printf 'open %s %s\n' "$@" >> "$TEST_TMP/firewall"; }
close_port() { printf 'close %s %s\n' "$@" >> "$TEST_TMP/firewall"; }
ask() { printf '24444\n'; }
check 'edit HY2 UDP port' edit_port hy2
check 'UDP firewall only' grep -qx 'open 24444 udp' "$TEST_TMP/firewall"
check 'old UDP port closed' grep -qx 'close 24443 udp' "$TEST_TMP/firewall"
check 'toggle via management action' toggle_enabled hy2
check 'toggle persists' jq -e '.nodes[0].enabled == false' "$XRAY_NODES"
check 'delete via management action' del_node hy2
check 'node removed' jq -e '.nodes == []' "$XRAY_NODES"
cp "$TEST_TMP/before.json" "$XRAY_NODES"
cp "$TEST_TMP/config.json" "$XRAY_CONF"
reject 'duplicate HY2 port rejected' prepare_hy2_change "$XRAY_NODES" "$TEST_TMP/bad.json" another add \
  "$(jq -c '.nodes[0] | .id="another" | .tag="hy2-another"' "$XRAY_NODES")"
(
  secure_xray_files() { :; }
  validate_hy2_certificate() { return 0; }
  ss() { :; }
  runuser() { :; }
  ask() {
    case "$1" in
      'Node name') printf 'Created from menu\n' ;;
      'Certificate:'*) printf '2\n' ;;
      'TLS domain') printf 'node.example.com\n' ;;
      'Absolute PEM certificate/full-chain path') printf '/etc/hy2/cert.pem\n' ;;
      'Absolute unencrypted PEM private-key path') printf '/etc/hy2/key.pem\n' ;;
      'UDP listen port'*) printf '24445\n' ;;
      'Password'*) printf 'new-menu-password\n' ;;
      *) return 1 ;;
    esac
  }
  check 'creation flow integrates storage, service and UDP firewall' add_hysteria_node
  check 'created HY2 retained alongside existing node' jq -e '.nodes | length == 2' "$XRAY_NODES"
  check 'creation opens UDP only' grep -qx 'open 24445 udp' "$TEST_TMP/firewall"
  cp "$TEST_TMP/before.json" "$XRAY_NODES"
  acme_issue() { printf '%s\n' "$1" > "$TEST_TMP/acme-domain"; }
  ask() {
    case "$1" in
      'Node name') printf 'Automatic HY2\n' ;;
      'Certificate:'*) printf '%s\n' "$2" ;;
      'TLS domain') printf 'node.example.com\n' ;;
      'UDP listen port'*) printf '24445\n' ;;
      'Password'*) printf 'auto-password\n' ;;
      *) printf 'UNEXPECTED PROMPT: %s\n' "$1" >&2; return 1 ;;
    esac
  }
  check 'default certificate flow asks no email or PEM paths' add_hysteria_node
  check 'automatic issuance receives only domain' grep -qx node.example.com "$TEST_TMP/acme-domain"
  check 'automatic certificate path stored' jq -e \
    '.nodes[-1].tls_cert == "/etc/onevps-certs/node.example.com/current/fullchain.pem"' "$XRAY_NODES"
)
cp "$TEST_TMP/before.json" "$XRAY_NODES"
cp "$TEST_TMP/config.json" "$XRAY_CONF"
unset -f systemctl
if [[ -n "${XRAY_TEST_BIN:-}" ]]; then
  XRAY_BIN="$XRAY_TEST_BIN"
  check 'real supported core' require_hy2_core
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_TMP/key.pem" -out "$TEST_TMP/cert.pem" \
    -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
  check 'real certificate and key match' validate_hy2_pem localhost "$TEST_TMP/cert.pem" "$TEST_TMP/key.pem"
  reject 'wrong certificate hostname' validate_hy2_pem wrong.example "$TEST_TMP/cert.pem" "$TEST_TMP/key.pem"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TEST_TMP/wrong-key.pem" >/dev/null 2>&1
  reject 'wrong private key' validate_hy2_pem localhost "$TEST_TMP/cert.pem" "$TEST_TMP/wrong-key.pem"
  reject 'missing certificate rejected' validate_hy2_certificate localhost /tmp/missing-cert /tmp/missing-key
  jq --arg cert "$TEST_TMP/cert.pem" --arg key "$TEST_TMP/key.pem" \
    '.nodes[0].tls_cert=$cert | .nodes[0].tls_key=$key | .nodes[0].users[0].outbound={mode:"proxy",protocol:"socks",server:"127.0.0.1",port:10808}' "$TEST_TMP/nodes.json" > "$TEST_TMP/real.json"
  render_config "$TEST_TMP/real.json" "$TEST_TMP/server.json"
  check 'real core config validation' validate_xray_config "$TEST_TMP/server.json" "$TEST_TMP/check.log"
  python3 "$ROOT_DIR/tests/hy2_runtime.py" "$XRAY_BIN" "$TEST_TMP/server.json" "$TEST_TMP"
else
  printf 'SKIP real HY2 tests: set XRAY_TEST_BIN to Xray >= %s\n' "$HY2_MIN_VERSION"
fi
