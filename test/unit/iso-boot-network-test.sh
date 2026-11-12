#!/bin/bash
# Exercise the real launcher without installing packages or starting a VM.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$work/stubs" "$work/home"
disk="$work/not a disk.qcow2"
vars="$work/not firmware.fd"
iso="$work/not an iso.iso"
printf 'disk sentinel\n' >"$disk"
printf 'firmware sentinel\n' >"$vars"
printf 'iso sentinel\n' >"$iso"

cat >"$work/stubs/uname" <<'STUB'
#!/bin/bash
printf 'x86_64\n'
STUB
cat >"$work/stubs/nproc" <<'STUB'
#!/bin/bash
printf '4\n'
STUB
cat >"$work/stubs/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >>"$TEST_PKG_LOG"
STUB
cat >"$work/stubs/qemu-system-x86_64" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >>"$TEST_ARGV_LOG"
STUB
# Even if disk reuse or session detection regresses, no real setup may run.
for command in qemu-img cp systemctl gum taskset qemu-system-aarch64; do
  cat >"$work/stubs/$command" <<'STUB'
#!/bin/bash
printf 'unexpected helper: %s\n' "$0" >&2
exit 99
STUB
done
chmod +x "$work/stubs"/*

launch_env=()
run_boot() {
  # No inherited environment, exported functions, or host PATH fallback: a
  # missing stub must fail with command-not-found, not find a real helper.
  /usr/bin/env -i PATH="$work/stubs" HOME="$work/home" \
    WAYLAND_DISPLAY=mock-only TEST_ARGV_LOG="$work/argv" TEST_PKG_LOG="$work/pkg" \
    "${launch_env[@]}" /bin/bash "$ROOT/bin/omarchy-iso-boot" \
    --reuse --disk "$disk" --ovmf-vars "$vars" "$iso" "$@" \
    >"$work/stdout" 2>"$work/stderr"
}

launch() {
  rm -f "$work/argv" "$work/pkg"
  run_boot "$@" || fail "launcher failed: $(<"$work/stderr")"
  [[ -s $work/argv ]] || fail "launcher did not reach the QEMU stub"
  [[ -s $work/pkg ]] || fail "launcher did not call the package helper stub"
  [[ $(<"$disk") == "disk sentinel" && $(<"$vars") == "firmware sentinel" && $(<"$iso") == "iso sentinel" ]] ||
    fail "launcher modified a sentinel"
}

failures=0
check_network() {
  local description=$1 i
  shift
  local -a argv network=()
  mapfile -d '' -t argv <"$work/argv"
  for ((i = 0; i < ${#argv[@]}; i++)); do
    case "${argv[i]}" in
      -nic|-net|-netdev)
        network+=("${argv[i]}" "${argv[i+1]}")
        ((i += 1))
        ;;
      -device)
        if [[ ${argv[i+1]} == *net* ]]; then
          network+=("${argv[i]}" "${argv[i+1]}")
        fi
        ((i += 1))
        ;;
    esac
  done
  printf '%s\0' "$@" >"$work/expected-network"
  printf '%s\0' "${network[@]}" >"$work/actual-network"
  if cmp -s "$work/expected-network" "$work/actual-network"; then
    pass "$description"
  else
    printf 'not ok - %s (network argv: %s)\n' "$description" "${network[*]}" >&2
    ((failures += 1))
  fi
}

launch
check_network "default SSH forwarding" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0
launch_env=(OMARCHY_VM_SSH_PORT=0)
launch
check_network "SSH port zero keeps user networking without forwarding" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0

launch_env=()
for option in --no-network --no-net; do
  launch "$option"
  check_network "$option explicitly disables the NIC" -nic none
done
grep -qx 'Networking disabled.' "$work/stdout" || fail "--no-network did not report networking disabled"
pass "--no-network reports networking disabled"
for value in 0 false no off OFF False NO; do
  launch_env=("OMARCHY_VM_NETWORK=$value")
  launch
  check_network "OMARCHY_VM_NETWORK=$value explicitly disables the NIC" -nic none
done

# Raw arguments remain last and intact, even when the caller deliberately
# adds a NIC. --no-network must not reinterpret this escape hatch.
launch_env=()
launch --no-network -- -nic 'user,model=virtio-net-pci' -name 'raw guest name'
check_network "raw QEMU networking arguments remain available" -nic none -nic user,model=virtio-net-pci
mapfile -d '' -t argv <"$work/argv"
[[ ${argv[*]: -4} == "-nic user,model=virtio-net-pci -name raw guest name" && ${argv[-1]} == "raw guest name" ]] ||
  fail "raw QEMU arguments did not remain last and intact"
pass "raw QEMU arguments retain order and argument boundaries"
grep -qx 'Networking disabled, except what the QEMU arguments after -- add.' "$work/stdout" ||
  fail "raw QEMU networking was reported as fully disabled"
pass "raw QEMU networking is reported, not called disabled"

# Prove that removing either critical stub cannot fall back to the host.
for helper in omarchy-pkg-add qemu-system-x86_64; do
  mv "$work/stubs/$helper" "$work/$helper"
  rm -f "$work/argv"
  status=0
  run_boot --no-network || status=$?
  mv "$work/$helper" "$work/stubs/$helper"
  [[ $status == 127 && ! -e $work/argv ]] || fail "missing $helper did not fail closed"
  pass "missing $helper fails closed"
done

(( failures == 0 )) || fail "$failures network cases failed"
