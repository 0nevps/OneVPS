#!/usr/bin/env bash
#
# OneVPS - Xray node setup script
# Protocols:
#   - VLESS + TCP + REALITY + XTLS Vision + uTLS (standalone)
#   - Trojan + WebSocket behind Caddy (coexists with Caddy-proxied sites)
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
TUNE_CONF=/etc/sysctl.d/99-onevps-tune.conf
BBR_CONF=/etc/sysctl.d/99-bbr.conf
REALITY_PROBE_ROUNDS=3
REALM_DIR=/usr/local/etc/onevps-realm
REALM_BIN=/usr/local/bin/onevps-realm
REALM_SERVICE=/etc/systemd/system/onevps-realm.service
REALM_VERSION=v2.9.6
HY2_MIN_VERSION=26.10.21
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
    echo "${ans:-$def}"
  else
    read -rp "$q: " ans || true
    echo "$ans"
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
  default=$(rand_uuid)
  input=$(ask "UUID (Enter for random)" "$default")
  while ! is_valid_uuid "$input"; do
    warn "invalid UUID format (expected: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)"
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
    port_taken_by_node "$p" 2>/dev/null && continue
    port_in_use "$p" && continue
    echo "$p"; return
  done
}

pub_ip() {
  [[ -n "$PUBIP" ]] && { echo "$PUBIP"; return; }
  PUBIP=$(run_with_progress 'Looking up public IP (ipify)' curl -fsSL4 --max-time 8 https://api.ipify.org \
       || run_with_progress 'Looking up public IP (ifconfig.me)' curl -fsSL4 --max-time 8 https://ifconfig.me || true)
  echo "$PUBIP"
}

require_xray() {
  command -v "$XRAY_BIN" >/dev/null 2>&1 || die "run menu option [1] to install Xray first"
}

installed_version() {
  [[ -x "$XRAY_BIN" ]] || { echo ""; return; }
  "$XRAY_BIN" version 2>/dev/null | awk '/^Xray /{print $2; exit}'
}

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

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
  kp=$("$XRAY_BIN" x25519)
  pk=$(awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$kp")
  pubk=$(awk -F': ' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$kp")
  [[ -n "$pk" && -n "$pubk" ]] || die "failed to parse Xray x25519 keypair"
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
write_service() {
  mkdir -p "$XRAY_DIR" /var/log/xray
  cat > "$XRAY_SERVICE" <<EOF
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
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
}

secure_xray_files() {
  local ng
  mkdir -p "$XRAY_DIR" /var/log/xray
  ng=$(id -gn nobody 2>/dev/null || true)
  if [[ -n "$ng" ]]; then
    chown root:"$ng" "$XRAY_DIR" 2>/dev/null || true
    chmod 750 "$XRAY_DIR" 2>/dev/null || true
    [[ -f "$XRAY_CONF" ]] && chown root:"$ng" "$XRAY_CONF" && chmod 640 "$XRAY_CONF"
    [[ -f "$XRAY_NODES" ]] && chown root:"$ng" "$XRAY_NODES" && chmod 640 "$XRAY_NODES"
    chown nobody:"$ng" /var/log/xray 2>/dev/null || true
    chmod 750 /var/log/xray 2>/dev/null || true
  fi
}

install_xray() {
  ensure_deps
  local tmp
  tmp=$(mktemp)
  info "downloading official Xray installer..."
  download_file "$XRAY_INSTALL_URL" -o "$tmp" || { rm -f "$tmp"; die "download failed"; }
  run_with_progress 'Installing/updating Xray-core and geodata' bash "$tmp" install \
    || { rm -f "$tmp"; die "Xray install failed"; }
  rm -f "$tmp"

  mkdir -p "$XRAY_DIR"
  [[ -f "$XRAY_NODES" ]] || echo '{"nodes":[]}' > "$XRAY_NODES"
  write_service
  rebuild_config
  ok "Xray $(installed_version) installed"
}

# ----------------------------------------------------------------------------
# Firewall / ports
# ----------------------------------------------------------------------------
open_port() {
  local p="$1" proto="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p/$proto" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/$proto" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

close_port() {
  local p="$1" proto="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$p/$proto" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$p/$proto" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

port_in_use() {
  local p="$1" proto="${2:-both}" flags=-tunl
  [[ "$proto" != udp ]] || flags=-unl
  [[ "$proto" != tcp ]] || flags=-tnl
  if command -v ss >/dev/null 2>&1; then
    ss "$flags" 2>/dev/null | awk '{print $(NF-1)}' | grep -qE ":$p$"
  else
    return 1
  fi
}

port_taken_by_node() {
  [[ -f "$XRAY_NODES" ]] || return 1
  jq -e --argjson p "$1" --arg proto "${2:-both}" --arg exclude "${3:-}" '
    .nodes[] | select(.port == $p and .id != $exclude) |
    select($proto == "both" or (if .type == "hysteria2" then "udp" else "tcp" end) == $proto)
  ' "$XRAY_NODES" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Caddy integration (for Trojan + WS nodes; shares Caddy's :443 + certs)
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
  mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy

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
    warn "Caddy not found; installing (required for Trojan nodes)"
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
    mkdir -p /etc/caddy
    cat > "$cf" <<'EOF'
# Managed alongside OneVPS. Caddy reverse-proxies real services here;
# OneVPS appends marked Trojan-WS site blocks below.
:80 {
	respond "OK" 200
}
EOF
    CADDYFILE="$cf"
  fi

  systemctl enable caddy >/dev/null 2>&1 || true
  if ! systemctl is-active caddy >/dev/null 2>&1; then
    run_with_progress 'Starting Caddy service' systemctl start caddy >/dev/null || true
  fi
  return 0
}

find_caddyfile() {
  [[ -n "$CADDYFILE" && -f "$CADDYFILE" ]] && { echo "$CADDYFILE"; return; }
  local c
  c=$(systemctl cat caddy 2>/dev/null \
      | sed -n 's/.*--config[ =]\([^ ]*\).*/\1/p' | head -n1)
  if [[ -n "$c" && -f "$c" ]]; then CADDYFILE="$c"; echo "$c"; return; fi
  for c in /etc/caddy/Caddyfile /etc/Caddyfile /usr/local/etc/caddy/Caddyfile; do
    [[ -f "$c" ]] && { CADDYFILE="$c"; echo "$c"; return; }
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

# Append a marked site block routing a secret WS path to a local Xray inbound.
# Requests to the secret path are proxied to Xray (reverse_proxy handles the
# WebSocket upgrade); every other path returns HTTP 403 with the styled 403
# page, so the rest of the subdomain looks like a locked-down site.
# Reverts the append if Caddy reload fails. Returns non-zero on failure.
caddy_add_route() {
  local id="$1" domain="$2" path="$3" port="$4" file="$5" route backup
  [[ "$id" =~ ^[a-f0-9]+$ && "$path" =~ ^/[a-zA-Z0-9_/-]+$ && "$port" =~ ^[0-9]+$ ]] || return 1
  caddy_domain_ensure "$domain" "$file" || return 1
  route="$CADDY_STATE/routes/$domain/$id.caddy"
  backup=$(mktemp "$CADDY_STATE/.route.XXXXXXXX") || return 1
  [[ ! -f "$route" ]] || cp -p "$route" "$backup" || return 1
  printf 'handle %s {\n    reverse_proxy 127.0.0.1:%s\n}\n' "$path" "$port" > "$route" || return 1
  chmod 644 "$route" || return 1
  if ! caddy_reload "$file"; then
    if [[ -s "$backup" ]]; then cp -p "$backup" "$route"; else rm -f "$route"; fi
    caddy_reload "$file" || true
    rm -f "$backup"; return 1
  fi
  rm -f "$backup"
}

# Removing a node never removes the domain's certificate automation.
caddy_remove_route() {
  local id="$1" route
  [[ "$id" =~ ^[a-f0-9]+$ ]] || return 1
  for route in "$CADDY_STATE/routes/"*/"$id.caddy"; do
    [[ ! -f "$route" ]] || rm -f "$route" || return 1
  done

}

# ----------------------------------------------------------------------------
# [3] Node storage + config generation
# ----------------------------------------------------------------------------
ensure_nodes_file() {
  mkdir -p "$XRAY_DIR"
  [[ -f "$XRAY_NODES" ]] || echo '{"nodes":[]}' > "$XRAY_NODES"
}

jq_update_nodes() {
  ensure_nodes_file
  local t
  t=$(mktemp)
  jq "$@" "$XRAY_NODES" > "$t" && mv "$t" "$XRAY_NODES"
  secure_xray_files
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

mktemp_json() {
  local t
  t=$(mktemp)
  rm -f "$t"
  echo "${t}.json"
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
  decoded=$(printf '%s' "$normalized" | openssl base64 -d -A | jq -Rs -e '
    select(length > 0 and (test("[\\x00-\\x1f\\x7f]") | not))') || return 1
  check=$(printf '%s' "$decoded" | jq -jr '.' | openssl base64 -A) || return 1
  [[ "$check" == "$normalized" ]] || return 1
  printf '%s' "$decoded" | jq -jr '.'
}

# Strict, limited persistent schema. Revalidated on every render, including
# disabled nodes. No arbitrary Xray JSON accepted.
validate_outbound() {
  local data host
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
  ' 2>/dev/null) || return 1
  host=$(jq -r '.server // empty' <<<"$data") || return 1
  [[ -z "$host" ]] || realm_valid_host "$host"
}

parse_outbound_link() {
  local link rest scheme authority query='' fragment='' auth='' host port key value pair params='{}' data credential method password user
  IFS= read -r link || [[ -n "$link" ]] || return 1
  [[ -n "$link" && "$link" != *[[:space:]]* && "$link" != *[[:cntrl:]]* ]] || return 1
  # Exactly one URI; never silently discard a second line.
  if IFS= read -r rest || [[ -n "$rest" ]]; then return 1; fi
  [[ "$link" == *://* ]] || return 1
  scheme=${link%%://*}; rest=${link#*://}
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
    [.nodes[] | select(.enabled == true and (.type == "vless-reality" or .type == "trojan-ws" or .type == "hysteria2")) | . as $n |
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
      trojan-ws)     ib=$(build_trojan_inbound "$n") || return 1 ;;
      hysteria2)     ib=$(build_hysteria_inbound "$n") || return 1 ;;
      *) continue ;;
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

rebuild_config() {
  ensure_nodes_file
  local tmp_conf chk_err
  tmp_conf=$(mktemp_json)
  render_config "$XRAY_NODES" "$tmp_conf" || { rm -f "$tmp_conf"; return 1; }
  chk_err=$(mktemp)
  if ! validate_xray_config "$tmp_conf" "$chk_err"; then
    err "generated config failed validation (details withheld to protect credentials)"
    rm -f "$tmp_conf" "$chk_err"
    return 1
  fi
  rm -f "$chk_err"

  mv "$tmp_conf" "$XRAY_CONF"
  secure_xray_files
  if [[ -x "$XRAY_BIN" ]]; then
    run_with_progress 'Restarting Xray service' systemctl restart xray || true
  fi
}

# Legacy top-level users and node.clients remain ignored.
node_clients() {
  jq -c '
    . as $n |
    [{uuid:.uuid,password:.password,email:(.tag + "@onevps")}] +
      [(.users // [])[] | . + {email:(([ $n.id, .id ] | tojson | @base64) + "@onevps-user")}] |
    map(if $n.type == "vless-reality" then {id:.uuid,flow:"xtls-rprx-vision",email}
        elif $n.type == "hysteria2" then {auth:.password,email}
        else {password,email} end)' <<<"$1"
}

validate_node_metadata() {
  local outbounds outbound
  outbounds=$(jq -c '.nodes[] | (select(has("outbound")) | .outbound), (select(has("default_outbound")) | .default_outbound), ((.users // [])[] | select(has("outbound")) | .outbound)' "$1" 2>/dev/null) || return 1
  while IFS= read -r outbound; do
    [[ -n "$outbound" ]] || continue
    validate_outbound <<<"$outbound" || return 1
  done <<<"$outbounds"
  jq -e '
    def nonempty: type == "string" and length > 0;
    (.nodes | type == "array") and
    ([.nodes[].id] | length == (unique | length)) and
    all(.nodes[];
      . as $n |
      (.id | nonempty) and
      (if .type == "hysteria2" then
        (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.domain | type == "string" and test("^[A-Za-z0-9.-]+$")) and
        (.tls_cert | type == "string" and startswith("/")) and
        (.tls_key | type == "string" and startswith("/")) and
        (.enabled | type == "boolean") and (.tag | nonempty)
       else true end) and
      (if .type == "vless-reality" then (.uuid | nonempty)
       elif .type == "trojan-ws" or .type == "hysteria2" then (.password | nonempty)
       else true end) and
      (if has("users") then (.users | type == "array") else true end) and
      ((.users // []) as $users |
        ([$users[].id] | length == (unique | length)) and
        ([$users[].name] | length == (unique | length)) and
        all($users[];
          (.id | type == "string" and test("^[A-Za-z0-9_-]+$") and . != "default") and
          (.name | type == "string" and test("\\S") and (test("[\\x00-\\x1f\\x7f]") | not)) and
          (if $n.type == "vless-reality" then
             (.uuid | type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
           elif $n.type == "trojan-ws" or $n.type == "hysteria2" then (.password | nonempty)
           else false end)) and
        (if .type == "vless-reality" then ([.uuid, $users[].uuid] | map(ascii_downcase))
         else [.password, $users[].password] end | length == (unique | length))))
  ' "$1" >/dev/null 2>&1
}

# A subshell scopes traps. Backups and candidates stay on the target filesystem.
# Rollback covers detectable failures, not power-loss atomicity across two files.
apply_candidate_transaction() (
  local prepare="$1"
  shift
  umask 077
  local tx active=false touched=false committed=false preserve=false
  [[ -x "$XRAY_BIN" && -f "$XRAY_NODES" && -f "$XRAY_CONF" ]] || {
    err "installed Xray and existing configuration required"; return 1;
  }
  tx=$(mktemp -d "$XRAY_DIR/.transaction.XXXXXXXX") || return 1
  transaction_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      cp -p "$tx/nodes.backup" "$XRAY_NODES" || failed=true
      cp -p "$tx/config.backup" "$XRAY_CONF" || failed=true
      if $active; then
        run_with_progress 'Restarting Xray service' systemctl restart xray && systemctl is-active --quiet xray || failed=true
      else
        systemctl stop xray || failed=true
        if systemctl is-active --quiet xray; then failed=true; fi
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
  jq -e --arg id "$id" 'any(.nodes[]; .id == $id and (.type == "vless-reality" or .type == "trojan-ws" or .type == "hysteria2"))' "$source" >/dev/null || return 1
  case "$action" in
    add|reset) payload=$(jq -cse 'select(length == 1) | .[0]') || return 1 ;;
    delete)
      [[ "$uid" != default ]] || return 1
      jq -e --arg id "$id" --arg uid "$uid" '.nodes[] | select(.id == $id) | any((.users // [])[]; .id == $uid)' "$source" >/dev/null || return 1
      payload=null ;;
    *) return 1 ;;
  esac
  if [[ "$action" == reset ]] && jq -e --arg id "$id" '.nodes[] | select(.id == $id) | .type == "vless-reality"' "$source" >/dev/null; then
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
        if [[ $(jq -r '.type' <<<"$n") == vless-reality ]]; then
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
        if [[ "$action" == 3 ]]; then node_user_link "$n" "$uid"; pause; continue; fi
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
  mkdir -p "$CADDY_STATE/domains" "$CADDY_STATE/routes" "$CADDY_STATE/staging" "$ACME_CERT_DIR" || return 1
  chmod 755 "$CADDY_STATE" "$CADDY_STATE/routes" || return 1
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
  if ! caddy adapt --adapter caddyfile --config "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; err 'existing Caddy global options conflict; configuration was not changed'; return 1
  fi
  cat "$tmp" > "$file"; rm -f "$tmp"
}

caddy_domain_ensure() {
  local domain="$1" file="$2" backup root site_root
  acme_domain_valid "$domain" || return 1
  if [[ -f "$CADDY_STATE/domains/$domain.json" ]]; then
    jq -e --arg file "$file" '.caddy_file == $file' "$CADDY_STATE/domains/$domain.json" >/dev/null &&
      [[ $(grep -cxF "# OneVPS-domain:$domain BEGIN" "$file") == 1 ]] &&
      [[ $(grep -cxF "# OneVPS-domain:$domain END" "$file") == 1 ]] &&
      grep -qxF "    import $CADDY_STATE/routes/$domain/*.caddy" "$file" || return 1
    return 0
  fi
  if grep -qiF "$domain" "$file"; then err "unmanaged domain already appears in Caddyfile: $domain"; return 1; fi
  root=$(caddy_storage_root "$file") || return 1
  site_root=$(caddy_site_root "$domain")
  ensure_site_content "$domain" || return 1
  backup=$(mktemp "$CADDY_STATE/.domain.XXXXXXXX") || return 1
  cp -p "$file" "$backup" || return 1
  mkdir -p "$CADDY_STATE/routes/$domain" && chmod 755 "$CADDY_STATE/routes/$domain" || return 1
  cat >> "$file" <<EOF_SITE

# OneVPS-domain:$domain BEGIN
$domain {
    root * $site_root
    import $CADDY_STATE/routes/$domain/*.caddy
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
  if ! caddy_reload "$file"; then
    cp -p "$backup" "$file"; caddy_reload "$file" || true; rm -f "$backup"; return 1
  fi
  if ! jq -n --arg file "$file" --arg root "$root" '{caddy_file:$file,storage_root:$root}' > "$CADDY_STATE/domains/$domain.json"; then
    cp -p "$backup" "$file"; caddy_reload "$file" || true; rm -f "$backup" "$CADDY_STATE/domains/$domain.json"; return 1
  fi
  rm -f "$backup"
}

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
  exec 9> "$CADDY_STATE/operation.lock"
  flock -n 9 || return 0
  local meta failed=0
  for meta in "$CADDY_STATE/domains/"*.json; do
    [[ -f "$meta" ]] || continue
    caddy_sync_domain "$(basename "$meta" .json)" || failed=1
  done
  return "$failed"
)

caddy_sync_install() {
  local tmp
  mkdir -p "$(dirname "$CADDY_SYNC_RUNNER")" || return 1
  tmp=$(mktemp "${CADDY_SYNC_RUNNER}.XXXXXXXX") || return 1
  cat "$ONEVPS_SCRIPT_PATH" > "$tmp" && bash -n "$tmp" && chmod 700 "$tmp" && mv -f "$tmp" "$CADDY_SYNC_RUNNER" || return 1
  cat > "$ACME_UNIT_DIR/onevps-caddy-sync.service" <<EOF_SERVICE
[Unit]
Description=Deploy Caddy certificates to OneVPS Xray
After=caddy.service
[Service]
Type=oneshot
ExecStart=/bin/bash $CADDY_SYNC_RUNNER --caddy-sync
UMask=0077
EOF_SERVICE
  cat > "$ACME_UNIT_DIR/onevps-caddy-sync.timer" <<'EOF_TIMER'
[Unit]
Description=Check Caddy certificate deployment every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true
[Install]
WantedBy=timers.target
EOF_TIMER
  systemctl daemon-reload && systemctl enable --now onevps-caddy-sync.timer
}

caddy_certificate_issue() (
  local domain="$1" file i
  acme_domain_valid "$domain" || return 1
  prepare_caddy_for_trojan || return 1
  exec 9> "$CADDY_STATE/operation.lock"
  flock -n 9 || { err 'another Caddy certificate operation is running'; return 1; }
  file=$(find_caddyfile)
  caddy_domain_ensure "$domain" "$file" || return 1
  open_port 80 tcp; open_port 443 tcp
  for ((i=0; i<30; i++)); do
    if caddy_sync_domain "$domain"; then return 0; fi
    sleep 2
  done
  err 'Caddy issuance is still pending; retry from Certificates after checking Caddy logs'
  return 1
)

# Configure Caddy for new deployments without inspecting or migrating old resources.
prepare_caddy_for_trojan() (
  local file backup active=false enabled=false committed=false sync_enabled=false
  caddy_state_init || return 1
  exec 8> "$CADDY_STATE/operation.lock"
  flock -n 8 || { err 'another Caddy operation is running'; return 1; }
  file=$(find_caddyfile)
  backup=$(mktemp -d "$CADDY_STATE/backup.XXXXXXXX") || return 1
  [[ -z "$file" ]] || cp -p "$file" "$backup/Caddyfile" || return 1
  systemctl is-active --quiet caddy && active=true
  systemctl is-enabled --quiet caddy && enabled=true
  systemctl is-enabled --quiet onevps-caddy-sync.timer && sync_enabled=true
  rollback_caddy_setup() {
    local status=$? failed=false current
    trap - EXIT INT TERM HUP
    if ! $committed; then
      status=1
      if ! $sync_enabled; then systemctl disable --now onevps-caddy-sync.timer || failed=true; fi
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
  version=$(mktemp -d "$dir/cert.XXXXXXXX") || return 1
  check_log="$version/check.log"
  if [[ -L "$dir/current" ]]; then previous=$(readlink "$dir/current") || return 1
  elif [[ -e "$dir/current" ]]; then err 'refusing unmanaged current certificate'; return 1; fi
  deploy_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $switched && ! $committed; then
      if [[ -n "$previous" ]]; then
        ln -s "$previous" "$version/rollback" && mv -Tf "$version/rollback" "$dir/current" || failed=true
      else rm -f "$dir/current" || failed=true; fi
      if $active; then systemctl restart xray && systemctl is-active --quiet xray || failed=true; fi
      if $failed; then err "certificate rollback failed; retained $version"; exit 1; fi
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
  if [[ -f "$XRAY_NODES" ]] && jq -e --arg path "$dir/current/fullchain.pem" \
    'any(.nodes[]; .enabled == true and .tls_cert == $path)' "$XRAY_NODES" >/dev/null; then used=true; fi
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
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || {
      err 'certificate is expired, invalid or does not match the domain'; return 1;
    }
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
  key_pub=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || return 1
  [[ "$cert_pub" == "$key_pub" ]] || { err 'certificate and unencrypted private key do not match'; return 1; }
}

build_hysteria_inbound() {
  local n="$1" users
  users=$(node_clients "$n") || return 1
  jq -c --argjson users "$users" '{
    tag,listen:"0.0.0.0",port,protocol:"hysteria",
    settings:{version:2,users:$users},
    streamSettings:{network:"hysteria",security:"tls",
      tlsSettings:{serverName:.domain,alpn:["h3"],certificates:[{
        usage:"encipherment",certificateFile:.tls_cert,keyFile:.tls_key}]},
      hysteriaSettings:{version:2}}
  }' <<<"$n"
}

# HY2 mutations use the existing validated configuration/service transaction.
prepare_hy2_change() {
  local source="$1" output="$2" id="$3" action="$4" value="${5:-null}"
  validate_node_metadata "$source" || return 1
  if [[ "$action" == add ]]; then
    jq -e --arg id "$id" 'all(.nodes[]; .id != $id)' "$source" >/dev/null || return 1
    jq -e --arg id "$id" '.id == $id and .type == "hysteria2"' <<<"$value" >/dev/null || return 1
    jq --argjson node "$value" '.nodes += [$node]' "$source" > "$output" || return 1
  else
    jq -e --arg id "$id" 'any(.nodes[]; .id == $id and .type == "hysteria2")' "$source" >/dev/null || return 1
    case "$action" in
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
  ensure_nodes_file
  local name domain password cert key port id node
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
    if port_taken_by_node "$port" udp || port_in_use "$port" udp; then
      warn 'UDP port is already in use'; continue
    fi
    break
  done
  password=$(ask 'Password (Enter for random)' "$(rand_password)")
  id=$(openssl rand -hex 4)
  node=$(jq -nc --arg id "$id" --arg name "$name" --arg domain "$domain" \
    --arg password "$password" --arg cert "$cert" --arg key "$key" --argjson port "$port" \
    '{id:$id,name:$name,tag:("hy2-"+$id),type:"hysteria2",domain:$domain,password:$password,
      port:$port,tls_cert:$cert,tls_key:$key,enabled:true}') || return 1
  if apply_candidate_transaction prepare_hy2_change "$id" add "$node"; then
    open_port "$port" udp
    ok 'Hysteria2 node added; also allow this UDP port in your cloud firewall'
    node_link "$node"
  else
    err 'Hysteria2 node not added'
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

# Trojan inbound: listens on loopback only; Caddy terminates TLS on :443 and
# reverse-proxies the WS path here. No TLS at the Xray layer.
build_trojan_inbound() {
  local n="$1" clients
  clients=$(node_clients "$n") || return 1
  printf '%s\n%s\n' "$n" "$clients" | jq -s '
    .[0] as $n | .[1] as $clients |
    $n.tag as $tag | $n.port as $port | $n.ws_path as $path |
    {
      tag: $tag,
      listen: "127.0.0.1",
      port: $port,
      protocol: "trojan",
      settings: {
        clients: $clients
      },
      streamSettings: {
        network: "ws",
        security: "none",
        wsSettings: { path: $path }
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
  elif [[ "$sel" =~ ^[0-9]+$ ]] && ((sel>=1 && sel<=${#REALITY_DESTS[@]})); then
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
add_reality_node() {
  require_xray
  ensure_nodes_file
  echo; info "Add node - VLESS + TCP + REALITY + Vision + uTLS"

  local name uuid id default_port port target pk pubk sid node
  name=$(ask "Node name" "reality-$(openssl rand -hex 2)")
  uuid=$(ask_uuid)
  id=$(openssl rand -hex 4)

  default_port=443
  if port_taken_by_node "$default_port" || port_in_use "$default_port"; then
    default_port=$(rand_port)
  fi

  while :; do
    port=$(ask "Listen port" "$default_port")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "invalid port"; continue; }
    port=$((10#$port))
    (( port >= 1 && port <= 65535 )) || { warn "port out of range"; continue; }
    if port_taken_by_node "$port"; then warn "port $port already used by another node"; continue; fi
    if port_in_use "$port"; then
      confirm "Port $port appears to be in use. Use anyway?" n || continue
    fi
    break
  done

  target=$(pick_reality_target)
  info "generating X25519 Reality keypair..."
  read -r pk pubk < <(gen_x25519)
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

  jq_update_nodes --argjson node "$node" '.nodes += [$node]'
  open_port "$port" tcp

  if rebuild_config; then
    ok "Reality node added"
    node_link "$(node_by_id "$id")"
  else
    err "config generation failed, rolled back"
    jq_update_nodes --arg id "$id" 'del(.nodes[] | select(.id==$id))'
    close_port "$port" tcp
    rebuild_config || true
  fi
  pause
}

# ----------------------------------------------------------------------------
# [4b] Add Trojan + WS node (behind Caddy)
# ----------------------------------------------------------------------------
add_trojan_node() {
  require_xray
  ensure_nodes_file
  echo; info "Add node - Trojan + WebSocket (behind Caddy)"

  if ! prepare_caddy_for_trojan; then
    err "Caddy required for Trojan nodes but could not be installed"
    pause; return
  fi
  local cfile
  cfile=$(find_caddyfile)
  if [[ -z "$cfile" ]]; then
    err "Caddyfile still not found after install"
    pause; return
  fi
  info "using Caddyfile: $cfile"

  local name domain password path id port node
  name=$(ask "Node name" "trojan-$(openssl rand -hex 2)")

  domain=$(normalize_domain "$(ask "Trojan subdomain (DNS A/AAAA -> this server)")")
  while ! is_valid_domain "$domain"; do
    warn "invalid domain"
    domain=$(normalize_domain "$(ask "Trojan subdomain")")
  done
  if grep -qiF "$domain" "$cfile" 2>/dev/null && [[ ! -f "$CADDY_STATE/domains/$domain.json" ]]; then
    err "$domain already appears in $cfile; pick another subdomain or remove the existing block first"
    pause; return
  fi

  password=$(ask "Password (Enter for random)" "$(rand_password)")
  path="/$(openssl rand -hex 8)"
  id=$(openssl rand -hex 4)
  port=$(rand_port)   # loopback-only inbound; firewall untouched

  node=$(jq -n \
    --arg id "$id" --arg name "$name" --arg tag "trojan-$id" \
    --argjson port "$port" --arg pw "$password" \
    --arg domain "$domain" --arg path "$path" --arg cfile "$cfile" '
    {
      id: $id,
      type: "trojan-ws",
      name: $name,
      tag: $tag,
      port: $port,
      password: $pw,
      domain: $domain,
      ws_path: $path,
      caddy_file: $cfile,
      enabled: true
    }')

  jq_update_nodes --argjson node "$node" '.nodes += [$node]'

  if ! caddy_add_route "$id" "$domain" "$path" "$port" "$cfile"; then
    err "Caddy update failed, rolled back"
    jq_update_nodes --arg id "$id" 'del(.nodes[]|select(.id==$id))'
    pause; return
  fi

  if rebuild_config; then
    ok "Trojan node added"
    info "ensure DNS A/AAAA for $domain points here so Caddy can issue its cert"
    node_link "$(node_by_id "$id")"
  else
    err "Xray config generation failed, rolled back"
    caddy_remove_route "$id" "$cfile"; caddy_reload "$cfile" || true
    jq_update_nodes --arg id "$id" 'del(.nodes[]|select(.id==$id))'
    rebuild_config || true
  fi
  pause
}

# ----------------------------------------------------------------------------
# Share links
# ----------------------------------------------------------------------------
node_link() {
  local n="$1" type name port link addr uuid sni pubk sid spx fp pw domain path
  type=$(jq -r '.type' <<<"$n")
  name=$(jq -r '.name' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  link=""

  if [[ "$type" == "vless-reality" ]]; then
    addr="$(pub_ip)"
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
    pw=$(jq -r '.password' <<<"$n")
    domain=$(jq -r '.domain' <<<"$n")
    printf '\n%s-- %s (Hysteria2 + QUIC + TLS) --%s\n' "$c_grn" "$name" "$c_rst"
    printf 'hysteria2://%s@%s:%s/?sni=%s#%s\n' \
      "$(urlenc "$pw")" "$domain" "$port" "$(urlenc "$domain")" "$(urlenc "$name")"
  elif [[ "$type" == "trojan-ws" ]]; then
    pw=$(jq -r '.password' <<<"$n")
    domain=$(jq -r '.domain' <<<"$n")
    path=$(jq -r '.ws_path' <<<"$n")
    link="trojan://$(urlenc "$pw")@${domain}:443?security=tls&sni=${domain}&type=ws&host=${domain}&path=$(urlenc "$path")#$(urlenc "$name")"
    echo
    printf '%s-- %s (Trojan + WS behind Caddy) --%s\n' "$c_grn" "$name" "$c_rst"
    echo "$link"
    printf '%sDomain: %s  path: %s  upstream: 127.0.0.1:%s%s\n' "$c_ylw" \
      "$domain" "$path" "$port" "$c_rst"
  fi
}

show_links() {
  require_xray
  ensure_nodes_file
  [[ "$(node_count)" -gt 0 ]] || { warn "no nodes"; pause; return; }
  local n
  while IFS= read -r n; do node_link "$n"; done < <(jq -c '.nodes[]' "$XRAY_NODES")
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
      trojan-ws) kind="trojan"; dest=$(jq -r '.domain' <<<"$n") ;;
      hysteria2) kind="hy2"; dest=$(jq -r '.domain' <<<"$n") ;;
      *)         kind="reality"; dest=$(jq -r '.reality_target' <<<"$n") ;;
    esac
    printf '  %d) %-18s %-8s port:%-6s %-26s %s\n' \
      "$i" "$(jq -r '.name' <<<"$n")" "$kind" "$(jq -r '.port' <<<"$n")" \
      "$dest" \
      "$([[ "$en" == true ]] && echo "$st" || echo "${c_ylw}$st${c_rst}")"
  done < <(jq -c '.nodes[]' "$XRAY_NODES")
}

pick_node() {
  local cnt sel
  cnt=$(node_count)
  [[ "$cnt" -gt 0 ]] || { echo ""; return; }
  list_nodes >&2
  sel=$(ask $'Select node number (Enter to go back)' "")
  [[ "$sel" =~ ^[0-9]+$ ]] || { echo ""; return; }
  (( sel>=1 && sel<=cnt )) || { echo ""; return; }
  jq -r --argjson i "$((sel-1))" '.nodes[$i].id' "$XRAY_NODES"
}

manage_nodes() {
  require_xray
  ensure_nodes_file
  [[ "$(node_count)" -gt 0 ]] || { warn "no nodes, add one first"; pause; return; }
  local id n type
  id=$(pick_node)
  [[ -n "$id" ]] || return
  n=$(node_by_id "$id")
  type=$(jq -r '.type' <<<"$n")

  while :; do
    clear
    node_link "$n"
    if [[ "$type" == "hysteria2" ]]; then
      printf '\nConnection settings:\n1) Change UDP port\n2) Reset default password\n\nUsers / outbound:\n7) Manage node users\n8) Set node outbound\n\nNode status:\n5) Enable/disable node\n\nDanger zone:\n6) Delete node\n\n0) Back\n'
      case "$(ask 'Select')" in
        1) edit_port "$id" ;;
        2) reset_trojan_password "$id" ;;
        5) toggle_enabled "$id" ;;
        6) del_node "$id"; return ;;
        7) manage_node_users "$id" || true ;;
        8) manage_outbound "$id" || true ;;
        0|"") return ;;
        *) continue ;;
      esac
    elif [[ "$type" == "trojan-ws" ]]; then
      cat <<EOF

  Connection settings:
   1) Reset default password
   2) Change domain
   3) Change WS path
   4) Rebuild Caddy route

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
        1) reset_trojan_password "$id" ;;
        2) edit_trojan_domain "$id" ;;
        3) edit_trojan_path "$id" ;;
        4) rebuild_trojan_route "$id" ;;
        5) toggle_enabled "$id" ;;
        6) del_node "$id"; return ;;
        7) manage_node_users "$id" || true ;;
        8) manage_outbound "$id" || true ;;
        0|"") return ;;
        *) continue ;;
      esac
    else
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
        1) edit_port "$id" ;;
        2) reset_uuid "$id" ;;
        3) rotate_reality_secret "$id" ;;
        4) edit_reality_target "$id" ;;
        5) toggle_enabled "$id" ;;
        6) del_node "$id"; return ;;
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

edit_port() {
  local id="$1" n newp oldp proto=tcp
  n=$(node_by_id "$id")
  [[ $(jq -r '.type' <<<"$n") != hysteria2 ]] || proto=udp
  while :; do
    newp=$(ask "New port" "$(jq -r '.port' <<<"$n")")
    [[ "$newp" =~ ^[0-9]+$ ]] || { warn "invalid port"; continue; }
    newp=$((10#$newp))
    (( newp >= 1 && newp <= 65535 )) || { warn "port out of range"; continue; }
    if port_taken_by_node "$newp" "$proto" "$id"; then
      warn "port used by another node"; continue
    fi
    if [[ "$newp" != "$(jq -r '.port' <<<"$n")" ]] && port_in_use "$newp" "$proto"; then
      if [[ "$proto" == udp ]]; then warn 'UDP port is already in use'; continue; fi
      confirm "Port $newp appears to be in use. Use anyway?" n || continue
    fi
    break
  done
  oldp=$(jq -r '.port' <<<"$n")
  if [[ "$proto" == udp ]]; then
    if apply_candidate_transaction prepare_hy2_change "$id" port "$newp"; then
      [[ "$newp" == "$oldp" ]] || close_port "$oldp" udp
      open_port "$newp" udp
      ok "port changed to $newp"
    else err 'port unchanged'; fi
    pause; return
  fi
  jq_update_nodes --arg id "$id" --argjson p "$newp" '(.nodes[]|select(.id==$id)).port = $p'
  if [[ "$newp" != "$oldp" ]]; then close_port "$oldp" tcp; fi
  open_port "$newp" tcp
  rebuild_config && ok "port changed to $newp" || err "apply failed"
  pause
}

reset_uuid() {
  local id="$1" new_uuid
  new_uuid=$(ask_uuid)
  printf '%s\n' "$new_uuid" | jq -R . | apply_node_user_change "$id" reset || { err 'apply failed'; return 1; }
  ok "UUID reset"
  pause
}

rotate_reality_secret() {
  local id="$1" pk pubk sid
  confirm "Rotate Reality keypair and shortId? Existing links for this node will stop working." n || return
  read -r pk pubk < <(gen_x25519)
  sid=$(rand_short_id)
  jq_update_nodes --arg id "$id" --arg pk "$pk" --arg pubk "$pubk" --arg sid "$sid" '
    (.nodes[]|select(.id==$id)) |=
      (.reality_private_key=$pk | .reality_public_key=$pubk | .reality_short_id=$sid)'
  rebuild_config && ok "Reality keypair rotated" || err "apply failed"
  pause
}

edit_reality_target() {
  local id="$1" target
  target=$(pick_reality_target)
  jq_update_nodes --arg id "$id" --arg target "$target" '
    (.nodes[]|select(.id==$id)) |= (.reality_sni=$target | .reality_target=$target | .reality_target_port=443)'
  rebuild_config && ok "target changed to $target" || err "apply failed"
  pause
}

reset_trojan_password() {
  local id="$1" pw
  pw=$(ask "New default password (Enter for random)" "$(rand_password)")
  printf '%s\n' "$pw" | jq -R . | apply_node_user_change "$id" reset || { err 'apply failed'; return 1; }
  ok "password reset"
  pause
}

edit_trojan_domain() {
  local id="$1" n cf port path olddom newdom
  n=$(node_by_id "$id")
  cf=$(jq -r '.caddy_file' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  path=$(jq -r '.ws_path' <<<"$n")
  olddom=$(jq -r '.domain' <<<"$n")
  newdom=$(normalize_domain "$(ask "New subdomain (DNS A/AAAA -> this server)" "$olddom")")
  while ! is_valid_domain "$newdom"; do
    warn "invalid domain"
    newdom=$(normalize_domain "$(ask "New subdomain")")
  done
  if [[ "$newdom" == "$olddom" ]]; then warn "unchanged"; pause; return; fi

  # Drop our old block first so the collision check ignores it.
  caddy_remove_route "$id" "$cf"
  if grep -qiF "$newdom" "$cf" 2>/dev/null && [[ ! -f "$CADDY_STATE/domains/$newdom.json" ]]; then
    err "$newdom already appears in $cf; restoring old route"
    caddy_add_route "$id" "$olddom" "$path" "$port" "$cf" || true
    pause; return
  fi
  if ! caddy_add_route "$id" "$newdom" "$path" "$port" "$cf"; then
    err "Caddy update failed; restoring old route"
    caddy_add_route "$id" "$olddom" "$path" "$port" "$cf" || true
    pause; return
  fi
  jq_update_nodes --arg id "$id" --arg d "$newdom" \
    '(.nodes[]|select(.id==$id)).domain = $d'
  rebuild_config && ok "domain changed to $newdom" || err "apply failed"
  info "ensure DNS for $newdom points here so Caddy can issue its cert"
  pause
}

edit_trojan_path() {
  local id="$1" n cf port domain newpath
  n=$(node_by_id "$id")
  cf=$(jq -r '.caddy_file' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  domain=$(jq -r '.domain' <<<"$n")
  newpath=$(ask "New WS path" "$(jq -r '.ws_path' <<<"$n")")
  [[ "$newpath" == /* ]] || newpath="/$newpath"
  caddy_remove_route "$id" "$cf"
  if ! caddy_add_route "$id" "$domain" "$newpath" "$port" "$cf"; then
    err "Caddy update failed"; pause; return
  fi
  jq_update_nodes --arg id "$id" --arg p "$newpath" \
    '(.nodes[]|select(.id==$id)).ws_path = $p'
  rebuild_config && ok "WS path changed to $newpath" || err "apply failed"
  pause
}

# Regenerate the Caddy block for an existing node from its stored fields,
# without changing the password/path/port (share link stays valid). Use after
# updating the script to roll an old node onto the current Caddy template.
rebuild_trojan_route() {
  local id="$1" n cf domain path port
  n=$(node_by_id "$id")
  cf=$(jq -r '.caddy_file' <<<"$n")
  domain=$(jq -r '.domain' <<<"$n")
  path=$(jq -r '.ws_path' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  if [[ ! -f "$cf" ]]; then
    cf=$(find_caddyfile)
    [[ -n "$cf" ]] || { err "Caddyfile not found"; pause; return; }
  fi
  caddy_remove_route "$id" "$cf"
  if caddy_add_route "$id" "$domain" "$path" "$port" "$cf"; then
    ok "Caddy route rebuilt for $domain"
  else
    err "rebuild failed"
  fi
  pause
}

toggle_enabled() {
  local id="$1"
  if [[ $(node_by_id "$id" | jq -r '.type') == hysteria2 ]]; then
    apply_candidate_transaction prepare_hy2_change "$id" toggle && ok 'enabled state toggled' || err 'apply failed'
    pause; return
  fi
  jq_update_nodes --arg id "$id" '(.nodes[]|select(.id==$id)).enabled |= (.|not)'
  rebuild_config && ok "enabled state toggled" || err "apply failed"
  pause
}

del_node() {
  local id="$1" n port type cf
  confirm "Delete this node?" n || return
  n=$(node_by_id "$id")
  port=$(jq -r '.port' <<<"$n")
  type=$(jq -r '.type' <<<"$n")
  if [[ "$type" == hysteria2 ]]; then
    if apply_candidate_transaction prepare_hy2_change "$id" delete; then
      close_port "$port" udp
      ok 'deleted; externally managed certificate files were kept'
    else err 'delete failed'; fi
    pause; return
  fi
  jq_update_nodes --arg id "$id" 'del(.nodes[]|select(.id==$id))'
  if [[ "$type" == "trojan-ws" ]]; then
    cf=$(jq -r '.caddy_file' <<<"$n")
    caddy_remove_route "$id" "$cf"; caddy_reload "$cf" || true
  else
    close_port "$port" tcp
  fi
  rebuild_config && ok "deleted" || err "apply failed"
  pause
}

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
# TCP optimization
# ----------------------------------------------------------------------------
write_tune_conf() {
  local key values min initial maximum rmem wmem
  for key in tcp_rmem tcp_wmem; do
    values=$(sysctl -n "net.ipv4.$key" 2>/dev/null) || {
      err "cannot read $key; tuning file unchanged"; return 1;
    }
    # Restrict size before arithmetic to avoid overflow and reject multiline data.
    if [[ ! "$values" =~ ^[[:blank:]]*[0-9]{1,10}[[:blank:]]+[0-9]{1,10}[[:blank:]]+[0-9]{1,10}[[:blank:]]*$ ]]; then
      err "invalid $key triple; tuning file unchanged"; return 1
    fi
    read -r min initial maximum <<<"$values"
    min=$((10#$min)); initial=$((10#$initial)); maximum=$((10#$maximum))
    if (( min <= 0 || min > initial || initial > maximum || initial > 67108864 )); then
      err "invalid $key bounds; tuning file unchanged"; return 1
    fi
    if [[ "$key" == tcp_rmem ]]; then rmem="$min $initial"; else wmem="$min $initial"; fi
  done
  if ! cat > "$TUNE_CONF" <<EOF
# OneVPS TCP tuning
# Ceilings are not preallocated; preserve current minimum and initial buffers.
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = $rmem 67108864
net.ipv4.tcp_wmem = $wmem 67108864
# TFO requires application support; no universal speedup is guaranteed.
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
# Shared socket/backlog/port settings can also affect non-TCP traffic.
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
# Unsent-data readiness threshold, not a hard cap on all send memory.
net.ipv4.tcp_notsent_lowat = 131072
EOF
  then
    err "cannot write $TUNE_CONF; tuning not applied"; return 1
  fi
  apply_sysctl_file "$TUNE_CONF" || return 1
  ok "TCP tuning applied ($TUNE_CONF)"
}

optimize_system() {
  echo; info "TCP optimization"
  if [[ -f "$TUNE_CONF" ]]; then
    info "TCP tuning configuration file exists ($TUNE_CONF); runtime state not verified"
    if confirm "Re-apply (overwrite)?" n; then
      write_tune_conf || err "TCP tuning failed; some settings may already be applied"
    fi
  else
    if confirm "Apply TCP tuning (buffer ceilings, TFO, backlog)?" y; then
      write_tune_conf || err "TCP tuning failed; some settings may already be applied"
    fi
  fi
  pause
}

# ----------------------------------------------------------------------------
# Service / uninstall
# ----------------------------------------------------------------------------
restart_service() {
  require_xray
  rebuild_config
  run_with_progress 'Restarting Xray service' systemctl restart xray && ok "restarted" || err "restart failed"
  systemctl --no-pager -l status xray 2>/dev/null | head -n 8 || true
  pause
}

uninstall() {
  warn "Uninstall removes Xray binary, config, onevps nodes and logs"
  warn "(BBR/system tuning configs and the swap file are kept)"
  confirm "Confirm uninstall?" n || return
  local node route_id route_file
  while IFS= read -r node; do
    route_id=$(jq -r '.id' <<< "$node")
    route_file=$(jq -r '.caddy_file' <<< "$node")
    caddy_remove_route "$route_id" "$route_file" && caddy_reload "$route_file" || {
      err 'Caddy route cleanup failed; Xray uninstall cancelled'; return 1;
    }
  done < <(jq -c '.nodes[] | select(.type == "trojan-ws")' "$XRAY_NODES")
  systemctl disable --now onevps-caddy-sync.timer 2>/dev/null || true
  warn 'Caddy domain sites and certificates are retained; certificate sync to Xray is disabled.'
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f "$XRAY_SERVICE" /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d
  systemctl daemon-reload
  rm -f "$XRAY_BIN"
  rm -rf "$XRAY_DIR" /usr/local/share/xray /var/log/xray
  ok "uninstalled"
  pause
}

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
  local pid port udp sockets
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
  done < <(jq -r '.endpoints[] | "\(.listen | split(":") | last) \(.network.use_udp)"' "$REALM_DIR/config.json")
}

realm_apply() {
  local candidate="$1" backup was_active=false was_enabled=false
  realm_owned || { err "realm is not managed by OneVPS"; return 1; }
  jq -e '.endpoints | type == "array"' "$candidate" >/dev/null || return 1
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

realm_add() {
  local port host remote_port mode endpoint candidate sockets
  port=$(ask 'Local listening port')
  host=$(ask 'Destination IP or hostname (IPv6 without brackets)')
  remote_port=$(ask 'Destination port')
  mode=$(ask 'Protocol: tcp or both (TCP+UDP)' tcp)
  endpoint=$(realm_endpoint "$port" "$host" "$remote_port" "$mode") || { err "invalid relay input"; return 1; }
  command -v ss >/dev/null 2>&1 || { err "ss is required to check listening ports; install iproute2/iproute"; return 1; }
  sockets=$(ss -H -lntu) || { err "cannot inspect listening ports"; return 1; }
  if awk '{print $5}' <<<"$sockets" | grep -qE ":$port$"; then
    err "port $port is already in use"; return 1
  fi
  warn "relay listens on all IPv4 interfaces; it adds no authentication or encryption"
  confirm "Forward port $port to $host:$remote_port ($mode)?" || return 0
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
}

realm_list() {
  jq -r '.endpoints | to_entries[] | "\(.key + 1)) \(.value.listen) -> \(.value.remote) [\(if .value.network.use_udp then "TCP+UDP" else "TCP" end)]"' \
    "$REALM_DIR/config.json"
}

realm_delete() {
  local index count candidate
  realm_list
  count=$(jq '.endpoints | length' "$REALM_DIR/config.json")
  index=$(ask 'Rule number to delete (empty cancels)')
  [[ -n "$index" ]] || return 0
  [[ "$index" =~ ^[1-9][0-9]{0,5}$ ]] && (( index <= count )) || { err "invalid rule number"; return 1; }
  confirm "Delete rule $index?" || return 0
  candidate=$(mktemp "$REALM_DIR/.candidate.XXXXXX") || return 1
  if jq --argjson index "$((index - 1))" 'del(.endpoints[$index])' "$REALM_DIR/config.json" > "$candidate" &&
     realm_apply "$candidate"; then
    ok "rule removed"
  else
    rm -f "$candidate"; return 1
  fi
}

realm_uninstall() {
  realm_owned || { err "refusing to remove unmanaged realm installation"; return 1; }
  confirm 'Remove OneVPS realm and all its relay rules?' || return 0
  systemctl stop onevps-realm && systemctl disable onevps-realm || return 1
  rm -f "$REALM_BIN" "$REALM_SERVICE"
  rm -rf "$REALM_DIR"
  systemctl daemon-reload
  ok "realm removed; firewall rules were not changed"
}

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
  local target="$ONEVPS_SCRIPT_PATH" tmp first_line=""
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
  IFS= read -r first_line < "$tmp/onevps.sh" || true
  if [[ "$first_line" != '#!/usr/bin/env bash' ]] || ! bash -n "$tmp/onevps.sh"; then
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
    v=$(installed_version)
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
    printf '\nNodes / share links:\n1) Add VLESS Reality\n2) Add Trojan WS\n3) Add Hysteria2\n4) Manage nodes / users / outbound\n5) Show share links\n0) Back\n'
    case "$(ask 'Select')" in
      1) add_reality_node ;;
      2) add_trojan_node ;;
      3) add_hysteria_node ;;
      4) manage_nodes ;;
      5) show_links ;;
      0|"") return ;;
      *) warn 'invalid selection' ;;
    esac
  done
}

network_menu() {
  while :; do
    printf '\nService / network:\n1) Restart Xray service\n2) Enable BBR / show status\n3) TCP optimization\n0) Back\n'
    case "$(ask 'Select')" in
      1) restart_service ;;
      2) enable_bbr || { err 'BBR configuration failed; some settings may already be applied'; pause; } ;;
      3) optimize_system ;;
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
      1) install_xray; pause ;;
      2) node_menu ;;
      3) certificate_menu ;;
      4) realm_menu ;;
      5) network_menu ;;
      6) if update_script; then return 0; else pause; fi ;;
      9) uninstall ;;
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
