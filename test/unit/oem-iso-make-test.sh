#!/bin/bash
#
# bin/omarchy-iso-make's OEM bundle flags, as far as the check that runs before
# anything is built: a bundle that is refused stops the command there.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
make="$ROOT/bin/omarchy-iso-make"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Nothing here may reach a build: these stand in for what one would start with.
mkdir -p "$work/bin" "$work/tmp" "$work/cwd"
for tool in docker sudo git; do
  printf '#!/bin/bash\necho "reached %s" >>"%s/reached"\nexit 99\n' "$tool" "$work" >"$work/bin/$tool"
done
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp"
cd "$work/cwd"

# A config whose name opens with a dash is a file, not an option.
printf '{}' >./-brand.json
! bash "$make" --oem --oem-config -brand.json 2>"$work/err" || fail "a config without a name was accepted"
grep -q '"name" is required' "$work/err" || fail "a config named like an option was not read as one: $(cat "$work/err")"
[[ -z $(ls -A "$work/tmp") ]] || fail "a refused bundle left its staging directory behind"

# The bundle is the OEM ISO's, whichever side of it --oem is given on.
printf '{"name": "Acme"}' >brand.json
! bash "$make" --oem-config brand.json 2>"$work/err" || fail "an OEM config was accepted without --oem"
grep -q -- "add --oem" "$work/err" || fail "an OEM config without --oem was refused without saying why: $(cat "$work/err")"
printf 'if true; then\n' >broken.sh
! bash "$make" --oem-script broken.sh --oem 2>"$work/err" || fail "a script that does not parse was accepted"
grep -q "not a bash script that parses" "$work/err" || fail "a script that does not parse was not named: $(cat "$work/err")"

! bash "$make" --preset xx 2>"$work/err" || fail "a preset with no file was accepted"
grep -q "no preset xx; the presets are: cn" "$work/err" || fail "an unknown preset was refused without naming the presets: $(cat "$work/err")"

[[ ! -e $work/reached ]] || fail "a refused bundle got as far as: $(cat "$work/reached")"

echo "ok - an OEM bundle that is refused stops omarchy-iso-make before it builds anything"

# A valid preset reaches the container with its configuration and separate
# build caches. Capture the actual invocation without starting a builder.
cat >"$work/bin/git" <<'STUB'
#!/bin/bash
if [[ $1 == submodule ]]; then exit 0; fi
exec /usr/bin/git "$@"
STUB
cat >"$work/bin/sudo" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >"$PRESET_CAPTURE"
exit 99
STUB
mkdir -p "$work/home"
export PRESET_CAPTURE="$work/preset-args"
(cd "$ROOT" && HOME="$work/home" bash "$make" --preset cn) >"$work/preset.log" 2>&1 && fail "the stubbed builder unexpectedly succeeded"
[[ -s $PRESET_CAPTURE ]] || fail "the preset did not reach the builder: $(cat "$work/preset.log")"
python3 - "$PRESET_CAPTURE" "$ROOT/presets/cn.json" <<'PY'
from pathlib import Path
import sys
argv = Path(sys.argv[1]).read_bytes().decode().split('\0')
assert argv[:2] == ['podman', 'run'], argv
assert 'OMARCHY_PRESET=cn' in argv
assert sys.argv[2] + ':/preset.json:ro' in argv
assert any(arg.endswith(':/var/cache/omarchy-offline-cache') for arg in argv)
assert any('builder_pkg_stable_x86_64:/var/cache/pacman/pkg' in arg for arg in argv), argv
assert '/var/cache/pacman/pkg:/var/cache/pacman/pkg' not in argv
PY
echo "ok - the Podman builder gets the preset and its own caches"
