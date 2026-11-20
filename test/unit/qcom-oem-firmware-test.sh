#!/bin/bash
#
# qcom_oem_firmware_packages finds the Snapdragon OEM firmware packages in a
# repository database by the qcom-firmware-<folder> name each provides.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/builder/qcom-oem-firmware.sh"

# desc <dir> <name> [provides...]: one package entry the way repo-add writes it
desc() {
  local dir=$1 name=$2
  shift 2
  mkdir -p "$fixture/db/$dir"
  {
    printf '%%FILENAME%%\n%s-1-1-aarch64.pkg.tar.zst\n\n' "$name"
    printf '%%NAME%%\n%s\n\n' "$name"
    printf '%%VERSION%%\n1-1\n\n'
    if (($#)); then
      printf '%%PROVIDES%%\n'
      printf '%s\n' "$@"
      printf '\n'
    fi
    printf '%%ARCH%%\naarch64\n\n'
  } >"$fixture/db/$dir/desc"
}

desc acer-aspire-14-ai-firmware-20261102-2 acer-aspire-14-ai-firmware qcom-firmware-x1p42100-acer-a14-11m
desc asus-zenbook-a14-firmware-20261102-3 asus-zenbook-a14-firmware \
  qcom-firmware-x1e80100-asustek-zenbook-a14 qcom-firmware-x1p42100-asustek-zenbook-a14
desc linux-omarchy-7.3-19 linux-omarchy linux=7.3 WIREGUARD-MODULE
desc omarchy-settings-3.2-1 omarchy-settings
(cd "$fixture/db" && bsdtar -czf "$fixture/omarchy.db" -- *)

mkdir -p "$fixture/other/hello-1-1"
printf '%%NAME%%\nhello\n\n%%PROVIDES%%\nqcom-firmware-in-another-repo\n\n' >"$fixture/other/hello-1-1/desc"
(cd "$fixture/other" && bsdtar -czf "$fixture/other.db" -- *)

got=$(qcom_oem_firmware_packages "$fixture/omarchy.db")
expected=$'acer-aspire-14-ai-firmware\nasus-zenbook-a14-firmware'
[[ $got == "$expected" ]] || fail "expected the two firmware packages, once each, got: $got"

got=$(qcom_oem_firmware_packages "$fixture/omarchy.db" "$fixture/other.db")
[[ $got == *hello* ]] || fail "reads every database it is given"

[[ -z $(qcom_oem_firmware_packages) ]] || fail "no databases, no packages"

echo "ok - qcom_oem_firmware_packages"
