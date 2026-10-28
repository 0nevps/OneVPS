# shellcheck shell=bash
# Sing-box is an alternative installation, not a second concurrently managed core.

sing_owned() { [[ -f "$SING_DIR/.onevps-managed" && -x "$SING_BIN" ]]; }

sing_require() { sing_owned || { err 'No OneVPS-managed sing-box installation'; return 1; }; }

sing_free_path() { [[ ! -e "$1" && ! -L "$1" ]]; }

sing_asset() {
  case "$ARCH" in
    amd64) printf '%s %s\n' linux-amd64 699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ;;
    arm64) printf '%s %s\n' linux-arm64 436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ;;
    armv7) printf '%s %s\n' linux-armv7 fd164ed45ebc784f657a3e1d0e0ad0f68afdcff864ee57122c2cfed3ddb80a00 ;;
    *) return 1 ;;
  esac
}

sing_validate_users() {
  local source="$1" outbound
  jq -e '
    def uuid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
    all(.nodes[]; . as $n | (.users // []) as $users |
      ($users|type == "array") and
      ([$users[].id]|length == (unique|length)) and
      ([$users[].name]|length == (unique|length)) and
      all($users[];
        (.id|type == "string" and test("^[A-Za-z0-9_-]+$") and . != "default") and
        (.name|type == "string" and test("\\S") and (test("[\\x00-\\x1f\\x7f]")|not)) and
        (if $n.type == "vless-reality" or $n.type == "vmess-ws" then (.uuid|uuid)
         else (.password|type == "string" and length > 0) end)) and
      (if $n.type == "vless-reality" or $n.type == "vmess-ws" then
        ([ $n.uuid, $users[].uuid ] | map(ascii_downcase) | length == (unique|length))
       else ([ $n.password, $users[].password ] | length == (unique|length)) end))
  ' "$source" >/dev/null 2>&1 || return 1
  local outbounds
  outbounds=$(jq -c '.nodes[] | (select(has("outbound")) | .outbound),
    (select(has("default_outbound")) | .default_outbound),
    ((.users // [])[] | select(has("outbound")) | .outbound)' "$source") || return 1
  while IFS= read -r outbound; do
    [[ -n "$outbound" ]] || continue
    printf '%s\n' "$outbound" | validate_outbound || return 1
    sing_outbound_supported "$outbound" || return 1
  done <<<"$outbounds"
}

# Reject link features that have no equivalent in the pinned core.
sing_outbound_supported() {
  jq -e 'if .mode == "direct" then true
    elif .protocol == "socks" or .protocol == "shadowsocks" then true
    elif .protocol == "vmess" or .protocol == "vless" then
      (.params.type == "tcp" or .params.type == "ws") and
      ((.params.spx // "/") == "/") and
      ((.params.mode // "gun") == "gun")
    else false end' <<<"$1" >/dev/null 2>&1
}

sing_proxy_outbound() {
  local tag="$1" value="$2"
  jq -c --arg tag "$tag" '
    . as $v |
    {tag:$tag,type:$v.protocol,server:$v.server,server_port:$v.port} +
    if $v.protocol == "socks" then
      {version:"5"} + (if $v|has("username") then {username:$v.username,password:$v.password} else {} end)
    elif $v.protocol == "shadowsocks" then {method:$v.method,password:$v.password}
    elif $v.protocol == "vmess" or $v.protocol == "vless" then
      $v.params as $p |
      (if $v.protocol == "vmess" then {uuid:$v.uuid,security:$v.method,alter_id:0}
       else {uuid:$v.uuid} + (if ($p.flow // "") != "" then {flow:$p.flow} else {} end) end) +
      {tls:({enabled:true} +
        (if $p|has("sni") then {server_name:$p.sni} else {} end) +
        (if $p|has("alpn") then {alpn:($p.alpn|split(","))} else {} end) +
        (if $p|has("fp") then {utls:{enabled:true,fingerprint:$p.fp}} else {} end) +
        (if $p.security == "reality" then
          {reality:{enabled:true,public_key:$p.pbk,short_id:$p.sid}} else {} end))} +
      (if $p.type == "ws" then
        {transport:({type:"ws",path:($p.path // "/")} +
          (if $p|has("host") then {headers:{Host:$p.host}} else {} end))}
       else {} end)
    else error("unsupported sing-box outbound") end' <<<"$value"
}

sing_routes() {
  local source="$1" node user value tag auth outbound inherited
  local proxies='[]' rules='[]'
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    while IFS= read -r user; do
      [[ -n "$user" ]] || continue
      inherited=$(jq -c '.outbound // empty' <<<"$node") || return 1
      value=$(jq -c '.outbound // empty' <<<"$user") || return 1
      if [[ -z "$value" && $(jq -r '.id' <<<"$user") == default ]]; then
        value=$(jq -c '.default_outbound // empty' <<<"$node") || return 1
      fi
      [[ -n "$value" ]] || value=$inherited
      [[ -n "$value" ]] || continue
      tag=$(jq -r '.tag' <<<"$node")-$(jq -r '.id' <<<"$user")
      auth=$(jq -r '.id' <<<"$user")
      outbound=direct
      if [[ $(jq -r '.mode' <<<"$value") == proxy ]]; then
        outbound="out-$tag"
        local proxy
        proxy=$(sing_proxy_outbound "$outbound" "$value") || return 1
        proxies=$(printf '%s\n%s\n' "$proxies" "$proxy" | jq -sc '.[0] + [.[1]]') || return 1
      fi
      rules=$(jq -c --arg inbound "$(jq -r '.tag' <<<"$node")" --arg auth "$auth" --arg outbound "$outbound" \
        '. + [{inbound:[$inbound],auth_user:[$auth],action:"route",outbound:$outbound}]' <<<"$rules") || return 1
    done < <(jq -c '[{id:"default"}] + (.users // []) | .[]' <<<"$node")
  done < <(jq -c '.nodes[] | select(.enabled)' "$source")
  jq -nc --argjson outbounds "$proxies" --argjson rules "$rules" '{outbounds:$outbounds,rules:$rules}'
}

sing_render() {
  local source="$1" output="$2"
  local routes
  jq -e '(.nodes | type == "array") and
    ([.nodes[].id] | length == (unique | length)) and
    ([.nodes[] | select(.type == "vless-reality")] | length <= 1) and
    ([.nodes[] | select(.type == "hysteria2")] | length <= 1) and
    ([.nodes[] | select(.type == "trojan-ws")] | length <= 1) and
    ([.nodes[] | select(.type == "vmess-ws")] | length <= 1) and
    ([.nodes[] | select(.type != "hysteria2") | .port] | length == (unique | length)) and
    all(.nodes[]; (.enabled | type == "boolean") and
      (.id|type == "string" and test("^[0-9a-f]{8}$")) and
      (.name|type == "string" and length > 0) and
      (.port|type == "number" and floor == . and . >= 1 and . <= 65535) and
      (if .type == "vless-reality" then
        (.tag == ("reality-" + .id)) and
        (.uuid|type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")) and
        (.reality_target|type == "string" and length > 0) and
        (.reality_target_port == 443) and (.reality_sni == .reality_target) and
        (.reality_public_key|type == "string" and length > 0) and
        (.reality_private_key|type == "string" and length > 0) and
        (.reality_short_id|type == "string" and test("^[0-9a-fA-F]{16}$"))
      elif .type == "hysteria2" then
        (.tag == ("hy2-" + .id)) and
        (.domain|type == "string" and test("^[a-z0-9.-]+$")) and
        (.password|type == "string" and length > 0) and
        (.tls_cert|type == "string" and startswith("/")) and
        (.tls_key|type == "string" and startswith("/"))
      elif .type == "trojan-ws" or .type == "vmess-ws" then
        (.tag == ((if .type == "vmess-ws" then "vmess-" else "trojan-" end) + .id)) and
        (.domain|type == "string" and test("^[a-z0-9.-]+$")) and
        (if .type == "vmess-ws" then
          (.uuid|type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
        else (.password|type == "string" and length > 0) end) and
        (.ws_path|type == "string" and test("^/[a-zA-Z0-9_/-]+$")) and
        (.caddy_file|type == "string" and startswith("/"))
      else false end))' \
    "$source" >/dev/null || return 1
  sing_validate_users "$source" || return 1
  routes=$(sing_routes "$source") || return 1
  jq --slurpfile extra <(printf '%s\n' "$routes") '{log:{level:"warn"},dns:{servers:[{type:"local",tag:"local"}]},
    inbounds:[.nodes[] | select(.enabled) | if .type == "vless-reality" then
      {type:"vless",tag:.tag,listen:"0.0.0.0",listen_port:.port,
        users:([{name:"default",uuid:.uuid,flow:"xtls-rprx-vision"}] +
          [(.users // [])[] | {name:.id,uuid:.uuid,flow:"xtls-rprx-vision"}]),
        tls:{enabled:true,server_name:.reality_sni,
          reality:{enabled:true,handshake:{server:.reality_target,server_port:.reality_target_port},
            private_key:.reality_private_key,short_id:[.reality_short_id]}}}
      elif .type == "hysteria2" then
        {type:"hysteria2",tag:.tag,listen:"0.0.0.0",listen_port:.port,
          users:([{name:"default",password:.password}] +
            [(.users // [])[] | {name:.id,password:.password}]),
          tls:{enabled:true,server_name:.domain,alpn:["h3"],
            certificate_path:.tls_cert,key_path:.tls_key}}
      elif .type == "trojan-ws" then
        {type:"trojan",tag:.tag,listen:"127.0.0.1",listen_port:.port,
          users:([{name:"default",password:.password}] +
            [(.users // [])[] | {name:.id,password:.password}]),
          transport:{type:"ws",path:.ws_path}}
      else
        {type:"vmess",tag:.tag,listen:"127.0.0.1",listen_port:.port,
          users:([{name:"default",uuid:.uuid,alterId:0}] +
            [(.users // [])[] | {name:.id,uuid:.uuid,alterId:0}]),
          transport:{type:"ws",path:.ws_path}}
      end],
    outbounds:([{type:"direct",tag:"direct"}] + $extra[0].outbounds),
    route:{rules:([
      {action:"resolve",server:"local"},
      {ip_cidr:["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8",
        "169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24",
        "192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24",
        "::1/128","fc00::/7","fe80::/10"],action:"reject"},
      {action:"sniff"},{protocol:"bittorrent",action:"reject"}
    ] + $extra[0].rules),final:"direct"}}' "$source" > "$output"
}

sing_check() { "$SING_BIN" check -c "$1" >"$2" 2>&1; }

sing_service() {
  cat <<EOF
[Unit]
Description=Sing-box Service (OneVPS)
After=network-online.target
Wants=network-online.target
[Service]
User=nobody
WorkingDirectory=$SING_DIR
ExecStart=$SING_BIN run -c $SING_CONF
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
[Install]
WantedBy=multi-user.target
EOF
}

sing_secure() {
  local group
  group=$(id -gn nobody) || return 1
  chown root:"$group" "$SING_DIR" "$SING_CONF" "$SING_NODES" &&
    chmod 750 "$SING_DIR" && chmod 640 "$SING_CONF" "$SING_NODES"
}

sing_install() (
  if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" || -e "$XRAY_NODES" || -e "$XRAY_CONF" ]] ||
    systemctl cat xray >/dev/null 2>&1; then
    err 'Existing Xray installation or data detected; automatic switching is not supported'; return 1;
  fi
  if command -v sing-box >/dev/null 2>&1 || systemctl cat sing-box >/dev/null 2>&1; then
    err 'Unmanaged sing-box binary or service detected'; return 1
  fi
  local path
  for path in "$SING_BIN" "$SING_SERVICE" "$SING_CONF" "$SING_NODES" "$SING_DIR"; do
    sing_free_path "$path" || { err 'Sing-box already installed or unmanaged files detected'; return 1; }
  done
  ensure_deps
  local arch digest asset url tmp actual candidate committed=false touched=false
  read -r arch digest <<<"$(sing_asset)" || return 1
  [[ -n "$arch" && -n "$digest" ]] || return 1
  asset="sing-box-$SING_VERSION-$arch.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v$SING_VERSION/$asset"
  tmp=$(mktemp -d) || return 1
  sing_install_cleanup() {
    local status=$?
    trap - EXIT
    if ! $committed && $touched; then
      systemctl disable --now sing-box >/dev/null 2>&1 || true
      rm -f "$SING_BIN" "$SING_SERVICE"
      rm -rf "$SING_DIR"
      systemctl daemon-reload || true
    fi
    rm -rf "$tmp"
    exit "$status"
  }
  trap sing_install_cleanup EXIT
  if ! download_file --connect-timeout 15 --max-time 180 "$url" -o "$tmp/archive.tar.gz"; then
    err 'sing-box download failed'; return 1
  fi
  actual=$(openssl dgst -sha256 "$tmp/archive.tar.gz") || return 1
  [[ "${actual##* }" == "$digest" ]] || { err 'sing-box checksum mismatch'; return 1; }
  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" "sing-box-$SING_VERSION-$arch/sing-box" || return 1
  candidate="$tmp/sing-box-$SING_VERSION-$arch/sing-box"
  chmod 755 "$candidate"
  [[ $("$candidate" version | awk 'NR==1{print $3}') == "$SING_VERSION" ]] || return 1
  [[ $("$candidate" version) == *with_acme* ]] || { err 'Official build lacks ACME support'; return 1; }
  printf '{"nodes":[]}\n' > "$tmp/nodes.json"
  sing_render "$tmp/nodes.json" "$tmp/config.json" || return 1
  "$candidate" check -c "$tmp/config.json" >"$tmp/check.log" 2>&1 || {
    err 'sing-box configuration check failed (details withheld)'; return 1;
  }
  touched=true
  mkdir -p "$SING_DIR" || return 1
  install -m 640 "$tmp/nodes.json" "$SING_NODES" || return 1
  install -m 755 "$candidate" "$SING_BIN" || return 1
  install -m 640 "$tmp/config.json" "$SING_CONF" || return 1
  sing_secure || return 1
  sing_service > "$SING_SERVICE" || return 1
  systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box &&
    systemctl is-active --quiet sing-box || { err 'sing-box service failed; inspect journalctl -u sing-box'; return 1; }
  touch "$SING_DIR/.onevps-managed" || return 1
  committed=true
  ok "sing-box $SING_VERSION installed"
)

sing_add_reality() (
  sing_require || return 1
  [[ -f "$SING_NODES" && -f "$SING_CONF" ]] || { err 'Sing-box state is incomplete'; return 1; }
  jq -e 'all(.nodes[]; .type != "vless-reality")' "$SING_NODES" >/dev/null || { err 'Only one REALITY node is supported'; return 1; }
  local name uuid id port target kp pk pubk sid node work active=false
  name=$(ask 'Node name' "reality-$(openssl rand -hex 2)")
  uuid=$(ask_uuid)
  id=$(openssl rand -hex 4)
  port=$(ask 'TCP listen port' 443)
  realm_valid_port "$port" || { err 'Invalid port'; return 1; }
  port=$((10#$port))
  if port_in_use "$port" tcp; then err 'Port already in use'; return 1; fi
  target=$(normalize_domain "$(ask 'REALITY handshake domain' 'www.cloudflare.com')")
  is_valid_domain "$target" || { err 'Invalid domain'; return 1; }
  kp=$("$SING_BIN" generate reality-keypair) || return 1
  pk=$(awk '/^PrivateKey: /{print $2}' <<<"$kp")
  pubk=$(awk '/^PublicKey: /{print $2}' <<<"$kp")
  [[ -n "$pk" && -n "$pubk" ]] || return 1
  sid=$(rand_short_id)
  node=$(jq -nc --arg id "$id" --arg name "$name" --arg uuid "$uuid" \
    --arg target "$target" --arg pk "$pk" --arg pubk "$pubk" --arg sid "$sid" --argjson port "$port" \
    '{nodes:[{id:$id,name:$name,type:"vless-reality",tag:("reality-"+$id),uuid:$uuid,port:$port,
      reality_target:$target,reality_target_port:443,reality_sni:$target,
      reality_private_key:$pk,reality_public_key:$pubk,reality_short_id:$sid,enabled:true}]}') || return 1
  work=$(mktemp -d "$SING_DIR/.candidate.XXXXXXXX") || return 1
  local touched=false committed=false preserve=false
  sing_candidate_cleanup() {
    local status=$? failed=false
    trap - EXIT
    if $touched && ! $committed; then
      cp -p "$work/old-nodes.json" "$SING_NODES" && cp -p "$work/old-config.json" "$SING_CONF" || failed=true
      if $active; then
        systemctl restart sing-box && systemctl is-active --quiet sing-box || failed=true
      else
        systemctl stop sing-box || failed=true
      fi
      if $failed; then
        preserve=true
        err "ROLLBACK FAILED; backup retained at $work"
      else
        err 'Candidate failed; old sing-box configuration restored'
      fi
      status=1
    fi
    if ! $preserve; then rm -rf "$work"; fi
    exit "$status"
  }
  trap sing_candidate_cleanup EXIT
  jq --argjson added "$node" '.nodes += $added.nodes' "$SING_NODES" > "$work/nodes.json" || return 1
  sing_render "$work/nodes.json" "$work/config.json" && sing_check "$work/config.json" "$work/check.log" || {
    err 'Candidate sing-box configuration rejected'; return 1;
  }
  systemctl is-active --quiet sing-box && active=true
  cp -p "$SING_NODES" "$work/old-nodes.json" && cp -p "$SING_CONF" "$work/old-config.json" || return 1
  touched=true
  install -m 640 "$work/nodes.json" "$SING_NODES" && install -m 640 "$work/config.json" "$SING_CONF" &&
    sing_secure && systemctl restart sing-box && systemctl is-active --quiet sing-box || return 1
  committed=true
  open_port "$port" tcp
  ok 'Sing-box VLESS REALITY node added'
  node_link "$(jq -c --arg id "$id" '.nodes[] | select(.id == $id)' "$SING_NODES")"
)

sing_add_hysteria() (
  sing_require || return 1
  [[ -f "$SING_NODES" && -f "$SING_CONF" ]] || { err 'Sing-box state is incomplete'; return 1; }
  jq -e 'all(.nodes[]; .type != "hysteria2")' "$SING_NODES" >/dev/null || { err 'Only one Hysteria2 node is supported'; return 1; }
  local name domain port password id cert key node work active=false touched=false committed=false preserve=false
  domain=$(normalize_domain "$(ask 'TLS domain')")
  acme_domain_valid "$domain" || { err 'Invalid domain'; return 1; }
  if ! command -v ss >/dev/null 2>&1 || ! command -v runuser >/dev/null 2>&1; then
    err 'Hysteria2 requires ss and runuser'; return 1
  fi
  port=$(ask 'UDP listen port' 443)
  realm_valid_port "$port" || { err 'Invalid port'; return 1; }
  port=$((10#$port))
  if port_in_use "$port" udp; then err 'UDP port already in use'; return 1; fi
  name=$(ask 'Node name' "hy2-$(openssl rand -hex 2)")
  password=$(ask 'Password (Enter for random)' "$(rand_password)")
  [[ -n "$password" ]] || { err 'Empty password'; return 1; }
  id=$(openssl rand -hex 4)
  cert="$ACME_CERT_DIR/$domain/current/fullchain.pem"
  key="$ACME_CERT_DIR/$domain/current/key.pem"
  caddy_certificate_issue "$domain" || { err 'Caddy certificate setup failed'; return 1; }
  validate_hy2_certificate "$domain" "$cert" "$key" || return 1
  node=$(jq -nc --arg id "$id" --arg name "$name" --arg domain "$domain" \
    --arg password "$password" --arg cert "$cert" --arg key "$key" --argjson port "$port" \
    '{id:$id,name:$name,tag:("hy2-"+$id),type:"hysteria2",domain:$domain,password:$password,
      port:$port,tls_cert:$cert,tls_key:$key,enabled:true}') || return 1
  work=$(mktemp -d "$SING_DIR/.candidate.XXXXXXXX") || return 1
  sing_hy2_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      cp -p "$work/old-nodes.json" "$SING_NODES" && cp -p "$work/old-config.json" "$SING_CONF" || failed=true
      if $active; then
        systemctl restart sing-box && systemctl is-active --quiet sing-box || failed=true
      else systemctl stop sing-box || failed=true; fi
      if $failed; then preserve=true; err "ROLLBACK FAILED; backup retained at $work"
      else err 'Candidate failed; old sing-box configuration restored'; fi
      status=1
    fi
    if ! $preserve; then rm -rf "$work"; fi
    exit "$status"
  }
  trap sing_hy2_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  jq --argjson added "$node" '.nodes += [$added]' "$SING_NODES" > "$work/nodes.json" || return 1
  sing_render "$work/nodes.json" "$work/config.json" && sing_check "$work/config.json" "$work/check.log" || {
    err 'Candidate sing-box configuration rejected'; return 1;
  }
  cp -p "$SING_NODES" "$work/old-nodes.json" && cp -p "$SING_CONF" "$work/old-config.json" || return 1
  if systemctl is-active --quiet sing-box; then active=true; fi
  touched=true
  install -m 640 "$work/nodes.json" "$SING_NODES" && install -m 640 "$work/config.json" "$SING_CONF" &&
    sing_secure && systemctl restart sing-box && systemctl is-active --quiet sing-box || return 1
  committed=true
  open_port "$port" udp
  ok 'Sing-box Hysteria2 node added'
  node_link "$node"
)

sing_add_ws() (
  sing_require || return 1
  [[ -f "$SING_NODES" && -f "$SING_CONF" ]] || { err 'Sing-box state is incomplete'; return 1; }
  local type="${1:-trojan-ws}" kind prefix credential
  case "$type" in
    trojan-ws) kind=Trojan; prefix=trojan ;;
    vmess-ws) kind=VMess; prefix=vmess ;;
    *) err 'Unsupported WebSocket node type'; return 1 ;;
  esac
  jq -e --arg type "$type" 'all(.nodes[]; .type != $type)' "$SING_NODES" >/dev/null || {
    err "Only one $kind WebSocket node is supported"; return 1;
  }
  local name domain port id path file node work route touched=false committed=false active=false preserve=false
  name=$(ask 'Node name' "$prefix-$(openssl rand -hex 2)")
  domain=$(normalize_domain "$(ask 'TLS domain')")
  acme_domain_valid "$domain" || { err 'Invalid domain'; return 1; }
  port=$(ask 'Loopback TCP port' "$(rand_port)")
  realm_valid_port "$port" || { err 'Invalid port'; return 1; }
  port=$((10#$port))
  if port_in_use "$port" tcp || jq -e --argjson p "$port" \
    'any(.nodes[]; .type != "hysteria2" and .port == $p)' "$SING_NODES" >/dev/null; then
    err 'TCP port already in use'; return 1
  fi
  if (( port == 80 || port == 443 )); then err 'Caddy reserves TCP 80/443'; return 1; fi
  if [[ "$type" == vmess-ws ]]; then credential=$(ask_uuid) || return 1
  else
    credential=$(ask 'Password (Enter for random)' "$(rand_password)")
    [[ -n "$credential" ]] || { err 'Empty password'; return 1; }
  fi
  path="/$(openssl rand -hex 8)" || return 1
  id=$(openssl rand -hex 4) || return 1
  jq -e --arg id "$id" --arg domain "$domain" --arg path "$path" '
    all(.nodes[]; .id != $id and
      ((.type != "trojan-ws" and .type != "vmess-ws") or
        .domain != $domain or .ws_path != $path))' "$SING_NODES" >/dev/null || return 1
  prepare_caddy_for_trojan || return 1
  file=$(find_caddyfile)
  [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
  route="$CADDY_STATE/routes/$domain/$id.caddy"
  [[ ! -e "$route" && ! -L "$route" ]] || { err 'Caddy route already exists'; return 1; }
  node=$(jq -nc --arg id "$id" --arg name "$name" --arg domain "$domain" \
    --arg credential "$credential" --arg type "$type" --arg prefix "$prefix" \
    --arg path "$path" --arg file "$file" --argjson port "$port" \
    '{id:$id,name:$name,tag:($prefix+"-"+$id),type:$type,domain:$domain,
      port:$port,ws_path:$path,caddy_file:$file,enabled:true} +
      (if $type == "vmess-ws" then {uuid:$credential} else {password:$credential} end)') || return 1
  work=$(mktemp -d "$SING_DIR/.candidate.XXXXXXXX") || return 1
  sing_ws_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      if [[ -f "$route" ]]; then
        caddy_remove_route "$id" && caddy_reload "$file" || failed=true
      fi
      cp -p "$work/old-nodes.json" "$SING_NODES" && cp -p "$work/old-config.json" "$SING_CONF" || failed=true
      if $active; then
        systemctl restart sing-box && systemctl is-active --quiet sing-box || failed=true
      else systemctl stop sing-box || failed=true; fi
      if $failed; then preserve=true; err "ROLLBACK FAILED; backup retained at $work"
      else err 'Candidate failed; old sing-box configuration and Caddy route restored'; fi
      status=1
    fi
    if ! $preserve; then rm -rf "$work"; fi
    exit "$status"
  }
  trap sing_ws_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  jq --argjson added "$node" '.nodes += [$added]' "$SING_NODES" > "$work/nodes.json" || return 1
  sing_render "$work/nodes.json" "$work/config.json" && sing_check "$work/config.json" "$work/check.log" || {
    err 'Candidate sing-box configuration rejected'; return 1;
  }
  cp -p "$SING_NODES" "$work/old-nodes.json" && cp -p "$SING_CONF" "$work/old-config.json" || return 1
  if systemctl is-active --quiet sing-box; then active=true; fi
  touched=true
  install -m 640 "$work/nodes.json" "$SING_NODES" && install -m 640 "$work/config.json" "$SING_CONF" &&
    sing_secure && systemctl restart sing-box && systemctl is-active --quiet sing-box || return 1
  caddy_add_route "$id" "$domain" "$path" "$port" "$file" || return 1
  committed=true
  ok "Sing-box $kind WebSocket node added"
  node_link "$node"
)

# Keep node metadata, core config and the owned WS route in one rollback boundary.
sing_change_node() (
  local id="$1" action="$2" value='' old new work route='' file='' active=false
  local touched=false committed=false preserve=false route_changed=false failed=false
  sing_require || return 1
  [[ -f "$SING_NODES" && -f "$SING_CONF" ]] || return 1
  old=$(jq -ce --arg id "$id" '.nodes[] | select(.id == $id)' "$SING_NODES") || return 1
  [[ -n "$old" ]] || return 1
  if [[ "$action" != toggle && "$action" != delete ]]; then
    value=$(jq -cse 'select(length == 1) | .[0]') || return 1
  fi
  work=$(mktemp -d "$SING_DIR/.candidate.XXXXXXXX") || return 1
  sing_change_cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      if $route_changed; then
        if [[ -f "$work/old-route.caddy" ]]; then
          install -m 644 "$work/old-route.caddy" "$route" && caddy_reload "$file" || failed=true
        else
          caddy_remove_route "$id" && caddy_reload "$file" || failed=true
        fi
      fi
      cp -p "$work/old-nodes.json" "$SING_NODES" &&
        cp -p "$work/old-config.json" "$SING_CONF" || failed=true
      if $active; then
        systemctl restart sing-box && systemctl is-active --quiet sing-box || failed=true
      else
        systemctl stop sing-box || failed=true
      fi
      if $failed; then preserve=true; err "ROLLBACK FAILED; backup retained at $work"
      else err 'Change failed; old sing-box node and route restored'; fi
      status=1
    fi
    if ! $preserve; then rm -rf "$work"; fi
    exit "$status"
  }
  trap sing_change_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  case "$action" in
    port)
      [[ "$value" =~ ^[0-9]+$ ]] && realm_valid_port "$value" || return 1
      if jq -e '.type == "trojan-ws" or .type == "vmess-ws"' <<<"$old" >/dev/null &&
        (( value == 80 || value == 443 )); then return 1; fi
      if [[ "$value" != "$(jq -r '.port' <<<"$old")" ]]; then
        local proto=tcp
        [[ $(jq -r '.type' <<<"$old") == hysteria2 ]] && proto=udp
        if port_in_use "$value" "$proto"; then err 'Port already in use'; return 1; fi
      fi ;;
    credential)
      if jq -e '.type == "vless-reality" or .type == "vmess-ws"' <<<"$old" >/dev/null; then
        is_valid_uuid "$(jq -r . <<<"$value")" || return 1
      else [[ $(jq -r 'type == "string" and length > 0' <<<"$value") == true ]] || return 1; fi ;;
    toggle|delete) ;;
    *) return 1 ;;
  esac
  jq --arg id "$id" --arg action "$action" --argjson value "${value:-null}" '
    if $action == "delete" then .nodes |= map(select(.id != $id))
    else (.nodes[] | select(.id == $id)) |=
      if $action == "port" then .port = $value
      elif $action == "credential" then
        if .type == "vless-reality" or .type == "vmess-ws" then .uuid = $value else .password = $value end
      else .enabled |= not end end' "$SING_NODES" > "$work/nodes.json" || return 1
  sing_render "$work/nodes.json" "$work/config.json" && sing_check "$work/config.json" "$work/check.log" || {
    err 'Candidate sing-box configuration rejected'; return 1;
  }
  new=$(jq -c --arg id "$id" '.nodes[] | select(.id == $id)' "$work/nodes.json") || return 1
  if jq -e '.type == "trojan-ws" or .type == "vmess-ws"' <<<"$old" >/dev/null &&
    [[ "$action" == port || "$action" == toggle || "$action" == delete ]]; then
    file=$(jq -r '.caddy_file' <<<"$old")
    route="$CADDY_STATE/routes/$(jq -r '.domain' <<<"$old")/$id.caddy"
    [[ -f "$file" && ! -L "$file" && ! -L "$route" ]] || return 1
    if [[ $(jq -r '.enabled' <<<"$old") == true ]]; then
      [[ -f "$route" ]] || { err 'Managed WS route missing'; return 1; }
      cp -p "$route" "$work/old-route.caddy" || return 1
    elif [[ -e "$route" ]]; then err 'Unexpected route for disabled node'; return 1; fi
  fi
  cp -p "$SING_NODES" "$work/old-nodes.json" && cp -p "$SING_CONF" "$work/old-config.json" || return 1
  if systemctl is-active --quiet sing-box; then active=true; fi
  touched=true
  install -m 640 "$work/nodes.json" "$SING_NODES" && install -m 640 "$work/config.json" "$SING_CONF" &&
    sing_secure && systemctl restart sing-box && systemctl is-active --quiet sing-box || return 1
  if [[ -n "$route" ]]; then
    route_changed=true
    if [[ -n "$new" && $(jq -r '.enabled' <<<"$new") == true ]]; then
      caddy_add_route "$id" "$(jq -r .domain <<<"$new")" "$(jq -r .ws_path <<<"$new")" \
        "$(jq -r .port <<<"$new")" "$file" || return 1
    else
      caddy_remove_route "$id" && caddy_reload "$file" || return 1
    fi
  fi
  committed=true
  if [[ "$action" == port || "$action" == delete ]]; then
    local proto=tcp oldport
    [[ $(jq -r '.type' <<<"$old") == hysteria2 ]] && proto=udp
    oldport=$(jq -r .port <<<"$old")
    if [[ "$proto" == udp || $(jq -r '.type' <<<"$old") == vless-reality ]]; then
      if [[ "$action" == delete || "$oldport" != "$value" ]]; then close_port "$oldport" "$proto"; fi
      if [[ "$action" == port && "$oldport" != "$value" ]]; then open_port "$value" "$proto"; fi
    fi
  fi
)

# Reuse the sing-box candidate transaction without changing the Xray transaction.
sing_change_user_or_outbound() (
  local prepare="$1" id="$2" action="$3" work active=false touched=false committed=false preserve=false
  shift 3
  sing_require || return 1
  [[ -f "$SING_NODES" && -f "$SING_CONF" ]] || return 1
  work=$(mktemp -d "$SING_DIR/.candidate.XXXXXXXX") || return 1
  sing_user_cleanup() {
    local status=$? failed=false
    trap - EXIT INT TERM HUP
    if $touched && ! $committed; then
      cp -p "$work/old-nodes.json" "$SING_NODES" &&
        cp -p "$work/old-config.json" "$SING_CONF" || failed=true
      if $active; then
        systemctl restart sing-box && systemctl is-active --quiet sing-box || failed=true
      else systemctl stop sing-box || failed=true; fi
      if $failed; then preserve=true; err "ROLLBACK FAILED; backup retained at $work"
      else err 'Change failed; old sing-box configuration restored'; fi
      status=1
    fi
    if ! $preserve; then rm -rf "$work"; fi
    exit "$status"
  }
  trap sing_user_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  "$prepare" "$SING_NODES" "$work/nodes.json" "$id" "$action" "$@" || return 1
  sing_render "$work/nodes.json" "$work/config.json" && sing_check "$work/config.json" "$work/check.log" || {
    err 'Candidate sing-box configuration rejected'; return 1;
  }
  cp -p "$SING_NODES" "$work/old-nodes.json" && cp -p "$SING_CONF" "$work/old-config.json" || return 1
  if systemctl is-active --quiet sing-box; then active=true; fi
  touched=true
  install -m 640 "$work/nodes.json" "$SING_NODES" && install -m 640 "$work/config.json" "$SING_CONF" &&
    sing_secure && systemctl restart sing-box && systemctl is-active --quiet sing-box || return 1
  committed=true
)

sing_prepare_user() {
  local source="$1" output="$2" id="$3" action="$4" uid="${5:-}" payload
  [[ "$action" == add || "$action" == delete ]] || return 1
  jq -e --arg id "$id" 'any(.nodes[]; .id == $id)' "$source" >/dev/null || return 1
  if [[ "$action" == add ]]; then
    payload=$(jq -cse 'select(length == 1) | .[0]') || return 1
    jq --slurpfile source "$source" --arg id "$id" \
      '. as $user | $source[0] | (.nodes[] | select(.id == $id)).users += [$user]' \
      <<<"$payload" > "$output" || return 1
  else
    [[ "$uid" != default ]] || return 1
    jq -e --arg id "$id" --arg uid "$uid" 'any(.nodes[] | select(.id == $id) | (.users // [])[]; .id == $uid)' \
      "$source" >/dev/null || return 1
    jq --arg id "$id" --arg uid "$uid" '(.nodes[] | select(.id == $id)).users |= map(select(.id != $uid))' \
      "$source" > "$output" || return 1
  fi
}

sing_prepare_outbound() {
  local source="$1" output="$2" id="$3" scope="$4" selected="${5:-[]}" value
  [[ "$scope" == all || "$scope" == selected ]] || return 1
  value=$(jq -cse 'select(length == 1) | .[0]') || return 1
  [[ "$value" == '"inherit"' ]] || {
    printf '%s\n' "$value" | validate_outbound && sing_outbound_supported "$value" || return 1
  }
  jq -e --arg id "$id" 'any(.nodes[]; .id == $id)' "$source" >/dev/null || return 1
  if [[ "$scope" == selected ]]; then validate_node_selection "$source" "$id" "$selected" || return 1; fi
  jq --slurpfile source "$source" --arg id "$id" --arg scope "$scope" --argjson selected "$selected" '
    . as $value | $source[0] | (.nodes[] | select(.id == $id)) |=
      if $scope == "all" then
        (del(.default_outbound) | if has("users") then .users |= map(del(.outbound)) else . end |
          if $value == "inherit" then del(.outbound) else .outbound=$value end)
      else
        (if $selected | index("default") then
          if $value == "inherit" then del(.default_outbound) else .default_outbound=$value end
        else . end |
        if has("users") then .users |= map(.id as $uid | if $selected | index($uid) then
          if $value == "inherit" then del(.outbound) else .outbound=$value end
        else . end) else . end)
      end' <<<"$value" > "$output"
}

sing_manage_users() {
  local id="$1" node choice name uid credential payload selected
  while :; do
    node=$(jq -ce --arg id "$id" '.nodes[] | select(.id == $id)' "$SING_NODES") || return 1
    [[ -n "$node" ]] || return
    printf '\nUsers:\n'
    list_node_users "$node"
    printf '1) Add user\n2) Delete user\n3) Show user share link\n0) Back\n'
    choice=$(ask 'Select')
    case "$choice" in
      1)
        name=$(ask 'User name (Enter to cancel)')
        [[ -n "$name" ]] || continue
        uid=$(openssl rand -hex 8) || return 1
        if jq -e '.type == "vless-reality" or .type == "vmess-ws"' <<<"$node" >/dev/null; then
          credential=$(rand_uuid) || return 1
          payload=$(jq -nc --arg id "$uid" --arg name "$name" --arg uuid "$credential" '{id:$id,name:$name,uuid:$uuid}') || return 1
        else
          credential=$(rand_password) || return 1
          payload=$(jq -nc --arg id "$uid" --arg name "$name" --arg password "$credential" '{id:$id,name:$name,password:$password}') || return 1
        fi
        printf '%s\n' "$payload" | sing_change_user_or_outbound sing_prepare_user "$id" add || {
          err 'User not added'; continue;
        }
        ok 'User added'; node_user_link "$(jq -c --arg id "$id" '.nodes[] | select(.id == $id)' "$SING_NODES")" "$uid" ;;
      2|3)
        selected=$(pick_node_users "$node") || continue
        [[ $(jq length <<<"$selected") == 1 ]] || { warn 'Select exactly one user'; continue; }
        uid=$(jq -r '.[0]' <<<"$selected")
        if [[ "$choice" == 3 ]]; then node_user_link "$node" "$uid"; pause; continue; fi
        [[ "$uid" != default ]] || { warn 'Default user cannot be deleted'; continue; }
        confirm "Delete user $uid?" n || continue
        sing_change_user_or_outbound sing_prepare_user "$id" delete "$uid" || err 'User not deleted' ;;
      0|'') return ;;
      *) warn 'Invalid selection' ;;
    esac
  done
}

sing_manage_outbound() {
  local id="$1" node scope selected='[]' choice value link=''
  node=$(jq -ce --arg id "$id" '.nodes[] | select(.id == $id)' "$SING_NODES") || return 1
  printf '1) All users\n2) Selected users\n0) Cancel\n'
  case "$(ask 'Scope')" in
    1) scope=all ;;
    2) scope=selected; selected=$(pick_node_users "$node") || return 0 ;;
    *) return 0 ;;
  esac
  info 'Selected users inherit the node route when reset; all users reset to direct.'
  printf '1) Restore default\n2) Explicit direct\n3) Proxy link\n0) Cancel\n'
  choice=$(ask 'Select')
  case "$choice" in
    1) value='"inherit"' ;;
    2) value='{"mode":"direct"}' ;;
    3)
      printf 'Proxy link (Enter to cancel): ' >&2
      IFS= read -r link || return 1
      [[ -n "$link" ]] || return 0
      value=$(printf '%s\n' "$link" | parse_outbound_link) || { err 'Invalid proxy link'; return 1; }
      sing_outbound_supported "$value" || { err 'Unsupported sing-box outbound'; return 1; } ;;
    *) return 0 ;;
  esac
  confirm 'Apply outbound setting?' n || return 0
  printf '%s\n' "$value" | sing_change_user_or_outbound sing_prepare_outbound "$id" "$scope" "$selected" || {
    err 'Outbound unchanged'; return 1;
  }
  ok 'Outbound updated'
}

sing_manage_nodes() {
  sing_require || return 1
  local index id node type action value
  while :; do
    if ! jq -e '.nodes|length > 0' "$SING_NODES" >/dev/null; then warn 'No nodes'; return; fi
    jq -r '.nodes | to_entries[] | "\(.key+1)) \(.value.name) [\(.value.type)] port:\(.value.port) \(if .value.enabled then "enabled" else "disabled" end)"' "$SING_NODES"
    index=$(ask 'Node number (Enter to go back)')
    [[ -n "$index" ]] || return
    [[ "$index" =~ ^[1-9][0-9]{0,5}$ ]] || { warn 'Invalid node number'; continue; }
    node=$(jq -ce --argjson i "$((index-1))" '.nodes[$i] // empty' "$SING_NODES") || return 1
    [[ -n "$node" ]] || { warn 'Invalid node number'; continue; }
    id=$(jq -r .id <<<"$node")
    type=$(jq -r .type <<<"$node")
    printf '1) Change port\n2) Reset default credential\n3) Enable/disable\n4) Show share link\n5) Delete node\n6) Manage users\n7) Set outbound\n0) Back\n'
    action=$(ask 'Select')
    case "$action" in
      1)
        value=$(ask 'New listen port' "$(jq -r .port <<<"$node")")
        [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || { warn 'Invalid port'; continue; }
        printf '%s\n' "$value" | jq -R 'tonumber' | sing_change_node "$id" port || warn 'Port unchanged' ;;
      2)
        if [[ "$type" == vless-reality || "$type" == vmess-ws ]]; then value=$(ask_uuid)
        else value=$(ask 'New password (Enter for random)' "$(rand_password)"); fi
        printf '%s\n' "$value" | jq -R . | sing_change_node "$id" credential || warn 'Credential unchanged' ;;
      3) sing_change_node "$id" toggle || warn 'Status unchanged' ;;
      4) node_link "$node"; pause ;;
      5) if confirm "Delete node $(jq -r .name <<<"$node")?" n; then
           sing_change_node "$id" delete || warn 'Node not deleted'
         fi ;;
      6) sing_manage_users "$id" ;;
      7) sing_manage_outbound "$id" ;;
      0|'') return ;;
      *) warn 'Invalid selection' ;;
    esac
  done
}

sing_menu() {
  while :; do
    printf '\nSing-box (exclusive mode)\n1) Install sing-box\n2) Add VLESS REALITY node\n3) Show node links\n4) Restart service\n5) Update script\n6) Add Hysteria2 (Caddy certificate)\n7) Add Trojan WebSocket (behind Caddy)\n8) Add VMess AEAD WebSocket (behind Caddy)\n9) Uninstall sing-box\n10) Manage nodes\n0) Back/exit\n'
    case "$(ask 'Select')" in
      1) sing_install || warn 'Installation failed'; pause ;;
      2) sing_add_reality || warn 'Node not added'; pause ;;
      3) if sing_require; then
           local n
           if jq -e '.nodes|length > 0' "$SING_NODES" >/dev/null; then
             while IFS= read -r n; do node_link "$n"; done < <(jq -c '.nodes[]' "$SING_NODES")
           else warn 'No node installed'; fi
         fi; pause ;;
      4) sing_require && sing_check "$SING_CONF" /dev/null && systemctl restart sing-box || warn 'Restart failed'; pause ;;
      5) if update_script; then return 0; else pause; fi ;;
      6) sing_add_hysteria || warn 'Hysteria2 node not added'; pause ;;
      7) sing_add_ws trojan-ws || warn 'Trojan WebSocket node not added'; pause ;;
      8) sing_add_ws vmess-ws || warn 'VMess WebSocket node not added'; pause ;;
      9) sing_uninstall; pause ;;
      10) sing_manage_nodes ;;
      0|'') return ;;
      *) warn 'Invalid selection' ;;
    esac
  done
}

sing_uninstall() {
  sing_require || return 1
  confirm 'Remove OneVPS sing-box binary, service and all its nodes?' n || return 0
  local node route file
  while IFS= read -r node; do
    route="$CADDY_STATE/routes/$(jq -r '.domain' <<<"$node")/$(jq -r '.id' <<<"$node").caddy"
    file=$(jq -r '.caddy_file' <<<"$node")
    [[ -f "$route" && -f "$file" && ! -L "$route" && ! -L "$file" ]] || {
      err 'Missing or unmanaged Caddy route; sing-box uninstall cancelled'; return 1;
    }
  done < <(jq -c '.nodes[] | select(.type == "trojan-ws" or .type == "vmess-ws")' "$SING_NODES")
  while IFS= read -r node; do
    file=$(jq -r '.caddy_file' <<<"$node")
    caddy_remove_route "$(jq -r '.id' <<<"$node")" && caddy_reload "$file" || {
      err 'Caddy route cleanup failed; sing-box uninstall cancelled'; return 1;
    }
  done < <(jq -c '.nodes[] | select(.type == "trojan-ws" or .type == "vmess-ws")' "$SING_NODES")
  systemctl disable --now sing-box || return 1
  systemctl disable --now onevps-caddy-sync.timer 2>/dev/null || true
  rm -f "$SING_BIN" "$SING_SERVICE" || return 1
  systemctl daemon-reload || return 1
  rm -rf "$SING_DIR"
  ok 'Sing-box removed; Caddy sites and certificates are retained; firewall rules were not changed'
}
