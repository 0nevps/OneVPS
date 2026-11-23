#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} != --isolated ]]; then
  [[ $(uname -s) == Linux && $EUID == 0 && -x ${XRAY_TEST_BIN:?set XRAY_TEST_BIN} ]] || exit 1
  exec unshare --net --mount --propagation private bash "$0" --isolated
fi
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || exit 1
# shellcheck source=../onevps.sh
source "$root/onevps.sh"
work=$(mktemp -d)
client_ns="onevps-hop-test-$$"
cleanup() {
  if [[ -n ${server_pid:-} ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  ip netns del "$client_ns" || true
  rm -rf "$work"
}
ip netns add "$client_ns"
trap cleanup EXIT
ip link set lo up
ip link add ingress type veth peer name client0
ip link set client0 netns "$client_ns"
ip addr add 192.0.2.1/30 dev ingress
ip link set ingress up
ip -n "$client_ns" addr add 192.0.2.2/30 dev client0
ip -n "$client_ns" link set client0 up
ip -n "$client_ns" link set lo up

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost \
  -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
jq --arg work "$work" '{nodes:[.nodes[] | select(.type=="hysteria2") |
  .domain="localhost" | .port=24443 | .tls_cert=($work+"/cert.pem") | .tls_key=($work+"/key.pem") |
  .hopping={interface:"ingress",ports:"21001-21008"}]}' "$root/tests/fixtures/nodes.json" > "$work/nodes.json"
render_config "$work/nodes.json" "$work/production.json"
jq '.routing.rules=[] | .outbounds[0].settings.finalRules=[{action:"allow",ip:["127.0.0.1"]}]' \
  "$work/production.json" > "$work/server.json"
hy2_hop_plan "$work/nodes.json" > "$work/plan"
HY2_HOP_DIR="$work/managed"; HY2_HOP_UNIT="$work/hop.service"; export REALM_DIR="$work/realm"
systemctl() { :; }
hy2_hop_preflight "$work/plan"
hy2_hop_apply "$work/plan"
nft delete table ip onevps_hy2_hop
nft -f "$HY2_HOP_DIR/rules.nft"
"$XRAY_TEST_BIN" run -config "$work/server.json" > "$work/server.log" 2>&1 & server_pid=$!
if ! python3 "$root/tests/hy2_hopping_runtime.py" "$client_ns" "$XRAY_TEST_BIN" "$work"; then
  cat "$work/server.log" "$work/client.log" >&2; exit 1
fi
hy2_hop_apply /dev/null
[[ ! -e "$HY2_HOP_UNIT" && ! -d "$HY2_HOP_DIR" && -z $(nft list tables) ]]
