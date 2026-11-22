#!/bin/bash
#
# .automated_script.sh shows the installer in kmscon and falls back to the
# plain console when kmscon is turned off or cannot show it. This runs its
# kmscon_wanted and run_in_kmscon against stubs of kmscon in each state.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/configs/airootfs/root/.automated_script.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

functions=$(sed -n '/^kmscon_wanted() {$/,/^}$/p; /^run_in_kmscon() {$/,/^}$/p' "$SCRIPT")
[[ $functions == *kmscon_wanted*run_in_kmscon* ]] || fail "the kmscon launch functions are gone from .automated_script.sh"
functions=${functions//\/run\/omarchy-iso/$fixture/run}
functions=${functions//\/proc\/cmdline/$fixture/cmdline}
functions=${functions//\/dev\/dri/$fixture/dri}
# A second, not fifteen, for the stub that never starts the installer.
functions=${functions//sleep 15/sleep 1}
eval "$functions"

mkdir -p "$fixture/bin" "$fixture/run" "$fixture/dri"
PATH="$fixture/bin:$PATH"
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$fixture/bin/$1"
  chmod +x "$fixture/bin/$1"
}

stub kmscon "exit 0"
echo "quiet archisobasedir=arch" >"$fixture/cmdline"
touch "$fixture/dri/card0"
kmscon_wanted || fail "kmscon is not used on a machine with a display device"
OMARCHY_ISO_NO_KMSCON=1 kmscon_wanted && fail "OMARCHY_ISO_NO_KMSCON=1 did not turn kmscon off"
echo "quiet omarchy.kmscon=0" >"$fixture/cmdline"
kmscon_wanted && fail "omarchy.kmscon=0 did not turn kmscon off"
echo "quiet" >"$fixture/cmdline"
rm "$fixture/dri/card0"
kmscon_wanted && fail "kmscon is used with no DRM device to draw on"

stub omarchy-iso-kmscon "touch '$fixture/run/kmscon-started'"
run_in_kmscon || fail "an installer that ran in kmscon was reported as not shown"

stub omarchy-iso-kmscon "exit 1"
run_in_kmscon && fail "a kmscon that failed to start was reported as showing the installer"

stub omarchy-iso-kmscon "echo \$\$ >'$fixture/run/kmscon.pid'; exec sleep 60"
SECONDS=0
run_in_kmscon && fail "a kmscon that never ran the installer was reported as showing it"
((SECONDS < 10)) || fail "a kmscon that never ran the installer was waited on for ${SECONDS}s"

echo "ok - kmscon launch"
