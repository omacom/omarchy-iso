#!/bin/bash
#
# Hardware layers: each configs/airootfs/usr/share/omarchy-iso/hardware-layers
# file names packages that builder/build-root-image.sh packs as a layer over the
# root image, and a check, layer_matches, that the installer runs in the target
# to pick it (phases_impl._hardware_layer). The files must load without running
# anything, the build must pack each for its own architecture only, and the
# Panther Lake layer must match exactly where Omarchy's scripts install all of
# its packages.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$ROOT/builder/build-root-image.sh"
layers="$ROOT/configs/airootfs/usr/share/omarchy-iso/hardware-layers"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Every layer file loads with no command on PATH, so loading runs nothing, and
# sets an architecture, packages and a check.
count=0
for file in "$layers"/*.layer; do
  [[ -f $file ]] || continue
  # shellcheck disable=SC2016 # expanded by the inner shell
  out=$(env -i PATH=/nonexistent /bin/bash -c 'source "$1" &&
    [[ $layer_arch == x86_64 || $layer_arch == aarch64 ]] && ((${#layer_packages[@]})) &&
    declare -F layer_matches >/dev/null && echo loaded' _ "$file" 2>&1) || fail "${file##*/} does not load: $out"
  [[ $out == loaded ]] || fail "${file##*/} printed while loading: $out"
  count=$((count + 1))
done
((count > 0)) || fail "no hardware layer files in $layers"
echo "ok - $count hardware layer file(s) load without running anything and name packages and a check"

# The Panther Lake layer, on fixtures shaped like a Dell XPS 16 (DA16260).
# Omarchy's detectors stand in as functions.
fixture() {
  rm -rf "$work/proc" "$work/sys"
  mkdir -p "$work/proc" "$work/sys/bus/acpi/devices/OVTI08F4:00" "$work/sys/devices/platform"
  printf 'processor\t: 0\ncpu family\t: 6\nmodel\t\t: 204\n' >"$work/proc/cpuinfo"
  echo OVTI08F4 >"$work/sys/bus/acpi/devices/OVTI08F4:00/hid"
}
matches() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  OMARCHY_PROC_ROOT="$work/proc" OMARCHY_SYS_ROOT="$work/sys" \
    OMARCHY_INSTALL_KERNELS=${KERNELS-linux-omarchy} bash -c '
    omarchy-hw-intel-ptl() { [[ ${NO_PTL:-} != 1 ]]; }
    omarchy-hw-intel() { [[ ${NO_INTEL:-} != 1 ]]; }
    omarchy-battery-present() { [[ ${NO_BATTERY:-} != 1 ]]; }
    omarchy-hw-intel-sof() { [[ ${NO_SOF:-} != 1 ]]; }
    source "$1"
    layer_matches' _ "$layers/intel-ptl-ipu7.layer"
}

fixture
matches || fail "the Panther Lake layer does not match a Dell XPS 16"
echo "ok - the Panther Lake layer matches a Panther Lake laptop with the OV08F4 camera"

NO_PTL=1 matches && fail "it matched without a Panther Lake GPU"
NO_INTEL=1 matches && fail "it matched without an Intel CPU"
KERNELS="linux-omarchy linux-lts" matches && fail "it matched with a second kernel, where ipu7-camera.sh installs DKMS drivers"
KERNELS="" matches && fail "it matched without being told the kernels"
NO_BATTERY=1 matches && fail "it matched without a battery"
NO_SOF=1 matches && fail "it matched without SOF audio"
sed -i 's/^model\t\t: 204/model\t\t: 189/' "$work/proc/cpuinfo"
matches && fail "it matched a CPU model other than Panther Lake's"
fixture
mkdir -p "$work/sys/devices/platform/thinkpad_acpi"
touch "$work/sys/devices/platform/thinkpad_acpi/dytc_lapmode"
matches && fail "it matched a ThinkPad, where thermald.sh installs nothing"
fixture
rm -r "$work/sys/bus/acpi/devices/OVTI08F4:00"
matches && fail "it matched without the OV08F4 camera"
echo "ok - it does not match where any of its scripts would install nothing"

# A hardware layer is installed with --noscriptlet, and the packages that
# carry a scriptlet are listed in pacman's order for the installer to run once
# the user exists. Only what pacman installed after the given log line counts.
eval "$(sed -n '/^record_layer_scriptlets() {$/,/^}$/p' "$builder")"
merged="$work/merged"
mkdir -p "$merged/var/log" "$merged/var/lib/pacman/local"/{old-1-1,camera-1.0-4,lib-2-1,tool-3-1}
touch "$merged/var/lib/pacman/local/old-1-1/install" "$merged/var/lib/pacman/local/camera-1.0-4/install" \
  "$merged/var/lib/pacman/local/tool-3-1/install"
cat >"$merged/var/log/pacman.log" <<'LOG'
[2026-11-26T00:00:00+0000] [ALPM] installed old (1-1)
[2026-11-26T00:00:01+0000] [PACMAN] Running 'pacman -S --noscriptlet camera'
[2026-11-26T00:00:01+0000] [ALPM] installed lib (2-1)
[2026-11-26T00:00:01+0000] [ALPM] installed tool (3-1)
[2026-11-26T00:00:01+0000] [ALPM] installed camera (1.0-4)
LOG
record_layer_scriptlets "$merged" 1 || fail "record_layer_scriptlets failed"
[[ $(<"$merged/var/lib/omarchy-iso/layer-scriptlets") == $'tool 3-1\ncamera 1.0-4' ]] ||
  fail "the scriptlet list is wrong: $(cat "$merged/var/lib/omarchy-iso/layer-scriptlets")"
rm "$merged/var/log/pacman.log"
if record_layer_scriptlets "$merged" 0 2>/dev/null; then fail "a layer without a pacman log was not refused"; fi
echo "ok - the layer lists, in pacman's order, the packages whose scriptlets the installer runs"

# The build packs each layer for its own architecture, and drops one that
# fails, so no stale layer ships.
eval "$(sed -n '/^layer_path() {$/,/^}$/p' "$builder")"
eval "$(sed -n '/^hardware_layer_packages() {$/,/^}$/p' "$builder")"
eval "$(sed -n '/^build_hardware_layers() {$/,/^}$/p' "$builder")"
declare -F build_hardware_layers >/dev/null || fail "the builder has no build_hardware_layers"
# shellcheck disable=SC2034 # read by layer_path and build_hardware_layers
output="$work/iso/omarchy-root.img.zst"
hardware_layers="$work/layers"
mkdir -p "$work/iso" "$hardware_layers"
arch=$(uname -m)
other=aarch64
[[ $arch == aarch64 ]] && other=x86_64
printf 'layer_arch=%s\nlayer_packages=(one two)\nlayer_matches() { :; }\n' "$arch" >"$hardware_layers/native.layer"
printf 'layer_arch=%s\nlayer_packages=(three)\nlayer_matches() { :; }\n' "$other" >"$hardware_layers/foreign.layer"
printf 'layer_arch=%s\nlayer_packages=(four)\nlayer_matches() { :; }\n' "$arch" >"$hardware_layers/broken.layer"
touch "$(layer_path broken)"
with_image_overlay() {
  echo "$*" >>"$work/calls"
  [[ $2 != broken ]]
}
build_hardware_layers >/dev/null
grep -qxF "build_hardware_layer_in native one two" "$work/calls" || fail "the native layer was not built: $(cat "$work/calls")"
if grep -q foreign "$work/calls"; then fail "a layer for another architecture was built"; fi
[[ ! -e $(layer_path broken) ]] || fail "a layer that failed to build was left to ship"
echo "ok - each layer is built for its own architecture, and one that fails is not shipped"

# build-iso.sh hands the directory over, and the layers are packed once the
# image's tree is final, after its build-only files are gone.
# shellcheck disable=SC2016 # the line as written in build-iso.sh, unexpanded
grep -Fq 'OMARCHY_HARDWARE_LAYERS="$build_cache_dir/airootfs/usr/share/omarchy-iso/hardware-layers"' "$ROOT/builder/build-iso.sh" ||
  fail "build-iso.sh does not pass the hardware layers to build-root-image.sh"
cleanup=$(grep -n "^  # Only this build uses these; the installed system has no use for them.$" "$builder" | cut -d: -f1)
packed=$(grep -n '^  build_hardware_layers$' "$builder" | cut -d: -f1)
populated=$(grep -n '^  echo "Populating btrfs root image with' "$builder" | cut -d: -f1)
[[ -n $cleanup && -n $packed && -n $populated ]] || fail "cannot find the build steps in build-root-image.sh"
((cleanup < packed && packed < populated)) || fail "the layers are not packed between the image's cleanup and its btrfs copy"
echo "ok - build-iso.sh passes the layers, and they are packed from the image's final tree"
