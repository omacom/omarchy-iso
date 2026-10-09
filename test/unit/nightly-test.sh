#!/bin/bash
#
# The nightly's decisions, tried without a runner: which channels a run makes
# and where they go (test/vm-image/nightly-plan), what it lays out and what
# latest.json then says (test/vm-image/nightly-layout), and two things the
# install test decides from what it is given: which Omarchy packages an ISO
# installs, and when an install is over.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
plan="$ROOT/test/vm-image/nightly-plan"
layout="$ROOT/test/vm-image/nightly-layout"
harness="$ROOT/test/integration.d/base-test.sh"
bash -n "$plan"
bash -n "$layout"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
equal() { [[ $2 == "$3" ]] || fail "$1: got '$2', expected '$3'"; }
refused() { # description, command...: it has to fail and say why
  local what=$1; shift
  if "$@" >"$tmp/refused.out" 2>"$tmp/refused.err"; then fail "$what was accepted"; fi
  [[ -s $tmp/refused.err ]] || fail "$what was refused without a word"
}

# ---------------------------------------------------------------- nightly-plan
planned() { "$plan" "$@" 2>/dev/null; }

first=$(planned 2026.10.09 431 1 schedule v4.0.4 "")
equal "a first run makes both channels" "$(jq -r 'map(.channel) | join(",")' <<<"$first")" "edge,stable"
equal "the edge version" "$(jq -r '.[0].version' <<<"$first")" "2026.10.09.431"
equal "the edge path" "$(jq -r '.[0].release' <<<"$first")" "edge/2026.10.09.431"
equal "the stable version is the release's" "$(jq -r '.[1].version' <<<"$first")" "4.0.4"
equal "the stable path has the run number" "$(jq -r '.[1].release' <<<"$first")" "stable/4.0.4/431"

again=$(planned 2026.10.09 431 2 schedule v4.0.4 "")
equal "a run started again has its own edge version" "$(jq -r '.[0].version' <<<"$again")" "2026.10.09.431.2"
equal "a run started again has its own stable path" "$(jq -r '.[1].release' <<<"$again")" "stable/4.0.4/431.2"
[[ $(jq -r '.[].release' <<<"$first" | sort) != "$(jq -r '.[].release' <<<"$again" | sort)" ]] ||
  fail "two attempts of one run share a path"

equal "a published release is left out of a scheduled run" \
  "$(planned 2026.10.09 432 1 schedule v4.0.4 4.0.4 | jq -r 'map(.channel) | join(",")')" "edge"
equal "a new release is made on the next scheduled run" \
  "$(planned 2026.10.09 432 1 schedule v4.0.5 4.0.4 | jq -r '.[1].version')" "4.0.5"
equal "a manual run makes a published release again" \
  "$(planned 2026.10.09 432 1 workflow_dispatch v4.0.4 4.0.4 | jq -r 'map(.channel) | join(",")')" "edge,stable"

refused "a release tag that is not a version" "$plan" 2026.10.09 431 1 schedule nightly ""
refused "an empty release tag" "$plan" 2026.10.09 431 1 schedule "" ""
refused "a release tag with a path in it" "$plan" 2026.10.09 431 1 schedule "v4.0.4/../x" ""
refused "a run number that is not a number" "$plan" 2026.10.09 "" 1 schedule v4.0.4 ""
refused "a date in another form" "$plan" 2026-10-09 431 1 schedule v4.0.4 ""

# -------------------------------------------------------------- nightly-layout
sealed() { # directory: what vm-seal leaves
  rm -rf "$1"; mkdir -p "$1"
  local file
  for file in base.qcow2 OVMF_VARS.4m.fd vmlinuz initrd cmdline; do echo "$file of ${1##*/}" >"$1/$file"; done
  echo "sums of the seal" >"$1/SHA256SUMS"
}
export SITE=https://nightly.example ISO_SITE=https://iso.example ISO_COMMIT=0123456789abcdef0123456789abcdef01234567

# Edge. pacman answers for omarchy and omarchy-dev with the one installed
# package, so its line is there twice.
mkdir -p "$tmp/release"
echo "an edge iso" >"$tmp/release/omarchy-2026.10.09-x86_64-edge.iso"
sealed "$tmp/sealed-edge"
printf '%s\n' "omarchy-dev 4.0.0.r6818.gc352b62-2" "omarchy-dev 4.0.0.r6818.gc352b62-2" \
  "/usr/lib/modules/7.2.8-5-omarchy-bore/pkgbase is owned by linux-omarchy-bore 7.2.8-5" "7.2.8-5-omarchy-bore" >"$tmp/edge-packages"
"$layout" edge 2026.10.09.431 edge/2026.10.09.431 "$tmp/release/omarchy-2026.10.09-x86_64-edge.iso" \
  "$tmp/sealed-edge" "$tmp/edge-packages" "$tmp/out" >/dev/null
json=$tmp/out/edge/latest.json
dir=$tmp/out/edge/2026.10.09.431
field() { jq -r "$1" "$json"; }

equal "edge: files published" "$(cd "$tmp/out" && find . -type f | sort | paste -sd' ')" \
  "./edge/2026.10.09.431/omarchy-edge-2026.10.09.431.iso ./edge/2026.10.09.431/omarchy-edge-2026.10.09.431.iso.sha256 ./edge/2026.10.09.431/vm/OVMF_VARS.4m.fd ./edge/2026.10.09.431/vm/SHA256SUMS ./edge/2026.10.09.431/vm/base.qcow2 ./edge/2026.10.09.431/vm/cmdline ./edge/2026.10.09.431/vm/initrd ./edge/2026.10.09.431/vm/vm-boot ./edge/2026.10.09.431/vm/vmlinuz ./edge/latest.json"
(cd "$dir" && sha256sum -c --quiet ./*.sha256) || fail "edge: the ISO's checksum file does not match the ISO"
(cd "$dir/vm" && sha256sum -c --quiet SHA256SUMS) || fail "edge: SHA256SUMS does not match the image"
equal "edge: SHA256SUMS covers every file beside it" \
  "$(awk '{ print $2 }' "$dir/vm/SHA256SUMS" | sort | paste -sd' ')" "$(cd "$dir/vm" && ls | grep -v SHA256SUMS | sort | paste -sd' ')"
cmp -s "$dir/vm/vm-boot" "$ROOT/test/vm-image/vm-boot" || fail "edge: the published vm-boot is not the repository's"
equal "edge: version" "$(field .version)" "2026.10.09.431"
equal "edge: channel" "$(field .channel)" "edge"
equal "edge: url" "$(field .url)" "https://nightly.example/edge/2026.10.09.431/omarchy-edge-2026.10.09.431.iso"
equal "edge: sha256 is the ISO's" "$(field .sha256)" "$(sha256sum "$dir/omarchy-edge-2026.10.09.431.iso" | cut -d' ' -f1)"
equal "edge: size is the ISO's" "$(field .size)" "$(stat -c %s "$dir/omarchy-edge-2026.10.09.431.iso")"
equal "edge: iso_commit" "$(field .iso_commit)" "$ISO_COMMIT"
equal "edge: omarchy_version, once" "$(field .omarchy_version)" "4.0.0.r6818.gc352b62-2"
equal "edge: omarchy_commit" "$(field .omarchy_commit)" "c352b62"
equal "edge: kernel" "$(field .kernel)" "7.2.8-5-omarchy-bore"
equal "edge: image address" "$(field .vm.disk)" "https://nightly.example/edge/2026.10.09.431/vm/base.qcow2"
equal "edge: image checksum is the disk's" "$(field .vm.disk_sha256)" "$(sha256sum "$dir/vm/base.qcow2" | cut -d' ' -f1)"
equal "edge: every listed file is published" "$(field '.vm.files[]' | sort | paste -sd' ')" "$(cd "$dir/vm" && ls | sort | paste -sd' ')"
[[ $(field .built_at) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail "edge: built_at is '$(field .built_at)'"
# What a consumer does with the ISO's name: the first run of three or more
# dotted numbers is the version.
[[ $(basename "$(field .url)") =~ [0-9]+(\.[0-9]+){2,} ]] || fail "edge: the ISO's name carries no version"
equal "edge: the version read from the ISO's name" "${BASH_REMATCH[0]}" "2026.10.09.431"

# Stable: the image is published, the released ISO stays where it is.
rm -rf "$tmp/out"
echo "a released iso" >"$tmp/release/omarchy-4.0.4.iso"
sealed "$tmp/sealed-stable"
printf '%s\n' "omarchy 4.0.4-1" "/usr/lib/modules/7.2.5-3-omarchy/pkgbase is owned by linux-omarchy 7.2.5-3" "7.2.5-3-omarchy" >"$tmp/stable-packages"
"$layout" stable 4.0.4 stable/4.0.4/431 "$tmp/release/omarchy-4.0.4.iso" "$tmp/sealed-stable" "$tmp/stable-packages" "$tmp/out" >/dev/null
json=$tmp/out/stable/latest.json
equal "stable: no ISO is published" "$(find "$tmp/out" -name '*.iso*' | wc -l)" "0"
[[ -f $tmp/release/omarchy-4.0.4.iso ]] || fail "stable: the released ISO was moved away"
equal "stable: url is the release's" "$(field .url)" "https://iso.example/omarchy-4.0.4.iso"
equal "stable: sha256 is the ISO's" "$(field .sha256)" "$(sha256sum "$tmp/release/omarchy-4.0.4.iso" | cut -d' ' -f1)"
equal "stable: version" "$(field .version)" "4.0.4"
equal "stable: omarchy_version" "$(field .omarchy_version)" "4.0.4-1"
equal "stable: a release names no commit" "$(field .omarchy_commit)" ""
equal "stable: image address has the run number" "$(field .vm.disk)" "https://nightly.example/stable/4.0.4/431/vm/base.qcow2"
(cd "$tmp/out/stable/4.0.4/431/vm" && sha256sum -c --quiet SHA256SUMS) || fail "stable: SHA256SUMS does not match the image"

# Nothing half-made is described.
sealed "$tmp/sealed-short"; rm "$tmp/sealed-short/initrd"
refused "a sealed image without its initrd" "$layout" stable 4.0.4 stable/4.0.4/9 "$tmp/release/omarchy-4.0.4.iso" "$tmp/sealed-short" "$tmp/stable-packages" "$tmp/out2"
sealed "$tmp/sealed-x"; : >"$tmp/no-packages"
refused "an image that named no Omarchy package" "$layout" stable 4.0.4 stable/4.0.4/9 "$tmp/release/omarchy-4.0.4.iso" "$tmp/sealed-x" "$tmp/no-packages" "$tmp/out3"
sealed "$tmp/sealed-y"
refused "a released ISO under another version's name" "$layout" stable 4.0.5 stable/4.0.5/9 "$tmp/release/omarchy-4.0.4.iso" "$tmp/sealed-y" "$tmp/stable-packages" "$tmp/out4"
sealed "$tmp/sealed-z"
refused "a channel that does not exist" "$layout" rc 4.0.4 rc/4.0.4 "$tmp/release/omarchy-4.0.4.iso" "$tmp/sealed-z" "$tmp/stable-packages" "$tmp/out5"

# ------------------------------------------------------------ the install test
# The harness is a script that starts a VM when it is read; take the two
# functions out of it.
eval "$(sed -n '/^detect_packages() {$/,/^}$/p; /^installed_system_started() {$/,/^}$/p' "$harness")"
declare -F detect_packages installed_system_started >/dev/null || fail "the harness no longer has detect_packages and installed_system_started"

packages_of() { ISO=$1; detect_packages; echo "$RUNTIME_PACKAGE $SETTINGS_PACKAGE"; }
equal "an edge ISO installs the -dev packages" "$(packages_of release/omarchy-2026.10.09-x86_64-edge.iso)" "omarchy-dev omarchy-settings-dev"
equal "a dev ISO installs the -dev packages" "$(packages_of release/omarchy-2026.10.09-x86_64-dev.iso)" "omarchy-dev omarchy-settings-dev"
equal "a released ISO installs the release packages" "$(packages_of release/omarchy-4.0.4.iso)" "omarchy omarchy-settings"
equal "a stable build installs the release packages" "$(packages_of /x/edge/omarchy-2026.10.09-x86_64-stable.iso)" "omarchy omarchy-settings"

printf '%s\r\n' 'BdsDxe: loading Boot0002 "UEFI QEMU DVD-ROM QM00011 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x5,0xFFFF,0x0)' \
  'BdsDxe: starting Boot0002 "UEFI QEMU DVD-ROM QM00011 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x5,0xFFFF,0x0)' >"$tmp/serial"
if installed_system_started "$tmp/serial"; then fail "the installer's own boot counts as the installed system's"; fi
printf '%s\r\n' 'BdsDxe: loading Boot0005 "Limine" from HD(1,GPT,774175D2,0x800,0x400000)/\EFI\limine\limine_x64.efi' >>"$tmp/serial"
if installed_system_started "$tmp/serial"; then fail "loading Limine counts as having started it"; fi
printf '%s\r\n' 'BdsDxe: starting Boot0005 "Limine" from HD(1,GPT,774175D2,0x800,0x400000)/\EFI\limine\limine_x64.efi' >>"$tmp/serial"
installed_system_started "$tmp/serial" || fail "the installed system's Limine starting is not noticed"
if installed_system_started "$tmp/no-such-log"; then fail "a missing serial log counts as a started system"; fi

echo "nightly tests passed"
