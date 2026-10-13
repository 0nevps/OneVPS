#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CORE="${XRAY_TEST_BIN:-}"
[[ -n "$CORE" && -x "$CORE" ]] || {
  printf 'XRAY_TEST_BIN must name a real executable Xray binary\n' >&2
  exit 1
}
# shellcheck source=../onevps.sh
source "$ROOT_DIR/onevps.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

"$CORE" version
# Disposable test keys only; never use these credentials in a deployed node.
"$CORE" x25519 > "$TEST_TMP/keys"
private_key=$(while IFS= read -r line; do
  case "$line" in (PrivateKey:*|'Private key:'*) printf '%s' "${line#*: }" ;; esac
done < "$TEST_TMP/keys")
public_key=$(while IFS= read -r line; do
  case "$line" in ('Password (PublicKey):'*|'Public key:'*|Password:*) printf '%s' "${line#*: }" ;; esac
done < "$TEST_TMP/keys")
[[ -n "$private_key" && -n "$public_key" ]] || { printf 'unrecognized x25519 output\n' >&2; exit 1; }
printf '%s\n' "$private_key" "$public_key" | jq -Rn '[inputs]' > "$TEST_TMP/key-values.json"
jq --slurpfile keys "$TEST_TMP/key-values.json" '
  .nodes |= map(if .type == "vless-reality" then
    .reality_private_key = $keys[0][0] | .reality_public_key = $keys[0][1]
  else . end) |
  .users = [{id:"test-user", name:"Test user"}] |
  .nodes[0].clients = [{user_id:"test-user",uuid:"123e4567-e89b-12d3-a456-426614174002"}] |
  .nodes[1].clients = [{user_id:"test-user",password:"disposable-member-password"}]
' "$ROOT_DIR/tests/fixtures/nodes.json" > "$TEST_TMP/base.json"

check_link() {
  local label="$1" link="$2"
  printf '%s\n' "$link" | parse_outbound_link > "$TEST_TMP/outbound.json"
  prepare_outbound_assignment "$TEST_TMP/base.json" "$TEST_TMP/node.json" nodes a1b2c3d4 < "$TEST_TMP/outbound.json"
  prepare_outbound_assignment "$TEST_TMP/node.json" "$TEST_TMP/users.json" users test-user < "$TEST_TMP/outbound.json"
  render_config "$TEST_TMP/users.json" "$TEST_TMP/config.json"
  if ! "$CORE" run -test -config "$TEST_TMP/config.json" > "$TEST_TMP/check.log" 2>&1; then
    printf 'not ok - real Xray rejected %s (log: %s)\n' "$label" "$TEST_TMP/check.log" >&2
    # All input here is disposable test data, not user configuration.
    while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$TEST_TMP/check.log"
    exit 1
  fi
  printf 'ok - real Xray accepts %s\n' "$label"
}

for method in aes-128-gcm aes-256-gcm chacha20-ietf-poly1305; do
  check_link "SS $method" "ss://$method:disposable-password@proxy.example.com:8388"
done
check_link 'SS Base64URL userinfo' 'ss://YWVzLTEyOC1nY206ZGlzcG9zYWJsZS1wYXNzd29yZA@proxy.example.com:8388'
check_link 'SOCKS5 anonymous' 'socks5://proxy.example.com:1080'
check_link 'SOCKS5 authenticated IPv6' 'socks5://test:pass%3Aword@[::1]:1080'
uuid=123e4567-e89b-12d3-a456-426614174000
check_link 'VLESS Reality TCP' "vless://$uuid@proxy.example.com:443?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=$public_key&sid=0123456789abcdef&spx=%2F"
check_link 'VLESS TLS TCP' "vless://$uuid@proxy.example.com:443?encryption=none&type=tcp&security=tls&sni=proxy.example.com"
check_link 'VLESS TLS WS' "vless://$uuid@proxy.example.com:443?encryption=none&type=ws&security=tls&sni=proxy.example.com&host=proxy.example.com&path=%2Fproxy"
check_link 'VLESS TLS gRPC' "vless://$uuid@proxy.example.com:443?encryption=none&type=grpc&security=tls&sni=proxy.example.com&serviceName=proxy"

check_link 'VLESS TLS TCP Vision' "vless://$uuid@proxy.example.com:443?type=tcp&security=tls&flow=xtls-rprx-vision&fp=chrome&sni=proxy.example.com&alpn=h2%2Chttp%2F1.1"
check_link 'VLESS TLS gRPC multi' "vless://$uuid@proxy.example.com:443?type=grpc&security=tls&sni=proxy.example.com&serviceName=proxy&mode=multi&alpn=h2"

printf '%s\n' '{"mode":"direct"}' | prepare_outbound_assignment "$TEST_TMP/node.json" "$TEST_TMP/direct.json" users test-user
render_config "$TEST_TMP/direct.json" "$TEST_TMP/config.json"
"$CORE" run -test -config "$TEST_TMP/config.json" > "$TEST_TMP/check.log" 2>&1
printf 'ok - real Xray accepts explicit user direct override\n'
