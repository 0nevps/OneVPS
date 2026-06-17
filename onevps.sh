#!/usr/bin/env bash
#
# OneVPS - Xray Reality node setup script
# Protocol: VLESS + TCP + REALITY + XTLS Vision + uTLS
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
TUNE_CONF=/etc/sysctl.d/99-onevps-tune.conf

REALITY_DESTS=(
  "www.microsoft.com"
  "www.apple.com"
  "www.samsung.com"
  "gateway.icloud.com"
  "www.lovelive-anime.jp"
)

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
  echo "${d,,}"
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
  curl -fsSL "$XRAY_INSTALL_URL" -o "$tmp" || { rm -f "$tmp"; die "download failed"; }
  info "installing/updating Xray-core and geodata..."
  bash "$tmp" install || { rm -f "$tmp"; die "Xray install failed"; }
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
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tunl 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"
  else
    return 1
  fi
}

port_taken_by_node() {
  [[ -f "$XRAY_NODES" ]] || return 1
  jq -e --argjson p "$1" '.nodes[]|select(.port==$p)' "$XRAY_NODES" >/dev/null 2>&1
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
  "$XRAY_BIN" run -test -config "$conf" >/dev/null 2>"$err_file"
}

rebuild_config() {
  ensure_nodes_file

  local inbounds n enabled type ib
  inbounds='[]'
  while IFS= read -r n; do
    enabled=$(jq -r '.enabled' <<<"$n")
    [[ "$enabled" == "true" ]] || continue
    type=$(jq -r '.type' <<<"$n")
    case "$type" in
      vless-reality) ib=$(build_reality_inbound "$n") ;;
      *) continue ;;
    esac
    inbounds=$(jq -c --argjson x "$ib" '. + [$x]' <<<"$inbounds")
  done < <(jq -c '.nodes[]' "$XRAY_NODES")

  local tmp_conf chk_err
  tmp_conf=$(mktemp)
  jq -n --argjson inbounds "$inbounds" '
    {
      log: {loglevel: "warning"},
      inbounds: $inbounds,
      outbounds: [
        {tag: "direct", protocol: "freedom", settings: {domainStrategy: "UseIP"}},
        {tag: "block", protocol: "blackhole", settings: {}}
      ],
      routing: {
        domainStrategy: "AsIs",
        rules: [
          {
            type: "field",
            ip: [
              "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10",
              "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
              "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16",
              "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
              "::1/128", "fc00::/7", "fe80::/10"
            ],
            outboundTag: "block"
          },
          {type: "field", protocol: ["bittorrent"], outboundTag: "block"},
          {type: "field", network: "udp", port: "443", outboundTag: "block"}
        ]
      },
      policy: {
        levels: {
          "0": {handshake: 4, connIdle: 300, uplinkOnly: 2, downlinkOnly: 5}
        }
      }
    }' > "$tmp_conf"

  chk_err=$(mktemp)
  if ! validate_xray_config "$tmp_conf" "$chk_err"; then
    err "generated config failed validation:"
    cat "$chk_err" >&2
    rm -f "$tmp_conf" "$chk_err"
    return 1
  fi
  rm -f "$chk_err"

  mv "$tmp_conf" "$XRAY_CONF"
  secure_xray_files
  if [[ -x "$XRAY_BIN" ]]; then
    systemctl restart xray 2>/dev/null || true
  fi
}

build_reality_inbound() {
  local n="$1"
  jq -n \
    --arg tag "$(jq -r '.tag' <<<"$n")" \
    --argjson port "$(jq -r '.port' <<<"$n")" \
    --arg uuid "$(jq -r '.uuid' <<<"$n")" \
    --arg email "$(jq -r '.tag' <<<"$n")@onevps" \
    --arg sni "$(jq -r '.reality_sni' <<<"$n")" \
    --arg target "$(jq -r '.reality_target' <<<"$n"):$(jq -r '.reality_target_port // 443' <<<"$n")" \
    --arg pk "$(jq -r '.reality_private_key' <<<"$n")" \
    --arg sid "$(jq -r '.reality_short_id' <<<"$n")" '
    {
      tag: $tag,
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: {
        clients: [
          {id: $uuid, flow: "xtls-rprx-vision", email: $email}
        ],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          target: $target,
          xver: 0,
          serverNames: [$sni],
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
  info "probing target with: xray tls ping $domain"
  if timeout 12 "$XRAY_BIN" tls ping "$domain" >/dev/null 2>&1 \
     || timeout 12 "$XRAY_BIN" tls ping "$domain:443" >/dev/null 2>&1; then
    ok "target probe OK"
  else
    warn "target probe failed or timed out; continue only if this domain supports TLS 1.3/H2 and has stable SNI"
  fi
}

pick_reality_target() {
  echo >&2
  info "Reality handshake target (major TLS site; TLS 1.3 + H2 preferred):" >&2
  local i=0 d sel target
  for d in "${REALITY_DESTS[@]}"; do
    i=$((i+1))
    echo "  $i) $d" >&2
  done
  echo "  0) custom" >&2
  sel=$(ask "Select" "1")
  if [[ "$sel" == "0" ]]; then
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
# Share links
# ----------------------------------------------------------------------------
node_link() {
  local n="$1" type name port link addr uuid sni pubk sid spx fp
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
  fi

  echo
  printf '%s-- %s (VLESS Reality + Vision + uTLS) --%s\n' "$c_grn" "$name" "$c_rst"
  echo "$link"
  printf '%sTarget: %s:%s  uTLS: %s  shortId: %s%s\n' "$c_ylw" \
    "$(jq -r '.reality_target' <<<"$n")" "$(jq -r '.reality_target_port // 443' <<<"$n")" \
    "$(jq -r '.fingerprint // "chrome"' <<<"$n")" "$(jq -r '.reality_short_id' <<<"$n")" "$c_rst"
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
  local i=0 n en st
  while IFS= read -r n; do
    i=$((i+1))
    en=$(jq -r '.enabled' <<<"$n"); st="enabled"; [[ "$en" == true ]] || st="disabled"
    printf '  %d) %-18s port:%-6s target:%-24s %s\n' \
      "$i" "$(jq -r '.name' <<<"$n")" "$(jq -r '.port' <<<"$n")" \
      "$(jq -r '.reality_target' <<<"$n")" \
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
  local id n
  id=$(pick_node)
  [[ -n "$id" ]] || return
  n=$(node_by_id "$id")

  while :; do
    clear
    node_link "$n"
    cat <<EOF

  Node actions:
   1) Change port
   2) Reset UUID
   3) Rotate Reality keypair / shortId
   4) Change Reality handshake target
   5) Enable/disable
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
      0|"") return ;;
      *) continue ;;
    esac
    n=$(node_by_id "$id") || return
    [[ -n "$n" ]] || return
  done
}

edit_port() {
  local id="$1" n newp oldp
  n=$(node_by_id "$id")
  while :; do
    newp=$(ask "New port" "$(jq -r '.port' <<<"$n")")
    [[ "$newp" =~ ^[0-9]+$ ]] || { warn "invalid port"; continue; }
    newp=$((10#$newp))
    (( newp >= 1 && newp <= 65535 )) || { warn "port out of range"; continue; }
    if jq -e --argjson p "$newp" --arg id "$id" \
        '.nodes[]|select(.port==$p and .id!=$id)' "$XRAY_NODES" >/dev/null 2>&1; then
      warn "port used by another node"; continue
    fi
    if [[ "$newp" != "$(jq -r '.port' <<<"$n")" ]] && port_in_use "$newp"; then
      confirm "Port $newp appears to be in use. Use anyway?" n || continue
    fi
    break
  done
  oldp=$(jq -r '.port' <<<"$n")
  jq_update_nodes --arg id "$id" --argjson p "$newp" '(.nodes[]|select(.id==$id)).port = $p'
  if [[ "$newp" != "$oldp" ]]; then close_port "$oldp" tcp; fi
  open_port "$newp" tcp
  rebuild_config && ok "port changed to $newp" || err "apply failed"
  pause
}

reset_uuid() {
  local id="$1" new_uuid
  new_uuid=$(ask_uuid)
  jq_update_nodes --arg id "$id" --arg uuid "$new_uuid" '(.nodes[]|select(.id==$id)).uuid = $uuid'
  rebuild_config && ok "UUID reset" || err "apply failed"
  pause
}

rotate_reality_secret() {
  local id="$1" pk pubk sid
  confirm "Rotate Reality keypair and shortId? Old client links will stop working." n || return
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

toggle_enabled() {
  local id="$1"
  jq_update_nodes --arg id "$id" '(.nodes[]|select(.id==$id)).enabled |= (.|not)'
  rebuild_config && ok "enabled state toggled" || err "apply failed"
  pause
}

del_node() {
  local id="$1" n port
  confirm "Delete this node?" n || return
  n=$(node_by_id "$id")
  port=$(jq -r '.port' <<<"$n")
  jq_update_nodes --arg id "$id" 'del(.nodes[]|select(.id==$id))'
  close_port "$port" tcp
  rebuild_config && ok "deleted" || err "apply failed"
  pause
}

# ----------------------------------------------------------------------------
# BBR acceleration
# ----------------------------------------------------------------------------
apply_fq_qdisc() {
  command -v ip >/dev/null 2>&1 || return 0
  command -v tc >/dev/null 2>&1 || return 0
  local dev
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
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
  local cc qdisc kver kmin
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")

  if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
    apply_fq_qdisc
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

  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1
  apply_fq_qdisc

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
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
# TCP buffers - high-BDP (long-distance) links
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
# cap unsent buffer per socket - lower latency for multiplexed proxy streams
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
  require_xray
  rebuild_config
  systemctl restart xray && ok "restarted" || err "restart failed"
  systemctl --no-pager -l status xray 2>/dev/null | head -n 8 || true
  pause
}

uninstall() {
  warn "Uninstall removes Xray binary, config, onevps nodes and logs"
  warn "(BBR/system tuning configs and the swap file are kept)"
  confirm "Confirm uninstall?" n || return
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
# Main menu
# ----------------------------------------------------------------------------
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

main_menu() {
  while :; do
    clear
    cat <<'EOF'
 ╔════════════════════════════════════════════════╗
 ║   OneVPS - Xray Reality / Vision / uTLS       ║
 ╚════════════════════════════════════════════════╝
EOF
    status_line
    cat <<EOF

  1) Install / update Xray-core
  2) Add node - VLESS + Reality + Vision + uTLS
  3) Manage nodes
  4) Show all share links
  5) Restart service
  6) BBR acceleration
  7) System optimization
  8) Uninstall
  0) Exit
EOF
    case "$(ask 'Select')" in
      1) install_xray; pause ;;
      2) add_reality_node ;;
      3) manage_nodes ;;
      4) show_links ;;
      5) restart_service ;;
      6) enable_bbr ;;
      7) optimize_system ;;
      8) uninstall ;;
      0|"") exit 0 ;;
      *) ;;
    esac
  done
}

main() {
  check_env
  main_menu
}
main "$@"
