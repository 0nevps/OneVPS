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
ACME_UNIT_DIR="$TMP/units"
XRAY_DIR="$TMP/xray"
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
(
  mkdir -p "$ACME_CERT_DIR/example.com/current"
  reject 'unmanaged current path rejected' acme_deploy example.com
  shopt -s nullglob; versions=("$ACME_CERT_DIR/example.com/"cert.*)
  check 'rejected path leaves no temporary certificate directories' test "${#versions[@]}" = 0
  rmdir "$ACME_CERT_DIR/example.com/current"
)
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
cp "$XRAY_NODES" "$TMP/good-metadata"
printf 'invalid json\n' > "$XRAY_NODES"
reject 'unreadable metadata blocks renewal' acme_deploy example.com
check 'metadata failure preserves current certificate' test "$previous" = "$(readlink "$ACME_CERT_DIR/example.com/current")"
cp "$TMP/good-metadata" "$XRAY_NODES"
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
validate_xray_config() { ! flock -n "${XRAY_DIR}.lock" -c true; }
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
ADAPTED_CONFIG='{}'
caddy() {
  [[ "$1" == adapt ]] || return 1
  local probe
  probe=$(awk '/^onevps-listener-.*\.invalid \{/ {print $1}') || return 1
  jq --arg probe "$probe" '.apps.http.servers.web.listen=[":443"] |
    .apps.http.servers.web.routes += [{match:[{host:[$probe]}]}]' <<<"$ADAPTED_CONFIG"
}
printf ':80 {\n respond "existing"\n}\n' > "$CADDYFILE"
(
  caddy_present() { return 0; }
  systemctl() {
    case "$1" in enable) return "$enable_status" ;; start) return "$start_status" ;; is-active) return "$active_status" ;; *) return 1 ;; esac
  }
  enable_status=1; start_status=0; active_status=0
  reject 'Caddy enable failure stops setup' ensure_caddy
  enable_status=0; start_status=1; active_status=1
  reject 'Caddy start failure stops setup' ensure_caddy
  start_status=0
  reject 'inactive Caddy after start stops setup' ensure_caddy
)
(
  CADDYFILE="$TMP/menu-Caddyfile"; printf ':80 {\n respond 200\n}\n' > "$CADDYFILE"
  ask() { printf '%s\n' site.example.com; }; ensure_deps() { :; }; flock() { :; }
  ensure_caddy() { touch "$TMP/caddy-prepared"; }; ss() { printf '%s' "${SOCKETS:-}"; }
  systemctl() { case "$1" in show) echo 123 ;; is-active) return "${active_status:-0}" ;; *) return 1 ;; esac; }
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
  active_status=1; reject 'existing site with inactive Caddy cannot report success' setup_static_site; active_status=0
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
ADAPTED_CONFIG='{"apps":{"http":{"servers":{"web":{"routes":[{"match":[{"host":["external.example.com","*.wild.example.com"]}]}]}}}}}'
reject 'unknown site not overwritten' caddy_domain_ensure external.example.com "$CADDYFILE"
reject 'matching wildcard site not shadowed' caddy_domain_ensure one.wild.example.com "$CADDYFILE"
check 'external site is untouched' cmp "$CADDYFILE" "$TMP/before-domain-failure"
(
  cat() { if (($# == 0)); then printf '# partial site block\n'; return 1; fi; command cat "$@"; }
  caddy_reload() { touch "$TMP/unexpected-site-reload"; }
  reject 'partial site write fails before reload' caddy_domain_ensure write.example.org "$CADDYFILE" static
  check 'partial site write restores file' cmp "$CADDYFILE" "$TMP/before-domain-failure"
  reject 'partial site write never reloaded' test -e "$TMP/unexpected-site-reload"
  reject 'partial site not enrolled' test -e "$CADDY_STATE/sites/write.example.org.json"
)
(
  caddy() { return 1; }
  reject 'failed Caddy adaptation stops setup' caddy_domain_ensure inspect.example.com "$CADDYFILE" static
  check 'unreadable routes leave file intact' cmp "$CADDYFILE" "$TMP/before-domain-failure"
)
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
  cp "$CADDY_SYNC_RUNNER" "$TMP/working-runner"
  ONEVPS_SCRIPT_PATH="$TMP/incomplete-script"
  : > "$ONEVPS_SCRIPT_PATH"
  reject 'empty source cannot replace sync runner' caddy_sync_install
  sed '$d' "$ROOT_DIR/onevps.sh" > "$ONEVPS_SCRIPT_PATH"
  reject 'syntactically valid truncated source rejected' caddy_sync_install
  exec 7< <(cat "$ROOT_DIR/onevps.sh"); ONEVPS_SCRIPT_PATH=/dev/fd/7
  reject 'pipe cannot replace sync runner' caddy_sync_install
  check 'working runner preserved' cmp "$TMP/working-runner" "$CADDY_SYNC_RUNNER"
)
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
    caddy() { "$CADDY_TEST_BIN" "$@"; }
    (
      confirm() { return 0; }
      mkdir "$TMP/import-test"
      printf 'import child.caddy\n' > "$TMP/import-test/Caddyfile"
      printf 'import.example.org {\n respond ok\n}\n' > "$TMP/import-test/child.caddy"
      check 'reserve HY2 UDP port with relative Caddy imports' caddy_tcp_https "$TMP/import-test/Caddyfile"
      caddy adapt --adapter caddyfile --config "$TMP/import-test/Caddyfile" | jq -e \
        'any(.apps.http.servers[]; .protocols==["h1","h2"] and any(.routes[].match[]?.host[]?; .=="import.example.org"))' >/dev/null
    )
    CADDYFILE="$TMP/https-Caddyfile"
    port=$(python3 -c 'import socket; sock=socket.socket(); sock.bind(("127.0.0.1",0)); print(sock.getsockname()[1])')
    printf '{\n admin off\n auto_https disable_redirects\n https_port %s\n}\n' "$port" > "$CADDYFILE"
    (
      fixture="$TMP/domain-match-Caddyfile"
      printf '{\n https_port 4443\n default_bind 127.0.0.1\n}\nalt.example.com:8443 {\n respond ok\n}\naddr.example.com:4443 {\n bind 127.0.0.2\n respond ok\n}\n' > "$fixture"
      check 'same host on different port can coexist' caddy_domain_ensure alt.example.com "$fixture" static
      check 'disjoint bind addresses can coexist' caddy_domain_ensure addr.example.com "$fixture" static
      printf '# live.example.com\nimport imported-sites\n' > "$fixture"
      printf 'sub.live.example.com, *.private.example.com {\n respond "live.example.com"\n}\n' > "$TMP/imported-sites"
      reject 'imported exact site name blocks setup' caddy_domain_ensure sub.live.example.com "$fixture" static
      reject 'imported wildcard blocks matching name' caddy_domain_ensure app.private.example.com "$fixture" static
      check 'wildcard does not match multiple labels' caddy_domain_ensure deep.app.private.example.com "$fixture" static
      CADDY_STATE="$TMP/domain-match-state"; caddy_state_init static
      check 'comment, body and subdomain do not reserve parent' caddy_domain_ensure live.example.com "$fixture" static
    )
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
