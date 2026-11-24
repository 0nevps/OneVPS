#!/usr/bin/env bash
#
# OneVPS - Xray node setup script
# Protocols:
#   - VLESS + TCP + REALITY + XTLS Vision + uTLS (standalone)
#   - Hysteria2 + QUIC + TLS (native Xray inbound)
#
set -euo pipefail
umask 077

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
XRAY_DIR=/usr/local/etc/xray
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=$XRAY_DIR/config.json
XRAY_NODES=$XRAY_DIR/onevps-nodes.json
XRAY_SERVICE=/etc/systemd/system/xray.service
XRAY_INSTALL_URL=https://github.com/XTLS/Xray-install/raw/main/install-release.sh
ONEVPS_UPDATE_URL=https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh
ONEVPS_SCRIPT_PATH=${BASH_SOURCE[0]}
BBR_CONF=/etc/sysctl.d/99-bbr.conf
REALITY_PROBE_ROUNDS=3
REALM_DIR=/usr/local/etc/onevps-realm
REALM_BIN=/usr/local/bin/onevps-realm
REALM_SERVICE=/etc/systemd/system/onevps-realm.service
REALM_VERSION=v2.9.6
HY2_MIN_VERSION=26.10.21
HY2_HOP_DIR=/etc/onevps-hy2-hop
HY2_HOP_UNIT=/etc/systemd/system/onevps-hy2-hop.service
ACME_CERT_DIR=/etc/onevps-certs
ACME_UNIT_DIR=/etc/systemd/system

REALITY_DESTS=(
  "www.cloudflare.com"
  "www.amazon.com"
  "www.paypal.com"
  "www.ebay.com"
  "www.microsoft.com"
  "www.apple.com"
  "www.samsung.com"
  "gateway.icloud.com"
  "www.lovelive-anime.jp"
  "www.wikipedia.org"
  "www.oracle.com"
  "www.netflix.com"
)

PKG=""
ARCH=""
PUBIP=""
CADDYFILE=""

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'; c_rst=$'\e[0m'
info() { printf '%s[*]%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Keep the command in the foreground so stdin, shell state and caller traps survive.
# Progress uses stderr only; command substitutions must still return clean data.
run_with_progress() {
  local label="$1" spinner="" status=0 started=$SECONDS owner
  shift
  printf '[*] %s...\n' "$label" >&2
  if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then
    owner=$(exec sh -c 'printf "%s" "$PPID"')
    (
      trap 'printf "\r\033[K" >&2' EXIT
      trap 'exit 0' TERM
      local frames='|/-\\' frame=0
      while kill -0 "$owner" 2>/dev/null; do
        printf '\r\033[K[%s] %s (%ds)' "${frames:frame%4:1}" "$label" "$((SECONDS - started))" >&2
        frame=$((frame + 1))
        command sleep 0.2
      done
    ) &
    spinner=$!
  fi
  "$@" || status=$?
  if [[ -n "$spinner" ]]; then
    kill "$spinner" 2>/dev/null || true
    wait "$spinner" 2>/dev/null || true
  fi
  if (( status == 0 )); then
    printf '[+] %s: done (%ds)\n' "$label" "$((SECONDS - started))" >&2
  else
    printf '[!] %s: failed (exit %d, %ds)\n' "$label" "$status" "$((SECONDS - started))" >&2
  fi
  return "$status"
}

# Curl reports real transfer progress when a terminal is available.
download_file() {
  if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then
    curl -fSL --progress-bar "$@"
  else
    run_with_progress 'Downloading file' curl -fsSL "$@"
  fi
}

confirm() {
  local q="$1" def="${2:-n}" ans
  local hint="[y/N]"; [[ "$def" == y ]] && hint="[Y/n]"
  read -rp "$q $hint " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

ask() {
  local q="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -rp "$q [$def]: " ans || true
    printf '%s\n' "${ans:-$def}"
  else
    read -rp "$q: " ans || true
    printf '%s\n' "$ans"
  fi
}

pause() { read -rp $'\nPress Enter to continue...' _ || true; }

# ----------------------------------------------------------------------------
# Basic helpers
# ----------------------------------------------------------------------------
is_valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

rand_uuid() {
  if [[ -x "$XRAY_BIN" ]]; then "$XRAY_BIN" uuid | tr 'A-Z' 'a-z'; return; fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; return; fi
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; return; fi
  python3 -c 'import uuid;print(uuid.uuid4())'
}

ask_uuid() {
  local input default
  default=$(rand_uuid) && is_valid_uuid "$default" || { err 'UUID generation failed'; return 1; }
  input=$(ask "UUID (Enter for random)" "$default")
  while ! is_valid_uuid "$input"; do
    warn "invalid UUID format (expected: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)" >&2
    input=$(ask "UUID (Enter for random)" "$default")
  done
  echo "$input"
}

rand_short_id() { openssl rand -hex 8; }

rand_password() { openssl rand -hex 16; }

rand_port() {
  local p
  while :; do
    p=$(( ( (RANDOM << 15) | RANDOM ) % 55535 + 10000 ))
    if port_taken_by_node "$p" tcp; then continue; else
      [[ $? == 1 ]] || return 1
    fi
    if port_in_use "$p" tcp; then continue; else
      [[ $? == 1 ]] || return 1
    fi
    echo "$p"; return
  done
}

pub_ip() {
  local addr="$PUBIP" url
  if [[ -n "$addr" ]] && realm_valid_host "$addr"; then printf '%s\n' "$addr"; return; fi
  for url in https://api.ipify.org https://ifconfig.me; do
    addr=$(run_with_progress 'Looking up public IPv4 address' curl -fsSL4 --max-time 8 "$url") || continue
    if [[ "$addr" =~ ^[0-9.]+$ ]] && realm_valid_host "$addr"; then printf '%s\n' "$addr"; return; fi
  done
  err 'Cannot determine a valid public IP for the Reality link'
  [[ -t 0 ]] || return 1
  while :; do
    read -rp 'Public IP or domain (Enter to skip link): ' addr || return 1
    [[ -n "$addr" ]] || return 1
    if realm_valid_host "$addr"; then printf '%s\n' "$addr"; return; fi
    err 'Enter a bare IP address or hostname, without a scheme or port'
  done
}

require_xray() {
  command -v "$XRAY_BIN" >/dev/null 2>&1 || die "run menu option [1] to install Xray first"
}

installed_version() {
  [[ -x "$XRAY_BIN" ]] || { echo ""; return; }
  "$XRAY_BIN" version 2>/dev/null | awk '/^Xray / && !seen {print $2; seen=1}'
}

urlenc() { printf '%s' "$1" | jq -Rrs '@uri'; }

normalize_domain() {
  local d="$1"
  d="${d#https://}"; d="${d#http://}"
  d="${d%%/*}"; d="${d%%:*}"
  printf '%s\n' "$d" | tr '[:upper:]' '[:lower:]'
}

is_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" == *.* && "$1" != .* && "$1" != *..* ]]
}

gen_x25519() {
  require_xray
  local kp pk pubk
  kp=$("$XRAY_BIN" x25519) || { err 'Xray key generation failed'; return 1; }
  pk=$(awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$kp")
  pubk=$(awk -F': ' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$kp")
  [[ -n "$pk" && -n "$pubk" ]] || { err 'failed to parse Xray x25519 keypair'; return 1; }
  printf '%s %s\n' "$pk" "$pubk"
}

# ----------------------------------------------------------------------------
# [1] Environment check
# ----------------------------------------------------------------------------
check_env() {
  [[ $EUID -eq 0 ]] || die "must run as root (sudo bash $0)"
  command -v systemctl >/dev/null 2>&1 || die "systemd not found; this script relies on systemd to manage Xray"
  id nobody >/dev/null 2>&1 || die "system user 'nobody' not found"

  case "$(uname -m)" in
    x86_64|amd64)        ARCH=amd64 ;;
    aarch64|arm64)       ARCH=arm64 ;;
    armv7l|armv7|armhf)  ARCH=armv7 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac

  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG=yum
  elif command -v zypper  >/dev/null 2>&1; then PKG=zypper
  else die "unrecognized package manager (apt/dnf/yum/zypper supported)"; fi

  ok "environment OK - arch:$ARCH  pkg:$PKG  systemd:yes"
}

pkg_install() {
  case "$PKG" in
    apt)
      DEBIAN_FRONTEND=noninteractive run_with_progress 'Refreshing apt package index' apt-get update -qq &&
        run_with_progress "Installing packages: $*" apt-get install -y -qq "$@"
      ;;
    dnf) run_with_progress "Installing packages: $*" dnf install -y -q "$@" ;;
    yum) run_with_progress "Installing packages: $*" yum install -y -q "$@" ;;
    zypper) run_with_progress "Installing packages: $*" zypper install -y --no-recommends "$@" ;;
  esac
}

ensure_deps() {
  local need=() bin
  for bin in curl jq openssl; do
    command -v "$bin" >/dev/null 2>&1 || need+=("$bin")
  done
  if ! [[ -r /etc/ssl/certs/ca-certificates.crt || -d /etc/ssl/certs ]]; then
    need+=(ca-certificates)
  fi
  if ((${#need[@]})); then
    info "installing dependencies: ${need[*]}"
    pkg_install "${need[@]}" || die "failed to install dependencies: ${need[*]}"
  fi
}

# ----------------------------------------------------------------------------
# [2] Install / update Xray
# ----------------------------------------------------------------------------
write_service() (
  local staged
  [[ ! -d "$XRAY_SERVICE" ]] || { err 'Xray service path is a directory'; return 1; }
  mkdir -p "$XRAY_DIR" /var/log/xray || return 1
  staged=$(mktemp "${XRAY_SERVICE}.XXXXXXXX") || return 1
  trap 'rm -f "$staged"' EXIT
  cat > "$staged" <<EOF || return 1
[Unit]
Description=Xray Service (OneVPS)
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
User=nobody
WorkingDirectory=$XRAY_DIR
ExecStart=$XRAY_BIN run -config $XRAY_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/log/xray

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$staged" && mv -f "$staged" "$XRAY_SERVICE" || return 1
  systemctl daemon-reload && systemctl enable xray >/dev/null
)

secure_xray_files() {
  local candidate="$1" group
  group=$(id -gn nobody) && [[ -n "$group" ]] &&
    mkdir -p "$XRAY_DIR" /var/log/xray &&
    chown root:"$group" "$XRAY_DIR" "$XRAY_NODES" "$candidate" &&
    chmod 750 "$XRAY_DIR" && chmod 640 "$XRAY_NODES" "$candidate" &&
    chown nobody:"$group" /var/log/xray && chmod 750 /var/log/xray
}

install_xray() (
  ensure_deps
  xray_write_lock || return 1
  local tmp
  tmp=$(mktemp)
  info "downloading official Xray installer..."
  download_file "$XRAY_INSTALL_URL" -o "$tmp" || { rm -f "$tmp"; die "download failed"; }
  run_with_progress 'Installing/updating Xray-core and geodata' bash "$tmp" install 7>&- \
    || { rm -f "$tmp"; die "Xray install failed"; }
  rm -f "$tmp"

  write_service || { err 'Cannot configure Xray service; installation did not finish'; return 1; }
  rebuild_config_locked || return 1
  ok "Xray $(installed_version) installed"
)

# ----------------------------------------------------------------------------
# Firewall / ports
# ----------------------------------------------------------------------------
update_firewall_port() {
  local action="$1" endpoint="$2/$3" state flag result=0
  local -a args
  if [[ "$action" == open ]]; then args=(allow); flag=--add-port; else args=(delete allow); flag=--remove-port; fi
  if command -v ufw >/dev/null 2>&1; then
    state=$(LC_ALL=C ufw status) || { err "Cannot read UFW status for $endpoint"; return 1; }
    if [[ "$state" == 'Status: active'* ]] && ! ufw "${args[@]}" "$endpoint"; then
      err "UFW failed to $action $endpoint"; result=1
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      if ! firewall-cmd --permanent "$flag=$endpoint" || ! firewall-cmd --reload; then
        err "firewalld failed to $action $endpoint"; result=1
      fi
    elif [[ $? != 252 ]]; then
      err "Cannot read firewalld status for $endpoint"; result=1
    fi
  fi
  return "$result"
}

open_port() { update_firewall_port open "$@"; }
close_port() { update_firewall_port close "$@"; }

port_in_use() {
  local p="$1" proto="${2:-both}" flags=-tunl sockets
  [[ "$proto" != udp ]] || flags=-unl
  [[ "$proto" != tcp ]] || flags=-tnl
  if command -v ss >/dev/null 2>&1; then
    sockets=$(ss "$flags") || { err "Cannot inspect $proto port $p"; return 2; }
    socket_list_has_port "$p" <<< "$sockets"
  else
    err 'Port inspection requires ss (iproute2/iproute)'; return 2
  fi
}

socket_list_has_port() {
  awk -v port="$1" 'NF >= 2 && $(NF-1) ~ (":" port "$") {found=1} END {exit !found}'
}

port_taken_by_node() {
  local result
  [[ -e "$XRAY_NODES" || -L "$XRAY_NODES" ]] || return 1
  result=$(jq -sr --argjson p "$1" --arg proto "${2:-both}" --arg exclude "${3:-}" '
    if length!=1 or (.[0].nodes|type)!="array" then error("invalid node reservations") else .[0] end |
    any(.nodes[]; .id != $exclude and
      ($proto == "both" or (if .type == "hysteria2" then "udp" else "tcp" end) == $proto) and
      (.port == $p or (.hopping != null and any(.hopping.ports | split(",")[] | split("-") | map(tonumber);
        first <= $p and last >= $p))))
  ' "$XRAY_NODES") || { err 'Cannot inspect Xray port reservations'; return 2; }
  [[ "$result" == true ]]
}

# ----------------------------------------------------------------------------
# Caddy integration (HY2 certificates)
# ----------------------------------------------------------------------------
caddy_present() { command -v caddy >/dev/null 2>&1; }

# Install Caddy from its official package repo (apt/dnf/yum). Non-zero if the
# distro has no supported repo path.
caddy_install_repo() {
  case "$PKG" in
    apt)
      pkg_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg || return 1
      mkdir -p /usr/share/keyrings
      # umask 077 (set script-wide) would make these root-only; apt reads the
      # keyring and sources list as the unprivileged _apt user, so force 0644.
      download_file -1 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || return 1
      chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      download_file -1 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list || return 1
      chmod 0644 /etc/apt/sources.list.d/caddy-stable.list
      if pkg_install caddy; then
        return 0
      fi
      # Don't leave a broken/unsigned repo poisoning future apt runs.
      rm -f /etc/apt/sources.list.d/caddy-stable.list
      return 1
      ;;
    dnf)
      pkg_install 'dnf-command(copr)' || return 1
      run_with_progress 'Enabling Caddy repository' dnf copr enable -y @caddy/caddy || return 1
      pkg_install caddy
      ;;
    yum)
      pkg_install yum-plugin-copr || return 1
      run_with_progress 'Enabling Caddy repository' yum copr enable -y @caddy/caddy || return 1
      pkg_install caddy
      ;;
    *) return 1 ;;
  esac
}

# Fallback: drop the official static binary + systemd unit + caddy user.
# Prefers the GitHub release tarball (a fast static asset); falls back to the
# on-demand caddyserver.com build API. All downloads are time-limited so a slow
# or blocked mirror fails fast instead of hanging.
caddy_install_binary() {
  local gh_arch td ver url
  case "$ARCH" in
    amd64) gh_arch="amd64" ;;
    arm64) gh_arch="arm64" ;;
    armv7) gh_arch="armv7" ;;
  esac
  td=$(mktemp -d)

  ver=$(run_with_progress 'Checking latest Caddy release' curl -fsSL --connect-timeout 10 --max-time 30 \
          https://api.github.com/repos/caddyserver/caddy/releases/latest \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')

  if [[ -n "$ver" ]] && command -v tar >/dev/null 2>&1; then
    url="https://github.com/caddyserver/caddy/releases/download/v${ver}/caddy_${ver}_linux_${gh_arch}.tar.gz"
    info "downloading Caddy ${ver} (${gh_arch}) from GitHub..."
    if download_file --connect-timeout 15 --max-time 180 --retry 2 "$url" -o "$td/caddy.tar.gz" \
       && tar -xzf "$td/caddy.tar.gz" -C "$td" caddy 2>/dev/null; then
      install -m 0755 "$td/caddy" /usr/local/bin/caddy || true
    fi
  fi

  if ! caddy_present; then
    local carch="$gh_arch"; [[ "$gh_arch" == armv7 ]] && carch="arm&arm=7"
    info "trying caddyserver.com download API..."
    if download_file --connect-timeout 15 --max-time 180 \
        "https://caddyserver.com/api/download?os=linux&arch=${carch}" -o "$td/caddy"; then
      install -m 0755 "$td/caddy" /usr/local/bin/caddy || true
    fi
  fi

  rm -rf "$td"
  caddy_present || { err "Caddy binary download failed"; return 1; }

  id caddy >/dev/null 2>&1 || \
    useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy 2>/dev/null || true
  if [[ ! -d /etc/caddy ]]; then install -d -m 755 /etc/caddy || return 1; fi
  local dir
  for dir in /var/lib/caddy /var/log/caddy; do
    [[ -d "$dir" ]] || install -d -o caddy -g caddy -m 750 "$dir" || return 1
  done

  cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# Guarantee Caddy is installed, has a Caddyfile, and is enabled. Non-zero on
# failure. Sets CADDYFILE on success.
ensure_caddy() {
  if ! caddy_present; then
    warn "Caddy not found; installing for HTTPS"
    if ! caddy_install_repo; then
      warn "repo install unavailable; falling back to static binary"
      caddy_install_binary || { err "Caddy install failed"; return 1; }
    fi
    caddy_present || { err "Caddy install failed"; return 1; }
    ok "Caddy installed"
  fi

  local cf
  cf=$(find_caddyfile)
  if [[ -z "$cf" ]]; then
    cf=/etc/caddy/Caddyfile
    if [[ ! -d /etc/caddy ]]; then install -d -m 755 /etc/caddy || return 1; fi
    cat > "$cf" <<'EOF'
# Managed alongside OneVPS. Caddy reverse-proxies real services here;
# OneVPS appends managed certificate domains below.
:80 {
	respond "OK" 200
}
EOF
    chmod 644 "$cf" || return 1
    CADDYFILE="$cf"
  fi

  systemctl enable caddy >/dev/null || { err 'Cannot enable Caddy'; return 1; }
  if ! systemctl is-active --quiet caddy; then
    run_with_progress 'Starting Caddy service' systemctl start caddy >/dev/null || return 1
  fi
  systemctl is-active --quiet caddy || { err 'Caddy is not active'; return 1; }
}

find_caddyfile() {
  [[ -n "$CADDYFILE" && -f "$CADDYFILE" ]] && { echo "$CADDYFILE"; return; }
  local c
  c=$(systemctl cat caddy 2>/dev/null \
      | sed -n 's/.*--config[ =]\([^ ]*\).*/\1/p' | head -n1)
  if [[ -n "$c" && -f "$c" ]]; then echo "$c"; return; fi
  for c in /etc/caddy/Caddyfile /etc/Caddyfile /usr/local/etc/caddy/Caddyfile; do
    [[ -f "$c" ]] && { echo "$c"; return; }
  done
  echo ""
}

# Reload Caddy after validating. Returns non-zero on validation/reload failure.
caddy_reload() {
  local file="$1"
  if caddy_present; then
    if ! caddy validate --adapter caddyfile --config "$file" >/dev/null 2>&1; then
      err "Caddyfile validation failed ($file)"
      return 1
    fi
  fi
  if systemctl is-active caddy >/dev/null 2>&1; then
    run_with_progress 'Reloading Caddy service' systemctl reload caddy >/dev/null && return 0
  fi
  if caddy_present; then
    run_with_progress 'Reloading Caddy configuration' caddy reload --adapter caddyfile --config "$file" >/dev/null && return 0
  fi
  err "failed to reload Caddy"
  return 1
}

# Error-page root for ordinary requests to a managed domain.
caddy_site_root() { echo "/var/lib/onevps/sites/$1"; }

# Drop a small static landing page so casual probes see a site, not a 404.
# Never overwrites an existing index.html (user may customize it).
ensure_site_content() {
  local domain="$1" root
  root=$(caddy_site_root "$domain")
  mkdir -p "$root" || return 1
  if [[ ! -f "$root/index.html" ]]; then
    cat > "$root/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>403 Forbidden</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700;800&family=Noto+Sans+SC:wght@400;500;700&display=swap" rel="stylesheet">
<style>
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
@keyframes floatA{0%,100%{transform:translateY(0)}50%{transform:translateY(-18px)}}
@keyframes floatB{0%,100%{transform:translateY(0) rotate(-3deg)}50%{transform:translateY(-12px) rotate(3deg)}}
@keyframes blob{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(30px,-20px) scale(1.12)}}
@keyframes pop{0%{transform:scale(.8);opacity:0}100%{transform:scale(1);opacity:1}}
@keyframes blink{0%,90%,100%{transform:scaleY(1)}95%{transform:scaleY(.1)}}
@keyframes shake{0%,100%{transform:rotate(0)}25%{transform:rotate(-12deg)}75%{transform:rotate(12deg)}}
</style>
</head>
<body>
<div style="position:relative;min-height:100vh;width:100%;overflow:hidden;background:radial-gradient(1200px 800px at 75% 15%, #241d33 0%, #181520 55%, #131019 100%);font-family:'Outfit','Noto Sans SC',system-ui,sans-serif;color:#ece8f2;display:flex;align-items:center;justify-content:center;padding:48px 32px">
  <div style="position:relative;z-index:2;display:flex;align-items:center;justify-content:center;max-width:760px;width:100%">
    <div style="display:flex;flex-direction:column;gap:28px">
      <div style="display:inline-flex;align-items:center;gap:10px;align-self:flex-start;padding:7px 14px;border-radius:999px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);font-size:13px;letter-spacing:.04em;color:#b9b2c9;font-weight:500">
        <span style="width:8px;height:8px;border-radius:50%;background:#ff4d42;box-shadow:0 0 12px #ff4d42"></span>
        HTTP 403 · FORBIDDEN
      </div>
      <div style="display:flex;align-items:baseline;gap:6px;font-weight:800;line-height:.85;font-size:clamp(96px,16vw,196px);letter-spacing:-.04em">
        <span>4</span>
        <span>0</span>
        <span>3</span>
      </div>
      <div style="display:flex;flex-direction:column;gap:10px">
        <h1 style="font-size:clamp(26px,3.4vw,40px);font-weight:700;letter-spacing:-.01em;line-height:1.15">Access Forbidden</h1>
      </div>
      <p style="font-size:16px;line-height:1.7;color:#b9b2c9;max-width:52ch">
        You don't have permission to view this page. Try signing in again, or reach out if you think this is a mistake.
      </p>
    </div>
  </div>
</div>
</body>
</html>
HTML
  fi
  chmod a+rx "$(dirname "$(dirname "$root")")" "$(dirname "$root")" "$root" &&
    chmod a+r "$root/index.html"
}

# ----------------------------------------------------------------------------
# [3] Node storage + config generation
# ----------------------------------------------------------------------------
xray_write_lock() {
  command -v flock >/dev/null || { err 'Xray configuration writes require flock (util-linux)'; return 1; }
  mkdir -p "$(dirname "$XRAY_DIR")" || return 1
  exec 7>>"${XRAY_DIR}.lock" || return 1
  flock -x 7 || { err 'Cannot lock Xray configuration'; return 1; }
}

ensure_nodes_file() (
  [[ ! -f "$XRAY_NODES" ]] || return 0
  xray_write_lock && ensure_nodes_file_locked
)

ensure_nodes_file_locked() {
  [[ ! -f "$XRAY_NODES" ]] || return 0
  mkdir -p "$XRAY_DIR" && echo '{"nodes":[]}' > "$XRAY_NODES"
}

node_count() {
  [[ -f "$XRAY_NODES" ]] || { echo 0; return; }
  jq '.nodes|length' "$XRAY_NODES"
}

node_by_id() {
  jq -c --arg id "$1" '.nodes[]|select(.id==$id)' "$XRAY_NODES"
}

validate_xray_config() {
  local conf="$1" err_file="$2"
  [[ -x "$XRAY_BIN" ]] || return 0
  if jq -e 'any(.inbounds[]; .protocol == "hysteria")' "$conf" >/dev/null; then
    require_hy2_core || return 1
  fi
  "$XRAY_BIN" run -test -config "$conf" >"$err_file" 2>&1
}

# Decode a URI component exactly once; '+' is not a form-space.
# Keep secret-bearing data in shell variables/stdin, never external argv.
outbound_decode() {
  local rest="$1" out='' char hex
  while [[ -n "$rest" ]]; do
    char=${rest:0:1}; rest=${rest:1}
    if [[ "$char" == '%' ]]; then
      hex=${rest:0:2}
      [[ "$hex" =~ ^[0-9a-fA-F]{2}$ ]] || return 1
      [[ "$hex" != 00 ]] || return 1
      printf -v char '%b' "\\x$hex"
      rest=${rest:2}
    fi
    [[ "$char" != [[:cntrl:]] ]] || return 1
    out+="$char"
  done
  printf '%s' "$out"
}

# SIP002 base64url userinfo. Canonical re-encoding detects bad padding/bits.
outbound_base64() {
  local encoded="$1" bare normalized decoded check
  [[ "$encoded" =~ ^[A-Za-z0-9_-]+={0,2}$ ]] || return 1
  bare=${encoded%%=*}
  (( ${#bare} % 4 != 1 )) || return 1
  normalized=${bare//-/+}; normalized=${normalized//_/\/}
  while (( ${#normalized} % 4 )); do normalized+='='; done
  [[ "$encoded" != *=* || ${#encoded} == "${#normalized}" ]] || return 1
  # JSON checks decoded bytes before Bash command substitution can strip NUL/LF.
  decoded=$(printf '%s' "$normalized" | openssl base64 -d -A | jq -Rs -e --arg kind "${2:-credential}" '
    select(length > 0 and (test(if $kind == "json" then "[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]" else "[\\x00-\\x1f\\x7f]" end) | not))') || return 1
  check=$(printf '%s' "$decoded" | jq -jr '.' | openssl base64 -A) || return 1
  [[ "$check" == "$normalized" ]] || return 1
  printf '%s' "$decoded" | jq -jr '.'
}

# Strict, limited persistent schema. Revalidated on every render, including
# disabled nodes. No arbitrary Xray JSON accepted.
validate_outbound() {
  local data host
  data=$(jq -cse 'select(length == 1) | .[0] | select(type == "object")' 2>/dev/null) || return 1
  if [[ $(jq -r '.protocol // empty' <<<"$data") == vmess ]]; then
    jq -e '
      (.method | IN("auto","aes-128-gcm","chacha20-poly1305")) and
      (.params.type | IN("tcp","ws")) and .params.security == "tls" and
      .params.flow == "" and
      ((keys - ["mode","protocol","server","port","uuid","params","method"]) | length == 0)
    ' <<<"$data" >/dev/null || return 1
    # Reuse the TLS/transport validator without allowing VLESS-only features.
    jq -c 'del(.method) | .protocol = "vless"' <<<"$data" | validate_outbound
    return
  fi
  data=$(jq -cs -e '
    def text: type == "string" and (test("[\\x00-\\x1f\\x7f]") | not);
    def nonempty: text and length > 0;
    def keys_only($allowed): (keys - $allowed | length) == 0;
    def uuid: type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    select(length == 1) | .[0] | select(type == "object") |
    select(if .mode == "direct" then keys == ["mode"]
    elif .mode == "proxy" then
      (.server | nonempty) and (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
      if .protocol == "shadowsocks" then
        keys_only(["mode","protocol","server","port","method","password"]) and
        (.method == "aes-128-gcm" or .method == "aes-256-gcm" or .method == "chacha20-ietf-poly1305") and (.password | nonempty)
      elif .protocol == "socks" then
        keys_only(["mode","protocol","server","port","username","password"]) and
        (if has("username") or has("password") then (.username | nonempty) and (.password | nonempty) else true end)
      elif .protocol == "vless" then
        keys_only(["mode","protocol","server","port","uuid","params"]) and (.uuid | uuid) and
        (.params | type == "object" and
          keys_only(["encryption","type","security","flow","sni","fp","pbk","sid","spx","host","path","serviceName","mode","alpn"]) and
          all(.[]; text) and .encryption == "none" and
          (.type == "tcp" or .type == "ws" or .type == "grpc") and
          (.flow == "" or (.flow == "xtls-rprx-vision" and .type == "tcp")) and
          (if has("sni") then (.sni | nonempty and test("^[A-Za-z0-9.-]+$")) else true end) and
          (if has("fp") then (.fp | IN("chrome","firefox","safari","ios","android","edge","360","qq","random","randomized")) else true end) and
          (if has("alpn") then (.alpn | test("^(h2|http/1\\.1)(,(h2|http/1\\.1))*$")) else true end) and
          (if .security == "reality" then
             .type == "tcp" and (.sni | nonempty) and (.fp | nonempty) and
             (.pbk | type == "string" and test("^[A-Za-z0-9_-]{43}$")) and
             (.sid | type == "string" and test("^([0-9a-fA-F]{2}){0,8}$")) and
             (has("alpn") | not) and
             (if has("spx") then (.spx | startswith("/")) else true end)
           elif .security == "tls" then (has("pbk") or has("sid") or has("spx") | not)
           else false end) and
          (if .type == "ws" then
             (has("serviceName") or has("mode") | not) and
             (if has("path") then (.path | startswith("/")) else true end) and
             (if has("host") then (.host | nonempty and test("^[A-Za-z0-9.:-]+$")) else true end)
           elif .type == "grpc" then
             (has("host") or has("path") | not) and
             (if has("mode") then (.mode == "gun" or .mode == "multi") else true end) and
             (if has("serviceName") then (.serviceName | nonempty) else true end)
           else (has("host") or has("path") or has("serviceName") or has("mode") | not) end))
      else false end
    else false end)
  ' <<<"$data" 2>/dev/null) || return 1
  host=$(jq -r '.server // empty' <<<"$data") || return 1
  [[ -z "$host" ]] || realm_valid_host "$host"
}

# v2rayN v2 JSON links only; never silently discard transport/security options.
parse_vmess_link() {
  local encoded="$1" data
  [[ "$encoded" =~ ^[A-Za-z0-9+/_-]+={0,2}$ ]] || return 1
  encoded=${encoded//+/-}; encoded=${encoded//\//_}
  data=$(outbound_base64 "$encoded" json) || return 1
  data=$(jq -cse '
    select(length == 1) | .[0] | select(type == "object") |
    select((keys - ["v","ps","add","port","id","aid","scy","net","type","host","path","tls","sni","alpn","fp","insecure"]) | length == 0) |
    select(all(.[]; type == "string" or type == "number")) |
    select((.v|tostring) == "2" and ((.aid // 0)|tostring) == "0" and
      ((.insecure // "0")|tostring) == "0" and
      ((.type // "none") | IN("none","")) and .tls == "tls" and (.net | IN("tcp","ws"))) |
    select(if .net == "tcp" then ((.host // "") == "" and (.path // "") == "") else true end) |
    {mode:"proxy",protocol:"vmess",server:.add,port:(.port|tonumber),uuid:.id,
     method:(if (.scy // "") == "" then "auto" else .scy end),
     params:({encryption:"none",type:.net,security:"tls",flow:""} +
       (if (.sni // "") != "" then {sni:.sni} else {} end) +
       (if (.fp // "") != "" then {fp:.fp} else {} end) +
       (if (.alpn // "") != "" then {alpn:.alpn} else {} end) +
       (if .net == "ws" then
         {path:(if (.path // "") == "" then "/" else .path end)} +
         (if (.host // "") != "" then {host:.host} else {} end)
        else {} end))}
  ' <<<"$data" 2>/dev/null) || return 1
  validate_outbound <<<"$data" || return 1
  printf '%s\n' "$data"
}

parse_outbound_link() {
  local link rest scheme authority query='' fragment='' auth='' host port key value pair params='{}' data credential method password user
  IFS= read -r link || [[ -n "$link" ]] || return 1
  [[ -n "$link" && "$link" != *[[:space:]]* && "$link" != *[[:cntrl:]]* ]] || return 1
  # Exactly one URI; never silently discard a second line.
  if IFS= read -r rest || [[ -n "$rest" ]]; then return 1; fi
  [[ "$link" == *://* ]] || return 1
  scheme=${link%%://*}; rest=${link#*://}
  if [[ "$scheme" == vmess ]]; then parse_vmess_link "$rest"; return; fi
  case "$scheme" in ss|vless|socks5) ;; *) return 1 ;; esac
  if [[ "$rest" == *'#'* ]]; then fragment=${rest#*#}; rest=${rest%%#*}; outbound_decode "$fragment" >/dev/null || return 1; fi
  if [[ "$rest" == *'?'* ]]; then query=${rest#*\?}; rest=${rest%%\?*}; [[ -n "$query" ]] || return 1; fi
  authority=$rest
  # SIP002 permits an optional slash after the authority, but no path.
  if [[ "$scheme" == ss && "$authority" == */ ]]; then authority=${authority%/}; fi
  [[ "$authority" != */* ]] || return 1
  if [[ "$authority" == *@* ]]; then
    auth=${authority%@*}; authority=${authority##*@}
    [[ -n "$auth" && "$auth" != *@* ]] || return 1
  fi
  if [[ "$authority" == '['* ]]; then
    [[ "$authority" == *']:'* ]] || return 1
    host=${authority%%]*}; host=${host#\[}; port=${authority#*]:}
    [[ "$host" == *:* ]] || return 1
  else
    [[ "$authority" == *:* ]] || return 1
    host=${authority%:*}; port=${authority##*:}
    [[ "$host" != *:* ]] || return 1
  fi
  realm_valid_host "$host" && realm_valid_port "$port" || return 1
  data=$(printf '%s\n' "$host" "$port" | jq -Rsc 'split("\n") | {mode:"proxy",server:.[0],port:(.[1]|tonumber)}') || return 1
  case "$scheme" in
    ss)
      [[ -z "$query" && -n "$auth" ]] || return 1
      if [[ "$auth" == *:* ]]; then
        method=$(outbound_decode "${auth%%:*}") && password=$(outbound_decode "${auth#*:}") || return 1
      else
        credential=$(outbound_base64 "$auth") || return 1
        [[ "$credential" == *:* ]] || return 1
        method=${credential%%:*}; password=${credential#*:}
      fi
      data=$(printf '%s\n%s\n%s\n' "$data" "$method" "$password" | jq -Rsc 'split("\n") | (.[0]|fromjson) + {protocol:"shadowsocks",method:.[1],password:.[2]}') || return 1 ;;
    socks5)
      [[ -z "$query" ]] || return 1
      data=$(jq -c '. + {protocol:"socks"}' <<<"$data") || return 1
      if [[ -n "$auth" ]]; then
        [[ "$auth" == *:* ]] || return 1
        user=$(outbound_decode "${auth%%:*}") && password=$(outbound_decode "${auth#*:}") || return 1
        data=$(printf '%s\n%s\n%s\n' "$data" "$user" "$password" | jq -Rsc 'split("\n") | (.[0]|fromjson) + {username:.[1],password:.[2]}') || return 1
      fi ;;
    vless)
      credential=$(outbound_decode "$auth") || return 1
      [[ -n "$query" ]] || return 1
      while :; do
        pair=${query%%&*}; [[ "$pair" == *=* ]] || return 1
        key=$(outbound_decode "${pair%%=*}") && value=$(outbound_decode "${pair#*=}") || return 1
        case "$key" in encryption|type|security|flow|sni|fp|pbk|sid|spx|host|path|serviceName|mode|alpn) ;; *) return 1 ;; esac
        params=$(printf '%s\n%s\n%s\n' "$params" "$key" "$value" | jq -Rsc -e 'split("\n") | .[1] as $k | .[2] as $v | (.[0]|fromjson) | select(has($k)|not) | . + {($k):$v}') || return 1
        [[ "$query" == *'&'* ]] || break
        query=${query#*&}
      done
      params=$(jq -c '{encryption:"none",type:"tcp",flow:""} + .' <<<"$params") || return 1
      data=$(printf '%s\n%s\n%s\n' "$data" "$credential" "$params" | jq -Rsc 'split("\n") | (.[0]|fromjson) + {protocol:"vless",uuid:.[1],params:(.[2]|fromjson)}') || return 1 ;;
  esac
  validate_outbound <<<"$data" || return 1
  printf '%s\n' "$data"
}

build_proxy_outbound() {
  local tag="$1" data
  data=$(jq -c '.') || return 1
  validate_outbound <<<"$data" || return 1
  if [[ $(jq -r '.protocol' <<<"$data") == vmess ]]; then
    local transport
    transport=$(jq -c 'del(.method) | .protocol = "vless"' <<<"$data" | build_proxy_outbound "$tag") || return 1
    printf '%s\n%s\n' "$transport" "$data" | jq -sc '
      .[1] as $v | .[0] | .protocol = "vmess" |
      .settings = {vnext:[{address:$v.server,port:$v.port,users:[{id:$v.uuid,security:$v.method}]}]}'
    return
  fi
  jq -c --arg tag "$tag" '
    {tag:$tag,protocol:.protocol} +
    if .protocol == "shadowsocks" then {settings:{servers:[{address:.server,port:.port,method:.method,password:.password}]}}
    elif .protocol == "socks" then {settings:{servers:[({address:.server,port:.port} +
      if has("username") then {users:[{user:.username,pass:.password}]} else {} end)]}}
    elif .protocol == "vless" then
      .params as $p | {settings:{vnext:[{address:.server,port:.port,users:[{id:.uuid,encryption:"none",flow:$p.flow}]}]},
      streamSettings:({network:$p.type,security:$p.security} +
        (if $p.security == "reality" then {realitySettings:({serverName:$p.sni,fingerprint:$p.fp,publicKey:$p.pbk,shortId:$p.sid} + if $p|has("spx") then {spiderX:$p.spx} else {} end)}
         else {tlsSettings:({allowInsecure:false} +
           (if $p|has("sni") then {serverName:$p.sni} else {} end) +
           (if $p|has("fp") then {fingerprint:$p.fp} else {} end) +
           (if $p|has("alpn") then {alpn:($p.alpn|split(","))} else {} end))} end) +
        (if $p.type == "ws" then {wsSettings:({path:($p.path // "/")} + if $p|has("host") then {host:$p.host} else {} end)}
         elif $p.type == "grpc" then {grpcSettings:{serviceName:($p.serviceName // ""),multiMode:($p.mode == "multi")}}
         else {} end))}
    else error("proxy required") end' <<<"$data"
}

# Identity overrides precede node inheritance; security blocks are prepended by render_config.
build_outbound_routes() {
  local source="$1" rows row object tag proxy proxies='[]' rules assignments
  assignments=$(jq -c '
    [.nodes[] | select(.enabled == true) | . as $n |
      (if has("default_outbound") then
        {tag:("default-out-" + (.id|@base64)),inbound:.tag,user:(.tag + "@onevps"),outbound:.default_outbound}
       else empty end),
      ((.users // [])[] | select(has("outbound")) |
        ([$n.id,.id]|tojson|@base64) as $key |
        {tag:("user-out-" + $key),inbound:$n.tag,user:($key + "@onevps-user"),outbound}),
      (if has("outbound") then {tag:("node-out-" + .id),inbound:.tag,outbound} else empty end)]' "$source") || return 1
  rows=$(jq -c '.[] | select(.outbound.mode == "proxy")' <<<"$assignments") || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    tag=$(jq -r '.tag' <<<"$row") || return 1
    object=$(jq -c '.outbound' <<<"$row") || return 1
    proxy=$(build_proxy_outbound "$tag" <<<"$object") || return 1
    proxies=$(printf '%s\n%s\n' "$proxies" "$proxy" | jq -sc '.[0] + [.[1]]') || return 1
  done <<<"$rows"
  rules=$(jq -c '[.[] | {type:"field",inboundTag:[.inbound],
    outboundTag:(if .outbound.mode == "direct" then "direct" else .tag end)} +
    (if has("user") then {user:[.user]} else {} end)]' <<<"$assignments") || return 1
  printf '%s\n%s\n' "$proxies" "$rules" | jq -sc '{outbounds:.[0],rules:.[1]}'
}

render_config() {
  local source="$1" output="$2"
  validate_node_metadata "$source" || { err "invalid node metadata"; return 1; }
  local inbounds n enabled type ib rows routes
  rows=$(jq -c '.nodes[]' "$source") || return 1
  inbounds='[]'
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    enabled=$(jq -r '.enabled' <<<"$n") || return 1
    [[ "$enabled" == "true" ]] || continue
    type=$(jq -r '.type' <<<"$n") || return 1
    case "$type" in
      vless-reality) ib=$(build_reality_inbound "$n") || return 1 ;;
      hysteria2)     ib=$(build_hysteria_inbound "$n") || return 1 ;;
      *) return 1 ;;
    esac
    inbounds=$(printf '%s\n%s\n' "$inbounds" "$ib" | jq -sc '.[0] + [.[1]]') || return 1
  done <<<"$rows"
  routes=$(build_outbound_routes "$source") || return 1
  printf '%s\n%s\n' "$inbounds" "$routes" | jq -s '
    .[0] as $inbounds | .[1] as $routes |
    def private_ip_rule: {
      type: "field",
      ip: [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10",
        "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16",
        "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
        "::1/128", "fc00::/7", "fe80::/10"
      ],
      outboundTag: "block"
    };
    def bittorrent_rule: {type: "field", protocol: ["bittorrent"], outboundTag: "block"};
    {
      log: {loglevel: "warning"},
      inbounds: $inbounds,
      outbounds: ([
        {tag: "direct", protocol: "freedom", settings: {domainStrategy: "UseIP"}},
        {tag: "block", protocol: "blackhole", settings: {}}
      ] + $routes.outbounds),
      routing: {
        domainStrategy: "AsIs",
        rules: ([private_ip_rule, bittorrent_rule] + $routes.rules)
      },
      policy: {
        levels: {
          "0": {handshake: 4, connIdle: 300, uplinkOnly: 2, downlinkOnly: 5}
        }
      }
    }' > "$output"
}

rebuild_config() (
  xray_write_lock && rebuild_config_locked
)

rebuild_config_locked() (
  ensure_nodes_file_locked || return 1
  local work had_config=false was_active=false replaced=false committed=false
  work=$(mktemp -d "$XRAY_DIR/.rebuild.XXXXXXXX") || return 1
  rebuild_cleanup() {
    local status=$? restored=true
    trap - EXIT INT TERM HUP
    if $replaced && ! $committed; then
      if $had_config; then
        cp -p "$work/config.backup" "$work/config.restore" && mv "$work/config.restore" "$XRAY_CONF" || restored=false
      else
        rm -f "$XRAY_CONF" || restored=false
      fi
      if $restored && [[ -x "$XRAY_BIN" ]]; then
        if $was_active; then
          run_with_progress 'Restoring previous Xray service' systemctl restart xray && systemctl is-active --quiet xray || restored=false
        else
          systemctl stop xray || restored=false
          if systemctl is-active --quiet xray; then restored=false; fi
        fi
      fi
      if ! $restored; then err "Xray rollback failed; recovery directory retained: $work"; exit 1; fi
      err 'Restored previous Xray configuration and service state'
    fi
    rm -rf "$work"
    exit "$status"
  }
  trap rebuild_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  render_config "$XRAY_NODES" "$work/config.json" || return 1
  if ! validate_xray_config "$work/config.json" "$work/check.log"; then
    err "generated config failed validation (details withheld to protect credentials)"
    return 1
  fi
  secure_xray_files "$work/config.json" || { err 'Cannot prepare Xray file permissions'; return 1; }
  if [[ -f "$XRAY_CONF" ]]; then
    cp -p "$XRAY_CONF" "$work/config.backup" || return 1
    had_config=true
  fi
  if [[ -x "$XRAY_BIN" ]] && systemctl is-active --quiet xray; then was_active=true; fi
  replaced=true
  mv "$work/config.json" "$XRAY_CONF" || return 1
  if [[ -x "$XRAY_BIN" ]]; then
    run_with_progress 'Restarting Xray service' systemctl restart xray && systemctl is-active --quiet xray || {
      err 'Xray did not restart successfully'; return 1;
    }
  fi
  committed=true
)

node_clients() {
  jq -c '
    . as $n |
    [{uuid:.uuid,password:.password,email:(.tag + "@onevps")}] +
      [(.users // [])[] | . + {email:(([ $n.id, .id ] | tojson | @base64) + "@onevps-user")}] |
    map(if $n.type == "vless-reality" then {id:.uuid,flow:"xtls-rprx-vision",email}
        elif $n.type == "hysteria2" then {auth:.password,email}
        else error("unsupported inbound") end)' <<<"$1"
}

validate_node_metadata() {
  local outbounds outbound
  hy2_hop_plan "$1" >/dev/null || return 1
  outbounds=$(jq -c '.nodes[] | (select(has("outbound")) | .outbound), (select(has("default_outbound")) | .default_outbound), ((.users // [])[] | select(has("outbound")) | .outbound)' "$1" 2>/dev/null) || return 1
  while IFS= read -r outbound; do
    [[ -n "$outbound" ]] || continue
    validate_outbound <<<"$outbound" || return 1
  done <<<"$outbounds"
  jq -es '
    def nonempty: type == "string" and length > 0;
    def port: type == "number" and floor == . and . >= 1 and . <= 65535;
    def uuid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\\z");
    select(length == 1) | .[0] |
    (.nodes | type == "array") and
    ([.nodes[].id] | length == (unique | length)) and
    ([.nodes[].tag] | length == (unique | length)) and
    all(.nodes[];
      . as $n |
      (.id | nonempty) and
      (.enabled | type == "boolean") and (.tag | nonempty) and (.port | port) and
      (if .type == "hysteria2" then
        (.domain | type == "string" and test("^[A-Za-z0-9.-]+$")) and
        (.tls_cert | type == "string" and startswith("/")) and
        (.tls_key | type == "string" and startswith("/"))
       elif .type == "vless-reality" then
        all(.reality_sni, .reality_target, .reality_public_key, .reality_private_key, .reality_short_id; nonempty) and
        (if has("reality_target_port") then .reality_target_port | port else true end)
       else true end) and
      (if .type == "vless-reality" then (.uuid | uuid)
       elif .type == "hysteria2" then (.password | nonempty)
       else false end) and
      (if has("users") then (.users | type == "array") else true end) and
      ((.users // []) as $users |
        ([$users[].id] | length == (unique | length)) and
        ([$users[].name] | length == (unique | length)) and
        all($users[];
          (.id | type == "string" and test("^[A-Za-z0-9_-]+$") and . != "default") and
          (.name | type == "string" and test("\\S") and (test("[\\x00-\\x1f\\x7f]") | not)) and
          (if $n.type == "vless-reality" then
             (.uuid | uuid)
           elif $n.type == "hysteria2" then (.password | nonempty)
           else false end)) and
        (if .type == "vless-reality" then ([.uuid, $users[].uuid] | map(ascii_downcase))
         else [.password, $users[].password] end | length == (unique | length))))
  ' "$1" >/dev/null 2>&1
}

# A subshell scopes traps. Backups and candidates stay on the target filesystem.
# Rollback covers detectable failures, not power-loss atomicity across two files.
apply_candidate_transaction() (
  xray_write_lock && apply_candidate_transaction_locked "$@"
)

apply_candidate_transaction_locked() (
  local prepare="$1"
  shift
  umask 077
  local tx active=false touched=false committed=false preserve=false hop_changed=false hop_touched=false
  [[ -x "$XRAY_BIN" && -f "$XRAY_NODES" && -f "$XRAY_CONF" ]] || {
    err "installed Xray and existing configuration required"; return 1;
  }
  tx=$(mktemp -d "$XRAY_DIR/.transaction.XXXXXXXX") || return 1
  transaction_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      if ! cp -p "$tx/nodes.backup" "$tx/nodes.restore" || ! cp -p "$tx/config.backup" "$tx/config.restore"; then
        failed=true
      elif ! mv -f "$tx/nodes.restore" "$XRAY_NODES" || ! mv -f "$tx/config.restore" "$XRAY_CONF"; then
        failed=true
      fi
      if $hop_touched; then hy2_hop_apply "$tx/hop.before" || failed=true; fi
      if ! $failed; then
        if $active; then
          run_with_progress 'Restarting Xray service' systemctl restart xray && systemctl is-active --quiet xray || failed=true
        else
          systemctl stop xray || failed=true
          if systemctl is-active --quiet xray; then failed=true; fi
        fi
      fi
      if $failed; then
        preserve=true
        err "ROLLBACK FAILED; recovery files retained at $tx"
      else
        err "candidate update failed; restored configuration and service state"
      fi
      status=1
    fi
    if ! $preserve; then rm -rf "$tx"; fi
    exit "$status"
  }
  trap transaction_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  "$prepare" "$XRAY_NODES" "$tx/nodes.json" "$@" || return 1
  render_config "$tx/nodes.json" "$tx/config.json" || return 1
  if ! validate_xray_config "$tx/config.json" "$tx/check.log"; then
    err "candidate Xray validation failed"; return 1
  fi
  hy2_hop_plan "$XRAY_NODES" > "$tx/hop.before" && hy2_hop_plan "$tx/nodes.json" > "$tx/hop.after" || return 1
  if ! cmp -s "$tx/hop.before" "$tx/hop.after"; then
    hop_changed=true
    hy2_hop_preflight "$tx/hop.after" || return 1
  fi
  cp -p "$XRAY_NODES" "$tx/nodes.backup" || return 1
  cp -p "$XRAY_CONF" "$tx/config.backup" || return 1
  # Copy attributes from each original before filling replacement contents.
  cp -p "$XRAY_NODES" "$tx/nodes.next" && cp -p "$XRAY_CONF" "$tx/config.next" || return 1
  cat "$tx/nodes.json" > "$tx/nodes.next" && cat "$tx/config.json" > "$tx/config.next" || return 1
  if systemctl is-active --quiet xray; then active=true; fi
  touched=true
  mv -f "$tx/nodes.next" "$XRAY_NODES" || return 1
  mv -f "$tx/config.next" "$XRAY_CONF" || return 1
  run_with_progress 'Restarting Xray service' systemctl restart xray && systemctl is-active --quiet xray || return 1
  if $hop_changed; then
    hop_touched=true
    hy2_hop_apply "$tx/hop.after" || return 1
  fi
  committed=true
)

# Inherit is a command, never a stored mode. Object travels on stdin.
prepare_outbound_assignment() {
  local source="$1" output="$2" id="$3" scope="${4:-all}" selected="${5:-[]}" outbound
  [[ "$scope" == all || "$scope" == selected ]] || return 1
  if [[ "$scope" == selected ]]; then validate_node_selection "$source" "$id" "$selected" || return 1; fi
  outbound=$(jq -c -s -e 'select(length == 1) | .[0]') || return 1
  [[ "$outbound" == '"inherit"' ]] || validate_outbound <<<"$outbound" || return 1
  validate_node_metadata "$source" || return 1
  jq -e --arg id "$id" 'any(.nodes[]; .id == $id)' "$source" >/dev/null || return 1
  printf '%s\n' "$outbound" | jq --slurpfile source "$source" --arg id "$id" --arg scope "$scope" --argjson selected "$selected" '
    . as $outbound | $source[0] |
    (.nodes[] | select(.id == $id)) |=
      if $scope == "all" then
        (del(.default_outbound) | if has("users") then .users |= map(del(.outbound)) else . end |
         if $outbound == "inherit" then del(.outbound) else .outbound = $outbound end)
      else
        (if $selected | index("default") then
           if $outbound == "inherit" then del(.default_outbound) else .default_outbound = $outbound end
         else . end |
         if has("users") then .users |= map(.id as $uid | if $selected | index($uid) then
           if $outbound == "inherit" then del(.outbound) else .outbound = $outbound end
         else . end) else . end)
      end' > "$output" || return 1
  validate_node_metadata "$output"
}

apply_outbound_assignment() {
  apply_candidate_transaction prepare_outbound_assignment "$@"
}

validate_node_selection() {
  jq -e --arg id "$2" --argjson selected "$3" '
    .nodes[] | select(.id == $id) |
    ["default", (.users // [])[].id] as $ids |
    ($selected | type == "array" and length > 0 and length == (unique|length)) and
    all($selected[]; . as $id | $ids | index($id) != null)' "$1" >/dev/null 2>&1
}

# Candidate mutation API: credentials travel on stdin, never external argv.
prepare_node_user_change() {
  local source="$1" output="$2" id="$3" action="$4" uid="${5:-}" payload
  validate_node_metadata "$source" || return 1
  jq -e --arg id "$id" 'any(.nodes[]; .id == $id)' "$source" >/dev/null || return 1
  case "$action" in
    add|reset) payload=$(jq -cse 'select(length == 1) | .[0]') || return 1 ;;
    delete)
      [[ "$uid" != default ]] || return 1
      jq -e --arg id "$id" --arg uid "$uid" '.nodes[] | select(.id == $id) | any((.users // [])[]; .id == $uid)' "$source" >/dev/null || return 1
      payload=null ;;
    *) return 1 ;;
  esac
  if [[ "$action" == reset ]] && jq -e --arg id "$id" '.nodes[] | select(.id == $id) | (.type == "vless-reality")' "$source" >/dev/null; then
    jq -e 'type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")' <<<"$payload" >/dev/null || return 1
  fi
  printf '%s\n' "$payload" | jq --slurpfile source "$source" --arg id "$id" --arg uid "$uid" --arg action "$action" '
    . as $payload | $source[0] | (.nodes[] | select(.id == $id)) |=
    if $action == "add" then .users = ((.users // []) + [$payload])
    elif $action == "delete" then .users |= map(select(.id != $uid))
    elif .type == "vless-reality" then .uuid = $payload
    else .password = $payload end' > "$output" || return 1
  validate_node_metadata "$output"
}

apply_node_user_change() {
  apply_candidate_transaction prepare_node_user_change "$@"
}

node_user_link() {
  local n="$1" uid="$2" selected
  if [[ "$uid" == default ]]; then node_link "$n"; return; fi
  selected=$(jq -ce --arg uid "$uid" '. as $n | (.users // [])[] | select(.id == $uid) |
    . as $u | $n | .name += (" / " + $u.name) |
    if .type == "vless-reality" then .uuid = $u.uuid else .password = $u.password end' <<<"$n") || return 1
  node_link "$selected"
}

list_node_users() {
  jq -r '[{id:"default",name:"Default client (reserved; cannot delete)"}] + (.users // []) |
    to_entries[] | "\(.key + 1)) \(.value.name) [\(.value.id)]"' <<<"$1"
}

# Number selection is validated as one batch before any transaction.
pick_node_users() {
  local n="$1" answer ids
  list_node_users "$n" >&2
  ids=$(jq -c '["default", (.users // [])[].id]' <<<"$n") || return 1
  answer=$(ask 'User numbers (space separated, Enter to cancel)') || return 1
  printf '%s\n' "$answer" | jq -Rce --argjson ids "$ids" '
    split(" ") | map(select(length > 0)) as $tokens |
    if ($tokens|length) > 0 and all($tokens[]; test("^[1-9][0-9]*$")) then
      $tokens | map(tonumber) |
      if all(.[]; . <= ($ids|length)) and length == (unique|length) then
        map($ids[. - 1]) else error("invalid selection") end
    else error("invalid selection") end' 2>/dev/null
}

manage_node_users() {
  local id="$1" n action name uid credential payload selected
  while :; do
    n=$(node_by_id "$id") || return 1
    printf '\nUsers:\n'
    list_node_users "$n"
    printf '\nUser actions:\n1) Add user\n3) Show user share link\n\nDanger zone:\n2) Delete user\n\n0) Back\n'
    action=$(ask 'Select')
    case "$action" in
      1)
        name=$(ask 'User name (Enter to cancel)'); [[ -n "$name" ]] || continue
        uid=$(openssl rand -hex 8) || return 1
        if jq -e '.type == "vless-reality"' <<<"$n" >/dev/null; then
          credential=$(rand_uuid) || return 1
          payload=$(printf '%s\n' "$credential" | jq -Rc --arg id "$uid" --arg name "$name" '{id:$id,name:$name,uuid:.}') || return 1
        else
          credential=$(rand_password) || return 1
          payload=$(printf '%s\n' "$credential" | jq -Rc --arg id "$uid" --arg name "$name" '{id:$id,name:$name,password:.}') || return 1
        fi
        apply_node_user_change "$id" add <<<"$payload" || { err 'user not added'; continue; }
        ok 'user added' ;;
      2|3)
        selected=$(pick_node_users "$n") || continue
        [[ $(jq length <<<"$selected") == 1 ]] || { warn 'select exactly one user'; continue; }
        uid=$(jq -r '.[0]' <<<"$selected")
        if [[ "$action" == 3 ]]; then node_user_link "$n" "$uid" || warn 'Share link unavailable'; pause; continue; fi
        [[ "$uid" != default ]] || { warn 'default client cannot be deleted'; continue; }
        name=$(jq -r --arg uid "$uid" '.users[] | select(.id == $uid) | .name' <<<"$n")
        confirm "Delete user $name from node $(jq -r '.name' <<<"$n")? Its credential will stop working." n || continue
        apply_node_user_change "$id" delete "$uid" || { err 'user not deleted'; continue; }
        ok 'user deleted' ;;
      *) return 0 ;;
    esac
  done
}

manage_outbound() {
  local id="$1" action link='' outbound scope selected='[]' n
  n=$(node_by_id "$id") || return 1
  printf '1) All users (overwrite every individual outbound)\n2) Selected users\n0) Cancel\n'
  case "$(ask 'Scope')" in
    1) scope=all ;;
    2) scope=selected; selected=$(pick_node_users "$n") || return 0 ;;
    *) return 0 ;;
  esac
  info 'Restore default means inherit for selected users; direct for all users.'
  printf '1) Restore default\n2) Explicit direct\n3) Proxy link\n0) Cancel\n'
  action=$(ask 'Select')
  case "$action" in
    1) outbound='"inherit"' ;;
    2) outbound='{"mode":"direct"}' ;;
    3)
      printf 'Proxy link (Enter to cancel): ' >&2
      IFS= read -r link || return 1
      printf '\n' >&2
      [[ -n "$link" ]] || return 0
      outbound=$(printf '%s\n' "$link" | parse_outbound_link) || { err 'invalid or unsupported proxy link'; return 1; }
      link='' ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$outbound" | jq -r 'if . == "inherit" then "Default" elif .mode == "direct" then "Explicit direct" else "\(.protocol) \(.server):\(.port)" end'
  confirm 'Apply outbound setting?' n || return 0
  if apply_outbound_assignment "$id" "$scope" "$selected" <<<"$outbound"; then ok 'outbound applied'
  else err 'outbound not applied'; return 1; fi
}

# ----------------------------------------------------------------------------
# Caddy certificate ownership and private Xray deployment.
# ----------------------------------------------------------------------------

acme_domain_valid() {
  [[ ${#1} -le 253 && "$1" == *.* && "$1" != *..* && "$1" != *[!a-z0-9.-]* ]] || return 1
  local label
  local -a labels
  IFS=. read -r -a labels <<< "$1"
  [[ "$1" != *. ]] || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
  done
}

# Caddy owns issuance/renewal; OneVPS only deploys validated pairs to Xray.
CADDY_STATE=/etc/onevps-caddy
CADDY_SYNC_RUNNER=/usr/local/lib/onevps/caddy-sync.sh

caddy_state_init() {
  if [[ ! -f "$CADDY_STATE/.onevps-owned" ]]; then
    [[ ! -e "$CADDY_STATE" && ! -L "$CADDY_STATE" ]] || { err 'unmanaged Caddy state directory'; return 1; }
    mkdir -p "$CADDY_STATE" && touch "$CADDY_STATE/.onevps-owned" || return 1
  fi
  [[ ! -L "$CADDY_STATE" ]] || return 1
  chmod 755 "$CADDY_STATE" || return 1
  [[ "${1:-}" != static ]] || return 0
  mkdir -p "$CADDY_STATE/domains" "$CADDY_STATE/staging" "$ACME_CERT_DIR" || return 1
  chmod 700 "$CADDY_STATE/domains" || return 1
  chmod 750 "$ACME_CERT_DIR" && chown root:"$(id -gn nobody)" "$ACME_CERT_DIR" || return 1
}

# Read the configured storage, or the actual running service's environment.
# Refuse non-filesystem storage rather than guessing where private keys live.
caddy_storage_root() {
  local file="$1" config root pid home xdg entry
  config=$(caddy adapt --adapter caddyfile --config "$file" 2>/dev/null) || return 1
  if jq -e '.storage != null' <<< "$config" >/dev/null; then
    root=$(jq -er 'select(.storage.module == "file_system") | .storage.root | select(startswith("/"))' <<< "$config") || {
      err 'certificate sync requires local Caddy file_system storage with an absolute root'; return 1;
    }
  else
    pid=$(systemctl show caddy -p MainPID --value) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/environ" ]] || { err 'cannot inspect running Caddy storage environment'; return 1; }
    home='' xdg=''
    while IFS= read -r -d '' entry; do
      case "$entry" in HOME=*) home=${entry#HOME=};; XDG_DATA_HOME=*) xdg=${entry#XDG_DATA_HOME=};; esac
    done < "/proc/$pid/environ"
    if [[ -n "$xdg" ]]; then root="$xdg/caddy"; else root="$home/.local/share/caddy"; fi
    [[ "$root" == /* && -n "${xdg:-$home}" ]] || return 1
  fi
  [[ "$root" != *'{'* && "$root" != *$'\n'* && -d "$root" ]] || return 1
  printf '%s\n' "$root"
}

# OneVPS deliberately reserves UDP 443 for HY2 on the shared HTTPS listener.
caddy_tcp_https() {
  local file="$1" tmp
  grep -qx '# OneVPS TCP-only HTTPS' "$file" && return 0
  warn 'Caddy shares :443 with existing sites. HTTP/3 on this listener will be disabled; HTTP/1.1 and HTTP/2 remain enabled.'
  confirm 'Reserve UDP 443 for HY2 on this Caddy listener?' n || return 1
  tmp=$(mktemp) || return 1
  awk '
    function settings() {print "# OneVPS TCP-only HTTPS\n    servers :443 {\n        protocols h1 h2\n    }"}
    !seen && /^[[:space:]]*(#.*)?$/ {print; next}
    !seen {seen=1; if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) {print; settings(); next}
      print "{"; settings(); print "}"}
    {print}
    END {if (!seen) {print "{"; settings(); print "}"}}
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! (cd -- "$(dirname -- "$file")" && caddy adapt --adapter caddyfile --config -) < "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; err 'existing Caddy global options conflict; configuration was not changed'; return 1
  fi
  cat "$tmp" > "$file" || { rm -f "$tmp"; err 'cannot write Caddy HTTPS settings'; return 1; }
  rm -f "$tmp"
}

caddy_restore_site() {
  local backup="$1" file="$2" reload="$3"
  if ! cp -p "$backup" "$file"; then
    err "Cannot restore Caddyfile; backup retained: $backup"
  elif [[ "$reload" == true ]] && ! caddy_reload "$file"; then
    err "Caddyfile restored but reload failed; backup retained: $backup"
  else
    rm -f "$backup"
    return
  fi
  return 1
}

caddy_domain_ensure() {
  local domain="$1" file="$2" mode="${3:-certificate}" backup site_root record static_record occupied probe
  acme_domain_valid "$domain" || return 1
  record="$CADDY_STATE/domains/$domain.json"
  static_record="$CADDY_STATE/sites/$domain.json"
  if [[ -f "$record" || -f "$static_record" ]]; then
    local existing="$record"
    [[ -f "$existing" ]] || existing="$static_record"
    jq -e --arg file "$file" '.caddy_file == $file' "$existing" >/dev/null &&
      [[ $(grep -cxF "# OneVPS-domain:$domain BEGIN" "$file") == 1 ]] &&
      [[ $(grep -cxF "# OneVPS-domain:$domain END" "$file") == 1 ]] &&
      grep -qxF "$domain {" "$file" || return 1
    ensure_site_content "$domain" || return 1
    if [[ "$mode" == certificate && ! -f "$record" ]]; then
      caddy_storage_root "$file" >/dev/null || return 1
      jq '{caddy_file}' "$existing" > "$record.next" && mv "$record.next" "$record" || return 1
    fi
    return 0
  fi
  probe="onevps-listener-$(openssl rand -hex 12).invalid"
  occupied=$(cd -- "$(dirname -- "$file")" &&
    { cat -- "$(basename -- "$file")" && printf '\n%s {\n respond 204\n}\n' "$probe"; } |
    caddy adapt --adapter caddyfile --config - | jq -er --arg domain "$domain" --arg probe "$probe" '
    def covers($name): ascii_downcase | rtrimstr(".") | split(".") as $pattern |
      ($name | split(".")) as $labels | ($pattern | length) == ($labels | length) and
      all(range(0; $labels | length); . as $idx | $pattern[$idx] == "*" or $pattern[$idx] == $labels[$idx]);
    def hosts: .routes[]? | recurse(.handle[]?.routes[]?) | .match[]?.host[]?;
    def endpoint: capture("^(?:(?<net>tcp[46]?)/)?(?<addr>[^/]*):(?<port>[0-9]+)$");
    def families: if .net=="tcp4" then [4] elif .net=="tcp6" then [6]
      elif .addr=="" or .addr=="[::]" then [4,6] elif (.addr|startswith("[")) then [6] else [4] end;
    def wildcard: . == "" or . == "0.0.0.0" or . == "[::]";
    def overlaps($old): .port==$old.port and any(families[]; . as $family | ($old|families|index($family))!=null) and
      (.addr==$old.addr or (.addr|wildcard) or ($old.addr|wildcard));
    [.apps.http.servers[]?] as $servers |
    [$servers[] | select(any(hosts; . == $probe)) | .listen[] | endpoint] as $target |
    if ($target|length)==0 then error("unknown site listener") else
      any($servers[] | select(any(.listen[] | endpoint; . as $old | any($target[]; overlaps($old)))) | hosts;
        . != $probe and covers($domain)) | tostring end') || {
    err 'Cannot inspect existing Caddy routes'; return 1;
  }
  if [[ "$occupied" == true ]]; then err "unmanaged Caddy route already matches $domain"; return 1; fi
  if [[ "$mode" == static ]]; then
    mkdir -p "$CADDY_STATE/sites" || return 1
    record="$static_record"
  else
    caddy_storage_root "$file" >/dev/null || return 1
  fi
  site_root=$(caddy_site_root "$domain")
  ensure_site_content "$domain" || return 1
  backup=$(mktemp "$CADDY_STATE/.domain.XXXXXXXX") || return 1
  cp -p "$file" "$backup" || { rm -f "$backup"; return 1; }
  if ! cat >> "$file" <<EOF_SITE

# OneVPS-domain:$domain BEGIN
$domain {
    root * $site_root
    handle {
        error 403
    }
    handle_errors {
        rewrite * /index.html
        file_server
    }
}
# OneVPS-domain:$domain END
EOF_SITE
  then
    err 'Cannot write Caddy site configuration'
    caddy_restore_site "$backup" "$file" false || return 1
    return 1
  fi
  if ! caddy_reload "$file"; then
    caddy_restore_site "$backup" "$file" true || return 1
    return 1
  fi
  if ! jq -n --arg file "$file" '{caddy_file:$file}' > "$record"; then
    err "Cannot write Caddy site record: $record"
    if ! rm -f "$record"; then err "Cannot remove incomplete site record: $record"; fi
    caddy_restore_site "$backup" "$file" true || return 1
    return 1
  fi
  rm -f "$backup"
}

setup_static_site() (
  local domain file listeners listener pid
  domain=$(normalize_domain "$(ask 'Static site domain (DNS must point to this VPS)')")
  acme_domain_valid "$domain" || { err 'Enter a valid domain name'; return 1; }
  ensure_deps || return 1
  if [[ -f "$XRAY_NODES" ]]; then
    local reserved
    reserved=$(jq -r 'any(.nodes[]; .enabled and .type=="vless-reality" and (.port==443 or .port==80))' "$XRAY_NODES") || {
      err 'Cannot read Xray node reservations'; return 1;
    }
    if [[ "$reserved" == true ]]; then err 'A Reality node uses TCP 80 or 443; static site setup cancelled'; return 1; fi
  fi
  listeners=$(ss -H -ltnp '( sport = :80 or sport = :443 )') || { err 'Cannot check TCP listeners (ss required)'; return 1; }
  pid=$(systemctl show caddy -p MainPID --value 2>/dev/null) || pid=''
  while IFS= read -r listener; do
    [[ -z "$listener" ]] && continue
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$listener" == *"pid=$pid,"* ]] || {
      err "TCP 80 or 443 is occupied by another service; static site setup cancelled"; return 1;
    }
  done <<< "$listeners"
  caddy_state_init static || return 1
  exec 9> "$CADDY_STATE/operation.lock" || return 1
  flock -n 9 || { err 'another Caddy operation is running'; return 1; }
  ensure_caddy || return 1
  file=$(find_caddyfile)
  [[ -f "$file" && ! -L "$file" ]] || { err 'Missing or unsupported Caddyfile'; return 1; }
  caddy_domain_ensure "$domain" "$file" static || return 1
  open_port 80 tcp && open_port 443 tcp || return 1
  systemctl is-active --quiet caddy || { err 'Caddy is not active; static site unavailable'; return 1; }
  ok "Static site configured: https://$domain (HTTP 403 after certificate issuance)"
  info "Edit $(caddy_site_root "$domain")/index.html; allow TCP 80/443 in your cloud firewall."
)

caddy_sync_domain() {
  local domain="$1" file root cert key found=false stage="$CADDY_STATE/staging/$1"
  acme_domain_valid "$domain" || return 1
  file=$(jq -er '.caddy_file' "$CADDY_STATE/domains/$domain.json") || return 1
  root=$(caddy_storage_root "$file") || return 1
  mkdir -p "$stage" || return 1
  # Check all issuers; never hardcode Let's Encrypt or copy Caddy's whole store.
  for cert in "$root/certificates/"*/"$domain/$domain.crt"; do
    [[ -f "$cert" && ! -L "$cert" ]] || continue
    key="${cert%.crt}.key"
    [[ -f "$key" && ! -L "$key" ]] || continue
    cp "$cert" "$stage/fullchain.pem" && cp "$key" "$stage/key.pem" || return 1
    chmod 600 "$stage/fullchain.pem" "$stage/key.pem" || return 1
    if validate_hy2_pem "$domain" "$stage/fullchain.pem" "$stage/key.pem"; then found=true; break; fi
  done
  $found || { err "Caddy certificate not ready for $domain; check DNS, TCP 80/443 and Caddy logs"; return 1; }
  acme_deploy "$domain"
}

caddy_sync_all() (
  [[ -f "$CADDY_STATE/.onevps-owned" ]] || return 0
  exec 9> "$CADDY_STATE/operation.lock" || { err 'Cannot open certificate sync lock'; return 1; }
  local meta failed=0 lock_status
  if flock -n 9; then :; else
    lock_status=$?
    if ((lock_status == 1)); then return 0; fi
    err "Cannot lock certificate sync (exit $lock_status)"; return "$lock_status"
  fi
  for meta in "$CADDY_STATE/domains/"*.json; do
    [[ -f "$meta" ]] || continue
    caddy_sync_domain "$(basename "$meta" .json)" || failed=1
  done
  return "$failed"
)

validate_onevps_script() {
  local file="$1" first_line
  [[ -f "$file" && -s "$file" ]] && IFS= read -r first_line < "$file" &&
    [[ "$first_line" == '#!/usr/bin/env bash' ]] && grep -Fxq 'caddy_sync_all() (' "$file" &&
    grep -Fxq 'main() {' "$file" && [[ $(tail -n 1 "$file") == 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi' ]] &&
    bash -n "$file"
}

caddy_sync_install() (
  local runner_work='' units service="$ACME_UNIT_DIR/onevps-caddy-sync.service" timer="$ACME_UNIT_DIR/onevps-caddy-sync.timer"
  local published=0 complete=false activation_started=false was_enabled=false was_active=false index
  local -a targets backups staged
  if [[ ! -f "$ONEVPS_SCRIPT_PATH" || ! -s "$ONEVPS_SCRIPT_PATH" ]]; then
    err 'Certificate sync requires the complete onevps.sh file. Download it before running bash.'; return 1
  fi
  if [[ -d "$service" || -d "$timer" ]]; then err 'Certificate sync unit path is a directory'; return 1; fi
  mkdir -p "$(dirname "$CADDY_SYNC_RUNNER")" || return 1
  units=$(mktemp -d "$ACME_UNIT_DIR/.onevps-caddy-sync.XXXXXXXX") || return 1
  sync_publish_cleanup() {
    local result=$? restored=true entry
    trap - EXIT INT TERM HUP
    if ! $complete; then
      if $activation_started; then
        if ! $was_enabled && systemctl is-enabled --quiet onevps-caddy-sync.timer; then
          systemctl disable onevps-caddy-sync.timer || restored=false
        fi
        if ! $was_active && systemctl is-active --quiet onevps-caddy-sync.timer; then
          systemctl stop onevps-caddy-sync.timer || restored=false
        fi
      fi
      for ((entry=published-1; entry>=0; entry--)); do
        if [[ -e "${backups[entry]}" || -L "${backups[entry]}" ]]; then
          mv -Tf "${backups[entry]}" "${targets[entry]}" || restored=false
        else
          rm -f "${targets[entry]}" || restored=false
        fi
      done
      if $activation_started; then
        systemctl daemon-reload || restored=false
        if $was_enabled; then systemctl enable onevps-caddy-sync.timer || restored=false; fi
        if $was_active; then systemctl start onevps-caddy-sync.timer || restored=false; fi
      fi
    fi
    if ! $restored; then
      err "Certificate sync rollback failed; recovery directories retained: $units and $runner_work"
      exit 1
    fi
    rm -rf "$units"
    if [[ -n "$runner_work" ]]; then rm -rf "$runner_work"; fi
    exit "$result"
  }
  trap sync_publish_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  runner_work=$(mktemp -d "${CADDY_SYNC_RUNNER}.XXXXXXXX") || return 1
  targets=("$CADDY_SYNC_RUNNER" "$service" "$timer")
  backups=("$runner_work/runner.backup" "$units/service.backup" "$units/timer.backup")
  staged=("$runner_work/runner" "$units/sync.service" "$units/sync.timer")
  if ! cat "$ONEVPS_SCRIPT_PATH" > "${staged[0]}" || ! validate_onevps_script "${staged[0]}"; then
    err 'Incomplete OneVPS script; certificate sync runner not installed'; return 1
  fi
  cat > "$units/sync.service" <<EOF_SERVICE || return 1
[Unit]
Description=Deploy Caddy certificates to OneVPS Xray
After=caddy.service
[Service]
Type=oneshot
ExecStart=/bin/bash $CADDY_SYNC_RUNNER --caddy-sync
UMask=0077
EOF_SERVICE
  cat > "$units/sync.timer" <<'EOF_TIMER' || return 1
[Unit]
Description=Check Caddy certificate deployment every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true
[Install]
WantedBy=timers.target
EOF_TIMER
  chmod 644 "${staged[1]}" "${staged[2]}" && chmod 700 "${staged[0]}" || return 1
  for index in "${!targets[@]}"; do
    if [[ -e "${targets[index]}" || -L "${targets[index]}" ]]; then
      cp -pP "${targets[index]}" "${backups[index]}" || return 1
    fi
  done
  systemctl is-enabled --quiet onevps-caddy-sync.timer && was_enabled=true
  systemctl is-active --quiet onevps-caddy-sync.timer && was_active=true
  for index in "${!targets[@]}"; do
    published=$((index + 1))
    mv -Tf "${staged[index]}" "${targets[index]}" || { err 'Cannot publish certificate sync files'; return 1; }
  done
  activation_started=true
  systemctl daemon-reload && systemctl enable --now onevps-caddy-sync.timer || {
    err 'Cannot activate certificate sync timer'; return 1;
  }
  complete=true
)

caddy_certificate_issue() (
  local domain="$1" file i
  acme_domain_valid "$domain" || return 1
  prepare_caddy_for_certificates || return 1
  exec 9> "$CADDY_STATE/operation.lock"
  flock -n 9 || { err 'another Caddy certificate operation is running'; return 1; }
  file=$(find_caddyfile)
  caddy_domain_ensure "$domain" "$file" || return 1
  open_port 80 tcp && open_port 443 tcp || return 1
  for ((i=0; i<30; i++)); do
    if caddy_sync_domain "$domain"; then return 0; fi
    sleep 2
  done
  err 'Caddy issuance is still pending; retry from Certificates after checking Caddy logs'
  return 1
)

prepare_caddy_for_certificates() (
  local file backup active=false enabled=false committed=false
  caddy_state_init || return 1
  exec 8> "$CADDY_STATE/operation.lock"
  flock -n 8 || { err 'another Caddy operation is running'; return 1; }
  file=$(find_caddyfile)
  backup=$(mktemp -d "$CADDY_STATE/backup.XXXXXXXX") || return 1
  [[ -z "$file" ]] || cp -p "$file" "$backup/Caddyfile" || return 1
  systemctl is-active --quiet caddy && active=true
  systemctl is-enabled --quiet caddy && enabled=true
  rollback_caddy_setup() {
    local status=$? failed=false current
    trap - EXIT INT TERM HUP
    if ! $committed; then
      status=1
      current=$(find_caddyfile)
      if [[ -f "$backup/Caddyfile" ]]; then cp -p "$backup/Caddyfile" "$file" || failed=true
      elif [[ -n "$current" ]]; then rm -f "$current" || failed=true; fi
      if $active; then caddy_reload "$file" || failed=true
      else systemctl stop caddy || failed=true; fi
      if ! $enabled; then systemctl disable caddy || failed=true; fi
      err "Caddy setup failed; backup retained: $backup"
    else rm -rf "$backup"; fi
    if $failed; then err 'rollback incomplete; inspect retained backup'; exit 1; fi
    exit "$status"
  }
  trap rollback_caddy_setup EXIT
  trap 'exit 1' INT TERM HUP
  ensure_caddy || return 1
  file=$(find_caddyfile)
  [[ -n "$file" && ! -L "$file" ]] || return 1
  caddy_tcp_https "$file" || return 1
  caddy_reload "$file" || return 1
  caddy_sync_install || return 1
  committed=true
)

# Switch a symlink to a complete key/cert pair, retaining the previous pair on failure.
acme_deploy() (
  local domain="$1" stage="$CADDY_STATE/staging/$1" dir="$ACME_CERT_DIR/$1"
  local version previous='' active=false switched=false committed=false used=false check_log ng
  acme_domain_valid "$domain" || return 1
  validate_hy2_pem "$domain" "$stage/fullchain.pem" "$stage/key.pem" || return 1
  ng=$(id -gn nobody) || return 1
  mkdir -p "$dir" || return 1
  chown root:"$ng" "$dir" && chmod 750 "$dir" || return 1
  if [[ -L "$dir/current" ]]; then previous=$(readlink "$dir/current") || return 1
  elif [[ -e "$dir/current" ]]; then err 'refusing unmanaged current certificate'; return 1; fi
  version=$(mktemp -d "$dir/cert.XXXXXXXX") || return 1
  check_log="$version/check.log"
  deploy_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $switched && ! $committed; then
      if [[ -n "$previous" ]]; then
        ln -s "$previous" "$version/rollback" && mv -Tf "$version/rollback" "$dir/current" || failed=true
      else rm -f "$dir/current" || failed=true; fi
      if $active; then systemctl restart xray && systemctl is-active --quiet xray || failed=true; fi
      if $failed; then
        touch "$version/.recovery-required" || err "Cannot mark certificate recovery directory: $version"
        err "certificate rollback failed; retained $version"; exit 1
      fi
    fi
    if ! $committed; then rm -rf "$version"; fi
    exit "$status"
  }
  trap deploy_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  install -m 640 "$stage/fullchain.pem" "$version/fullchain.pem" &&
    install -m 640 "$stage/key.pem" "$version/key.pem" || return 1
  chown -R root:"$ng" "$version" && chmod 750 "$version" || return 1
  if [[ -n "$previous" ]] && cmp -s "$version/fullchain.pem" "$dir/current/fullchain.pem" &&
    cmp -s "$version/key.pem" "$dir/current/key.pem"; then return 0; fi
  xray_write_lock || return 1
  if [[ -e "$XRAY_NODES" ]]; then
    used=$(jq -sr --arg path "$dir/current/fullchain.pem" '
      if length==1 and (.[0].nodes | type=="array") and
        all(.[0].nodes[]; type=="object" and (.enabled|type=="boolean") and
          (if has("tls_cert") then .tls_cert|type=="string" and startswith("/") else true end))
      then any(.[0].nodes[]; .enabled==true and .tls_cert==$path)
      else error("invalid node metadata") end' "$XRAY_NODES") || { err 'Cannot determine which nodes use the certificate'; return 1; }
  fi
  if $used && systemctl is-active --quiet xray; then active=true; fi
  ln -s "$(basename "$version")" "$version/next" || return 1
  switched=true
  # GNU mv -T replaces the symlink itself, never follows it as a directory.
  mv -Tf "$version/next" "$dir/current" || return 1
  if $used; then validate_xray_config "$XRAY_CONF" "$check_log" || return 1; fi
  if $active; then systemctl restart xray && systemctl is-active --quiet xray || return 1; fi
  committed=true
  rm -f "$check_log"
  local old
  for old in "$dir/"cert.*; do
    [[ -d "$old" && ! -L "$old" && "$old" != "$version" && "$(basename "$old")" != "$previous" ]] || continue
    [[ ! -e "$old/.recovery-required" && ! -L "$old/rollback" ]] || continue
    rm -rf "$old"
  done
  ok "certificate deployed: $domain"
)

certificate_menu() {
  local choice domain file
  while :; do
    printf '\nCertificates (Caddy-managed)\n1) Status / expiry\n2) Apply certificate (domain only)\n3) Check renewals / retry deployment\n4) Renewal logs\n0) Back\n'
    choice=$(ask 'Select')
    case "$choice" in
      0|'') return ;;
      1)
        if [[ -f "$CADDY_STATE/.onevps-owned" ]]; then
          systemctl --no-pager status onevps-caddy-sync.timer || true
          for file in "$ACME_CERT_DIR/"*/current/fullchain.pem; do
            [[ -f "$file" ]] || continue
            printf '\n%s\n' "$file"; openssl x509 -in "$file" -noout -subject -dates || true
          done
        else info 'no OneVPS Caddy certificate setup'; fi ;;
      2)
        domain=$(normalize_domain "$(ask 'Domain')")
        caddy_certificate_issue "$domain" || err 'certificate was not deployed' ;;
      3) caddy_sync_all || err 'renewal failed; see logs' ;;
      4) journalctl -u caddy -u onevps-caddy-sync.service --no-pager -n 60 || true ;;
      *) warn 'invalid selection' ;;
    esac
  done
}

require_hy2_core() {
  local version minimum major minor patch status
  if version=$("$XRAY_BIN" version); then
    # Consume all output before selecting the first line to avoid SIGPIPE.
    version=${version%%$'\n'*}
  else
    status=$?
    err "Cannot read Xray version from $XRAY_BIN (exit $status); Hysteria2 setup aborted"
    return 1
  fi
  if [[ "$version" =~ ^Xray[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major=$((10#${BASH_REMATCH[1]})); minor=$((10#${BASH_REMATCH[2]})); patch=$((10#${BASH_REMATCH[3]}))
    minimum=$((26 * 10000 + 10 * 100 + 21))
    (( major * 10000 + minor * 100 + patch >= minimum )) && return 0
  else
    err "Cannot parse Xray version: ${version:-<empty output>}; Hysteria2 setup aborted"
    return 1
  fi
  err "Hysteria2 requires tested Xray >= $HY2_MIN_VERSION; update Xray first"
  return 1
}

validate_hy2_certificate() {
  local domain="$1" cert="$2" key="$3" path
  for path in "$cert" "$key"; do
    [[ "$path" == /* && -f "$path" && -r "$path" ]] || { err 'certificate/key must be readable absolute file paths'; return 1; }
    case "$path" in
      /root/*|/home/*|/run/user/*|/tmp/*|/var/tmp/*)
        err 'certificate/key path is hidden by the Xray systemd sandbox; use a persistent path under /etc'; return 1 ;;
    esac
    path=$(readlink -f -- "$path") || return 1
    case "$path" in
      /root/*|/home/*|/run/user/*|/tmp/*|/var/tmp/*)
        err 'certificate/key path is hidden by the Xray systemd sandbox; use a persistent path under /etc'; return 1 ;;
    esac
    runuser -u nobody -- test -r "$path" || { err 'certificate/key must be readable by nobody (including parent directories)'; return 1; }
  done
  validate_hy2_pem "$domain" "$cert" "$key"
}

validate_hy2_pem() {
  local domain="$1" cert="$2" key="$3" cert_pub key_pub
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 &&
    openssl verify -partial_chain -trusted "$cert" "$cert" >/dev/null 2>&1 &&
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || {
      err 'certificate is outside its validity period, invalid or does not match the domain'; return 1;
    }
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
  key_pub=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || return 1
  [[ "$cert_pub" == "$key_pub" ]] || { err 'certificate and unencrypted private key do not match'; return 1; }
}

hy2_hop_plan() {
  jq -r '
    def ranges: split(",") | map(split("-") | map(tonumber) | [first,last]);
    [.nodes[] | select(has("hopping")) | . as $node | .hopping |
      if $node.type != "hysteria2" or (.interface | type != "string" or
          (test("^[a-zA-Z0-9_-][a-zA-Z0-9_.-]{0,14}\\z") | not) or . == "lo") or
         (.ports | type != "string" or (test("^[1-9][0-9]{0,4}(-[1-9][0-9]{0,4})?(,[1-9][0-9]{0,4}(-[1-9][0-9]{0,4})?)*\\z") | not))
      then error("invalid HY2 hopping interface or port list") else . end |
      (.ports | ranges) as $ranges |
      if any($ranges[]; .[0] > .[1] or .[1] > 65535) or
         ([$ranges[] | .[1] - .[0] + 1] | add) < 2 then error("invalid HY2 hopping range") else . end |
      {interface,ports, ranges:$ranges, target:$node.port, enabled:$node.enabled}] as $hops |
    if ($hops | length) > 0 then
      ([.nodes[] | select(.type == "hysteria2") | [.port,.port]] + [$hops[].ranges[]] | sort) as $all |
      if any(range(1; $all|length); . as $idx | $all[$idx][0] <= $all[$idx-1][1])
      then error("overlapping HY2 listening or hopping ports") else
        $hops[] | select(.enabled) | [.interface,.ports,.target] | @tsv end
    else empty end' "$1"
}

hy2_hop_rules() {
  local iface ports target
  printf '%s\n' 'table ip onevps_hy2_hop {' '  comment "Managed by OneVPS"' \
    '  chain ingress {' '    type nat hook prerouting priority dstnat; policy accept;'
  while IFS=$'\t' read -r iface ports target; do
    printf '    iifname "%s" fib daddr type local udp dport { %s } counter redirect to :%s\n' "$iface" "$ports" "$target"
  done < "$1"
  printf '%s\n' '  }' '}'
}

hy2_hop_owned() {
  [[ ! -L "$HY2_HOP_DIR" && ! -L "$HY2_HOP_UNIT" ]] &&
    { [[ ! -e "$HY2_HOP_DIR" ]] || [[ -f "$HY2_HOP_DIR/.onevps-managed" ]]; } &&
    { [[ ! -e "$HY2_HOP_UNIT" ]] || grep -qxF '# Managed by OneVPS HY2' "$HY2_HOP_UNIT"; } || {
    err 'refusing to overwrite unmanaged HY2 hopping files'; return 1;
  }
  local path
  for path in "$HY2_HOP_DIR/.onevps-managed" "$HY2_HOP_DIR/rules.nft" "$HY2_HOP_DIR/rules.next" "$HY2_HOP_UNIT"; do
    if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
      err "Unsupported HY2 hopping file type: $path"; return 1
    fi
  done
}

hy2_hop_table_delete_rule() {
  local tables
  command -v nft >/dev/null || { err 'HY2 hopping requires nft (install nftables)'; return 1; }
  tables=$(nft list tables) || return 1
  if grep -Fxq 'table ip onevps_hy2_hop' <<<"$tables"; then
    if [[ ! -f "$HY2_HOP_DIR/.onevps-managed" ]] || ! nft -j list table ip onevps_hy2_hop |
      jq -e 'any(.nftables[].table?; .family=="ip" and .name=="onevps_hy2_hop" and .comment=="Managed by OneVPS")' >/dev/null; then
      err 'nft table ip onevps_hy2_hop is not owned by OneVPS'; return 1;
    fi
    printf 'delete table ip onevps_hy2_hop\n'
  fi
}

hy2_hop_preflight() {
  local iface ports target sockets occupied relay_ports
  hy2_hop_owned && hy2_hop_table_delete_rule >/dev/null || return 1
  [[ -s "$1" ]] || return 0
  sockets=$(ss -H -uan) || return 1
  occupied=$(awk '{print $4}' <<<"$sockets") || return 1
  if [[ -f "$REALM_DIR/config.json" ]]; then
    relay_ports=$(jq -r '.endpoints[] | select(.network.use_udp) | .listen' "$REALM_DIR/config.json") || return 1
    occupied+=$'\n'"$relay_ports"
  fi
  while IFS=$'\t' read -r iface ports target; do
    ip link show dev "$iface" >/dev/null || return 1
    if ! awk -v ports="$ports" 'BEGIN {count=split(ports,items,",")}
      {port=$0; sub(/^.*:/,"",port); if (port !~ /^[0-9]+$/) next;
       for (idx=1;idx<=count;idx++) {split(items[idx],bounds,"-");
         if (+port >= +bounds[1] && +port <= +(bounds[2] ? bounds[2] : bounds[1])) exit 1}}' <<<"$occupied"; then
      err 'a hopping port is reserved by a UDP socket or Realm relay'; return 1
    fi
  done < "$1"
}

hy2_hop_apply() (
  local plan="$1" batch nft_bin
  hy2_hop_owned || return 1
  batch=$(mktemp) || return 1
  trap 'rm -f "$batch"' EXIT
  hy2_hop_table_delete_rule > "$batch" || return 1
  if [[ -s "$plan" ]]; then
    hy2_hop_rules "$plan" >> "$batch" || return 1
    nft -c -f "$batch" || return 1
    nft_bin=$(type -P nft) || return 1
    if [[ ! -d "$HY2_HOP_DIR" ]]; then
      mkdir -m 700 "$HY2_HOP_DIR" && touch "$HY2_HOP_DIR/.onevps-managed" || return 1
    fi
    hy2_hop_rules "$plan" > "$HY2_HOP_DIR/rules.next" && mv "$HY2_HOP_DIR/rules.next" "$HY2_HOP_DIR/rules.nft" || return 1
    if [[ ! -e "$HY2_HOP_UNIT" ]]; then
      cat > "$HY2_HOP_UNIT" <<EOF || return 1
# Managed by OneVPS HY2
[Unit]
Description=OneVPS HY2 UDP port hopping
After=nftables.service firewalld.service ufw.service
Before=xray.service
[Service]
Type=oneshot
ExecStart=$nft_bin -f $HY2_HOP_DIR/rules.nft
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload || return 1
    fi
    systemctl enable onevps-hy2-hop.service >/dev/null || return 1
    nft -f "$batch" || return 1
  else
    [[ ! -s "$batch" ]] || nft -f "$batch" || return 1
    if [[ -f "$HY2_HOP_UNIT" ]]; then
      systemctl disable --now onevps-hy2-hop.service && rm -f "$HY2_HOP_UNIT" && systemctl daemon-reload || return 1
    fi
    if [[ -d "$HY2_HOP_DIR" ]]; then
      rm -f "$HY2_HOP_DIR/rules.nft" "$HY2_HOP_DIR/rules.next" "$HY2_HOP_DIR/.onevps-managed" && rmdir "$HY2_HOP_DIR" || return 1
    fi
  fi
)

ask_hy2_hopping() {
  local ports iface
  ports=$(ask 'Public UDP hopping ports (e.g. 20000-20100,21000; empty = off)')
  if [[ -z "$ports" ]]; then printf 'null\n'; return; fi
  iface=$(ask 'Public ingress interface (e.g. eth0)')
  jq -nc --arg ports "$ports" --arg iface "$iface" '{ports:$ports,interface:$iface}'
}

build_hysteria_inbound() {
  local n="$1" users
  users=$(node_clients "$n") || return 1
  printf '%s\n%s\n' "$n" "$users" | jq -sc '.[0] as $node | .[1] as $users | $node | {
    tag,listen:"0.0.0.0",port,protocol:"hysteria",
    settings:{version:2,users:$users},
    streamSettings:{network:"hysteria",security:"tls",
      tlsSettings:{serverName:.domain,alpn:["h3"],certificates:[{
        usage:"encipherment",certificateFile:.tls_cert,keyFile:.tls_key}]},
      hysteriaSettings:{version:2}}
  }'
}

# HY2 mutations use the existing validated configuration/service transaction.
prepare_hy2_change() {
  local source="$1" output="$2" id="$3" action="$4" value="${5:-null}"
  validate_node_metadata "$source" || return 1
  if [[ "$action" == add ]]; then
    jq -e --arg id "$id" 'all(.nodes[]; .id != $id)' "$source" >/dev/null || return 1
    jq -e --arg id "$id" '.id == $id and .type == "hysteria2"' <<<"$value" >/dev/null || return 1
    printf '%s\n' "$value" | jq --slurpfile source "$source" '. as $node | $source[0] | .nodes += [$node]' > "$output" || return 1
  else
    jq -e --arg id "$id" 'any(.nodes[]; .id == $id and .type == "hysteria2")' "$source" >/dev/null || return 1
    case "$action" in
      hopping) jq --arg id "$id" --argjson value "$value" '(.nodes[]|select(.id==$id)) |=
        if $value == null then del(.hopping) else .hopping=$value end' "$source" > "$output" ;;
      port) jq --arg id "$id" --argjson port "$value" '(.nodes[]|select(.id==$id)).port=$port' "$source" > "$output" ;;
      toggle) jq --arg id "$id" '(.nodes[]|select(.id==$id)).enabled |= not' "$source" > "$output" ;;
      delete) jq --arg id "$id" 'del(.nodes[]|select(.id==$id))' "$source" > "$output" ;;
      *) return 1 ;;
    esac || return 1
  fi
  validate_node_metadata "$output" || return 1
  jq -e '[.nodes[] | select(.type == "hysteria2") | .port] | length == (unique | length)' "$output" >/dev/null
}

add_hysteria_node() {
  require_xray
  require_hy2_core || { pause; return 0; }
  command -v ss >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 || {
    err 'Hysteria2 setup requires ss (iproute2) and runuser (util-linux)'; pause; return 0;
  }
  ensure_nodes_file || return 1
  local name domain password cert key port id node hopping
  info 'Add Hysteria2 (native Xray, QUIC/UDP + TLS)'
  warn 'Use a DNS-only domain pointing to this server. Caddy manages TLS; public TCP 80/443 must be reachable.'
  name=$(ask 'Node name' "hy2-$(openssl rand -hex 2)")
  domain=$(normalize_domain "$(ask 'TLS domain')")
  is_valid_domain "$domain" || { err 'invalid domain'; pause; return 0; }
  caddy_certificate_issue "$domain" || { err 'Caddy certificate setup failed'; pause; return 0; }
  cert="$ACME_CERT_DIR/$domain/current/fullchain.pem"
  key="$ACME_CERT_DIR/$domain/current/key.pem"
  validate_hy2_certificate "$domain" "$cert" "$key" || { pause; return 0; }
  while :; do
    port=$(ask 'UDP listen port (Caddy HTTP/3 may already use UDP 443)' 443)
    realm_valid_port "$port" || { warn 'invalid port'; continue; }
    port=$((10#$port))
    if port_taken_by_node "$port" udp; then
      warn 'UDP port is already in use'; continue
    else
      [[ $? == 1 ]] || { pause; return 1; }
    fi
    if port_in_use "$port" udp; then warn 'UDP port is already in use'; continue; else
      [[ $? == 1 ]] || { pause; return 1; }
    fi
    break
  done
  hopping=$(ask_hy2_hopping) || return 1
  password=$(ask 'Password (Enter for random)' "$(rand_password)")
  id=$(openssl rand -hex 4)
  node=$(printf '%s\n' "$password" | jq -Rc --arg id "$id" --arg name "$name" --arg domain "$domain" \
    --arg cert "$cert" --arg key "$key" --argjson port "$port" --argjson hopping "$hopping" \
    '{id:$id,name:$name,tag:("hy2-"+$id),type:"hysteria2",domain:$domain,password:.,
      port:$port,tls_cert:$cert,tls_key:$key,enabled:true} +
      (if $hopping == null then {} else {hopping:$hopping} end)') || return 1
  if apply_node_add "$node"; then
    ok 'Hysteria2 node added; allow the advertised UDP ports in your cloud firewall'
    node_link "$node"
  fi
  pause
}

build_reality_inbound() {
  local n="$1" clients
  clients=$(node_clients "$n") || return 1
  printf '%s\n%s\n' "$n" "$clients" | jq -s '
    .[0] as $n | .[1] as $clients |
    $n.tag as $tag | $n.port as $port | $n.reality_sni as $sni |
    ($n.reality_target + ":" + (($n.reality_target_port // 443)|tostring)) as $target |
    $n.reality_private_key as $pk | $n.reality_short_id as $sid |
    {
      tag: $tag,
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: {
        clients: $clients,
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          target: $target,
          xver: 0,
          serverNames: [$sni, ""],
          privateKey: $pk,
          shortIds: [$sid]
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls"],
        routeOnly: true
      }
    }'
}

# ----------------------------------------------------------------------------
# Reality target helpers
# ----------------------------------------------------------------------------
probe_reality_target() {
  local domain="$1"
  [[ -x "$XRAY_BIN" ]] || return 0
  command -v timeout >/dev/null 2>&1 || return 0
  if run_with_progress "Probing Reality target $domain" probe_reality_once "$domain" 12; then
    ok "target probe OK"
  else
    warn "target probe failed or timed out; continue only if this domain supports TLS 1.3/H2 and has stable SNI"
  fi
}

probe_reality_once() {
  local domain="$1" timeout_seconds="${2:-10}"
  timeout "$timeout_seconds" "$XRAY_BIN" tls ping "$domain" >/dev/null 2>&1 \
    || timeout "$timeout_seconds" "$XRAY_BIN" tls ping "$domain:443" >/dev/null 2>&1
}

# Assign elapsed in the caller, excluding progress rendering and cleanup time.
time_reality_probe() {
  local domain="$1" start end status=0
  start=$(date +%s%3N)
  probe_reality_once "$domain" || status=$?
  end=$(date +%s%3N)
  elapsed=$((end - start))
  return "$status"
}

auto_pick_reality_target() {
  [[ -x "$XRAY_BIN" ]] || { echo "${REALITY_DESTS[0]}"; return; }
  if ! command -v timeout >/dev/null 2>&1; then
    warn "timeout command not found; using ${REALITY_DESTS[0]}" >&2
    echo "${REALITY_DESTS[0]}"
    return
  fi

  local d i elapsed ok total avg completed=0 steps
  local best="" best_ok=-1 best_avg=999999999
  steps=$((${#REALITY_DESTS[@]} * REALITY_PROBE_ROUNDS))

  info "auto-testing Reality targets (${REALITY_PROBE_ROUNDS} rounds each)..." >&2
  for d in "${REALITY_DESTS[@]}"; do
    ok=0
    total=0
    for ((i=1; i<=REALITY_PROBE_ROUNDS; i++)); do
      if run_with_progress "Reality probe $((completed + 1))/$steps: $d (round $i/$REALITY_PROBE_ROUNDS)" \
        time_reality_probe "$d"; then
        ok=$((ok + 1))
        total=$((total + elapsed))
      fi
      completed=$((completed + 1))
      printf '[*] Reality progress: %d/%d (%d%%)\n' "$completed" "$steps" "$((completed * 100 / steps))" >&2
    done
    avg=999999
    (( ok > 0 )) && avg=$((total / ok))
    if (( ok > best_ok || (ok == best_ok && avg < best_avg) )); then
      best="$d"
      best_ok="$ok"
      best_avg="$avg"
    fi
    if (( ok > 0 )); then
      printf '  %-24s %d/%d avg:%dms\n' "$d" "$ok" "$REALITY_PROBE_ROUNDS" "$avg" >&2
    else
      printf '  %-24s %d/%d failed\n' "$d" "$ok" "$REALITY_PROBE_ROUNDS" >&2
    fi
  done

  if (( best_ok <= 0 )); then
    warn "all target probes failed; using ${REALITY_DESTS[0]}" >&2
    echo "${REALITY_DESTS[0]}"
  else
    ok "selected $best (${best_ok}/${REALITY_PROBE_ROUNDS}, avg ${best_avg}ms)" >&2
    echo "$best"
  fi
}

valid_menu_index() {
  local input="$1" count="$2"
  [[ "$input" =~ ^[1-9][0-9]*$ && ${#input} -le ${#count} ]] && ((input <= count))
}

pick_reality_target() {
  echo >&2
  info "Reality handshake target (major TLS site; TLS 1.3 + H2 preferred):" >&2
  local i=0 d sel target
  echo "  a) auto-test candidates (recommended)" >&2
  for d in "${REALITY_DESTS[@]}"; do
    i=$((i+1))
    echo "  $i) $d" >&2
  done
  echo "  0) custom" >&2
  sel=$(ask "Select" "a")
  if [[ "$sel" =~ ^[Aa]$ ]]; then
    target=$(auto_pick_reality_target)
  elif [[ "$sel" == "0" ]]; then
    target=$(normalize_domain "$(ask "Target domain")")
  elif valid_menu_index "$sel" "${#REALITY_DESTS[@]}"; then
    target="${REALITY_DESTS[$((sel-1))]}"
  else
    target="${REALITY_DESTS[0]}"
  fi
  while ! is_valid_domain "$target"; do
    warn "invalid domain" >&2
    target=$(normalize_domain "$(ask "Target domain")")
  done
  probe_reality_target "$target" >&2
  echo "$target"
}

# ----------------------------------------------------------------------------
# [4] Add VLESS Reality node
# ----------------------------------------------------------------------------
prepare_reality_change() {
  local source="$1" output="$2" id="$3" action="$4" value="${5:-null}"
  validate_node_metadata "$source" || return 1
  printf '%s\n' "$value" | jq --slurpfile source "$source" --arg id "$id" --arg action "$action" '
    . as $value | $source[0] |
    if $action == "add" then
      if $value.type == "vless-reality" and $value.id == $id and all(.nodes[]; .id != $id)
      then .nodes += [$value] else error("invalid Reality node") end
    elif any(.nodes[]; .id == $id and .type == "vless-reality") then
      if $action == "delete" then del(.nodes[] | select(.id == $id))
      else (.nodes[] | select(.id == $id)) |=
        if $action == "port" then .port=$value
        elif $action == "toggle" then .enabled |= not
        elif $action == "secrets" then .reality_private_key=$value.private | .reality_public_key=$value.public | .reality_short_id=$value.short
        elif $action == "target" then .reality_sni=$value | .reality_target=$value | .reality_target_port=443
        else error("unknown Reality change") end end
    else error("unknown Reality node") end' > "$output" || return 1
  validate_node_metadata "$output" || return 1
  jq -e '[.nodes[] | select(.type=="vless-reality") | .port] | length==(unique|length)' "$output" >/dev/null
}

add_reality_node() {
  require_xray
  ensure_nodes_file || return 1
  echo; info "Add node - VLESS + TCP + REALITY + Vision + uTLS"

  local name uuid id default_port port target pk pubk sid node keypair
  name=$(ask "Node name" "reality-$(openssl rand -hex 2)")
  uuid=$(ask_uuid) || { pause; return 1; }
  id=$(openssl rand -hex 4)

  default_port=443
  if port_taken_by_node "$default_port" tcp; then
    default_port=$(rand_port) || { pause; return 1; }
  else
    [[ $? == 1 ]] || { pause; return 1; }
    if port_in_use "$default_port" tcp; then default_port=$(rand_port) || { pause; return 1; }; else
      [[ $? == 1 ]] || { pause; return 1; }
    fi
  fi

  while :; do
    port=$(ask "Listen port" "$default_port")
    realm_valid_port "$port" || { warn 'invalid TCP port (1-65535)'; continue; }
    if port_taken_by_node "$port" tcp; then warn "TCP port $port already used by another node"; continue; else
      [[ $? == 1 ]] || { pause; return 1; }
    fi
    if port_in_use "$port" tcp; then
      confirm "Port $port appears to be in use. Use anyway?" n || continue
    else
      [[ $? == 1 ]] || { pause; return 1; }
    fi
    break
  done

  target=$(pick_reality_target)
  info "generating X25519 Reality keypair..."
  keypair=$(gen_x25519) && read -r pk pubk <<< "$keypair" || { err 'key generation failed'; pause; return 1; }
  sid=$(rand_short_id)

  node=$(jq -n \
    --arg id "$id" --arg name "$name" --arg tag "reality-$id" \
    --argjson port "$port" --arg uuid "$uuid" \
    --arg target "$target" --arg pk "$pk" --arg pubk "$pubk" --arg sid "$sid" '
    {
      id: $id,
      type: "vless-reality",
      name: $name,
      tag: $tag,
      port: $port,
      uuid: $uuid,
      flow: "xtls-rprx-vision",
      fingerprint: "chrome",
      reality_sni: $target,
      reality_target: $target,
      reality_target_port: 443,
      reality_private_key: $pk,
      reality_public_key: $pubk,
      reality_short_id: $sid,
      spider_x: "/",
      enabled: true
    }')

  if apply_node_add "$node"; then
    ok "Reality node added"
    node_link "$node" || warn 'Node saved without displaying a share link'
  fi
  pause
}

# ----------------------------------------------------------------------------
# Share links
# ----------------------------------------------------------------------------
node_link() {
  local n="$1" type name port link addr uuid sni pubk sid spx fp pw domain
  type=$(jq -r '.type' <<<"$n")
  name=$(jq -r '.name' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  link=""

  if [[ "$type" == "vless-reality" ]]; then
    addr=$(pub_ip) || return 1
    [[ "$addr" != *:* ]] || addr="[$addr]"
    uuid=$(jq -r '.uuid' <<<"$n")
    sni=$(jq -r '.reality_sni' <<<"$n")
    pubk=$(jq -r '.reality_public_key' <<<"$n")
    sid=$(jq -r '.reality_short_id' <<<"$n")
    fp=$(jq -r '.fingerprint // "chrome"' <<<"$n")
    spx=$(jq -r '.spider_x // "/"' <<<"$n")
    link="vless://${uuid}@${addr}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pubk}&sid=${sid}&spx=$(urlenc "$spx")&type=tcp#$(urlenc "$name")"
    echo
    printf '%s-- %s (VLESS Reality + Vision + uTLS) --%s\n' "$c_grn" "$name" "$c_rst"
    echo "$link"
    printf '%sTarget: %s:%s  uTLS: %s  shortId: %s%s\n' "$c_ylw" \
      "$(jq -r '.reality_target' <<<"$n")" "$(jq -r '.reality_target_port // 443' <<<"$n")" \
      "$(jq -r '.fingerprint // "chrome"' <<<"$n")" "$(jq -r '.reality_short_id' <<<"$n")" "$c_rst"

  elif [[ "$type" == "hysteria2" ]]; then
    port=$(jq -r '.hopping.ports // .port' <<<"$n")
    pw=$(jq -r '.password' <<<"$n")
    domain=$(jq -r '.domain' <<<"$n")
    printf '\n%s-- %s (Hysteria2 + QUIC + TLS) --%s\n' "$c_grn" "$name" "$c_rst"
    printf 'hysteria2://%s@%s:%s/?sni=%s#%s\n' \
      "$(urlenc "$pw")" "$domain" "$port" "$(urlenc "$domain")" "$(urlenc "$name")"
  else
    err 'invalid node type'; return 1
  fi
}

show_links() {
  require_xray
  ensure_nodes_file || return 1
  [[ "$(node_count)" -gt 0 ]] || { warn "no nodes"; pause; return; }
  local n
  local rows
  rows=$(jq -c '.nodes[]' "$XRAY_NODES") || return 1
  while IFS= read -r n; do node_link "$n" <&3 || continue; done 3<&0 <<< "$rows"
  pause
}

# ----------------------------------------------------------------------------
# Node management
# ----------------------------------------------------------------------------
list_nodes() {
  local i=0 n en st kind dest
  while IFS= read -r n; do
    i=$((i+1))
    en=$(jq -r '.enabled' <<<"$n"); st="enabled"; [[ "$en" == true ]] || st="disabled"
    case "$(jq -r '.type' <<<"$n")" in
      hysteria2) kind="hy2"; dest=$(jq -r '.domain' <<<"$n") ;;
      vless-reality) kind="reality"; dest=$(jq -r '.reality_target' <<<"$n") ;;
      *) kind="invalid"; dest="-" ;;
    esac
    printf '  %d) %-18s %-8s port:%-6s %-26s %s\n' \
      "$i" "$(jq -r '.name' <<<"$n")" "$kind" "$(jq -r '.port' <<<"$n")" \
      "$dest" \
      "$([[ "$en" == true ]] && echo "$st" || echo "${c_ylw}$st${c_rst}")"
  done
}

pick_node() {
  local cnt sel snapshot
  snapshot=$(jq -ce '.nodes | select(type=="array")' "$XRAY_NODES") || return 1
  cnt=$(jq 'length' <<<"$snapshot") || return 1
  [[ "$cnt" -gt 0 ]] || { echo ""; return; }
  list_nodes < <(jq -c '.[]' <<<"$snapshot") >&2
  sel=$(ask $'Select node number (Enter to go back)' "")
  valid_menu_index "$sel" "$cnt" || { echo ""; return; }
  jq -r --argjson i "$((sel-1))" '.[$i].id' <<<"$snapshot"
}

manage_nodes() {
  require_xray
  ensure_nodes_file || return 1
  [[ "$(node_count)" -gt 0 ]] || { warn "no nodes, add one first"; pause; return; }
  local id n type hopping
  id=$(pick_node)
  [[ -n "$id" ]] || return
  n=$(node_by_id "$id")
  [[ -n "$n" ]] || { warn 'Selected node no longer exists'; pause; return 0; }
  type=$(jq -r '.type' <<<"$n")

  while :; do
    clear
    node_link "$n" || warn 'Share link unavailable; node management is still available'
    if [[ "$type" == "hysteria2" ]]; then
      printf '\nConnection settings:\n1) Change UDP port\n2) Reset default password\n3) Set UDP port hopping\n\nUsers / outbound:\n7) Manage node users\n8) Set node outbound\n\nNode status:\n5) Enable/disable node\n\nDanger zone:\n6) Delete node\n\n0) Back\n'
      case "$(ask 'Select')" in
        1) edit_port "$id" || continue ;;
        2) reset_hy2_password "$id" || continue ;;
        3) hopping=$(ask_hy2_hopping) || return 1
           apply_candidate_transaction prepare_hy2_change "$id" hopping "$hopping" && ok 'updated; allow advertised UDP ports in cloud firewall' || err 'port hopping unchanged'; pause ;;
        5) toggle_enabled "$id" ;;
        6) del_node "$id" || true; return 0 ;;
        7) manage_node_users "$id" || true ;;
        8) manage_outbound "$id" || true ;;
        0|"") return ;;
        *) continue ;;
      esac
    elif [[ "$type" == "vless-reality" ]]; then
      cat <<EOF

  Connection settings:
   1) Change port
   2) Reset default UUID
   3) Rotate Reality keypair / shortId
   4) Change Reality handshake target

  Users / outbound:
   7) Manage node users
   8) Set node outbound

  Node status:
   5) Enable/disable node

  Danger zone:
   6) Delete node

   0) Back
EOF
      case "$(ask 'Select')" in
        1) edit_port "$id" || continue ;;
        2) reset_uuid "$id" || continue ;;
        3) rotate_reality_secret "$id" || continue ;;
        4) edit_reality_target "$id" ;;
        5) toggle_enabled "$id" ;;
        6) del_node "$id" || true; return 0 ;;
        7) manage_node_users "$id" || true ;;
        8) manage_outbound "$id" || true ;;
        0|"") return ;;
        *) continue ;;
      esac
    fi
    n=$(node_by_id "$id") || return
    [[ -n "$n" ]] || return
  done
}

apply_port_change() (
  local id="$1" newp="$2" oldp proto=tcp prepare=prepare_reality_change node
  xray_write_lock || return 1
  node=$(node_by_id "$id") && [[ -n "$node" ]] || { err 'Node no longer exists'; return 1; }
  oldp=$(jq -r '.port' <<<"$node") || return 1
  if [[ $(jq -r '.type' <<<"$node") == hysteria2 ]]; then proto=udp; prepare=prepare_hy2_change; fi
  apply_candidate_transaction_locked "$prepare" "$id" port "$newp" || { err 'port change failed'; return 1; }
  open_port "$newp" "$proto" || { err "Node port saved as $newp/$proto; check the firewall. The old rule was not removed."; return 1; }
  if [[ "$oldp" != "$newp" ]]; then
    close_port "$oldp" "$proto" || { err "Node port saved as $newp/$proto; check the old firewall rule for $oldp/$proto"; return 1; }
  fi
  ok "port changed to $newp"
)

apply_node_add() (
  local node="$1" id port proto=tcp prepare=prepare_reality_change
  id=$(jq -er '.id' <<<"$node") && port=$(jq -er '.port' <<<"$node") || return 1
  if [[ $(jq -r '.type' <<<"$node") == hysteria2 ]]; then proto=udp; prepare=prepare_hy2_change; fi
  xray_write_lock || return 1
  apply_candidate_transaction_locked "$prepare" "$id" add "$node" || { err 'Node not added'; return 1; }
  open_port "$port" "$proto" || { err 'Node saved; check the host firewall before connecting'; return 1; }
)

edit_port() {
  local id="$1" n newp proto=tcp
  n=$(node_by_id "$id")
  [[ $(jq -r '.type' <<<"$n") != hysteria2 ]] || proto=udp
  while :; do
    newp=$(ask "New port" "$(jq -r '.port' <<<"$n")")
    realm_valid_port "$newp" || { warn 'invalid port (1-65535)'; continue; }
    if port_taken_by_node "$newp" "$proto" "$id"; then
      warn "port used by another node"; continue
    else
      [[ $? == 1 ]] || { pause; return 1; }
    fi
    if [[ "$newp" != "$(jq -r '.port' <<<"$n")" ]]; then
      if port_in_use "$newp" "$proto"; then
        if [[ "$proto" == udp ]]; then warn 'UDP port is already in use'; continue; fi
        confirm "Port $newp appears to be in use. Use anyway?" n || continue
      else
        [[ $? == 1 ]] || { pause; return 1; }
      fi
    fi
    break
  done
  apply_port_change "$id" "$newp" || { pause; return 1; }
  pause
}

reset_uuid() {
  local id="$1" new_uuid
  new_uuid=$(ask_uuid) || { pause; return 1; }
  printf '%s\n' "$new_uuid" | jq -R . | apply_node_user_change "$id" reset || { err 'apply failed'; return 1; }
  ok "UUID reset"
  pause
}

rotate_reality_secret() {
  local id="$1" pk pubk sid secrets keypair
  confirm "Rotate Reality keypair and shortId? Existing links for this node will stop working." n || return
  keypair=$(gen_x25519) && read -r pk pubk <<< "$keypair" || { err 'key generation failed'; pause; return 1; }
  sid=$(rand_short_id)
  secrets=$(printf '%s\n' "$pk" "$pubk" "$sid" | jq -Rsc 'split("\n") | {private:.[0],public:.[1],short:.[2]}') || return 1
  apply_candidate_transaction prepare_reality_change "$id" secrets "$secrets" && ok "Reality keypair rotated" || err "apply failed"
  pause
}

edit_reality_target() {
  local id="$1" target
  target=$(pick_reality_target)
  apply_candidate_transaction prepare_reality_change "$id" target "$(jq -Rn --arg target "$target" '$target')" && ok "target changed to $target" || err "apply failed"
  pause
}

reset_hy2_password() {
  local id="$1" pw
  pw=$(ask "New default password (Enter for random)" "$(rand_password)")
  printf '%s\n' "$pw" | jq -R . | apply_node_user_change "$id" reset || { err 'apply failed'; return 1; }
  ok "password reset"
  pause
}

toggle_enabled() {
  local id="$1" prepare=prepare_reality_change
  if [[ $(node_by_id "$id" | jq -r '.type') == hysteria2 ]]; then
    prepare=prepare_hy2_change
  fi
  apply_candidate_transaction "$prepare" "$id" toggle && ok 'enabled state toggled' || err 'apply failed'
  pause
}

del_node() {
  confirm "Delete this node?" n || return 0
  apply_node_delete "$1" || { pause; return 1; }
  ok 'deleted'
  pause
}

apply_node_delete() (
  local id="$1" n port type proto=tcp prepare=prepare_reality_change
  xray_write_lock || return 1
  n=$(node_by_id "$id") && [[ -n "$n" ]] || { err 'Node no longer exists'; return 1; }
  port=$(jq -r '.port' <<<"$n")
  type=$(jq -r '.type' <<<"$n")
  if [[ "$type" == hysteria2 ]]; then
    proto=udp; prepare=prepare_hy2_change
  fi
  apply_candidate_transaction_locked "$prepare" "$id" delete || { err 'delete failed'; return 1; }
  close_port "$port" "$proto" || { err "Node deleted; check the firewall rule for $port/$proto"; return 1; }
)

# ----------------------------------------------------------------------------
# BBR acceleration
# ----------------------------------------------------------------------------
apply_fq_qdisc() {
  command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 || {
    warn "ip/tc unavailable; actual root qdisc unchanged"; return 1;
  }
  local dev queues root
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}') || {
    warn "cannot query default interface; qdisc unchanged"; return 1;
  }
  [[ -n "$dev" ]] || { warn "default interface unknown; qdisc unchanged"; return 1; }
  queues=$(tc qdisc show dev "$dev" 2>/dev/null) || {
    warn "cannot query qdisc on $dev; unchanged"; return 1;
  }
  root=$(awk '$1 == "qdisc" && $4 == "root" {print $2}' <<<"$queues")
  if [[ "$root" == fq ]]; then
    info "$dev root qdisc is already fq"; return 0
  fi
  # Only a single, simple default queue is safe to replace. Preserve mq,
  # classful/custom trees and unrecognized output, including child queues.
  if [[ "$queues" == *$'\n'* || ! "$queues" =~ ^qdisc[[:blank:]]+pfifo_fast[[:blank:]]+0:[[:blank:]]+root[[:blank:]] ]]; then
    warn "$dev root qdisc preserved ($root); custom, multiqueue or unknown layout"
    return 0
  fi
  local filters
  filters=$(tc filter show dev "$dev" root 2>/dev/null) || {
    warn "cannot inspect filters on $dev; qdisc unchanged"; return 1;
  }
  [[ -z "$filters" ]] || { warn "$dev has filters; qdisc preserved"; return 0; }
  if ! tc qdisc replace dev "$dev" root fq; then
    err "failed to replace root qdisc on $dev"; return 1
  fi
}

bbr_status() {
  local qdisc cc dev actual="unknown"
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
  if command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1; then
    dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    if [[ -n "$dev" ]]; then
      actual=$(tc qdisc show dev "$dev" 2>/dev/null || echo "unknown")
    fi
  fi
  echo "congestion control: $cc  default qdisc: $qdisc  interface qdisc: $actual"
}

apply_sysctl_file() {
  local file="$1"
  command -v sysctl >/dev/null 2>&1 || { err "sysctl not found; cannot apply $file"; return 1; }
  # Do not suppress unsupported-key or permission errors: neither is success.
  if ! sysctl -p "$file"; then
    err "failed to apply $file (possibly unsupported keys or permissions); some settings may already be applied"
    return 1
  fi
}

enable_bbr() {
  echo; info "BBR acceleration"
  local cc qdisc kver kmin
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")

  if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
    ok "BBR already enabled ($(bbr_status))"
    pause; return
  fi

  info "current state: $(bbr_status)"
  kver=$(uname -r | cut -d. -f1-2)
  kmin="4.9"
  if ! printf '%s\n%s\n' "$kmin" "$kver" | sort -V -C; then
    die "kernel $kver does not support BBR (requires >= $kmin)"
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
  fi
  if ! grep -q tcp_bbr /proc/modules 2>/dev/null && [[ ! -d /sys/module/tcp_bbr ]]; then
    die "kernel lacks tcp_bbr module"
  fi

  confirm "Enable BBR?" y || { pause; return; }

  if ! cat > "$BBR_CONF" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  then
    err "cannot write $BBR_CONF"; return 1
  fi
  apply_sysctl_file "$BBR_CONF" || return 1
  apply_fq_qdisc || return 1

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
  if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
    ok "BBR enabled ($(bbr_status))"
  else
    err "failed to enable BBR, current: $(bbr_status)"
    return 1
  fi
  pause
}

# ----------------------------------------------------------------------------
# Service / uninstall
# ----------------------------------------------------------------------------
restart_service() {
  require_xray
  rebuild_config || return 1
  ok "restarted"
  systemctl --no-pager -l status xray 2>/dev/null | head -n 8 || true
  pause
}

uninstall() (
  warn "Uninstall removes Xray binary, config, onevps nodes and logs"
  warn "(BBR/system tuning configs and the swap file are kept)"
  confirm "Confirm uninstall?" n || return 0
  xray_write_lock || return 1
  local load_state active_state
  load_state=$(systemctl show -p LoadState --value xray) || { err 'Cannot inspect the Xray service; uninstall cancelled'; return 1; }
  [[ -n "$load_state" ]] || { err 'Unknown Xray service state; uninstall cancelled'; return 1; }
  if [[ "$load_state" != not-found ]]; then
    if ! systemctl stop xray || ! active_state=$(systemctl show -p ActiveState --value xray) ||
       [[ "$active_state" != inactive && "$active_state" != failed ]]; then
      err 'Cannot confirm Xray stopped; uninstall cancelled'; return 1
    fi
    systemctl disable xray || { err 'Cannot disable Xray; uninstall cancelled'; return 1; }
  fi
  if [[ -f "$ACME_UNIT_DIR/onevps-caddy-sync.timer" ]]; then
    systemctl disable --now onevps-caddy-sync.timer || { err 'Cannot disable certificate sync; uninstall cancelled'; return 1; }
  fi
  if [[ -e "$HY2_HOP_DIR" || -e "$HY2_HOP_UNIT" ]]; then
    hy2_hop_apply /dev/null || { err 'cannot remove managed hopping rules; uninstall cancelled'; return 1; }
  fi
  warn 'Caddy domain sites and certificates are retained; certificate sync to Xray is disabled.'
  rm -f "$XRAY_SERVICE" /etc/systemd/system/xray@.service &&
    rm -rf /etc/systemd/system/xray.service.d && systemctl daemon-reload &&
    rm -f "$XRAY_BIN" && rm -rf "$XRAY_DIR" /usr/local/share/xray /var/log/xray || {
    err 'Xray cleanup did not finish; check the error and retry uninstall'; return 1;
  }
  ok "uninstalled"
  pause
)

# ----------------------------------------------------------------------------
# Realm relay (independent of Xray)
# ----------------------------------------------------------------------------
realm_valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

realm_valid_host() {
  local host="$1" part rest count=0
  if [[ "$host" == *:* ]]; then
    [[ "$host" =~ ^[0-9a-fA-F:]+$ && "$host" != *:::* ]] || return 1
    [[ "$host" != :* || "$host" == ::* ]] || return 1
    [[ "$host" != *: || "$host" == *:: ]] || return 1
    rest=${host/::/X}
    [[ "$rest" != *::* ]] || return 1
    if [[ "$host" != *::* ]]; then
      [[ "$host" != :* && "$host" != *: ]] || return 1
    fi
    rest="$host"
    while [[ -n "$rest" ]]; do
      part=${rest%%:*}
      [[ -z "$part" || ${#part} -le 4 ]] || return 1
      [[ -z "$part" ]] || count=$((count + 1))
      [[ "$rest" == *:* ]] || break
      rest=${rest#*:}
    done
    if [[ "$host" == *::* ]]; then (( count < 8 )); else (( count == 8 )); fi
  elif [[ "$host" =~ ^[0-9.]+$ ]]; then
    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    rest="$host"
    while :; do
      part=${rest%%.*}
      [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$part <= 255 )) || return 1
      [[ "$rest" == *.* ]] || break
      rest=${rest#*.}
    done
  else
    [[ ${#host} -le 253 && "$host" != *. ]] || return 1
    rest="$host"
    while :; do
      part=${rest%%.*}
      [[ ${#part} -le 63 && "$part" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
      [[ "$rest" == *.* ]] || break
      rest=${rest#*.}
    done
  fi
}

realm_endpoint() {
  local port="$1" host="$2" remote_port="$3" mode="$4"
  realm_valid_port "$port" && realm_valid_port "$remote_port" && realm_valid_host "$host" || return 1
  [[ "$mode" == tcp || "$mode" == both ]] || return 1
  [[ "$host" != *:* ]] || host="[$host]"
  jq -n --arg listen "0.0.0.0:$port" --arg remote "$host:$remote_port" --arg mode "$mode" \
    '{listen:$listen,remote:$remote,network:{no_tcp:false,use_udp:($mode == "both")}}'
}

realm_owned() {
  [[ -f "$REALM_DIR/.onevps-managed" && ! -L "$REALM_DIR" && ! -L "$REALM_SERVICE" ]] &&
    grep -qx '# Managed by OneVPS realm' "$REALM_SERVICE"
}

realm_write_service() {
  cat <<EOF
# Managed by OneVPS realm
[Unit]
Description=OneVPS Realm Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=true
ExecStart=$REALM_BIN -c $REALM_DIR/config.json
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

realm_install() {
  if realm_owned; then
    [[ -x "$REALM_BIN" && -f "$REALM_DIR/config.json" ]] || { err "incomplete realm installation; inspect before reinstalling"; return 1; }
    return 0
  fi
  if [[ -e "$REALM_DIR" || -L "$REALM_DIR" || -e "$REALM_BIN" || -L "$REALM_BIN" ||
        -e "$REALM_SERVICE" || -L "$REALM_SERVICE" ]]; then
    err "refusing to overwrite unmanaged realm paths"; return 1
  fi
  local target tmp asset url digest actual
  case "$ARCH" in
    amd64) target=x86_64-unknown-linux-musl ;;
    arm64) target=aarch64-unknown-linux-musl ;;
    armv7) target=armv7-unknown-linux-musleabihf ;;
    *) err "unsupported realm architecture: $ARCH"; return 1 ;;
  esac
  tmp=$(mktemp -d) || return 1
  asset="realm-$target.tar.gz"
  info "downloading official realm $REALM_VERSION ($target)"
  if ! run_with_progress "Checking Realm $REALM_VERSION release" curl -fsSL --connect-timeout 15 --max-time 60 \
    "https://api.github.com/repos/zhboner/realm/releases/tags/$REALM_VERSION" > "$tmp/release.json"; then
    rm -rf "$tmp"; return 1
  fi
  url=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' "$tmp/release.json")
  digest=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest' "$tmp/release.json")
  if [[ "$url" != "https://github.com/zhboner/realm/releases/download/$REALM_VERSION/$asset" ||
        ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    err "missing official asset or SHA-256 digest"; rm -rf "$tmp"; return 1
  fi
  if ! download_file --connect-timeout 15 --max-time 180 "$url" -o "$tmp/archive.tar.gz"; then
    rm -rf "$tmp"; return 1
  fi
  actual=$(openssl dgst -sha256 "$tmp/archive.tar.gz")
  if [[ "${actual##* }" != "${digest#sha256:}" ]]; then
    err "realm checksum mismatch"; rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$tmp/archive.tar.gz" -C "$tmp" realm ||
     [[ ! -f "$tmp/realm" || -L "$tmp/realm" ]] ||
     ! chmod 755 "$tmp/realm" || ! "$tmp/realm" --version; then
    err "invalid realm binary"; rm -rf "$tmp"; return 1
  fi
  # Publish only after the downloaded binary has passed validation.
  if ! mkdir -p "$REALM_DIR" || ! chmod 755 "$REALM_DIR" ||
     ! install -m 755 "$tmp/realm" "$REALM_BIN" ||
     ! printf '{"log":{"level":"warn"},"endpoints":[]}\n' > "$REALM_DIR/config.json" ||
     ! chmod 644 "$REALM_DIR/config.json" ||
     ! realm_write_service > "$REALM_SERVICE" || ! chmod 644 "$REALM_SERVICE" ||
     ! touch "$REALM_DIR/.onevps-managed" || ! systemctl daemon-reload; then
    rm -f "$REALM_BIN" "$REALM_SERVICE"
    rm -rf "$REALM_DIR" "$tmp"
    systemctl daemon-reload || true
    err "realm installation failed"; return 1
  fi
  rm -rf "$tmp"
  ok "realm installed; add a rule to start forwarding"
}

realm_restart() {
  local pid port udp sockets listeners
  listeners=$(jq -ers '
    if length != 1 or (.[0].endpoints | type) != "array" or (.[0].endpoints | length)==0 then
      error("expected at least one relay rule") else .[0].endpoints[] end |
    (.listen | capture("^0\\.0\\.0\\.0:(?<port>[1-9][0-9]{0,4})\\z") // error("invalid relay listener")) as $listen |
    if ($listen.port|tonumber)>65535 or (.network.use_udp|type)!="boolean" then error("invalid relay listener")
    else "\($listen.port) \(.network.use_udp)" end' "$REALM_DIR/config.json") || {
    err 'Cannot restart Realm: no valid listener configuration'; return 1;
  }
  run_with_progress 'Restarting Realm service' systemctl restart onevps-realm || return 1
  run_with_progress 'Waiting for Realm listeners' sleep 2
  systemctl is-active --quiet onevps-realm || return 1
  pid=$(systemctl show -p MainPID --value onevps-realm) || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  # Realm can remain active when only some listeners bind successfully.
  while read -r port udp; do
    sockets=$(ss -H -lntp "sport = :$port") || return 1
    [[ "$sockets" == *"pid=$pid,"* ]] || return 1
    if [[ "$udp" == true ]]; then
      sockets=$(ss -H -lnup "sport = :$port") || return 1
      [[ "$sockets" == *"pid=$pid,"* ]] || return 1
    fi
  done <<< "$listeners"
}

realm_apply() {
  local candidate="$1" backup was_active=false was_enabled=false
  realm_owned || { err "realm is not managed by OneVPS"; return 1; }
  jq -es 'length == 1 and (.[0].endpoints | type == "array")' "$candidate" >/dev/null || return 1
  backup=$(mktemp "$REALM_DIR/.backup.XXXXXX") || return 1
  cp -p "$REALM_DIR/config.json" "$backup" || { rm -f "$backup"; return 1; }
  systemctl is-active --quiet onevps-realm && was_active=true
  systemctl is-enabled --quiet onevps-realm && was_enabled=true
  if chmod 644 "$candidate" && mv -f "$candidate" "$REALM_DIR/config.json"; then
    if [[ $(jq '.endpoints | length' "$REALM_DIR/config.json") == 0 ]]; then
      if systemctl stop onevps-realm && systemctl disable onevps-realm; then
        rm -f "$backup"; return 0
      fi
    elif realm_restart && systemctl enable onevps-realm; then
      rm -f "$backup"; return 0
    fi
  fi
  mv -f "$backup" "$REALM_DIR/config.json" || { err "could not restore realm backup: $backup"; return 1; }
  if $was_enabled; then systemctl enable onevps-realm || true; else systemctl disable onevps-realm || true; fi
  if $was_active; then
    realm_restart || err "old config restored, but service recovery failed; inspect journalctl -u onevps-realm"
  else
    systemctl stop onevps-realm || true
  fi
  err "realm change failed; previous configuration restored"
  return 1
}

realm_write_lock() {
  command -v flock >/dev/null || { err 'Realm changes require flock (util-linux)'; return 1; }
  mkdir -p "$(dirname "$REALM_DIR")" && exec 8>>"${REALM_DIR}.lock" && flock -x 8
}

realm_add() (
  local port host remote_port mode endpoint candidate sockets flags=-lnt
  port=$(ask 'Local listening port')
  host=$(ask 'Destination IP or hostname (IPv6 without brackets)')
  remote_port=$(ask 'Destination port')
  mode=$(ask 'Protocol: tcp or both (TCP+UDP)' tcp)
  endpoint=$(realm_endpoint "$port" "$host" "$remote_port" "$mode") || { err "invalid relay input"; return 1; }
  warn "relay listens on all IPv4 interfaces; it adds no authentication or encryption"
  confirm "Forward port $port to $host:$remote_port ($mode)?" || return 0
  realm_write_lock || return 1
  if port_taken_by_node "$port" tcp; then err 'TCP port reserved by Xray'; return 1; else
    [[ $? == 1 ]] || return 1
  fi
  if [[ "$mode" == both ]]; then
    flags=-lntu
    if port_taken_by_node "$port" udp; then err 'UDP port reserved by Xray'; return 1; else
      [[ $? == 1 ]] || return 1
    fi
  fi
  command -v ss >/dev/null 2>&1 || { err "ss is required to check listening ports; install iproute2/iproute"; return 1; }
  sockets=$(ss -H "$flags") || { err "cannot inspect listening ports"; return 1; }
  if socket_list_has_port "$port" <<<"$sockets"; then
    err "port $port is already in use"; return 1
  fi
  realm_install || return 1
  if jq -e --arg listen "0.0.0.0:$port" 'any(.endpoints[]; .listen == $listen)' "$REALM_DIR/config.json" >/dev/null; then
    err "a rule already uses this port"; return 1
  fi
  candidate=$(mktemp "$REALM_DIR/.candidate.XXXXXX") || return 1
  if jq --argjson endpoint "$endpoint" '.endpoints += [$endpoint]' "$REALM_DIR/config.json" > "$candidate" &&
     realm_apply "$candidate"; then
    ok "relay added; allow port $port ($mode) in your firewall and cloud security group"
  else
    rm -f "$candidate"; return 1
  fi
)

realm_list() {
  jq -r '.endpoints | to_entries[] | "\(.key + 1)) \(.value.listen) -> \(.value.remote) [\(if .value.network.use_udp then "TCP+UDP" else "TCP" end)]"' \
    "${1:-$REALM_DIR/config.json}"
}

realm_delete() (
  local index count candidate snapshot selected
  snapshot=$(jq -cse 'select(length==1) | .[0] | select(.endpoints | type=="array")' "$REALM_DIR/config.json") || return 1
  realm_list /dev/stdin <<<"$snapshot" || return 1
  count=$(jq '.endpoints | length' <<<"$snapshot") || return 1
  index=$(ask 'Rule number to delete (empty cancels)')
  [[ -n "$index" ]] || return 0
  valid_menu_index "$index" "$count" || { err "invalid rule number"; return 1; }
  selected=$(jq -ce --argjson index "$((index - 1))" '.endpoints[$index]' <<<"$snapshot") || return 1
  confirm "Delete $(jq -r '.listen + " -> " + .remote' <<<"$selected")?" || return 0
  realm_write_lock && realm_owned || return 1
  candidate=$(mktemp "$REALM_DIR/.candidate.XXXXXX") || return 1
  if jq --argjson selected "$selected" '
      [.endpoints | to_entries[] | select(.value==$selected) | .key] as $matches |
      if ($matches|length)==1 then del(.endpoints[$matches[0]]) else error("relay rule changed; select it again") end' \
      "$REALM_DIR/config.json" > "$candidate" &&
     realm_apply "$candidate"; then
    ok "rule removed"
  else
    rm -f "$candidate"; return 1
  fi
)

realm_uninstall() (
  realm_owned || { err "refusing to remove unmanaged realm installation"; return 1; }
  confirm 'Remove OneVPS realm and all its relay rules?' || return 0
  realm_write_lock && realm_owned || return 1
  systemctl stop onevps-realm && systemctl disable onevps-realm || return 1
  rm -f "$REALM_BIN" "$REALM_SERVICE" && rm -rf "$REALM_DIR" && systemctl daemon-reload || {
    err 'Realm cleanup did not finish; inspect remaining files and retry'; return 1;
  }
  ok "realm removed; firewall rules were not changed"
)

realm_menu() {
  ensure_deps
  while :; do
    printf '\nRealm relay\n\nRelay rules:\n1) Install realm / add relay rule\n2) Show relay rules / service status\n\nService:\n4) Restart realm service\n\nDanger zone:\n3) Delete relay rule\n5) Uninstall realm\n\n0) Back\n'
    local choice
    choice=$(ask 'Select')
    case "$choice" in
      0|"") return ;;
      1) realm_add || warn "relay was not added" ;;
      2|3|4|5)
        if ! realm_owned; then warn "no OneVPS-managed realm installation"; continue; fi
        case "$choice" in
          2) realm_list; systemctl --no-pager status onevps-realm || true ;;
          3) realm_delete || warn "rule was not removed" ;;
          4) realm_restart || warn "restart failed; inspect journalctl -u onevps-realm" ;;
          5) realm_uninstall || warn "uninstall failed" ;;
        esac ;;
      *) warn "invalid selection" ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------
update_script() (
  local target="$ONEVPS_SCRIPT_PATH" tmp
  warn "This downloads and runs OneVPS from the repository main branch."
  confirm "Update script now?" || return 1
  ensure_deps || return 1
  if [[ -f "$target" && ! -L "$target" ]]; then
    tmp=$(mktemp -d "$(dirname -- "$target")/.onevps-update.XXXXXX") || return 1
  elif [[ "$target" == /dev/fd/* || "$target" == /proc/self/fd/* ]]; then
    target=""
    tmp=$(mktemp -d) || return 1
  else
    err "script path is not a regular file; download onevps.sh again to update"
    return 1
  fi
  trap 'rm -rf -- "$tmp"' EXIT
  if [[ -n "$target" ]]; then
    cp -p -- "$target" "$tmp/onevps.sh" || return 1
  fi
  if ! download_file --connect-timeout 15 --max-time 180 "$ONEVPS_UPDATE_URL" -o "$tmp/onevps.sh"; then
    err "script download failed; current script unchanged"
    return 1
  fi
  if ! validate_onevps_script "$tmp/onevps.sh"; then
    err "downloaded script is invalid; current script unchanged"
    return 1
  fi
  if [[ -n "$target" ]]; then
    if ! mv -f -- "$tmp/onevps.sh" "$target"; then
      err "script replacement failed; current script unchanged"
      return 1
    fi
    ok "script updated; starting the updated menu"
    bash "$target"
  else
    ok "starting the updated script for this session (streamed launch)"
    bash "$tmp/onevps.sh"
  fi
)

status_line() {
  if [[ -x "$XRAY_BIN" ]]; then
    local v st bbr_cc
    v=$(installed_version) || v=unknown
    [[ -n "$v" ]] || v=unknown
    st=$(systemctl is-active xray 2>/dev/null || echo unknown)
    bbr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    printf '%sXray %s - service:%s - nodes:%s - TCP:%s%s\n' \
      "$c_blu" "$v" "$st" "$(node_count 2>/dev/null || echo 0)" "$bbr_cc" "$c_rst"
  else
    printf '%sXray not installed%s\n' "$c_ylw" "$c_rst"
  fi
}

node_menu() {
  while :; do
    printf '\nNodes / share links:\n1) Add VLESS Reality\n3) Add Hysteria2\n4) Manage nodes / users / outbound\n5) Show share links\n0) Back\n'
    case "$(ask 'Select')" in
      1) add_reality_node || warn 'Reality setup did not finish' ;;
      3) add_hysteria_node || warn 'HY2 setup did not finish' ;;
      4) manage_nodes ;;
      5) show_links ;;
      0|"") return ;;
      *) warn 'invalid selection' ;;
    esac
  done
}

network_menu() {
  while :; do
    printf '\nService / network:\n1) Restart Xray service\n2) Enable BBR / show status\n3) Set up HTTPS static site (403)\n0) Back\n'
    case "$(ask 'Select')" in
      1) restart_service || { err 'Xray restart failed'; pause; } ;;
      2) enable_bbr || { err 'BBR configuration failed; some settings may already be applied'; pause; } ;;
      3) setup_static_site || err 'Static site setup failed'; pause ;;
      0|"") return ;;
      *) warn 'invalid selection' ;;
    esac
  done
}

main_menu() {
  while :; do
    clear
    cat <<'EOF'
 ╔════════════════════════════════════════════════╗
 ║   OneVPS - Xray nodes / Realm relay            ║
 ╚════════════════════════════════════════════════╝
EOF
    status_line
    cat <<'EOF'

  Setup / management:
   1) Install / update Xray-core
   2) Nodes / users / outbound / share links
   3) Certificates (Caddy-managed)
   4) Realm relay
   5) Service / network

  Script:
   6) Update script

  Danger zone:
   9) Uninstall Xray (keep Realm / Caddy)

   0) Exit
EOF
    case "$(ask 'Select')" in
      1) install_xray || err 'Xray installation failed'; pause ;;
      2) node_menu ;;
      3) certificate_menu ;;
      4) realm_menu ;;
      5) network_menu ;;
      6) if update_script; then return 0; else pause; fi ;;
      9) uninstall || pause ;;
      0|"") exit 0 ;;
      *) warn 'invalid selection' ;;
    esac
  done
}

main() {
  check_env
  if [[ "${1:-}" == --caddy-sync ]]; then
    caddy_sync_all
    return
  fi
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
