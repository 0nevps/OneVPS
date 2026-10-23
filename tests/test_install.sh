#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Rewrite fixed production paths only in a disposable test copy, not via a
# production environment override. Never invoke host services or install paths.
python3 -I - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
a = (root / 'install.sh').read_text()
b = (root / 'onevps.sh').read_text()
def block(s):
    return s.split('# BEGIN RELEASE INSTALLATION')[1].split('# END RELEASE INSTALLATION')[0]
assert block(a) == block(b), 'installer/update implementations drifted'
(work / 'install.sh').write_text(a.replace('/usr/local/bin', str(work / 'bin')))
(work / 'onevps.sh').write_text(b)
(work / 'bin').mkdir()
PY
# shellcheck disable=SC1091
source "$WORK/install.sh"
cp "$ROOT/onevps.sh" "$WORK/asset"
export WORK
release_fetch() {
  case "$1" in
    */releases/latest|*/releases/tags/*)
      printf '{"tag_name":"%s","draft":false,"prerelease":false}\n' "${TAG:-v0.2.0}" > "$2" ;;
    */onevps.sh) [[ "${MODE:-}" != download ]] || return 1; cp "$WORK/asset" "$2" ;;
    */SHA256SUMS)
      local sum
      sum=$(openssl dgst -sha256 "$WORK/asset"); sum=${sum##* }
      [[ "${MODE:-}" != checksum ]] || sum=$(printf '%064d' 0)
      printf '%s  onevps.sh\n' "$sum" > "$2"
      # Unrelated entries must not be checked or opened.
      printf '%s  /must/not/read\n' "$sum" >> "$2"
      [[ "${MODE:-}" != duplicate ]] || printf '%s  onevps.sh\n' "$sum" >> "$2" ;;
    *) return 1 ;;
  esac
}
pass() { printf 'ok - %s\n' "$1"; }
release_install
cmp "$WORK/asset" "$WORK/bin/onevps"
pass 'first atomic script installation'
release_install v0.2.0
cmp "$WORK/asset" "$WORK/bin/onevps"
pass 'repeat installation'
for mode in download checksum duplicate; do
  MODE=$mode
  if release_install; then printf 'unexpected success: %s\n' "$mode"; exit 1; fi
  cmp "$WORK/asset" "$WORK/bin/onevps"
  pass "$mode failure preserves installed script"
done
MODE=''
cp "$WORK/asset" "$WORK/good"
printf '\nif\n' >> "$WORK/asset"
if release_install; then exit 1; fi
cmp "$WORK/good" "$WORK/bin/onevps"
cp "$WORK/good" "$WORK/asset"
pass 'syntax failure preserves installed script'
mv() { return 1; }
if release_install; then exit 1; fi
cmp "$WORK/asset" "$WORK/bin/onevps"
unset -f mv
pass 'atomic rename failure preserves installed script'
TAG=v0.1.2
if release_install; then exit 1; fi
TAG=v0.2.0
for version in v0.1.2 ../main v0.2.0-rc1 v1.0.0; do
  if release_install "$version"; then exit 1; fi
done
pass 'legacy, traversal, prerelease and incompatible family rejected'
printf 'unmanaged\n' > "$WORK/bin/onevps"
if release_install; then exit 1; fi
grep -qx unmanaged "$WORK/bin/onevps"
rm "$WORK/bin/onevps"
ln -s "$WORK/asset" "$WORK/bin/onevps"
if release_install; then exit 1; fi
pass 'unmanaged and symlink conflicts preserved'
if installer_main </dev/null; then exit 1; fi
pass 'installer rejects absent TTY'
# Verify orchestration without invoking any real core, package or service operation.
# shellcheck source=../onevps.sh
source "$ROOT/onevps.sh"
check_singbox_conflicts() { [[ "${CONFLICT:-}" != yes ]]; }
singbox_owned() { [[ "${OWNED:-}" == yes ]]; }
confirm() { return 0; }
install_singbox() { printf 'core\n' >> "$WORK/calls"; }
ask() { printf '%s\n' "${PROTOCOL:-0}"; }
add_reality_node() { printf 'reality\n' >> "$WORK/calls"; }
add_hysteria2_node() { printf 'hy2\n' >> "$WORK/calls"; }
add_snell_node() { printf 'snell\n' >> "$WORK/calls"; }
for protocol in 1 2 3; do PROTOCOL=$protocol; first_run; done
[[ $(wc -l < "$WORK/calls" | tr -d ' ') == 6 ]]
grep -qx reality "$WORK/calls"; grep -qx hy2 "$WORK/calls"; grep -qx snell "$WORK/calls"
OWNED=yes
first_run
[[ $(wc -l < "$WORK/calls" | tr -d ' ') == 6 ]]
CONFLICT=yes
if first_run; then exit 1; fi
pass 'first-run protocol dispatch, repeat preservation and conflict abort'
if (main </dev/null); then exit 1; fi
pass 'manager rejects absent TTY'
# main's update branch must only dispatch the shared release installer. A real
# root branch is tested with a test-copy EUID expression, never privilege escalation.
python3 -I - "$WORK/onevps.sh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('[[ $EUID -eq 0 ]]', '[[ 0 -eq 0 ]]'))
PY
(
  # shellcheck disable=SC1091
  source "$WORK/onevps.sh"
  uname() { printf 'Linux\n'; }
  release_install() { [[ "$1" == v0.2.0 ]] && return 17; }
  install_singbox() { exit 91; }
  main_menu() { exit 92; }
  if main update v0.2.0; then exit 1; else [[ $? == 17 ]]; fi
)
pass 'update propagates failure without core installation or menu'

