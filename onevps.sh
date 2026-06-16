#!/usr/bin/env bash
#
# OneVPS — sing-box node setup script
# Protocols: VLESS (Reality / WS+CF)  /  SOCKS5
# Features: optional Cloudflare CDN  /  optional SOCKS5 egress
#
set -euo pipefail
umask 077

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
SB_DIR=/etc/sing-box
SB_BIN=/usr/local/bin/sing-box
SB_CONF=$SB_DIR/config.json
SB_NODES=$SB_DIR/nodes.json
SB_CERT_DIR=$SB_DIR/certs
SB_SERVICE=/etc/systemd/system/sing-box.service
GH_REPO=SagerNet/sing-box
TUNE_CONF=/etc/sysctl.d/99-onevps-tune.conf

CF_PORTS=(443 2053 2083 2087 2096 8443)
REALITY_DESTS=("www.microsoft.com" "www.apple.com" "www.samsung.com" "gateway.icloud.com" "www.lovelive-anime.jp")

PKG=""
ARCH=""
PUBIP=""

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
# Random values
# ----------------------------------------------------------------------------
rand_uuid() {
  if [[ -x "$SB_BIN" ]]; then "$SB_BIN" generate uuid; return; fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; return; fi
  python3 -c 'import uuid;print(uuid.uuid4())'
}
is_valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
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
rand_pass() { openssl rand -base64 16 | tr -d '/+=' | cut -c1-16; }
rand_path() { echo "/$(openssl rand -hex 6)"; }
rand_short_id() { openssl rand -hex 8; }
rand_port() {
  local p
  while :; do
    # RANDOM alone caps at 32767; combine two draws to cover the full range
    p=$(( ( (RANDOM << 15) | RANDOM ) % 55535 + 10000 ))
    port_taken_by_node "$p" 2>/dev/null && continue
    port_in_use "$p" && continue
    echo "$p"; return
  done
}

reality_keypair() {
  if [[ -x "$SB_BIN" ]]; then
    "$SB_BIN" generate reality-keypair
  else
    die "sing-box must be installed before generating a Reality keypair"
  fi
}

pub_ip() {
  [[ -n "$PUBIP" ]] && { echo "$PUBIP"; return; }
  PUBIP=$(curl -fsSL4 --max-time 8 https://api.ipify.org 2>/dev/null \
       || curl -fsSL4 --max-time 8 https://ifconfig.me 2>/dev/null || true)
  echo "$PUBIP"
}

# ----------------------------------------------------------------------------
# [1] Environment check
# ----------------------------------------------------------------------------
check_env() {
  [[ $EUID -eq 0 ]] || die "must run as root (sudo bash $0)"
  command -v systemctl >/dev/null 2>&1 || die "systemd not found; this script relies on systemd to manage services"

  case "$(uname -m)" in
    x86_64|amd64)        ARCH=amd64 ;;
    aarch64|arm64)       ARCH=arm64 ;;
    armv7l|armv7|armhf)  ARCH=armv7 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac

  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG=yum
  elif command -v apk     >/dev/null 2>&1; then PKG=apk
  else die "unrecognized package manager (apt/dnf/yum/apk supported)"; fi

  ok "environment OK — arch:$ARCH  pkg:$PKG  systemd:yes"
}

pkg_install() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
    apk) apk add --no-cache "$@" ;;
  esac
}

ensure_deps() {
  local need=() bin
  for bin in curl jq openssl tar; do
    command -v "$bin" >/dev/null 2>&1 || need+=("$bin")
  done
  if ((${#need[@]})); then
    info "installing dependencies: ${need[*]}"
    pkg_install "${need[@]}" || die "failed to install dependencies: ${need[*]}"
  fi
}

# ----------------------------------------------------------------------------
# [2] Install / update sing-box
# ----------------------------------------------------------------------------
latest_version() {
  curl -fsSL "https://api.github.com/repos/$GH_REPO/releases/latest" \
    | jq -r '.tag_name' | sed 's/^v//'
}
installed_version() {
  [[ -x "$SB_BIN" ]] || { echo ""; return; }
  "$SB_BIN" version 2>/dev/null | awk '/version/{print $3; exit}'
}

install_singbox() {
  ensure_deps
  local latest cur
  info "checking latest version..."
  latest=$(latest_version) || die "failed to fetch latest version"
  [[ -n "$latest" && "$latest" != null ]] || die "failed to parse latest version (GitHub API rate limit?)"
  cur=$(installed_version)

  if [[ -n "$cur" ]]; then
    if [[ "$cur" == "$latest" ]]; then
      ok "sing-box $cur is already the latest version"
      confirm "Force reinstall?" n || return 0
    else
      info "current $cur → latest $latest"
      confirm "Update?" y || return 0
    fi
  else
    info "will install sing-box $latest"
  fi

  local url tmp
  url="https://github.com/$GH_REPO/releases/download/v${latest}/sing-box-${latest}-linux-${ARCH}.tar.gz"
  tmp=$(mktemp -d)
  info "downloading $url"
  curl -fsSL "$url" -o "$tmp/sb.tar.gz" || { rm -rf "$tmp"; die "download failed"; }
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "extraction failed"; }
  install -m755 "$tmp/sing-box-${latest}-linux-${ARCH}/sing-box" "$SB_BIN"
  rm -rf "$tmp"

  mkdir -p "$SB_DIR" "$SB_CERT_DIR"
  [[ -f "$SB_NODES" ]] || echo '{"nodes":[]}' > "$SB_NODES"

  write_service
  rebuild_config
  ok "sing-box $(installed_version) installed"
}

write_service() {
  cat > "$SB_SERVICE" <<EOF
[Unit]
Description=sing-box (OneVPS)
After=network.target nss-lookup.target

[Service]
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
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
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tunl 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"
  else
    return 1
  fi
}

port_taken_by_node() {
  jq -e --argjson p "$1" '.nodes[]|select(.port==$p)' "$SB_NODES" >/dev/null 2>&1
}

require_must() { command -v "$SB_BIN" >/dev/null 2>&1 || die "run menu option [1] to install sing-box first"; }

# ----------------------------------------------------------------------------
# Certificates (used by WS+CF)
# ----------------------------------------------------------------------------
gen_self_cert() {
  local cn="$1" crt key
  cn="${cn:-bing.com}"
  crt="$SB_CERT_DIR/${cn}.crt"; key="$SB_CERT_DIR/${cn}.key"
  if [[ ! -f "$crt" || ! -f "$key" ]]; then
    openssl ecparam -genkey -name prime256v1 -out "$key" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$key" -out "$crt" -subj "/CN=$cn" >/dev/null 2>&1
  fi
  echo "$crt $key"
}


# ----------------------------------------------------------------------------
# [3] Node storage + config generation
# ----------------------------------------------------------------------------
tmp_nodes() {
  local expr="$1"
  local t; t=$(mktemp)
  jq "$expr" "$SB_NODES" > "$t" && mv "$t" "$SB_NODES"
}

node_count() { jq '.nodes|length' "$SB_NODES"; }

rebuild_config() {
  [[ -f "$SB_NODES" ]] || echo '{"nodes":[]}' > "$SB_NODES"

  local inbounds outbounds rules
  inbounds=$(jq -c '[]' <<<'[]')
  outbounds='[{"type":"direct","tag":"direct"}]'
  rules='[]'

  local n type tag enabled
  while IFS= read -r n; do
    enabled=$(jq -r '.enabled' <<<"$n")
    [[ "$enabled" == "true" ]] || continue
    type=$(jq -r '.type' <<<"$n")
    tag=$(jq -r '.tag' <<<"$n")

    local ib
    case "$type" in
      vless)  ib=$(build_vless_inbound "$n") ;;
      socks5) ib=$(build_socks5_inbound "$n") ;;
      *) continue ;;
    esac
    inbounds=$(jq -c --argjson x "$ib" '. + [$x]' <<<"$inbounds")

    if jq -e '.socks5' <<<"$n" >/dev/null 2>&1; then
      local sid sob
      sid=$(jq -r '.id' <<<"$n")
      sob=$(jq -c \
        --arg tag "socks-$sid" \
        --arg srv "$(jq -r '.socks5.server' <<<"$n")" \
        --argjson port "$(jq -r '.socks5.port' <<<"$n")" \
        --arg user "$(jq -r '.socks5.username // ""' <<<"$n")" \
        --arg pass "$(jq -r '.socks5.password // ""' <<<"$n")" '
        {type:"socks",tag:$tag,server:$srv,server_port:$port,version:"5"}
        + (if $user!="" then {username:$user,password:$pass} else {} end)' <<<'{}')
      outbounds=$(jq -c --argjson x "$sob" '. + [$x]' <<<"$outbounds")
      rules=$(jq -c --arg ib "$tag" --arg ob "socks-$sid" \
        '. + [{inbound:[$ib],outbound:$ob}]' <<<"$rules")
    fi
  done < <(jq -c '.nodes[]' "$SB_NODES")

  jq -n \
    --argjson inbounds "$inbounds" \
    --argjson outbounds "$outbounds" \
    --argjson rules "$rules" '
    {
      log: {level:"warn",timestamp:true},
      inbounds: $inbounds,
      outbounds: $outbounds,
      route: {rules:$rules, final:"direct"}
    }' > "$SB_CONF"

  chmod 600 "$SB_CONF"

  if [[ -x "$SB_BIN" ]]; then
    local chk_err; chk_err=$(mktemp)
    if ! "$SB_BIN" check -c "$SB_CONF" 2>"$chk_err"; then
      err "generated config failed validation:"; cat "$chk_err" >&2
      rm -f "$chk_err"
      return 1
    fi
    rm -f "$chk_err"
    systemctl restart sing-box 2>/dev/null || true
  fi
}

# --- VLESS inbound ---
build_vless_inbound() {
  local n="$1"
  local transport; transport=$(jq -r '.transport' <<<"$n")

  if [[ "$transport" == "reality" ]]; then
    build_vless_reality_inbound "$n"
  else
    build_vless_ws_inbound "$n"
  fi
}

build_vless_reality_inbound() {
  local n="$1"
  jq -n \
    --arg tag "$(jq -r '.tag' <<<"$n")" \
    --argjson port "$(jq -r '.port' <<<"$n")" \
    --arg uuid "$(jq -r '.uuid' <<<"$n")" \
    --arg sni "$(jq -r '.reality_sni' <<<"$n")" \
    --arg dest "$(jq -r '.reality_dest' <<<"$n")" \
    --argjson dest_port "$(jq -r '.reality_dest_port // 443' <<<"$n")" \
    --arg pk "$(jq -r '.reality_private_key' <<<"$n")" \
    --arg sid "$(jq -r '.reality_short_id' <<<"$n")" '
    {
      type:"vless", tag:$tag, listen:"::", listen_port:$port,
      users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
      tls:{
        enabled:true,
        server_name:$sni,
        reality:{
          enabled:true,
          handshake:{server:$dest, server_port:$dest_port},
          private_key:$pk,
          short_id:[$sid]
        }
      }
    }'
}

build_vless_ws_inbound() {
  local n="$1" tls
  local domain; domain=$(jq -r '.domain // ""' <<<"$n")
  local crt key
  read -r crt key < <(gen_self_cert "${domain:-bing.com}")
  tls=$(jq -n --arg sn "${domain:-bing.com}" --arg crt "$crt" --arg key "$key" '
    {enabled:true, server_name:$sn, certificate_path:$crt, key_path:$key}')

  jq -n \
    --arg tag "$(jq -r '.tag' <<<"$n")" \
    --argjson port "$(jq -r '.port' <<<"$n")" \
    --arg uuid "$(jq -r '.uuid' <<<"$n")" \
    --arg path "$(jq -r '.ws_path' <<<"$n")" \
    --arg host "$(jq -r '.domain // ""' <<<"$n")" \
    --argjson tls "$tls" '
    {
      type:"vless", tag:$tag, listen:"::", listen_port:$port,
      users:[{uuid:$uuid}],
      transport:({type:"ws", path:$path}
        + (if $host!="" then {headers:{Host:$host}} else {} end)),
      tls:$tls
    }'
}


# --- SOCKS5 inbound ---
build_socks5_inbound() {
  local n="$1"
  jq -n \
    --arg tag "$(jq -r '.tag' <<<"$n")" \
    --argjson port "$(jq -r '.port' <<<"$n")" \
    --arg user "$(jq -r '.username' <<<"$n")" \
    --arg pass "$(jq -r '.password' <<<"$n")" '
    {
      type:"socks", tag:$tag, listen:"::", listen_port:$port,
      users:[{username:$user, password:$pass}]
    }'
}

# ----------------------------------------------------------------------------
# SOCKS5 egress prompts
# ----------------------------------------------------------------------------
ask_socks5() {
  confirm "Attach SOCKS5 egress (all traffic of this node exits via the SOCKS5)?" n || { echo ""; return; }
  local srv port user pass
  srv=$(ask "SOCKS5 server address")
  [[ -n "$srv" ]] || { warn "address empty, skipping SOCKS5"; echo ""; return; }
  while :; do
    port=$(ask "SOCKS5 port" "1080")
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && break
    warn "invalid port"
  done
  user=$(ask "Username (leave empty for no auth)" "")
  if [[ -n "$user" ]]; then
    pass=$(ask "Password" "")
  fi
  jq -n --arg s "$srv" --argjson p "$port" --arg u "$user" --arg w "${pass:-}" '
    {server:$s, port:$p}
    + (if $u!="" then {username:$u,password:$w} else {} end)'
}

# ----------------------------------------------------------------------------
# [4] Add VLESS node
# ----------------------------------------------------------------------------
add_vless() {
  require_must
  echo; info "Add VLESS node"

  local name uuid id socks5
  name=$(ask "Node name" "vless-$(openssl rand -hex 2)")
  uuid=$(ask_uuid)
  id=$(openssl rand -hex 4)

  if confirm "Enable Cloudflare CDN?" n; then
    add_vless_ws "$id" "$name" "$uuid"
  else
    add_vless_reality "$id" "$name" "$uuid"
  fi
}

add_vless_reality() {
  local id="$1" name="$2" uuid="$3"
  info "Mode: VLESS + Reality (direct, no domain/cert needed)"

  local port sni dest socks5
  while :; do
    port=$(ask "Listen port (Enter for random)" "$(rand_port)")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "invalid port"; continue; }
    if port_taken_by_node "$port"; then warn "port $port already used by another node"; continue; fi
    if port_in_use "$port"; then
      confirm "Port $port appears to be in use. Use anyway?" n || continue
    fi
    break
  done

  echo; info "Reality handshake target (must be a major site with TLS 1.3 + H2):"
  local i=0
  for d in "${REALITY_DESTS[@]}"; do
    i=$((i+1))
    echo "  $i) $d"
  done
  echo "  0) custom"
  local sel
  sel=$(ask "Select" "1")
  if [[ "$sel" == "0" ]]; then
    dest=$(ask "Target domain")
  elif [[ "$sel" =~ ^[0-9]+$ ]] && ((sel>=1 && sel<=${#REALITY_DESTS[@]})); then
    dest="${REALITY_DESTS[$((sel-1))]}"
  else
    dest="${REALITY_DESTS[0]}"
  fi
  sni="$dest"

  info "generating Reality keypair..."
  local kp pk pubk sid
  kp=$(reality_keypair)
  pk=$(echo "$kp" | awk '/PrivateKey:/{print $2}')
  pubk=$(echo "$kp" | awk '/PublicKey:/{print $2}')
  sid=$(rand_short_id)

  socks5=$(ask_socks5)

  local node
  node=$(jq -n \
    --arg id "$id" --arg name "$name" --arg tag "vless-$id" \
    --argjson port "$port" --arg uuid "$uuid" \
    --arg transport "reality" \
    --arg sni "$sni" --arg dest "$dest" --arg pk "$pk" --arg pubk "$pubk" --arg sid "$sid" '
    {id:$id,type:"vless",name:$name,tag:$tag,port:$port,uuid:$uuid,
     transport:$transport,cf:false,
     reality_sni:$sni,reality_dest:$dest,reality_dest_port:443,
     reality_private_key:$pk,reality_public_key:$pubk,reality_short_id:$sid,
     enabled:true}')
  if [[ -n "$socks5" ]]; then
    node=$(jq -c --argjson s "$socks5" '. + {socks5:$s}' <<<"$node")
  fi

  tmp_nodes ".nodes += [$node]"
  open_port "$port" tcp

  if rebuild_config; then
    ok "VLESS + Reality node added"
    node_link "$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")"
  else
    err "config generation failed, rolled back"
    tmp_nodes "del(.nodes[] | select(.id==\"$id\"))"
    rebuild_config || true
  fi
  pause
}

add_vless_ws() {
  local id="$1" name="$2" uuid="$3"
  info "Mode: VLESS + WebSocket + CF CDN (domain required)"

  local domain port path socks5
  domain=$(ask "Domain (hosted on CF, A record pointing to this VPS, orange cloud on)")
  [[ -n "$domain" ]] || die "domain is empty"

  info "CF origin ports (pick one):"
  local i=1
  for p in "${CF_PORTS[@]}"; do
    local mark=""
    if port_taken_by_node "$p"; then mark=" [node]"
    elif port_in_use "$p"; then mark=" [in use]"
    fi
    printf '    %d) %s%s\n' "$i" "$p" "$mark"
    ((i++))
  done
  while :; do
    local choice
    choice=$(ask "Port number or selection [1-${#CF_PORTS[@]}]" "1")
    if [[ "$choice" =~ ^[1-${#CF_PORTS[@]}]$ ]]; then
      port="${CF_PORTS[$((choice-1))]}"
    elif printf '%s\n' "${CF_PORTS[@]}" | grep -qx "$choice"; then
      port="$choice"
    else
      warn "pick from list: ${CF_PORTS[*]}"; continue
    fi
    if port_taken_by_node "$port"; then warn "port $port already used by another node"; continue; fi
    if port_in_use "$port"; then
      confirm "Port $port appears to be in use. Use anyway?" n || continue
    fi
    break
  done

  path=$(rand_path)
  socks5=$(ask_socks5)

  local node
  node=$(jq -n \
    --arg id "$id" --arg name "$name" --arg tag "vless-$id" \
    --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
    --arg domain "$domain" --arg transport "ws" '
    {id:$id,type:"vless",name:$name,tag:$tag,port:$port,uuid:$uuid,
     transport:$transport,ws_path:$path,domain:$domain,tls:"self",cf:true,
     enabled:true}')
  if [[ -n "$socks5" ]]; then
    node=$(jq -c --argjson s "$socks5" '. + {socks5:$s}' <<<"$node")
  fi

  tmp_nodes ".nodes += [$node]"
  open_port "$port" tcp

  if rebuild_config; then
    ok "VLESS + WS + CF node added"
    warn "Make sure CF dashboard SSL/TLS is set to \"Full\""
    node_link "$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")"
  else
    err "config generation failed, rolled back"
    tmp_nodes "del(.nodes[] | select(.id==\"$id\"))"
    rebuild_config || true
  fi
  pause
}


# ----------------------------------------------------------------------------
# [6] Add SOCKS5 node
# ----------------------------------------------------------------------------
add_socks5() {
  require_must
  echo; info "Add SOCKS5 node"
  local name port user pass socks5

  name=$(ask "Node name" "socks5-$(openssl rand -hex 2)")

  while :; do
    port=$(ask "Listen port (Enter for random)" "$(rand_port)")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "invalid port"; continue; }
    if port_taken_by_node "$port"; then warn "port $port already used by another node"; continue; fi
    if port_in_use "$port"; then
      confirm "Port $port appears to be in use. Use anyway?" n || continue
    fi
    break
  done

  user=$(ask "Auth username" "user-$(openssl rand -hex 2)")
  pass=$(rand_pass)

  socks5=$(ask_socks5)

  local id; id=$(openssl rand -hex 4)
  local node
  node=$(jq -n \
    --arg id "$id" --arg name "$name" --arg tag "socks5-$id" \
    --argjson port "$port" --arg user "$user" --arg pass "$pass" '
    {id:$id,type:"socks5",name:$name,tag:$tag,port:$port,
     username:$user,password:$pass,enabled:true}')
  if [[ -n "$socks5" ]]; then
    node=$(jq -c --argjson s "$socks5" '. + {socks5:$s}' <<<"$node")
  fi

  tmp_nodes ".nodes += [$node]"
  open_port "$port" tcp

  if rebuild_config; then
    ok "SOCKS5 node added"
    node_link "$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")"
  else
    err "config generation failed, rolled back"
    tmp_nodes "del(.nodes[] | select(.id==\"$id\"))"
    rebuild_config || true
  fi
  pause
}

# ----------------------------------------------------------------------------
# Share links
# ----------------------------------------------------------------------------
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

node_link() {
  local n="$1" type addr port name
  type=$(jq -r '.type' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  name=$(jq -r '.name' <<<"$n")
  local transport; transport=$(jq -r '.transport // ""' <<<"$n")

  local link=""
  if [[ "$type" == socks5 ]]; then
    addr="$(pub_ip)"
    local user pass
    user=$(jq -r '.username' <<<"$n")
    pass=$(jq -r '.password' <<<"$n")
    link="socks5://${user}:${pass}@${addr}:${port}#$(urlenc "$name")"
  elif [[ "$type" == vless ]]; then
    local uuid
    uuid=$(jq -r '.uuid' <<<"$n")

    if [[ "$transport" == "reality" ]]; then
      addr="$(pub_ip)"
      local sni pubk sid
      sni=$(jq -r '.reality_sni' <<<"$n")
      pubk=$(jq -r '.reality_public_key' <<<"$n")
      sid=$(jq -r '.reality_short_id' <<<"$n")
      link="vless://${uuid}@${addr}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubk}&sid=${sid}&type=tcp#$(urlenc "$name")"
    else
      local domain path host sni
      domain=$(jq -r '.domain // ""' <<<"$n")
      path=$(jq -r '.ws_path' <<<"$n")
      addr="$domain"; [[ -z "$addr" ]] && addr="$(pub_ip)"
      host="$domain"; sni="$domain"
      [[ -z "$sni" ]] && sni="$addr"
      link="vless://${uuid}@${addr}:${port}?encryption=none&security=tls&sni=${sni}&type=ws&host=${host}&path=$(urlenc "$path")&allowInsecure=1#$(urlenc "$name")"
    fi
  fi

  echo
  local suffix=""
  [[ "$transport" == "reality" ]] && suffix="+reality"
  [[ "$transport" == "ws" ]] && suffix="+ws+cf"
  printf '%s── %s (%s%s) ──%s\n' "$c_grn" "$name" "$type" "$suffix" "$c_rst"
  echo "$link"
  if jq -e '.socks5' <<<"$n" >/dev/null 2>&1; then
    printf '%sSOCKS5 egress: %s:%s%s\n' "$c_ylw" \
      "$(jq -r '.socks5.server' <<<"$n")" "$(jq -r '.socks5.port' <<<"$n")" "$c_rst"
  fi
}

show_links() {
  require_must
  [[ "$(node_count)" -gt 0 ]] || { warn "no nodes"; pause; return; }
  local n
  while IFS= read -r n; do node_link "$n"; done < <(jq -c '.nodes[]' "$SB_NODES")
  pause
}

# ----------------------------------------------------------------------------
# Node management
# ----------------------------------------------------------------------------
list_nodes() {
  local i=0 n
  while IFS= read -r n; do
    i=$((i+1))
    local en st tp
    en=$(jq -r '.enabled' <<<"$n"); st="enabled"; [[ "$en" == true ]] || st="disabled"
    tp=$(jq -r '.transport // ""' <<<"$n")
    local mode=""
    [[ "$tp" == "reality" ]] && mode="reality"
    [[ "$tp" == "ws" ]] && mode="ws+cf"
    printf '  %d) %-16s %-9s %-8s port:%-6s %s\n' \
      "$i" "$(jq -r '.name' <<<"$n")" "$(jq -r '.type' <<<"$n")" \
      "$mode" \
      "$(jq -r '.port' <<<"$n")" \
      "$([[ "$en" == true ]] && echo "$st" || echo "${c_ylw}$st${c_rst}")"
  done < <(jq -c '.nodes[]' "$SB_NODES")
}

pick_node() {
  local cnt sel
  cnt=$(node_count)
  [[ "$cnt" -gt 0 ]] || { echo ""; return; }
  list_nodes >&2
  sel=$(ask $'Select node number (Enter to go back)' "" )
  [[ "$sel" =~ ^[0-9]+$ ]] || { echo ""; return; }
  (( sel>=1 && sel<=cnt )) || { echo ""; return; }
  jq -r --argjson i "$((sel-1))" '.nodes[$i].id' "$SB_NODES"
}

manage_nodes() {
  require_must
  [[ "$(node_count)" -gt 0 ]] || { warn "no nodes, add one first"; pause; return; }
  local id
  id=$(pick_node)
  [[ -n "$id" ]] || return
  local n; n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")

  while :; do
    clear
    node_link "$n"
    local tp; tp=$(jq -r '.transport // ""' <<<"$n")
    cat <<EOF

  Node actions:
   1) Change SOCKS5 egress (edit/add/remove)
   2) Change port
   3) Reset UUID / password
   4) Enable/disable
   5) Delete node
EOF
    [[ "$tp" == "reality" ]] && echo "   6) Change Reality handshake target"
    echo "   0) Back"

    case "$(ask 'Select')" in
      1) edit_socks5 "$id" ;;
      2) edit_port "$id" ;;
      3) reset_secret "$id" ;;
      4) toggle_enabled "$id" ;;
      5) del_node "$id"; return ;;
      6) [[ "$tp" == "reality" ]] && edit_reality_dest "$id" ;;
      0|"") return ;;
      *) continue ;;
    esac
    n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES") || return
    [[ -n "$n" ]] || return
  done
}

edit_socks5() {
  local id="$1" s
  s=$(ask_socks5)
  if [[ -n "$s" ]]; then
    tmp_nodes "(.nodes[]|select(.id==\"$id\")).socks5 |= $s"
    ok "SOCKS5 updated"
  else
    if confirm "Remove SOCKS5 egress from this node?" n; then
      tmp_nodes "(.nodes[]|select(.id==\"$id\")) |= del(.socks5)"
      ok "SOCKS5 removed"
    fi
  fi
  rebuild_config && ok "applied" || err "apply failed"
  pause
}

edit_port() {
  local id="$1" n type cf tp newp proto
  n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")
  type=$(jq -r '.type' <<<"$n"); cf=$(jq -r '.cf//false' <<<"$n")
  tp=$(jq -r '.transport // ""' <<<"$n")
  proto=tcp
  if [[ "$tp" == "ws" ]]; then
    info "CF origin ports (pick one):"
    local i=1
    for p in "${CF_PORTS[@]}"; do
      local mark=""
      if port_taken_by_node "$p"; then mark=" [node]"
      elif port_in_use "$p"; then mark=" [in use]"
      fi
      printf '    %d) %s%s\n' "$i" "$p" "$mark"
      ((i++))
    done
  fi
  while :; do
    if [[ "$tp" == "ws" ]]; then
      local choice
      choice=$(ask "Port number or selection [1-${#CF_PORTS[@]}]" "$(jq -r '.port' <<<"$n")")
      if [[ "$choice" =~ ^[1-${#CF_PORTS[@]}]$ ]]; then
        newp="${CF_PORTS[$((choice-1))]}"
      elif printf '%s\n' "${CF_PORTS[@]}" | grep -qx "$choice"; then
        newp="$choice"
      else
        warn "pick from list: ${CF_PORTS[*]}"; continue
      fi
    else
      newp=$(ask "New port" "$(jq -r '.port' <<<"$n")")
      [[ "$newp" =~ ^[0-9]+$ ]] || { warn "invalid"; continue; }
    fi
    if jq -e --argjson p "$newp" --arg id "$id" \
        '.nodes[]|select(.port==$p and .id!=$id)' "$SB_NODES" >/dev/null 2>&1; then
      warn "port used by another node"; continue
    fi
    if [[ "$newp" != "$(jq -r '.port' <<<"$n")" ]] && port_in_use "$newp"; then
      confirm "Port $newp appears to be in use. Use anyway?" n || continue
    fi
    break
  done
  local oldp; oldp=$(jq -r '.port' <<<"$n")
  tmp_nodes "(.nodes[]|select(.id==\"$id\")).port = $newp"
  if [[ "$newp" != "$oldp" ]]; then
    close_port "$oldp" "$proto"
  fi
  open_port "$newp" "$proto"
  rebuild_config && ok "port changed to $newp" || err "apply failed"
  pause
}

reset_secret() {
  local id="$1" type
  type=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.type' "$SB_NODES")
  case "$type" in
    vless)
      local new_uuid
      new_uuid=$(ask_uuid)
      tmp_nodes "(.nodes[]|select(.id==\"$id\")).uuid = \"$new_uuid\""
      ok "UUID reset" ;;
    socks5)
      tmp_nodes "(.nodes[]|select(.id==\"$id\")).password = \"$(rand_pass)\""
      ok "password reset (username unchanged)" ;;
    *)
      tmp_nodes "(.nodes[]|select(.id==\"$id\")).password = \"$(rand_pass)\""
      ok "password reset" ;;
  esac
  rebuild_config && ok "applied" || err "apply failed"
  pause
}

toggle_enabled() {
  local id="$1"
  tmp_nodes "(.nodes[]|select(.id==\"$id\")).enabled |= (.|not)"
  rebuild_config && ok "enabled state toggled" || err "apply failed"
  pause
}

del_node() {
  local id="$1"
  confirm "Delete this node?" n || return
  local n port proto
  n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")
  port=$(jq -r '.port' <<<"$n")
  proto=tcp
  tmp_nodes "del(.nodes[]|select(.id==\"$id\"))"
  close_port "$port" "$proto"
  rebuild_config && ok "deleted" || err "apply failed"
  pause
}

edit_reality_dest() {
  local id="$1"
  echo; info "Change Reality handshake target:"
  local i=0
  for d in "${REALITY_DESTS[@]}"; do
    i=$((i+1))
    echo "  $i) $d"
  done
  echo "  0) custom"
  local sel dest
  sel=$(ask "Select" "1")
  if [[ "$sel" == "0" ]]; then
    dest=$(ask "Target domain")
  elif [[ "$sel" =~ ^[0-9]+$ ]] && ((sel>=1 && sel<=${#REALITY_DESTS[@]})); then
    dest="${REALITY_DESTS[$((sel-1))]}"
  else
    dest="${REALITY_DESTS[0]}"
  fi
  tmp_nodes "(.nodes[]|select(.id==\"$id\")) |= (.reality_sni=\"$dest\"|.reality_dest=\"$dest\")"
  rebuild_config && ok "handshake target changed to $dest" || err "apply failed"
  pause
}

# ----------------------------------------------------------------------------
# BBR acceleration
# ----------------------------------------------------------------------------
# default_qdisc sysctl only affects interfaces created afterwards;
# apply fq to the live default-route interface as well
apply_fq_qdisc() {
  local dev
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$dev" ]] || return 0
  tc qdisc replace dev "$dev" root fq 2>/dev/null || true
}

bbr_status() {
  local qdisc cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
  echo "congestion control: $cc  qdisc: $qdisc"
}

enable_bbr() {
  echo; info "BBR acceleration"
  local cc qdisc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

  if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
    apply_fq_qdisc
    ok "BBR already enabled ($(bbr_status))"
    pause; return
  fi

  info "current state: $(bbr_status)"

  local kver kmin
  kver=$(uname -r | cut -d. -f1-2)
  kmin="4.9"
  if ! printf '%s\n%s\n' "$kmin" "$kver" | sort -V -C; then
    die "kernel $kver does not support BBR (requires >= $kmin)"
  fi

  if ! modprobe tcp_bbr 2>/dev/null; then
    if ! grep -q tcp_bbr /proc/modules 2>/dev/null; then
      die "kernel lacks tcp_bbr module"
    fi
  fi

  confirm "Enable BBR?" y || { pause; return; }

  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1
  apply_fq_qdisc

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [[ "$cc" == "bbr" ]]; then
    ok "BBR enabled ($(bbr_status))"
  else
    err "failed to enable BBR, current: $(bbr_status)"
  fi
  pause
}

# ----------------------------------------------------------------------------
# System optimization (sysctl tuning / swap / journald cap)
# ----------------------------------------------------------------------------
write_tune_conf() {
  cat > "$TUNE_CONF" <<EOF
# OneVPS system tuning
# TCP buffers — high-BDP (long-distance) links
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# UDP buffers
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
# many concurrent connections
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
# cap unsent buffer per socket — lower latency for multiplexed proxy streams
net.ipv4.tcp_notsent_lowat = 131072
# drop dead connections faster
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fin_timeout = 30
vm.swappiness = 10
EOF
  if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    echo "net.netfilter.nf_conntrack_max = 262144" >> "$TUNE_CONF"
  fi
  sysctl --system >/dev/null 2>&1
  ok "network tuning applied ($TUNE_CONF)"
}

create_swap() {
  local size_mb="$1" f=/swapfile
  if [[ -f "$f" ]]; then
    warn "$f already exists, skipping"
    return
  fi
  info "creating ${size_mb}MiB swap file at $f ..."
  if ! fallocate -l "${size_mb}M" "$f" 2>/dev/null; then
    if ! dd if=/dev/zero of="$f" bs=1M count="$size_mb" status=none 2>/dev/null; then
      warn "failed to allocate swap file (disk full?)"
      rm -f "$f"; return
    fi
  fi
  chmod 600 "$f"
  if ! mkswap "$f" >/dev/null 2>&1 || ! swapon "$f" 2>/dev/null; then
    warn "swap activation failed (note: btrfs needs a NOCOW swapfile); removing $f"
    rm -f "$f"; return
  fi
  grep -q "^$f " /etc/fstab || echo "$f none swap sw 0 0" >> /etc/fstab
  ok "swap enabled (${size_mb}MiB)"
}

optimize_system() {
  echo; info "System optimization (network sysctl / swap / journald cap)"

  # --- sysctl network tuning ---
  if [[ -f "$TUNE_CONF" ]]; then
    ok "network tuning already applied ($TUNE_CONF)"
    if confirm "Re-apply (overwrite)?" n; then
      write_tune_conf
    fi
  else
    if confirm "Apply network tuning (TCP/UDP buffers, TFO, backlog)?" y; then
      write_tune_conf
    fi
  fi

  # --- swap ---
  local swap_kb mem_mb size_mb
  swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
  if [[ "${swap_kb:-0}" -gt 0 ]]; then
    ok "swap already present ($((swap_kb/1024)) MiB)"
  else
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    size_mb=512; [[ "$mem_mb" -le 1024 ]] && size_mb=1024
    if confirm "No swap detected (RAM ${mem_mb}MiB). Create ${size_mb}MiB swap file?" y; then
      create_swap "$size_mb"
    fi
  fi

  # --- journald disk cap ---
  if [[ -f /etc/systemd/journald.conf.d/onevps.conf ]]; then
    ok "journald disk cap already set"
  else
    if confirm "Cap journald logs at 50MiB?" y; then
      mkdir -p /etc/systemd/journald.conf.d
      cat > /etc/systemd/journald.conf.d/onevps.conf <<EOF
[Journal]
SystemMaxUse=50M
EOF
      systemctl restart systemd-journald 2>/dev/null || true
      ok "journald capped at 50MiB"
    fi
  fi
  pause
}

# ----------------------------------------------------------------------------
# Service / uninstall
# ----------------------------------------------------------------------------
restart_service() {
  require_must
  systemctl restart sing-box && ok "restarted" || err "restart failed"
  systemctl --no-pager -l status sing-box 2>/dev/null | head -n 6 || true
  pause
}

uninstall() {
  warn "Uninstall removes the sing-box binary, config, all nodes and certs"
  warn "(BBR/system tuning configs and the swap file are kept)"
  confirm "Confirm uninstall?" n || return
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$SB_SERVICE"; systemctl daemon-reload
  rm -f "$SB_BIN"
  rm -rf "$SB_DIR"
  ok "uninstalled"
  pause
}

# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------
status_line() {
  if [[ -x "$SB_BIN" ]]; then
    local v st; v=$(installed_version)
    st=$(systemctl is-active sing-box 2>/dev/null || echo unknown)
    local bbr_cc; bbr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    printf '%ssing-box %s — service:%s — nodes:%s — TCP:%s%s\n' \
      "$c_blu" "$v" "$st" "$(node_count 2>/dev/null || echo 0)" "$bbr_cc" "$c_rst"
  else
    printf '%ssing-box not installed%s\n' "$c_ylw" "$c_rst"
  fi
}

main_menu() {
  while :; do
    clear
    cat <<'EOF'
 ╔══════════════════════════════════╗
 ║   OneVPS — sing-box node script  ║
 ╚══════════════════════════════════╝
EOF
    status_line
    cat <<EOF

  1) Install / update sing-box
  2) Add node — VLESS (Reality / WS+CF)
  3) Add node — SOCKS5
  4) Manage nodes
  5) Show all share links
  6) Restart service
  7) BBR acceleration
  8) System optimization
  9) Uninstall
  0) Exit
EOF
    case "$(ask 'Select')" in
      1) install_singbox; pause ;;
      2) add_vless ;;
      3) add_socks5 ;;
      4) manage_nodes ;;
      5) show_links ;;
      6) restart_service ;;
      7) enable_bbr ;;
      8) optimize_system ;;
      9) uninstall ;;
      0|"") exit 0 ;;
      *) ;;
    esac
  done
}

# ----------------------------------------------------------------------------
main() {
  check_env
  main_menu
}
main "$@"
