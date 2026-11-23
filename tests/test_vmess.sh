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
json=$(jq -nc --arg uuid "$UUID" '{v:"2",ps:"VMess upstream",add:"proxy.example.com",port:"443",id:$uuid,
  aid:"0",scy:"auto",net:"ws",type:"none",host:"proxy.example.com",path:"/vmess-test",tls:"tls",sni:"proxy.example.com"}')
link=$(encode <<<"$json")
check parse_outbound_link <<<"$link" > "$WORK/outbound.json"
check jq -e --arg uuid "$UUID" '.protocol == "vmess" and .uuid == $uuid and .port == 443 and .method == "auto" and .params.path == "/vmess-test"' "$WORK/outbound.json"
check build_proxy_outbound vmess-test < "$WORK/outbound.json" > "$WORK/proxy.json"
check jq -e '.protocol == "vmess" and .streamSettings.tlsSettings.allowInsecure == false and .settings.vnext[0].users[0].security == "auto"' "$WORK/proxy.json"
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
check prepare_outbound_assignment "$ROOT_DIR/tests/fixtures/nodes.json" "$WORK/assigned.json" b2c3d4e5 selected '["default"]' < "$WORK/outbound.json"
check render_config "$WORK/assigned.json" "$WORK/assigned-config.json"
check jq -e '.outbounds[2].protocol == "vmess" and .routing.rules[2].user == ["hy2-b2c3d4e5@onevps"]' "$WORK/assigned-config.json"
printf 'ok - VMess upstream import, validation and per-user routing\n'
