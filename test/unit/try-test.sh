#!/bin/bash
#
# Unit tests for omarchy-try — the orchestrator. Verifies its guards, its GPU
# node selection, and that it hands the install/setup off to omarchy-try-setup.
# The install steps themselves are covered by try-setup-test.sh.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TRY="$ROOT/configs/airootfs/usr/local/bin/omarchy-try"

pass() { printf 'ok - %s\n' "$1"; }
fail() { local d="$1" x="${2:-}"; [[ -n $x ]] && printf '%s\n' "$x" >&2; printf 'not ok - %s\n' "$d" >&2; exit 1; }

work=$(mktemp -d); trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
stub_dir="$work/stubs"; mkdir -p "$stub_dir"
# The dashboard stub logs the argv and environment the greeter would hand it,
# then runs its child like the real one; the setup stub logs its own argv.
cat >"$stub_dir/omarchy-install-dashboard" <<'STUB'
#!/bin/bash
printf 'omarchy-install-dashboard TRY=%s %s\n' "${OMARCHY_DASHBOARD_TRY:-}" "$*" >>"$TEST_LOG"
while [[ $1 != -- ]]; do shift; done; shift
exec "$@"
STUB
cat >"$stub_dir/omarchy-try-setup" <<'STUB'
#!/bin/bash
printf 'omarchy-try-setup %s\n' "$*" >>"$TEST_LOG"
exit ${SETUP_RC:-0}
STUB
chmod +x "$stub_dir"/*

new_sandbox() {
  sandbox=$(mktemp -d "$work/sb.XXXXXX")
  mkdir -p "$sandbox/proc" "$sandbox/usr/share/omarchy-iso"
  printf 'MemTotal:       %d kB\n' "${1:-16000000}" >"$sandbox/proc/meminfo"
  printf 'omarchy omarchy.pkg\n' >"$sandbox/usr/share/omarchy-iso/try-packages"
  export TEST_LOG="$sandbox/calls.log"; : >"$TEST_LOG"
}
run() { PATH="$stub_dir:$PATH" "$TRY" "$sandbox"; }

# Guards.
new_sandbox 2000000 # a 2 GiB machine cannot hold the set under any cap
! run 2>"$sandbox/err" || fail "low memory exits non-zero"
grep -q '4 GiB' "$sandbox/err" || fail "low memory explains the floor" "$(<"$sandbox/err")"
! grep -q '^omarchy-try-setup' "$TEST_LOG" || fail "low memory sets nothing up"
pass "refuses below the memory floor without setting up"

# MemTotal on a nominal 4 GiB machine reads ~3.8 GiB after kernel reservations.
# Measured: such a machine runs the session, with zram holding ~1 GiB and the
# browser open, so the floor has to admit it.
new_sandbox 3992896
run >/dev/null 2>&1 || fail "a nominal 4 GiB machine is admitted"
grep -q '^omarchy-try-setup' "$TEST_LOG" || fail "a nominal 4 GiB machine sets up"
pass "admits a nominal 4 GiB machine"

new_sandbox
rm "$sandbox/usr/share/omarchy-iso/try-packages"
! run 2>/dev/null || fail "missing list exits non-zero"
pass "refuses without a try package list"

# Hand-off: omarchy-try runs the setup worker under the dashboard, in try mode,
# with the log and state files it polls, the sandbox root, and no nvidia.
new_sandbox
run >/dev/null 2>&1 || fail "happy path exits zero"
state=$sandbox/run/omarchy-try/state.json; log=$sandbox/var/log/omarchy-install.log
grep -q "^omarchy-install-dashboard TRY=yes $log $state -- omarchy-try-setup $state no $sandbox\$" "$TEST_LOG" \
  || fail "runs the setup under the dashboard in try mode" "$(<"$TEST_LOG")"
grep -q "^omarchy-try-setup $state no $sandbox\$" "$TEST_LOG" || fail "the dashboard's child is the setup worker" "$(<"$TEST_LOG")"
[[ -f $log ]] || fail "starts the install log the dashboard tails"
pass "hands the install and setup to omarchy-try-setup under the dashboard"

# A failing setup makes omarchy-try exit non-zero.
new_sandbox
! SETUP_RC=1 run >/dev/null 2>&1 || fail "setup failure exits non-zero"
pass "propagates a setup failure"

# cleanup() promises the installer the environment it booted into: every unit
# omarchy-try-setup starts for the session (zram aside — swap is harmless and
# swapoff would only pull the overlay back into RAM) must be stopped here.
SETUP="$ROOT/configs/airootfs/usr/local/bin/omarchy-try-setup"
stops=$(sed -n '/^cleanup() {/,/^}/p' "$TRY" | grep 'systemctl stop')
for unit in $(grep -oE '^systemctl start [^|&]*' "$SETUP" | sed 's/^systemctl start //; s/--no-block //' | tr ' ' '\n' | grep -v zram | sort -u); do
  grep -q -- "$unit" <<<"$stops" || fail "cleanup stops $unit" "$stops"
done
pass "cleanup stops every service the setup started"

# Nothing on the way back to the installer may block: a queued start job that
# waits on an unreachable dependency (time-sync on an offline machine) would
# strand the user instead of returning them to the greeter.
sed -n '/^cleanup() {/,/^}/p' "$TRY" | grep -q 'systemctl start --no-block' || fail "cleanup restores the installer's network without waiting"
pass "cleanup does not block restoring the installer's network"

# The software fallback only has something to render to because nouveau is kept
# off the card, so the parameter that does it is load-bearing for every NVIDIA
# machine. It belongs on the UEFI cmdline and nowhere else: a BIOS boot has no
# firmware framebuffer to fall back to, so it must keep nouveau and its console.
# Both GRUB configs: grub.cfg is the UEFI medium, loopback.cfg is the same ISO
# loop-mounted (Ventoy and friends). Both set gfxpayload=keep, so both have a
# firmware framebuffer to fall back to, and a machine booted either way needs
# the same treatment.
for GRUB in "$ROOT/configs/grub/grub.cfg" "$ROOT/configs/grub/loopback.cfg"; do
  n=$(grep -c '^\s*linux .*modprobe.blacklist=nouveau' "$GRUB" || true)
  (( n == 2 )) || fail "blacklists nouveau on both Linux entries of $(basename "$GRUB")" "$n found"
done
GRUB="$ROOT/configs/grub/grub.cfg"
grep -q 'set gfxmode="auto"' "$GRUB" || fail "leaves the boot resolution as upstream set it"
[[ ! -e $ROOT/configs/airootfs/etc/modprobe.d/omarchy-try-nouveau.conf ]] || fail "does not blacklist nouveau for BIOS boots too"
for f in "$ROOT"/configs/syslinux/*; do
  ! grep -q 'nouveau' "$f" || fail "leaves the BIOS boot config alone" "$f"
done
pass "nouveau is kept off the card on UEFI boots only"

# --- GPU selection helpers, sourced against sysfs fixtures -------------------
eval "$(sed -n '/^is_firmware_fb() {/,/^}/p' "$TRY")"
eval "$(sed -n '/^select_display_gpu() {/,/^}/p' "$TRY")"
eval "$(sed -n '/^nvidia_pci_present() {/,/^}/p' "$TRY")"

mk_card() { # <root> <card> <driver> <connector> <status>
  local r=$1 c=$2 d=$3 conn=$4 st=$5
  mkdir -p "$r/$c/device"
  [[ -n $d ]] && { mkdir -p "$r/.drv/$d"; ln -sfn "$r/.drv/$d" "$r/$c/device/driver"; }
  mkdir -p "$r/$c-$conn"; echo "$st" >"$r/$c-$conn/status"
}

g=$(mktemp -d "$work/g.XXXXXX"); mk_card "$g" card0 amdgpu DP-1 connected
TRY_DRM_DEVICE=; TRY_SOFTWARE=
select_display_gpu "$g" /dev/dri || fail "hw: returns a device"
[[ $TRY_DRM_DEVICE == /dev/dri/card0 && $TRY_SOFTWARE == 0 ]] || fail "hw: amd panel, no software" "$TRY_DRM_DEVICE/$TRY_SOFTWARE"
pass "select_display_gpu picks a hardware panel"

g=$(mktemp -d "$work/g.XXXXXX")
mk_card "$g" card0 amdgpu DP-4 disconnected
mk_card "$g" card1 simple-framebuffer Virtual-1 connected
TRY_DRM_DEVICE=; TRY_SOFTWARE=
select_display_gpu "$g" /dev/dri || fail "hybrid: returns a device"
[[ $TRY_DRM_DEVICE == /dev/dri/card1 && $TRY_SOFTWARE == 1 ]] || fail "hybrid: firmware fb + software" "$TRY_DRM_DEVICE/$TRY_SOFTWARE"
pass "select_display_gpu falls back to software on the firmware framebuffer"

g=$(mktemp -d "$work/g.XXXXXX"); mk_card "$g" card0 amdgpu DP-1 disconnected
! select_display_gpu "$g" /dev/dri || fail "no display: returns non-zero"
pass "select_display_gpu reports no usable display node"

# nvidia_pci_present: a display-class 0x10de device is detected; others aren't.
p=$(mktemp -d "$work/p.XXXXXX"); mkdir -p "$p/0000:01:00.0"
echo 0x10de >"$p/0000:01:00.0/vendor"; echo 0x030000 >"$p/0000:01:00.0/class"
nvidia_pci_present "$p" || fail "detects an NVIDIA display GPU"
p=$(mktemp -d "$work/p.XXXXXX"); mkdir -p "$p/0000:01:00.0"
echo 0x1002 >"$p/0000:01:00.0/vendor"; echo 0x030000 >"$p/0000:01:00.0/class"
! nvidia_pci_present "$p" || fail "does not flag an AMD GPU as NVIDIA"
pass "nvidia_pci_present detects only NVIDIA display GPUs"
