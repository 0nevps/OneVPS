#!/usr/bin/env bash
#
# onevps-netwatch - lightweight VPS network/service recorder
#
# Samples network and system counters on a systemd timer and appends one
# logfmt line per sample. When a user reports "I could not connect at 14:30",
# `netwatch at 14:30` shows exactly what the box looked like at that moment,
# which separates a server-side fault from a link/client-side one.
#
# status, at and report answer that question in plain language, so an operator
# who does not read TCP counters still gets a verdict and a next step; --detail
# exposes the underlying numbers.
#
# Subcommands:
#   collect            take one sample and append it to the log (timer entry)
#   status             verdict for the last 24 hours
#   at <time>          verdict around a point in time
#   report [--since D] verdict over a window
#   tail               follow the raw log live
#   install            install and start the systemd timer
#   uninstall          remove the timer (add --purge to drop logs and config)
#
set -euo pipefail
umask 077

# ----------------------------------------------------------------------------
# Constants and defaults
# ----------------------------------------------------------------------------
NAME=onevps-netwatch
CONF=/etc/$NAME.conf
STATE_DIR=/var/lib/$NAME
STATE=$STATE_DIR/state
ALERT_DIR=$STATE_DIR/alerts
LOG=/var/log/$NAME.log
BIN=/usr/local/sbin/$NAME
SERVICE=/etc/systemd/system/$NAME.service
TIMER=/etc/systemd/system/$NAME.timer

# Overridable from $CONF
INTERVAL=30                 # seconds between samples
IFACE=""                    # network interface, empty = default route
MONITOR_UNITS=""            # space separated systemd units, empty = autodetect
LOG_MAX_BYTES=$((20 * 1024 * 1024))
LOG_KEEP=5                  # rotated files to retain
ALERT_COOLDOWN=1800         # seconds between repeats of the same alert
CT_ALERT_PCT=80             # conntrack usage alert threshold
DISK_ALERT_PCT=90
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
WEBHOOK_URL=""

AUTODETECT_UNITS="xray caddy nginx sshd ssh fail2ban docker"

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'; c_rst=$'\e[0m'
info() { printf '%s[*]%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "must run as root (sudo $0 $*)"
}

load_conf() {
  if [[ -r "$CONF" ]]; then
    # shellcheck source=/dev/null
    source "$CONF"
  fi
}

# ----------------------------------------------------------------------------
# Basic helpers
# ----------------------------------------------------------------------------

# Reads a whole file, or echoes a fallback when it is missing.
read_or() {
  local file="$1" fallback="${2:-}"
  if [[ -r "$file" ]]; then tr -d '\n' <"$file"; else printf '%s' "$fallback"; fi
}

# Forces the named variables to 0 unless they hold a plain integer.
numeric_or_zero() {
  local name
  for name in "$@"; do
    if [[ ! "${!name:-}" =~ ^[0-9]+$ ]]; then printf -v "$name" '%s' 0; fi
  done
}

# Non-negative counter delta; counters reset on reboot, so clamp at zero.
delta() {
  local cur="$1" prev="${2:-}" d
  if [[ -z "$prev" || ! "$prev" =~ ^[0-9]+$ || ! "$cur" =~ ^[0-9]+$ ]]; then
    printf '0'; return
  fi
  d=$(( cur - prev ))
  if (( d < 0 )); then d=0; fi
  printf '%s' "$d"
}

pct() {
  local part="$1" total="$2"
  if [[ ! "$part" =~ ^[0-9]+$ || ! "$total" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
    printf '0'; return
  fi
  printf '%s' "$(( part * 100 / total ))"
}

# Previous sample values, loaded as prev_<key> shell variables.
load_state() {
  [[ -r "$STATE" ]] || return 0
  local key val
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
    printf -v "prev_$key" '%s' "$val"
  done <"$STATE"
}

default_iface() {
  if [[ -n "$IFACE" ]]; then printf '%s' "$IFACE"; return; fi
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# Units that exist on this box, so the log only carries meaningful services.
detect_units() {
  if [[ -n "$MONITOR_UNITS" ]]; then printf '%s' "$MONITOR_UNITS"; return; fi
  local unit out=""
  for unit in $AUTODETECT_UNITS; do
    if systemctl cat "$unit.service" >/dev/null 2>&1; then out+="$unit "; fi
  done
  printf '%s' "${out% }"
}

# ----------------------------------------------------------------------------
# Metric collection
# ----------------------------------------------------------------------------

# Emits "ListenDrops ListenOverflows TCPSynRetrans" from /proc/net/netstat.
tcpext_counters() {
  awk '
    /^TcpExt:/ {
      if (!seen) { for (i = 2; i <= NF; i++) idx[$i] = i; seen = 1; next }
      d = (("ListenDrops" in idx)     ? $(idx["ListenDrops"])     : 0)
      o = (("ListenOverflows" in idx) ? $(idx["ListenOverflows"]) : 0)
      r = (("TCPSynRetrans" in idx)   ? $(idx["TCPSynRetrans"])   : 0)
      print d, o, r
      exit
    }
  ' /proc/net/netstat 2>/dev/null || printf '0 0 0\n'
}

# Emits "CurrEstab RetransSegs OutSegs" from /proc/net/snmp.
tcp_counters() {
  awk '
    /^Tcp:/ {
      if (!seen) { for (i = 2; i <= NF; i++) idx[$i] = i; seen = 1; next }
      e = (("CurrEstab" in idx)   ? $(idx["CurrEstab"])   : 0)
      r = (("RetransSegs" in idx) ? $(idx["RetransSegs"]) : 0)
      o = (("OutSegs" in idx)     ? $(idx["OutSegs"])     : 0)
      print e, r, o
      exit
    }
  ' /proc/net/snmp 2>/dev/null || printf '0 0 0\n'
}

# Emits "busy total" jiffies from /proc/stat, for CPU usage deltas.
cpu_jiffies() {
  awk '/^cpu /{ total = 0; for (i = 2; i <= NF; i++) total += $i; print total - $5, total; exit }' \
      /proc/stat 2>/dev/null || true
}

# Emits "rx_bytes rx_drop tx_bytes tx_drop" for one interface.
# The counter column can run into the "iface:" label when the value is large,
# so the label is stripped before the fields are split.
nic_counters() {
  local iface="$1"
  if [[ -z "$iface" ]]; then printf '0 0 0 0\n'; return; fi
  awk -v ifc="$iface" '
    { sub(/^[ \t]+/, "") }
    index($0, ifc ":") == 1 {
      rest = $0
      sub(/^[^:]+:[ \t]*/, "", rest)
      n = split(rest, f, /[ \t]+/)
      if (n >= 12) { print f[1], f[4], f[9], f[12]; found = 1; exit }
    }
    END { if (!found) print 0, 0, 0, 0 }
  ' /proc/net/dev
}

mem_pct() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
       END { if (t > 0) printf "%d", (t - a) * 100 / t; else printf "0" }' \
      /proc/meminfo 2>/dev/null || true
}

disk_pct() {
  df -P / 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5; exit }' || true
}

# Total IPs currently banned across all fail2ban jails.
fail2ban_banned() {
  command -v fail2ban-client >/dev/null 2>&1 || { printf '0'; return; }
  local jails jail total=0 n
  jails=$(timeout 5 fail2ban-client status 2>/dev/null \
          | awk -F: '/Jail list/ { gsub(/[ \t]/, "", $2); print $2 }' | tr ',' ' ' || true)
  for jail in $jails; do
    n=$(timeout 5 fail2ban-client status "$jail" 2>/dev/null \
        | awk -F: '/Currently banned/ { gsub(/[ \t]/, "", $2); print $2 }' || true)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    total=$(( total + n ))
  done
  printf '%s' "$total"
}

# Kernel ring buffer hits; used as deltas because the buffer wraps.
dmesg_count() {
  local pattern="$1"
  dmesg 2>/dev/null | grep -ci -- "$pattern" || true
}

# ----------------------------------------------------------------------------
# Sampling
# ----------------------------------------------------------------------------
collect() {
  require_root collect
  mkdir -p "$STATE_DIR" "$ALERT_DIR"

  load_state

  local now iface line alerts=""
  now=$(date +%s)
  iface=$(default_iface)

  # --- conntrack -------------------------------------------------------------
  local ct ct_max ct_pct
  ct=$(read_or /proc/sys/net/netfilter/nf_conntrack_count 0)
  ct_max=$(read_or /proc/sys/net/netfilter/nf_conntrack_max 0)
  [[ "$ct" =~ ^[0-9]+$ ]] || ct=0
  [[ "$ct_max" =~ ^[0-9]+$ ]] || ct_max=0
  ct_pct=$(pct "$ct" "$ct_max")

  # --- TCP -------------------------------------------------------------------
  # A kernel without these /proc sections yields no fields, so every read is
  # allowed to fail and each value is defaulted rather than aborting the run.
  local drops ovfl synretrans est retrans outsegs
  read -r drops ovfl synretrans < <(tcpext_counters) || true
  read -r est retrans outsegs < <(tcp_counters) || true
  numeric_or_zero drops ovfl synretrans est retrans outsegs

  local tw syn_recv listen_n
  tw=$(awk '/^TCP:/ { for (i = 1; i <= NF; i++) if ($i == "tw") { print $(i+1); exit } }' \
       /proc/net/sockstat 2>/dev/null || true)
  # pipefail is on, so a missing or failing 'ss' must not abort the sample.
  syn_recv=$(ss -H -tan state syn-recv 2>/dev/null | wc -l | tr -d ' ' || true)
  listen_n=$(ss -H -ltn 2>/dev/null | wc -l | tr -d ' ' || true)
  numeric_or_zero tw syn_recv listen_n

  local d_drops d_ovfl d_synretrans d_retrans d_outsegs retr_pct
  d_drops=$(delta "$drops" "${prev_drops_raw:-}")
  d_ovfl=$(delta "$ovfl" "${prev_ovfl_raw:-}")
  d_synretrans=$(delta "$synretrans" "${prev_synretrans_raw:-}")
  d_retrans=$(delta "$retrans" "${prev_retrans_raw:-}")
  d_outsegs=$(delta "$outsegs" "${prev_outsegs_raw:-}")
  retr_pct=$(pct "$d_retrans" "$d_outsegs")

  # --- CPU / memory / disk ---------------------------------------------------
  local cpu_busy cpu_total d_busy d_total cpu mem disk
  read -r cpu_busy cpu_total < <(cpu_jiffies) || true
  numeric_or_zero cpu_busy cpu_total
  d_busy=$(delta "$cpu_busy" "${prev_cpu_busy:-}")
  d_total=$(delta "$cpu_total" "${prev_cpu_total:-}")
  cpu=$(pct "$d_busy" "$d_total")
  mem=$(mem_pct)
  disk=$(disk_pct)
  numeric_or_zero mem disk

  # --- interface -------------------------------------------------------------
  local rx rxdrop tx txdrop d_secs rx_bps tx_bps d_rxdrop d_txdrop
  read -r rx rxdrop tx txdrop < <(nic_counters "$iface") || true
  numeric_or_zero rx rxdrop tx txdrop
  d_secs=$(delta "$now" "${prev_ts:-}")
  if [[ "$d_secs" -eq 0 ]]; then d_secs=1; fi
  rx_bps=$(( $(delta "$rx" "${prev_rx:-}") / d_secs ))
  tx_bps=$(( $(delta "$tx" "${prev_tx:-}") / d_secs ))
  d_rxdrop=$(delta "$rxdrop" "${prev_rxdrop:-}")
  d_txdrop=$(delta "$txdrop" "${prev_txdrop:-}")

  # --- kernel events ---------------------------------------------------------
  local oom ctfull d_oom d_ctfull
  oom=$(dmesg_count "out of memory")
  ctfull=$(dmesg_count "nf_conntrack: table full")
  d_oom=$(delta "$oom" "${prev_oom:-}")
  d_ctfull=$(delta "$ctfull" "${prev_ctfull:-}")

  # --- services --------------------------------------------------------------
  # Each MainPID is queried once and kept for the state file, so the logged
  # pid and the next sample's baseline can never disagree.
  local units unit svc_fields="" pid_state="" state pid var prev_pid
  units=$(detect_units)
  for unit in $units; do
    state=down
    if systemctl is-active --quiet "$unit.service" 2>/dev/null; then state=up; fi
    pid=$(systemctl show -p MainPID --value "$unit.service" 2>/dev/null || printf '0')
    [[ "$pid" =~ ^[0-9]+$ ]] || pid=0
    svc_fields+=" svc.$unit=$state pid.$unit=$pid"
    pid_state+="pid_${unit//[^a-zA-Z0-9_]/_}=$pid"$'\n'

    var="prev_pid_${unit//[^a-zA-Z0-9_]/_}"
    prev_pid="${!var:-}"
    if [[ "$state" == down ]]; then
      alerts+="svc_down_$unit|service $unit is down"$'\n'
    elif [[ -n "$prev_pid" && "$prev_pid" != 0 && "$pid" != 0 && "$prev_pid" != "$pid" ]]; then
      alerts+="svc_restart_$unit|service $unit restarted (pid $prev_pid -> $pid)"$'\n'
    fi
  done

  local banned
  banned=$(fail2ban_banned)

  # --- write log line --------------------------------------------------------
  line="ts=$(date -Iseconds) epoch=$now iface=${iface:-none}"
  line+=" ct=$ct ct_max=$ct_max ct_pct=$ct_pct"
  line+=" est=$est tw=$tw syn_recv=$syn_recv listen_n=$listen_n"
  line+=" drops=$d_drops ovfl=$d_ovfl synretr=$d_synretrans retr_pct=$retr_pct"
  line+=" cpu=$cpu mem=$mem disk=$disk"
  line+=" rx_bps=$rx_bps tx_bps=$tx_bps rxdrop=$d_rxdrop txdrop=$d_txdrop"
  line+=" oom=$d_oom ctfull=$d_ctfull banned=$banned"
  line+="$svc_fields"

  rotate_log
  printf '%s\n' "$line" >>"$LOG"

  # --- persist state ---------------------------------------------------------
  {
    printf 'ts=%s\n' "$now"
    printf 'drops_raw=%s\novfl_raw=%s\nsynretrans_raw=%s\n' "$drops" "$ovfl" "$synretrans"
    printf 'retrans_raw=%s\noutsegs_raw=%s\n' "$retrans" "$outsegs"
    printf 'cpu_busy=%s\ncpu_total=%s\n' "$cpu_busy" "$cpu_total"
    printf 'rx=%s\nrxdrop=%s\ntx=%s\ntxdrop=%s\n' "$rx" "$rxdrop" "$tx" "$txdrop"
    printf 'oom=%s\nctfull=%s\n' "$oom" "$ctfull"
    printf '%s' "$pid_state"
  } >"$STATE"

  # --- alerts ----------------------------------------------------------------
  if [[ "$ct_pct" -ge "$CT_ALERT_PCT" ]]; then
    alerts+="conntrack|conntrack at ${ct_pct}% ($ct/$ct_max)"$'\n'
  fi
  if [[ "$d_ctfull" -gt 0 ]]; then
    alerts+="conntrack_full|conntrack table full events: $d_ctfull (connections are being refused)"$'\n'
  fi
  if [[ "$d_drops" -gt 0 || "$d_ovfl" -gt 0 ]]; then
    alerts+="accept_queue|accept queue pressure: listen_drops=$d_drops overflows=$d_ovfl"$'\n'
  fi
  if [[ "$d_oom" -gt 0 ]]; then
    alerts+="oom|kernel OOM events: $d_oom"$'\n'
  fi
  if [[ "$disk" -ge "$DISK_ALERT_PCT" ]]; then
    alerts+="disk|disk usage at ${disk}%"$'\n'
  fi

  # Each entry is "<kind>|<message>"; the kind drives cooldown.
  local entry
  while IFS= read -r entry; do
    if [[ -n "$entry" ]]; then notify "${entry%%|*}" "${entry#*|}"; fi
  done <<<"$alerts"

  # The timer marks the unit failed on any non-zero exit, so end deliberately.
  return 0
}

# ----------------------------------------------------------------------------
# Log rotation
# ----------------------------------------------------------------------------
rotate_log() {
  [[ -f "$LOG" ]] || return 0
  # wc -c rather than stat, whose flags differ between implementations; a
  # failing size check must never silently disable rotation.
  local size
  size=$(wc -c <"$LOG" | tr -d ' ')
  numeric_or_zero size
  [[ "$size" -lt "$LOG_MAX_BYTES" ]] && return 0

  local i
  for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
    [[ -f "$LOG.$i.gz" ]] && mv -f "$LOG.$i.gz" "$LOG.$(( i + 1 )).gz"
  done
  mv -f "$LOG" "$LOG.1"
  gzip -f "$LOG.1"
  rm -f "$LOG.$(( LOG_KEEP + 1 )).gz"
  : >"$LOG"
}

# ----------------------------------------------------------------------------
# Alerting
# ----------------------------------------------------------------------------
json_escape() {
  if command -v jq >/dev/null 2>&1; then
    jq -Rn --arg s "$1" '$s' | sed 's/^"//; s/"$//'
  else
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  fi
}

# Suppresses a repeat of the same alert kind within $ALERT_COOLDOWN seconds.
# Keyed on the alert kind rather than the rendered text, so a counter that
# changes on every sample cannot slip past the cooldown.
alert_throttled() {
  local file hash last now
  hash=$(printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '_' | cut -c1-64)
  file="$ALERT_DIR/$hash"
  now=$(date +%s)
  last=$(read_or "$file" 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < ALERT_COOLDOWN )); then return 0; fi
  printf '%s' "$now" >"$file"
  return 1
}

# notify <kind> <message>: always logs, pushes at most once per cooldown.
notify() {
  local kind="$1" msg="$2" host text
  host=$(hostname -s 2>/dev/null || printf 'vps')
  text="[$NAME] $host: $msg"

  warn "$msg"
  alert_throttled "$kind" && return 0

  if [[ -n "$TELEGRAM_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    curl -fsS --max-time 10 -o /dev/null \
      "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$text" 2>/dev/null \
      || err "telegram notification failed"
  fi

  if [[ -n "$WEBHOOK_URL" ]]; then
    curl -fsS --max-time 10 -o /dev/null -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"text\":\"$(json_escape "$text")\"}" 2>/dev/null \
      || err "webhook notification failed"
  fi
}

# ----------------------------------------------------------------------------
# Viewing
# ----------------------------------------------------------------------------
require_log() {
  [[ -s "$LOG" ]] || die "no samples yet: $LOG is empty (run '$0 install' first)"
}

# Renders one logfmt line as a labelled table.
render_sample() {
  awk -v red="$c_red" -v grn="$c_grn" -v rst="$c_rst" '
    # Colors a value only when it reaches the threshold, so quiet samples
    # stay free of escape codes and remain greppable.
    function hot(val, threshold, color) {
      return (val + 0 >= threshold) ? color val rst : val
    }
    {
      delete v
      for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }

      printf "  %-14s %s\n", "time", v["ts"]
      printf "  %-14s %s\n", "iface", v["iface"]
      printf "  %-14s %s/%s (%s%%)\n", "conntrack", v["ct"], v["ct_max"],
             hot(v["ct_pct"], 80, red)
      printf "  %-14s est=%s tw=%s syn_recv=%s listening=%s\n", "tcp",
             v["est"], v["tw"], v["syn_recv"], v["listen_n"]
      printf "  %-14s drops=%s ovfl=%s syn_retrans=%s retrans=%s%%\n", "tcp queue",
             hot(v["drops"], 1, red), hot(v["ovfl"], 1, red),
             v["synretr"], v["retr_pct"]
      printf "  %-14s cpu=%s%% mem=%s%% disk=%s%%\n", "load",
             v["cpu"], v["mem"], v["disk"]
      printf "  %-14s rx=%.1f Mbps tx=%.1f Mbps rxdrop=%s txdrop=%s\n", "traffic",
             v["rx_bps"] * 8 / 1000000, v["tx_bps"] * 8 / 1000000,
             v["rxdrop"], v["txdrop"]
      printf "  %-14s oom=%s conntrack_full=%s banned_ips=%s\n", "events",
             v["oom"], v["ctfull"], v["banned"]

      svc = ""
      for (k in v) {
        if (substr(k, 1, 4) == "svc.") {
          svc = svc sprintf("%s=%s%s%s ", substr(k, 5),
                            (v[k] == "up" ? grn : red), v[k], rst)
        }
      }
      if (svc != "") printf "  %-14s %s\n", "services", svc
    }
  '
}

# Plain-language verdict over a window, for operators who should not have to
# read TCP counters. Findings are aggregated per kind rather than per sample,
# and ordered by how likely they are to explain a failed connection.
# plain_view <from> <to> <lead> <hint> <live>
# live=1 means the window runs up to now, so an unresolved fault can be
# described in the present tense; on a historical window it cannot.
plain_view() {
  local from="$1" to="$2" lead="$3" hint="$4" live="${5:-0}"
  awk -v from="$from" -v to="$to" -v lead="$lead" -v hint="$hint" -v live="$live" \
      -v interval="$INTERVAL" \
      -v grn="$c_grn" -v ylw="$c_ylw" -v red="$c_red" -v blu="$c_blu" -v rst="$c_rst" '
    function hm(ts) { return substr(ts, 12, 5) }
    function dur(sec,   h, m) {
      h = int(sec / 3600); m = int((sec % 3600) / 60)
      if (h > 0) return h "小时" (m > 0 ? m "分钟" : "")
      if (m > 0) return m "分钟"
      return sec "秒"
    }
    function add(title, why, how) {
      p++
      out = out sprintf("\n  %s●%s %s\n", red, rst, title)
      out = out sprintf("    %s\n", why)
      if (how != "") out = out sprintf("    %s细查：%s%s\n", blu, how, rst)
    }
    {
      delete v
      for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
      e = v["epoch"] + 0
      if (e < from || e > to) next

      n++
      if (!first_e) { first_e = e }
      last_e = e
      t = hm(v["ts"])

      for (k in v) {
        if (substr(k, 1, 4) == "svc.") {
          name = substr(k, 5); seen[name] = 1
          if (v[k] == "down") {
            if (!(name in down_from)) { down_from[name] = e; down_hm[name] = t }
            down_last[name] = e
          } else if (name in down_from) {
            downlen[name] += down_last[name] - down_from[name] + interval
            if (!(name in down_start_hm)) down_start_hm[name] = down_hm[name]
            down_end_hm[name] = t
            delete down_from[name]
          }
        }
        if (substr(k, 1, 4) == "pid.") {
          name = substr(k, 5)
          if (name in lastpid && lastpid[name] != 0 && v[k] != 0 && lastpid[name] != v[k]) {
            restarts[name]++
            if (!(name in restart_hm)) restart_hm[name] = t
          }
          lastpid[name] = v[k]
        }
      }

      if (v["drops"] + 0 > 0 || v["ovfl"] + 0 > 0) {
        queue_lost += v["drops"] + v["ovfl"]
        if (queue_hm == "") queue_hm = t
      }
      if (v["ctfull"] + 0 > 0) { ctfull += v["ctfull"]; if (ctfull_hm == "") ctfull_hm = t }
      if (v["oom"] + 0 > 0)    { oom += v["oom"];       if (oom_hm == "")    oom_hm = t }
      if (v["ct_pct"] + 0 > ct_peak)  { ct_peak = v["ct_pct"] + 0; ct_hm = t }
      if (v["disk"] + 0 > disk_peak)  { disk_peak = v["disk"] + 0; disk_hm = t }

      if (n == 1) { banned_first = banned_max = v["banned"] + 0; listen_min = listen_max = v["listen_n"] + 0 }
      if (v["banned"] + 0 > banned_max) banned_max = v["banned"] + 0
      if (v["listen_n"] + 0 < listen_min) listen_min = v["listen_n"] + 0
      if (v["listen_n"] + 0 > listen_max) listen_max = v["listen_n"] + 0
    }
    END {
      if (n == 0) {
        printf "\n  %s这段时间没有采样记录。%s\n", ylw, rst
        printf "  记录可能尚未启动，或该时间早于安装时间。\n\n"
        exit
      }

      # Ordered by how directly each finding explains a failed connection.
      for (name in down_from) {
        if (live == 1) {
          add(name " 服务当前处于停止状态，已持续 " dur(last_e - down_from[name] + interval),
              "现在所有到该服务的连接都会失败，需要立即处理。",
              "systemctl status " name)
        } else {
          add(name " 服务在 " down_hm[name] " 停止，直到这段记录结束仍未恢复",
              "这段时间内所有到该服务的连接都会失败。",
              "journalctl -u " name " --since \"" down_hm[name] "\"")
        }
      }
      for (name in downlen) {
        add(name " 服务曾停止 " dur(downlen[name]) \
            "（" down_start_hm[name] " - " down_end_hm[name] "）",
            "这段时间内所有到该服务的连接都会失败。",
            "journalctl -u " name " --since \"" down_start_hm[name] "\"")
      }
      if (ctfull > 0) {
        add("连接跟踪表被占满 " ctfull " 次（最早 " ctfull_hm "）",
            "内核直接拒绝了新连接。这是偶发连不上最常见的服务端原因。",
            "sysctl net.netfilter.nf_conntrack_max")
      }
      if (queue_lost > 0) {
        add("连接队列溢出，共丢弃 " queue_lost " 个连接（最早 " queue_hm "）",
            "短时间涌入的连接超过了服务处理能力，一部分被直接拒绝。", "")
      }
      if (oom > 0) {
        add("内存耗尽，内核杀掉进程 " oom " 次（最早 " oom_hm "）",
            "被杀掉的可能就是代理服务，期间会完全无法连接。",
            "journalctl -k | grep -i \"out of memory\"")
      }
      for (name in restarts) {
        add(name " 服务重启过 " restarts[name] " 次（最早 " restart_hm[name] "）",
            "重启瞬间已建立的连接会断开，用户需要重新连接。",
            "journalctl -u " name " --since \"" restart_hm[name] "\"")
      }
      # Only worth reporting as a warning when the table never actually filled;
      # otherwise the "table full" finding above already says it, and harder.
      if (ct_peak >= 80 && ctfull == 0) {
        add("连接跟踪表最高占用 " ct_peak "%（" ct_hm "）",
            "还没到拒绝连接的程度，但已接近上限，继续增长就会开始丢连接。", "")
      }
      if (banned_max > banned_first) {
        add("fail2ban 新封禁了 " (banned_max - banned_first) " 个 IP",
            "如果用户的 IP 被误封，他们会完全连不上，而其他人一切正常。",
            "fail2ban-client status")
      }
      if (disk_peak >= 90) {
        add("磁盘占用最高 " disk_peak "%（" disk_hm "）",
            "磁盘写满会导致服务写日志失败甚至崩溃。", "")
      }
      if (listen_max != listen_min) {
        add("监听端口数量变化过（" listen_min " - " listen_max "）",
            "期间有服务启动或停止过，可能与连接失败有关。", "")
      }

      if (p == 0) {
        printf "\n%s[+] 服务端正常%s\n\n", grn, rst
        printf "  %s：共 %d 次采样，实际覆盖 %s。\n", lead, n, dur(last_e - first_e + interval)
        svc = ""
        for (name in seen) svc = svc (svc == "" ? "" : "、") name
        if (svc != "") printf "  %s 全程在线。\n", svc
        printf "  这台服务器没有拒绝或丢弃过任何连接。\n\n"
        printf "  如果这段时间有人连不上，问题出在他们自己的网络或到本机的线路，\n"
        printf "  不在这台服务器。\n"
      } else {
        printf "\n%s[!] 发现 %d 个问题%s\n", ylw, p, rst
        printf "  %s：共 %d 次采样，实际覆盖 %s。\n", lead, n, dur(last_e - first_e + interval)
        printf "%s", out
      }
      if (hint != "") printf "\n  %s完整指标：%s%s\n", blu, hint, rst
      printf "\n"
    }
  ' "$LOG"
}

cmd_status() {
  local detail=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detail) detail=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_log

  local last epoch age now stale
  last=$(tail -n 1 "$LOG")
  now=$(date +%s)
  epoch=$(printf '%s\n' "$last" | grep -o 'epoch=[0-9]*' | head -n 1 | cut -d= -f2)
  [[ "$epoch" =~ ^[0-9]+$ ]] || die "malformed last log line in $LOG"
  age=$(( now - epoch ))
  stale=$(( INTERVAL * 3 ))

  if [[ "$detail" -eq 1 ]]; then
    info "latest sample (${age}s ago)"
    printf '%s\n' "$last" | render_sample
    if (( age > stale )); then
      warn "sample is stale (> ${stale}s) - check: systemctl status $NAME.timer"
    fi
    return 0
  fi

  if (( age > stale )); then
    printf '\n%s[!] 采样已中断%s\n\n' "$c_red" "$c_rst"
    printf '  最后一次采样在 %s 分钟前，记录并不完整。\n' "$(( age / 60 ))"
    printf '  %s细查：systemctl status %s.timer%s\n\n' "$c_blu" "$NAME" "$c_rst"
    return 0
  fi

  plain_view "$(( now - 86400 ))" "$now" "最近 24 小时" "$NAME status --detail" 1
}

cmd_tail() {
  require_log
  tail -n "${1:-20}" -f "$LOG"
}

# Answers "what did this box look like when the user could not connect?"
cmd_at() {
  local detail=0 args=() when window="10" target from to
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detail) detail=1; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  when="${args[0]:-}"
  [[ -n "$when" ]] || die "usage: $0 at \"<time>\" [window_minutes] [--detail]"
  [[ ${#args[@]} -lt 2 ]] || window="${args[1]}"
  [[ "$window" =~ ^[0-9]+$ ]] || die "window must be a number of minutes: $window"
  require_log

  target=$(date -d "$when" +%s 2>/dev/null) \
    || die "cannot parse time: $when (try \"14:30\" or \"2026-08-13 14:30\")"
  from=$(( target - window * 60 ))
  to=$(( target + window * 60 ))

  if [[ "$detail" -eq 0 ]]; then
    local live=0
    [[ "$to" -ge "$(( $(date +%s) - INTERVAL * 2 ))" ]] && live=1
    plain_view "$from" "$to" \
      "$(date -d "@$from" +%H:%M) - $(date -d "@$to" +%H:%M)" \
      "$NAME at \"$when\" $window --detail" "$live"
    return 0
  fi

  info "samples within +/-${window}min of $(date -d "@$target" -Iseconds)"
  local matched=0 line
  while IFS= read -r line; do
    matched=1
    printf '\n'
    printf '%s\n' "$line" | render_sample
  done < <(awk -v from="$from" -v to="$to" '
    { for (i = 1; i <= NF; i++) if (substr($i, 1, 6) == "epoch=") {
        e = substr($i, 7); if (e >= from && e <= to) print; next } }' "$LOG")

  if [[ "$matched" -eq 0 ]]; then
    warn "no samples in that window - the recorder may not have been running yet"
  fi
}

# Parses a duration such as 90m, 24h, 7d into seconds.
parse_since() {
  local v="$1" n="${1%[smhd]}" unit="${1: -1}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "invalid duration: $v (use 30m, 24h, 7d)"
  case "$unit" in
    s) printf '%s' "$n" ;;
    m) printf '%s' $(( n * 60 )) ;;
    h) printf '%s' $(( n * 3600 )) ;;
    d) printf '%s' $(( n * 86400 )) ;;
    *) die "invalid duration: $v (use 30m, 24h, 7d)" ;;
  esac
}

# Summarizes only the anomalies in a window - the point is to answer
# "was anything wrong on the server side at that time?" in one screen.
cmd_report() {
  local since=24h from secs detail=0 now
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 ;;
      --detail) detail=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_log
  # parse_since dies in a subshell, so its failure has to be checked here.
  secs=$(parse_since "$since") || exit 1
  now=$(date +%s)
  from=$(( now - secs ))

  if [[ "$detail" -eq 0 ]]; then
    plain_view "$from" "$now" "最近 $since" "$NAME report --since $since --detail" 1
    return 0
  fi

  info "anomaly report over the last $since"
  awk -v from="$from" -v red="$c_red" -v ylw="$c_ylw" -v rst="$c_rst" '
    {
      delete v
      for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
      if (v["epoch"] + 0 < from) next

      n++
      if (first == "") first = v["ts"]
      last = v["ts"]

      if (v["ct_pct"] + 0 > ct_max_pct) { ct_max_pct = v["ct_pct"] + 0; ct_at = v["ts"] }
      if (v["retr_pct"] + 0 > retr_max)  { retr_max = v["retr_pct"] + 0; retr_at = v["ts"] }
      drops += v["drops"]; ovfl += v["ovfl"]
      oom   += v["oom"];   ctfull += v["ctfull"]
      rxdrop += v["rxdrop"]; txdrop += v["txdrop"]

      if (v["drops"] + 0 > 0 || v["ovfl"] + 0 > 0)
        ev[++e] = sprintf("%s  %saccept queue%s  drops=%s ovfl=%s",
                          v["ts"], red, rst, v["drops"], v["ovfl"])
      if (v["ctfull"] + 0 > 0)
        ev[++e] = sprintf("%s  %sconntrack table full%s  x%s",
                          v["ts"], red, rst, v["ctfull"])
      if (v["oom"] + 0 > 0)
        ev[++e] = sprintf("%s  %skernel OOM%s  x%s", v["ts"], red, rst, v["oom"])
      if (v["ct_pct"] + 0 >= 80)
        ev[++e] = sprintf("%s  %sconntrack %s%%%s  %s/%s",
                          v["ts"], ylw, v["ct_pct"], rst, v["ct"], v["ct_max"])

      for (k in v) {
        if (substr(k, 1, 4) == "svc." && v[k] == "down")
          ev[++e] = sprintf("%s  %s%s down%s", v["ts"], red, substr(k, 5), rst)
        if (substr(k, 1, 4) == "pid.") {
          name = substr(k, 5)
          if (name in lastpid && lastpid[name] != 0 && v[k] != 0 && lastpid[name] != v[k])
            ev[++e] = sprintf("%s  %s%s restarted%s  pid %s -> %s",
                              v["ts"], ylw, name, rst, lastpid[name], v[k])
          lastpid[name] = v[k]
        }
      }
      if ("listen_n" in v) {
        if (lastlisten != "" && lastlisten != v["listen_n"])
          ev[++e] = sprintf("%s  %slistening sockets%s  %s -> %s",
                            v["ts"], ylw, rst, lastlisten, v["listen_n"])
        lastlisten = v["listen_n"]
      }
      # n counts in-window samples; the first one only seeds the baseline.
      if (n > 1 && v["banned"] + 0 > lastbanned)
        ev[++e] = sprintf("%s  %sfail2ban%s  banned %s -> %s",
                          v["ts"], ylw, rst, lastbanned, v["banned"])
      lastbanned = v["banned"] + 0
    }
    END {
      if (n == 0) { print "  no samples in this window"; exit }
      printf "  samples: %d   from %s   to %s\n\n", n, first, last
      printf "  peak conntrack : %d%% at %s\n", ct_max_pct, ct_at
      printf "  peak retransmit: %d%% at %s\n", retr_max, retr_at
      printf "  totals         : listen_drops=%d overflows=%d oom=%d conntrack_full=%d\n",
             drops, ovfl, oom, ctfull
      printf "  nic drops      : rx=%d tx=%d\n", rxdrop, txdrop
      if (e == 0) {
        printf "\n  no server-side anomalies recorded - look at the link or the client\n"
      } else {
        printf "\n  events (%d):\n", e
        start = (e > 40 ? e - 39 : 1)
        if (start > 1) printf "  ... %d earlier events omitted\n", start - 1
        for (i = start; i <= e; i++) print "  " ev[i]
      }
    }
  ' "$LOG"
}

# ----------------------------------------------------------------------------
# Install / uninstall
# ----------------------------------------------------------------------------
write_default_conf() {
  [[ -f "$CONF" ]] && return 0
  cat >"$CONF" <<EOF
# $NAME configuration. Values here override the script defaults.

# Seconds between samples (applied on 'install').
INTERVAL=$INTERVAL

# Network interface to record. Empty = interface of the default route.
IFACE=""

# Space separated systemd units to watch, without the .service suffix.
# Empty = autodetect from: $AUTODETECT_UNITS
MONITOR_UNITS=""

# Alert thresholds.
CT_ALERT_PCT=$CT_ALERT_PCT
DISK_ALERT_PCT=$DISK_ALERT_PCT
ALERT_COOLDOWN=$ALERT_COOLDOWN

# Log rotation.
LOG_MAX_BYTES=$LOG_MAX_BYTES
LOG_KEEP=$LOG_KEEP

# Notifications. Leave empty to disable.
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
WEBHOOK_URL=""
EOF
  chmod 600 "$CONF"
  ok "wrote $CONF (mode 600 - it holds notification tokens)"
}

cmd_install() {
  require_root install
  command -v systemctl >/dev/null 2>&1 || die "systemd not found"
  command -v ss >/dev/null 2>&1 || die "'ss' not found (install iproute2)"

  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  install -m 700 "$src" "$BIN"
  mkdir -p "$STATE_DIR" "$ALERT_DIR"
  write_default_conf

  cat >"$SERVICE" <<EOF
[Unit]
Description=OneVPS network watch sample
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN collect
Nice=10
IOSchedulingClass=idle
EOF

  cat >"$TIMER" <<EOF
[Unit]
Description=OneVPS network watch timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=1s
Unit=$NAME.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$NAME.timer" >/dev/null
  "$BIN" collect

  ok "installed - sampling every ${INTERVAL}s into $LOG"
  info "view:   $BIN status | $BIN report --since 24h | $BIN at \"14:30\""
  info "config: $CONF (set TELEGRAM_TOKEN / WEBHOOK_URL for alerts)"
}

cmd_uninstall() {
  require_root uninstall
  local purge=0 ans=""
  if [[ "${1:-}" == "--purge" ]]; then purge=1; fi

  info "this will remove:"
  info "  $TIMER"
  info "  $SERVICE"
  info "  $BIN"
  if [[ "$purge" -eq 1 ]]; then
    info "  $CONF"
    info "  $LOG (and rotated $LOG.*.gz)"
    info "  $STATE_DIR"
  else
    info "keeping $LOG, $CONF and $STATE_DIR (pass --purge to remove them too)"
  fi
  read -rp "Proceed? [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]$ ]] || { info "aborted"; return 0; }

  systemctl disable --now "$NAME.timer" >/dev/null 2>&1 || true
  rm -f "$TIMER" "$SERVICE" "$BIN"
  systemctl daemon-reload

  if [[ "$purge" -eq 1 ]]; then
    rm -f "$CONF" "$LOG" "$LOG".*.gz
    rm -rf "$STATE_DIR"
    ok "removed timer, script, logs and config"
  else
    ok "removed timer and script; logs kept at $LOG"
  fi
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
$NAME - record what the VPS looked like when a user could not connect

Usage: $0 <command> [args]

  install                 install and start the systemd timer
  uninstall [--purge]     remove the timer (--purge also drops logs and config)
  collect                 take one sample (invoked by the timer)

  status                  verdict for the last 24 hours
  at "<time>" [minutes]   verdict around a time, default +/-10 minutes
  report [--since 24h]    verdict over a window
  tail [lines]            follow the raw log live

status, at and report explain in plain language whether this server was at
fault. Add --detail to any of them for the underlying counters instead.

Log:    $LOG
Config: $CONF

Typical use: a user reports trouble at 14:30, then
  $0 at "14:30"        - was this server at fault at that moment?
  $0 report --since 6h - anything wrong in the hours around it?
No findings means the fault was on the link or the client side.
EOF
}

main() {
  load_conf
  local cmd="${1:-status}"
  shift || true
  case "$cmd" in
    collect)         collect ;;
    status)          cmd_status "$@" ;;
    tail)            cmd_tail "$@" ;;
    at)              cmd_at "$@" ;;
    report)          cmd_report "$@" ;;
    install)         cmd_install ;;
    uninstall)       cmd_uninstall "$@" ;;
    help|-h|--help)  usage ;;
    *)               err "unknown command: $cmd"; usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
