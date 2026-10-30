#!/bin/bash
#
# test/boot-benchmark without a VM: the function that turns a run's screen
# and stick-read timeline into the firmware/ISO split and the ISO's black
# seconds, and the one that stops the screen sampler, are taken out of the
# benchmark and run against hand-made timelines and processes.

# shellcheck disable=SC2034 # the variables are used by the functions taken out of the benchmark

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
benchmark="$ROOT/test/boot-benchmark"
bash -n "$benchmark"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The benchmark boots VMs when it is run; take only the functions under test.
take() {
  local name
  for name; do
    eval "$(sed -n "/^$name() {\$/,/^}\$/p" "$benchmark")"
    declare -F "$name" >/dev/null || fail "test/boot-benchmark no longer has $name"
  done
}
take split_wait stop_sampler

BLACK_LIT_FRACTION=0.005

expect() {
  local what="$1" want="$2" got="$3"
  [[ $got == "$want" ]] || fail "$what: want '$want', got '$got'"
}

# Timeline lines are "<seconds since QEMU start> <lit fraction> <stick bytes>";
# split_wait prints "<first read> <menu> <boot MB> <boot s at the stick's
# rate> <firmware read overhead> <MB read kernel to greeter> <black>
# <longest black> <frames> <mean interval ms>".

# ------------------------------------------------------------- BIOS boot

# The firmware shows nothing until it reads the loader at 0.3 s; ISOLINUX's
# menu is on screen while the stick sits idle until 16.0 (it starts reading
# again somewhere before 17.0); the boot files load on a black screen until
# 19.5; the kernel starts at 19.8, the splash shows at 22.0 and the greeter
# at 25.0.
cat >"$work/bios" <<'EOF'
0.1 0.000000 0
0.3 0.000000 700000
1.0 0.100000 700000
16.0 0.100000 700000
17.0 0.000000 20000000
18.0 0.000000 60000000
19.0 0.000000 100000000
19.5 0.000000 100000000
22.0 0.100000 300000000
25.0 0.100000 400000000
26.0 0.100000 500000000
EOF

# Menu 16.0 - 0.3. The 100 MB of boot files take 2.5 s at 40 MB/s of the
# 3.8 s loading took (19.8 - 0.3 - 15.7), leaving 1.3 s to the firmware, so
# a loading second counts as 2.5 / 3.8 of one. Black: the first menu frame
# (0.3-1.0, before the menu drew) is 0.7, then loading from 17.0 to kernel
# start (2.8 s, 1.84 of it the ISO's) runs on unbroken into kernel start to
# the splash (2.2): 0.7 + 4.04, longest 4.04. Black before the first read
# is the firmware's and counts nowhere.
expect "BIOS boot" "0.3 15.7 100 2.5 1.3 300 4.7 4.0 10 2767" \
  "$(split_wait "$work/bios" 19.8 25.0 40)"

# ------------------------------------------------------------- UEFI boot

# A slow firmware USB driver: QEMU's placeholder until 1.0, the firmware's
# logo from its first read at 2.0, then black while every frame, however
# sparse, sees more bytes (so no menu) until the splash at 19.0, black again
# at 20.0 and the greeter at 21.0. The kernel starts at 18.5.
cat >"$work/uefi" <<'EOF'
1.0 0.000000 0
2.0 0.020000 30000
6.0 0.000000 30000000
10.0 0.000000 60000000
14.0 0.000000 90000000
18.0 0.000000 120000000
19.0 0.100000 150000000
20.0 0.000000 180000000
21.0 0.100000 200000000
EOF

# 120 MB at 40 MB/s is 3 of the 16.5 s loading took: 13.5 s are the
# firmware's, and a loading second counts as 3 / 16.5 of one. Black: 6.0 to
# 18.5 at that share (2.27) runs on into 18.5-19.0 (0.5), then 20.0-21.0.
expect "UEFI boot" "2.0 0.0 120 3.0 13.5 80 3.8 2.8 9 2500" \
  "$(split_wait "$work/uefi" 18.5 21.0 40)"

# A stick measured slower than the firmware read it (the throttle lets a
# burst through): the boot files' share never exceeds the time loading took,
# so the firmware gets no negative overhead and loading counts in full.
expect "boot files read faster than the measured rate" "2.0 0.0 120 16.5 0.0 80 14.0 13.0 9 2500" \
  "$(split_wait "$work/uefi" 18.5 21.0 4)"

# Without the stick's byte counts the firmware cannot be cut out: no split.
sed 's/ [0-9]*$/ -1/' "$work/uefi" >"$work/unknown"
split_wait "$work/unknown" 18.5 21.0 40 >/dev/null && fail "a timeline without byte counts was split"
sed 's/ [0-9]*$/ 0/' "$work/uefi" >"$work/unread"
split_wait "$work/unread" 18.5 21.0 40 >/dev/null && fail "a timeline where the stick was never read was split"
: >"$work/empty"
split_wait "$work/empty" 18.5 21.0 40 >/dev/null && fail "an empty timeline was split"

# ------------------------------------------------------------- dead sampler

# stop_sampler kills the sampler and keeps its exit status: 143 is its own
# SIGTERM, anything else a sampler that died before the greeter, which the
# benchmark then refuses to turn into a row.
sleep 60 &
SAMPLER_PID=$!
stop_sampler
expect "a live sampler ends by the kill" 143 "$SAMPLER_STATUS"
expect "stop_sampler forgets the pid" "" "$SAMPLER_PID"

(exit 7) &
SAMPLER_PID=$!
while kill -0 "$SAMPLER_PID" 2>/dev/null; do sleep 0.05; done
stop_sampler
expect "a sampler that died keeps its own status" 7 "$SAMPLER_STATUS"

echo "boot-benchmark: ok"
