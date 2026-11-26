#!/bin/bash
#
# Just try, picked on the installer's welcome, and the soft reboot into Try
# Omarchy behind it.
#
# The boot menus read keys through the firmware, which drives only keyboards
# that speak the USB boot protocol. A wired Apple Magic Keyboard does not: on
# an MSI Z690 no key reached GRUB, and its countdown booted the default entry.
# So the menus boot Install at once, and the welcome offers Just try under
# Start Install, where Linux drives every keyboard. Return installs, as
# before. Try never falls through to an install, and it starts without kexec,
# which the signed kernel lacks.

# The screens start_try draws are stubbed as functions the eval'd start_try
# calls, the stub commands are written with their variables unexpanded, for
# them to expand when they run, and the stubs go first on a PATH each run sets
# for itself.
# shellcheck disable=SC2329,SC2016,SC2030,SC2031

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"
TRY="$ROOT/configs/airootfs/usr/local/bin/omarchy-try"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# --- Just try, from the welcome ---------------------------------------------------

# The choice itself, on the welcome, is test/unit/test_greeter_choice.py.
start_try_source=$(awk '/^start_try\(\) \{/,/^\}/' "$CONFIGURATOR")
[[ -n $start_try_source ]] || fail "the configurator has no start_try"

# omarchy-try succeeds or fails as $WORK/try-status says.
cat >"$work/bin/omarchy-try" <<'EOF'
#!/bin/bash
echo run >>"$WORK/try-calls"
echo "the root image is not mounted at /run/omarchy-root/image" >&2
exit "$(<"$WORK/try-status")"
EOF
chmod +x "$work/bin/omarchy-try"
# gum is only the Back button of a Try that could not start.
printf '#!/bin/bash\necho "gum $1" >>"$WORK/screens"\n' >"$work/bin/gum"
chmod +x "$work/bin/gum"

# start_try as the configurator defines it, with the screens it draws
# stubbed. A soft reboot that is under way leaves start_try sleeping until
# systemd stops it: the sleep stands in for that and ends the run with 42.
run_start_try() {
  : >"$work/try-calls"
  : >"$work/screens"
  (
    export WORK=$work PATH="$work/bin:$PATH"
    t() { printf '%s' "$1"; }
    say() { echo "say $*" >>"$WORK/screens"; }
    step() { echo "step $1" >>"$WORK/screens"; }
    sleep() { exit 42; }
    eval "$start_try_source"
    start_try
  ) </dev/null >/dev/null 2>&1
}

echo 0 >"$work/try-status"
run_start_try
status=$?
((status == 42)) || fail "start_try returned $status after Try started, so the install would run"
[[ $(wc -l <"$work/try-calls") == 1 ]] || fail "omarchy-try ran $(wc -l <"$work/try-calls") times"
pass "Just try starts Try and never returns to the install"

echo 1 >"$work/try-status"
run_start_try
status=$?
((status == 0)) || fail "a Try that could not start returned $status"
grep -qx "step start.failed" "$work/screens" || fail "a Try that could not start said nothing"
grep -q "say the root image is not mounted" "$work/screens" || fail "a Try that could not start did not say why"
pass "a Try that cannot start says why and returns"

# The welcome comes back after a Try that could not start, and only Install
# carries on to the language. OEM media skip the welcome, and a cidata drive
# or a kmscon relaunch never reach this block.
# shellcheck disable=SC2016 # the configurator's text, not this shell's
grep -Pzq '(?s)if \[\[ -z \$resume_stage \]\]; then.*?if ! \$oem_install; then\n    greeter\n    while \[\[ \$greeter_choice == "try" \]\]; do\n      start_try\n      greeter\n    done\n    language_form\n  fi' "$CONFIGURATOR" ||
  fail "the configurator does not go from the welcome to Just try, or on to the language"
grep -q "start_form\|start\.header" "$CONFIGURATOR" && fail "the separate Install or Just try question is still there"
pass "the welcome leads to Just try or the install, and asks nothing else first"

# --- the soft reboot -----------------------------------------------------------

# A medium, an image mount and the commands omarchy-try runs, all recorded.
setup_try() {
  rm -rf "$work/t"
  mkdir -p "$work/t/medium" "$work/t/image/usr/lib/modules/7.2.15" "$work/t/pci" \
    "$work/t/live-modules/7.2.15-t2" "$work/t/omarchy/bin" "$work/t/bin"
  touch "$work/t/medium/omarchy-try.sfs" "$work/t/medium/omarchy-try-nvidia-open.sfs" \
    "$work/t/medium/omarchy-try-t2.sfs"
  : >"$work/t/calls"
  for command in mount umount systemctl; do
    printf '#!/bin/bash\necho "%s $*" >>"$WORK/t/calls"\n[[ " $* " == *" ${FAIL_ON:-none} "* ]] && exit 1\nexit 0\n' "$command" >"$work/t/bin/$command"
  done
  # The image is mounted; /run/nextroot is not.
  printf '#!/bin/bash\n[[ ${@: -1} == "$WORK/t/image" ]]\n' >"$work/t/bin/mountpoint"
  printf '#!/bin/bash\ncase $1 in -r) echo "${KVER:-7.2.15}" ;; -m) echo x86_64 ;; esac\n' >"$work/t/bin/uname"
  printf '#!/bin/bash\nexit "${GSP:-1}"\n' >"$work/t/omarchy/bin/omarchy-hw-nvidia-gsp"
  chmod +x "$work/t/bin/"* "$work/t/omarchy/bin/"*
}

run_try() {
  env WORK="$work" PATH="$work/t/bin:$PATH" \
    OMARCHY_TRY_MEDIUM="$work/t/medium" OMARCHY_TRY_IMAGE="$work/t/image" \
    OMARCHY_TRY_RUN="$work/t/run" OMARCHY_TRY_NEXTROOT="$work/t/nextroot" \
    OMARCHY_PCI_DEVICES_PATH="$work/t/pci" OMARCHY_TRY_LIVE_MODULES="$work/t/live-modules" \
    OMARCHY_SYSFS="$work/t/sys" \
    OMARCHY_PATH="$work/t/omarchy" "$@" bash "$TRY" >"$work/t/out" 2>"$work/t/err"
}

[[ -f $TRY ]] || fail "there is no omarchy-try"

setup_try
run_try
status=$?
((status == 0)) || fail "omarchy-try failed: $(cat "$work/t/err")"
expected="mount -t squashfs -o ro,loop $work/t/medium/omarchy-try.sfs $work/t/run/layer
mount -t tmpfs -o size=50%,mode=0755 omarchy-try $work/t/run/rw
mount -t overlay omarchy-try -o lowerdir=$work/t/run/layer:$work/t/image,upperdir=$work/t/run/rw/upper,workdir=$work/t/run/rw/work,index=off,metacopy=off,redirect_dir=off $work/t/nextroot
systemctl stop omarchy-mirror-verify.service omarchy-root-image-verify.service omarchy-luks-calibrate.service omarchy-target-keyring-early.service
systemctl reset-failed omarchy-mirror-verify.service omarchy-root-image-verify.service omarchy-luks-calibrate.service omarchy-target-keyring-early.service
systemctl soft-reboot"
[[ $(<"$work/t/calls") == "$expected" ]] || fail "omarchy-try ran:
$(cat "$work/t/calls")"
grep -v '^\s*#' "$TRY" | grep -Eq 'kexec|systemctl (reboot|kexec)' && fail "omarchy-try reboots another way than a soft reboot"
[[ ! -s $work/t/err ]] || fail "an empty PCI bus printed: $(cat "$work/t/err")"
pass "the Try layer and a tmpfs go over the image at /run/nextroot, the installer's background work stops, and the soft reboot starts it"

setup_try
mkdir -p "$work/t/pci/0000:01:00.0"
run_try GSP=0
status=$?
((status == 0)) || fail "omarchy-try failed with an NVIDIA card: $(cat "$work/t/err")"
grep -Fq "mount -t squashfs -o ro,loop $work/t/medium/omarchy-try-nvidia-open.sfs $work/t/run/driver" "$work/t/calls" ||
  fail "the NVIDIA layer was not mounted: $(cat "$work/t/calls")"
grep -Fq "lowerdir=$work/t/run/driver:$work/t/run/layer:$work/t/image," "$work/t/calls" ||
  fail "the NVIDIA layer is not on top: $(cat "$work/t/calls")"
pass "a card Omarchy's detector gives nvidia-open gets that layer on top"

setup_try
mkdir -p "$work/t/pci/0000:00:00.0"
echo 0x106b >"$work/t/pci/0000:00:00.0/vendor"
echo 0x1801 >"$work/t/pci/0000:00:00.0/device"
run_try KVER=7.2.15-t2
status=$?
((status == 0)) || fail "omarchy-try failed on a T2 Mac: $(cat "$work/t/err")"
grep -Fq "$work/t/medium/omarchy-try-t2.sfs $work/t/run/driver" "$work/t/calls" || fail "the T2 layer was not mounted: $(cat "$work/t/calls")"
grep -Fq "mount --bind $work/t/live-modules/7.2.15-t2 $work/t/nextroot/usr/lib/modules/7.2.15-t2" "$work/t/calls" ||
  fail "linux-t2's modules were not given to the session: $(cat "$work/t/calls")"
[[ $(tail -1 "$work/t/calls") == "systemctl soft-reboot" ]] || fail "the soft reboot is not the last step"
pass "a T2 Mac gets its layer and the live kernel's modules"

setup_try
run_try FAIL_ON=overlay
status=$?
((status == 1)) || fail "a failed session mount returned $status"
grep -q "soft-reboot" "$work/t/calls" && fail "omarchy-try soft-rebooted after a failed mount"
# Each mount is recorded before it is made, so the failed one is unmounted
# too, which does nothing.
[[ $(grep '^umount' "$work/t/calls" | paste -sd'|') == "umount $work/t/nextroot|umount $work/t/run/rw|umount $work/t/run/layer" ]] ||
  fail "a failed mount left mounts behind: $(cat "$work/t/calls")"
grep -q "could not mount the session root" "$work/t/err" || fail "a failed mount gave no reason"
pass "a failed mount unmounts what it mounted, says why and does not reboot"

setup_try
run_try FAIL_ON=soft-reboot
status=$?
grep -q "^mount .* $work/t/nextroot$" "$work/t/calls" || fail "the session root was never mounted"
[[ $(tail -1 "$work/t/calls") == "umount $work/t/run/layer" ]] || fail "the last step was not taking the layers down: $(tail -1 "$work/t/calls")"

((status == 1)) || fail "a failed soft reboot returned $status"
[[ $(grep -c '^umount' "$work/t/calls") == 3 ]] || fail "a failed soft reboot left mounts behind: $(cat "$work/t/calls")"
grep -qx "systemctl start --no-block omarchy-mirror-verify.service omarchy-root-image-verify.service omarchy-luks-calibrate.service omarchy-target-keyring-early.service" "$work/t/calls" ||
  fail "a refused soft reboot left the medium checks stopped, so the install would have no verdict"
pass "a soft reboot systemd refuses unmounts the session and starts the installer's background work again"

setup_try
rm "$work/t/medium/omarchy-try.sfs"
run_try
status=$?
((status == 1)) || fail "a medium without the Try layer returned $status"
[[ ! -s $work/t/calls ]] || fail "a medium without the Try layer mounted: $(cat "$work/t/calls")"
pass "a medium without the Try layer mounts nothing"

# An earlier attempt that could not finish left the session root mounted: it
# goes before anything else, since systemctl reboot would soft-reboot into it.
setup_try
printf '#!/bin/bash\n[[ ${@: -1} == "$WORK/t/image" || ${@: -1} == "$WORK/t/nextroot" ]]\n' >"$work/t/bin/mountpoint"
run_try
status=$?
((status == 0)) || fail "a leftover session root stopped omarchy-try: $(cat "$work/t/err")"
[[ $(head -1 "$work/t/calls") == "umount -R $work/t/nextroot" ]] || fail "a leftover session root was not unmounted first: $(head -1 "$work/t/calls")"
pass "a session root left by an earlier attempt is unmounted first"

# A leftover that is busy is detached instead: still mounted, it would take
# the installer's own reboot after an install into Try.
setup_try
printf '#!/bin/bash\n[[ ${@: -1} == "$WORK/t/image" || ${@: -1} == "$WORK/t/nextroot" ]]\n' >"$work/t/bin/mountpoint"
run_try FAIL_ON="-R $work/t/nextroot"
status=$?
((status == 0)) || fail "a busy leftover session root stopped omarchy-try: $(cat "$work/t/err")"
[[ $(sed -n 2p "$work/t/calls") == "umount -R -l $work/t/nextroot" ]] || fail "a busy leftover session root was not detached: $(head -3 "$work/t/calls")"
pass "a busy leftover session root is detached, and Try goes on"

# A signal right after the session root is mounted, before it is recorded:
# the root still goes.
setup_try
printf '#!/bin/bash\necho "mount $*" >>"$WORK/t/calls"\n[[ " $* " == *" overlay "* ]] && { touch "$WORK/t/nextroot-mounted"; kill -TERM "$PPID"; }\nexit 0\n' >"$work/t/bin/mount"
printf '#!/bin/bash\n[[ ${@: -1} == "$WORK/t/image" ]] && exit 0\n[[ ${@: -1} == "$WORK/t/nextroot" && -e "$WORK/t/nextroot-mounted" ]]\n' >"$work/t/bin/mountpoint"
run_try
grep -qx "umount -R $work/t/nextroot" "$work/t/calls" || fail "a signal right after the session root's mount left it mounted: $(cat "$work/t/calls")"
pass "a signal right after the session root's mount still takes it down"

# A signal while the medium checks stop does not leave them failed: the
# install would read that as a corrupt medium.
setup_try
printf '#!/bin/bash\necho "systemctl $*" >>"$WORK/t/calls"\n[[ $1 == "stop" ]] && kill -TERM "$PPID"\nexit 0\n' >"$work/t/bin/systemctl"
run_try
grep -q "^systemctl reset-failed" "$work/t/calls" || fail "a signal while the checks stopped skipped their reset: $(cat "$work/t/calls")"
pass "a signal while the medium checks stop still resets them"

# A signal right after a backing mount, before anything else: it still goes.
setup_try
printf '#!/bin/bash\necho "mount $*" >>"$WORK/t/calls"\n[[ " $* " == *" tmpfs "* ]] && kill -TERM "$PPID"\nexit 0\n' >"$work/t/bin/mount"
run_try
grep -qx "umount $work/t/run/rw" "$work/t/calls" || fail "a signal right after the tmpfs mount left it mounted: $(cat "$work/t/calls")"
pass "a signal right after a backing mount still takes it down"

# The wireless and audio controllers the live system ran are let go right
# before the soft reboot, and taken back if it is refused; a GPU stays.
setup_try
sys="$work/t/sys/bus/pci"
for d in 0000:00:02.0:0x030000 0000:00:14.3:0x028000 0000:00:1f.3:0x040380 0000:00:1f.4:0x040100; do
  name=${d%:*}
  mkdir -p "$sys/devices/$name/driver"
  echo "${d##*:}" >"$sys/devices/$name/class"
  : >"$sys/devices/$name/driver/unbind"
done
: >"$sys/drivers_probe"
run_try
for name in 0000:00:14.3 0000:00:1f.3 0000:00:1f.4; do
  [[ $(<"$sys/devices/$name/driver/unbind") == "$name" ]] || fail "$name was not let go before the soft reboot"
done
[[ ! -s $sys/devices/0000:00:02.0/driver/unbind ]] || fail "the GPU was let go"
[[ ! -s $sys/drivers_probe ]] || fail "devices were probed again although the soft reboot was taken"
run_try FAIL_ON=soft-reboot
[[ $(<"$sys/drivers_probe") == "0000:00:1f.4" ]] || fail "a refused soft reboot did not give the released devices back: '$(<"$sys/drivers_probe")'"
pass "wireless and audio controllers are let go for the session, and taken back if the soft reboot is refused"

# A signal while systemd takes the soft reboot does not take its root away.
setup_try
printf '#!/bin/bash\necho "systemctl $*" >>"$WORK/t/calls"\n[[ $1 == "soft-reboot" ]] && kill -TERM "$PPID"\nexit 0\n' >"$work/t/bin/systemctl"
run_try
status=$?
((status == 0)) || fail "a signal during the soft reboot request failed omarchy-try"
grep -q '^umount' "$work/t/calls" && fail "a signal during the soft reboot request unmounted its root: $(cat "$work/t/calls")"
pass "a signal while the soft reboot is requested leaves its root in place"

# --- the Try layer's scripts -----------------------------------------------------

LAYER_SCRIPTS="$ROOT/builder/try-layer"

# A device a driver holds is left alone; one with none is written to its bus's
# drivers_probe, by name. Real sysfs makes each write its own probe.
sys="$work/sys"
mkdir -p "$sys/bus/pci/devices/0000:00:02.0/driver" "$sys/bus/pci/devices/0000:00:14.3" \
  "$sys/bus/usb/devices/1-2:1.0/driver"
: >"$sys/bus/pci/drivers_probe"
: >"$sys/bus/usb/drivers_probe"
OMARCHY_SYSFS=$sys bash "$LAYER_SCRIPTS/omarchy-try-reprobe" || fail "omarchy-try-reprobe failed"
[[ $(<"$sys/bus/pci/drivers_probe") == "0000:00:14.3" ]] || fail "the driverless PCI device was not probed: '$(<"$sys/bus/pci/drivers_probe")'"
[[ ! -s $sys/bus/usb/drivers_probe ]] || fail "a USB interface with a driver was probed again"
pass "the reprobe writes each driverless device, and only those, to its bus"

# The framebuffer console lets go of the card before nouveau is unloaded.
sys="$work/sys2"
mkdir -p "$sys/class/vtconsole/vtcon0" "$sys/class/vtconsole/vtcon1" "$work/handover-bin"
echo "(S) dummy device" >"$sys/class/vtconsole/vtcon0/name"
echo "(M) frame buffer device" >"$sys/class/vtconsole/vtcon1/name"
echo 1 >"$sys/class/vtconsole/vtcon0/bind"
echo 1 >"$sys/class/vtconsole/vtcon1/bind"
printf '#!/bin/bash\necho "modprobe $* after bind=$(<"%s")" >"%s"\n' "$sys/class/vtconsole/vtcon1/bind" "$work/handover-modprobe" >"$work/handover-bin/modprobe"
chmod +x "$work/handover-bin/modprobe"
PATH="$work/handover-bin:$PATH" OMARCHY_SYSFS=$sys bash "$LAYER_SCRIPTS/omarchy-try-nvidia-handover" || fail "the handover failed"
[[ $(<"$sys/class/vtconsole/vtcon0/bind") == 1 ]] || fail "the handover unbound the dummy console"
[[ $(<"$work/handover-modprobe") == "modprobe -r nouveau after bind=0" ]] || fail "nouveau was unloaded before the console let go: $(<"$work/handover-modprobe")"
pass "the NVIDIA handover unbinds the framebuffer console, then unloads nouveau"

# systemd expands $ in ExecStart= itself: the units run these scripts, with no
# shell code of their own.
layer="$ROOT/builder/build-try-layer.sh"
grep -qx 'ExecStart=/usr/local/lib/omarchy-try/omarchy-try-reprobe' "$layer" || fail "the reprobe unit does not run its script"
grep -qx 'ExecStart=/usr/local/lib/omarchy-try/omarchy-try-nvidia-handover' "$layer" || fail "the handover unit does not run its script"
grep -E '^ExecStart=.*\$' "$layer" | grep -v '\$\$' && fail "a unit in the Try layer has a \$ systemd would expand"
pass "the layer's units run their scripts, with nothing for systemd to expand"
