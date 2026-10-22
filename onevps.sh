#!/usr/bin/env bash
#
# OneVPS - sing-box node setup script
# Protocols:
#   - VLESS + TCP + REALITY + XTLS Vision + uTLS (standalone)
#   - Trojan + WebSocket behind Caddy (coexists with Caddy-proxied sites)
#   - Hysteria 2 + native ACME HTTP-01 (standalone UDP)
#
set -euo pipefail
umask 077

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
SINGBOX_DIR=/usr/local/etc/onevps
SINGBOX_BIN=/usr/local/bin/onevps-sing-box
SINGBOX_CONF=$SINGBOX_DIR/config.json
SINGBOX_NODES=$SINGBOX_DIR/onevps-nodes.json
SINGBOX_SERVICE=/etc/systemd/system/onevps-sing-box.service
SINGBOX_VERSION=v1.14.3
SINGBOX_ACME_DIR=/var/lib/onevps-acme
TUNE_CONF=/etc/sysctl.d/99-onevps-tune.conf
BBR_CONF=/etc/sysctl.d/99-bbr.conf
REALITY_PROBE_ROUNDS=3
REALM_DIR=/usr/local/etc/onevps-realm
REALM_BIN=/usr/local/bin/onevps-realm
REALM_SERVICE=/etc/systemd/system/onevps-realm.service
REALM_VERSION=v2.9.6

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
  if [[ -x "$SINGBOX_BIN" ]]; then "$SINGBOX_BIN" generate uuid | tr 'A-Z' 'a-z'; return; fi
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
  PUBIP=$(curl -fsSL4 --max-time 8 https://api.ipify.org 2>/dev/null \
       || curl -fsSL4 --max-time 8 https://ifconfig.me 2>/dev/null || true)
  echo "$PUBIP"
}

require_singbox() {
  singbox_owned && [[ -x "$SINGBOX_BIN" ]] || die "run menu option [1] to install OneVPS sing-box first"
}

installed_version() {
  [[ -x "$SINGBOX_BIN" ]] || { echo ""; return; }
  "$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version /{print $3; exit}'
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
  require_singbox
  local kp pk pubk
  kp=$("$SINGBOX_BIN" generate reality-keypair) || return 1
  pk=$(awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$kp")
  pubk=$(awk -F': ' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$kp")
  [[ -n "$pk" && -n "$pubk" ]] || die "failed to parse sing-box x25519 keypair"
  printf '%s %s\n' "$pk" "$pubk"
}

# ----------------------------------------------------------------------------
# [1] Environment check
# ----------------------------------------------------------------------------
check_env() {
  [[ $EUID -eq 0 ]] || die "must run as root (sudo bash $0)"
  command -v systemctl >/dev/null 2>&1 || die "systemd not found; this script relies on systemd to manage sing-box"
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
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
    zypper) zypper install -y --no-recommends "$@" ;;
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
# [2] Install / update sing-box
# ----------------------------------------------------------------------------
write_service() {
  cat <<EOF
# Managed by OneVPS sing-box
[Unit]
Description=OneVPS sing-box
Documentation=https://sing-box.sagernet.org/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=nobody
WorkingDirectory=$SINGBOX_DIR
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=-$SINGBOX_ACME_DIR

[Install]
WantedBy=multi-user.target
EOF
}

secure_singbox_files() {
  local ng
  ng=$(id -gn nobody) || return 1
  chown root:"$ng" "$SINGBOX_DIR" "$SINGBOX_CONF" "$SINGBOX_NODES" || return 1
  chmod 750 "$SINGBOX_DIR" && chmod 640 "$SINGBOX_CONF" "$SINGBOX_NODES"
}

singbox_owned() {
  local p
  for p in "$SINGBOX_DIR" "$SINGBOX_BIN" "$SINGBOX_CONF" "$SINGBOX_NODES" "$SINGBOX_SERVICE" "$SINGBOX_DIR/.onevps-managed"; do
    [[ ! -L "$p" ]] || return 1
  done
  [[ -f "$SINGBOX_DIR/.onevps-managed" && -f "$SINGBOX_SERVICE" ]] &&
    grep -qx 'OneVPS sing-box schema 1' "$SINGBOX_DIR/.onevps-managed" &&
    grep -qx '# Managed by OneVPS sing-box' "$SINGBOX_SERVICE"
}

check_singbox_conflicts() {
  local p unit loaded
  # No migration and no dual-core installation, even if the old unit is stopped.
  for p in /usr/local/etc/xray /etc/xray /etc/sing-box /usr/local/etc/sing-box /etc/singbox /usr/local/etc/singbox; do
    if [[ -e "$p" || -L "$p" ]]; then err "conflicting configuration: $p"; return 1; fi
  done
  for unit in xray.service xray@.service sing-box.service singbox.service; do
    loaded=$(systemctl show -p LoadState --value "$unit") || return 1
    if [[ "$loaded" != not-found ]]; then err "conflicting service: $unit"; return 1; fi
  done
  if singbox_owned; then
    [[ -x "$SINGBOX_BIN" && -f "$SINGBOX_CONF" && -f "$SINGBOX_NODES" ]] || return 1
    validate_node_metadata "$SINGBOX_NODES" || return 1
  else
    for p in "$SINGBOX_DIR" "$SINGBOX_BIN" "$SINGBOX_SERVICE"; do
      if [[ -e "$p" || -L "$p" ]]; then err "refusing unmanaged path: $p"; return 1; fi
    done
    loaded=$(systemctl show -p LoadState --value onevps-sing-box.service) || return 1
    [[ "$loaded" == not-found ]] || { err 'unmanaged onevps-sing-box service'; return 1; }
  fi
  for p in /etc/systemd/system/onevps-sing-box.service.d /run/systemd/system/onevps-sing-box.service.d; do
    [[ ! -e "$p" && ! -L "$p" ]] || { err "unmanaged service override: $p"; return 1; }
  done
}

# Download only the pinned official asset. Missing/invalid API digest fails closed.
# Extract one regular member to stdout: never unpack archive paths or links.
download_singbox() {
  local dest="$1" asset url digest actual member listing
  case "$ARCH" in amd64|arm64|armv7) ;; *) return 1 ;; esac
  asset="sing-box-${SINGBOX_VERSION#v}-linux-$ARCH.tar.gz"
  member="${asset%.tar.gz}/sing-box"
  mkdir "$dest/download" || return 1
  curl -fsSL --proto '=https' --connect-timeout 15 --max-time 60 \
    "https://api.github.com/repos/SagerNet/sing-box/releases/tags/$SINGBOX_VERSION" > "$dest/download/release.json" || return 1
  url=$(jq -er --arg name "$asset" --arg version "$SINGBOX_VERSION" \
    'select(.tag_name == $version) | [.assets[] | select(.name == $name)] | select(length == 1) | .[0].browser_download_url' "$dest/download/release.json") || return 1
  digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest' "$dest/download/release.json") || return 1
  [[ "$url" == "https://github.com/SagerNet/sing-box/releases/download/$SINGBOX_VERSION/$asset" && "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  curl -fsSL --proto '=https' --connect-timeout 15 --max-time 180 "$url" -o "$dest/download/archive.tar.gz" || return 1
  actual=$(openssl dgst -sha256 "$dest/download/archive.tar.gz") || return 1
  [[ "${actual##* }" == "${digest#sha256:}" ]] || { err 'sing-box SHA-256 mismatch'; return 1; }
  listing=$(tar -tvzf "$dest/download/archive.tar.gz" "$member") || return 1
  [[ "$listing" == -* && "$listing" != *$'\n'* ]] || return 1
  tar -xOzf "$dest/download/archive.tar.gz" "$member" > "$dest/sing-box" || return 1
  chmod 755 "$dest/sing-box" || return 1
  [[ $("$dest/sing-box" version | awk '/^sing-box version /{print $3; exit}') == "${SINGBOX_VERSION#v}" ]]
}

install_singbox() (
  ensure_deps
  check_singbox_conflicts || return 1
  local tx owned=false active=false enabled=false touched=false committed=false
  tx=$(mktemp -d) || return 1
  singbox_owned && owned=true
  systemctl is-active --quiet onevps-sing-box && active=true
  systemctl is-enabled --quiet onevps-sing-box && enabled=true
  install_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      systemctl stop onevps-sing-box || failed=true
      if $owned; then
        cp -p "$tx/binary.backup" "$SINGBOX_BIN" || failed=true
        cp -p "$tx/service.backup" "$SINGBOX_SERVICE" || failed=true
        cp -p "$tx/config.backup" "$SINGBOX_CONF" || failed=true
        cp -p "$tx/nodes.backup" "$SINGBOX_NODES" || failed=true
      else
        systemctl disable onevps-sing-box || failed=true
        rm -f "$SINGBOX_BIN" "$SINGBOX_SERVICE" "$SINGBOX_CONF" "$SINGBOX_NODES" "$SINGBOX_DIR/.onevps-managed" || failed=true
        rmdir "$SINGBOX_DIR" || failed=true
      fi
      systemctl daemon-reload || failed=true
      if $owned; then
        if $enabled; then systemctl enable onevps-sing-box || failed=true; else systemctl disable onevps-sing-box || failed=true; fi
        if $active; then systemctl restart onevps-sing-box && systemctl is-active --quiet onevps-sing-box || failed=true; fi
      fi
      status=1
    fi
    if $failed; then err "ROLLBACK FAILED; recovery files retained at $tx"; else rm -rf "$tx"; fi
    exit "$status"
  }
  trap install_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  download_singbox "$tx" || { err 'verified sing-box download failed'; return 1; }
  if $owned; then
    cp -p "$SINGBOX_BIN" "$tx/binary.backup" && cp -p "$SINGBOX_SERVICE" "$tx/service.backup" &&
      cp -p "$SINGBOX_CONF" "$tx/config.backup" && cp -p "$SINGBOX_NODES" "$tx/nodes.backup" || return 1
    cp "$SINGBOX_NODES" "$tx/nodes.json" || return 1
  else
    printf '{"schema_version":1,"nodes":[]}\n' > "$tx/nodes.json" || return 1
  fi
  render_config "$tx/nodes.json" "$tx/config.json" || return 1
  "$tx/sing-box" check -c "$tx/config.json" > "$tx/check.log" 2>&1 || { err 'candidate validation failed'; return 1; }
  write_service > "$tx/service" || return 1
  touched=true
  mkdir -p "$SINGBOX_DIR" || return 1
  install -m 755 "$tx/sing-box" "$SINGBOX_BIN" &&
    install -m 644 "$tx/service" "$SINGBOX_SERVICE" &&
    cp "$tx/config.json" "$SINGBOX_CONF" && cp "$tx/nodes.json" "$SINGBOX_NODES" || return 1
  printf 'OneVPS sing-box schema 1\n' > "$SINGBOX_DIR/.onevps-managed" || return 1
  secure_singbox_files && hysteria2_preflight "$SINGBOX_NODES" &&
    systemctl daemon-reload && systemctl enable onevps-sing-box &&
    systemctl restart onevps-sing-box && systemctl is-active --quiet onevps-sing-box || return 1
  verify_hysteria2_nodes "$SINGBOX_NODES" "$tx" || return 1
  committed=true
  ok "sing-box $(installed_version) installed"
)

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

node_network() {
  if [[ "$1" == hysteria2 ]]; then printf 'udp\n'; else printf 'tcp\n'; fi
}

port_in_use() {
  local p="$1" proto="${2:-tcp}" flags
  case "$proto" in tcp) flags=-tnl ;; udp) flags=-unl ;; *) return 2 ;; esac
  if command -v ss >/dev/null 2>&1; then
    ss "$flags" 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"
  else
    return 1
  fi
}

port_taken_by_node() {
  [[ -f "$SINGBOX_NODES" ]] || return 1
  jq -e --argjson p "$1" --arg proto "${2:-tcp}" --arg exclude "${3:-}" '
    .nodes[] | select(.id != $exclude and .port == $p and
      (if .type == "hysteria2" then "udp" else "tcp" end) == $proto)' "$SINGBOX_NODES" >/dev/null 2>&1
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
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || return 1
      chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list || return 1
      chmod 0644 /etc/apt/sources.list.d/caddy-stable.list
      if DEBIAN_FRONTEND=noninteractive apt-get update -qq \
         && apt-get install -y -qq caddy; then
        return 0
      fi
      # Don't leave a broken/unsigned repo poisoning future apt runs.
      rm -f /etc/apt/sources.list.d/caddy-stable.list
      return 1
      ;;
    dnf)
      dnf install -y -q 'dnf-command(copr)' || return 1
      dnf copr enable -y @caddy/caddy || return 1
      dnf install -y -q caddy
      ;;
    yum)
      yum install -y -q yum-plugin-copr || return 1
      yum copr enable -y @caddy/caddy || return 1
      yum install -y -q caddy
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

  ver=$(curl -fsSL --connect-timeout 10 --max-time 30 \
          https://api.github.com/repos/caddyserver/caddy/releases/latest 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')

  if [[ -n "$ver" ]] && command -v tar >/dev/null 2>&1; then
    url="https://github.com/caddyserver/caddy/releases/download/v${ver}/caddy_${ver}_linux_${gh_arch}.tar.gz"
    info "downloading Caddy ${ver} (${gh_arch}) from GitHub..."
    if curl -fL --connect-timeout 15 --max-time 180 --retry 2 "$url" -o "$td/caddy.tar.gz" \
       && tar -xzf "$td/caddy.tar.gz" -C "$td" caddy 2>/dev/null; then
      install -m 0755 "$td/caddy" /usr/local/bin/caddy || true
    fi
  fi

  if ! caddy_present; then
    local carch="$gh_arch"; [[ "$gh_arch" == armv7 ]] && carch="arm&arm=7"
    info "trying caddyserver.com download API..."
    if curl -fL --connect-timeout 15 --max-time 180 \
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
    systemctl start caddy >/dev/null 2>&1 || true
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
    systemctl reload caddy >/dev/null 2>&1 && return 0
  fi
  if caddy_present; then
    caddy reload --adapter caddyfile --config "$file" >/dev/null 2>&1 && return 0
  fi
  err "failed to reload Caddy"
  return 1
}

# Web root served for non-WS traffic on a Trojan subdomain.
caddy_site_root() { echo "/var/lib/onevps/sites/$1"; }

# Drop a small static landing page so casual probes see a site, not a 404.
# Never overwrites an existing index.html (user may customize it).
ensure_site_content() {
  local domain="$1" root
  root=$(caddy_site_root "$domain")
  mkdir -p "$root"
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
  chmod -R a+rX /var/lib/onevps 2>/dev/null || true
}

# Append a marked site block routing a secret WS path to a local sing-box inbound.
# Requests to the secret path are proxied to sing-box (reverse_proxy handles the
# WebSocket upgrade); every other path returns HTTP 403 with the styled 403
# page, so the rest of the subdomain looks like a locked-down site.
# Reverts the append if Caddy reload fails. Returns non-zero on failure.
caddy_add_route() {
  local id="$1" domain="$2" path="$3" port="$4" file="$5" root
  root=$(caddy_site_root "$domain")
  ensure_site_content "$domain"
  cp -f "$file" "$file.onevps.bak" 2>/dev/null || true
  {
    printf '\n# OneVPS-trojan:%s BEGIN\n' "$id"
    printf '%s {\n' "$domain"
    printf '\tencode zstd gzip\n'
    printf '\troot * %s\n' "$root"
    printf '\thandle %s {\n' "$path"
    printf '\t\treverse_proxy 127.0.0.1:%s\n' "$port"
    printf '\t}\n'
    printf '\thandle {\n'
    printf '\t\terror 403\n'
    printf '\t}\n'
    printf '\thandle_errors {\n'
    printf '\t\trewrite * /index.html\n'
    printf '\t\tfile_server\n'
    printf '\t}\n'
    printf '}\n'
    printf '# OneVPS-trojan:%s END\n' "$id"
  } >> "$file" || return 1
  if ! caddy_reload "$file"; then
    err "reverting Caddyfile change"
    caddy_remove_route "$id" "$file"
    caddy_reload "$file" || true
    return 1
  fi
  return 0
}

# Remove the marked block for a node id (does not reload; caller reloads).
caddy_remove_route() {
  local id="$1" file="$2"
  [[ -f "$file" ]] || return 0
  cp -f "$file" "$file.onevps.bak" 2>/dev/null || true
  sed -i "/# OneVPS-trojan:$id BEGIN/,/# OneVPS-trojan:$id END/d" "$file"
}

# ----------------------------------------------------------------------------
# [3] Node storage + config generation
# ----------------------------------------------------------------------------
ensure_nodes_file() {
  [[ -f "$SINGBOX_NODES" ]] && validate_node_metadata "$SINGBOX_NODES" || {
    err 'valid schema_version 1 installation required; install sing-box first'; return 1;
  }
}

prepare_jq_nodes() {
  local source="$1" output="$2"
  shift 2
  jq "$@" "$source" > "$output"
}

jq_update_nodes() {
  apply_candidate_transaction prepare_jq_nodes "$@"
}

node_count() {
  [[ -f "$SINGBOX_NODES" ]] || { echo 0; return; }
  jq '.nodes|length' "$SINGBOX_NODES"
}

node_by_id() {
  jq -c --arg id "$1" '.nodes[]|select(.id==$id)' "$SINGBOX_NODES"
}

validate_singbox_config() {
  local conf="$1" err_file="$2"
  [[ -x "$SINGBOX_BIN" ]] || return 1
  "$SINGBOX_BIN" check -c "$conf" >"$err_file" 2>&1
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
# disabled nodes. No arbitrary sing-box JSON accepted.
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
          keys_only(["encryption","type","security","flow","sni","fp","pbk","sid","host","path","serviceName","mode","alpn"]) and
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
             (has("spx") | not)
           elif .security == "tls" then (has("pbk") or has("sid") or has("spx") | not)
           else false end) and
          (if .type == "ws" then
             (has("serviceName") or has("mode") | not) and
             (if has("path") then (.path | startswith("/")) else true end) and
             (if has("host") then (.host | nonempty and test("^[A-Za-z0-9.:-]+$")) else true end)
           elif .type == "grpc" then
             (has("host") or has("path") | not) and
             (if has("mode") then (.mode == "gun") else true end) and
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
    {tag:$tag,type:.protocol,server:.server,server_port:.port} +
    if .protocol == "shadowsocks" then {method:.method,password:.password}
    elif .protocol == "socks" then {version:"5"} +
      (if has("username") then {username:.username,password:.password} else {} end)
    elif .protocol == "vless" then
      .params as $p | {uuid:.uuid,flow:$p.flow,
        tls:({enabled:true,insecure:false} +
          (if $p|has("sni") then {server_name:$p.sni} else {} end) +
          (if $p|has("fp") then {utls:{enabled:true,fingerprint:$p.fp}} else {} end) +
          (if $p|has("alpn") then {alpn:($p.alpn|split(","))} else {} end) +
          (if $p.security == "reality" then {reality:{enabled:true,public_key:$p.pbk,short_id:$p.sid}} else {} end))} +
        (if $p.type == "ws" then {transport:({type:"ws",path:($p.path // "/")} +
          if $p|has("host") then {headers:{Host:$p.host}} else {} end)}
         elif $p.type == "grpc" then {transport:{type:"grpc",service_name:($p.serviceName // "")}}
         else {} end)
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
  rules=$(jq -c '[.[] | {action:"route",inbound:[.inbound],
    outbound:(if .outbound.mode == "direct" then "direct" else .tag end)} +
    (if has("user") then {auth_user:[.user]} else {} end)]' <<<"$assignments") || return 1
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
      hysteria2)     ib=$(build_hysteria2_inbound "$n") || return 1 ;;
      *) continue ;;
    esac
    inbounds=$(printf '%s\n%s\n' "$inbounds" "$ib" | jq -sc '.[0] + [.[1]]') || return 1
  done <<<"$rows"
  routes=$(build_outbound_routes "$source") || return 1
  printf '%s\n%s\n' "$inbounds" "$routes" | jq -s --slurpfile nodes "$source" --arg acme_dir "$SINGBOX_ACME_DIR" '
    .[0] as $inbounds | .[1] as $routes |
    def private_ip_rule: {
      action: "reject",
      ip_cidr: [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10",
        "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16",
        "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
        "::1/128", "fc00::/7", "fe80::/10"
      ]
    };
    def bittorrent_rule: {protocol: ["bittorrent"], action: "reject"};
    {
      log: {level: "warn"},
      dns: {servers:[{type:"local",tag:"local"}],final:"local"},
      inbounds: $inbounds,
      outbounds: ([{tag: "direct", type: "direct"}] + $routes.outbounds),
      route: {
        default_domain_resolver: "local",
        final: "direct",
        rules: ([{action:"sniff"}, private_ip_rule, bittorrent_rule] + $routes.rules)
      }
    } +
    ([$nodes[0].nodes[] | select(.enabled and .type == "hysteria2")] | unique_by(.domain) |
      if length == 0 then {} else {certificate_providers: map({
        type:"acme", tag:("acme-" + .domain), domain:[.domain], email:.acme_email,
        provider:"letsencrypt", data_directory:$acme_dir,
        disable_http_challenge:false, disable_tls_alpn_challenge:true
      })} end)' > "$output"
}

rebuild_config() {
  apply_candidate_transaction prepare_jq_nodes '.'
}

# Stable identity labels are unchanged; no legacy metadata is accepted.
node_clients() {
  jq -c '
    . as $n |
    [{uuid:.uuid,password:.password,email:(.tag + "@onevps")}] +
      [(.users // [])[] | . + {email:(([ $n.id, .id ] | tojson | @base64) + "@onevps-user")}] |
    map(if $n.type == "vless-reality" then {uuid:.uuid,flow:"xtls-rprx-vision",name:.email}
        else {password,name:.email} end)' <<<"$1"
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
    .schema_version == 1 and (has("users") | not) and (has("clients") | not) and
    (.nodes | type == "array") and
    all(.nodes[]; (has("clients") | not) and (has("spider_x") | not) and
      (.type == "vless-reality" or .type == "trojan-ws" or .type == "hysteria2") and
      (if .type == "trojan-ws" then (.ws_path | type == "string" and test("^/[A-Za-z0-9/_-]*$"))
       elif .type == "hysteria2" then
         (.domain | type == "string" and length <= 253 and
           test("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$")) and
         (.acme_email | type == "string" and test("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")) and
         (if has("obfs_password") then (.obfs_password | nonempty) else true end)
       else true end)) and
    (if any(.nodes[]; .enabled and .type == "hysteria2") then
      all(.nodes[]; (.enabled and .type != "hysteria2" and .port == 80) | not)
     else true end) and
    ([.nodes[] | select(.type == "hysteria2")] | group_by(.domain) |
      all(.[]; ([.[].acme_email] | unique | length) == 1)) and
    ([.nodes[] | [(if .type == "hysteria2" then "udp" else "tcp" end), .port]] |
      length == (unique | length)) and
    ([.nodes[].id] | length == (unique | length)) and
    ([.nodes[].tag] | length == (unique | length)) and
    all(.nodes[];
      . as $n |
      (.id | type == "string" and test("^[A-Za-z0-9_-]+$")) and
      (.tag | nonempty) and
      (.enabled | type == "boolean") and
      (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
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

hysteria2_preflight() {
  local source="$1" version listeners pid line
  jq -e 'any(.nodes[]; .enabled and .type == "hysteria2")' "$source" >/dev/null || return 0
  version=$("$SINGBOX_BIN" version) || return 1
  [[ "$(installed_version)" == "${SINGBOX_VERSION#v}" && "$version" == *with_acme* && "$version" == *with_quic* ]] || {
    err "Hysteria 2 requires sing-box $SINGBOX_VERSION with_acme and with_quic"; return 1;
  }
  grep -qxF "ReadWritePaths=-$SINGBOX_ACME_DIR" "$SINGBOX_SERVICE" || {
    err 'Update the OneVPS core from menu [1] to enable persistent ACME storage'; return 1;
  }
  command -v ss >/dev/null 2>&1 || { err 'ss is required to check HTTP-01 and UDP listeners'; return 1; }
  listeners=$(ss -H -ltnp 'sport = :80') || return 1
  if [[ -n "$listeners" ]]; then
    pid=$(systemctl show -p MainPID --value onevps-sing-box) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { err 'TCP/80 is occupied'; return 1; }
    while IFS= read -r line; do
      [[ "$line" == *"pid=$pid,"* ]] || { err 'TCP/80 belongs to another service; HTTP-01 cannot proceed'; return 1; }
    done <<<"$listeners"
  fi
  if [[ -e "$SINGBOX_ACME_DIR" || -L "$SINGBOX_ACME_DIR" ]]; then
    [[ -d "$SINGBOX_ACME_DIR" && ! -L "$SINGBOX_ACME_DIR" && -f "$SINGBOX_ACME_DIR/.onevps-managed" && ! -L "$SINGBOX_ACME_DIR/.onevps-managed" ]] &&
      grep -qx 'OneVPS ACME storage' "$SINGBOX_ACME_DIR/.onevps-managed" || {
        err "refusing unmanaged ACME storage: $SINGBOX_ACME_DIR"; return 1;
      }
  else
    mkdir -m 700 "$SINGBOX_ACME_DIR" || return 1
    printf 'OneVPS ACME storage\n' > "$SINGBOX_ACME_DIR/.onevps-managed" || return 1
  fi
  chown nobody:"$(id -gn nobody)" "$SINGBOX_ACME_DIR" && chmod 700 "$SINGBOX_ACME_DIR" || return 1
}

check_hysteria2_dns() {
  local domain="$1" resolved address expected
  command -v getent >/dev/null 2>&1 || { err 'getent is required for DNS checks'; return 1; }
  expected=$(pub_ip) || return 1
  [[ -n "$expected" ]] || { err 'could not determine public IPv4 address'; return 1; }
  resolved=$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u) || return 1
  [[ -n "$resolved" ]] || { err 'domain has no IPv4 resolution'; return 1; }
  while IFS= read -r address; do
    [[ "$address" == "$expected" ]] || { err 'domain must resolve directly to this VPS public IPv4, without a CDN'; return 1; }
  done <<<"$resolved"
  warn 'Verify any AAAA record also reaches this VPS; incorrect IPv6 can break HTTP-01.'
}

# A disposable loopback client verifies QUIC, authentication and trusted TLS.
# The HTTPS probe also needs the selected default user's outbound to work.
verify_hysteria2_nodes() (
  local source="$1" work="$2" n port pid='' deadline result=0
  trap 'if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi' EXIT
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    port=$(rand_port) || return 1
    printf '%s\n' "$n" | jq --argjson port "$port" '{
      log:{level:"error"},
      inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:$port}],
      outbounds:[({type:"hysteria2",server:"127.0.0.1",server_port:.port,password:.password,
        tls:{enabled:true,server_name:.domain}} +
        (if .obfs_password then {obfs:{type:"salamander",password:.obfs_password}} else {} end))]
    }' > "$work/probe.json" || return 1
    "$SINGBOX_BIN" run -c "$work/probe.json" > "$work/probe.log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + 90))
    result=1
    while (( SECONDS < deadline )); do
      kill -0 "$pid" 2>/dev/null || break
      if curl --silent --fail --noproxy '' --proxy "socks5h://127.0.0.1:$port" \
          --connect-timeout 3 --max-time 5 https://www.example.com/ -o /dev/null; then
        result=0; break
      fi
      sleep 2
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=''
    (( result == 0 )) || { err 'Hysteria 2 certificate/QUIC/egress probe timed out; candidate will roll back'; return 1; }
  done < <(jq -c '.nodes[] | select(.enabled and .type == "hysteria2")' "$source")
)

# A subshell scopes traps. Backups and candidates stay on the target filesystem.
# Rollback covers detectable failures, not power-loss atomicity across two files.
apply_candidate_transaction() (
  local prepare="$1"
  shift
  umask 077
  local tx active=false touched=false committed=false preserve=false
  local path
  for path in "$SINGBOX_DIR" "$SINGBOX_BIN" "$SINGBOX_NODES" "$SINGBOX_CONF" "$SINGBOX_SERVICE"; do
    [[ ! -L "$path" ]] || { err "refusing symlink: $path"; return 1; }
  done
  [[ -x "$SINGBOX_BIN" && -f "$SINGBOX_NODES" && -f "$SINGBOX_CONF" ]] || {
    err "installed sing-box and existing configuration required"; return 1;
  }
  tx=$(mktemp -d "$SINGBOX_DIR/.transaction.XXXXXXXX") || return 1
  transaction_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      cp -p "$tx/nodes.backup" "$SINGBOX_NODES" || failed=true
      cp -p "$tx/config.backup" "$SINGBOX_CONF" || failed=true
      if $active; then
        systemctl restart onevps-sing-box && systemctl is-active --quiet onevps-sing-box || failed=true
      else
        systemctl stop onevps-sing-box || failed=true
        if systemctl is-active --quiet onevps-sing-box; then failed=true; fi
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
  "$prepare" "$SINGBOX_NODES" "$tx/nodes.json" "$@" || return 1
  render_config "$tx/nodes.json" "$tx/config.json" || return 1
  hysteria2_preflight "$tx/nodes.json" || return 1
  if ! validate_singbox_config "$tx/config.json" "$tx/check.log"; then
    err "candidate sing-box validation failed"; return 1
  fi
  cp -p "$SINGBOX_NODES" "$tx/nodes.backup" || return 1
  cp -p "$SINGBOX_CONF" "$tx/config.backup" || return 1
  # Copy attributes from each original before filling replacement contents.
  cp -p "$SINGBOX_NODES" "$tx/nodes.next" && cp -p "$SINGBOX_CONF" "$tx/config.next" || return 1
  cat "$tx/nodes.json" > "$tx/nodes.next" && cat "$tx/config.json" > "$tx/config.next" || return 1
  if systemctl is-active --quiet onevps-sing-box; then active=true; fi
  touched=true
  if jq -e 'any(.nodes[]; .enabled and .type == "hysteria2")' "$tx/nodes.json" >/dev/null; then
    open_port 80 tcp
    while IFS= read -r path; do open_port "$path" udp; done < <(
      jq -r '.nodes[] | select(.enabled and .type == "hysteria2") | .port' "$tx/nodes.json")
    warn 'ACME/UDP firewall allowances are retained on failure; review shared rules before removing them.'
  fi
  mv -f "$tx/nodes.next" "$SINGBOX_NODES" || return 1
  mv -f "$tx/config.next" "$SINGBOX_CONF" || return 1
  systemctl restart onevps-sing-box && systemctl is-active --quiet onevps-sing-box || return 1
  verify_hysteria2_nodes "$tx/nodes.json" "$tx" || return 1
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
    printf '\nActions:\n1) Add user\n2) Delete user\n3) User share link\n0) Back\n'
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

build_hysteria2_inbound() {
  local n="$1" clients
  clients=$(node_clients "$n") || return 1
  printf '%s\n%s\n' "$n" "$clients" | jq -s '
    .[0] as $n | {
      type:"hysteria2", tag:$n.tag, listen:"0.0.0.0", listen_port:$n.port,
      users:.[1], tls:{enabled:true, server_name:$n.domain,
        certificate_provider:("acme-" + $n.domain)}
    } + (if $n.obfs_password then {obfs:{type:"salamander",password:$n.obfs_password}} else {} end)'
}

build_reality_inbound() {
  local n="$1" clients
  clients=$(node_clients "$n") || return 1
  printf '%s\n%s\n' "$n" "$clients" | jq -s '
    .[0] as $n | .[1] as $clients |
    {
      type: "vless", tag: $n.tag, listen: "0.0.0.0", listen_port: $n.port,
      users: $clients,
      tls: {
        enabled: true, server_name: $n.reality_sni,
        reality: {
          enabled: true,
          handshake: {server:$n.reality_target,server_port:($n.reality_target_port // 443)},
          private_key: $n.reality_private_key, short_id: [$n.reality_short_id]
        }
      }
    }'
}

# Trojan inbound: listens on loopback only; Caddy terminates TLS on :443 and
# reverse-proxies the WS path here. No TLS at the sing-box layer.
build_trojan_inbound() {
  local n="$1" clients
  clients=$(node_clients "$n") || return 1
  printf '%s\n%s\n' "$n" "$clients" | jq -s '
    .[0] as $n | .[1] as $clients |
    {
      type: "trojan", tag: $n.tag, listen: "127.0.0.1", listen_port: $n.port,
      users: $clients, transport: {type:"ws",path:$n.ws_path}
    }'
}

# ----------------------------------------------------------------------------
# Reality target helpers
# ----------------------------------------------------------------------------
probe_reality_target() {
  local domain="$1"
  info "probing TLS 1.3, certificate and H2 with OpenSSL: $domain"
  if probe_reality_once "$domain"; then
    ok 'TLS target probe OK (not an end-to-end Reality test)'
  else
    warn 'target probe failed or timed out; verify TLS 1.3/H2 and SNI before use'
  fi
}

probe_reality_once() {
  local domain="$1" result
  command -v timeout >/dev/null 2>&1 || return 1
  result=$(timeout 10 openssl s_client -connect "$domain:443" -servername "$domain" \
    -tls1_3 -alpn h2 -verify_return_error -verify_hostname "$domain" </dev/null 2>&1) || return 1
  grep -q 'ALPN protocol: h2' <<<"$result"
}

auto_pick_reality_target() {
  [[ -x "$SINGBOX_BIN" ]] || { echo "${REALITY_DESTS[0]}"; return; }
  if ! command -v timeout >/dev/null 2>&1; then
    warn "timeout command not found; using ${REALITY_DESTS[0]}" >&2
    echo "${REALITY_DESTS[0]}"
    return
  fi

  local d i start end elapsed ok total avg
  local best="" best_ok=-1 best_avg=999999999

  info "auto-testing Reality targets (${REALITY_PROBE_ROUNDS} rounds each)..." >&2
  for d in "${REALITY_DESTS[@]}"; do
    ok=0
    total=0
    for ((i=1; i<=REALITY_PROBE_ROUNDS; i++)); do
      start=$(date +%s%3N)
      if probe_reality_once "$d"; then
        end=$(date +%s%3N)
        elapsed=$((end - start))
        ok=$((ok + 1))
        total=$((total + elapsed))
      fi
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
  require_singbox
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
      enabled: true
    }')

  if jq_update_nodes --argjson node "$node" '.nodes += [$node]'; then
    open_port "$port" tcp
    ok "Reality node added"
    node_link "$(node_by_id "$id")"
  else
    err "node not added; transaction rolled back"
  fi
  pause
}

# ----------------------------------------------------------------------------
# [4b] Add Trojan + WS node (behind Caddy)
# ----------------------------------------------------------------------------
add_hysteria2_node() {
  require_singbox
  ensure_nodes_file
  local name domain email password port id node obfs=''
  info "Add Hysteria 2 with native ACME HTTP-01 (Let's Encrypt)"
  warn 'Requires a domain pointing directly to this VPS and public TCP/80 for issuance and renewal.'
  warn 'The domain will be sent to the CA and published in public certificate transparency logs.'
  confirm 'Proceed with public certificate issuance?' n || return
  name=$(ask 'Node name' "hy2-$(openssl rand -hex 2)")
  domain=$(normalize_domain "$(ask 'Certificate domain')")
  email=$(ask 'ACME contact email')
  password=$(rand_password) || return 1
  while :; do
    port=$(ask 'Hysteria 2 UDP port' 443)
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || { warn 'invalid port'; continue; }
    port=$((10#$port))
    (( port >= 1 && port <= 65535 )) || { warn 'port out of range'; continue; }
    if port_taken_by_node "$port" udp || port_in_use "$port" udp; then
      warn 'UDP port is occupied; choose another port'; continue
    fi
    break
  done
  if confirm 'Enable salamander obfuscation?' n; then obfs=$(rand_password) || return 1; fi
  id=$(openssl rand -hex 4) || return 1
  node=$(printf '%s\n' "$password" | jq -Rc --arg id "$id" --arg name "$name" --arg domain "$domain" \
    --arg email "$email" --argjson port "$port" --arg obfs "$obfs" '
    {id:$id,type:"hysteria2",name:$name,tag:("hy2-" + $id),domain:$domain,
      acme_email:$email,port:$port,password:.,enabled:true} +
    (if $obfs == "" then {} else {obfs_password:$obfs} end)') || return 1
  local candidate
  candidate=$(mktemp_json) || return 1
  if ! jq --argjson node "$node" '.nodes += [$node]' "$SINGBOX_NODES" > "$candidate" ||
      ! validate_node_metadata "$candidate"; then
    rm -f "$candidate"; err 'invalid domain, email or conflicting node settings'; return 1
  fi
  rm -f "$candidate"
  check_hysteria2_dns "$domain" || return 1
  warn "Allow TCP/80 and UDP/$port in your cloud security group; TCP/80 remains necessary for renewal."
  confirm 'Network prerequisites ready?' n || return
  if jq_update_nodes --argjson node "$node" '.nodes += [$node]'; then
    ok 'Hysteria 2 node added and verified through a local client'
    node_link "$(node_by_id "$id")"
  else
    err 'Hysteria 2 activation failed; inspect DNS, TCP/80 reachability and journalctl -u onevps-sing-box'
  fi
  pause
}

add_trojan_node() {
  require_singbox
  ensure_nodes_file
  echo; info "Add node - Trojan + WebSocket (behind Caddy)"

  if ! ensure_caddy; then
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
  if grep -qiF "$domain" "$cfile" 2>/dev/null; then
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

  if ! caddy_add_route "$id" "$domain" "$path" "$port" "$cfile"; then
    err "Caddy update failed, rolled back"
    pause; return
  fi

  if jq_update_nodes --argjson node "$node" '.nodes += [$node]'; then
    ok "Trojan node added"
    info "ensure DNS A/AAAA for $domain points here so Caddy can issue its cert"
    node_link "$(node_by_id "$id")"
  else
    err "sing-box config generation failed, rolled back"
    caddy_remove_route "$id" "$cfile"; caddy_reload "$cfile" || true
  fi
  pause
}

# ----------------------------------------------------------------------------
# Share links
# ----------------------------------------------------------------------------
node_link() {
  local n="$1" type name port link addr uuid sni pubk sid fp pw domain path
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
    link="vless://${uuid}@${addr}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pubk}&sid=${sid}&type=tcp#$(urlenc "$name")"
    echo
    printf '%s-- %s (VLESS Reality + Vision + uTLS) --%s\n' "$c_grn" "$name" "$c_rst"
    echo "$link"
    printf '%sTarget: %s:%s  uTLS: %s  shortId: %s%s\n' "$c_ylw" \
      "$(jq -r '.reality_target' <<<"$n")" "$(jq -r '.reality_target_port // 443' <<<"$n")" \
      "$(jq -r '.fingerprint // "chrome"' <<<"$n")" "$(jq -r '.reality_short_id' <<<"$n")" "$c_rst"

  elif [[ "$type" == "hysteria2" ]]; then
    pw=$(jq -r '.password' <<<"$n")
    domain=$(jq -r '.domain' <<<"$n")
    link="hysteria2://$(urlenc "$pw")@${domain}:${port}/?sni=$(urlenc "$domain")"
    if jq -e 'has("obfs_password")' <<<"$n" >/dev/null; then
      link+="&obfs=salamander&obfs-password=$(urlenc "$(jq -r '.obfs_password' <<<"$n")")"
    fi
    printf '\n%s-- %s (Hysteria 2 / ACME) --%s\n' "$c_grn" "$name" "$c_rst"
    printf '%s#%s\n' "$link" "$(urlenc "$name")"
    info "UDP/$port; native HTTP-01 renewal requires TCP/80 while the node is enabled"
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
  require_singbox
  ensure_nodes_file
  [[ "$(node_count)" -gt 0 ]] || { warn "no nodes"; pause; return; }
  local n
  while IFS= read -r n; do node_link "$n"; done < <(jq -c '.nodes[]' "$SINGBOX_NODES")
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
      hysteria2) kind="hy2/udp"; dest=$(jq -r '.domain' <<<"$n") ;;
      *)         kind="reality"; dest=$(jq -r '.reality_target' <<<"$n") ;;
    esac
    printf '  %d) %-18s %-8s port:%-6s %-26s %s\n' \
      "$i" "$(jq -r '.name' <<<"$n")" "$kind" "$(jq -r '.port' <<<"$n")" \
      "$dest" \
      "$([[ "$en" == true ]] && echo "$st" || echo "${c_ylw}$st${c_rst}")"
  done < <(jq -c '.nodes[]' "$SINGBOX_NODES")
}

pick_node() {
  local cnt sel
  cnt=$(node_count)
  [[ "$cnt" -gt 0 ]] || { echo ""; return; }
  list_nodes >&2
  sel=$(ask $'Select node number (Enter to go back)' "")
  [[ "$sel" =~ ^[0-9]+$ ]] || { echo ""; return; }
  (( sel>=1 && sel<=cnt )) || { echo ""; return; }
  jq -r --argjson i "$((sel-1))" '.nodes[$i].id' "$SINGBOX_NODES"
}

manage_nodes() {
  require_singbox
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
      printf '\n1) Change UDP port\n2) Reset default password\n3) Enable/disable\n4) Delete node\n5) Manage node users\n6) Set node outbound\n0) Back\n'
      case "$(ask 'Select')" in
        1) edit_port "$id" ;;
        2) reset_trojan_password "$id" ;;
        3) toggle_enabled "$id" ;;
        4) del_node "$id"; return ;;
        5) manage_node_users "$id" || true ;;
        6) manage_outbound "$id" || true ;;
        0|"") return ;;
        *) continue ;;
      esac
    elif [[ "$type" == "trojan-ws" ]]; then
      cat <<EOF

  Node actions:
   1) Reset default password
   2) Change domain
   3) Change WS path
   4) Rebuild Caddy route
   5) Enable/disable
   6) Delete node
   7) Manage node users
   8) Set node outbound
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

  Node actions:
   1) Change port
   2) Reset default UUID
   3) Rotate Reality keypair / shortId
   4) Change Reality handshake target
   5) Enable/disable
   6) Delete node
   7) Manage node users
   8) Set node outbound
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
  local id="$1" n newp oldp proto
  n=$(node_by_id "$id")
  proto=$(node_network "$(jq -r '.type' <<<"$n")")
  while :; do
    newp=$(ask "New port" "$(jq -r '.port' <<<"$n")")
    [[ "$newp" =~ ^[0-9]+$ ]] || { warn "invalid port"; continue; }
    newp=$((10#$newp))
    (( newp >= 1 && newp <= 65535 )) || { warn "port out of range"; continue; }
    if port_taken_by_node "$newp" "$proto" "$id"; then
      warn "$proto port used by another node"; continue
    fi
    if [[ "$newp" != "$(jq -r '.port' <<<"$n")" ]] && port_in_use "$newp" "$proto"; then
      warn "$proto port is already in use"; continue
    fi
    break
  done
  oldp=$(jq -r '.port' <<<"$n")
  jq_update_nodes --arg id "$id" --argjson p "$newp" '(.nodes[]|select(.id==$id)).port = $p' || { err 'apply failed'; return 1; }
  if [[ "$newp" != "$oldp" ]]; then
    if [[ "$proto" == tcp ]]; then close_port "$oldp" tcp
    else warn "old UDP/$oldp firewall rule retained; remove it manually if no longer needed"; fi
  fi
  open_port "$newp" "$proto"
  ok "port changed to $newp"
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
      (.reality_private_key=$pk | .reality_public_key=$pubk | .reality_short_id=$sid)' || { err 'apply failed'; return 1; }
  ok "Reality keypair rotated"
  pause
}

edit_reality_target() {
  local id="$1" target
  target=$(pick_reality_target)
  jq_update_nodes --arg id "$id" --arg target "$target" '
    (.nodes[]|select(.id==$id)) |= (.reality_sni=$target | .reality_target=$target | .reality_target_port=443)' || { err 'apply failed'; return 1; }
  ok "target changed to $target"
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

  update_trojan_route "$id" "$cf" "$newdom" "$path" "$port" domain "$newdom" || return 1
  ok "domain changed to $newdom"
  info "ensure DNS for $newdom points here so Caddy can issue its cert"
  pause
}

# Caddy edit is rolled back byte-for-byte when metadata/core activation fails.
update_trojan_route() (
  local id="$1" cf="$2" domain="$3" path="$4" port="$5" field="$6" value="$7" backup committed=false
  [[ "$path" =~ ^/[A-Za-z0-9/_-]*$ ]] || { err 'WS path must contain only letters, digits, /, _ and -'; return 1; }
  backup=$(mktemp) || return 1
  cp -p "$cf" "$backup" || { rm -f "$backup"; return 1; }
  route_cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if ! $committed; then
      if ! cp -p "$backup" "$cf" || ! caddy_reload "$cf"; then
        err "Caddy rollback failed; backup retained at $backup"; exit 1
      fi
    fi
    rm -f "$backup"
    exit "$status"
  }
  trap route_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  caddy_remove_route "$id" "$cf" || return 1
  if grep -qiF "$domain" "$cf"; then err 'domain already in Caddyfile'; return 1; fi
  caddy_add_route "$id" "$domain" "$path" "$port" "$cf" || return 1
  if [[ -n "$field" ]]; then
    jq_update_nodes --arg id "$id" --arg field "$field" --arg value "$value" \
      '(.nodes[]|select(.id==$id))[$field] = $value' || return 1
  fi
  committed=true
)

edit_trojan_path() {
  local id="$1" n cf port domain newpath
  n=$(node_by_id "$id")
  cf=$(jq -r '.caddy_file' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  domain=$(jq -r '.domain' <<<"$n")
  newpath=$(ask "New WS path" "$(jq -r '.ws_path' <<<"$n")")
  [[ "$newpath" == /* ]] || newpath="/$newpath"
  update_trojan_route "$id" "$cf" "$domain" "$newpath" "$port" ws_path "$newpath" || return 1
  ok "WS path changed to $newpath"
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
  if update_trojan_route "$id" "$cf" "$domain" "$path" "$port" caddy_file "$cf"; then
    ok "Caddy route rebuilt for $domain"
  else
    err "rebuild failed"
  fi
  pause
}

toggle_enabled() {
  local id="$1"
  jq_update_nodes --arg id "$id" '(.nodes[]|select(.id==$id)).enabled |= (.|not)' &&
    ok "enabled state toggled" || { err 'apply failed'; return 1; }
  pause
}

del_node() (
  local id="$1" n port type cf='' backup='' committed=false
  confirm "Delete this node?" n || return
  n=$(node_by_id "$id") || return 1
  port=$(jq -r '.port' <<<"$n")
  type=$(jq -r '.type' <<<"$n")
  delete_cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$backup" ]] && ! $committed; then
      if ! cp -p "$backup" "$cf" || ! caddy_reload "$cf"; then
        err "Caddy rollback failed; backup retained at $backup"; exit 1
      fi
    fi
    [[ -z "$backup" ]] || rm -f "$backup"
    exit "$status"
  }
  trap delete_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if [[ "$type" == "trojan-ws" ]]; then
    cf=$(jq -r '.caddy_file' <<<"$n")
    if [[ -f "$cf" ]]; then
      backup=$(mktemp) || return 1
      cp -p "$cf" "$backup" || { rm -f "$backup"; backup=''; return 1; }
      caddy_remove_route "$id" "$cf" && caddy_reload "$cf" || return 1
    fi
  fi
  jq_update_nodes --arg id "$id" 'del(.nodes[]|select(.id==$id))' || { err 'delete failed'; return 1; }
  committed=true
  if [[ "$type" == hysteria2 ]]; then
    warn "ACME data and TCP/80, UDP/$port firewall rules retained; review shared use before cleanup"
  elif [[ "$type" != trojan-ws ]]; then close_port "$port" tcp; fi
  ok 'deleted'
  pause
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
  require_singbox
  rebuild_config || { err 'restart failed; transaction rolled back'; return 1; }
  ok 'restarted'
  systemctl --no-pager -l status onevps-sing-box 2>/dev/null | head -n 8 || true
  pause
}

uninstall() {
  singbox_owned || { err 'refusing to remove unmanaged sing-box resources'; return 1; }
  validate_node_metadata "$SINGBOX_NODES" || { err 'invalid metadata; inspect before uninstalling'; return 1; }
  warn "Remove only $SINGBOX_BIN, $SINGBOX_SERVICE, $SINGBOX_CONF and $SINGBOX_NODES"
  warn 'Realm, BBR/TCP tuning, Caddy and custom site content are kept'
  warn "ACME accounts, certificates and private keys in $SINGBOX_ACME_DIR are kept; renewal stops with the service"
  confirm 'Confirm uninstall?' n || return
  local n id cf backup
  # Remove only our marked routes; failed Caddy reload aborts core removal.
  while IFS= read -r n; do
    id=$(jq -r '.id' <<<"$n"); cf=$(jq -r '.caddy_file' <<<"$n")
    [[ -f "$cf" ]] || continue
    backup=$(mktemp) || return 1
    cp -p "$cf" "$backup" || { rm -f "$backup"; return 1; }
    if ! caddy_remove_route "$id" "$cf" || ! caddy_reload "$cf"; then
      cp -p "$backup" "$cf" && caddy_reload "$cf" || err "Caddy recovery failed; backup: $backup"
      err 'Caddy cleanup failed; core retained'; return 1
    fi
    rm -f "$backup"
  done < <(jq -c '.nodes[] | select(.type == "trojan-ws")' "$SINGBOX_NODES")
  systemctl stop onevps-sing-box && systemctl disable onevps-sing-box || return 1
  rm -f "$SINGBOX_BIN" "$SINGBOX_SERVICE" "$SINGBOX_CONF" "$SINGBOX_NODES" "$SINGBOX_DIR/.onevps-managed" || return 1
  # Never recursively remove a directory that may contain user files.
  rmdir "$SINGBOX_DIR" 2>/dev/null || warn "custom files retained in $SINGBOX_DIR"
  systemctl daemon-reload || return 1
  ok 'uninstalled'
  pause
}

# ----------------------------------------------------------------------------
# Realm relay (independent of sing-box)
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
  if ! curl -fsSL --connect-timeout 15 --max-time 60 \
    "https://api.github.com/repos/zhboner/realm/releases/tags/$REALM_VERSION" > "$tmp/release.json"; then
    rm -rf "$tmp"; return 1
  fi
  url=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' "$tmp/release.json")
  digest=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest' "$tmp/release.json")
  if [[ "$url" != "https://github.com/zhboner/realm/releases/download/$REALM_VERSION/$asset" ||
        ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    err "missing official asset or SHA-256 digest"; rm -rf "$tmp"; return 1
  fi
  if ! curl -fsSL --connect-timeout 15 --max-time 180 "$url" -o "$tmp/archive.tar.gz"; then
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
  systemctl restart onevps-realm || return 1
  sleep 2
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
    printf '\nRealm relay\n1) Install and add relay\n2) List rules / status\n3) Delete rule\n4) Restart\n5) Uninstall realm\n0) Back\n'
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
status_line() {
  if [[ -x "$SINGBOX_BIN" ]]; then
    local v st bbr_cc
    v=$(installed_version)
    st=$(systemctl is-active onevps-sing-box 2>/dev/null || echo unknown)
    bbr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    printf '%ssing-box %s - service:%s - nodes:%s - TCP:%s%s\n' \
      "$c_blu" "$v" "$st" "$(node_count 2>/dev/null || echo 0)" "$bbr_cc" "$c_rst"
  else
    printf '%ssing-box not installed%s\n' "$c_ylw" "$c_rst"
  fi
}

main_menu() {
  while :; do
    clear
    cat <<'EOF'
 ╔════════════════════════════════════════════════╗
 ║   OneVPS - sing-box Reality / Vision / uTLS     ║
 ╚════════════════════════════════════════════════╝
EOF
    status_line
    cat <<EOF

  1) Install / update sing-box-core
  2) Add node - VLESS + Reality + Vision + uTLS
  3) Add node - Trojan + WS (behind Caddy)
  4) Manage nodes
  5) Show default node share links
  6) Restart service
  7) BBR acceleration
  8) TCP optimization
  9) Uninstall
  10) Realm relay
  11) Add node - Hysteria 2 + native ACME
  0) Exit
EOF
    case "$(ask 'Select')" in
      1) install_singbox; pause ;;
      2) add_reality_node ;;
      3) add_trojan_node ;;
      4) manage_nodes ;;
      5) show_links ;;
      6) restart_service ;;
      7) enable_bbr || { err "BBR configuration failed; some settings may already be applied"; pause; } ;;
      8) optimize_system ;;
      9) uninstall ;;
      10) realm_menu ;;
      11) add_hysteria2_node || { err 'Hysteria 2 node not added'; pause; } ;;
      0|"") exit 0 ;;
      *) ;;
    esac
  done
}

main() {
  check_env
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
