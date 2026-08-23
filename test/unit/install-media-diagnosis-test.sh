#!/bin/bash
#
# Unit tests for omarchy-install-diagnose-media and the failure screen that
# renders it. Every case builds a throwaway offline mirror -- a package file
# and a real repo-add-shaped offline.db naming its sha256 -- so the three
# verdicts are told apart by the same evidence the live ISO has.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DIAGNOSE="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-diagnose-media"
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"
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

mirror="$work/mirror"
mkdir -p "$mirror"

# repo-add writes one desc record per package, %FILENAME% before %SHA256SUM%.
# Building a real gzipped tar of that shape keeps the parser honest.
write_mirror_db() {
  local checksum="$1" filename="${2:-$PACKAGE}" staging="$work/db"

  rm -rf "$staging"
  mkdir -p "$staging/npth-1.8-1"
  {
    printf '%%FILENAME%%\n%s\n\n' "$filename"
    printf '%%NAME%%\nnpth\n\n'
    printf '%%VERSION%%\n1.8-1\n\n'
    printf '%%SHA256SUM%%\n%s\n\n' "$checksum"
  } >"$staging/npth-1.8-1/desc"

  # A second package proves the lookup matches on name rather than on order.
  mkdir -p "$staging/zlib-1.3-1"
  {
    printf '%%FILENAME%%\nzlib-1.3-1-x86_64.pkg.tar.zst\n\n'
    printf '%%NAME%%\nzlib\n\n'
    printf '%%SHA256SUM%%\n%s\n\n' "$(printf 'f%.0s' {1..64})"
  } >"$staging/zlib-1.3-1/desc"

  tar -czf "$mirror/offline.db" -C "$staging" npth-1.8-1 zlib-1.3-1
}

write_log() {
  local log="$1" path="${2:-$TARGET_CACHE/$PACKAGE}"

  {
    echo "[dashboard] checking package integrity..."
    echo "[dashboard] :: File $path is corrupted (invalid or corrupted package)."
    echo "[dashboard] error: failed to commit transaction (invalid or corrupted package)"
    echo "[dashboard] ==> ERROR: Failed to install packages to new root"
  } >"$log"
}

diagnose() {
  OMARCHY_OFFLINE_MIRROR="$mirror" OMARCHY_TARGET_PACKAGE_CACHE="$TARGET_CACHE" \
    "$DIAGNOSE" "$@"
}

log="$work/install.log"
write_log "$log"

# The medium was written wrong: the package on the ISO no longer hashes to what
# the build recorded for it.
printf 'a package, but damaged\n' >"$mirror/$PACKAGE"
write_mirror_db "$(printf '0%.0s' {1..64})"

set +e
output=$(diagnose "$log")
status=$?
set -e

(( status == 0 )) || fail "a checksum mismatch is diagnosed" "exit status $status"
[[ $(head -n 1 <<<"$output") == "The install medium is damaged" ]] ||
  fail "a checksum mismatch is diagnosed" "$output"
grep -qF "$PACKAGE" <<<"$output" ||
  fail "the diagnosis names the package" "$output"
grep -qF "no longer matches the checksum" <<<"$output" ||
  fail "the diagnosis says the checksum disagrees" "$output"
grep -qF "sha256sum" <<<"$output" ||
  fail "the diagnosis says how to verify a fresh download" "$output"
pass "a checksum mismatch says the medium is damaged and names the package"

# The medium reads clean now, so the bytes were misread rather than written
# wrong. Re-downloading fixes nothing, and the advice has to say so.
write_mirror_db "$(sha256sum "$mirror/$PACKAGE" | cut -d " " -f 1)"

set +e
output=$(diagnose "$log")
status=$?
set -e

(( status == 0 )) || fail "an intact package is still diagnosed" "exit status $status"
[[ $(head -n 1 <<<"$output") == "The install medium was misread" ]] ||
  fail "an intact package is diagnosed as a misread" "$output"
grep -qF "another USB port" <<<"$output" ||
  fail "a misread points at the hardware" "$output"
if grep -qF "Re-download" <<<"$output"; then
  fail "a misread does not send anyone to re-download" "$output"
fi
pass "an intact package on the medium is diagnosed as a misread, not a bad download"

# The usual case. pacstrap runs with --noconfirm, which answers yes to pacman's
# "delete it?" and unlinks the package through the bind mount, so by the time
# anything here looks there is nothing left to weigh. The verdict must name the
# medium without claiming a comparison it never made, and must offer both
# remedies: a bad write and a bad read leave identical evidence.
rm "$mirror/$PACKAGE"

set +e
output=$(diagnose "$log")
status=$?
set -e

(( status == 0 )) || fail "a deleted package is still diagnosed" "exit status $status"
[[ $(head -n 1 <<<"$output") == "The install medium is damaged or misread" ]] ||
  fail "a deleted package is diagnosed without over-claiming" "$output"
grep -qF "read straight off this ISO" <<<"$output" ||
  fail "a deleted package still names the medium" "$output"
grep -qF "sha256sum" <<<"$output" ||
  fail "a deleted package offers the download remedy" "$output"
grep -qF "memory is at fault" <<<"$output" ||
  fail "a deleted package offers the hardware remedy too" "$output"
if grep -qF "no longer matches the checksum" <<<"$output"; then
  fail "a deleted package claims no comparison" "$output"
fi
pass "a deleted package names the medium without claiming which way it failed"

# A record with no %SHA256SUM% must not borrow the next record's, which would
# compare a real file against another package's checksum.
printf 'a package, but damaged\n' >"$mirror/$PACKAGE"
staging="$work/db"
rm -rf "$staging"
mkdir -p "$staging/npth-1.8-1" "$staging/zlib-1.3-1"
printf '%%FILENAME%%\n%s\n\n%%NAME%%\nnpth\n\n' "$PACKAGE" >"$staging/npth-1.8-1/desc"
{
  printf '%%FILENAME%%\nzlib-1.3-1-x86_64.pkg.tar.zst\n\n'
  printf '%%SHA256SUM%%\n%s\n\n' "$(sha256sum "$mirror/$PACKAGE" | cut -d " " -f 1)"
} >"$staging/zlib-1.3-1/desc"
tar -czf "$mirror/offline.db" -C "$staging" npth-1.8-1 zlib-1.3-1

set +e
output=$(diagnose "$log")
set -e

[[ $(head -n 1 <<<"$output") == "The install medium is damaged or misread" ]] ||
  fail "a record without a checksum borrows nobody else's" "$output"
pass "a record without a checksum borrows nobody else's"

# A package version may legally hold a backslash. It must not reach a terminal
# as an escape sequence, and awk must look it up literally rather than as one.
escaped='demo-1\033[2J-1-x86_64.pkg.tar.zst'
write_log "$work/escaped.log" "$TARGET_CACHE/$escaped"
printf 'a package, but damaged\n' >"$mirror/$escaped"
write_mirror_db "$(printf '0%.0s' {1..64})" "$escaped"

set +e
output=$(diagnose "$work/escaped.log")
set -e

# The dashboard renders these lines through printf %b, which turns a surviving
# backslash into whatever escape it spells. None may reach it.
if grep -qF '\' <<<"$output"; then
  fail "a backslash in a package name never reaches the renderer" "$(cat -v <<<"$output")"
fi
grep -qF "demo-1033" <<<"$output" ||
  fail "the sanitized name still identifies the package" "$output"
# The database record is found despite the backslash, so the verdict is the
# mismatch rather than the one that means no comparison could be made.
[[ $(head -n 1 <<<"$output") == "The install medium is damaged" ]] ||
  fail "a backslash in a package name is looked up literally" "$output"
pass "a backslash in a package name is looked up literally and never rendered as an escape"
rm "$mirror/$escaped"

# The live ISO has bsdtar through pacman's libarchive, but the tar fallback is
# the one that runs if that ever stops being true.
printf 'a package, but damaged\n' >"$mirror/$PACKAGE"
write_mirror_db "$(sha256sum "$mirror/$PACKAGE" | cut -d " " -f 1)"
no_bsdtar="$work/no-bsdtar"
mkdir -p "$no_bsdtar"
for tool in sed awk tar gzip sha256sum cat grep head tail cut printf; do
  command -v "$tool" >/dev/null && ln -sf "$(command -v "$tool")" "$no_bsdtar/$tool"
done

set +e
output=$(PATH="$no_bsdtar" diagnose "$log")
set -e

[[ $(head -n 1 <<<"$output") == "The install medium was misread" ]] ||
  fail "the tar fallback reads the database when bsdtar is absent" "$output"
pass "the tar fallback reads the database when bsdtar is absent"

printf 'a package, but damaged\n' >"$mirror/$PACKAGE"
write_mirror_db "$(printf '0%.0s' {1..64})"

# A corrupt package that was never read off this ISO is somebody else's
# problem. Guessing here sends people to buy a USB stick they did not need.
write_log "$work/elsewhere.log" "/var/tmp/build/$PACKAGE"

set +e
output=$(diagnose "$work/elsewhere.log")
status=$?
set -e

(( status == 1 )) || fail "corruption outside the target cache is not diagnosed" "exit $status: $output"
[[ -z $output ]] || fail "corruption outside the target cache prints nothing" "$output"
pass "corruption outside the target cache is not blamed on the medium"

# An ordinary failure has no media diagnosis, and the caller asks
# unconditionally, so silence has to be the answer.
printf 'error: something else went wrong entirely\n' >"$work/other.log"

set +e
output=$(diagnose "$work/other.log")
status=$?
set -e

(( status == 1 )) || fail "an unrelated failure is not diagnosed" "exit $status: $output"
[[ -z $output ]] || fail "an unrelated failure prints nothing" "$output"
pass "an unrelated failure produces no diagnosis"

set +e
output=$(diagnose "$work/does-not-exist.log")
status=$?
set -e

(( status == 1 )) || fail "a missing log is not diagnosed" "exit $status: $output"
pass "a missing log produces no diagnosis"

# End to end: the dashboard runs a failing installer and the diagnosis has to
# reach both the screen and the support log, above the tail it explains.
#
# The screen goes through a real pty rather than a file. The dashboard's exit
# handler reopens its TTY with a truncating redirect, which does nothing to a
# character device and empties a regular file, so a file would capture nothing.
stubs="$work/stubs"
mkdir -p "$stubs"
{
  echo '#!/bin/bash'
  echo "OMARCHY_OFFLINE_MIRROR='$mirror' OMARCHY_TARGET_PACKAGE_CACHE='$TARGET_CACHE' exec '$DIAGNOSE' \"\$@\""
} >"$stubs/omarchy-install-diagnose-media"
chmod +x "$stubs/omarchy-install-diagnose-media"

state_file="$work/state.json"
screen="$work/screen"

run_dashboard() {
  local install_log="$1"

  printf '{"current_phase":"Installing Arch + Omarchy","phases":[]}\n' >"$state_file"
  : >"$screen"
  script -qefc "PATH='$stubs:$PATH' OMARCHY_UI_INTERACTIVE=no OMARCHY_UI_FAILURE_ACTION=exit OMARCHY_FAILURE_TAIL_LOG='$install_log' '$DASHBOARD' '$install_log' '$state_file' -- bash -c 'exit 1'" \
    "$screen" >/dev/null 2>&1
}

visible_screen() {
  sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' "$screen"
}

dashboard_log="$work/dashboard.log"
write_log "$dashboard_log"

# State the case rather than inheriting whichever verdict the previous one left
# behind: this is the shape a real install fails in, with pacman having deleted
# the package it rejected.
rm -f "$mirror/$PACKAGE"
write_mirror_db "$(printf '0%.0s' {1..64})"

set +e
run_dashboard "$dashboard_log"
dashboard_status=$?
set -e

(( dashboard_status == 1 )) ||
  fail "the dashboard still exits with the installer's status" "exit $dashboard_status"
visible_screen | grep -qF "The install medium is damaged" ||
  fail "the failure screen shows the diagnosis" "$(visible_screen | tail -n 25)"
visible_screen | grep -qF "$PACKAGE" ||
  fail "the failure screen names the package" "$(visible_screen | tail -n 25)"
grep -qF "[dashboard] The install medium is damaged" "$dashboard_log" ||
  fail "the diagnosis is written to the support log" "$(tail -n 20 "$dashboard_log")"

# Once on the screen. The log tail rendered underneath reads the same file the
# diagnosis is recorded in, and the same finding printed twice reads as two.
headline_count=$(visible_screen | grep -cF "The install medium is damaged or misread" || true)
(( headline_count == 1 )) ||
  fail "the diagnosis appears once on the screen" "found $headline_count times"
pass "the dashboard renders the diagnosis once and records it in the support log"

# The screen is only as wide as the logo and the dashboard truncates to it with
# an ellipsis. Every sentence has to survive that, whatever the package is
# called, or the advice arrives with its second half cut off.
long_package="linux-firmware-nvidia-tegra-20250917.0e800e46-1-any.pkg.tar.zst"
long_log="$work/long.log"
write_log "$long_log" "$TARGET_CACHE/$long_package"

check_widths() {
  local label="$1" line
  while IFS= read -r line; do
    (( ${#line} <= 81 )) ||
      fail "no diagnosis line outruns the screen ($label)" "${#line} chars: $line"
  done < <(diagnose "$long_log")
}

# All three verdicts, since each writes its own sentences.
rm -f "$mirror/$long_package"
check_widths "deleted"
printf 'these are not the bytes that were built\n' >"$mirror/$long_package"
write_mirror_db "$(printf '0%.0s' {1..64})" "$long_package"
check_widths "damaged"
write_mirror_db "$(sha256sum "$mirror/$long_package" | cut -d " " -f 1)" "$long_package"
check_widths "misread"
rm -f "$mirror/$long_package"
pass "no diagnosis line outruns the screen, even with a long package name"

# A failure with no media explanation must leave the screen as it was, rather
# than gaining a banner or an empty gap where the diagnosis would go.
printf 'error: something else went wrong entirely\n' >"$work/plain.log"

set +e
run_dashboard "$work/plain.log"
set -e

if visible_screen | grep -qF "install medium"; then
  fail "an unrelated failure gets no media banner" "$(visible_screen | tail -n 25)"
fi
visible_screen | grep -qF "Omarchy installation stopped" ||
  fail "an unrelated failure still renders the normal failure screen" "$(visible_screen | tail -n 25)"
pass "an unrelated failure renders the failure screen unchanged"

# The failure menu redraws the screen after uploading or viewing the log, and a
# redraw that drops the diagnosis loses it exactly when someone went looking.
# Those paths need gum and a person at the keyboard, so they are checked here.
missing_redraw=$(grep -n 'render_failure "' "$DASHBOARD" | grep -v 'failure_media_diagnosis' || true)
[[ -z $missing_redraw ]] ||
  fail "every failure-screen redraw carries the diagnosis" "$missing_redraw"
pass "every failure-screen redraw carries the diagnosis"
