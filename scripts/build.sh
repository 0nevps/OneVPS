#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
entry="$root/src/entry.sh"
core="$root/src/cores/xray.sh"
target="$root/onevps.sh"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

[[ $(awk '$0 == "# @include cores/xray.sh" { count++ } END { print count+0 }' "$entry") == 1 ]] || {
  echo 'Expected exactly one Xray include in src/entry.sh' >&2
  exit 1
}
awk -v core="$core" '
  $0 == "# @include cores/xray.sh" {
    while ((getline line < core) > 0) print line
    close(core)
    next
  }
  { print }
' "$entry" > "$tmp"
bash -n "$tmp"

case "${1:---check}" in
  --check) cmp -s "$tmp" "$target" || {
    echo 'onevps.sh is stale; run bash scripts/build.sh --write' >&2
    exit 1
  } ;;
  --write) cat "$tmp" > "$target" ;;
  *) echo 'Usage: bash scripts/build.sh [--check|--write]' >&2; exit 2 ;;
esac
