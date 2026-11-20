#!/bin/bash
#
# The aarch64 launcher's display choice, with qemu-img stubbed. A fresh disk
# has no data extent; an installed one does.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$fixture/bin"
cat >"$fixture/bin/qemu-img" <<'EOF'
#!/bin/bash
# map -U --output=json DISK. The test writes the JSON next to the disk.
printf '%s\n' "$(cat "${4}.map")"
EOF
chmod +x "$fixture/bin/qemu-img"

export PATH="$fixture/bin:$PATH"
# shellcheck disable=SC1091
source "$ROOT/bin/lib/aarch64-installed-boot.sh"

DISK=$fixture/disk
printf '%s\n' '{ "data": false }' >"$DISK.map"

[[ $(aarch64_boot_mode) == gl ]] || fail "a fresh disk boots the live ISO on the GL device"
aarch64_should_relaunch guest-reset && fail "a fresh disk relaunches after the installer reboots"
OMARCHY_VM_GL=0
[[ $(aarch64_boot_mode) == plain ]] || fail "OMARCHY_VM_GL=0 stays on the plain device"
unset OMARCHY_VM_GL

printf '%s\n' '{ "start": 0, "data": true }' >"$DISK.map"
[[ $(aarch64_boot_mode) == plain ]] || fail "an installed disk starts on the plain device"
aarch64_should_relaunch guest-reset || fail "an installer reboot on a written disk does not relaunch"
aarch64_should_relaunch host-ui && fail "closing the window relaunches the VM"
aarch64_should_relaunch guest-shutdown && fail "a guest poweroff relaunches the VM"
aarch64_should_relaunch "" && fail "a missing QMP reason relaunches the VM"
OMARCHY_VM_GL=0
[[ $(aarch64_boot_mode) == plain ]] || fail "OMARCHY_VM_GL=0 on an installed disk leaves the plain device"

# qemu-img failing must read as an empty disk, not as an install.
printf '%s\n' '#!/bin/bash' 'exit 1' >"$fixture/bin/qemu-img"
chmod +x "$fixture/bin/qemu-img"
unset OMARCHY_VM_GL
[[ $(aarch64_boot_mode) == gl ]] || fail "an unreadable disk image boots as a fresh ISO"
aarch64_should_relaunch guest-reset && fail "an unreadable disk image relaunches"

grep -Fq 'aarch64_should_relaunch "$shutdown_reason"' "$ROOT/bin/omarchy-iso-boot" \
  || fail "the launcher does not consult the QMP shutdown reason"
grep -Fq 'qmp-shutdown-reason.py' "$ROOT/bin/omarchy-iso-boot" \
  || fail "the launcher does not read the QMP shutdown reason"
[[ $(grep -c 'run_aarch64 plain --no-iso$' "$ROOT/bin/omarchy-iso-boot") == 1 ]] \
  || fail "the installed-system relaunch still attaches the installer ISO"
[[ $(grep -c 'run_aarch64 plain$' "$ROOT/bin/omarchy-iso-boot") == 1 ]] \
  || fail "a disk that is already installed no longer boots with the ISO attached"
bash -n "$ROOT/bin/omarchy-iso-boot" "$ROOT/bin/lib/aarch64-installed-boot.sh"
echo "aarch64 installed-boot checks passed"
