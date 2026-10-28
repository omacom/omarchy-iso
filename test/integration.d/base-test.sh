#!/bin/bash
#
# Shared harness for the integration scenarios in test/integration.d/: QEMU
# lifecycle, QMP screendump + OCR console driving, virtual keystrokes, guest
# SSH, cidata autoinstall, and the reusable base-image contract. Source this
# from a scenario; ./test/integration exports the configuration and ensures
# the base image exists before any scenario runs.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

ISO="$OMARCHY_INTEGRATION_ISO"
SSH_PORT="${OMARCHY_INTEGRATION_SSH_PORT:-2322}"
MEMORY="${OMARCHY_INTEGRATION_MEMORY:-8192}"
INSTALL_TIMEOUT="${OMARCHY_INTEGRATION_INSTALL_TIMEOUT:-2400}"
# cache=none keeps the host page cache out of the guest's disk writes, so
# install times measure the installer rather than the host (CI sets it).
DISK_CACHE="${OMARCHY_INTEGRATION_DISK_CACHE:-}"
NO_PREVIEW="${OMARCHY_INTEGRATION_NO_PREVIEW:-false}"
# true when the ISO is a shipped release rather than a build of this tree:
# what only this tree's installer does is then noted instead of checked.
RELEASE_ISO="${OMARCHY_INTEGRATION_RELEASE_ISO:-false}"
BOOT_TIMEOUT=600

GUEST_USER="omarchy"
GUEST_PASSWORD="omarchy"
GUEST_HOSTNAME="omarchy-test"

SCENARIO="${SCENARIO:-$(basename "${0%-test.sh}")}"

# Firmware the VMs boot: uefi (OVMF, the default) or bios (SeaBIOS, legacy).
# BIOS exercises the Limine MBR boot path that only real hardware covered; set
# it with OMARCHY_INTEGRATION_FIRMWARE=bios or the runner's --bios flag. The
# base image and its caches are kept per-firmware so the two never collide.
FIRMWARE="${OMARCHY_INTEGRATION_FIRMWARE:-uefi}"
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="/usr/share/edk2/x64/OVMF_VARS.4m.fd"

# Variant knobs. One ISO can be installed several different ways, and each
# way is a configuration users actually run; keeping them here means a variant
# costs an install, not a second image. Each variant keeps its own base image
# so the scenarios that boot an overlay stay independent.
VARIANT="${OMARCHY_INTEGRATION_VARIANT:-default}"
DISK_GB="${OMARCHY_INTEGRATION_DISK_GB:-40}"
UKI="${OMARCHY_INTEGRATION_UKI:-false}"
ENCRYPT="${OMARCHY_INTEGRATION_ENCRYPT:-false}"
# The console keymap the autoinstall asks for. With the default, us, a dropped
# layout looks the same as a kept one. keymap-locale-test.sh checks that the
# chosen layout reaches the target and the initramfs the LUKS passphrase
# prompt runs from (upstream omarchy#8196); it needs a non-us value here to
# assert anything.
KB_LAYOUT="${OMARCHY_INTEGRATION_KB_LAYOUT:-us}"

# type_text sends key positions over QMP and the guest reads them through its
# own keymap: KB_LAYOUT at the installed system's console, LUKS prompt and
# desktop, us on the live ISO (an autoinstall skips the configurator, the one
# thing there that loads another). TYPE_LAYOUT is the layout being typed
# into; a caller typing into anything else sets it. type_text knows us and
# uk: of what it sends, kbd's uk map moves only @ (Shift+') and ~ (Shift+#,
# the key beside Enter). Other layouts move what every run types: de swaps y
# and z, so the passphrase "omarchy" arrives as "omarchz" and the unlock and
# the console login fail. Teach type_text a layout's keys before allowing it
# here.
kb_layout_typeable() {
  case "$1" in
    us | uk) ;;
    *)
      echo "OMARCHY_INTEGRATION_KB_LAYOUT=$1: the harness can type only the us and uk layouts" >&2
      return 1
      ;;
  esac
}
kb_layout_typeable "$KB_LAYOUT" || exit 1
TYPE_LAYOUT=$KB_LAYOUT

# Every setting that changes what is installed names the base folder, so
# --reuse-base never boots an install made another way; with the defaults
# it is the plain name, which the nightly and upgrade workflows look for.
# install-test.yml's "Report times" step names it the same way.
BASE_DIR="$ROOT/test-runs/$(basename "$ISO" .iso)-integration"
if [[ $FIRMWARE == bios ]]; then
  BASE_DIR+="-bios"
fi
if [[ $VARIANT != default ]]; then
  BASE_DIR="$BASE_DIR-$VARIANT"
fi
if [[ $KB_LAYOUT != us ]]; then
  BASE_DIR="$BASE_DIR-kb$KB_LAYOUT"
fi
if [[ $ENCRYPT == true ]]; then
  BASE_DIR+="-luks"
fi
if [[ $UKI == true ]]; then
  BASE_DIR+="-uki"
fi
if [[ $DISK_GB != 40 ]]; then
  BASE_DIR+="-${DISK_GB}g"
fi
RUN_DIR="$BASE_DIR/runs/$(date +%Y%m%d-%H%M%S)-$SCENARIO"
BASE_DISK="$BASE_DIR/base.qcow2"
BASE_OVMF="$BASE_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$BASE_OVMF"
SSH_KEY="$BASE_DIR/id_ed25519"
CIDATA_IMG="$BASE_DIR/cidata.img"
HTTP_PORT=$((SSH_PORT + 1))
HTTP_PID=""

# Scenario extensions to the network stack, appended verbatim (leading comma
# included) to the user netdev and the NIC device: the PXE scenario adds the
# built-in TFTP server to the former and a boot order to the latter.
NETDEV_EXTRA=""
NIC_EXTRA=""

mkdir -p "$BASE_DIR" "$RUN_DIR"

QMP_SOCK=$(mktemp -u "${TMPDIR:-/tmp}/omarchy-integration-qmp.XXXXXX.sock")
PIDFILE="$RUN_DIR/qemu.pid"

FAILURES=0
KNOWN_FAILURES=0
source "$ROOT/test/integration.d/known-failures.sh"

log() {
  printf '\033[1;35m==> %s\033[0m\n' "$1"
}

check() {
  local description="$1" until
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$description"
  else
    until=$(known_failure_until "$description")
    if [[ -n $until ]]; then
      printf 'not ok - %s # known failure, allowed until %s\n' "$description" "$until"
      ((KNOWN_FAILURES += 1))
    else
      printf 'not ok - %s\n' "$description"
      ((FAILURES += 1))
    fi
    # What was on the screen when it failed. A screen assertion that fails
    # leaves nothing else to look at: the last capture predates it.
    local slug=${description,,}
    slug=${slug//[^a-z0-9]/-}
    vm_running 2>/dev/null && capture_console "failure-check-${slug:0:60}" || true
  fi
}

finish() {
  if ((FAILURES == 0)); then
    if ((KNOWN_FAILURES > 0)); then
      log "$SCENARIO passed with $KNOWN_FAILURES known failure(s). Artifacts: $RUN_DIR"
    else
      log "$SCENARIO passed. Artifacts: $RUN_DIR"
    fi
    # The disk overlays a passed scenario booted are reproducible from the
    # base image and are the bulk of what a run leaves behind (a hibernate
    # overlay carries the memory image); on a ramdisk run directory they
    # are what fills it. Screenshots and logs stay.
    [[ ${OMARCHY_INTEGRATION_KEEP_DISKS:-0} == 1 ]] || rm -f "$RUN_DIR"/*.qcow2
  else
    log "$SCENARIO FAILED: $FAILURES assertion(s). Artifacts: $RUN_DIR"
    # A failed scenario keeps its disks for a look afterwards. A CI host
    # never takes that look (it uploads logs and screenshots, not disks)
    # and a scenario whose failures are known and allowed, such as
    # factory-reset's shared-ESP ones, would otherwise park a full
    # re-install's overlay on the run directory for every scenario after
    # it: with corrupt-image's ISO copy that fills an 18 GB tmpfs.
    [[ ${OMARCHY_INTEGRATION_DISCARD_DISKS:-0} == 1 ]] && rm -f "$RUN_DIR"/*.qcow2
    exit 1
  fi
}

base_image_ready() {
  [[ -f $BASE_DISK && -f $SSH_KEY ]] || return 1
  # UEFI keeps its NVRAM vars alongside the disk; BIOS has none.
  [[ $FIRMWARE != uefi || -f $BASE_OVMF ]]
}

# ---------------------------------------------------------------- vm control

vm_running() {
  [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

qmp() {
  printf '{"execute":"qmp_capabilities"}\n{"execute":%s}\n' "$1" |
    timeout 5 socat -t 2 - "UNIX-CONNECT:$QMP_SOCK" 2>/dev/null || true
}

screendump() {
  qmp "\"screendump\", \"arguments\": {\"filename\": \"$1\"}" >/dev/null
}

capture_console() {
  local name="$1" shot="$RUN_DIR/.capture.ppm"

  sleep 1
  screendump "$shot"
  [[ -s $shot ]] || return 0
  magick "$shot" "$RUN_DIR/$name.png" 2>/dev/null || true
  rm -f "$shot"
}

# What the vCPUs are doing, for a boot that hangs before the kernel prints:
# the installed system boots quiet, so the serial log of a hang stops at the
# firmware starting Limine whether the loader or the kernel stopped. A RIP
# in the kernel's half of the address space (0xffff...) or below it, and
# whether the CPUs halted, tell the two apart.
capture_vm_state() {
  local name="$1" what
  for what in "info status" "info cpus" "info registers -a"; do
    printf '=== %s\n' "$what"
    qmp "\"human-monitor-command\", \"arguments\": {\"command-line\": \"$what\"}" |
      sed -n 's/.*"return": *"\(.*\)".*/\1/p' | sed 's/\\r//g; s/\\n/\n/g'
  done >"$RUN_DIR/$name-vm-state.txt" 2>&1
}

stop_vm() {
  vm_running || return 0

  if ! ssh_guest "echo $GUEST_PASSWORD | sudo -S systemctl poweroff" >/dev/null 2>&1; then
    qmp '"system_powerdown"' >/dev/null
  fi

  local waited=0
  while vm_running && ((waited < 15)); do
    sleep 1
    ((waited += 1))
  done

  if vm_running; then
    qmp '"quit"' >/dev/null
    sleep 1
  fi

  if vm_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sleep 1
  fi
}

open_screenshots() {
  local entry
  local -a screenshots=()

  while IFS= read -r -d '' entry; do
    screenshots+=("${entry#* }")
  done < <(
    find "$RUN_DIR" -type f \( -name "success-*.png" -o -name "failure-*.png" \) -printf '%T@ %p\0' |
      sort -zn
  )

  (( ${#screenshots[@]} > 0 )) || return 0

  log "Visual review: ${#screenshots[@]} screenshots in $RUN_DIR"
  [[ $NO_PREVIEW == "true" ]] && return 0

  if command -v imv >/dev/null && [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
    setsid -f imv "${screenshots[@]}" >/dev/null 2>&1
  fi
}

cleanup() {
  local status=$?

  [[ -n $HTTP_PID ]] && kill "$HTTP_PID" 2>/dev/null || true
  vm_running && log "Stopping test VM"
  stop_vm
  rm -f "$RUN_DIR/.screen.ppm" "$RUN_DIR/.screen.png"
  open_screenshots
  rmdir "$RUN_DIR" 2>/dev/null || true

  return $status
}
trap cleanup EXIT

start_vm() {
  local disk="$1" serial="$2"
  shift 2

  # UEFI needs the OVMF firmware pair; BIOS boots QEMU's built-in SeaBIOS with
  # no pflash at all.
  local firmware_args=()
  if [[ $FIRMWARE == uefi ]]; then
    firmware_args=(
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
      -drive if=pflash,format=raw,file="$ACTIVE_OVMF"
    )
  fi

  qemu-system-x86_64 \
    -cpu host -enable-kvm -machine q35,accel=kvm \
    -smp "$(nproc)" \
    -m "$MEMORY" \
    "${firmware_args[@]}" \
    -drive "file=$disk,format=qcow2,if=none,id=drive0${DISK_CACHE:+,cache=$DISK_CACHE}${OMARCHY_DISK_DRIVE_OPTS:+,$OMARCHY_DISK_DRIVE_OPTS}" \
    -device virtio-blk-pci,drive=drive0,bootindex=1 \
    -device virtio-vga \
    -display none \
    -usb -device usb-tablet \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22$NETDEV_EXTRA" \
    -device "virtio-net-pci,netdev=net0$NIC_EXTRA" \
    -qmp "unix:$QMP_SOCK,server,nowait" \
    -serial "file:$serial" \
    -pidfile "$PIDFILE" \
    -daemonize \
    "$@"
}

# Boot a throwaway overlay of the installed base. The disk gets a per-run
# overlay; the firmware vars need the same isolation or NVRAM state would
# leak between runs.
start_vm_from_base() {
  qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
  if [[ $FIRMWARE == uefi ]]; then
    cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
    ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
  fi
  start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log"
}

# ------------------------------------------------------------ console driver

# Read the guest's screen. A blank read is retried once after waking the
# console: the kernel blanks a VT after ten idle minutes, and a scenario that
# waits that long (corrupt-image and slow-medium wait for an installer to
# stop, which on a busy CI runner takes minutes) then screendumps black and
# every assertion that greps the dashboard fails although the text is there.
# Shift is the wake-up: it unblanks the VT and no dashboard reads it.
ocr_screen() {
  local text
  text=$(ocr_screen_once)
  if [[ -z ${text//[[:space:]]/} ]]; then
    press shift
    sleep 1
    text=$(ocr_screen_once)
  fi
  printf '%s' "$text"
}

ocr_screen_once() {
  local shot="$RUN_DIR/.screen.ppm" prepped="$RUN_DIR/.screen.png"

  screendump "$shot"
  [[ -s $shot ]] || return 0
  # Black on white: the negated grays alone read the focused button on the
  # finished install, dark text on a light bar, as "Reboot Nou".
  magick "$shot" -colorspace gray -negate -resize 150% -threshold 50% "$prepped" 2>/dev/null || return 0
  tesseract "$prepped" - --psm 6 2>/dev/null || true
}

wait_for_screen() {
  local text="$1" timeout="$2" waited=0 slug

  until ocr_screen | grep -qi "$text"; do
    if ! vm_running; then
      echo "VM exited while waiting for screen: $text" >&2
      return 1
    fi

    if ((waited >= timeout)); then
      slug=${text,,}
      slug=${slug// /-}
      slug=${slug//[^a-z0-9-]/}
      capture_console "failure-waiting-for-$slug"
      echo "Timed out after ${timeout}s waiting for screen: $text" >&2
      return 1
    fi

    sleep 3
    ((waited += 3))
  done

  sleep 1
}

press() {
  local part json=""
  local -a parts

  IFS='-' read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    json+="{\"type\":\"qcode\",\"data\":\"$part\"},"
  done

  qmp "\"send-key\", \"arguments\": {\"keys\": [${json%,}]}" >/dev/null
}

type_text() {
  local text="$1" ch i

  for ((i = 0; i < ${#text}; i++)); do
    ch=${text:i:1}
    case "$ch" in
      [a-z0-9]) press "$ch" ;;
      [A-Z]) press "shift-${ch,,}" ;;
      " ") press spc ;;
      .) press dot ;;
      ,) press comma ;;
      -) press minus ;;
      _) press shift-minus ;;
      /) press slash ;;
      :) press shift-semicolon ;;
      "&") press shift-7 ;;
      "=") press equal ;;
      "?") press shift-slash ;;
      "!") press shift-1 ;;
      "~") if [[ $TYPE_LAYOUT == uk ]]; then press shift-backslash; else press shift-grave_accent; fi ;;
      @) if [[ $TYPE_LAYOUT == uk ]]; then press shift-apostrophe; else press shift-2; fi ;;
      *) echo "type_text: unsupported character: $ch" >&2; return 1 ;;
    esac
    sleep 0.05
  done
}

# --------------------------------------------------------------------- guest

ssh_guest() {
  ssh -i "$SSH_KEY" -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    "$GUEST_USER@127.0.0.1" "$@"
}

ssh_sudo() {
  ssh_guest "echo $GUEST_PASSWORD | sudo -S -p '' bash -c $(printf %q "$1")"
}

# Answer an encrypted boot's LUKS prompt, given what OCR read off the screen.
# The busybox encrypt hook asks "A password is required to access the root
# volume"; systemd-cryptsetup (the pre-built UKI's initramfs) asks "Please
# enter passphrase for disk root". An initramfs mkinitcpio builds on the
# machine (on BIOS, or for a layout the pre-built UKI lacks) asks with
# Plymouth's lock field under the logo: OCR reads the logo ("OMARCHY",
# "OMARCHS" at this size, "0MMARCHY" with tesseract 5.5) and nothing else:
# one short word around "arch". Once an encrypted run has
# shown nothing but the logo for two samples in a row, nothing but that
# prompt is listening to the keyboard, so type the passphrase blind. The
# installer's dashboard always carries more text ("Installing Omarchy",
# the tip line), and so does a booted system; the splash between the reboot
# and the prompt discards keystrokes. Takes the screen's text, the name of
# the caller's count of logo-only samples and a name for the screenshot,
# and succeeds when it typed the passphrase.
answer_luks_prompt() {
  local text="$1" shot="$3" screen_words=${1//[^[:alpha:]]/}
  local -n logo_samples="$2"

  if grep -qiE "password is required|enter passphrase|unlocking" <<<"$text"; then
    capture_console "success-$shot"
  elif [[ ${screen_words,,} =~ ^([a-z]{0,3}arch[a-z]{0,3})?$ ]]; then
    ((++logo_samples >= 2)) || return 1
    capture_console "success-$shot-blind"
    logo_samples=0
  else
    logo_samples=0
    return 1
  fi
  type_text "$GUEST_PASSWORD"
  press ret
}

# The deadline is wall-clock: under QEMU user networking every attempt can
# spend its whole ConnectTimeout waiting for a banner, so counting only the
# sleeps let a "300 s" wait run for ten minutes or more, silently.
wait_for_ssh() {
  local timeout="$1" failure_name="${2:-failure-ssh-timeout}"
  # shellcheck disable=SC2034 # answer_luks_prompt counts in logo_screens
  local started=$SECONDS next_note=30 next_unlock=0 logo_screens=0 progress_name

  while ! ssh_guest true 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited while waiting for SSH" >&2
      return 1
    fi

    # Every boot of an encrypted install stops in the initramfs asking for the
    # passphrase, scenario overlays included.
    if [[ ${ENCRYPT:-false} == true ]] && ((SECONDS - started >= next_unlock)); then
      ((next_unlock += 15))
      answer_luks_prompt "$(ocr_screen)" logo_screens boot-luks-prompt || true
    fi

    if ((SECONDS - started >= timeout)); then
      capture_console "$failure_name"
      capture_vm_state "$failure_name"
      echo "Timed out after ${timeout}s waiting for SSH" >&2
      return 1
    fi

    if ((SECONDS - started >= next_note)); then
      printf -v progress_name 'waiting-ssh-%04ds' "$((SECONDS - started))"
      capture_console "$progress_name"
      echo "    ... waiting for SSH ($((SECONDS - started))s)"
      ((next_note += 30))
    fi

    sleep 2
  done
}

# Authorize SSH the way a person would when the guest has no key yet (or a
# reset just scrubbed it): console login on a spare TTY, then a bootstrap
# script fetched from a throwaway host HTTP server.
bootstrap_ssh() {
  log "Authorizing SSH access via console login"

  mkdir -p "$BASE_DIR/www"
  cat >"$BASE_DIR/www/bootstrap" <<EOF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "$(cat "$SSH_KEY.pub")" >>~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "$GUEST_PASSWORD" | sudo -S ufw allow from 10.0.2.2 to any port 22 proto tcp
echo "$GUEST_PASSWORD" | sudo -S systemctl enable --now sshd.service
EOF

  (cd "$BASE_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  HTTP_PID=$!

  # The typing below races whatever else owns the console: on a factory
  # first boot, provisioning finishing mid-command starts the graphical
  # session and switches the VT, and the rest of the line lands in Hyprland,
  # so the bootstrap never runs. Each attempt uses a fresh getty (tty3, tty4,
  # tty5) so a half-typed session on the previous one cannot get in the way.
  local attempt waited
  for attempt in 1 2 3; do
    waited=0
    while true; do
      press "ctrl-alt-f$((attempt + 2))"
      sleep 4
      ocr_screen | grep -qi "login:" && break
      ((waited += 8))

      if ((waited >= 300)); then
        capture_console "failure-console-timeout"
        echo "Timed out waiting for a console login prompt" >&2
        return 1
      fi
      sleep 4
    done

    type_text "$GUEST_USER"
    press ret
    # The VT can switch away before the prompt shows; that loses this
    # attempt, not the scenario.
    if ! wait_for_screen "Password" 60; then
      log "No password prompt after the username (attempt $attempt); retrying on the next VT"
      continue
    fi
    type_text "$GUEST_PASSWORD"
    press ret
    sleep 3

    type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/bootstrap -o /tmp/bs && bash /tmp/bs"
    press ret

    if wait_for_ssh 120 "failure-bootstrap-ssh-timeout-$attempt"; then
      capture_console "success-bootstrap-ssh"
      kill "$HTTP_PID" 2>/dev/null || true
      HTTP_PID=""
      press ctrl-alt-f1
      return 0
    fi
    log "SSH did not come up after the console login (attempt $attempt); retrying on the next VT"
  done

  echo "SSH bootstrap failed after 3 console logins" >&2
  return 1
}

# Root SSH into the live ISO itself (not the installed system). The live root
# runs sshd and autologs in on tty1 with an empty password, but sshd refuses
# empty passwords, so authorize our key the same console-login way as above,
# on tty3 and up (tty1 is the installer's).
ssh_live_root() {
  ssh -i "$SSH_KEY" -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    "root@127.0.0.1" "$@"
}

# Root SSH on a live ISO booted with the cidata drive, whose user-data
# authorizes the key (build_cidata). The VM also needs LIVE_CIDATA_SMBIOS:
# cloud-init's generator runs ds-identify before a USB drive has appeared,
# finds no datasource and leaves cloud-init off for the boot; the DMI serial
# ds=nocloud tells it NoCloud is there, and NoCloud then finds the drive.
# Nothing in the ISO or the install reads the serial.
LIVE_CIDATA_SMBIOS=(-smbios "type=1,serial=ds=nocloud")
wait_for_live_root_ssh() {
  local timeout="$1" started=$SECONDS
  # By the clock: a refused attempt can itself take ConnectTimeout.
  until ssh_live_root true 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited while waiting for live root SSH" >&2
      return 1
    fi
    if ((SECONDS - started >= timeout)); then
      capture_console "failure-live-ssh-timeout"
      echo "Timed out after ${timeout}s waiting for root SSH on the live ISO" >&2
      return 1
    fi
    sleep 1
  done
  capture_console "success-live-root-ssh"
}

bootstrap_live_root_ssh() {
  # The live ISO's console is us, whatever layout the install was given.
  local TYPE_LAYOUT=us

  log "Authorizing root SSH on the live ISO via console login"

  mkdir -p "$BASE_DIR/www"
  cat >"$BASE_DIR/www/bootstrap-live" <<EOF
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$(cat "$SSH_KEY.pub")" >>/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
EOF

  (cd "$BASE_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  HTTP_PID=$!

  if [[ $FIRMWARE == bios ]]; then
    # ISOLINUX cancels its auto-boot countdown on any keystroke, so the
    # ctrl-alt-f3 below would strand the VM at the boot menu. Commit the
    # highlighted default (the install medium) with Enter first; a few presses
    # catch the menu whenever it renders, and once booted they are harmless
    # newlines (still well before the installer dashboard comes up).
    local i
    for i in 1 2 3; do press ret; sleep 2; done
  fi

  # The live boot can switch the VT back to tty1 after the login prompt has
  # shown on the spare one: on a run of used-disk, "root", Return and this
  # curl line all went into the installer's wizard on tty1, and the scenario
  # timed out waiting for a command that never ran. So a root prompt must be
  # on screen before the command is typed, the VT is selected again right
  # before each line, and an attempt that still loses its console moves to a
  # fresh getty (tty3, tty4, tty5), as bootstrap_ssh does.
  local attempt vt waited deadline up=false
  for attempt in 1 2 3; do
    vt=$((attempt + 2))
    waited=0
    while true; do
      press "ctrl-alt-f$vt"
      sleep 4
      ocr_screen | grep -qi "login:" && break
      ((waited += 8))

      if ((waited >= 300)); then
        capture_console "failure-live-console-timeout"
        echo "Timed out waiting for a live console login prompt" >&2
        return 1
      fi
      sleep 4
    done

    press "ctrl-alt-f$vt"
    type_text root
    press ret
    sleep 2
    # The password is empty; login may still prompt for it.
    ocr_screen | grep -qi "password" && { press ret; sleep 2; }
    # The shell prompt, root@archiso ~ #. OCR reads its red "root@" as
    # noise, so match the rest: the login banner, "archiso login:", has no #.
    if ! wait_for_screen "archiso [^l]*#" 30; then
      log "No root prompt on tty$vt (attempt $attempt); retrying on the next VT"
      continue
    fi

    press "ctrl-alt-f$vt"
    type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/bootstrap-live -o /tmp/bs && bash /tmp/bs"
    press ret

    # By the clock: a refused attempt can itself take ConnectTimeout.
    deadline=$((SECONDS + 60))
    until ssh_live_root true 2>/dev/null && up=true; do
      if ! vm_running; then
        echo "VM exited while waiting for live root SSH" >&2
        return 1
      fi
      ((SECONDS >= deadline)) && break
      sleep 2
    done
    [[ $up == true ]] && break
    capture_console "failure-live-ssh-timeout-$attempt"
    log "Root SSH did not come up after the console login on tty$vt (attempt $attempt); retrying on the next VT"
  done
  if [[ $up != true ]]; then
    echo "Live root SSH bootstrap failed after 3 console logins" >&2
    return 1
  fi
  capture_console "success-live-root-ssh"

  kill "$HTTP_PID" 2>/dev/null || true
  HTTP_PID=""
  press ctrl-alt-f1
}

# ---------------------------------------------------------- cidata autoinstall

# The configurator's own output files, synthesized for the 40G virtio disk the
# VM boots from. Sizing mirrors the configurator: 1MiB gap, 2GiB ESP, the rest
# btrfs minus the GPT backup reserve.
# The live ISO's cloud-init reads a CIDATA volume as NoCloud: this
# user-data gives the live system's root the harness key at boot, so a
# scenario with the drive reaches it over SSH without typing on a console the
# installer can take back, and before an unattended install that is over in
# seconds has rebooted it away. The image's cloud.cfg has disable_root: true,
# which wraps root's key in a "log in as the default user" command, and
# creates a default user; neither is wanted here. The installer copies only
# its own files off the drive, and the installed system has no cloud-init, so
# none of this reaches it.
cidata_cloud_init() {
  local dir="$1"
  printf 'instance-id: omarchy-integration\n' >"$dir/meta-data"
  printf '#cloud-config\nusers: []\ndisable_root: false\nssh_authorized_keys:\n  - %s\n' \
    "$(cat "$SSH_KEY.pub")" >"$dir/user-data"
}

build_cidata() {
  local dir="$BASE_DIR/cidata" hash encryption_config="" credentials_encryption=""
  local disk_bytes=$((DISK_GB * 1024 * 1024 * 1024))
  local mib=$((1024 * 1024)) gib=$((1024 * 1024 * 1024))
  local boot_start=$mib boot_size=$((2 * gib))
  local main_start=$((boot_size + boot_start))
  local main_size=$((disk_bytes - main_start - mib))

  rm -rf "$dir"
  mkdir -p "$dir"

  hash=$(openssl passwd -6 "$GUEST_PASSWORD")

  # The obj_id is the main partition's, as written below: archinstall encrypts
  # partitions by identity, not by path. The passphrase also has to be in the
  # credentials, exactly where the configurator puts it: archinstall reads the
  # encryption password from there, and a disk_encryption block without one
  # installs unencrypted while the orchestrator still believes it is encrypted.
  if [[ $ENCRYPT == true ]]; then
    credentials_encryption="    \"encryption_password\": $(jq -Rn --arg v "$GUEST_PASSWORD" '$v'),"
    encryption_config=$(
      cat <<EOF
,
        "disk_encryption": {
            "encryption_type": "luks",
            "lvm_volumes": [],
            "iter_time": 2000,
            "partitions": [ "8c2c2b92-1070-455d-b76a-56263bab24aa" ],
            "encryption_password": $(jq -Rn --arg v "$GUEST_PASSWORD" '$v')
        }
EOF
    )
  fi

  cat >"$dir/user_credentials.json" <<EOF
{
$credentials_encryption
    "root_enc_password": $(jq -Rn --arg v "$hash" '$v'),
    "users": [
        {
            "enc_password": $(jq -Rn --arg v "$hash" '$v'),
            "groups": [],
            "sudo": true,
            "username": "$GUEST_USER"
        }
    ]
}
EOF

  cat >"$dir/user_configuration.json" <<EOF
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": { "audio": "pipewire" },
    "bootloader_config": { "bootloader": "Limine", "uki": $UKI, "removable": false },
    "custom_commands": [],
    "omarchy_install": {
        "mode": "full_disk",
        "defer_provisioning": false,
        "target_mount": "/mnt",
        "boot": {
            "esp_mount": "/boot",
            "esp_path": "/EFI/limine",
            "efi_binary": "limine_x64.efi",
            "enable_fallback": true
        },
        "storage": { "kernel": "linux-omarchy" }
    },
    "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "/dev/vda",
                "partitions": [
                    {
                        "btrfs": [],
                        "dev_path": null,
                        "flags": [ "boot", "esp" ],
                        "fs_type": "fat32",
                        "mount_options": [],
                        "mountpoint": "/boot",
                        "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_start },
                        "status": "create",
                        "type": "primary"
                    },
                    {
                        "btrfs": [
                            { "mountpoint": "/", "name": "@" },
                            { "mountpoint": "/home", "name": "@home" },
                            { "mountpoint": "/var/log", "name": "@log" },
                            { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
                        ],
                        "dev_path": null,
                        "flags": [],
                        "fs_type": "btrfs",
                        "mount_options": [ "compress=zstd" ],
                        "mountpoint": null,
                        "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_start },
                        "status": "create",
                        "type": "primary"
                    }
                ],
                "wipe": true
            }
        ]$encryption_config
    },
    "hostname": "$GUEST_HOSTNAME",
    "kernels": [ "linux-omarchy" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "UTC",
    "locale_config": { "kb_layout": "$KB_LAYOUT", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [
            {"url": "https://mirror.omarchy.org/\$repo/os/\$arch"},
            {"url": "https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"},
            {"url": "https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"}
        ],
        "mirror_regions": {},
        "optional_repositories": []
    },
    "packages": [
        "base-devel",
        "git",
        "omarchy-keyring",
        "$SETTINGS_PACKAGE",
        "$RUNTIME_PACKAGE"
    ],
    "profile_config": { "gfx_driver": null, "greeter": null, "profile": {} },
    "version": "3.0.9"
}
EOF

  echo "$ENCRYPT" >"$dir/user_encrypt_installation.txt"
  cp "$SSH_KEY.pub" "$dir/authorized_keys"

  cidata_cloud_init "$dir"

  rm -f "$CIDATA_IMG"
  truncate -s 4M "$CIDATA_IMG"
  mkfs.vfat -n CIDATA "$CIDATA_IMG" >/dev/null
  mcopy -i "$CIDATA_IMG" "$dir"/* ::/
}

# The edge/dev/local ISO installs the -dev packages, as builder/build-iso.sh
# picks them; a stable ISO the plain ones. An aarch64 image with the N1x debug
# key says -devssh in its name, which is no channel.
detect_packages() {
  local name
  name=$(basename "$ISO")
  name=${name/-devssh/}
  RUNTIME_PACKAGE=omarchy-dev
  SETTINGS_PACKAGE=omarchy-settings-dev
  if [[ $name != *edge* && $name != *dev* && $name != *local* && $name != *pr* ]]; then
    RUNTIME_PACKAGE=omarchy
    SETTINGS_PACKAGE=omarchy-settings
  fi
}

# The firmware names what it starts on the serial port: the ISO's medium while
# the installer runs, the installed disk's Limine once the install is over.
installed_system_started() {
  grep -aq 'starting Boot.*"Limine"' "$1" 2>/dev/null
}

# Wait out an unattended cidata install to its reboot into the installed
# system: SSH answering as the guest user is the success signal (cidata's
# authorized_keys enables sshd there, and the live environment has no such
# user, so there is no false positive from the installer phase). Presses the
# Reboot Now prompt if one appears. Screenshot names take the given prefix so
# each caller's artifacts stay apart; on a stopped install the live system's
# log and state are saved best-effort (root SSH may not be authorized yet).
# Given the VM's serial log, it also says when the install is over and the
# first boot is what is being waited for.
wait_for_unattended_install() {
  local prefix="$1" serial_log="${2:-}"
  # shellcheck disable=SC2034 # answer_luks_prompt counts in blank_screens
  local waited=0 text progress_name blank_screens=0 first_boot_at=""

  log "Waiting for the unattended install to finish (timeout ${INSTALL_TIMEOUT}s)"
  while true; do
    if ssh_guest true 2>/dev/null; then
      log "Install finished and rebooted into the installed system."
      capture_console "success-$prefix-first-boot"
      return 0
    fi

    # Checked first, so every branch below that types and waits (the
    # passphrase prompts) counts against the budget too.
    if ((waited >= INSTALL_TIMEOUT)); then
      capture_console "failure-$prefix-timeout"
      echo "Timed out after ${INSTALL_TIMEOUT}s waiting for install" >&2
      return 1
    fi

    text=$(ocr_screen)

    # An encrypted install reboots into a passphrase prompt, which nothing
    # else in an unattended run is there to answer.
    if [[ $ENCRYPT == true ]] && answer_luks_prompt "$text" blank_screens install-luks-prompt; then
      sleep 10
      ((waited += 10))
      continue
    fi

    if grep -qi "Reboot Now" <<<"$text"; then
      log "Install finished. Confirming the reboot prompt."
      capture_console "success-$prefix-reboot"
      press ret
    fi

    if grep -qi "installation stopped" <<<"$text"; then
      capture_console "failure-$prefix-stopped"
      # The unattended path does not authorize root SSH on the live ISO, so
      # without this the log copies below come back empty. The installer has
      # exited to a shell on tty1; tty3 is free for the console login.
      ssh_live_root true 2>/dev/null || bootstrap_live_root_ssh 2>/dev/null || true
      ssh_live_root "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
      ssh_live_root "cat /run/omarchy-install/state.json" >"$RUN_DIR/state.json" 2>/dev/null || true
      # What the kernel saw: an I/O error in the installer is only explainable
      # with the block and filesystem messages behind it.
      ssh_live_root "dmesg" >"$RUN_DIR/dmesg.txt" 2>/dev/null || true
      ssh_live_root "journalctl -b --no-pager -o short-precise | tail -n 400" >"$RUN_DIR/journal-tail.txt" 2>/dev/null || true
      ssh_live_root "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS; df -h /mnt /mnt/boot 2>/dev/null; btrfs device stats /mnt 2>/dev/null" >"$RUN_DIR/target-state.txt" 2>/dev/null || true
      echo "Install failed — artifacts saved to $RUN_DIR" >&2
      return 1
    fi

    if ! vm_running; then
      echo "VM exited during install" >&2
      return 1
    fi

    # A line every 30 s so a slow runner never looks hung; a screenshot of
    # the installer's dashboard every 2 min, which is enough to see progress.
    if ((waited % 120 == 0)); then
      printf -v progress_name 'success-%s-progress-%04ds' "$prefix" "$waited"
      capture_console "$progress_name"
    fi
    # Once the installed system has started, the install is over and what is
    # being waited for is the first boot: say so, or a hung first boot reads
    # as a slow install.
    if [[ -n $serial_log && -z $first_boot_at ]] && installed_system_started "$serial_log"; then
      first_boot_at=$waited
      log "Install finished after about ${waited}s. Waiting for the installed system's first boot."
    fi
    if ((waited % 30 == 0)); then
      if [[ -n $first_boot_at ]]; then
        echo "    ... first boot ($((waited - first_boot_at))s, install took about ${first_boot_at}s)"
      else
        echo "    ... installing (${waited}s)"
      fi
    fi

    sleep 10
    ((waited += 10))
  done
}

# Boot the ISO with the cidata drive onto <disk> and wait until the installed
# system answers SSH, as install_phase does for the base image. Returns
# non-zero when the installer stops or times out (used-disk).
install_unattended() {
  local disk="$1" serial="$2"

  start_vm "$disk" "$serial" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  wait_for_unattended_install install "$serial"
}

# The installer marks updates as applied after its last pacman transaction,
# so the first boot must skip every ConditionNeedsUpdate= unit; a "yes" is
# 1-2 s of repeated work on every fresh install. A released ISO from before
# that change runs them and can no longer be changed: installed only to
# start an upgrade from, its first boot is noted, not failed.
check_first_boot_update_units() {
  local units="$1"

  grep -q '^ConditionResult=yes' "$units" 2>/dev/null || return 0
  echo "First boot ran the ConditionNeedsUpdate= units (see $units)" >&2
  [[ $RELEASE_ISO == true ]]
}

install_phase() {
  log "Installing $(basename "$ISO") unattended via cidata (headless)"

  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
  detect_packages
  build_cidata

  # Build under a staging name: the finished base is promoted only after a
  # clean shutdown, so a failed install can never pass for a reusable base.
  rm -f "$BASE_DISK" "$BASE_DISK.building"
  qemu-img create -f qcow2 "$BASE_DISK.building" "${DISK_GB}G" >/dev/null
  if [[ $FIRMWARE == uefi ]]; then
    cp "$OVMF_VARS_TEMPLATE" "$BASE_OVMF"
    ACTIVE_OVMF="$BASE_OVMF"
  fi

  # Boot the ISO from an optical drive under both firmwares: OVMF and SeaBIOS
  # both boot an ide-cd reliably, and the boot-medium type has no bearing on
  # what the BIOS run exercises (Limine's MBR install and boot). SeaBIOS will
  # not boot the isohybrid image off a fallback USB device here, so USB is not
  # worth the flakiness. The copytoram-off / USB path is covered by unit tests.
  start_vm "$BASE_DISK.building" "$RUN_DIR/install-serial.log" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0${OMARCHY_ISO_THROTTLE_BPS:+,throttling.bps-read=$OMARCHY_ISO_THROTTLE_BPS}" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  wait_for_unattended_install install "$RUN_DIR/install-serial.log" || return 1

  # Keep the installer's own clock, its log and the first boot's numbers next
  # to the base image while the system is reachable, so CI can report them
  # without attaching the disk (no nbd or loop device on a container runner).
  ssh_sudo "cat /var/log/omarchy-install-timing.json" >"$BASE_DIR/omarchy-install-timing.json" 2>/dev/null || true
  ssh_sudo "cat /var/log/omarchy-install.log" >"$BASE_DIR/omarchy-install.log" 2>/dev/null || true
  ssh_sudo "cat /etc/kernel/cmdline" >"$BASE_DIR/installed-cmdline.txt" 2>/dev/null || true
  # SSH can answer before startup finishes, and systemd-analyze refuses until
  # it has; wait (bounded) so the first-boot numbers are final.
  ssh_guest "timeout 120 systemctl is-system-running --wait >/dev/null; systemd-analyze" \
    >"$BASE_DIR/first-boot-systemd-analyze.txt" 2>/dev/null || true

  # This is the only first boot the harness ever sees, so it is where the
  # first-boot cost gets recorded: systemd's own timing, and whether the
  # ConditionNeedsUpdate= units ran.
  ssh_sudo "systemd-analyze; systemd-analyze blame | head -n 15" >"$BASE_DIR/first-boot-analyze.txt" 2>/dev/null || true
  ssh_sudo "systemctl show ldconfig.service systemd-hwdb-update.service systemd-journal-catalog-update.service systemd-sysusers.service -p Id -p ConditionResult" \
    >"$BASE_DIR/first-boot-update-units.txt" 2>/dev/null || true
  check_first_boot_update_units "$BASE_DIR/first-boot-update-units.txt" || return 1

  # Everything the boot and the install read off the install medium, as QEMU
  # counted it at the ISO drive: the number a slow USB stick turns into time.
  # Read before the VM stops; nothing reads the ISO after the reboot.
  local medium_bytes
  medium_bytes=$(qmp '"query-blockstats"' |
    jq -rs '[.[] | .return? // empty | .[] | select(.device == "cdrom0" or .qdev == "cdrom0")
             | .stats.rd_bytes] | first // empty' 2>/dev/null)
  if [[ $medium_bytes =~ ^[0-9]+$ ]]; then
    echo "$medium_bytes" >"$BASE_DIR/medium-read-bytes.txt"
    log "Read $((medium_bytes >> 20)) MiB off the install medium during boot and install"
  fi

  log "Installed system is up. Saving base image."
  stop_vm
  mv "$BASE_DISK.building" "$BASE_DISK"
}
