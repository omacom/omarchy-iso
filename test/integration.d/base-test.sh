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
NO_PREVIEW="${OMARCHY_INTEGRATION_NO_PREVIEW:-false}"
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

BASE_DIR="$ROOT/test-runs/$(basename "$ISO" .iso)-integration"
if [[ $FIRMWARE == bios ]]; then
  BASE_DIR+="-bios"
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

log() {
  printf '\033[1;35m==> %s\033[0m\n' "$1"
}

check() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description"
    ((FAILURES += 1))
  fi
}

finish() {
  if ((FAILURES == 0)); then
    log "$SCENARIO passed. Artifacts: $RUN_DIR"
  else
    log "$SCENARIO FAILED: $FAILURES assertion(s). Artifacts: $RUN_DIR"
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
    -drive file="$disk",format=qcow2,if=none,id=drive0 \
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

ocr_screen() {
  local shot="$RUN_DIR/.screen.ppm" prepped="$RUN_DIR/.screen.png"

  screendump "$shot"
  [[ -s $shot ]] || return 0
  magick "$shot" -colorspace gray -negate -resize 150% "$prepped" 2>/dev/null || return 0
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
      "~") press shift-grave_accent ;;
      @) press shift-2 ;;
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

wait_for_ssh() {
  local timeout="$1" failure_name="${2:-failure-ssh-timeout}" waited=0

  while ! ssh_guest true 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited while waiting for SSH" >&2
      return 1
    fi

    if ((waited >= timeout)); then
      capture_console "$failure_name"
      echo "Timed out after ${timeout}s waiting for SSH" >&2
      return 1
    fi

    sleep 5
    ((waited += 5))
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

  local waited=0
  while true; do
    press ctrl-alt-f3
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
  wait_for_screen "Password" 60
  type_text "$GUEST_PASSWORD"
  press ret
  sleep 3

  type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/bootstrap -o /tmp/bs && bash /tmp/bs"
  press ret

  wait_for_ssh 360 "failure-bootstrap-ssh-timeout"
  capture_console "success-bootstrap-ssh"

  kill "$HTTP_PID" 2>/dev/null || true
  HTTP_PID=""
  press ctrl-alt-f1
}

# Root SSH into the live ISO itself (not the installed system). The live root
# runs sshd and autologs in on tty1 with an empty password, but sshd refuses
# empty passwords, so authorize our key the same console-login way as above,
# on tty3 (tty1 is the installer's).
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

bootstrap_live_root_ssh() {
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

  local waited=0
  while true; do
    press ctrl-alt-f3
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

  type_text root
  press ret
  sleep 2
  # The password is empty; login still prompts for it.
  ocr_screen | grep -qi "password" && { press ret; sleep 2; }

  type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/bootstrap-live -o /tmp/bs && bash /tmp/bs"
  press ret

  waited=0
  until ssh_live_root true 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited while waiting for live root SSH" >&2
      return 1
    fi
    if ((waited >= 180)); then
      capture_console "failure-live-ssh-timeout"
      echo "Timed out waiting for root SSH on the live ISO" >&2
      return 1
    fi
    sleep 2
    ((waited += 2))
  done
  capture_console "success-live-root-ssh"

  kill "$HTTP_PID" 2>/dev/null || true
  HTTP_PID=""
  press ctrl-alt-f1
}

# ---------------------------------------------------------- cidata autoinstall

# The configurator's own output files, synthesized for the 40G virtio disk the
# VM boots from. Sizing mirrors the configurator: 1MiB gap, 2GiB ESP, the rest
# btrfs minus the GPT backup reserve.
build_cidata() {
  local dir="$BASE_DIR/cidata" hash
  local disk_bytes=$((40 * 1024 * 1024 * 1024))
  local mib=$((1024 * 1024)) gib=$((1024 * 1024 * 1024))
  local boot_start=$mib boot_size=$((2 * gib))
  local main_start=$((boot_size + boot_start))
  local main_size=$((disk_bytes - main_start - mib))

  rm -rf "$dir"
  mkdir -p "$dir"

  hash=$(openssl passwd -6 "$GUEST_PASSWORD")

  cat >"$dir/user_credentials.json" <<EOF
{
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
    "auth_config": {},
    "audio_config": { "audio": "pipewire" },
    "bootloader_config": { "bootloader": "Limine", "uki": false, "removable": false },
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
        "storage": { "kernel": "linux" }
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
        ]
    },
    "hostname": "$GUEST_HOSTNAME",
    "kernels": [ "linux" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "UTC",
    "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
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

  echo "Omarchy Test" >"$dir/user_full_name.txt"
  echo "test@omarchy.org" >"$dir/user_email_address.txt"
  echo "false" >"$dir/user_encrypt_installation.txt"
  cp "$SSH_KEY.pub" "$dir/authorized_keys"

  rm -f "$CIDATA_IMG"
  truncate -s 4M "$CIDATA_IMG"
  mkfs.vfat -n CIDATA "$CIDATA_IMG" >/dev/null
  mcopy -i "$CIDATA_IMG" "$dir"/* ::/
}

# The dev/local ISO installs the -dev packages; a stable ISO the plain ones.
detect_packages() {
  RUNTIME_PACKAGE=omarchy-dev
  SETTINGS_PACKAGE=omarchy-settings-dev
  if [[ $(basename "$ISO") != *dev* && $(basename "$ISO") != *local* && $(basename "$ISO") != *pr* ]]; then
    RUNTIME_PACKAGE=omarchy
    SETTINGS_PACKAGE=omarchy-settings
  fi
}

# Wait out an unattended cidata install to its reboot into the installed
# system: SSH answering as the guest user is the success signal (cidata's
# authorized_keys enables sshd there, and the live environment has no such
# user, so there is no false positive from the installer phase). Presses the
# Reboot Now prompt if one appears. Screenshot names take the given prefix so
# each caller's artifacts stay apart; on a stopped install the live system's
# log and state are saved best-effort (root SSH may not be authorized yet).
wait_for_unattended_install() {
  local prefix="$1"
  local waited=0 text progress_name

  log "Waiting for the unattended install to finish (timeout ${INSTALL_TIMEOUT}s)"
  while true; do
    if ssh_guest true 2>/dev/null; then
      log "Install finished and rebooted into the installed system."
      capture_console "success-$prefix-first-boot"
      return 0
    fi

    text=$(ocr_screen)

    if grep -qi "Reboot Now" <<<"$text"; then
      log "Install finished. Confirming the reboot prompt."
      capture_console "success-$prefix-reboot"
      press ret
    fi

    if grep -qi "installation stopped" <<<"$text"; then
      capture_console "failure-$prefix-stopped"
      ssh_live_root "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
      ssh_live_root "systemctl list-units --all --no-legend 'omarchy-install-*'; echo; journalctl -b -t omarchy-phase-error -o cat --no-pager 2>/dev/null" >"$RUN_DIR/phase-state" 2>/dev/null || true
      echo "Install failed — artifacts saved to $RUN_DIR" >&2
      return 1
    fi

    if ! vm_running; then
      echo "VM exited during install" >&2
      return 1
    fi

    if ((waited >= INSTALL_TIMEOUT)); then
      capture_console "failure-$prefix-timeout"
      echo "Timed out after ${INSTALL_TIMEOUT}s waiting for install" >&2
      return 1
    fi

    if ((waited % 120 == 0)); then
      printf -v progress_name 'success-%s-progress-%04ds' "$prefix" "$waited"
      capture_console "$progress_name"
      echo "    ... installing (${waited}s)"
    fi

    sleep 10
    ((waited += 10))
  done
}

install_phase() {
  log "Installing $(basename "$ISO") unattended via cidata (headless)"

  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
  detect_packages
  build_cidata

  # Build under a staging name: the finished base is promoted only after a
  # clean shutdown, so a failed install can never pass for a reusable base.
  rm -f "$BASE_DISK" "$BASE_DISK.building"
  qemu-img create -f qcow2 "$BASE_DISK.building" 40G >/dev/null
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
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  wait_for_unattended_install install || return 1

  log "Installed system is up. Saving base image."
  stop_vm
  mv "$BASE_DISK.building" "$BASE_DISK"
}
