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

cat >"$stub_dir/udevadm" <<'STUB'
#!/bin/bash
printf 'udevadm %s\n' "$*" >>"$TEST_LOG"
STUB

cat >"$stub_dir/mount" <<'STUB'
#!/bin/bash
printf 'mount %s\n' "$*" >>"$TEST_LOG"
[[ ${MOUNT_FAIL:-} == 1 ]] && exit 32
# MOUNT_FAIL_DIRECT fakes a whole-disk boot medium holding the partition:
# only the direct device mount fails; the loop mount of the copy works.
[[ ${MOUNT_FAIL_DIRECT:-} == 1 && $* != *loop* ]] && exit 32
device=$3 mountpoint=$4
if [[ $device == *.img ]]; then
  cp -a "$FAKE_DEVICE_DIR"/. "$mountpoint"/
else
  cp -a "$(readlink -f "$device")"/. "$mountpoint"/
fi
STUB

cat >"$stub_dir/dd" <<'STUB'
#!/bin/bash
printf 'dd %s\n' "$*" >>"$TEST_LOG"
for a in "$@"; do case $a in of=*) : >"${a#of=}" ;; esac; done
STUB

cat >"$stub_dir/umount" <<'STUB'
#!/bin/bash
printf 'umount %s\n' "$*" >>"$TEST_LOG"
STUB

chmod +x "$stub_dir"/*

new_sandbox() {
  sandbox=$(mktemp -d "$work/sandbox.XXXXXX")
  mkdir -p "$sandbox/dev/disk/by-label" "$sandbox/root" "$sandbox/media" "$sandbox/run"
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
echo "Jeff" >"$sandbox/media/user_full_name.txt"
echo "jeff@example.com" >"$sandbox/media/user_email_address.txt"
echo "false" >"$sandbox/media/user_encrypt_installation.txt"
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
echo 'tskey-auth-kFAKEKEY' >"$sandbox/media/tailscale_authkey"
run_load || fail "full file set loads"
for file in user_configuration.json user_credentials.json user_full_name.txt user_email_address.txt user_encrypt_installation.txt authorized_keys tailscale_authkey; do
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
[[ ! -e $sandbox/root/user_full_name.txt ]] || fail "absent optional files are not copied"
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

# A whole-disk boot medium holds every partition exclusively: the direct
# mount fails, but plain reads still work, so the loader copies the device
# into /run and loop-mounts the copy.
new_sandbox
attach_drive cidata
write_required_pair
MOUNT_FAIL_DIRECT=1 FAKE_DEVICE_DIR="$sandbox/media" run_load || fail "held partition still loads"
grep -q '^dd ' "$TEST_LOG" || fail "held partition is copied with dd"
grep -q 'loop' "$TEST_LOG" || fail "the copy is loop-mounted"
[[ -f $sandbox/root/user_configuration.json ]] || fail "the copy delivers the files"
[[ ! -e $sandbox/run/cidata.img ]] || fail "the image copy is cleaned up"
pass "a held partition falls back to a copied image"

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
