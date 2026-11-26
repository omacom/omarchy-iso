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
# stubbed. A soft reboot that is under way leaves start_try waiting until
# systemd stops it: timeout stands in for that and ends the run with 124.
run_start_try() {
  : >"$work/try-calls"
  : >"$work/screens"
  (
    export WORK=$work PATH="$work/bin:$PATH"
    t() { printf '%s' "$1"; }
    say() { echo "say $*" >>"$WORK/screens"; }
    step() { echo "step $1" >>"$WORK/screens"; }
    eval "$start_try_source"
    start_try
  ) </dev/null >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && ((waited < 30)); do
    command sleep 0.1
    ((++waited))
  done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}

echo 0 >"$work/try-status"
run_start_try
status=$?
((status == 124)) || fail "start_try returned $status after Try started, so the install would run"
[[ $(wc -l <"$work/try-calls") == 1 ]] || fail "omarchy-try ran $(wc -l <"$work/try-calls") times"
pass "Just try starts Try and never returns to the install"

# Nothing it waits with is a program: one loading from the stick when the soft
# reboot's SIGTERM comes held the installer's session up 5 s and failed it.
waiting=$(sed -n '/omarchy-try 2>&1/,/^  fi$/p' <<<"$start_try_source")
grep -Eq "(^|[^a-z_])(sleep|tail|cat)( |$)" <<<"$waiting" && fail "start_try waits for the soft reboot with a program: $waiting"
pass "start_try waits for the soft reboot in bash alone"

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
    OMARCHY_SYSFS="$work/t/sys" OMARCHY_TRY_OFFLINE_MIRROR="$work/t/no-mirror" \
    OMARCHY_TRY_PACMAN_CONF="$work/t/pacman.conf" \
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
systemctl stop omarchy-mirror-verify.service omarchy-root-image-verify.service omarchy-luks-calibrate.service omarchy-target-keyring-early.service omarchy-cache-warm.service
systemctl reset-failed omarchy-mirror-verify.service omarchy-root-image-verify.service omarchy-luks-calibrate.service omarchy-target-keyring-early.service omarchy-cache-warm.service
systemctl soft-reboot"
[[ $(<"$work/t/calls") == "$expected" ]] || fail "omarchy-try ran:
$(cat "$work/t/calls")"
grep -v '^\s*#' "$TRY" | grep -Eq 'kexec|systemctl (reboot|kexec)' && fail "omarchy-try reboots another way than a soft reboot"
[[ ! -s $work/t/err ]] || fail "an empty PCI bus printed: $(cat "$work/t/err")"
pass "the Try layer and a tmpfs go over the image at /run/nextroot, the installer's background work stops, and the soft reboot starts it"

# The session's hardware setup takes its packages where an install does: the
# stick's offline repository, read-only, through the live pacman.conf, with the
# hooks that build boot images masked.
setup_try
mkdir -p "$work/t/mirror"
printf '[options]\nSigLevel = Never\n\n[offline]\nServer = file://%s/\n' "$work/t/mirror" >"$work/t/pacman.conf"
run_try OMARCHY_TRY_OFFLINE_MIRROR="$work/t/mirror"
status=$?
((status == 0)) || fail "omarchy-try failed with an offline repository: $(cat "$work/t/err")"
grep -Fqx "mount --bind -o ro $work/t/mirror $work/t/nextroot$work/t/mirror" "$work/t/calls" ||
  fail "the offline repository was not given to the session: $(cat "$work/t/calls")"
[[ $(sed -n 1,4p "$work/t/run/pacman-offline.conf") == "[options]
CacheDir = $work/t/mirror/
HookDir = /etc/pacman.d/hooks/
HookDir = /usr/local/lib/omarchy-try/pacman-hooks/" ]] ||
  fail "the session's offline pacman.conf is not the live one with the mirror and masked hooks: $(cat "$work/t/run/pacman-offline.conf")"
grep -qx '\[offline\]' "$work/t/run/pacman-offline.conf" || fail "the session's offline pacman.conf lost the offline repository"
pass "the session gets the stick's offline repository, and a pacman.conf for it with boot image hooks masked"

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
grep -qx "systemctl start --no-block omarchy-mirror-verify.service omarchy-root-image-verify.service omarchy-luks-calibrate.service omarchy-target-keyring-early.service omarchy-cache-warm.service" "$work/t/calls" ||
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
grep -qx 'ExecStart=/usr/local/lib/omarchy-try/omarchy-try-hardware --system' "$layer" || fail "the hardware unit does not run its script"
grep -qx 'ExecStart=/usr/local/lib/omarchy-try/omarchy-try-hardware --user' "$layer" || fail "the user hardware unit does not run its script"
grep -qx 'ExecStart=/usr/local/lib/omarchy-try/omarchy-try-welcome' "$layer" || fail "the welcome unit does not run its script"
grep -E '^ExecStart=.*\$' "$layer" | grep -v '\$\$' && fail "a unit in the Try layer has a \$ systemd would expand"
pass "the layer's units run their scripts, with nothing for systemd to expand"

# The welcome goes on top: after Omarchy's first-run has marked itself done
# and its prompts that wait for the network have gone, and never later than
# its wait.
wl="$work/welcome"
mkdir -p "$wl/bin" "$wl/home/.local/state/omarchy/done" "$wl/install/user/first-run"
printf '#!/bin/bash\nexit 0\n' >"$wl/bin/omarchy-notification-wait"
printf '#!/bin/bash\necho "send $*" >>"$WL/calls"\n' >"$wl/bin/omarchy-notification-send"
chmod +x "$wl/bin/"*
printf 'sleep 3\n' >"$wl/install/user/first-run/wifi.sh"
run_welcome() {
  rm -f "$wl/home/.local/state/omarchy/try-welcomed"
  : >"$wl/calls"
  env WL="$wl" HOME="$wl/home" XDG_STATE_HOME= PATH="$wl/bin:$PATH" OMARCHY_TRY_WELCOME_WAIT="${1:-10}" \
    bash "$LAYER_SCRIPTS/omarchy-try-welcome"
}
: >"$wl/home/.local/state/omarchy/done/first-run-user"
bash "$wl/install/user/first-run/wifi.sh" &
first_run=$!
started=$SECONDS
run_welcome || fail "the welcome failed"
((SECONDS - started >= 2)) || fail "the welcome came before first-run's network prompts were done"
wait "$first_run"
grep -q 'send .* Try Omarchy!' "$wl/calls" || fail "the welcome was not sent: $(cat "$wl/calls")"
rm "$wl/home/.local/state/omarchy/done/first-run-user"
started=$SECONDS
run_welcome 2 || fail "the welcome failed with no first-run"
{ ((SECONDS - started <= 5)) && grep -q 'Try Omarchy!' "$wl/calls"; } || fail "the welcome waited past its wait for a first-run that never ends"
pass "the welcome comes after Omarchy's first-run notifications, and never later than its wait"

# pacman for the session's hardware setup: a kernel, its headers and a DKMS
# module, told by their files, are recorded without them; the rest installs.
pw="$work/pw"
mkdir -p "$pw/pkgs"
mkpkg() { # name, a file in it
  mkdir -p "$pw/build/$1/${2%/*}"
  : >"$pw/build/$1/$2"
  bsdtar -cf "$pw/pkgs/$1.pkg.tar" -C "$pw/build/$1" "${2%%/*}"
}
mkpkg linux-t2 usr/lib/modules/7.2.15-t2/vmlinuz
mkpkg linux-t2-headers usr/lib/modules/7.2.15-t2/build/Makefile
mkpkg foo-dkms usr/src/foo-1.0/dkms.conf
mkpkg linux-firmware-marvell usr/lib/firmware/mrvl/sd8897_uapsta.bin
cat >"$pw/pacman" <<'EOF'
#!/bin/bash
if [[ $1 == -Sp ]]; then
  echo "file://$PW/pkgs/${*: -1}.pkg.tar"
  # Without --nodeps --nodeps, pacman lists the dependencies it would pull too.
  [[ " $* " == *" --nodeps --nodeps "* ]] || echo "file://$PW/pkgs/a-dependency.pkg.tar"
  exit 0
fi
echo "$*" >>"$PW/calls"
EOF
chmod +x "$pw/pacman"
PW=$pw OMARCHY_TRY_PACMAN="$pw/pacman" bash "$LAYER_SCRIPTS/live-bin/pacman" \
  -S --noconfirm --needed -- linux-t2 linux-firmware-marvell linux-t2-headers foo-dkms 2>/dev/null ||
  fail "the hardware setup's pacman failed"
[[ $(<"$pw/calls") == "-S --dbonly --nodeps --nodeps --noconfirm --needed -- linux-t2 linux-t2-headers foo-dkms
-S --noconfirm --needed -- linux-firmware-marvell" ]] || fail "the hardware setup's pacman ran: $(cat "$pw/calls")"
: >"$pw/calls"
PW=$pw OMARCHY_TRY_PACMAN="$pw/pacman" bash "$LAYER_SCRIPTS/live-bin/pacman" -Q linux-t2
[[ $(<"$pw/calls") == "-Q linux-t2" ]] || fail "a query did not reach pacman as it was: $(cat "$pw/calls")"
pass "the hardware setup records kernels, headers and DKMS modules without their files, and installs the rest"

# The hardware setup an install runs, run in the session: Omarchy's own entry
# point as root, then the per-user hardware steps install/user/all.sh lists,
# and what changed applied as a boot would.
hw="$work/hw"
mkdir -p "$hw/root/etc/udev/rules.d" "$hw/omarchy/bin" "$hw/omarchy/install/user" "$hw/lib/live-bin"
printf '#!/bin/bash\necho "omarchy-try-reprobe" >>"$HW/calls"\n' >"$hw/lib/omarchy-try-reprobe"
chmod +x "$hw/lib/omarchy-try-reprobe"
cat >"$hw/omarchy/install/user/all.sh" <<'EOF'
run_logged "$OMARCHY_INSTALL/user/theme.sh"
run_logged "$OMARCHY_INSTALL/user/hardware/asus/fix-mic.sh"
run_logged "$OMARCHY_INSTALL/user/hardware/dell/xps13-text-scaling.sh"
EOF
cat >"$hw/omarchy/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$HW/calls"
# The session is up from the check after SESSION_AFTER of them.
if [[ " $* " == *" is-active -q graphical-session.target "* ]]; then
  echo >>"$HW/session-checks"
  (($(wc -l <"$HW/session-checks") > ${SESSION_AFTER:-0}))
fi
EOF
chmod +x "$hw/omarchy/bin/systemctl"
cat >"$hw/omarchy/bin/omarchy-apply-hardware" <<'EOF'
#!/bin/bash
echo "omarchy-apply-hardware $*" >>"$HW/calls"
if [[ -n ${CHANGE:-} ]]; then
  # One for the boot, one for hibernation, which only a hibernation starts.
  mkdir -p "$HW/root/etc/systemd/system/multi-user.target.wants" "$HW/root/etc/systemd/system/hibernate.target.wants"
  ln -sfn /usr/lib/systemd/system/new-haptics.service "$HW/root/etc/systemd/system/multi-user.target.wants/new-haptics.service"
  ln -sfn /usr/lib/systemd/system/pre-hibernate.service "$HW/root/etc/systemd/system/hibernate.target.wants/pre-hibernate.service"
  if [[ -n ${FIRMWARE:-} ]]; then
    # Under updates/, as ath12k-board-fallback puts board data, in a folder
    # that was there, with an old mtime, as pacman keeps a packaged file's.
    : >"$HW/root/usr/lib/firmware/updates/ath12k/WCN7850/hw2.0/board-2.bin.zst"
    touch -d 2020-01-01 "$HW/root/usr/lib/firmware/updates/ath12k/WCN7850/hw2.0/board-2.bin.zst"
  fi
  if [[ -n ${IPU:-} ]]; then
    mkdir -p "$HW/root/usr/lib/firmware/intel/ipu"
    : >"$HW/root/usr/lib/firmware/intel/ipu/ipu7ptl_fw.bin"
  fi
  if [[ -n ${USERUNIT:-} ]]; then
    # A drop-in in a folder that was there before.
    : >"$HW/root/usr/lib/systemd/user/pipewire.service.d/10-camera.conf"
  fi
  # As dell-xps-touchpad-haptics ships it, as gb10/cpuidle.sh writes it, and
  # lines an add event does not reach.
  printf '%s\n' '# power' \
    'ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:19.0", ATTR{power/control}="on"' \
    'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="i2c_designware.0|i2c_designware.1", ATTR{power/control}="on"' \
    'ACTION=="add|online", SUBSYSTEM=="cpu", TEST=="cpuidle/state1", RUN+="/usr/bin/true"' \
    'ACTION=="online", SUBSYSTEM=="cpu", ATTR{online}="1"' \
    'ACTION=="change", SUBSYSTEM=="power_supply", RUN+="/usr/bin/true"' \
    >"$HW/root/etc/udev/rules.d/99-new.rules"
  [[ -z ${ANYDEVICE:-} ]] || echo 'ACTION=="add", ATTRS{idVendor}=="06cb", TAG+="uaccess"' >"$HW/root/etc/udev/rules.d/98-any.rules"
fi
EOF
printf '#!/bin/bash\necho "runuser ${*: -1}" >>"$HW/calls"\n' >"$hw/omarchy/bin/runuser"
printf '#!/bin/bash\necho "udevadm $*" >>"$HW/calls"\n' >"$hw/omarchy/bin/udevadm"
printf '#!/bin/bash\necho "pacman $*" >>"$HW/calls"\n' >"$hw/omarchy/bin/pacman"
# The firmware each module names and the modules it needs, as Linux 7.3's
# modules carry them: ath12k's PCI driver, ath12k_wifi7, names none itself.
cat >"$hw/omarchy/bin/modinfo" <<'EOF'
#!/bin/bash
case "$2 ${*: -1}" in
"firmware ath12k") printf '%s\n' 'ath12k/WCN7850/hw2.0/*' 'ath12k/QCN9274/hw2.0/*' ;;
"depends ath12k_wifi7") echo ath12k,mac80211,mhi,cfg80211 ;;
"firmware snd_sof_pci_intel_ptl") printf '%s\n' 'intel/sof-ipc4/ptl/sof-ptl.ri' ;;
esac
EOF
chmod +x "$hw/omarchy/bin/"*
run_hardware() {
  : >"$hw/calls"
  rm -f "$hw/session-checks"
  HW=$hw OMARCHY_TRY_USER=$(id -un) OMARCHY_TRY_ROOT="$hw/root" OMARCHY_PATH="$hw/omarchy" \
    OMARCHY_TRY_LIB="$hw/lib" OMARCHY_SYSFS="$hw/no-sys" "$@"
}
mkdir -p "$hw/root/etc/systemd/system/graphical.target.wants" "$hw/root/usr/lib/firmware/updates/ath12k/WCN7850/hw2.0" \
  "$hw/root/usr/lib/systemd/user/pipewire.service.d"
ln -sfn /usr/lib/systemd/system/sddm.service "$hw/root/etc/systemd/system/graphical.target.wants/sddm.service"
run_hardware env CHANGE=1 bash "$LAYER_SCRIPTS/omarchy-try-hardware" --system || fail "the session's hardware setup failed"
[[ $(<"$hw/calls") == "pacman -Sy --noconfirm
omarchy-apply-hardware --install-user $(id -un)
systemctl daemon-reload
udevadm control --reload
udevadm trigger --action=add --subsystem-match=pci --sysname-match=0000:00:19.0
udevadm trigger --action=add --subsystem-match=platform --sysname-match=i2c_designware.0 --sysname-match=i2c_designware.1
udevadm trigger --action=add --subsystem-match=cpu
udevadm settle --timeout=30
systemctl start --no-block new-haptics.service
omarchy-try-reprobe" ]] || fail "the session's hardware setup ran: $(cat "$hw/calls")"
# A rule that names no device could match any: everything is never
# triggered, and the run says the rule waits for the next boot.
rm -f "$hw/root/etc/udev/rules.d/"*.rules
run_hardware env CHANGE=1 ANYDEVICE=1 bash "$LAYER_SCRIPTS/omarchy-try-hardware" --system 2>"$hw/err" ||
  fail "the session's hardware setup failed with a rule for any device"
grep -q 'udevadm trigger --action=add$' "$hw/calls" && fail "every device was triggered: $(cat "$hw/calls")"
grep -q '98-any.rules names no device' "$hw/err" || fail "a rule that names no device was skipped without a word: $(cat "$hw/err")"
rm -rf "$hw/root/etc/systemd/system/multi-user.target.wants" "$hw/root/etc/systemd/system/hibernate.target.wants"
run_hardware bash "$LAYER_SCRIPTS/omarchy-try-hardware" --system || fail "the session's hardware setup failed with nothing to do"
[[ $(<"$hw/calls") == "pacman -Sy --noconfirm
omarchy-apply-hardware --install-user $(id -un)
systemctl daemon-reload
omarchy-try-reprobe" ]] || fail "a hardware setup that changed nothing still reloaded or started: $(cat "$hw/calls")"
# Firmware the setup brought, a package's or what its hook wrote, binds a
# Wi-Fi or audio controller again when its own module names it; others, and
# a controller whose module names other firmware, are left alone. On a Dell
# XPS 16 the IPU7 camera's firmware unbound the SOF audio mid-probe.
sys="$hw/sys"
mkdir -p "$sys/drivers/ath12k_wifi7_pci" "$sys/drivers/sof-audio-pci-intel-ptl" "$sys/module/ath12k_wifi7" \
  "$sys/module/snd_sof_pci_intel_ptl" "$sys/bus/pci/devices/0000:01:00.0" "$sys/bus/pci/devices/0000:00:1f.3" \
  "$sys/bus/pci/devices/0000:00:02.0"
for driver in ath12k_wifi7_pci sof-audio-pci-intel-ptl; do
  : >"$sys/drivers/$driver/unbind"
  : >"$sys/drivers/$driver/bind"
done
ln -sfn "$sys/module/ath12k_wifi7" "$sys/drivers/ath12k_wifi7_pci/module"
ln -sfn "$sys/module/snd_sof_pci_intel_ptl" "$sys/drivers/sof-audio-pci-intel-ptl/module"
ln -sfn "$sys/drivers/ath12k_wifi7_pci" "$sys/bus/pci/devices/0000:01:00.0/driver"
ln -sfn "$sys/drivers/sof-audio-pci-intel-ptl" "$sys/bus/pci/devices/0000:00:1f.3/driver"
ln -sfn "$sys/drivers/ath12k_wifi7_pci" "$sys/bus/pci/devices/0000:00:02.0/driver"
echo 0x028000 >"$sys/bus/pci/devices/0000:01:00.0/class"
echo 0x040100 >"$sys/bus/pci/devices/0000:00:1f.3/class"
echo 0x030000 >"$sys/bus/pci/devices/0000:00:02.0/class"
run_hardware env OMARCHY_SYSFS="$sys" CHANGE=1 FIRMWARE=1 bash "$LAYER_SCRIPTS/omarchy-try-hardware" --system ||
  fail "the session's hardware setup failed with firmware"
[[ $(<"$sys/drivers/ath12k_wifi7_pci/unbind") == "0000:01:00.0" && $(<"$sys/drivers/ath12k_wifi7_pci/bind") == "0000:01:00.0" ]] ||
  fail "the Wi-Fi controller was not bound again after its board data came: '$(<"$sys/drivers/ath12k_wifi7_pci/unbind")'"
[[ ! -s $sys/drivers/sof-audio-pci-intel-ptl/unbind ]] || fail "the audio controller was unbound for firmware that is not its own"
grep -qx 'udevadm settle --timeout=30' "$hw/calls" || fail "a controller was bound again before udev settled: $(cat "$hw/calls")"
: >"$sys/drivers/ath12k_wifi7_pci/unbind"
: >"$sys/drivers/ath12k_wifi7_pci/bind"
run_hardware env OMARCHY_SYSFS="$sys" CHANGE=1 IPU=1 bash "$LAYER_SCRIPTS/omarchy-try-hardware" --system ||
  fail "the session's hardware setup failed with the camera's firmware"
[[ ! -s $sys/drivers/ath12k_wifi7_pci/unbind && ! -s $sys/drivers/sof-audio-pci-intel-ptl/unbind ]] ||
  fail "a controller was bound again for the camera's firmware"
run_hardware env OMARCHY_SYSFS="$sys" CHANGE=1 bash "$LAYER_SCRIPTS/omarchy-try-hardware" --system ||
  fail "the session's hardware setup failed without firmware"
[[ ! -s $sys/drivers/ath12k_wifi7_pci/unbind ]] || fail "a controller was bound again though no firmware came"
# User units the setup brought reach the user manager by a reload once the
# session is up, never pacman's hook's re-execution (masked for the run).
run_hardware env CHANGE=1 USERUNIT=1 SESSION_AFTER=1 bash "$LAYER_SCRIPTS/omarchy-try-hardware" --system ||
  fail "the session's hardware setup failed with a user unit"
[[ $(grep -c "^systemctl --user -M $(id -un)@ " "$hw/calls") == 3 &&
  $(grep "^systemctl --user -M $(id -un)@ " "$hw/calls" | tail -1) == "systemctl --user -M $(id -un)@ daemon-reload" ]] ||
  fail "the user manager was not reloaded after the session came up: $(cat "$hw/calls")"
run_hardware bash "$LAYER_SCRIPTS/omarchy-try-hardware" --user || fail "the session's user hardware setup failed"
[[ $(<"$hw/calls") == "runuser $hw/omarchy/install/user/hardware/asus/fix-mic.sh
runuser $hw/omarchy/install/user/hardware/dell/xps13-text-scaling.sh" ]] ||
  fail "the session's user hardware setup ran: $(cat "$hw/calls")"
pass "the session runs the install's hardware setup and its user steps, and applies what they changed"
