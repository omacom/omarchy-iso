#!/bin/bash
#
# Unit test for warm_offline_mirror in .automated_script.sh: the try set is read
# first, and nothing is read (or charged to the budget) twice.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/configs/airootfs/root/.automated_script.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { local d="$1" x="${2:-}"; [[ -n $x ]] && printf '%s\n' "$x" >&2; printf 'not ok - %s\n' "$d" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stubs" "$work/mirror"
# cat is how the function warms a file; log every path it is asked to read.
cat >"$work/stubs/cat" <<'STUB'
#!/bin/bash
[[ $1 == -- ]] && shift
printf '%s\n' "$1" >>"$TEST_LOG"
STUB
chmod +x "$work/stubs/cat"

# Four archives; two of them are the try set. Sizes only matter for ordering.
head -c 5120 /dev/zero >"$work/mirror/big-1-x86_64.pkg.tar.zst"
head -c 3072 /dev/zero >"$work/mirror/try-a-1-x86_64.pkg.tar.zst"
head -c 2048 /dev/zero >"$work/mirror/try-b-1-x86_64.pkg.tar.zst"
head -c 1024 /dev/zero >"$work/mirror/small-1-x86_64.pkg.tar.zst"
printf 'try-a try-a-1-x86_64.pkg.tar.zst 3\ntry-b try-b-1-x86_64.pkg.tar.zst 2\n' >"$work/try-packages"
printf 'MemAvailable:   4000000 kB\n' >"$work/meminfo"
export TEST_LOG="$work/reads.log"; : >"$TEST_LOG"

eval "$(sed -n '/^warm_offline_mirror() {/,/^}/p' "$SCRIPT")"
PATH="$work/stubs:$PATH" OMARCHY_MIRROR_DIR="$work/mirror" OMARCHY_TRY_PACKAGES="$work/try-packages" OMARCHY_MEMINFO="$work/meminfo" warm_offline_mirror

mapfile -t reads < <(xargs -n1 basename <"$TEST_LOG")
[[ ${reads[0]} == try-a-1-x86_64.pkg.tar.zst && ${reads[1]} == try-b-1-x86_64.pkg.tar.zst ]] || fail "reads the try set first" "$(<"$TEST_LOG")"
[[ ${reads[2]} == big-1-x86_64.pkg.tar.zst && ${reads[3]} == small-1-x86_64.pkg.tar.zst ]] || fail "then the rest, largest first" "$(<"$TEST_LOG")"
(( ${#reads[@]} == 4 )) || fail "reads every archive exactly once" "$(<"$TEST_LOG")"
pass "warm_offline_mirror reads the try set first and nothing twice"
