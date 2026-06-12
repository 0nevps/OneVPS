#!/usr/bin/env bash
#
# OneVPS — sing-box 节点搭建脚本
# 协议: VLESS+WS  /  Hysteria2
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

# Cloudflare 代理(橙云)允许的回源 HTTPS 端口
CF_PORTS=(443 2053 2083 2087 2096 8443)

PKG=""          # apt | dnf | yum | apk
ARCH=""         # amd64 | arm64 | armv7
PUBIP=""        # 公网 IP(惰性获取)

# ----------------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'; c_rst=$'\e[0m'
info() { printf '%s[*]%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()  { err "$*"; exit 1; }

confirm() { # confirm "问题" [默认y]  -> 返回 0=yes
  local q="$1" def="${2:-n}" ans
  local hint="[y/N]"; [[ "$def" == y ]] && hint="[Y/n]"
  read -rp "$q $hint " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

ask() { # ask "提示" 默认值 -> echo 输入
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

pkg_install() { # pkg_install pkg...
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
# 防火墙放行
# ----------------------------------------------------------------------------
open_port() { # open_port port tcp|udp
  local p="$1" proto="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p/$proto" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/$proto" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

port_in_use() { # 0=被占用
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tunlp 2>/dev/null | grep -qE "[:.]$p\b"
  else
    return 1
  fi
}

# 校验端口未被本脚本其他节点占用(同协议族)
port_taken_by_node() { # port
  jq -e --argjson p "$1" '.nodes[]|select(.port==$p)' "$SB_NODES" >/dev/null 2>&1
}

require_must() { command -v "$SB_BIN" >/dev/null 2>&1 || die "请先执行菜单 [1] 安装 sing-box"; }

# ----------------------------------------------------------------------------
# 证书
# ----------------------------------------------------------------------------
gen_self_cert() { # gen_self_cert cn  -> 写 certs/cn.{crt,key},echo "crt key"
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
tmp_nodes() { # 对 nodes.json 应用 jq 表达式
  local expr="$1"
  local t; t=$(mktemp)
  jq "$expr" "$SB_NODES" > "$t" && mv "$t" "$SB_NODES"
}

node_count() { jq '.nodes|length' "$SB_NODES"; }

# 由 nodes.json 生成 sing-box config.json,然后重启
rebuild_config() {
  [[ -f "$SB_NODES" ]] || echo '{"nodes":[],"acme_email":""}' > "$SB_NODES"
  local email; email=$(jq -r '.acme_email // ""' "$SB_NODES")

  local inbounds outbounds rules
  inbounds=$(jq -c '[]' <<<'[]')
  outbounds='[{"type":"direct","tag":"direct"}]'
  rules='[]'

  local n type tag port enabled
  while IFS= read -r n; do
    enabled=$(jq -r '.enabled' <<<"$n")
    [[ "$enabled" == "true" ]] || continue
    type=$(jq -r '.type' <<<"$n")
    tag=$(jq -r '.tag' <<<"$n")

    local ib
    case "$type" in
      vless)     ib=$(build_vless_inbound "$n" "$email") ;;
      hysteria2) ib=$(build_hy2_inbound   "$n" "$email") ;;
      *) continue ;;
    esac
    inbounds=$(jq -c --argjson x "$ib" '. + [$x]' <<<"$inbounds")

    # SOCKS5 落地
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

# 构造 TLS 块(供 vless/hy2 共用): echo json
build_tls() { # build_tls node email [alpn_json]
  local n="$1" email="$2" alpn="${3:-}"
  local domain tlsmode crt key
  domain=$(jq -r '.domain // ""' <<<"$n")
  tlsmode=$(jq -r '.tls' <<<"$n")   # acme | self

  if [[ "$tlsmode" == "acme" ]]; then
    jq -n --arg sn "$domain" --arg email "$email" --argjson alpn "${alpn:-null}" '
      {enabled:true, server_name:$sn,
       acme:{domain:[$sn], email:$email}}
      + (if $alpn!=null then {alpn:$alpn} else {} end)'
  else
    read -r crt key < <(gen_self_cert "${domain:-bing.com}")
    jq -n --arg sn "${domain:-bing.com}" --arg crt "$crt" --arg key "$key" \
          --argjson alpn "${alpn:-null}" '
      {enabled:true, server_name:$sn,
       certificate_path:$crt, key_path:$key}
      + (if $alpn!=null then {alpn:$alpn} else {} end)'
  fi
}

build_vless_inbound() { # node email
  local n="$1" email="$2" tls
  tls=$(build_tls "$n" "$email")
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

build_hy2_inbound() { # node email
  local n="$1" email="$2" tls
  tls=$(build_tls "$n" "$email" '["h3"]')
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

# ----------------------------------------------------------------------------
# SOCKS5 落地交互 -> echo socks5 json 或空
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
# [4] 添加 VLESS+WS
# ----------------------------------------------------------------------------
add_vless() {
  require_must
  echo; info "添加 VLESS + WebSocket 节点"
  local name domain cf tls port path uuid socks5

  name=$(ask "节点名称" "vless-$(openssl rand -hex 2)")

  if confirm "使用域名? (套 CF CDN 必须有域名)" y; then
    domain=$(ask "域名(已解析到本机或 CF)")
    [[ -n "$domain" ]] || die "域名为空"
    if confirm "启用 Cloudflare CDN(橙云代理)?" n; then
      cf=true; tls=self
      warn "CF 模式: 回源用自签证书,请在 CF 面板把 SSL/TLS 设为 \"完全(Full)\""
    else
      cf=false; tls=acme
    fi
  else
    domain=""; cf=false; tls=self
    warn "无域名: 自签证书,客户端需开启 allowInsecure"
  fi

  # 端口
  local defport=443
  if [[ "$cf" == true ]]; then
    info "CF 回源端口仅支持: ${CF_PORTS[*]}"
  fi
  while :; do
    port=$(ask "监听端口" "$defport")
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "端口非法"; continue; }
    if [[ "$cf" == true ]] && ! printf '%s\n' "${CF_PORTS[@]}" | grep -qx "$port"; then
      warn "CF 模式端口须为: ${CF_PORTS[*]}"; continue
    fi
    if port_taken_by_node "$port"; then warn "端口 $port 已被其他节点占用"; continue; fi
    if port_in_use "$port"; then
      confirm "端口 $port 似乎已被系统其他进程占用,仍使用?" n || continue
    fi
    break
  done

  uuid=$(rand_uuid)
  path=$(rand_path)
  socks5=$(ask_socks5)

  local id; id=$(openssl rand -hex 4)
  local node
  node=$(jq -n \
    --arg id "$id" --arg name "$name" --arg tag "vless-$id" \
    --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
    --arg domain "$domain" --arg tls "$tls" --argjson cf "$cf" '
    {id:$id,type:"vless",name:$name,tag:$tag,port:$port,uuid:$uuid,
     ws_path:$path,domain:$domain,tls:$tls,cf:$cf,enabled:true}')
  if [[ -n "$socks5" ]]; then
    node=$(jq -c --argjson s "$socks5" '. + {socks5:$s}' <<<"$node")
  fi

  [[ "$tls" == acme ]] && acme_email >/dev/null
  tmp_nodes ".nodes += [$node]"
  open_port "$port" tcp

  if rebuild_config; then
    ok "VLESS 节点已添加"
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
    port=$(ask "监听端口(UDP)" "8443")
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
# 分享链接
# ----------------------------------------------------------------------------
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

node_link() { # node json -> echo 分享链接
  local n="$1" type addr port domain name
  type=$(jq -r '.type' <<<"$n")
  port=$(jq -r '.port' <<<"$n")
  domain=$(jq -r '.domain // ""' <<<"$n")
  name=$(jq -r '.name' <<<"$n")
  addr="$domain"; [[ -z "$addr" ]] && addr="$(pub_ip)"

  local link
  if [[ "$type" == vless ]]; then
    local uuid path host sni insecure
    uuid=$(jq -r '.uuid' <<<"$n")
    path=$(jq -r '.ws_path' <<<"$n")
    host="$domain"; sni="$domain"
    insecure=""
    [[ "$(jq -r '.tls' <<<"$n")" == self ]] && insecure="&allowInsecure=1"
    [[ -z "$sni" ]] && sni="$addr"
    link="vless://${uuid}@${addr}:${port}?encryption=none&security=tls&sni=${sni}&type=ws&host=${host}&path=$(urlenc "$path")${insecure}#$(urlenc "$name")"
  else
    local pass sni insecure
    pass=$(jq -r '.password' <<<"$n")
    sni="$domain"; [[ -z "$sni" ]] && sni="$addr"
    insecure=0; [[ "$(jq -r '.tls' <<<"$n")" == self ]] && insecure=1
    link="hysteria2://${pass}@${addr}:${port}?sni=${sni}&insecure=${insecure}#$(urlenc "$name")"
  fi

  echo
  printf '%s── %s (%s) ──%s\n' "$c_grn" "$name" "$type" "$c_rst"
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
list_nodes() { # 打印带序号列表
  local i=0 n
  while IFS= read -r n; do
    i=$((i+1))
    local en st
    en=$(jq -r '.enabled' <<<"$n"); st="启用"; [[ "$en" == true ]] || st="停用"
    printf '  %d) %-16s %-9s 端口:%-6s %s%s\n' \
      "$i" "$(jq -r '.name' <<<"$n")" "$(jq -r '.type' <<<"$n")" \
      "$(jq -r '.port' <<<"$n")" \
      "$([[ "$(jq -r '.cf//false' <<<"$n")" == true ]] && echo '[CF] ')" \
      "$([[ "$en" == true ]] && echo "$st" || echo "${c_ylw}$st${c_rst}")"
  done < <(jq -c '.nodes[]' "$SB_NODES")
}

pick_node() { # echo 选中 node id 或空
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
    cat <<EOF

  节点操作:
   1) 切换 SOCKS5 落地(改/加/删)
   2) 切换 Cloudflare CDN(仅 VLESS+域名)
   3) 修改端口
   4) 重置 UUID / 密码
   5) 启用/停用
   6) 删除节点
   0) 返回
EOF
    case "$(ask '选择')" in
      1) edit_socks5 "$id" ;;
      2) toggle_cf "$id" ;;
      3) edit_port "$id" ;;
      4) reset_secret "$id" ;;
      5) toggle_enabled "$id" ;;
      6) del_node "$id"; return ;;
      0|"") return ;;
      *) continue ;;
    esac
    # 刷新内存中的 node
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

toggle_cf() {
  local id="$1" n type domain cf
  n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")
  type=$(jq -r '.type' <<<"$n"); domain=$(jq -r '.domain//""' <<<"$n")
  cf=$(jq -r '.cf//false' <<<"$n")
  [[ "$type" == vless ]] || { warn "仅 VLESS 支持 CF"; pause; return; }
  [[ -n "$domain" ]] || { warn "无域名,无法启用 CF"; pause; return; }

  if [[ "$cf" == true ]]; then
    confirm "当前 CF 已启用,关闭并改用 ACME 真证书?" n || { pause; return; }
    tmp_nodes "(.nodes[]|select(.id==\"$id\")) |= (.cf=false|.tls=\"acme\")"
    acme_email >/dev/null
  else
    confirm "启用 CF? 端口须为 ${CF_PORTS[*]},证书改自签" n || { pause; return; }
    local p; p=$(jq -r '.port' <<<"$n")
    if ! printf '%s\n' "${CF_PORTS[@]}" | grep -qx "$p"; then
      warn "当前端口 $p 不在 CF 允许列表,请先改端口(操作 3)"; pause; return
    fi
    tmp_nodes "(.nodes[]|select(.id==\"$id\")) |= (.cf=true|.tls=\"self\")"
    warn "记得在 CF 面板把 SSL/TLS 设为 \"完全(Full)\""
  fi
  rebuild_config && ok "已应用" || err "应用失败"
  pause
}

edit_port() {
  local id="$1" n type cf proto newp
  n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SB_NODES")
  type=$(jq -r '.type' <<<"$n"); cf=$(jq -r '.cf//false' <<<"$n")
  proto=tcp; [[ "$type" == hysteria2 ]] && proto=udp
  while :; do
    newp=$(ask "新端口" "$(jq -r '.port' <<<"$n")")
    [[ "$newp" =~ ^[0-9]+$ ]] || { warn "非法"; continue; }
    if [[ "$cf" == true ]] && ! printf '%s\n' "${CF_PORTS[@]}" | grep -qx "$newp"; then
      warn "CF 模式端口须为: ${CF_PORTS[*]}"; continue
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
  if [[ "$type" == vless ]]; then
    tmp_nodes "(.nodes[]|select(.id==\"$id\")).uuid = \"$(rand_uuid)\""
    ok "UUID 已重置"
  else
    tmp_nodes "(.nodes[]|select(.id==\"$id\")).password = \"$(rand_pass)\""
    ok "密码已重置"
  fi
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
    printf '%ssing-box %s — 服务:%s — 节点:%s%s\n' \
      "$c_blu" "$v" "$st" "$(node_count 2>/dev/null || echo 0)" "$c_rst"
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
  2) 添加节点 — VLESS + WS
  3) 添加节点 — Hysteria2
  4) 管理节点
  5) 查看全部分享链接
  6) 重启服务
  7) 卸载
  0) 退出
EOF
    case "$(ask '选择')" in
      1) install_singbox; pause ;;
      2) add_vless ;;
      3) add_hysteria2 ;;
      4) manage_nodes ;;
      5) show_links ;;
      6) restart_service ;;
      7) uninstall ;;
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
