# The accelerator QEMU uses on this host, as the arguments the aarch64 test
# scripts splice into their command lines. Sourced by test/arm64-install and
# test/arm64-live-boot so the two cannot disagree about it.
#
# A Linux host virtualises with KVM. Apple Silicon has no /dev/kvm: QEMU drives
# the hypervisor framework instead, which takes the same -cpu host and the same
# virt machine, so only the accelerator changes.
#
# Sets QEMU_ACCEL, or returns 1 when the host has neither.
qemu_accel() {
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ACCEL=(-accel kvm -cpu host)
  elif [[ $(uname -s) == Darwin ]]; then
    QEMU_ACCEL=(-accel hvf -cpu host)
  else
    echo "qemu-accel: no usable accelerator: /dev/kvm is not readable and writable, and this is not a Mac" >&2
    return 1
  fi
}
