#!/bin/bash
#
# Unit tests for netinstall media: the build flag that selects it, the marker
# that records it, and the one place the installer's advice changes with it.
#
# Every case runs against a throwaway sandbox, so the build flag cases never
# reach Docker or the network: git and docker are stubbed, and the stub reports
# the environment the real script would have handed the build container.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DIAGNOSE="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-diagnose-media"
BUILD="$ROOT/builder/build-iso.sh"
PACKAGE="npth-1.8-1-x86_64.pkg.tar.zst"
TARGET_CACHE="/mnt/var/cache/pacman/pkg"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ── a corrupt package, as pacman reports it ─────────────────────────────────
log="$work/install.log"
printf 'error: %s/%s is corrupted\n' "$TARGET_CACHE" "$PACKAGE" >"$log"

# ── the medium's own verdict ────────────────────────────────────────────────
marker="$work/omarchy_media"
mirror="$work/mirror"
mkdir -p "$mirror"

printf 'netinstall\n' >"$marker"
verdict=$(OMARCHY_MEDIA_FILE="$marker" OMARCHY_TARGET_PACKAGE_CACHE="$TARGET_CACHE" \
  OMARCHY_OFFLINE_MIRROR="$mirror" bash "$DIAGNOSE" "$log") || true
[[ $verdict == *"download was incomplete"* ]] ||
  fail "netinstall names the download" "$verdict"

printf 'offline\n' >"$marker"
verdict=$(OMARCHY_MEDIA_FILE="$marker" OMARCHY_TARGET_PACKAGE_CACHE="$TARGET_CACHE" \
  OMARCHY_OFFLINE_MIRROR="$mirror" bash "$DIAGNOSE" "$log") || true
[[ $verdict != *"download was incomplete"* ]] ||
  fail "offline still names the medium, not the download" "$verdict"
[[ $verdict == *"medium"* ]] ||
  fail "offline names the medium" "$verdict"

pass "the failure screen tells a download apart from a damaged stick"

# ── the build flag ──────────────────────────────────────────────────────────
sandbox="$work/repo"
stubs="$work/stubs"
mkdir -p "$sandbox/bin" "$sandbox/release" "$stubs"

cp "$ROOT/bin/omarchy-iso-make" "$sandbox/bin/"

cat >"$stubs/git" <<'STUB'
#!/bin/bash
exit 0
STUB

# `docker version` has to succeed so the real script does not reach for sudo,
# and `docker run` has to leave an ISO in the mounted output directory: the
# script names the artifact it just built.
cat >"$stubs/docker" <<'STUB'
#!/bin/bash
[[ ${1:-} == version ]] && exit 0
[[ ${1:-} == run ]] || exit 0

out=""
media=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
  OMARCHY_MEDIA=*) media="${args[i]#OMARCHY_MEDIA=}" ;;
  esac
  if [[ ${args[i]} == -v && ${args[i + 1]:-} == *:/out/ ]]; then
    out="${args[i + 1]%:/out/}"
  fi
done

printf 'docker-run OMARCHY_MEDIA=%s\n' "$media"
[[ -n $out ]] && printf 'not really an iso\n' >"$out/omarchy-fake.iso"
exit 0
STUB

chmod +x "$stubs"/*

run_make() {
  PATH="$stubs:$PATH" bash "$sandbox/bin/omarchy-iso-make" --keep-pkg-cache --no-boot-offer "$@"
}

out=$(run_make --netinstall) || fail "omarchy-iso-make accepts --netinstall" "$out"
[[ $out == *"OMARCHY_MEDIA=netinstall"* ]] ||
  fail "--netinstall reaches the build container" "$out"
[[ -f $sandbox/release/omarchy-fake-quattro.iso ]] ||
  fail "--netinstall still names the built ISO" "$(ls "$sandbox/release")"

out=$(run_make) || fail "omarchy-iso-make builds without the flag" "$out"
[[ $out == *"OMARCHY_MEDIA=offline"* ]] ||
  fail "the medium defaults to offline" "$out"

pass "the build flag selects the medium and defaults to offline"

# ── an unknown medium is refused, not guessed ───────────────────────────────
if out=$(OMARCHY_MEDIA=compact bash "$BUILD" 2>&1); then
  fail "an unknown OMARCHY_MEDIA is refused" "$out"
fi
[[ $out == *"must be 'offline' or 'netinstall'"* ]] ||
  fail "the refusal names the accepted values" "$out"

pass "an unknown medium is refused"
