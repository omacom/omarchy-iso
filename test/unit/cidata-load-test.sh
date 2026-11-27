#!/bin/bash
#
# Unit tests for omarchy-cidata-load. The script takes a path prefix, so every
# case runs against a throwaway sandbox with mount/umount/udevadm stubbed out:
# "mounting" copies the fake drive's contents into the mountpoint, and every
# stub logs its invocation so the cases can assert what was (not) called.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CIDATA_LOAD="$ROOT/configs/airootfs/usr/local/bin/omarchy-cidata-load"

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
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

stub_dir="$work/stubs"
mkdir -p "$stub_dir"

REAL_SLEEP=$(type -P sleep)

cat >"$stub_dir/udevadm" <<'STUB'
#!/bin/bash
printf 'udevadm %s\n' "$*" >>"$TEST_LOG"
if [[ -n ${UDEV_ON_SETTLE_HOOK:-} ]]; then
  bash -c "$UDEV_ON_SETTLE_HOOK"
fi
if [[ -n ${UDEV_CREATE_LABEL:-} && -e ${UDEV_TRIGGER_PATH:-} ]]; then
  ln -sfn "$UDEV_TARGET" "$UDEV_CREATE_LABEL"
fi
STUB

cat >"$stub_dir/sleep" <<STUB
#!/bin/bash
printf 'sleep %s\n' "\$*" >>"\$TEST_LOG"
exec "$REAL_SLEEP" "\$@"
STUB

cat >"$stub_dir/mount" <<'STUB'
#!/bin/bash
printf 'mount %s\n' "$*" >>"$TEST_LOG"
[[ ${MOUNT_FAIL:-} == 1 ]] && exit 32
device=$3 mountpoint=$4
cp -a "$(readlink -f "$device")"/. "$mountpoint"/
STUB

cat >"$stub_dir/umount" <<'STUB'
#!/bin/bash
printf 'umount %s\n' "$*" >>"$TEST_LOG"
STUB

chmod +x "$stub_dir"/*

new_sandbox() {
  sandbox=$(mktemp -d "$work/sandbox.XXXXXX")
  mkdir -p "$sandbox/dev/disk/by-label" "$sandbox/root" "$sandbox/media"
  export TEST_LOG="$sandbox/calls.log"
  : >"$TEST_LOG"
}

attach_drive() {
  ln -s "$sandbox/media" "$sandbox/dev/disk/by-label/$1"
}

run_load() {
  PATH="$stub_dir:$PATH" "$CIDATA_LOAD" "$sandbox"
}

write_required_pair() {
  echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
  echo '{"users": []}' >"$sandbox/media/user_credentials.json"
}

# No cidata drive attached: fall back to the wizard without mounting anything.
new_sandbox
! run_load || fail "no drive exits non-zero"
! grep -q '^mount ' "$TEST_LOG" || fail "no drive mounts nothing"
pass "no drive falls back to the wizard"

# The probe must wait for udev to finish enumerating before concluding there
# is no drive.
grep -q '^udevadm settle$' "$TEST_LOG" || fail "probe settles udev first"
pass "probe settles udev first"

# A drive with the full file set: everything lands in /root and the drive is
# unmounted afterwards.
new_sandbox
attach_drive cidata
write_required_pair
echo "false" >"$sandbox/media/user_encrypt_installation.txt"
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
echo 'tskey-auth-kFAKEKEY' >"$sandbox/media/tailscale_authkey"
run_load || fail "full file set loads"
for file in user_configuration.json user_credentials.json user_encrypt_installation.txt authorized_keys tailscale_authkey; do
  [[ -f $sandbox/root/$file ]] || fail "full file set copies $file"
done
grep -q '^umount ' "$TEST_LOG" || fail "full file set unmounts the drive"
pass "full file set loads, copies everything, and unmounts"

# The uppercase label variant some tools produce works too.
new_sandbox
attach_drive CIDATA
write_required_pair
run_load || fail "uppercase CIDATA label loads"
pass "uppercase CIDATA label loads"

# The required pair alone is a valid autoinstall drive; the optional files
# stay optional.
new_sandbox
attach_drive cidata
write_required_pair
run_load || fail "required pair alone loads"
[[ ! -e $sandbox/root/authorized_keys ]] || fail "required pair alone copies no optional files"
pass "required pair alone loads without optional files"

# Optional files are copied individually when present.
new_sandbox
attach_drive cidata
write_required_pair
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
run_load || fail "required pair plus authorized_keys loads"
[[ -f $sandbox/root/authorized_keys ]] || fail "authorized_keys is copied when present"
[[ ! -e $sandbox/root/user_encrypt_installation.txt ]] || fail "absent optional files are not copied"
[[ ! -e $sandbox/root/tailscale_authkey ]] || fail "absent tailscale_authkey is not copied"
pass "present optional files are copied, absent ones skipped"

# A defer-provisioning marker replaces user_credentials.json: deferred-provisioning installs
# creation to first boot, so imaging rigs ship no credentials at all.
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
: >"$sandbox/media/defer-provisioning"
run_load || fail "config plus defer-provisioning marker loads"
[[ -f $sandbox/root/defer-provisioning ]] || fail "defer-provisioning marker is copied"
[[ ! -e $sandbox/root/user_credentials.json ]] || fail "defer-provisioning drive copies no credentials"
pass "defer-provisioning marker stands in for credentials"

# The defer-provisioning marker and credentials can coexist (rig supplies its own LUKS
# passphrase in the credentials file); both are copied.
new_sandbox
attach_drive cidata
write_required_pair
: >"$sandbox/media/defer-provisioning"
run_load || fail "defer-provisioning marker plus credentials loads"
[[ -f $sandbox/root/defer-provisioning && -f $sandbox/root/user_credentials.json ]] || fail "both defer-provisioning marker and credentials are copied"
pass "defer-provisioning marker plus credentials copies both"

# An defer-provisioning marker without the configuration is still not an autoinstall drive.
new_sandbox
attach_drive cidata
: >"$sandbox/media/defer-provisioning"
! run_load || fail "defer-provisioning marker alone is not an autoinstall drive"
[[ ! -e $sandbox/root/defer-provisioning ]] || fail "defer-provisioning marker alone copies nothing"
pass "defer-provisioning marker alone falls back to the wizard"

# Stale deferred-provisioning inputs from a previous load in the same session are cleared before
# the current drive is copied: a normal drive must not inherit an old defer-provisioning
# marker or credentials.
new_sandbox
attach_drive cidata
write_required_pair
: >"$sandbox/root/defer-provisioning"                       # leftover from a prior deferred-provisioning load
echo 'old-keys' >"$sandbox/root/authorized_keys"
run_load || fail "normal drive after a stale defer-provisioning load loads"
[[ ! -e $sandbox/root/defer-provisioning ]] || fail "stale defer-provisioning marker is cleared"
[[ ! -e $sandbox/root/authorized_keys ]] || fail "stale optional inputs are cleared"
pass "stale deferred-provisioning inputs are cleared before loading a normal drive"

# A drive that isn't an autoinstall drive at all still clears stale inputs so
# the wizard that follows doesn't inherit them.
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json" # half a pair
: >"$sandbox/root/defer-provisioning"
! run_load || fail "half-pair drive still falls back"
[[ ! -e $sandbox/root/defer-provisioning ]] || fail "stale defer-provisioning marker cleared even on fallback"
pass "stale inputs are cleared even when falling back to the wizard"

# Half the required pair is not an autoinstall drive: unmount and fall back.
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
! run_load || fail "half the required pair exits non-zero"
[[ ! -e $sandbox/root/user_configuration.json ]] || fail "half the required pair copies nothing"
grep -q '^umount ' "$TEST_LOG" || fail "half the required pair still unmounts"
pass "half the required pair falls back and unmounts"

# An empty drive labeled cidata is not an autoinstall drive either.
new_sandbox
attach_drive cidata
! run_load || fail "empty drive exits non-zero"
grep -q '^umount ' "$TEST_LOG" || fail "empty drive still unmounts"
pass "empty drive falls back and unmounts"

# A drive that will not mount falls back rather than failing the boot.
new_sandbox
attach_drive cidata
write_required_pair
! MOUNT_FAIL=1 run_load || fail "mount failure exits non-zero"
! grep -q '^umount ' "$TEST_LOG" || fail "mount failure has nothing to unmount"
pass "mount failure falls back to the wizard"

# A copy failure must not report a loaded drive: the install would start with
# missing inputs. Fall back and let the wizard produce them instead.
new_sandbox
attach_drive cidata
write_required_pair
chmod 555 "$sandbox/root"
! run_load 2>/dev/null || fail "copy failure exits non-zero"
grep -q '^umount ' "$TEST_LOG" || fail "copy failure still unmounts"
pass "copy failure falls back and unmounts"

# A partial copy must clean up after itself: the wizard removes only what it
# writes, so anything the loader left behind would leak into the interactive
# install that follows.
new_sandbox
attach_drive cidata
write_required_pair
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
mkdir "$sandbox/root/user_credentials.json"
! run_load 2>/dev/null || fail "partial copy exits non-zero"
[[ ! -e $sandbox/root/user_configuration.json ]] || fail "partial copy removes what it copied"
[[ ! -e $sandbox/root/authorized_keys ]] || fail "partial copy leaves no authorized_keys behind"
pass "partial copy cleans up what it copied"

add_usb_interface() {
  local name="$1"
  local iclass="$2"
  local driver="${3:-}"
  local intf="$sandbox/sys/bus/usb/devices/$name"
  mkdir -p "$intf"
  printf '%s\n' "$iclass" >"$intf/bInterfaceClass"
  if [[ -n $driver ]]; then
    mkdir -p "$sandbox/sys/bus/usb/drivers/$driver"
    ln -s "$sandbox/sys/bus/usb/drivers/$driver" "$intf/driver"
  fi
}

wait_for_sleep_call() {
  local _
  for _ in $(seq 1 100); do
    grep -q '^sleep ' "$TEST_LOG" 2>/dev/null && return 0
    "$REAL_SLEEP" 0.02
  done
}

# A USB mass-storage drive sitting in usb-storage's delay_use timer (host0
# exists, no target*/LUN yet): wait until the SCSI block device appears, settle
# udev so the by-label symlink lands, and load the cidata pair.
new_sandbox
write_required_pair
add_usb_interface 1-2:1.0 08 usb-storage
mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0"
(
  wait_for_sleep_call
  mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0"
  printf '0\n' >"$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/type"
  mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/block/sda"
) &
helper=$!
OMARCHY_CIDATA_WAIT_TIMEOUT=3 OMARCHY_CIDATA_WAIT_POLL=0.05 \
  UDEV_TRIGGER_PATH="$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/block/sda" \
  UDEV_CREATE_LABEL="$sandbox/dev/disk/by-label/CIDATA" \
  UDEV_TARGET="$sandbox/media" \
  run_load || { kill "$helper" 2>/dev/null || true; wait "$helper" 2>/dev/null || true; fail "pending usb-storage interface waits and loads"; }
wait "$helper"
grep -q '^sleep ' "$TEST_LOG" || fail "pending usb-storage interface waited before settling"
grep -q '^udevadm settle$' "$TEST_LOG" || fail "pending usb-storage interface settled udev"
[[ -f $sandbox/root/user_configuration.json && -f $sandbox/root/user_credentials.json ]] || fail "pending usb-storage interface copied required pair"
pass "pending usb-storage interface waits, settles udev, and loads"

# A USB mass-storage interface whose driver module has not bound yet (no driver
# symlink): wait through driver bind, host/LUN probe, and block device creation.
new_sandbox
write_required_pair
add_usb_interface 1-2:1.0 08
(
  wait_for_sleep_call
  mkdir -p "$sandbox/sys/bus/usb/drivers/usb-storage"
  ln -s "$sandbox/sys/bus/usb/drivers/usb-storage" "$sandbox/sys/bus/usb/devices/1-2:1.0/driver"
  "$REAL_SLEEP" 0.05
  mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0"
  printf '0\n' >"$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/type"
  mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/block/sda"
) &
helper=$!
OMARCHY_CIDATA_WAIT_TIMEOUT=3 OMARCHY_CIDATA_WAIT_POLL=0.05 \
  UDEV_TRIGGER_PATH="$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/block/sda" \
  UDEV_CREATE_LABEL="$sandbox/dev/disk/by-label/CIDATA" \
  UDEV_TARGET="$sandbox/media" \
  run_load || { kill "$helper" 2>/dev/null || true; wait "$helper" 2>/dev/null || true; fail "unbound USB mass-storage interface waits and loads"; }
wait "$helper"
grep -q '^sleep ' "$TEST_LOG" || fail "unbound USB mass-storage interface waited"
[[ -f $sandbox/root/user_configuration.json && -f $sandbox/root/user_credentials.json ]] || fail "unbound USB mass-storage interface copied required pair"
pass "unbound USB mass-storage interface waits for driver, LUN, block device, and loads"

# An already-enumerated USB stick (like the live boot medium) with no cidata
# label must fall back immediately without sleeping.
new_sandbox
add_usb_interface 1-1:1.0 08 usb-storage
mkdir -p "$sandbox/sys/bus/usb/devices/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sda"
printf '0\n' >"$sandbox/sys/bus/usb/devices/1-1:1.0/host0/target0:0:0/0:0:0:0/type"
! OMARCHY_CIDATA_WAIT_TIMEOUT=10 run_load || fail "enumerated USB stick without cidata exits non-zero"
! grep -q '^sleep ' "$TEST_LOG" || fail "enumerated USB stick without cidata does not sleep"
pass "already-enumerated USB stick without cidata exits immediately without sleeping"

# Non-storage USB (HID class 03), unauthorized class-08 USB (authorized=0),
# class-08 USB bound to a non-storage driver (usbfs), and non-block SCSI LUNs
# (type 13 enclosure with no block/ child) must not trigger any wait.
new_sandbox
add_usb_interface 1-1:1.0 03
add_usb_interface 1-2:1.0 08
printf '0\n' >"$sandbox/sys/bus/usb/devices/1-2:1.0/authorized"
add_usb_interface 1-3:1.0 08 usbfs
add_usb_interface 1-4:1.0 08 usb-storage
mkdir -p "$sandbox/sys/bus/usb/devices/1-4:1.0/host0/target0:0:0/0:0:0:0"
printf '13\n' >"$sandbox/sys/bus/usb/devices/1-4:1.0/host0/target0:0:0/0:0:0:0/type"
! OMARCHY_CIDATA_WAIT_TIMEOUT=10 run_load || fail "non-storage/unauthorized/enclosure USB exits non-zero"
! grep -q '^sleep ' "$TEST_LOG" || fail "non-storage/unauthorized/enclosure USB does not sleep"
pass "non-storage, unauthorized, non-storage-driver, and enclosure USB devices do not wait"

# A hung 0-LUN USB mass-storage device must not hang the boot: wait is bounded
# by OMARCHY_CIDATA_WAIT_TIMEOUT and falls back cleanly to the wizard. Use 2 s
# so an integer SECONDS tick right after startup cannot skip the first sleep.
new_sandbox
add_usb_interface 1-2:1.0 08 usb-storage
mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0"
! OMARCHY_CIDATA_WAIT_TIMEOUT=2 OMARCHY_CIDATA_WAIT_POLL=0.05 run_load || fail "hung 0-LUN USB device exits non-zero"
grep -q '^sleep ' "$TEST_LOG" || fail "hung 0-LUN USB device waited until timeout"
! grep -q '^mount ' "$TEST_LOG" || fail "hung 0-LUN USB device mounts nothing"
(( $(grep -c '^udevadm settle$' "$TEST_LOG") == 1 )) || fail "hung 0-LUN USB device settles udev once after deadline"
pass "hung 0-LUN USB mass-storage device times out cleanly and falls back"

# When CIDATA is already present, an unrelated hung 0-LUN USB mass-storage
# device must not delay loading it.
new_sandbox
attach_drive CIDATA
write_required_pair
add_usb_interface 1-2:1.0 08 usb-storage
mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0"
OMARCHY_CIDATA_WAIT_TIMEOUT=10 run_load || fail "already-present CIDATA loads alongside hung USB device"
! grep -q '^sleep ' "$TEST_LOG" || fail "already-present CIDATA does not sleep for hung USB device"
[[ -f $sandbox/root/user_configuration.json && -f $sandbox/root/user_credentials.json ]] || fail "already-present CIDATA copied required pair"
pass "already-present CIDATA loads immediately without waiting on hung USB device"

# A USB mass-storage interface (uas) that arrives during the initial udevadm
# settle is caught on the follow-up pass, waited on, and settled again.
new_sandbox
write_required_pair
(
  for _ in $(seq 1 150); do
    [[ -e $sandbox/step-b-settled ]] && break
    "$REAL_SLEEP" 0.02
  done
  wait_for_sleep_call
  mkdir -p "$sandbox/sys/bus/usb/devices/1-3:1.0/host1/target1:0:0/1:0:0:0"
  printf '0\n' >"$sandbox/sys/bus/usb/devices/1-3:1.0/host1/target1:0:0/1:0:0:0/type"
  mkdir -p "$sandbox/sys/bus/usb/devices/1-3:1.0/host1/target1:0:0/1:0:0:0/block/sdb"
) &
helper=$!
OMARCHY_CIDATA_WAIT_TIMEOUT=3 OMARCHY_CIDATA_WAIT_POLL=0.05 \
  UDEV_ON_SETTLE_HOOK="if [[ ! -e '$sandbox/step-b-settled' ]]; then mkdir -p '$sandbox/sys/bus/usb/devices/1-3:1.0/host1' '$sandbox/sys/bus/usb/drivers/uas'; printf '08\n' >'$sandbox/sys/bus/usb/devices/1-3:1.0/bInterfaceClass'; ln -s '$sandbox/sys/bus/usb/drivers/uas' '$sandbox/sys/bus/usb/devices/1-3:1.0/driver'; : >'$sandbox/step-b-settled'; fi" \
  UDEV_TRIGGER_PATH="$sandbox/sys/bus/usb/devices/1-3:1.0/host1/target1:0:0/1:0:0:0/block/sdb" \
  UDEV_CREATE_LABEL="$sandbox/dev/disk/by-label/CIDATA" \
  UDEV_TARGET="$sandbox/media" \
  run_load || { kill "$helper" 2>/dev/null || true; wait "$helper" 2>/dev/null || true; fail "late-arriving uas interface waits and loads"; }
wait "$helper"
grep -q '^sleep ' "$TEST_LOG" || fail "late-arriving uas interface waited"
(( $(grep -c '^udevadm settle$' "$TEST_LOG") == 2 )) || fail "late-arriving uas interface settled udev twice"
[[ -f $sandbox/root/user_configuration.json && -f $sandbox/root/user_credentials.json ]] || fail "late-arriving uas interface copied required pair"
pass "late-arriving uas interface during udev settle is caught and loads"

# device_add_disk() creates block/<dev> with uevent_suppress=1 before scanning
# partitions and emitting KOBJ_ADD: when /run/udev/data exists, wait until
# udevd has written b<maj>:<min> for the disk (and its partitions) rather than
# settling while KOBJ_ADD is still suppressed.
new_sandbox
write_required_pair
mkdir -p "$sandbox/run/udev/data"
add_usb_interface 1-2:1.0 08 usb-storage
mkdir -p "$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/block/sda/sda1"
printf '0\n' >"$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/type"
printf '8:0\n' >"$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/block/sda/dev"
printf '8:1\n' >"$sandbox/sys/bus/usb/devices/1-2:1.0/host0/target0:0:0/0:0:0:0/block/sda/sda1/dev"
(
  wait_for_sleep_call
  : >"$sandbox/run/udev/data/b8:0"
  "$REAL_SLEEP" 0.05
  : >"$sandbox/run/udev/data/b8:1"
  ln -s "$sandbox/media" "$sandbox/dev/disk/by-label/CIDATA"
) &
helper=$!
OMARCHY_CIDATA_WAIT_TIMEOUT=3 OMARCHY_CIDATA_WAIT_POLL=0.05 \
  run_load || { kill "$helper" 2>/dev/null || true; wait "$helper" 2>/dev/null || true; fail "suppressed KOBJ_ADD waits for udev db and loads"; }
wait "$helper"
grep -q '^sleep ' "$TEST_LOG" || fail "suppressed KOBJ_ADD waited for /run/udev/data/b8:1"
[[ -f $sandbox/root/user_configuration.json && -f $sandbox/root/user_credentials.json ]] || fail "suppressed KOBJ_ADD copied required pair"
pass "block device with suppressed KOBJ_ADD waits for udev database entry before settling"

# When /run/udev/data already has b<maj>:<min> for an enumerated non-cidata USB
# stick, no sleep happens.
new_sandbox
mkdir -p "$sandbox/run/udev/data"
add_usb_interface 1-1:1.0 08 usb-storage
mkdir -p "$sandbox/sys/bus/usb/devices/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sda"
printf '0\n' >"$sandbox/sys/bus/usb/devices/1-1:1.0/host0/target0:0:0/0:0:0:0/type"
printf '8:0\n' >"$sandbox/sys/bus/usb/devices/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sda/dev"
: >"$sandbox/run/udev/data/b8:0"
! OMARCHY_CIDATA_WAIT_TIMEOUT=10 run_load || fail "udev-recorded non-cidata USB exits non-zero"
! grep -q '^sleep ' "$TEST_LOG" || fail "udev-recorded non-cidata USB does not sleep"
pass "udev-recorded USB stick without cidata exits immediately without sleeping"
