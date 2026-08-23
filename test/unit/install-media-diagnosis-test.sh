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

# A ten-line logo, the height of the real one. Without it the dashboard falls
# back to a single centred word and the screen can never be tall enough to
# overflow, which is exactly the case worth testing.
omarchy_share="$work/share"
mkdir -p "$omarchy_share"
# 81 columns wide, like the real logo: the dashboard takes its content width
# from the logo, and a narrow one would truncate every line under test.
{
  printf 'LOGO TOP ROW%*s\n' 69 ''
  for n in 2 3 4 5 6 7 8 9; do printf 'logo row %s%*s\n' "$n" 71 ''; done
  printf 'logo bottom row%*s\n' 66 ''
} >"$omarchy_share/logo.txt"

run_dashboard() {
  local install_log="$1"

  # A real failure carries the failed phase as well as the current one, and
  # that second summary line is another row the screen has to find space for.
  cat >"$state_file" <<'STATE'
{"current_phase": "Installing Arch + Omarchy",
 "phases": [{"name": "Installing Arch + Omarchy", "status": "failed",
             "error": "Pacstrap failed. See /var/log/archinstall.log"}]}
STATE
  : >"$screen"
  script -qefc "stty rows 40 cols 120; PATH='$stubs:$PATH' OMARCHY_PATH='$omarchy_share' OMARCHY_UI_INTERACTIVE=no OMARCHY_UI_FAILURE_ACTION=exit OMARCHY_FAILURE_TAIL_LOG='$install_log' '$DASHBOARD' '$install_log' '$state_file' -- bash -c 'exit 1'" \
    "$screen" >/dev/null 2>&1
}

visible_screen() {
  # Carriage returns as well as escapes: the pty ends every line with one, and
  # a row that looks blank still carries it.
  sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g; s/\r//g' "$screen"
}

dashboard_log="$work/dashboard.log"
write_log "$dashboard_log"

# A real install log is longer than the tail can show, so the tail actually
# spends its whole budget. A short one hides an over-tall screen.
{
  for n in $(seq 1 20); do printf '[dashboard] installing package %s\n' "$n"; done
  cat "$dashboard_log"
} >"$dashboard_log.padded"
mv "$dashboard_log.padded" "$dashboard_log"

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

# The renderer used to drop blank lines, so the break has to be checked where
# it matters: on the screen, not only in the text the helper produced.
package_row=$(visible_screen | grep -nF "$PACKAGE" | grep -v "dashboard" | head -n 1 | cut -d: -f1)
[[ -n $package_row ]] ||
  fail "the screen names the package on its own row" "$(visible_screen | tail -n 25)"
next_row=$(visible_screen | sed -n "$((package_row + 1))p")
[[ -z ${next_row// /} ]] ||
  fail "the screen breaks after the package" "next row was: $next_row"
pass "the dashboard renders the diagnosis once, with the break, and logs it"

# The diagnosis costs rows the log tail's budget knew nothing about, so a
# screen carrying one scrolled its own logo off the top of the console. The
# tail gives those rows back now, which is visible as a shorter tail: count the
# filler lines it reaches, with a diagnosis and without one.
#
# Asserting the logo is still on screen would be the direct test, and it cannot
# be written here: this reads the output stream, which keeps every row ever
# emitted whether or not it stayed visible. Only a terminal emulator could tell
# the difference, so the mechanism is what gets checked.
tail_filler_rows() {
  visible_screen | grep -c "installing package" || true
}

with_diagnosis=$(tail_filler_rows)

# The same log line for line, differing only in the one path that decides
# whether there is a diagnosis at all. Two differently shaped logs would show
# different amounts of filler for reasons that have nothing to do with the
# budget, and the comparison would prove nothing.
elsewhere_log="$work/elsewhere-padded.log"
write_log "$elsewhere_log" "/var/tmp/build/$PACKAGE"
{
  for n in $(seq 1 20); do printf '[dashboard] installing package %s\n' "$n"; done
  cat "$elsewhere_log"
} >"$elsewhere_log.padded"
mv "$elsewhere_log.padded" "$elsewhere_log"

set +e
run_dashboard "$elsewhere_log"
set -e
without_diagnosis=$(tail_filler_rows)

(( with_diagnosis < without_diagnosis )) ||
  fail "the tail gives up rows to the diagnosis" \
    "with: $with_diagnosis, without: $without_diagnosis"
pass "the log tail gives up rows to the diagnosis so the screen still fits"

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

# The package line and the remedy that follows it are two different thoughts,
# so a blank line separates them in every verdict.
check_break() {
  local label="$1" package="$2" out
  out=$(diagnose "$long_log")
  local -a lines
  mapfile -t lines <<<"$out"

  local i
  for i in "${!lines[@]}"; do
    [[ ${lines[i]} == "$package" ]] || continue
    [[ -z ${lines[i + 1]-x} ]] ||
      fail "a break follows the package ($label)" "$out"
    [[ -n ${lines[i + 2]-} ]] ||
      fail "the remedy follows the break ($label)" "$out"
    return 0
  done
  fail "the package is on a line of its own ($label)" "$out"
}

# All three verdicts, since each writes its own sentences.
rm -f "$mirror/$long_package"
check_widths "deleted"
check_break "deleted" "$long_package"
printf 'these are not the bytes that were built\n' >"$mirror/$long_package"
write_mirror_db "$(printf '0%.0s' {1..64})" "$long_package"
check_widths "damaged"
check_break "damaged" "$long_package"
write_mirror_db "$(sha256sum "$mirror/$long_package" | cut -d " " -f 1)" "$long_package"
check_widths "misread"
check_break "misread" "$long_package"
rm -f "$mirror/$long_package"
pass "no diagnosis line outruns the screen, even with a long package name"
pass "a break separates the package from the remedy in every verdict"

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
