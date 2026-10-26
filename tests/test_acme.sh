#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../onevps.sh
source "$ROOT_DIR/onevps.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ACME_DIR="$TMP/acme"
ACME_CERT_DIR="$TMP/certs"
# shellcheck disable=SC2034
ACME_WEBROOT="$TMP/webroot"
# shellcheck disable=SC2034
ACME_RUNNER="$TMP/lib/runner.sh"
ACME_UNIT_DIR="$TMP/units"
XRAY_NODES="$TMP/nodes.json"
XRAY_CONF="$TMP/xray.json"
mkdir -p "$ACME_DIR/domains" "$ACME_DIR/staging/example.com" "$ACME_UNIT_DIR"
touch "$ACME_DIR/.onevps-owned"
printf '{"nodes":[]}' > "$XRAY_NODES"
printf '{}' > "$XRAY_CONF"
check() { local label="$1"; shift; "$@" || { echo "not ok - $label"; exit 1; }; echo "ok - $label"; }
reject() { local label="$1"; shift; if "$@"; then echo "not ok - $label"; exit 1; fi; echo "ok - $label"; }
check 'valid ACME domain' acme_domain_valid example.com
for domain in ../example.com -example.com example..com example.com. 'example.com;id' 'example.com/abc'; do
  reject 'unsafe domain rejected' acme_domain_valid "$domain"
done
# No host services, privileges, packages or network access in this suite.
chown() { :; }
systemctl() { printf '%s\n' "$*" >> "$TMP/systemctl"; return 0; }
open_port() { printf '%s\n' "$*" >> "$TMP/ports"; }
port_in_use() { return 1; }
socat() { :; }
validate_xray_config() { return 0; }
# Production uses GNU mv -T. Emulate only the symlink replacement on macOS.
if [[ $(uname -s) == Darwin ]]; then
  mv() {
    if [[ "$1" == -Tf ]]; then
      python3 -c 'import os,sys; os.replace(sys.argv[1],sys.argv[2])' "$2" "$3"
    else command mv "$@"; fi
  }
fi
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 2 -subj /CN=example.com -addext subjectAltName=DNS:example.com >/dev/null 2>&1
acme_exec() {
  printf '%s\n' "$*" >> "$TMP/commands"
  case "$1" in
    --issue|--renew) return "${ISSUE_STATUS:-0}" ;;
    --install-cert)
      cp "$TMP/cert.pem" "$ACME_DIR/staging/example.com/fullchain.pem"
      cp "$TMP/key.pem" "$ACME_DIR/staging/example.com/key.pem" ;;
    *) return 1 ;;
  esac
}
check 'standalone issuance and deployment' acme_process_domain example.com issue
check 'standalone selected' grep -q -- '--issue -d example.com --keylength ec-256 --standalone' "$TMP/commands"
reject 'no email requested or supplied' grep -qi email "$TMP/commands"
check 'fullchain deployed' cmp "$TMP/cert.pem" "$ACME_CERT_DIR/example.com/current/fullchain.pem"
previous=$(readlink "$ACME_CERT_DIR/example.com/current")
ISSUE_STATUS=2
check 'renewal skip still retries deployment' acme_process_domain example.com renew
check 'unchanged certificate not switched' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
ISSUE_STATUS=1
reject 'issuance failure stops deployment' acme_process_domain example.com issue
check 'old certificate survives issuance failure' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
ISSUE_STATUS=0
jq -n --arg cert "$ACME_CERT_DIR/example.com/current/fullchain.pem" \
  '{nodes:[{enabled:true,tls_cert:$cert}]}' > "$XRAY_NODES"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3 -subj /CN=example.com -addext subjectAltName=DNS:example.com >/dev/null 2>&1
restarts=0
systemctl() {
  if [[ "$1" == restart ]]; then restarts=$((restarts+1)); (( restarts > 1 )); else return 0; fi
}
reject 'restart failure rolls certificate back' acme_process_domain example.com renew
check 'previous pair restored atomically' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
systemctl() { return 0; }
validate_xray_config() { return 1; }
reject 'invalid Xray config rolls certificate back' acme_process_domain example.com renew
check 'previous pair retained after validation failure' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
validate_xray_config() { return 0; }
check 'renewal deploys new pair' acme_process_domain example.com renew
reject 'new certificate becomes current' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
CADDYFILE="$TMP/Caddyfile"
printf ':80 {\n respond "existing"\n}\n' > "$CADDYFILE"
caddy_reload() { return 0; }
port_in_use() { return 0; }
reject 'saved standalone does not silently change renewal mode' acme_challenge_mode example.com
printf '{"mode":"webroot","caddy_file":"%s"}' "$CADDYFILE" > "$ACME_DIR/domains/example.com.json"
check 'Caddy webroot route selected' test "$(acme_challenge_mode example.com)" = webroot
check 'HTTP-only challenge vhost' grep -q '^http://example.com {' "$CADDYFILE"
check 'existing Caddy content preserved' grep -q 'respond "existing"' "$CADDYFILE"
check 'Caddy route is idempotent' acme_caddy_route example.com "$CADDYFILE"
check 'only one managed block' test "$(grep -c 'BEGIN' "$CADDYFILE")" = 1
cp "$CADDYFILE" "$TMP/before"
caddy_reload() { return 1; }
reject 'failed Caddy reload' acme_caddy_route other.example.com "$CADDYFILE"
check 'Caddy file restored' cmp "$CADDYFILE" "$TMP/before"
caddy_reload() { return 0; }
reject 'existing domain not overwritten' acme_caddy_route existing "$CADDYFILE"
systemctl() { return 1; }
reject 'occupied port never stops unrelated service' acme_challenge_mode new.example.com
# ACME backend always pins Let's Encrypt and does not inherit user account state.
mkdir -p "$ACME_DIR/client"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' > "$ACME_DIR/client/acme.sh"
chmod +x "$ACME_DIR/client/acme.sh"
unset -f acme_exec
# Reload production definition only, preserving isolated paths and mocks.
eval "$(sed -n '/^acme_exec() {/,/^}/p' "$ROOT_DIR/onevps.sh")"
args=$(acme_exec --register-account)
[[ "$args" == *'--server letsencrypt'* && "$args" == *"--config-home $ACME_DIR/account"* && "$args" != *email* ]] || exit 1
echo 'ok - explicit CA and isolated account without email'
(
  ensure_deps() { :; }
  systemctl() { printf '%s\n' "$*" >> "$TMP/units-log"; }
  check 'isolated install writes runnable snapshot and timer' acme_install
  check 'runner is valid Bash' bash -n "$ACME_RUNNER"
  check 'timer is persistent' grep -q 'Persistent=true' "$ACME_UNIT_DIR/onevps-acme.timer"
  check 'timer enabled' grep -q 'enable --now onevps-acme.timer' "$TMP/units-log"
  check 'renewal runner bypasses interactive menu' grep -q -- '--acme-renew' "$ACME_UNIT_DIR/onevps-acme.service"
  ACME_DIR="$TMP/unmanaged"
  mkdir "$ACME_DIR"
  reject 'unmanaged ACME install is not overwritten' acme_install
)
# Categorized submenu dispatch and cancellation.
(
  printf '1\n2\n3\n4\n5\n0\n1\n2\n3\n0\n' > "$TMP/input"
  exec 3< "$TMP/input"
  ask() { local value; read -r value <&3; echo "$value"; }
  add_reality_node() { echo reality >> "$TMP/dispatch"; }
  add_trojan_node() { echo trojan >> "$TMP/dispatch"; }
  add_hysteria_node() { echo hy2 >> "$TMP/dispatch"; }
  manage_nodes() { echo manage >> "$TMP/dispatch"; }
  show_links() { echo links >> "$TMP/dispatch"; }
  restart_service() { echo restart >> "$TMP/dispatch"; }
  enable_bbr() { echo bbr >> "$TMP/dispatch"; }
  optimize_system() { echo tuning >> "$TMP/dispatch"; }
  node_menu >/dev/null; network_menu >/dev/null
  check 'categorized submenus dispatch all actions' test "$(cat "$TMP/dispatch")" = "$(printf '%s\n' reality trojan hy2 manage links restart bbr tuning)"
)
(
  systemctl() { return 0; }
  caddy_reload() { return 0; }
  confirm() { return 0; }
  printf 'external certificate\n' > "$TMP/external.pem"
  check 'uninstall only owned ACME resources' acme_uninstall
  reject 'owned account removed' test -e "$ACME_DIR"
  check 'external certificate kept' test -f "$TMP/external.pem"
  check 'existing website kept' grep -q 'respond "existing"' "$CADDYFILE"
  reject 'only marked challenge route removed' grep -q 'OneVPS-acme:' "$CADDYFILE"
)
