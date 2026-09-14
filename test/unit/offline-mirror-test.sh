#!/bin/bash
#
# The offline mirror's verifier, run for real against a throwaway mirror
# fixture shaped the way repo-add writes one: every way the medium can be
# wrong has to stop the install before it formats. The mount unit and build
# wiring around it are not restated here — the integration installs prove
# those.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

failures=0

check() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description"
    failures=$((failures + 1))
  fi
}

# ------------------------------------------------- verifying the mirror

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A payload fixture: a mirror with two packages the medium carries, one the
# root image provides, a sibling sharing a name prefix, and a repo database
# shaped the way repo-add writes one.
payload="$work/payload"
mkdir -p "$payload/mirror"
printf 'the kernel\n' >"$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst"
printf 'kernel signature\n' >"$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst.sig"
printf 'firmware\n' >"$payload/mirror/linux-firmware-1.0-1-x86_64.pkg.tar.zst"
db="$work/db"; rm -rf "$db"
desc_record() { # dir, filename, name
  mkdir -p "$db/$1"
  printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%SHA256SUM%%\n%s\n\n' \
    "$2" "$3" "$(sha256sum "$payload/mirror/$2" | cut -d' ' -f1)" >"$db/$1/desc"
}
desc_record linux-1.0-1 linux-1.0-1-x86_64.pkg.tar.zst linux
desc_record linux-firmware-1.0-1 linux-firmware-1.0-1-x86_64.pkg.tar.zst linux-firmware
# In the database because pacman has to resolve every name, but not on this
# medium: the root image provides it.
printf 'image-provided\n' >"$payload/mirror/coreutils-1.0-1-x86_64.pkg.tar.zst"
desc_record coreutils-1.0-1 coreutils-1.0-1-x86_64.pkg.tar.zst coreutils
rm -f "$payload/mirror/coreutils-1.0-1-x86_64.pkg.tar.zst"
tar -czf "$payload/mirror/offline.db.tar.gz" -C "$db" linux-1.0-1 linux-firmware-1.0-1 coreutils-1.0-1
printf 'files\n' | gzip >"$payload/mirror/offline.files.tar.gz"
# What the build recorded this medium as carrying.
printf '%s\n' linux-1.0-1-x86_64.pkg.tar.zst linux-firmware-1.0-1-x86_64.pkg.tar.zst >"$payload/shipped"
( cd "$payload" && printf 'root image\n' >omarchy-root.btrfs.zst && sha256sum omarchy-root.btrfs.zst >omarchy-root.btrfs.zst.sha256 )

VERIFIER="$ROOT/configs/airootfs/usr/local/bin/omarchy-verify-mirror"
# Run from the mirror, the way the unit's WorkingDirectory does.
verify() { ( cd "$payload/mirror" && OMARCHY_SHIPPED_LIST="$payload/shipped" bash "$VERIFIER" ); }
# The unit's own command for the stream, run the way the unit runs it.
boot_scope() { ( cd "$payload" && sha256sum --check --strict --quiet omarchy-root.btrfs.zst.sha256 ); }

check "an intact mirror verifies" verify
check "it says how many packages it checked" \
  bash -c "verify_out=\$(cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER'); [[ \$verify_out == 'verified 2 packages against the repo database' ]]"
check "the stream's own check passes" boot_scope
check "it names only the file it checks" \
  bash -c "(( \$(grep -c . '$payload/omarchy-root.btrfs.zst.sha256') == 1 ))"
# Every way the medium can be wrong has to stop the install before it formats.
check "a damaged package fails it" \
  bash -c "printf 'damaged\n' >'$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' ) >/dev/null 2>&1"
check "and tells the user to re-flash" \
  bash -c "cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' 2>&1 | grep -q 're-flash'"
check "a package missing from the medium fails it" \
  bash -c "printf 'the kernel\n' >'$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst';
    mv '$payload/mirror/linux-firmware-1.0-1-x86_64.pkg.tar.zst' '$work/hidden';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' ) >/dev/null 2>&1;
    rc=\$?; mv '$work/hidden' '$payload/mirror/linux-firmware-1.0-1-x86_64.pkg.tar.zst'; exit \$rc"
check "a shipped package with no database record fails it" \
  bash -c "printf '%s\n' linux-1.0-1-x86_64.pkg.tar.zst nosuch-1.0-1-x86_64.pkg.tar.zst >'$work/badlist';
    printf 'x\n' >'$payload/mirror/nosuch-1.0-1-x86_64.pkg.tar.zst';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$work/badlist' bash '$VERIFIER' ) >/dev/null 2>&1"
check "an unreadable database fails it" \
  bash -c "cp '$payload/mirror/offline.db.tar.gz' '$work/db.good';
    printf 'not a gzip stream\n' >'$payload/mirror/offline.db.tar.gz';
    ! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' ) >/dev/null 2>&1;
    rc=\$?; cp '$work/db.good' '$payload/mirror/offline.db.tar.gz'; exit \$rc"
check "a missing shipped list fails it rather than passing" \
  bash -c "! ( cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$work/nope' bash '$VERIFIER' ) >/dev/null 2>&1"
# Signatures are not read ([offline] is SigLevel = Never).
check "a damaged signature does not fail it" \
  bash -c "printf 'damaged\n' >'$payload/mirror/linux-1.0-1-x86_64.pkg.tar.zst.sig';
    cd '$payload/mirror' && OMARCHY_SHIPPED_LIST='$payload/shipped' bash '$VERIFIER' >/dev/null 2>&1"

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'the mirror verifier catches every bad-medium shape\n'
