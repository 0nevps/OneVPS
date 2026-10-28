# shellcheck shell=bash
# Xray core implementation. Bundled into onevps.sh for distribution.

# ----------------------------------------------------------------------------
# [2] Install / update Xray
# ----------------------------------------------------------------------------
require_xray() {
  command -v "$XRAY_BIN" >/dev/null 2>&1 || die "run menu option [1] to install Xray first"
}

installed_version() {
  [[ -x "$XRAY_BIN" ]] || { echo ""; return; }
  "$XRAY_BIN" version 2>/dev/null | awk '/^Xray /{print $2; exit}'
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

validate_xray_config() {
  local conf="$1" err_file="$2"
  [[ -x "$XRAY_BIN" ]] || return 0
  if jq -e 'any(.inbounds[]; .protocol == "hysteria")' "$conf" >/dev/null; then
    require_hy2_core || return 1
  fi
  "$XRAY_BIN" run -test -config "$conf" >"$err_file" 2>&1
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
    [.nodes[] | select(.enabled == true and (.type == "vless-reality" or .type == "vmess-ws" or .type == "trojan-ws" or .type == "hysteria2")) | . as $n |
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
      trojan-ws|vmess-ws) ib=$(build_trojan_inbound "$n") || return 1 ;;
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
        elif $n.type == "vmess-ws" then {id:.uuid,email}
        elif $n.type == "hysteria2" then {auth:.password,email}
        else {password,email} end)' <<<"$1"
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
      protocol: (if $n.type == "vmess-ws" then "vmess" else "trojan" end),
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
