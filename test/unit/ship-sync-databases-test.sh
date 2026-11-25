#!/bin/bash
#
# The root image is pacstrapped from the offline mirror, so on its own it holds
# no index for any repository the installed system uses, and nothing installs
# until the first -Syu. ship-sync-databases.sh copies the build's online
# indexes in: every repository the runtime's pacman.conf templates and hardware
# scripts name, none of the build-only ones, offline.db left alone, and the
# build stopped rather than shipping an image without [core], [extra] or
# [omarchy].

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOOL="$ROOT/builder/ship-sync-databases.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

fixture() {
  rm -rf "$WORK/root" "$WORK/sync"
  local runtime="$WORK/root/usr/share/omarchy"
  mkdir -p "$runtime/default/pacman/aarch64" "$runtime/install/hardware" \
    "$WORK/root/var/lib/pacman/sync" "$WORK/sync"
  printf '[options]\nArchitecture = auto\n\n[omarchy]\n[core]\n[extra]\n[multilib]\n' \
    >"$runtime/default/pacman/pacman-stable.conf"
  printf '[options]\n[omarchy]\n[core]\n[extra]\n[alarm]\n' >"$runtime/default/pacman/aarch64/pacman-stable.conf"
  printf "cat >> /etc/pacman.conf <<'EOF'\n\n[arch-mact2]\nSigLevel = Never\nEOF\n" \
    >"$runtime/install/hardware/pacman.sh"
  echo offline >"$WORK/root/var/lib/pacman/sync/offline.db"
  local repo
  for repo in "$@"; do
    echo "$repo" >"$WORK/sync/$repo.db"
    touch -d '2026-10-21 21:40' "$WORK/sync/$repo.db"
  done
}
shipped() { (cd "$WORK/root/var/lib/pacman/sync" && ls | tr '\n' ' ' | sed 's/ $//'); }

fixture omarchy core extra multilib arch-mact2 platform aur
bash "$TOOL" "$WORK/root" "$WORK/sync" >/dev/null
check "x86: exit status" 0 $?
check "x86: the runtime's repositories and the T2 one, offline.db kept, build-only ones left behind" \
  "arch-mact2.db core.db extra.db multilib.db offline.db omarchy.db" "$(shipped)"
check "x86: the index keeps its mtime" \
  "$(stat -c %Y "$WORK/sync/core.db")" "$(stat -c %Y "$WORK/root/var/lib/pacman/sync/core.db")"

fixture platform omarchy core extra alarm aur
bash "$TOOL" "$WORK/root" "$WORK/sync" >/dev/null
check "aarch64: exit status" 0 $?
check "aarch64: [alarm] shipped, the file:// [platform] bundle and [aur] not" \
  "alarm.db core.db extra.db offline.db omarchy.db" "$(shipped)"

fixture core extra
bash "$TOOL" "$WORK/root" "$WORK/sync" >/dev/null 2>&1
check "no omarchy.db: the build stops" 1 $?

fixture omarchy core extra
rm -rf "$WORK/root/usr/share/omarchy/default/pacman"
bash "$TOOL" "$WORK/root" "$WORK/sync" >/dev/null 2>&1
check "no pacman.conf templates: the build stops" 1 $?

exit $((failures > 0))
