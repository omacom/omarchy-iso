#!/bin/bash
#
# test/install-test-arches decides which architectures' install tests a pull
# request runs. A path it does not know must run both: a wrong guess costs
# test time, never a test.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
arches="$ROOT/test/install-test-arches"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { # description, expected output, paths...
  local what=$1 want=$2 got
  shift 2
  got=$(printf '%s\n' "$@" | "$arches" | paste -sd' ')
  [[ $got == "$want" ]] || fail "$what: got '$got', expected '$want'"
}

both="x86_64=true aarch64=true"
x86="x86_64=true aarch64=false"
arm="x86_64=false aarch64=true"
none="x86_64=false aarch64=false"

expect "documentation and unit tests build no ISO" "$none" README.md builder/qualcomm/README.md plans/x.md test/unit/foo-test.sh
expect "no paths at all" "$none"
expect "the nightly's own files" "$none" .github/workflows/nightly-build.yml test/vm-image/nightly-plan
expect "the aarch64 package filter (omarchy-iso#524)" "$arm" builder/aarch64-package-filter.sh test/unit/aarch64-build-test.sh
expect "the Snapdragon live startup" "$arm" builder/qualcomm/early-startup builder/qcom-oem-firmware.sh
expect "the aarch64 install test (omarchy-iso#523)" "$arm" test/arm64-install
expect "an aarch64 channel's mirrors" "$arm" configs/pacman-online-aarch64-edge.conf
expect "x86_64's aarch64-only exclusions are x86_64's" "$x86" builder/aarch64-only.packages
expect "an x86_64 channel's mirrors" "$x86" configs/pacman-online-edge.conf
expect "the x86_64 install scenarios" "$x86" test/integration.d/pxe-test.sh test/integration
expect "the scenario helpers the aarch64 install test borrows" "$both" test/integration.d/base-test.sh
expect "the shared ISO builder (omarchy-iso#522)" "$both" builder/build-iso.sh bin/omarchy-iso-make
expect "the installer" "$both" configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py
expect "the install test workflow itself" "$both" .github/workflows/install-test.yml
expect "a path no rule names" "$both" something/new.sh
expect "one shared path among aarch64 ones" "$both" builder/qualcomm/live-uki.sh builder/build-root-image.sh
expect "an aarch64 path and an x86_64 one" "$both" builder/arm64-kernel-image.sh configs/syslinux/archiso_sys.cfg

echo "ok - install-test-arches picks the architectures a change touches"
