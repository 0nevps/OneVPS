#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
entry="$root/src/entry.sh"
target="$root/onevps.sh"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for name in xray sing-box; do
  [[ $(awk -v marker="# @include cores/$name.sh" '$0 == marker { count++ } END { print count+0 }' "$entry") == 1 ]] || {
    echo "Expected exactly one $name include in src/entry.sh" >&2
    exit 1
  }
done
awk -v cores="$root/src/cores" '
  /^# @include cores\// {
    name = $3
    sub(/^cores\//, "", name)
    if (name != "xray.sh" && name != "sing-box.sh") exit 1
    while ((getline line < (cores "/" name)) > 0) print line
    close(cores "/" name)
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
