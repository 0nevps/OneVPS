#!/usr/bin/env bash
# OneVPS release installer. Download to a file; never pipe into bash.
set -euo pipefail
umask 077

# BEGIN RELEASE INSTALLATION (kept identical in onevps.sh by tests)
release_error() { printf 'OneVPS: %s\n' "$*" >&2; }
release_tag_supported() {
  [[ "$1" =~ ^v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]] || return 1
  local major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
  # Only the current 0.x sing-box family is compatible; never accept old Xray.
  (( major == 0 && minor >= 2 ))
}
release_fetch() {
  # -q must be first: ignore curlrc (credentials, insecure TLS, output overrides).
  curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 "$1" -o "$2"
}
release_target_ok() {
  local target="$1"
  [[ ! -L "$target" ]] || return 1
  if [[ -e "$target" ]]; then
    [[ -f "$target" ]] && grep -qx '# Managed by OneVPS script installer v1' "$target"
  fi
}
release_install() (
  local requested="${1:-}" target=/usr/local/bin/onevps work stage='' tag endpoint digest actual count
  for dependency in curl jq openssl; do
    command -v "$dependency" >/dev/null || { release_error "install $dependency first"; return 1; }
  done
  [[ -d /usr/local/bin && ! -L /usr/local/bin ]] || { release_error 'unsafe or missing /usr/local/bin'; return 1; }
  release_target_ok "$target" || { release_error "refusing unmanaged target: $target"; return 1; }
  work=$(mktemp -d /tmp/onevps-release.XXXXXXXX) || return 1
  trap 'rm -rf "$work"; if [[ -n "$stage" ]]; then rm -f "$stage"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  endpoint=latest
  if [[ -n "$requested" ]]; then
    release_tag_supported "$requested" || { release_error 'unsupported version (requires stable v0.2.0+ in the 0.x family)'; return 1; }
    endpoint="tags/$requested"
  fi
  release_fetch "https://api.github.com/repos/0nevps/OneVPS/releases/$endpoint" "$work/release.json" || return 1
  tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$work/release.json") || return 1
  release_tag_supported "$tag" && [[ -z "$requested" || "$tag" == "$requested" ]] || {
    release_error 'no compatible stable release available; never falling back to main or Xray'; return 1;
  }
  local base="https://github.com/0nevps/OneVPS/releases/download/$tag"
  release_fetch "$base/onevps.sh" "$work/onevps.sh" &&
    release_fetch "$base/SHA256SUMS" "$work/SHA256SUMS" || return 1
  # Parse only the exact target entry, never let a manifest choose filesystem paths.
  count=$(awk '$2 == "onevps.sh" || $2 == "*onevps.sh" {n++} END {print n+0}' "$work/SHA256SUMS")
  [[ "$count" == 1 ]] || { release_error 'missing or duplicate onevps.sh checksum'; return 1; }
  digest=$(awk '$2 == "onevps.sh" || $2 == "*onevps.sh" {if (NF == 2) print $1}' "$work/SHA256SUMS")
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { release_error 'invalid checksum'; return 1; }
  actual=$(openssl dgst -sha256 "$work/onevps.sh") || return 1
  [[ "${actual##* }" == "$digest" ]] || { release_error 'SHA-256 mismatch'; return 1; }
  bash -n "$work/onevps.sh" &&
    grep -qx '# Managed by OneVPS script installer v1' "$work/onevps.sh" &&
    grep -Fqx "ONEVPS_VERSION=$tag" "$work/onevps.sh" || { release_error 'incompatible script'; return 1; }
  stage=$(mktemp /usr/local/bin/.onevps.XXXXXXXX) || return 1
  install -m 755 "$work/onevps.sh" "$stage" || return 1
  release_target_ok "$target" || return 1
  mv -f "$stage" "$target" || return 1
  stage=''
  printf 'OneVPS %s installed at %s (core unchanged).\n' "$tag" "$target"
)
# END RELEASE INSTALLATION

installer_main() {
  (( $# <= 1 )) || { release_error 'usage: bash install.sh [v0.2.0]'; return 1; }
  [[ -t 0 && -t 1 ]] || { release_error 'interactive terminal required; download to a file, then run it'; return 1; }
  [[ $(uname -s) == Linux ]] || { release_error 'Linux required'; return 1; }
  case "$(uname -m)" in x86_64|amd64|aarch64|arm64|armv7l|armv7|armhf) ;; *) release_error 'unsupported architecture'; return 1 ;; esac
  command -v systemctl >/dev/null || { release_error 'systemd required'; return 1; }
  if (( EUID != 0 )); then
    release_error 'run this downloaded file with sudo bash install.sh [version]'; return 1
  fi
  release_install "${1:-}" || return 1
  /usr/local/bin/onevps
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then installer_main "$@"; fi
