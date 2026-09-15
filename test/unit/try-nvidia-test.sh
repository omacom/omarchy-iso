#!/bin/bash
#
# Unit tests for omarchy-try-nvidia. Runs against a sandbox with the omarchy
# generation helpers, pacman, modprobe, depmod and udevadm stubbed on PATH; the
# GPU-generation stub is switched per case to check driver selection.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
NV="$ROOT/configs/airootfs/usr/local/bin/omarchy-try-nvidia"

pass() { printf 'ok - %s\n' "$1"; }
fail() { local d="$1" x="${2:-}"; [[ -n $x ]] && printf '%s\n' "$x" >&2; printf 'not ok - %s\n' "$d" >&2; exit 1; }

work=$(mktemp -d); trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
stub_dir="$work/stubs"; mkdir -p "$stub_dir"
omarchy_bin="$work/omarchy/bin"; mkdir -p "$omarchy_bin"

# omarchy generation helpers: GSP=1 -> gsp true; GSP=0 -> without-gsp true.
cat >"$omarchy_bin/omarchy-hw-nvidia-gsp" <<'STUB'
#!/bin/bash
[[ ${GSP:-1} == 1 ]]
STUB
cat >"$omarchy_bin/omarchy-hw-nvidia-without-gsp" <<'STUB'
#!/bin/bash
[[ ${GSP:-1} == 0 ]]
STUB
cat >"$stub_dir/pacman" <<'STUB'
#!/bin/bash
# -Qqs prints a kernel package name; -Sy records the install line.
[[ $1 == -Qqs ]] && { echo linux-t2; exit 0; }
printf 'pacman %s\n' "$*" >>"$TEST_LOG"
[[ ${PACMAN_FAIL:-} == 1 ]] && exit 1
exit 0
STUB
for c in modprobe depmod udevadm; do
  cat >"$stub_dir/$c" <<STUB
#!/bin/bash
printf '$c %s\n' "\$*" >>"\$TEST_LOG"
[[ \${${c^^}_FAIL:-} == 1 ]] && exit 1
exit 0
STUB
done
chmod +x "$stub_dir"/* "$omarchy_bin"/*

new_sandbox() {
  sandbox=$(mktemp -d "$work/sb.XXXXXX")
  mkdir -p "$sandbox/sys/class/drm/card1/device"
  # a card the modprobe "bound": driver -> nvidia with a connected panel, so the
  # readiness check (which requires a connected connector) passes.
  mkdir -p "$sandbox/.drv/nvidia"; ln -sfn "$sandbox/.drv/nvidia" "$sandbox/sys/class/drm/card1/device/driver"
  mkdir -p "$sandbox/sys/class/drm/card1-DP-1"; echo connected >"$sandbox/sys/class/drm/card1-DP-1/status"
  export TEST_LOG="$sandbox/calls.log"; : >"$TEST_LOG"
}
run() { PATH="$stub_dir:$PATH" OMARCHY_PATH="$work/omarchy" "$NV" "$sandbox"; }

# GSP card (Turing+): open-dkms + utils + matching kernel headers.
new_sandbox; export GSP=1; unset PACMAN_FAIL
run >/dev/null 2>&1 || fail "gsp: exits zero when nvidia binds"
line=$(grep '^pacman -Sy' "$TEST_LOG")
[[ $line == *nvidia-open-dkms* && $line == *nvidia-utils* ]] || fail "gsp: installs nvidia-open" "$line"
[[ $line == *linux-t2-headers* ]] || fail "gsp: installs matching kernel headers" "$line"
# fbdev=1 as well as modeset=1: the greeter we return to lives on VT1, and a
# driver whose fbdev default is 0 leaves that console dark. It is the current
# default in 610.x, so this pins it rather than trusting it.
[[ $(<"$sandbox/etc/modprobe.d/nvidia.conf") == 'options nvidia_drm modeset=1 fbdev=1' ]] || fail "gsp: writes modeset and fbdev config" "$(<"$sandbox/etc/modprobe.d/nvidia.conf")"
# Without -a, modprobe loads only the first name and passes the rest as module
# parameters ("nvidia: unknown parameter 'nvidia_drm' ignored") — nvidia_drm
# then never loads and no NVIDIA DRM device appears. Seen on real hardware.
grep -q '^modprobe -a nvidia nvidia_modeset nvidia_uvm nvidia_drm$' "$TEST_LOG" || fail "gsp: loads all four nvidia modules with modprobe -a"
pass "omarchy-try-nvidia picks nvidia-open for a GSP card"

# Pre-GSP card: the 580xx branch.
new_sandbox; export GSP=0; unset PACMAN_FAIL
run >/dev/null 2>&1 || fail "pre-gsp: exits zero"
line=$(grep '^pacman -Sy' "$TEST_LOG")
[[ $line == *nvidia-580xx-dkms* && $line == *nvidia-580xx-utils* ]] || fail "pre-gsp: installs the 580xx driver" "$line"
pass "omarchy-try-nvidia picks the 580xx driver for a pre-GSP card"

# Install failure: report non-zero so the caller keeps the software fallback.
new_sandbox; export GSP=1 PACMAN_FAIL=1
! run >/dev/null 2>&1 || fail "install failure exits non-zero"
pass "omarchy-try-nvidia fails cleanly when the driver install fails"

# The readiness loop is the guard that decides between the accelerated session
# and the software fallback; it has to fail when the driver never drives a
# panel — the real-hardware case where nvidia_drm silently did not load.
new_sandbox; export GSP=1; unset PACMAN_FAIL
rm "$sandbox/sys/class/drm/card1/device/driver"; mkdir -p "$sandbox/.drv/amdgpu"
ln -sfn "$sandbox/.drv/amdgpu" "$sandbox/sys/class/drm/card1/device/driver"
! TRY_NVIDIA_RETRIES=2 run >/dev/null 2>&1 || fail "no nvidia card: exits non-zero"
grep -q '^modprobe -a nvidia' "$TEST_LOG" || fail "no nvidia card: still tried to load the driver"
pass "omarchy-try-nvidia fails when no card ends up on the nvidia driver"

new_sandbox; export GSP=1; unset PACMAN_FAIL
echo disconnected >"$sandbox/sys/class/drm/card1-DP-1/status"
! TRY_NVIDIA_RETRIES=2 run >/dev/null 2>&1 || fail "no connected panel: exits non-zero"
pass "omarchy-try-nvidia fails when the nvidia card drives no connected panel"
