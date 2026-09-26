#!/bin/bash
#
# Unit tests for omarchy-try-setup — the install/setup worker the dashboard runs.
# Runs against a sandbox with mount/pacman/systemctl/useradd/passwd/runuser/chown
# stubbed on PATH; each stub logs its call so the cases assert what ran.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SETUP="$ROOT/configs/airootfs/usr/local/bin/omarchy-try-setup"

pass() { printf 'ok - %s\n' "$1"; }
fail() { local d="$1" x="${2:-}"; [[ -n $x ]] && printf '%s\n' "$x" >&2; printf 'not ok - %s\n' "$d" >&2; exit 1; }

work=$(mktemp -d); trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
stub_dir="$work/stubs"; mkdir -p "$stub_dir"
# pacman remembers what -S installed and answers -Qq from that, so a second run
# sees the set already present the way a second T in the same boot does.
cat >"$stub_dir/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$TEST_LOG"
[[ ${PACMAN_FAIL:-} == 1 ]] && exit 1
installed="${TEST_LOG%/*}/.installed"
case $1 in
  -Qq) cat "$installed" 2>/dev/null; exit 0 ;;
  -S|-Sy) for a in "$@"; do [[ $a == -* || $a == limine* || $a == snapper ]] || echo "$a" >>"$installed"; done ;;
esac
exit 0
STUB
for cmd in mount passwd runuser chown; do
  cat >"$stub_dir/$cmd" <<STUB
#!/bin/bash
printf '$cmd %s\n' "\$*" >>"\$TEST_LOG"
[[ \${${cmd^^}_FAIL:-} == 1 ]] && exit 1
exit 0
STUB
done
cat >"$stub_dir/df" <<'STUB'
#!/bin/bash
printf 'df %s\n' "$*" >>"$TEST_LOG"
printf 'Avail\n%s\n' "${COWSPACE_AVAIL_KIB:-8000000}"
exit 0
STUB
cat >"$stub_dir/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
[[ -n ${SYSTEMCTL_FAIL_ON:-} && $* == "$SYSTEMCTL_FAIL_ON" ]] && exit 1
exit 0
STUB
# Network is "up" unless a case says otherwise; tzupdate only logs.
cat >"$stub_dir/nm-online" <<'STUB'
#!/bin/bash
printf 'nm-online %s\n' "$*" >>"$TEST_LOG"
[[ ${OFFLINE:-} == 1 ]] && exit 1
exit 0
STUB
cat >"$stub_dir/tzupdate" <<'STUB'
#!/bin/bash
printf 'tzupdate %s\n' "$*" >>"$TEST_LOG"
exit 0
STUB
# useradd records that it ran; id reports the user present only after that, so
# a second run in the same sandbox takes the user-exists path like a second T.
cat >"$stub_dir/useradd" <<'STUB'
#!/bin/bash
printf 'useradd %s\n' "$*" >>"$TEST_LOG"
[[ ${USERADD_FAIL:-} == 1 ]] && exit 1
touch "${TEST_LOG%/*}/.useradd-ran"
exit 0
STUB
cat >"$stub_dir/id" <<'STUB'
#!/bin/bash
[[ $* == *try* && ! -e ${TEST_LOG%/*}/.useradd-ran ]] && exit 1
exit 0
STUB
chmod +x "$stub_dir"/*

new_sandbox() {
  sandbox=$(mktemp -d "$work/sb.XXXXXX")
  mkdir -p "$sandbox/usr/share/omarchy-iso" "$sandbox/etc/pacman.d" \
    "$sandbox/run/archiso/cowspace" "$sandbox/home/try/.config/hypr" "$sandbox/run/omarchy-try"
  # name, archive, installed KiB — the three columns build-iso.sh writes
  printf 'omarchy omarchy.pkg 1048576\nhyprland hyprland.pkg 1048576\nchromium chromium.pkg 524288\n' \
    >"$sandbox/usr/share/omarchy-iso/try-packages"
  : >"$sandbox/home/try/.config/hypr/bindings.lua"
  : >"$sandbox/home/try/.config/hypr/autostart.lua"
  state="$sandbox/run/omarchy-try/state.json"
  export TEST_LOG="$sandbox/calls.log"; : >"$TEST_LOG"
}
run() { PATH="$stub_dir:$PATH" "$SETUP" "$state" "${1:-no}" "$sandbox"; }

# Happy path (no nvidia): every setup step runs and the state file finishes.
new_sandbox
run >/dev/null 2>&1 || fail "happy path exits zero"
grep -q '^mount -o remount,size=100% .*/run/archiso/cowspace$' "$TEST_LOG" || fail "grows the overlay to the whole of RAM"
for h in 60-mkinitcpio-remove.hook 80-limine-efi-deploy.hook 90-mkinitcpio-install.hook; do
  [[ $(readlink "$sandbox/etc/pacman.d/hooks/$h") == /dev/null ]] || fail "masks $h"
done
grep -q '^pacman -Sy --needed --noconfirm zram-generator$' "$TEST_LOG" || fail "syncs the db and installs zram-generator first"
line=$(grep '^pacman -S --needed --noconfirm .* omarchy hyprland chromium$' "$TEST_LOG") || fail "installs the try set after the sync" "$(<"$TEST_LOG")"
for p in limine limine-mkinitcpio-hook limine-snapper-sync snapper; do
  [[ $line == *"--assume-installed $p"* ]] || fail "assumes $p" "$line"
done
grep -q '^systemctl stop iwd.service systemd-networkd.service systemd-networkd.socket$' "$TEST_LOG" || fail "stops iwd/networkd"
grep -q '^systemctl start NetworkManager.service$' "$TEST_LOG" || fail "starts NetworkManager"
# --no-block is load-bearing: power-profiles-daemon orders after
# time-sync.target, and on a machine with no network systemd-time-wait-sync
# never finishes, so a blocking start never returns and the install hangs
# forever at the progress bar. Seen air-gapped in QEMU.
grep -q '^systemctl start --no-block bluetooth.service power-profiles-daemon.service$' "$TEST_LOG" || fail "starts the shell's daemons without waiting on them" "$(<"$TEST_LOG")"
grep -q '^systemctl daemon-reload$' "$TEST_LOG" || fail "reloads so the zram generator runs"
grep -q '^systemctl start systemd-zram-setup@zram0.service$' "$TEST_LOG" || fail "starts zram"
# zram has to be up before the install fills the overlay, not after.
zram_at=$(grep -n '^systemctl start systemd-zram-setup' "$TEST_LOG" | cut -d: -f1)
gen_at=$(grep -n '^pacman -Sy --needed --noconfirm zram-generator$' "$TEST_LOG" | cut -d: -f1)
set_at=$(grep -n '^pacman -S --needed' "$TEST_LOG" | cut -d: -f1)
df_at=$(grep -n '^df -k --output=avail' "$TEST_LOG" | cut -d: -f1)
# zram has to be up before the overlay is judged and before it is filled: the
# check is asking whether the machine can hold the set, and compressed swap is
# part of the answer.
(( gen_at < zram_at && zram_at < df_at && df_at < set_at )) \
  || fail "generator, zram, capacity check, then the install" "$(<"$TEST_LOG")"
grep -q '^df -k --output=avail .*/run/archiso/cowspace$' "$TEST_LOG" || fail "checks the overlay's capacity"
grep -q '^pacman -Qq$' "$TEST_LOG" || fail "asks pacman what is already installed"
grep -q '^tzupdate' "$TEST_LOG" || fail "sets the timezone when the network is up"
grep -q '^useradd -m -G wheel,video,input,audio -s /bin/bash try$' "$TEST_LOG" || fail "creates the try user"
grep -q '^chown -R try:try .*/home/try$' "$TEST_LOG" || fail "hands the seeded home to the try user"
[[ $(<"$sandbox/etc/sudoers.d/try") == 'try ALL=(ALL) NOPASSWD: ALL' ]] || fail "writes sudoers"
# Locked, not empty: nothing can authenticate as this user, while NOPASSWD sudo
# still works. The session is started by systemd-run as root, so it never
# authenticates against the password field.
grep -q '^passwd -l try$' "$TEST_LOG" || fail "locks the try user's password" "$(<"$TEST_LOG")"
! grep -q '^passwd -d' "$TEST_LOG" || fail "does not leave the try user with an empty password"
[[ $(readlink "$sandbox/home/try/.config/systemd/user/omarchy-fcitx5.service") == /dev/null ]] || fail "masks fcitx5"
grep -q 'omarchy-try-install' "$sandbox/home/try/.config/hypr/bindings.lua" || fail "adds the install binding"
grep -q '"finished_at": [1-9]' "$state" || fail "marks the state finished"
grep -q '"total_phases": 3' "$state" || fail "reports 3 phases without nvidia"
pass "omarchy-try-setup runs every step and finishes the progress state"

# NVIDIA opt-in: a fourth phase is written and setup continues even though the
# (real) nvidia helper is absent in the sandbox.
new_sandbox
run nvidia >/dev/null 2>&1 || fail "nvidia path exits zero"
grep -q '"total_phases": 4' "$state" || fail "reports 4 phases with nvidia"
pass "omarchy-try-setup adds an NVIDIA phase when asked"

# An overlay that cannot hold the try set fails before pacman, with numbers.
new_sandbox
! COWSPACE_AVAIL_KIB=2000000 run >/dev/null 2>"$sandbox/err" || fail "too-small overlay exits non-zero"
! grep -q '^pacman -S --needed' "$TEST_LOG" || fail "too-small overlay never reaches the install"
grep -qE '[0-9]+ MiB free; the desktop needs [0-9]+ MiB' "$sandbox/err" || fail "too-small overlay says how much is missing" "$(<"$sandbox/err")"
pass "omarchy-try-setup refuses an overlay too small for the try set"

# A second T in the same boot: the user exists, the dotfiles are already seeded,
# and a Ctrl+C in the first attempt may have left pacman's lock behind.
new_sandbox
mkdir -p "$sandbox/var/lib/pacman"; : >"$sandbox/var/lib/pacman/db.lck"
run >/dev/null 2>&1 || fail "first run exits zero"
[[ ! -e $sandbox/var/lib/pacman/db.lck ]] || fail "clears a stale pacman lock before installing"
# The set now occupies the overlay; free space is below the set's size but
# nothing needs installing, so the capacity check must let this through.
COWSPACE_AVAIL_KIB=1400000 run >/dev/null 2>"$sandbox/err2" || fail "second run exits zero" "$(<"$sandbox/err2")"
(( $(grep -c useradd "$TEST_LOG") == 1 )) || fail "does not recreate the user"
(( $(grep -c omarchy-try-install "$sandbox/home/try/.config/hypr/bindings.lua") == 1 )) || fail "appends the install binding once" "$(<"$sandbox/home/try/.config/hypr/bindings.lua")"
(( $(grep -c omarchy-try-welcome "$sandbox/home/try/.config/hypr/autostart.lua") == 1 )) || fail "appends the welcome autostart once"
pass "omarchy-try-setup is safe to run twice"

# The session needs NetworkManager; a failed start is a failed setup, not "Ready".
new_sandbox
! SYSTEMCTL_FAIL_ON='start NetworkManager.service' run >/dev/null 2>&1 || fail "NetworkManager failure exits non-zero"
! grep -q '"finished_at": [1-9]' "$state" || fail "NetworkManager failure does not mark the state finished"
pass "omarchy-try-setup fails when NetworkManager cannot start"

# No network yet: the timezone step is skipped rather than waited for.
new_sandbox
OFFLINE=1 run >/dev/null 2>&1 || fail "offline path exits zero"
grep -q '^nm-online -q -t 4$' "$TEST_LOG" || fail "asks NetworkManager with a short bound"
! grep -q '^tzupdate' "$TEST_LOG" || fail "does not run tzupdate offline"
pass "omarchy-try-setup skips the timezone lookup without a network"

# Install failure aborts non-zero so the dashboard reports it.
new_sandbox
! PACMAN_FAIL=1 run >/dev/null 2>&1 || fail "install failure exits non-zero"
pass "omarchy-try-setup fails cleanly when the install fails"
