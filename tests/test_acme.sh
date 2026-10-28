#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../onevps.sh
source "$ROOT_DIR/onevps.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CADDY_STATE="$TMP/caddy-state"
ACME_CERT_DIR="$TMP/certs"
# shellcheck disable=SC2034
# shellcheck disable=SC2034
ACME_UNIT_DIR="$TMP/units"
XRAY_NODES="$TMP/nodes.json"
XRAY_CONF="$TMP/xray.json"
mkdir -p "$CADDY_STATE/staging/example.com" "$ACME_UNIT_DIR"
touch "$CADDY_STATE/.onevps-owned"
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
cp "$TMP/cert.pem" "$CADDY_STATE/staging/example.com/fullchain.pem"
cp "$TMP/key.pem" "$CADDY_STATE/staging/example.com/key.pem"
check 'validated pair deployment' acme_deploy example.com
check 'fullchain deployed' cmp "$TMP/cert.pem" "$ACME_CERT_DIR/example.com/current/fullchain.pem"
previous=$(readlink "$ACME_CERT_DIR/example.com/current")
check 'renewal skip still retries deployment' acme_deploy example.com
check 'unchanged certificate not switched' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
jq -n --arg cert "$ACME_CERT_DIR/example.com/current/fullchain.pem" \
  '{nodes:[{enabled:true,tls_cert:$cert}]}' > "$XRAY_NODES"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3 -subj /CN=example.com -addext subjectAltName=DNS:example.com >/dev/null 2>&1
cp "$TMP/cert.pem" "$CADDY_STATE/staging/example.com/fullchain.pem"
cp "$TMP/key.pem" "$CADDY_STATE/staging/example.com/key.pem"
restarts=0
systemctl() {
  if [[ "$1" == restart ]]; then restarts=$((restarts+1)); (( restarts > 1 )); else return 0; fi
}
reject 'restart failure rolls certificate back' acme_deploy example.com
check 'previous pair restored atomically' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
systemctl() { return 0; }
validate_xray_config() { return 1; }
reject 'invalid Xray config rolls certificate back' acme_deploy example.com
check 'previous pair retained after validation failure' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
validate_xray_config() { return 0; }
check 'renewal deploys new pair' acme_deploy example.com
reject 'new certificate becomes current' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"

# The same Caddy-owned certificate transaction must target only the selected core.
SING_DIR="$TMP/sing"
SING_BIN="$TMP/sing-box"
SING_NODES="$SING_DIR/onevps-nodes.json"
SING_CONF="$SING_DIR/config.json"
mkdir -p "$SING_DIR"
printf '#!/usr/bin/env bash\n' > "$SING_BIN"
chmod 755 "$SING_BIN"
touch "$SING_DIR/.onevps-managed"
jq -n --arg cert "$ACME_CERT_DIR/example.com/current/fullchain.pem" \
  '{nodes:[{type:"hysteria2",enabled:true,tls_cert:$cert}]}' > "$SING_NODES"
printf '{}\n' > "$SING_CONF"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 4 -subj /CN=example.com -addext subjectAltName=DNS:example.com >/dev/null 2>&1
cp "$TMP/cert.pem" "$CADDY_STATE/staging/example.com/fullchain.pem"
cp "$TMP/key.pem" "$CADDY_STATE/staging/example.com/key.pem"
sing_check() { return 0; }
validate_xray_config() { return 1; }
systemctl() { printf '%s\n' "$*" >> "$TMP/sing-services"; return 0; }
check 'renewal validates sing-box instead of Xray' acme_deploy example.com
check 'renewal restarts only sing-box' grep -qx 'restart sing-box' "$TMP/sing-services"
reject 'renewal does not restart Xray' grep -qx 'restart xray' "$TMP/sing-services"
previous=$(readlink "$ACME_CERT_DIR/example.com/current")
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 5 -subj /CN=example.com -addext subjectAltName=DNS:example.com >/dev/null 2>&1
cp "$TMP/cert.pem" "$CADDY_STATE/staging/example.com/fullchain.pem"
cp "$TMP/key.pem" "$CADDY_STATE/staging/example.com/key.pem"
restarts=0
systemctl() {
  if [[ "$1" == restart ]]; then restarts=$((restarts+1)); (( restarts > 1 )) && return 0; return 1; fi
  return 0
}
reject 'sing-box restart failure rolls certificate back' acme_deploy example.com
check 'sing-box rollback retains previous certificate' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
systemctl() { return 0; }
sing_check() { return 1; }
reject 'sing-box check failure rolls certificate back' acme_deploy example.com
check 'sing-box check failure retains previous certificate' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
sing_check() { return 0; }
check 'sing-box renewal commits valid certificate' acme_deploy example.com
reject 'sing-box renewal changes current certificate' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
SING_DIR="$TMP/no-sing"

# Domain ownership is independent of node order; all services are mocked.
CADDY_STATE="$TMP/caddy-state"
CADDY_SYNC_RUNNER="$TMP/caddy-sync.sh"
CADDYFILE="$TMP/Caddyfile"
mkdir -p "$TMP/storage"
check 'initialize owned Caddy state' caddy_state_init
caddy_storage_root() { echo "$TMP/storage"; }
caddy_site_root() { echo "$TMP/sites/$1"; }
caddy_reload() { return "${RELOAD_STATUS:-0}"; }
printf ':80 {\n respond "existing"\n}\n' > "$CADDYFILE"
check 'HY2-first domain created' caddy_domain_ensure example.com "$CADDYFILE"
check 'domain error page generated' test -s "$TMP/sites/example.com/index.html"
check 'domain-specific page root' grep -qF "root * $TMP/sites/example.com" "$CADDYFILE"
check 'ordinary requests raise 403' grep -q 'error 403' "$CADDYFILE"
check 'error handler serves index internally' grep -q 'rewrite \* /index.html' "$CADDYFILE"
mkdir -p "$TMP/sites/other.example.com"
printf 'custom forbidden page\n' > "$TMP/sites/other.example.com/index.html"
cp "$TMP/sites/other.example.com/index.html" "$TMP/custom-index"
check 'Trojan reuses HY2 domain' caddy_add_route abcd example.com /secret 12345 "$CADDYFILE"
check 'only one domain site' test "$(grep -c '^example.com {' "$CADDYFILE")" = 1
check 'Trojan path fragment exists' grep -q 'reverse_proxy' "$CADDY_STATE/routes/example.com/abcd.caddy"
caddy_remove_route abcd "$CADDYFILE"
check 'deleting Trojan preserves certificate site' grep -q '^example.com {' "$CADDYFILE"
reject 'deleting Trojan removes only fragment' test -f "$CADDY_STATE/routes/example.com/abcd.caddy"
check 'Trojan-first domain created' caddy_add_route bcde other.example.com /other 12346 "$CADDYFILE"
check 'existing custom index preserved' cmp "$TMP/custom-index" "$TMP/sites/other.example.com/index.html"
check 'HY2 reuses Trojan domain' caddy_domain_ensure other.example.com "$CADDYFILE"
check 'Trojan-first site remains unique' test "$(grep -c '^other.example.com {' "$CADDYFILE")" = 1
printf '\nexternal.example.com {\n respond 200\n}\n' >> "$CADDYFILE"
reject 'unknown site not overwritten' caddy_domain_ensure external.example.com "$CADDYFILE"
cp "$CADDYFILE" "$TMP/before-domain-failure"
RELOAD_STATUS=1
reject 'failed domain reload' caddy_domain_ensure failed.example.com "$CADDYFILE"
check 'failed domain reload restores file' cmp "$CADDYFILE" "$TMP/before-domain-failure"
reject 'failed domain not recorded' test -f "$CADDY_STATE/domains/failed.example.com.json"
RELOAD_STATUS=0
mkdir -p "$TMP/storage/certificates/test-issuer/example.com"
cp "$TMP/cert.pem" "$TMP/storage/certificates/test-issuer/example.com/example.com.crt"
cp "$TMP/key.pem" "$TMP/storage/certificates/test-issuer/example.com/example.com.key"
check 'deploy from configured Caddy storage' caddy_sync_domain example.com
reject 'missing Caddy certificate fails safely' caddy_sync_domain other.example.com
check 'install sync timer' caddy_sync_install
check 'timer syncs every minute' grep -q '^OnUnitActiveSec=1min' "$ACME_UNIT_DIR/onevps-caddy-sync.timer"
check 'runner dispatches Caddy sync' grep -q -- '--caddy-sync' "$CADDY_SYNC_RUNNER"
check 'runner parses' bash -n "$CADDY_SYNC_RUNNER"
(
  CADDY_STATE="$TMP/setup-state"
  CADDYFILE="$TMP/setup-Caddyfile"
  printf ':80 {\n respond 200\n}\n' > "$CADDYFILE"
  cp "$CADDYFILE" "$TMP/setup-original"
  flock() { return 0; }
  systemctl() {
    printf '%s\n' "$*" >> "$TMP/setup-services"
    case "$1" in is-active|is-enabled) return 1;; esac
    return 0
  }
  ensure_caddy() { return 0; }
  caddy_tcp_https() { echo '# changed' >> "$1"; return 0; }
  caddy_reload() { return 1; }
  reject 'setup reload failure' prepare_caddy_for_trojan
  check 'setup restores original Caddyfile' cmp "$CADDYFILE" "$TMP/setup-original"
  check 'setup stops newly started Caddy after failure' grep -qx 'stop caddy' "$TMP/setup-services"
  caddy_reload() { return 0; }
  caddy_sync_install() { return 1; }
  reject 'sync install failure rolls back setup' prepare_caddy_for_trojan
  check 'sync failure restores original configuration' cmp "$CADDYFILE" "$TMP/setup-original"
  caddy_sync_install() { return 0; }
  check 'new deployment setup succeeds' prepare_caddy_for_trojan
  check 'setup is repeatable' prepare_caddy_for_trojan
  reject 'setup never manages old ACME timer' grep -q 'onevps-acme' "$TMP/setup-services"
  printf '# OneVPS-trojan:abcd BEGIN\nold.example.com {\n respond 200\n}\n# OneVPS-trojan:abcd END\n' > "$CADDYFILE"
  cp "$CADDYFILE" "$TMP/old-untouched"
  caddy_remove_route abcd "$CADDYFILE"
  check 'route removal does not rewrite old resources' cmp "$CADDYFILE" "$TMP/old-untouched"
  reject 'existing old site is not adopted' caddy_domain_ensure old.example.com "$CADDYFILE"
)
