#!/usr/bin/env bash
#
# OneVPS — sing-box 节点搭建脚本
# 协议: VLESS (Reality / WS+CF)  /  Hysteria2  /  SOCKS5
# 特性: 可选 Cloudflare CDN  /  可选 SOCKS5 落地
#
set -euo pipefail

# ----------------------------------------------------------------------------
# 常量
# ----------------------------------------------------------------------------
SB_DIR=/etc/sing-box
SB_BIN=/usr/local/bin/sing-box
SB_CONF=$SB_DIR/config.json
SB_NODES=$SB_DIR/nodes.json
SB_CERT_DIR=$SB_DIR/certs
SB_SERVICE=/etc/systemd/system/sing-box.service
GH_REPO=SagerNet/sing-box

CF_PORTS=(443 2053 2083 2087 2096 8443)
REALITY_DESTS=("www.microsoft.com" "www.apple.com" "www.samsung.com" "gateway.icloud.com" "www.lovelive-anime.jp")

PKG=""
ARCH=""
PUBIP=""

# ----------------------------------------------------------------------------
# 输出
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

pause() { read -rp $'\n回车继续...' _ || true; }

# ----------------------------------------------------------------------------
# 随机值
# ----------------------------------------------------------------------------
rand_uuid() {
  if [[ -x "$SB_BIN" ]]; then "$SB_BIN" generate uuid; return; fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; return; fi
  python3 -c 'import uuid;print(uuid.uuid4())'
}
rand_pass() { openssl rand -base64 16 | tr -d '/+=' | cut -c1-16; }
rand_path() { echo "/$(openssl rand -hex 6)"; }
rand_short_id() { openssl rand -hex 8; }
rand_port() {
  local p
  while :; do
    p=$(( RANDOM % 55535 + 10000 ))
    port_taken_by_node "$p" 2>/dev/null && continue
    port_in_use "$p" && continue
    echo "$p"; return
  done
}

reality_keypair() {
  if [[ -x "$SB_BIN" ]]; then
    "$SB_BIN" generate reality-keypair
  else
    die "需先安装 sing-box 才能生成 Reality 密钥对"
  fi
}

pub_ip() {
  [[ -n "$PUBIP" ]] && { echo "$PUBIP"; return; }
  PUBIP=$(curl -fsSL4 --max-time 8 https://api.ipify.org 2>/dev/null \
       || curl -fsSL4 --max-time 8 https://ifconfig.me 2>/dev/null || true)
  echo "$PUBIP"
}

# ----------------------------------------------------------------------------
# [1] 环境检测
# ----------------------------------------------------------------------------
check_env() {
  [[ $EUID -eq 0 ]] || die "需 root 运行 (sudo bash $0)"
  command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd,本脚本依赖 systemd 管理服务"

  case "$(uname -m)" in
    x86_64|amd64)        ARCH=amd64 ;;
    aarch64|arm64)       ARCH=arm64 ;;
    armv7l|armv7|armhf)  ARCH=armv7 ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac

  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG=yum
  elif command -v apk     >/dev/null 2>&1; then PKG=apk
  else die "未识别的包管理器 (支持 apt/dnf/yum/apk)"; fi

  ok "环境 OK — 架构:$ARCH  包管理:$PKG  systemd:yes"
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
    info "安装依赖: ${need[*]}"
    pkg_install "${need[@]}" || die "依赖安装失败: ${need[*]}"
  fi
}

# ----------------------------------------------------------------------------
# [2] 安装 / 更新 sing-box
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
  info "查询最新版本..."
  latest=$(latest_version) || die "无法获取最新版本"
  [[ -n "$latest" ]] || die "解析最新版本失败"
  cur=$(installed_version)

  if [[ -n "$cur" ]]; then
    if [[ "$cur" == "$latest" ]]; then
      ok "已是最新版 sing-box $cur"
      confirm "强制重装?" n || return 0
    else
      info "当前 $cur → 最新 $latest"
      confirm "更新?" y || return 0
    fi
  else
    info "将安装 sing-box $latest"
  fi

  local url tmp
  url="https://github.com/$GH_REPO/releases/download/v${latest}/sing-box-${latest}-linux-${ARCH}.tar.gz"
  tmp=$(mktemp -d)
  info "下载 $url"
  curl -fsSL "$url" -o "$tmp/sb.tar.gz" || { rm -rf "$tmp"; die "下载失败"; }
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "解压失败"; }
  install -m755 "$tmp/sing-box-${latest}-linux-${ARCH}/sing-box" "$SB_BIN"
  rm -rf "$tmp"

  mkdir -p "$SB_DIR" "$SB_CERT_DIR"
  [[ -f "$SB_NODES" ]] || echo '{"nodes":[],"acme_email":""}' > "$SB_NODES"

  write_service
  rebuild_config
  ok "sing-box $(installed_version) 安装完成"
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
# 防火墙 / 端口
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

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tunlp 2>/dev/null | grep -qE "[:.]$p\b"
  else
    return 1
  fi
}

port_taken_by_node() {
  jq -e --argjson p "$1" '.nodes[]|select(.port==$p)' "$SB_NODES" >/dev/null 2>&1
}

require_must() { command -v "$SB_BIN" >/dev/null 2>&1 || die "请先执行菜单 [1] 安装 sing-box"; }

# ----------------------------------------------------------------------------
# 证书(仅 WS+CF 和 Hysteria2 用)
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

acme_email() {
  local e
  e=$(jq -r '.acme_email // ""' "$SB_NODES")
  if [[ -z "$e" ]]; then
    e=$(ask "ACME 注册邮箱(Let's Encrypt 通知用)" "admin@$(hostname -f 2>/dev/null || echo example.com)")
    tmp_nodes ".acme_email=\"$e\""
  fi
  echo "$e"
}

# ----------------------------------------------------------------------------
# [3] 节点存储 + config 生成
# ----------------------------------------------------------------------------
tmp_nodes() {
  local expr="$1"
  local t; t=$(mktemp)
  jq "$expr" "$SB_NODES" > "$t" && mv "$t" "$SB_NODES"
}

node_count() { jq '.nodes|length' "$SB_NODES"; }

rebuild_config() {
  [[ -f "$SB_NODES" ]] || echo '{"nodes":[],"acme_email":""}' > "$SB_NODES"
  local email; email=$(jq -r '.acme_email // ""' "$SB_NODES")

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
      vless)     ib=$(build_vless_inbound "$n" "$email") ;;
      hysteria2) ib=$(build_hy2_inbound   "$n" "$email") ;;
      socks5)    ib=$(build_socks5_inbound "$n") ;;
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

  if [[ -x "$SB_BIN" ]]; then
    if ! "$SB_BIN" check -c "$SB_CONF" 2>/tmp/sb_check.err; then
      err "生成的配置校验失败:"; cat /tmp/sb_check.err >&2
      return 1
    fi
    systemctl restart sing-box 2>/dev/null || true
  fi
}

# --- VLESS inbound ---
build_vless_inbound() {
  local n="$1" email="$2"
  local transport; transport=$(jq -r '.transport' <<<"$n")

  if [[ "$transport" == "reality" ]]; then
    build_vless_reality_inbound "$n"
  else
    build_vless_ws_inbound "$n" "$email"
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
  local n="$1" email="$2" tls
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

# --- Hysteria2 inbound ---
build_hy2_inbound() {
  local n="$1" email="$2" tls
  local domain tlsmode crt key
  domain=$(jq -r '.domain // ""' <<<"$n")
  tlsmode=$(jq -r '.tls' <<<"$n")

  if [[ "$tlsmode" == "acme" ]]; then
    tls=$(jq -n --arg sn "$domain" --arg email "$email" '
      {enabled:true, server_name:$sn, alpn:["h3"],
       acme:{domain:[$sn], email:$email}}')
  else
    read -r crt key < <(gen_self_cert "${domain:-bing.com}")
    tls=$(jq -n --arg sn "${domain:-bing.com}" --arg crt "$crt" --arg key "$key" '
      {enabled:true, server_name:$sn, alpn:["h3"],
       certificate_path:$crt, key_path:$key}')
  fi

  jq -n \
    --arg tag "$(jq -r '.tag' <<<"$n")" \
    --argjson port "$(jq -r '.port' <<<"$n")" \
    --arg pass "$(jq -r '.password' <<<"$n")" \
    --argjson tls "$tls" '
    {
      type:"hysteria2", tag:$tag, listen:"::", listen_port:$port,
      users:[{password:$pass}],
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
# SOCKS5 落地交互
# ----------------------------------------------------------------------------
ask_socks5() {
  confirm "追加 SOCKS5 落地(节点全部流量走此 SOCKS5)?" n || { echo ""; return; }
  local srv port user pass
  srv=$(ask "SOCKS5 服务器地址")
  [[ -n "$srv" ]] || { warn "地址为空,跳过 SOCKS5"; echo ""; return; }
  port=$(ask "SOCKS5 端口" "1080")
  user=$(ask "用户名(无认证留空)" "")
  if [[ -n "$user" ]]; then
    pass=$(ask "密码" "")
  fi
  jq -n --arg s "$srv" --argjson p "$port" --arg u "$user" --arg w "${pass:-}" '
    {server:$s, port:$p}
    + (if $u!="" then {username:$u,password:$w} else {} end)'
}

# ----------------------------------------------------------------------------
# [4] 添加 VLESS 节点
# ----------------------------------------------------------------------------
add_vless() {
  require_must
  echo; info "添加 VLESS 节点"

  local name uuid id socks5
  name=$(ask "节点名称" "vless-$(openssl rand -hex 2)")
  uuid=$(rand_uuid)
  id=$(openssl rand -hex 4)

  if confirm "启用 Cloudflare CDN?" n; then
    add_vless_ws "$id" "$name" "$uuid"
  else
    add_vless_reality "$id" "$name" "$uuid"
  fi
}

add_vless_reality() {
  local id="$1" name="$2" uuid="$3"
  info "模式: VLESS + Reality (直连,无需域名/证书)"

  local port sni dest socks5
  while :; do
    port=$(ask "监听端口(回车随机)" "$(rand_port)")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "端口非法"; continue; }
    if port_taken_by_node "$port"; then warn "端口 $port 已被其他节点占用"; continue; fi
    if port_in_use "$port"; then
      confirm "端口 $port 似乎已被占用,仍使用?" n || continue
    fi
    break
  done

  echo; info "Reality 伪装目标站(需为支持 TLS 1.3 和 H2 的大站):"
  local i=0
  for d in "${REALITY_DESTS[@]}"; do
    i=$((i+1))
    echo "  $i) $d"
  done
  echo "  0) 自定义"
  local sel
  sel=$(ask "选择" "1")
  if [[ "$sel" == "0" ]]; then
    dest=$(ask "目标站域名")
  elif [[ "$sel" =~ ^[0-9]+$ ]] && ((sel>=1 && sel<=${#REALITY_DESTS[@]})); then
    dest="${REALITY_DESTS[$((sel-1))]}"
  else
    dest="${REALITY_DESTS[0]}"
  fi
  sni="$dest"

  info "生成 Reality 密钥对..."
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
    ok "VLESS + Reality 节点已添加"
    node_link "$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")"
  else
    err "配置生成失败,已回滚"
    tmp_nodes "del(.nodes[] | select(.id==\"$id\"))"
    rebuild_config || true
  fi
  pause
}

add_vless_ws() {
  local id="$1" name="$2" uuid="$3"
  info "模式: VLESS + WebSocket + CF CDN (需域名)"

  local domain port path socks5
  domain=$(ask "域名(已在 CF 托管,A 记录指向 VPS,橙云开启)")
  [[ -n "$domain" ]] || die "域名为空"

  info "CF 回源端口仅支持: ${CF_PORTS[*]}"
  while :; do
    port=$(ask "监听端口" "443")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "端口非法"; continue; }
    if ! printf '%s\n' "${CF_PORTS[@]}" | grep -qx "$port"; then
      warn "CF 模式端口须为: ${CF_PORTS[*]}"; continue
    fi
    if port_taken_by_node "$port"; then warn "端口 $port 已被其他节点占用"; continue; fi
    if port_in_use "$port"; then
      confirm "端口 $port 似乎已被占用,仍使用?" n || continue
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
    ok "VLESS + WS + CF 节点已添加"
    warn "请确保 CF 面板 SSL/TLS 设为 \"完全(Full)\""
    node_link "$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")"
  else
    err "配置生成失败,已回滚"
    tmp_nodes "del(.nodes[] | select(.id==\"$id\"))"
    rebuild_config || true
  fi
  pause
}

# ----------------------------------------------------------------------------
# [5] 添加 Hysteria2
# ----------------------------------------------------------------------------
add_hysteria2() {
  require_must
  echo; info "添加 Hysteria2 节点 (QUIC/UDP, 直连不支持 CF)"
  local name domain tls port pass socks5

  name=$(ask "节点名称" "hy2-$(openssl rand -hex 2)")

  if confirm "使用域名?" n; then
    domain=$(ask "域名(已解析到本机)")
    [[ -n "$domain" ]] || die "域名为空"
    if confirm "用 ACME 申请真证书? (需 80 端口可用且域名直连本机)" y; then
      tls=acme
    else
      tls=self; warn "自签证书,客户端需开启 insecure"
    fi
  else
    domain=""; tls=self
    warn "无域名: 自签证书,客户端需开启 insecure"
  fi

  while :; do
    port=$(ask "监听端口/UDP(回车随机)" "$(rand_port)")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "端口非法"; continue; }
    if port_taken_by_node "$port"; then warn "端口 $port 已被其他节点占用"; continue; fi
    break
  done

  pass=$(rand_pass)
  socks5=$(ask_socks5)

  local id; id=$(openssl rand -hex 4)
  local node
  node=$(jq -n \
    --arg id "$id" --arg name "$name" --arg tag "hy2-$id" \
    --argjson port "$port" --arg pass "$pass" \
    --arg domain "$domain" --arg tls "$tls" '
    {id:$id,type:"hysteria2",name:$name,tag:$tag,port:$port,password:$pass,
     domain:$domain,tls:$tls,enabled:true}')
  if [[ -n "$socks5" ]]; then
    node=$(jq -c --argjson s "$socks5" '. + {socks5:$s}' <<<"$node")
  fi

  [[ "$tls" == acme ]] && acme_email >/dev/null
  tmp_nodes ".nodes += [$node]"
  open_port "$port" udp

  if rebuild_config; then
    ok "Hysteria2 节点已添加"
    node_link "$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")"
  else
    err "配置生成失败,已回滚"
    tmp_nodes "del(.nodes[] | select(.id==\"$id\"))"
    rebuild_config || true
  fi
  pause
}

# ----------------------------------------------------------------------------
# [6] 添加 SOCKS5 节点
# ----------------------------------------------------------------------------
add_socks5() {
  require_must
  echo; info "添加 SOCKS5 节点"
  local name port user pass socks5

  name=$(ask "节点名称" "socks5-$(openssl rand -hex 2)")

  while :; do
    port=$(ask "监听端口(回车随机)" "$(rand_port)")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "端口非法"; continue; }
    if port_taken_by_node "$port"; then warn "端口 $port 已被其他节点占用"; continue; fi
    if port_in_use "$port"; then
      confirm "端口 $port 似乎已被占用,仍使用?" n || continue
    fi
    break
  done

  user=$(ask "认证用户名" "user-$(openssl rand -hex 2)")
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
    ok "SOCKS5 节点已添加"
    node_link "$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")"
  else
    err "配置生成失败,已回滚"
    tmp_nodes "del(.nodes[] | select(.id==\"$id\"))"
    rebuild_config || true
  fi
  pause
}

# ----------------------------------------------------------------------------
# 分享链接
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
  else
    local pass domain sni insecure
    pass=$(jq -r '.password' <<<"$n")
    domain=$(jq -r '.domain // ""' <<<"$n")
    addr="$domain"; [[ -z "$addr" ]] && addr="$(pub_ip)"
    sni="$domain"; [[ -z "$sni" ]] && sni="$addr"
    insecure=0; [[ "$(jq -r '.tls' <<<"$n")" == self ]] && insecure=1
    link="hysteria2://${pass}@${addr}:${port}?sni=${sni}&insecure=${insecure}#$(urlenc "$name")"
  fi

  echo
  local suffix=""
  [[ "$transport" == "reality" ]] && suffix="+reality"
  [[ "$transport" == "ws" ]] && suffix="+ws+cf"
  printf '%s── %s (%s%s) ──%s\n' "$c_grn" "$name" "$type" "$suffix" "$c_rst"
  echo "$link"
  if jq -e '.socks5' <<<"$n" >/dev/null 2>&1; then
    printf '%sSOCKS5 落地: %s:%s%s\n' "$c_ylw" \
      "$(jq -r '.socks5.server' <<<"$n")" "$(jq -r '.socks5.port' <<<"$n")" "$c_rst"
  fi
}

show_links() {
  require_must
  [[ "$(node_count)" -gt 0 ]] || { warn "无节点"; pause; return; }
  local n
  while IFS= read -r n; do node_link "$n"; done < <(jq -c '.nodes[]' "$SB_NODES")
  pause
}

# ----------------------------------------------------------------------------
# 节点管理
# ----------------------------------------------------------------------------
list_nodes() {
  local i=0 n
  while IFS= read -r n; do
    i=$((i+1))
    local en st tp
    en=$(jq -r '.enabled' <<<"$n"); st="启用"; [[ "$en" == true ]] || st="停用"
    tp=$(jq -r '.transport // ""' <<<"$n")
    local mode=""
    [[ "$tp" == "reality" ]] && mode="reality"
    [[ "$tp" == "ws" ]] && mode="ws+cf"
    printf '  %d) %-16s %-9s %-8s 端口:%-6s %s\n' \
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
  sel=$(ask $'选择节点序号(回车返回)' "" )
  [[ "$sel" =~ ^[0-9]+$ ]] || { echo ""; return; }
  (( sel>=1 && sel<=cnt )) || { echo ""; return; }
  jq -r --argjson i "$((sel-1))" '.nodes[$i].id' "$SB_NODES"
}

manage_nodes() {
  require_must
  [[ "$(node_count)" -gt 0 ]] || { warn "无节点,先添加"; pause; return; }
  local id
  id=$(pick_node)
  [[ -n "$id" ]] || return
  local n; n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")

  while :; do
    clear
    node_link "$n"
    local tp; tp=$(jq -r '.transport // ""' <<<"$n")
    cat <<EOF

  节点操作:
   1) 切换 SOCKS5 落地(改/加/删)
   2) 修改端口
   3) 重置 UUID / 密码
   4) 启用/停用
   5) 删除节点
EOF
    [[ "$tp" == "reality" ]] && echo "   6) 修改 Reality 伪装站"
    echo "   0) 返回"

    case "$(ask '选择')" in
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
    ok "SOCKS5 已更新"
  else
    if confirm "移除该节点 SOCKS5 落地?" n; then
      tmp_nodes "(.nodes[]|select(.id==\"$id\")) |= del(.socks5)"
      ok "SOCKS5 已移除"
    fi
  fi
  rebuild_config && ok "已应用" || err "应用失败"
  pause
}

edit_port() {
  local id="$1" n type cf tp newp proto
  n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")
  type=$(jq -r '.type' <<<"$n"); cf=$(jq -r '.cf//false' <<<"$n")
  tp=$(jq -r '.transport // ""' <<<"$n")
  proto=tcp; [[ "$type" == hysteria2 ]] && proto=udp
  while :; do
    newp=$(ask "新端口" "$(jq -r '.port' <<<"$n")")
    [[ "$newp" =~ ^[0-9]+$ ]] || { warn "非法"; continue; }
    if [[ "$tp" == "ws" ]] && ! printf '%s\n' "${CF_PORTS[@]}" | grep -qx "$newp"; then
      warn "WS+CF 模式端口须为: ${CF_PORTS[*]}"; continue
    fi
    if jq -e --argjson p "$newp" --arg id "$id" \
        '.nodes[]|select(.port==$p and .id!=$id)' "$SB_NODES" >/dev/null 2>&1; then
      warn "端口被其他节点占用"; continue
    fi
    break
  done
  tmp_nodes "(.nodes[]|select(.id==\"$id\")).port = $newp"
  open_port "$newp" "$proto"
  rebuild_config && ok "端口已改为 $newp" || err "应用失败"
  pause
}

reset_secret() {
  local id="$1" type
  type=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.type' "$SB_NODES")
  case "$type" in
    vless)
      tmp_nodes "(.nodes[]|select(.id==\"$id\")).uuid = \"$(rand_uuid)\""
      ok "UUID 已重置" ;;
    socks5)
      tmp_nodes "(.nodes[]|select(.id==\"$id\")).password = \"$(rand_pass)\""
      ok "密码已重置 (用户名不变)" ;;
    *)
      tmp_nodes "(.nodes[]|select(.id==\"$id\")).password = \"$(rand_pass)\""
      ok "密码已重置" ;;
  esac
  rebuild_config && ok "已应用" || err "应用失败"
  pause
}

toggle_enabled() {
  local id="$1"
  tmp_nodes "(.nodes[]|select(.id==\"$id\")).enabled |= (.|not)"
  rebuild_config && ok "已切换启用状态" || err "应用失败"
  pause
}

del_node() {
  local id="$1"
  confirm "确认删除该节点?" n || return
  tmp_nodes "del(.nodes[]|select(.id==\"$id\"))"
  rebuild_config && ok "已删除" || err "应用失败"
  pause
}

edit_reality_dest() {
  local id="$1"
  echo; info "修改 Reality 伪装目标站:"
  local i=0
  for d in "${REALITY_DESTS[@]}"; do
    i=$((i+1))
    echo "  $i) $d"
  done
  echo "  0) 自定义"
  local sel dest
  sel=$(ask "选择" "1")
  if [[ "$sel" == "0" ]]; then
    dest=$(ask "目标站域名")
  elif [[ "$sel" =~ ^[0-9]+$ ]] && ((sel>=1 && sel<=${#REALITY_DESTS[@]})); then
    dest="${REALITY_DESTS[$((sel-1))]}"
  else
    dest="${REALITY_DESTS[0]}"
  fi
  tmp_nodes "(.nodes[]|select(.id==\"$id\")) |= (.reality_sni=\"$dest\"|.reality_dest=\"$dest\")"
  rebuild_config && ok "伪装站已改为 $dest" || err "应用失败"
  pause
}

# ----------------------------------------------------------------------------
# BBR 加速
# ----------------------------------------------------------------------------
bbr_status() {
  local qdisc cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
  echo "拥塞控制: $cc  队列调度: $qdisc"
}

enable_bbr() {
  echo; info "BBR 加速设置"
  local cc qdisc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

  if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
    ok "BBR 已启用 ($(bbr_status))"
    pause; return
  fi

  info "当前状态: $(bbr_status)"

  local kver kmin
  kver=$(uname -r | cut -d. -f1-2)
  kmin="4.9"
  if ! printf '%s\n%s\n' "$kmin" "$kver" | sort -V -C; then
    die "内核版本 $kver 不支持 BBR (需 >= $kmin)"
  fi

  if ! modprobe tcp_bbr 2>/dev/null; then
    if ! grep -q tcp_bbr /proc/modules 2>/dev/null; then
      die "内核不支持 tcp_bbr 模块"
    fi
  fi

  confirm "启用 BBR 加速?" y || { pause; return; }

  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [[ "$cc" == "bbr" ]]; then
    ok "BBR 启用成功 ($(bbr_status))"
  else
    err "BBR 启用失败,当前: $(bbr_status)"
  fi
  pause
}

# ----------------------------------------------------------------------------
# 服务 / 卸载
# ----------------------------------------------------------------------------
restart_service() {
  require_must
  systemctl restart sing-box && ok "已重启" || err "重启失败"
  systemctl --no-pager -l status sing-box 2>/dev/null | head -n 6 || true
  pause
}

uninstall() {
  warn "卸载将删除 sing-box 二进制、配置、所有节点与证书"
  confirm "确认卸载?" n || return
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$SB_SERVICE"; systemctl daemon-reload
  rm -f "$SB_BIN"
  rm -rf "$SB_DIR"
  ok "已卸载"
  pause
}

# ----------------------------------------------------------------------------
# 主菜单
# ----------------------------------------------------------------------------
status_line() {
  if [[ -x "$SB_BIN" ]]; then
    local v st; v=$(installed_version)
    st=$(systemctl is-active sing-box 2>/dev/null || echo unknown)
    local bbr_cc; bbr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    printf '%ssing-box %s — 服务:%s — 节点:%s — TCP:%s%s\n' \
      "$c_blu" "$v" "$st" "$(node_count 2>/dev/null || echo 0)" "$bbr_cc" "$c_rst"
  else
    printf '%ssing-box 未安装%s\n' "$c_ylw" "$c_rst"
  fi
}

main_menu() {
  while :; do
    clear
    cat <<'EOF'
 ╔══════════════════════════════════╗
 ║   OneVPS — sing-box 节点脚本      ║
 ╚══════════════════════════════════╝
EOF
    status_line
    cat <<EOF

  1) 安装 / 更新 sing-box
  2) 添加节点 — VLESS (Reality / WS+CF)
  3) 添加节点 — Hysteria2
  4) 添加节点 — SOCKS5
  5) 管理节点
  6) 查看全部分享链接
  7) 重启服务
  8) BBR 加速
  9) 卸载
  0) 退出
EOF
    case "$(ask '选择')" in
      1) install_singbox; pause ;;
      2) add_vless ;;
      3) add_hysteria2 ;;
      4) add_socks5 ;;
      5) manage_nodes ;;
      6) show_links ;;
      7) restart_service ;;
      8) enable_bbr ;;
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
