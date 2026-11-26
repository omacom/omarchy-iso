#!/bin/bash
#
# The live system makes the installed system's pacman keyring while the wizard
# is open: the script runs the installer's own two pacman-key commands and
# marks the result complete last, and the unit runs it once the LUKS
# calibration is over.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tool="$ROOT/configs/airootfs/usr/local/bin/omarchy-target-keyring-early"
unit="$ROOT/configs/airootfs/etc/systemd/system/omarchy-target-keyring-early.service"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/keyrings"

fail() { echo "FAIL: $1" >&2; exit 1; }

cat >"$work/bin/pacman-key" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
[[ -e $DIR/complete ]] && echo "complete existed during: $*" >>"$CALLS"
[[ $* != *"$FAIL_ON"* || -z $FAIL_ON ]] || exit 1
touch "$2/made-by-${3#--}"
STUB
cat >"$work/bin/uname" <<'STUB'
#!/bin/bash
echo "${FAKE_MACHINE:-x86_64}"
STUB
# The calibration unit is active for the first $CALIBRATING checks.
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
[[ $* == "is-active --quiet omarchy-luks-calibrate.service" ]] || exit 1
left=$(cat "$CALIBRATING_FILE")
((left > 0)) || exit 3
echo $((left - 1)) >"$CALIBRATING_FILE"
[[ ! -s $CALLS ]] || echo "calibration still ran after: $(tail -n1 "$CALLS")" >>"$CALLS"
STUB
cat >"$work/bin/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$work/bin"/*

run() {
  : >"$work/calls"
  echo "${CALIBRATING:-0}" >"$work/calibrating"
  PATH="$work/bin:$PATH" CALLS="$work/calls" DIR="$work/run" FAIL_ON="${FAIL_ON:-}" \
    CALIBRATING_FILE="$work/calibrating" OMARCHY_LUKS_CALIBRATION_RESULT="$work/result.json" \
    OMARCHY_TARGET_KEYRING_DIR="$work/run" OMARCHY_KEYRINGS_DIR="$work/keyrings" bash "$tool"
}
touch "$work/result.json"

# Without the keyring packages there is nothing to make it from.
run || fail "a live system without the keyring packages is not an error"
[[ ! -s $work/calls && ! -e $work/run/complete ]] || fail "nothing is made without the keyring packages"

touch "$work/keyrings/archlinux.gpg" "$work/keyrings/omarchy.gpg"
run || fail "the keyring is made"
expected="--gpgdir $work/run/gnupg --init
--gpgdir $work/run/gnupg --populate-from $work/keyrings --populate archlinux omarchy"
[[ $(cat "$work/calls") == "$expected" ]] || fail "init, then populate from the live keyrings: $(cat "$work/calls")"
[[ -e $work/run/complete ]] || fail "a finished keyring is marked complete"
finished=$(cat "$work/run/complete")
now=$(date +%s)
[[ $finished =~ ^[0-9]+$ ]] && ((finished <= now + 1 && finished > now - 60)) || fail "the marker holds the time it was finished: $finished"
[[ ! -e $work/run/complete.new ]] || fail "the marker is renamed into place"

# A clock set back while the keyring is made must not date the marker before
# the keyring: it then holds the time at the start plus the time that took.
cat >"$work/bin/date" <<'STUB'
#!/bin/bash
n=$(cat "$DATE_CALLS" 2>/dev/null || echo 0)
echo $((n + 1)) >"$DATE_CALLS"
if ((n == 0)); then echo 2000000000; else echo 1999990000; fi
STUB
chmod +x "$work/bin/date"
rm -f "$work/date-calls"
DATE_CALLS="$work/date-calls" run || fail "a run across a clock change succeeds"
stepped=$(cat "$work/run/complete")
((stepped >= 2000000000 && stepped <= 2000000060)) || fail "a clock set back does not date the marker before the keyring: $stepped"
rm "$work/bin/date"
[[ $(stat -c %a "$work/run/gnupg") == 700 ]] || fail "the keyring directory is 0700"

# A second run starts over, and is not complete until it has finished.
touch "$work/run/gnupg/left-over"
run || fail "a second run succeeds"
[[ ! -e $work/run/gnupg/left-over ]] || fail "a second run starts from an empty directory"
! grep -q "complete existed" "$work/calls" || fail "complete is removed before the keyring is remade"

# It waits for the LUKS calibration to end before it starts gpg, and makes
# nothing when that calibration left no result.
CALIBRATING=3 run || fail "a run that waited succeeds"
[[ $(cat "$work/calibrating") == 0 ]] || fail "it waits until the calibration is over"
! grep -q "calibration still ran" "$work/calls" || fail "gpg starts only once the calibration is over"
rm "$work/result.json" "$work/run/complete"
run || fail "a calibration without a result is not an error"
[[ ! -s $work/calls && ! -e $work/run/complete ]] || fail "no keyring is made when the calibration left no result"
touch "$work/result.json"

# A run that fails leaves nothing marked complete.
if FAIL_ON=--populate run 2>/dev/null; then fail "a failed populate fails the unit"; fi
[[ ! -e $work/run/complete ]] || fail "a failed run is not marked complete"

# Arch Linux ARM's keyring joins the list on aarch64, and is needed there.
if FAKE_MACHINE=aarch64 run; then :; else fail "aarch64 without its keyring is not an error"; fi
[[ ! -s $work/calls ]] || fail "aarch64 waits for archlinuxarm.gpg"
touch "$work/keyrings/archlinuxarm.gpg"
FAKE_MACHINE=aarch64 run || fail "the aarch64 keyring is made"
grep -q -- "--populate archlinux omarchy archlinuxarm$" "$work/calls" || fail "aarch64 populates archlinuxarm too"

grep -q '^Type=oneshot$' "$unit" || fail "the unit is a oneshot, so a start joins a running one"
grep -q '^After=.*omarchy-luks-calibrate.service' "$unit" || fail "the unit is ordered after the LUKS calibration"
grep -q '^ConditionPathExists=/run/archiso/bootmnt$' "$unit" || fail "the unit only runs on the live ISO"
wanted="$ROOT/configs/airootfs/etc/systemd/system/multi-user.target.wants/omarchy-target-keyring-early.service"
[[ -L $wanted && $(readlink "$wanted") == ../omarchy-target-keyring-early.service ]] || fail "the unit is enabled"
grep -q '"/usr/local/bin/omarchy-target-keyring-early"\]="0:0:755"' "$ROOT/configs/profiledef.sh" || fail "the script is executable on the ISO"

echo "ok: the live system makes the target's pacman keyring before the install"
