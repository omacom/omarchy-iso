#!/bin/bash
#
# arch-mact2 replaced apple-bcm-firmware with apple-bcm-firmware-fetcher
# with no provides=. An ISO build that only drops the old name leaves the
# runtime's T2 step asking for it, in one pacman -S with linux-t2, its
# headers, the audio config and t2fanrd: "target not found" fails all five,
# on hardware no VM scenario reaches. This checks both halves of the fix:
# a known rename is rewritten in the install scripts, and a dropped name an
# install script still asks for stops the build.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOOL="$ROOT/builder/follow-renamed-packages.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

fixture() {
  rm -rf "$WORK/install"
  mkdir -p "$WORK/install/hardware/apple"
  # The block as omarchy 4.0.3 ships it.
  cat >"$WORK/install/hardware/apple/fix-t2.sh" <<'EOF'
if lspci -nn | grep "106b:180[12]" >/dev/null; then
  omarchy-pkg-add \
    linux-t2 \
    linux-t2-headers \
    apple-t2-audio-config \
    apple-bcm-firmware \
    t2fanrd
fi
EOF
  echo 'omarchy-pkg-add apple-bcm-firmware-fetcher' >"$WORK/install/hardware/apple/already-new.sh"
}
asked() { grep -cE "^ +$1( \\\\)?\$" "$WORK/install/hardware/apple/fix-t2.sh"; }

fixture
echo "apple-bcm-firmware apple-bcm-firmware-fetcher" >"$WORK/renamed"
: >"$WORK/unresolved"
bash "$TOOL" "$WORK/install" "$WORK/renamed" "$WORK/unresolved" >/dev/null
check "rename: exit status" 0 $?
check "rename: the old name is gone" 0 "$(asked apple-bcm-firmware)"
check "rename: the new name is asked for" 1 "$(asked apple-bcm-firmware-fetcher)"
check "rename: the neighbours are untouched" "1 1 1" "$(asked linux-t2) $(asked linux-t2-headers) $(asked t2fanrd)"
check "rename: a script already on the new name is not rewritten twice" \
  "omarchy-pkg-add apple-bcm-firmware-fetcher" "$(cat "$WORK/install/hardware/apple/already-new.sh")"

fixture
: >"$WORK/renamed"
echo "apple-bcm-firmware" >"$WORK/unresolved"
message=$(bash "$TOOL" "$WORK/install" "$WORK/renamed" "$WORK/unresolved" 2>&1)
check "dropped and still asked for: the build stops" 1 $?
check "dropped and still asked for: names the script" 1 "$(grep -c 'hardware/apple/fix-t2.sh' <<<"$message")"

echo "some-mirror-extra" >"$WORK/unresolved"
bash "$TOOL" "$WORK/install" "$WORK/renamed" "$WORK/unresolved" >/dev/null 2>&1
check "dropped but asked for by nothing: the build goes on" 0 $?

bash "$TOOL" "$WORK/install" "" "" >/dev/null 2>&1
check "no lists at all: nothing to do" 0 $?

((failures == 0)) && echo "PASS" || { echo "FAILED: $failures"; exit 1; }
