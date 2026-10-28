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

sing_render() {
  local source="$1" output="$2"
  jq -e '(.nodes | (type == "array" and length <= 1)) and
    all(.nodes[]; .type == "vless-reality" and .enabled == true and
      (.id|type == "string" and test("^[0-9a-f]{8}$")) and
      (.tag == ("reality-" + .id)) and
      (.name|type == "string" and length > 0) and
      (.uuid|type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")) and
      (.port|type == "number" and floor == . and . >= 1 and . <= 65535) and
      (.reality_target|type == "string" and length > 0) and
      (.reality_target_port == 443) and
      (.reality_sni == .reality_target) and
      (.reality_public_key|type == "string" and length > 0) and
      (.reality_private_key|type == "string" and length > 0) and
      (.reality_short_id|type == "string" and test("^[0-9a-fA-F]{16}$")))' \
    "$source" >/dev/null || return 1
  jq '{log:{level:"warn"},dns:{servers:[{type:"local",tag:"local"}]},
    inbounds:[.nodes[] | {
      type:"vless",tag:.tag,listen:"0.0.0.0",listen_port:.port,
      users:[{name:"default",uuid:.uuid,flow:"xtls-rprx-vision"}],
      tls:{enabled:true,server_name:.reality_sni,
        reality:{enabled:true,handshake:{server:.reality_target,server_port:.reality_target_port},
          private_key:.reality_private_key,short_id:[.reality_short_id]}}
    }],
    outbounds:[{type:"direct",tag:"direct"}],
    route:{rules:[
      {action:"resolve",server:"local"},
      {ip_cidr:["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8",
        "169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24",
        "192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24",
        "::1/128","fc00::/7","fe80::/10"],action:"reject"},
      {action:"sniff"},{protocol:"bittorrent",action:"reject"}
    ],final:"direct"}}' "$source" > "$output"
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
  jq -e '.nodes|length == 0' "$SING_NODES" >/dev/null || { err 'Only one sing-box node is supported in this phase'; return 1; }
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
  printf '%s\n' "$node" > "$work/nodes.json"
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
  node_link "$(jq -c '.nodes[0]' "$SING_NODES")"
)

sing_menu() {
  while :; do
    printf '\nSing-box (exclusive mode, VLESS REALITY only)\n1) Install sing-box\n2) Add VLESS REALITY node\n3) Show node link\n4) Restart service\n5) Update script\n9) Uninstall sing-box\n0) Back/exit\n'
    case "$(ask 'Select')" in
      1) sing_install || warn 'Installation failed'; pause ;;
      2) sing_add_reality || warn 'Node not added'; pause ;;
      3) if sing_require; then
           local n
           n=$(jq -c '.nodes[0] // empty' "$SING_NODES")
           if [[ -n "$n" ]]; then node_link "$n"; else warn 'No node installed'; fi
         fi; pause ;;
      4) sing_require && sing_check "$SING_CONF" /dev/null && systemctl restart sing-box || warn 'Restart failed'; pause ;;
      5) if update_script; then return 0; else pause; fi ;;
      9) sing_uninstall; pause ;;
      0|'') return ;;
      *) warn 'Invalid selection' ;;
    esac
  done
}

sing_uninstall() {
  sing_require || return 1
  confirm 'Remove OneVPS sing-box binary, service and all its nodes?' n || return 0
  systemctl disable --now sing-box || return 1
  rm -f "$SING_BIN" "$SING_SERVICE" || return 1
  systemctl daemon-reload || return 1
  rm -rf "$SING_DIR"
  ok 'Sing-box removed; firewall rules were not changed'
}
