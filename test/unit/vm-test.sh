#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

TEST_REPO="$TEST_TMP/repo"
TEST_BIN="$TEST_REPO/bin"
STUB_BIN="$TEST_TMP/stubs"
VM_DIR="$TEST_TMP/vms"
ACTIVE_DIR="$TEST_TMP/active"
CALL_LOG="$TEST_TMP/calls.log"
SSH_COUNT="$TEST_TMP/ssh-count"

mkdir -p "$TEST_BIN" "$STUB_BIN" "$VM_DIR" "$ACTIVE_DIR"
cp "$ROOT/bin/omarchy-vm" "$TEST_BIN/omarchy-vm"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

cat >"$STUB_BIN/gum" <<'STUB'
#!/bin/bash
case "$1" in
  confirm)
    exit "${GUM_CONFIRM_STATUS:-0}"
    ;;
  choose)
    printf 'gum\tchoose\n' >>"$TEST_CALL_LOG"
    head -n 1
    ;;
  input)
    printf '%s\n' "${GUM_INPUT_VALUE:-}"
    ;;
  style)
    shift
    printf '%s\n' "$@"
    ;;
esac
STUB

cat >"$STUB_BIN/qemu-img" <<'STUB'
#!/bin/bash
exit "${QEMU_IMG_STATUS:-0}"
STUB

cat >"$STUB_BIN/ssh" <<'STUB'
#!/bin/bash
printf 'ssh' >>"$TEST_CALL_LOG"
for arg in "$@"; do
  printf '\t%s' "$arg" >>"$TEST_CALL_LOG"
done
printf '\n' >>"$TEST_CALL_LOG"

for arg in "$@"; do
  [[ $arg == "-tt" ]] && exit 0
done

count=0
[[ ! -f $TEST_SSH_COUNT ]] || count=$(<"$TEST_SSH_COUNT")
((count += 1))
printf '%s\n' "$count" >"$TEST_SSH_COUNT"
[[ $count == 2 ]] && exit 1
exit 0
STUB

cat >"$TEST_BIN/omarchy-iso-boot" <<'STUB'
#!/bin/bash
pidfile=""
previous=""
printf 'iso-boot' >>"$TEST_CALL_LOG"
for arg in "$@"; do
  printf '\t%s' "$arg" >>"$TEST_CALL_LOG"
  if [[ $previous == "-pidfile" ]]; then
    pidfile="$arg"
  fi
  previous="$arg"
done
printf '\n' >>"$TEST_CALL_LOG"

if [[ -n $pidfile ]]; then
  printf '%s\n' "$$" >"$pidfile"
  trap 'rm -f "$pidfile"' EXIT
fi

if [[ ${TEST_WAIT_FOR_METADATA:-0} == 1 ]]; then
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -f ${OMARCHY_VM_DISK}.omarchy-vm.json ]] && exit 0
    sleep 0.05
  done
  exit 1
fi
STUB

chmod +x "$TEST_BIN/omarchy-vm" "$TEST_BIN/omarchy-iso-boot" "$STUB_BIN"/*
: >"$CALL_LOG"
: >"$SSH_COUNT"

run_vm() {
  PATH="$STUB_BIN:$PATH" \
    OMARCHY_VM_DIR="$VM_DIR" \
    OMARCHY_VM_DISK="$ACTIVE_DIR/disk.qcow2" \
    OMARCHY_VM_OVMF_VARS="$ACTIVE_DIR/OVMF_VARS.fd" \
    OMARCHY_VM_SSH_IDENTITY="$ACTIVE_DIR/id_ed25519" \
    OMARCHY_VM_TTY=/dev/null \
    OMARCHY_VM_SSH_TIMEOUT=5 \
    TEST_CALL_LOG="$CALL_LOG" \
    TEST_SSH_COUNT="$SSH_COUNT" \
    "$TEST_BIN/omarchy-vm" "$@"
}

make_workspace() {
  local path="$1"
  mkdir -p \
    "$path/omarchy/bin" \
    "$path/omarchy/default" \
    "$path/omarchy/shell" \
    "$path/omarchy-pkgs/bin" \
    "$path/omarchy-pkgs/pkgbuilds"
}

write_snapshot() {
  local name="$1"
  mkdir -p "$VM_DIR/$name"
  printf 'disk-%s\n' "$name" >"$VM_DIR/$name/omarchy-iso-boot.qcow2"
  printf 'ovmf-%s\n' "$name" >"$VM_DIR/$name/OVMF_VARS.4m.fd"
}

write_metadata() {
  local destination="$1" workspace="$2" user="$3"
  jq -n \
    --arg path "$workspace" \
    --arg user "$user" \
    --argjson uid "$(id -u)" \
    --argjson gid "$(id -g)" \
    '{version: 1, dev_link: {host_path: $path, ssh_user: $user, host_uid: $uid, host_gid: $gid}}' >"$destination"
}

workspace="$TEST_TMP/development, workspace"
replacement="$TEST_TMP/replacement workspace"
make_workspace "$workspace"
make_workspace "$replacement"
write_snapshot linked
write_metadata "$VM_DIR/linked/vm.json" "$workspace" developer

run_vm boot linked >/dev/null

expected_fsdev="local,id=omarchy_dev_link,path=${workspace//,/,,},security_model=none,multidevs=remap"
grep -F $'iso-boot\t/dev/null\treuse\t--' "$CALL_LOG" >/dev/null ||
  fail "linked snapshot passes raw QEMU arguments after the boot media"
grep -F "$expected_fsdev" "$CALL_LOG" >/dev/null || fail "linked snapshot restores and escapes the host workspace"
grep -F 'virtio-9p-pci,fsdev=omarchy_dev_link,mount_tag=dev-link' "$CALL_LOG" >/dev/null ||
  fail "linked snapshot restores the fixed 9p mount tag"
jq -e --arg path "$workspace" '.dev_link.host_path == $path and .dev_link.ssh_user == "developer"' \
  "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json" >/dev/null || fail "linked snapshot restores active metadata"
[[ ! -e $ACTIVE_DIR/disk.qcow2.omarchy-vm.pid ]] || fail "launcher removes its active-state marker"
pass "saved dev-link metadata is replayed"

printf 'current-disk\n' >"$ACTIVE_DIR/disk.qcow2"
printf 'current-ovmf\n' >"$ACTIVE_DIR/OVMF_VARS.fd"
: >"$CALL_LOG"
run_vm boot --ssh-port 2299 >/dev/null
grep -F $'iso-boot\t--ssh-port\t2299\t/dev/null\treuse\t--' "$CALL_LOG" >/dev/null ||
  fail "current VM does not receive boot options in reuse mode"
grep -F "$expected_fsdev" "$CALL_LOG" >/dev/null || fail "current VM does not restore its dev-link metadata"
grep -F $'gum\tchoose' "$CALL_LOG" >/dev/null && fail "current VM unexpectedly opens the snapshot chooser"
[[ $(<"$ACTIVE_DIR/disk.qcow2") == current-disk ]] || fail "current VM disk is replaced before boot"
[[ $(<"$ACTIVE_DIR/OVMF_VARS.fd") == current-ovmf ]] || fail "current VM OVMF vars are replaced before boot"
pass "boot without a snapshot name reuses the current VM"

: >"$CALL_LOG"
run_vm boot --dev-link "$replacement" >/dev/null
grep -F "path=$replacement,security_model=none" "$CALL_LOG" >/dev/null || fail "current VM does not accept a dev-link override"
jq -e --arg path "$replacement" '.dev_link.host_path == $path' "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json" >/dev/null ||
  fail "current VM dev-link override does not update active metadata"
pass "current VM dev-link path can be overridden"

rm "$ACTIVE_DIR/disk.qcow2" "$ACTIVE_DIR/OVMF_VARS.fd" "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json"
: >"$CALL_LOG"
run_vm boot >/dev/null
grep -F $'gum\tchoose' "$CALL_LOG" >/dev/null || fail "missing current VM does not fall back to snapshot selection"
[[ $(<"$ACTIVE_DIR/disk.qcow2") == disk-linked ]] || fail "snapshot fallback does not restore the selected disk"
pass "boot falls back to snapshot selection when no current VM exists"

rm "$ACTIVE_DIR/OVMF_VARS.fd"
: >"$CALL_LOG"
if run_vm boot >"$TEST_TMP/incomplete-current.out" 2>"$TEST_TMP/incomplete-current.err"; then
  fail "incomplete current VM is accepted"
fi
grep -F 'current VM is incomplete' "$TEST_TMP/incomplete-current.err" >/dev/null ||
  fail "incomplete current VM failure is unclear" "$(<"$TEST_TMP/incomplete-current.err")"
grep -F $'iso-boot\t' "$CALL_LOG" >/dev/null && fail "incomplete current VM reaches the launcher"
pass "boot rejects an incomplete current VM"

: >"$CALL_LOG"
run_vm boot linked --dev-link "$replacement" >/dev/null
grep -F "path=$replacement,security_model=none" "$CALL_LOG" >/dev/null || fail "explicit dev-link path overrides saved metadata"
jq -e --arg path "$replacement" '.dev_link.host_path == $path' "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json" >/dev/null ||
  fail "path override updates active metadata"
jq -e --arg path "$workspace" '.dev_link.host_path == $path' "$VM_DIR/linked/vm.json" >/dev/null ||
  fail "path override leaves the named snapshot unchanged"
pass "saved dev-link path can be overridden per active VM"

write_snapshot legacy
: >"$CALL_LOG"
run_vm boot legacy >/dev/null
grep -F 'omarchy_dev_link' "$CALL_LOG" >/dev/null && fail "legacy snapshot unexpectedly receives a dev share"
[[ ! -e $ACTIVE_DIR/disk.qcow2.omarchy-vm.json ]] || fail "legacy snapshot clears stale active metadata"
pass "legacy snapshots remain unlinked"

: >"$CALL_LOG"
run_vm boot >/dev/null
grep -F 'omarchy_dev_link' "$CALL_LOG" >/dev/null && fail "unlinked current VM unexpectedly receives a dev share"
grep -F $'gum\tchoose' "$CALL_LOG" >/dev/null && fail "unlinked current VM unexpectedly opens the snapshot chooser"
pass "unlinked current VM boots without a development share"

write_snapshot missing
write_metadata "$VM_DIR/missing/vm.json" "$TEST_TMP/no-longer-here" developer
if run_vm boot missing >"$TEST_TMP/missing.out" 2>"$TEST_TMP/missing.err"; then
  fail "missing saved dev-link path is accepted"
fi
grep -F 'override it with --dev-link NEW_PATH' "$TEST_TMP/missing.err" >/dev/null ||
  fail "missing saved path explains the recovery override" "$(<"$TEST_TMP/missing.err")"
pass "missing saved dev-link paths fail before boot"

incomplete_workspace="$TEST_TMP/incomplete-workspace"
mkdir -p "$incomplete_workspace/omarchy/bin" "$incomplete_workspace/omarchy/default" "$incomplete_workspace/omarchy/shell"
write_snapshot incomplete
write_metadata "$VM_DIR/incomplete/vm.json" "$incomplete_workspace" developer
if run_vm boot incomplete >"$TEST_TMP/incomplete.out" 2>"$TEST_TMP/incomplete.err"; then
  fail "dev-link workspace without omarchy-pkgs is accepted"
fi
grep -F 'missing omarchy-pkgs/bin/' "$TEST_TMP/incomplete.err" >/dev/null ||
  fail "incomplete workspace failure does not identify the missing package repository" "$(<"$TEST_TMP/incomplete.err")"
pass "dev-link paths must contain both repositories"

write_snapshot malformed
printf '{not-json\n' >"$VM_DIR/malformed/vm.json"
if run_vm boot malformed >"$TEST_TMP/malformed.out" 2>"$TEST_TMP/malformed.err"; then
  fail "malformed snapshot metadata is accepted"
fi
grep -F 'invalid or unsupported VM metadata' "$TEST_TMP/malformed.err" >/dev/null ||
  fail "malformed metadata failure is unclear"
pass "malformed snapshot metadata fails before boot"

printf 'active-disk\n' >"$ACTIVE_DIR/disk.qcow2"
printf 'active-ovmf\n' >"$ACTIVE_DIR/OVMF_VARS.fd"
write_metadata "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json" "$workspace" developer
run_vm save saved >/dev/null
cmp "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json" "$VM_DIR/saved/vm.json" >/dev/null ||
  fail "save does not copy active metadata"
rm "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json"
run_vm save saved >/dev/null
[[ ! -e $VM_DIR/saved/vm.json ]] || fail "overwrite retains stale dev-link metadata"
pass "save publishes and clears metadata with its snapshot"

printf '%s\n' "$$" >"$ACTIVE_DIR/disk.qcow2.omarchy-vm.pid"
if run_vm save running >"$TEST_TMP/running.out" 2>"$TEST_TMP/running.err"; then
  fail "save accepts a running VM"
fi
grep -F 'cannot save while the active VM is running' "$TEST_TMP/running.err" >/dev/null ||
  fail "running save failure is unclear"
rm "$ACTIVE_DIR/disk.qcow2.omarchy-vm.pid"
pass "save refuses a running VM"

if run_vm save ../escape >"$TEST_TMP/name.out" 2>"$TEST_TMP/name.err"; then
  fail "unsafe snapshot name is accepted"
fi
pass "snapshot names cannot escape the VM directory"

if run_vm create --dev-link "$workspace" fake.iso >"$TEST_TMP/create.out" 2>"$TEST_TMP/create.err"; then
  fail "dev-linked create without cidata is accepted"
fi
grep -F 'requires --cidata-dir' "$TEST_TMP/create.err" >/dev/null || fail "create does not explain its SSH provisioning requirement"
pass "dev-linked creation requires cidata SSH provisioning"

write_snapshot activation
touch "$ACTIVE_DIR/id_ed25519"
: >"$CALL_LOG"
: >"$SSH_COUNT"
TEST_WAIT_FOR_METADATA=1 run_vm boot activation --dev-link "$workspace" --ssh-user developer >"$TEST_TMP/activation.out"
grep -F 'Guest sudo authentication required' "$TEST_TMP/activation.out" >/dev/null ||
  fail "activation does not prominently announce the upcoming sudo prompt"
grep -F $'ssh\t-tt' "$CALL_LOG" >/dev/null || fail "activation does not allocate a TTY for sudo"
if ! grep -F 'mount_point=/mnt/dev-link' "$CALL_LOG" >/dev/null ||
  ! grep -F "omarchy_path=\"\$mount_point/omarchy\"" "$CALL_LOG" >/dev/null ||
  ! grep -F "packages_path=\"\$mount_point/omarchy-pkgs\"" "$CALL_LOG" >/dev/null ||
  ! grep -F "omarchy dev link \"\$omarchy_path\" --no-reboot" "$CALL_LOG" >/dev/null; then
  fail "activation does not mount the workspace and link its Omarchy repository"
fi
grep -F 'x-systemd.automount' "$CALL_LOG" >/dev/null || fail "activation does not persist the managed automount"
grep -F '/usr/bin/systemctl reboot' "$CALL_LOG" >/dev/null || fail "activation does not schedule the required reboot"
jq -e --arg path "$workspace" '.dev_link.host_path == $path and .dev_link.ssh_user == "developer"' \
  "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json" >/dev/null || fail "successful activation does not create metadata"
jq -e 'keys == ["dev_link", "version"] and (.dev_link | keys == ["host_gid", "host_path", "host_uid", "ssh_user"])' \
  "$ACTIVE_DIR/disk.qcow2.omarchy-vm.json" >/dev/null || fail "metadata stores unrelated launch settings"
pass "first-time dev-link activation is automated over interactive SSH"
