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
    return s.split('# BEGIN SCRIPT INSTALLATION')[1].split('# END SCRIPT INSTALLATION')[0]
assert block(a) == block(b), 'installer/update implementations drifted'
(work / 'install.sh').write_text(a.replace('/usr/local/bin', str(work / 'bin')))
(work / 'onevps.sh').write_text(b)
(work / 'bin').mkdir()
PY
# shellcheck disable=SC1091
source "$WORK/install.sh"
cp "$ROOT/onevps.sh" "$WORK/asset"
export WORK
script_fetch() {
  case "$1" in
    https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh)
      printf '%s\n' "$1" >> "$WORK/downloads"
      [[ "${MODE:-}" != download ]] || return 1
      cp "$WORK/asset" "$2" ;;
    *) return 1 ;;
  esac
}
pass() { printf 'ok - %s\n' "$1"; }
script_install
cmp "$WORK/asset" "$WORK/bin/onevps"
pass 'first atomic script installation'
script_install
cmp "$WORK/asset" "$WORK/bin/onevps"
[[ -x "$WORK/bin/onevps" ]]
[[ $(wc -l < "$WORK/downloads" | tr -d ' ') == 2 ]]
pass 'repeat installation uses only main raw script, no Release API or manifest'
MODE=download
if script_install; then printf 'unexpected download success\n'; exit 1; fi
cmp "$WORK/asset" "$WORK/bin/onevps"
pass 'download failure preserves installed script'
MODE=''
cp "$WORK/asset" "$WORK/good"
printf '\nif\n' >> "$WORK/asset"
if script_install; then exit 1; fi
cmp "$WORK/good" "$WORK/bin/onevps"
cp "$WORK/good" "$WORK/asset"
pass 'syntax failure preserves installed script'
mv() { return 1; }
if script_install; then exit 1; fi
cmp "$WORK/asset" "$WORK/bin/onevps"
unset -f mv
pass 'atomic rename failure preserves installed script'
for mode in marker version duplicate missing; do
  python3 -I - "$WORK/good" "$WORK/asset" "$mode" <<'PY'
from pathlib import Path
import sys
src, dest, mode = sys.argv[1:]
s = Path(src).read_text()
if mode == 'marker':
    s = s.replace('# Managed by OneVPS script installer v1', '# unmanaged')
elif mode == 'version':
    s = s.replace('ONEVPS_VERSION=v0.2.0', 'ONEVPS_VERSION=invalid')
elif mode == 'duplicate':
    s += '\nONEVPS_VERSION=v1.0.0\n'
else:
    s = s.replace('ONEVPS_VERSION=v0.2.0', '# no version')
Path(dest).write_text(s)
PY
  if script_install; then exit 1; fi
  cmp "$WORK/good" "$WORK/bin/onevps"
  pass "$mode validation failure preserves installed script"
done
cp "$WORK/good" "$WORK/asset"
for version in v0.2.0 ../main ''; do
  if script_install "$version"; then exit 1; fi
  if installer_main "$version"; then exit 1; fi
done
pass 'installer and shared installation reject all arguments'
python3 -I - "$WORK/asset" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('ONEVPS_VERSION=v0.2.0', 'ONEVPS_VERSION=v1.3.0'))
PY
script_install
cmp "$WORK/asset" "$WORK/bin/onevps"
pass 'future valid script version is not pinned to old version'
printf 'unmanaged\n' > "$WORK/bin/onevps"
if script_install; then exit 1; fi
grep -qx unmanaged "$WORK/bin/onevps"
rm "$WORK/bin/onevps"
ln -s "$WORK/asset" "$WORK/bin/onevps"
if script_install; then exit 1; fi
pass 'unmanaged and symlink conflicts preserved'
if installer_main </dev/null; then exit 1; fi
pass 'installer rejects absent TTY'
# Exercise installer launch in a disposable copy with only platform/TTY/root gates mocked.
python3 -I - "$WORK/install.sh" "$WORK/installer-test.sh" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
s = s.replace('[[ -t 0 && -t 1 ]]', '[[ 1 == 1 ]]').replace('(( EUID != 0 ))', '(( 0 != 0 ))')
Path(sys.argv[2]).write_text(s)
PY
(
  # shellcheck disable=SC1091
  source "$WORK/installer-test.sh"
  uname() { if [[ "$1" == -s ]]; then printf 'Linux\n'; else printf 'x86_64\n'; fi; }
  systemctl() { exit 93; }
  script_install() { return 17; }
  if installer_main; then exit 1; else [[ $? == 17 ]]; fi
  rm "$WORK/bin/onevps"
  printf '#!/usr/bin/env bash\nprintf "started\\n" > "$WORK/started"\n' > "$WORK/bin/onevps"
  chmod +x "$WORK/bin/onevps"
  script_install() { printf 'installed\n' > "$WORK/installed"; }
  installer_main
  grep -qx installed "$WORK/installed"
  grep -qx started "$WORK/started"
)
pass 'installer launches manager only after successful installation'
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
# main's update branch must only dispatch the shared script installer. A real
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
  script_install() { [[ $# == 0 ]] && return 17; }
  install_singbox() { exit 91; }
  main_menu() { exit 92; }
  if main update; then exit 1; else [[ $? == 17 ]]; fi
  for argument in v0.2.0 ''; do
    if (main update "$argument"); then exit 1; else [[ $? == 1 ]]; fi
  done
)
pass 'update propagates failure without core installation or menu'

