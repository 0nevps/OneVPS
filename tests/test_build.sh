#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/scripts" "$work/src/cores"
cp "$root/scripts/build.sh" "$work/scripts/build.sh"
cp "$root/src/entry.sh" "$work/src/entry.sh"
cp "$root/src/cores/xray.sh" "$work/src/cores/xray.sh"
cp "$root/src/cores/sing-box.sh" "$work/src/cores/sing-box.sh"

bash "$work/scripts/build.sh" --write
bash "$work/scripts/build.sh" --check
cmp "$root/onevps.sh" "$work/onevps.sh"

printf '\n# stale\n' >> "$work/onevps.sh"
if bash "$work/scripts/build.sh" --check >/dev/null 2>&1; then
  echo 'stale release script passed build check' >&2
  exit 1
fi

sed 's/^# @include cores\/xray.sh$/# missing core/' "$work/src/entry.sh" > "$work/entry.new"
mv "$work/entry.new" "$work/src/entry.sh"
if bash "$work/scripts/build.sh" --write >/dev/null 2>&1; then
  echo 'missing core marker passed build' >&2
  exit 1
fi

echo 'ok - single-file build is reproducible and rejects stale or missing inputs'
