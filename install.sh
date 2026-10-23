#!/usr/bin/env bash
# OneVPS repository installer. Download to a file; never pipe into bash.
set -euo pipefail
umask 077

# BEGIN SCRIPT INSTALLATION (kept identical in onevps.sh by tests)
script_error() { printf 'OneVPS: %s\n' "$*" >&2; }
script_fetch() {
  # -q must be first: ignore curlrc (credentials, insecure TLS, output overrides).
  curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 "$1" -o "$2"
}
script_target_ok() {
  local target="$1"
  [[ ! -L "$target" ]] || return 1
  if [[ -e "$target" ]]; then
    [[ -f "$target" ]] && grep -qx '# Managed by OneVPS script installer v1' "$target"
  fi
}
# Reject arguments defensively even though production callers pass none.
# shellcheck disable=SC2120
script_install() (
  (( $# == 0 )) || { script_error 'script installation takes no arguments'; return 1; }
  local target=/usr/local/bin/onevps work stage='' version
  command -v curl >/dev/null || { script_error 'install curl first'; return 1; }
  [[ -d /usr/local/bin && ! -L /usr/local/bin ]] || { script_error 'unsafe or missing /usr/local/bin'; return 1; }
  script_target_ok "$target" || { script_error "refusing unmanaged target: $target"; return 1; }
  work=$(mktemp -d /tmp/onevps-script.XXXXXXXX) || return 1
  trap 'rm -rf "$work"; if [[ -n "$stage" ]]; then rm -f "$stage"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  script_fetch 'https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh' "$work/onevps.sh" || return 1
  bash -n "$work/onevps.sh" &&
    grep -qx '# Managed by OneVPS script installer v1' "$work/onevps.sh" || { script_error 'incompatible script'; return 1; }
  # Read metadata without executing downloaded code; do not pin main to an old version.
  version=$(grep '^ONEVPS_VERSION=' "$work/onevps.sh") || return 1
  [[ "$version" =~ ^ONEVPS_VERSION=v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]] || {
    script_error 'invalid script version'; return 1;
  }
  version=${version#ONEVPS_VERSION=}
  stage=$(mktemp /usr/local/bin/.onevps.XXXXXXXX) || return 1
  install -m 755 "$work/onevps.sh" "$stage" || return 1
  script_target_ok "$target" || return 1
  mv -f "$stage" "$target" || return 1
  stage=''
  printf 'OneVPS %s from main installed at %s (core unchanged).\n' "$version" "$target"
)
# END SCRIPT INSTALLATION

installer_main() {
  (( $# == 0 )) || { script_error 'usage: bash install.sh'; return 1; }
  [[ -t 0 && -t 1 ]] || { script_error 'interactive terminal required; download to a file, then run it'; return 1; }
  [[ $(uname -s) == Linux ]] || { script_error 'Linux required'; return 1; }
  case "$(uname -m)" in x86_64|amd64|aarch64|arm64|armv7l|armv7|armhf) ;; *) script_error 'unsupported architecture'; return 1 ;; esac
  command -v systemctl >/dev/null || { script_error 'systemd required'; return 1; }
  if (( EUID != 0 )); then
    script_error 'run this downloaded file with sudo bash install.sh'; return 1
  fi
  script_install || return 1
  /usr/local/bin/onevps
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then installer_main "$@"; fi
