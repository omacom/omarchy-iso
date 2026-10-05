#!/bin/bash
#
# Unit tests for resolve_try_packages in builder/build-iso.sh: the build-time
# step that turns builder/try.packages into the "name file" list omarchy-try
# installs, and fails the build when the mirror cannot satisfy it.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD="$ROOT/builder/build-iso.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { local d="$1" x="${2:-}"; [[ -n $x ]] && printf '%s\n' "$x" >&2; printf 'not ok - %s\n' "$d" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stubs" "$work/cache"
# pacman stub: -Sy succeeds; -S --print lists each target with a file name plus
# one shared dependency (twice, to prove the output is de-duplicated); an
# unresolvable target makes it fail like the real thing.
cat >"$work/stubs/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$TEST_LOG"
[[ " $* " == *" -Sy "* ]] && exit 0
targets=(); skip=0
for a in "$@"; do
  (( skip )) && { skip=0; continue; }
  case $a in
    --config|--root|--dbpath|--print-format|--assume-installed) skip=1; continue ;;
    -*) continue ;;
  esac
  targets+=("$a")
done
if [[ " $* " == *" -Si "* ]]; then # sizes for the resolved names, in the units pacman uses
  for t in "${targets[@]}"; do
    printf 'Name            : %s\nInstalled Size  : %s\n\n' "$t" "$([[ $t == glibc ]] && echo '40.00 MiB' || echo '512.00 KiB')"
  done
  exit 0
fi
for t in "${targets[@]}"; do
  [[ $t == missing ]] && { echo "error: target not found: $t" >&2; exit 1; }
  printf '%s %s-1-1-x86_64.pkg.tar.zst\n' "$t" "$t"
  printf 'glibc glibc-2-1-x86_64.pkg.tar.zst\n'
done
STUB
chmod +x "$work/stubs/pacman"
: >"$work/cache/pacman-offline.conf"
export TEST_LOG="$work/calls.log"; : >"$TEST_LOG"

eval "$(sed -n '/^resolve_try_packages() {/,/^}/p' "$BUILD")"
build_cache_dir="$work/cache"

printf '# the desktop\nomarchy\n\nfoot\n' >"$work/try.packages"
out=$(PATH="$work/stubs:$PATH" TRY_PACKAGES_LIST="$work/try.packages" resolve_try_packages) || fail "resolves a valid list"
[[ $out == $'foot foot-1-1-x86_64.pkg.tar.zst 512\nglibc glibc-2-1-x86_64.pkg.tar.zst 40960\nomarchy omarchy-1-1-x86_64.pkg.tar.zst 512' ]] \
  || fail "emits sorted, de-duplicated 'name file kib' lines, comments and blanks skipped" "$out"
line=$(grep -- '--print' "$TEST_LOG")
for p in limine limine-mkinitcpio-hook limine-snapper-sync snapper; do
  [[ $line == *"--assume-installed $p"* ]] || fail "assumes $p, as omarchy-try-setup does" "$line"
done
grep -q '^pacman .* -Sy$' "$TEST_LOG" || fail "syncs the offline db first"
pass "resolve_try_packages resolves the list the way the live install does"

: >"$TEST_LOG"; printf 'omarchy\nmissing\n' >"$work/try.packages"
! PATH="$work/stubs:$PATH" TRY_PACKAGES_LIST="$work/try.packages" resolve_try_packages >/dev/null 2>&1 \
  || fail "an unresolvable package fails the resolution"
pass "resolve_try_packages fails when the mirror cannot satisfy the list"
