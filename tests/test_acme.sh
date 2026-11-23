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
(
  CADDYFILE="$TMP/menu-Caddyfile"; printf ':80 {\n respond 200\n}\n' > "$CADDYFILE"
  ask() { printf '%s\n' site.example.com; }; ensure_deps() { :; }; flock() { :; }
  ensure_caddy() { touch "$TMP/caddy-prepared"; }; ss() { printf '%s' "${SOCKETS:-}"; }
  systemctl() { [[ "$1" == show ]] && printf '123\n'; }
  XRAY_NODES="$TMP/site-nodes.json"
  printf '{"nodes":[{"type":"vless-reality","enabled":true,"port":443}]}' > "$XRAY_NODES"
  reject 'Reality reservation stops site setup' setup_static_site
  rm "$XRAY_NODES"
  SOCKETS='LISTEN 0 128 *:443 *:* users:(("xray",pid=456,fd=7))'
  reject 'foreign TCP listener stops site setup' setup_static_site
  reject 'conflicts checked before Caddy setup' test -e "$TMP/caddy-prepared"
  SOCKETS='LISTEN 0 128 *:443 *:* users:(("caddy",pid=123,fd=7))'
  check 'static page needs no Xray installation' setup_static_site
  check 'static site metadata kept outside HY2 sync' test -f "$CADDY_STATE/sites/site.example.com.json"
  reject 'static-only certificate not exported' test -f "$CADDY_STATE/domains/site.example.com.json"
  printf 'my custom 403\n' > "$TMP/sites/site.example.com/index.html"
  check 'repeat static setup' setup_static_site
  check 'custom content retained' grep -qx 'my custom 403' "$TMP/sites/site.example.com/index.html"
  check 'HY2 can reuse static domain' caddy_domain_ensure site.example.com "$CADDYFILE"
  check 'explicit certificate request enrolls site for sync' test -f "$CADDY_STATE/domains/site.example.com.json"
  check 'single shared site definition' test "$(grep -cx 'site.example.com {' "$CADDYFILE")" = 1
)
check 'HY2-first domain created' caddy_domain_ensure example.com "$CADDYFILE"
check 'domain error page generated' test -s "$TMP/sites/example.com/index.html"
check 'domain-specific page root' grep -qF "root * $TMP/sites/example.com" "$CADDYFILE"
check 'ordinary requests raise 403' grep -q 'error 403' "$CADDYFILE"
check 'error handler serves index internally' grep -q 'rewrite \* /index.html' "$CADDYFILE"
mkdir -p "$TMP/sites/other.example.com"
printf 'custom forbidden page\n' > "$TMP/sites/other.example.com/index.html"
cp "$TMP/sites/other.example.com/index.html" "$TMP/custom-index"
check 'reuse managed certificate domain' caddy_domain_ensure example.com "$CADDYFILE"
check 'only one domain site' test "$(grep -c '^example.com {' "$CADDYFILE")" = 1
reject 'new domain has no proxy route import' grep -q 'import .*routes/' "$CADDYFILE"
check 'second certificate domain created' caddy_domain_ensure other.example.com "$CADDYFILE"
check 'existing custom index preserved' cmp "$TMP/custom-index" "$TMP/sites/other.example.com/index.html"
printf '\nexternal.example.com {\n respond 200\n}\n' >> "$CADDYFILE"
cp "$CADDYFILE" "$TMP/before-domain-failure"
reject 'unknown site not overwritten' caddy_domain_ensure external.example.com "$CADDYFILE"
check 'external site is untouched' cmp "$CADDYFILE" "$TMP/before-domain-failure"
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
  reject 'setup reload failure' prepare_caddy_for_certificates
  check 'setup restores original Caddyfile' cmp "$CADDYFILE" "$TMP/setup-original"
  check 'setup stops newly started Caddy after failure' grep -qx 'stop caddy' "$TMP/setup-services"
  caddy_reload() { return 0; }
  caddy_sync_install() { return 1; }
  reject 'sync install failure rolls back setup' prepare_caddy_for_certificates
  check 'sync failure restores original configuration' cmp "$CADDYFILE" "$TMP/setup-original"
  caddy_sync_install() { return 0; }
  check 'new deployment setup succeeds' prepare_caddy_for_certificates
  check 'setup is repeatable' prepare_caddy_for_certificates
)

if [[ -n ${CADDY_TEST_BIN:-} ]]; then
  (
    CADDYFILE="$TMP/https-Caddyfile"
    port=$(python3 -c 'import socket; sock=socket.socket(); sock.bind(("127.0.0.1",0)); print(sock.getsockname()[1])')
    printf '{\n admin off\n auto_https disable_redirects\n https_port %s\n}\n' "$port" > "$CADDYFILE"
    check 'generate real static site' caddy_domain_ensure live.example.com "$CADDYFILE" static
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=live.example.com \
      -addext subjectAltName=DNS:live.example.com -keyout "$TMP/live.key" -out "$TMP/live.crt" >/dev/null 2>&1
    awk -v dir="$TMP" '{print} /^live\.example\.com \{/ {print "    bind 127.0.0.1\n    tls " dir "/live.crt " dir "/live.key"}' \
      "$CADDYFILE" > "$TMP/loopback-Caddyfile"
    export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
    "$CADDY_TEST_BIN" run --adapter caddyfile --config "$TMP/loopback-Caddyfile" > "$TMP/caddy.log" 2>&1 & pid=$!
    trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
    fetch_site() {
      curl -sS --noproxy '*' --max-time 2 --cacert "$TMP/live.crt" --resolve "live.example.com:$port:127.0.0.1" \
        -o "$TMP/body" -w '%{http_code}' "https://live.example.com:$port/"
    }
    status=''
    for ((attempt=0; attempt<50; attempt++)); do
      if status=$(fetch_site 2>/dev/null); then break; fi
      sleep 0.1
    done
    check 'HTTPS returns actual HTTP 403' test "$status" = 403
    check 'HTTPS serves the existing page template' cmp "$TMP/body" "$TMP/sites/live.example.com/index.html"
    printf 'my custom page\n' > "$TMP/sites/live.example.com/index.html"
    check 'custom page still returns HTTP 403' test "$(fetch_site)" = 403
    check 'HTTPS serves customized contents' cmp "$TMP/body" "$TMP/sites/live.example.com/index.html"
  )
fi
