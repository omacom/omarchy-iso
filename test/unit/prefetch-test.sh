#!/bin/bash
#
# Unit tests for omarchy-prefetch. The plan mode's output file IS the
# interface — one "read <kb> <path>" line per read, in read order — so the
# cases run the real script against throwaway fixtures and assert the plan:
# the budget arithmetic, the largest-first mirror walk, and the stream head
# planned last. The execute mode is the dumb half; it gets the leftovers:
# it reads what a plan says, reports the total, and shrugs at vanished files.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PREFETCH="$ROOT/configs/airootfs/usr/local/bin/omarchy-prefetch"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# du -k rounds up to the fs block, so fixture sizes are whole KiB multiples
# large enough that rounding cannot flip a budget comparison.
make_fixture() {
  local path="$1" kb="$2"
  mkdir -p "$(dirname "$path")"
  dd if=/dev/zero of="$path" bs=1024 count="$kb" status=none
}

run_plan() {
  local budget_kb="$1"
  OMARCHY_PREFETCH_IMAGE="$work/medium/image.btrfs.zst" \
    OMARCHY_PREFETCH_MIRROR="$work/medium/mirror" \
    OMARCHY_PREFETCH_BUDGET_KB="$budget_kb" \
    "$PREFETCH" plan "$work/plan" >"$work/plan.summary" ||
    fail "plan exited non-zero (budget ${budget_kb}K)"
}

# --- fixture: a 3000K image, mirror packages of 2000K, 1500K, 500K ----------

make_fixture "$work/medium/image.btrfs.zst" 3000
make_fixture "$work/medium/mirror/a.pkg.tar.zst" 2000
make_fixture "$work/medium/mirror/b.pkg.tar.zst" 1500
make_fixture "$work/medium/mirror/c.pkg.tar.zst" 500

# --- image claims the budget first; mirror gets the leftover ----------------

run_plan 4000
# 3000K image reserves first, leaving 1000K: a (2000K) and b (1500K) exceed
# it, c (500K) fits. The image itself is planned last.
expected="read 500 $work/medium/mirror/c.pkg.tar.zst
read 3000 $work/medium/image.btrfs.zst"
[[ $(cat "$work/plan") == "$expected" ]] ||
  fail "image budget-first, mirror leftover, stream last" "$(cat "$work/plan")"
pass "image claims the budget first, mirror fills the leftover, stream planned last"

[[ $(cat "$work/plan.summary") == "plan: 3000K of stream + 500K of mirror within a 4000K budget" ]] ||
  fail "plan summary line" "$(cat "$work/plan.summary")"
pass "the plan reports what it chose and against what budget"

# --- a budget below the image size clamps the head and starves the mirror ---

run_plan 1000
expected="read 1000 $work/medium/image.btrfs.zst"
[[ $(cat "$work/plan") == "$expected" ]] ||
  fail "clamped head only" "$(cat "$work/plan")"
pass "a small budget clamps the stream head and leaves no mirror budget"

# --- a roomy budget plans everything, mirror largest first ------------------

run_plan 10000
expected="read 2000 $work/medium/mirror/a.pkg.tar.zst
read 1500 $work/medium/mirror/b.pkg.tar.zst
read 500 $work/medium/mirror/c.pkg.tar.zst
read 3000 $work/medium/image.btrfs.zst"
[[ $(cat "$work/plan") == "$expected" ]] ||
  fail "full warm, largest first" "$(cat "$work/plan")"
pass "a roomy budget plans everything, mirror largest first, stream still last"

# --- missing image: the mirror still gets the whole budget ------------------

mv "$work/medium/image.btrfs.zst" "$work/medium/image.gone"
run_plan 4000
expected="read 2000 $work/medium/mirror/a.pkg.tar.zst
read 1500 $work/medium/mirror/b.pkg.tar.zst
read 500 $work/medium/mirror/c.pkg.tar.zst"
[[ $(cat "$work/plan") == "$expected" ]] ||
  fail "mirror-only plan" "$(cat "$work/plan")"
pass "a missing stream leaves the whole budget to the mirror"
mv "$work/medium/image.gone" "$work/medium/image.btrfs.zst"

# --- missing mirror: the stream head alone ----------------------------------

mv "$work/medium/mirror" "$work/mirror.gone"
run_plan 4000
expected="read 3000 $work/medium/image.btrfs.zst"
[[ $(cat "$work/plan") == "$expected" ]] ||
  fail "stream-only plan" "$(cat "$work/plan")"
pass "a missing mirror still plans the stream head"
mv "$work/mirror.gone" "$work/medium/mirror"

# --- execute reads the plan in order and reports the total ------------------

run_plan 4000
out=$("$PREFETCH" execute "$work/plan") || fail "execute exited non-zero"
[[ $out == "warmed 3500K in 2 reads" ]] ||
  fail "execute total" "$out"
pass "execute reads the plan and reports the warmed total"

# --- a file that vanished between plan and execute is shrugged off ----------

run_plan 4000
rm "$work/medium/mirror/c.pkg.tar.zst"
out=$("$PREFETCH" execute "$work/plan") || fail "execute failed on a vanished file"
[[ $out == "warmed 3500K in 2 reads" ]] ||
  fail "execute after vanish" "$out"
pass "a file vanished after planning does not fail the warm"

# --- an empty plan (budget floor) executes as a clean no-op -----------------

: >"$work/plan"
out=$("$PREFETCH" execute "$work/plan") || fail "execute failed on an empty plan"
[[ $out == "warmed 0K in 0 reads" ]] ||
  fail "empty plan no-op" "$out"
pass "an empty plan executes as a clean no-op"

# --- a missing plan is loud: the unit's steps are mis-wired -----------------

"$PREFETCH" execute "$work/no-such-plan" 2>/dev/null &&
  fail "execute accepted a missing plan"
pass "a missing plan file fails loudly"

echo "all prefetch tests passed"
