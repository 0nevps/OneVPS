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
jq '.nodes += .nodes' "$SING_NODES" > "$work/two.json"
reject sing_render "$work/two.json" "$work/reject.json"
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
