#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CORE="${SINGBOX_TEST_BIN:-}"
[[ -n "$CORE" && -x "$CORE" ]] || {
  printf 'SINGBOX_TEST_BIN must name a real executable sing-box binary\n' >&2
  exit 1
}
# shellcheck source=../onevps.sh
source "$ROOT_DIR/onevps.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

version_output=$("$CORE" version)
printf '%s\n' "$version_output"
[[ "$version_output" == "sing-box version ${SINGBOX_VERSION#v}"$'\n'* ]] || {
  printf 'Expected sing-box %s\n' "$SINGBOX_VERSION" >&2; exit 1;
}
"$CORE" generate reality-keypair > "$TEST_TMP/keys"
private_key=''; public_key=''
while IFS= read -r line; do
  case "$line" in
    PrivateKey:*) private_key=${line#*: } ;;
    PublicKey:*) public_key=${line#*: } ;;
  esac
done < "$TEST_TMP/keys"
[[ -n "$private_key" && -n "$public_key" ]] || { printf 'unrecognized Reality keypair output\n' >&2; exit 1; }
printf '%s\n' "$private_key" "$public_key" | jq -Rn '[inputs]' > "$TEST_TMP/key-values.json"
jq --slurpfile keys "$TEST_TMP/key-values.json" '
  .schema_version = 1 |
  .nodes[1].ws_path = "/onevps-runtime" |
  .nodes |= map(if .type == "vless-reality" then
    .reality_private_key = $keys[0][0] | .reality_public_key = $keys[0][1]
  else . end) |
  .nodes[0].users = [{id:"alice",name:"Alice",uuid:"123e4567-e89b-12d3-a456-426614174011"}] |
  .nodes[1].users = [{id:"alice",name:"Alice",password:"disposable-local-password",outbound:{mode:"direct"}}]
' "$ROOT_DIR/tests/fixtures/nodes.json" > "$TEST_TMP/base.json"

check_link() {
  local label="$1" link="$2"
  printf '%s\n' "$link" | parse_outbound_link > "$TEST_TMP/outbound.json"
  prepare_outbound_assignment "$TEST_TMP/base.json" "$TEST_TMP/node.json" a1b2c3d4 selected '["default","alice"]' < "$TEST_TMP/outbound.json"
  render_config "$TEST_TMP/node.json" "$TEST_TMP/config.json"
  if ! "$CORE" check -c "$TEST_TMP/config.json" > "$TEST_TMP/check.log" 2>&1; then
    printf 'not ok - real sing-box rejected %s\n' "$label" >&2
    # Only disposable fixture credentials occur in this log.
    while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$TEST_TMP/check.log"
    exit 1
  fi
  printf 'ok - real sing-box accepts %s\n' "$label"
}

for method in aes-128-gcm aes-256-gcm chacha20-ietf-poly1305; do
  check_link "SS $method" "ss://$method:disposable-password@proxy.example.com:8388"
done
check_link 'SS Base64URL userinfo' 'ss://YWVzLTEyOC1nY206ZGlzcG9zYWJsZS1wYXNzd29yZA@proxy.example.com:8388'
check_link 'SOCKS5 anonymous' 'socks5://proxy.example.com:1080'
check_link 'SOCKS5 authenticated IPv6' 'socks5://test:pass%3Aword@[::1]:1080'
uuid=123e4567-e89b-12d3-a456-426614174000
check_link 'VLESS Reality TCP' "vless://$uuid@proxy.example.com:443?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=$public_key&sid=0123456789abcdef"
check_link 'VLESS TLS TCP' "vless://$uuid@proxy.example.com:443?encryption=none&type=tcp&security=tls&sni=proxy.example.com"
check_link 'VLESS TLS WS' "vless://$uuid@proxy.example.com:443?encryption=none&type=ws&security=tls&sni=proxy.example.com&host=proxy.example.com&path=%2Fproxy"
check_link 'VLESS TLS gRPC' "vless://$uuid@proxy.example.com:443?encryption=none&type=grpc&security=tls&sni=proxy.example.com&serviceName=proxy&mode=gun"
check_link 'VLESS TLS TCP Vision' "vless://$uuid@proxy.example.com:443?type=tcp&security=tls&flow=xtls-rprx-vision&fp=chrome&sni=proxy.example.com&alpn=h2%2Chttp%2F1.1"
for link in \
  "vless://$uuid@proxy.example.com:443?security=tls&type=grpc&mode=multi" \
  "vless://$uuid@proxy.example.com:443?security=reality&sni=www.example.com&fp=chrome&pbk=$public_key&sid=0123456789abcdef&spx=%2F"; do
  if printf '%s\n' "$link" | parse_outbound_link >/dev/null; then
    printf 'not ok - Xray-only parameter accepted\n' >&2; exit 1
  fi
done
printf 'ok - unsupported Xray parameters rejected\n'
printf '%s\n' '{"mode":"direct"}' | prepare_outbound_assignment "$TEST_TMP/node.json" "$TEST_TMP/direct.json" a1b2c3d4
render_config "$TEST_TMP/direct.json" "$TEST_TMP/config.json"
"$CORE" check -c "$TEST_TMP/config.json"
printf '%s\n' '"inherit"' | prepare_outbound_assignment "$TEST_TMP/direct.json" "$TEST_TMP/reset.json" a1b2c3d4
render_config "$TEST_TMP/reset.json" "$TEST_TMP/config.json"
"$CORE" check -c "$TEST_TMP/config.json"
printf 'ok - explicit direct and inherited default validate\n'
printf '%s\n' '{"mode":"proxy","protocol":"socks","server":"127.0.0.1","port":1080}' |
  prepare_outbound_assignment "$TEST_TMP/base.json" "$TEST_TMP/runtime-nodes.json" b2c3d4e5
printf '%s\n' '{"mode":"direct"}' |
  prepare_outbound_assignment "$TEST_TMP/runtime-nodes.json" "$TEST_TMP/runtime-users.json" b2c3d4e5 selected '["alice"]'
render_config "$TEST_TMP/runtime-users.json" "$TEST_TMP/runtime-base.json"
python3 -I "$ROOT_DIR/tests/runtime_singbox.py" "$CORE" "$TEST_TMP/runtime-base.json" "$TEST_TMP"
