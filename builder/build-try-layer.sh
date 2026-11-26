#!/bin/bash
#
# Build the Try layer: what turns the root image into a live Omarchy session
# when the installer soft-reboots into it for Try Omarchy
# (configs/airootfs/usr/local/bin/omarchy-try). The image itself stays
# exactly the bytes an install writes; this layer goes on top of it,
# read-only, under a tmpfs.
#
# Usage: build-try-layer.sh <image root> <output.sfs> [channel] [pacman.conf]
#
#   image root   The image's subvolume, mounted (build-root-image.sh's $root).
#   output.sfs   Where to write the layer.
#   channel      The pacman channel of the session: stable (default), rc, edge.
#   pacman.conf  The image's offline repository: with it, the driver layers
#                are built next to output.sfs as well (see the end).
#
# It runs, once, the parts of an install that a live session needs, against an
# overlay of the image, and keeps the overlay's upper directory:
#
#   - user omarchy with no password, sudo without one, SDDM logging it in;
#   - omarchy-provision-user for it, as the installer runs it;
#   - the services an installed system enables for its desktop and network;
#   - pacman as an install leaves it: the channel's repositories and mirrors,
#     and a keyring of the session's own, made at boot;
#   - nothing that touches a disk: no Snapper or Limine timers, no mdraid or
#     LVM autoassembly, no automount of other disks.
#
# Needs a privileged environment: an overlay mount and arch-chroot.

set -euo pipefail

image_root="${1:-}"
output="${2:-}"
channel="${3:-stable}"
pacman_conf="${4:-}"
if [[ -z $image_root || -z $output ]]; then
  echo "Usage: build-try-layer.sh <image root> <output.sfs> [channel] [pacman.conf]" >&2
  exit 1
fi
case $channel in
stable | rc | edge) ;;
*)
  echo "build-try-layer.sh: unknown channel '$channel'" >&2
  exit 1
  ;;
esac

TRY_USER=omarchy
# The scripts the layer's own units run (builder/try-layer/).
scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/try-layer

work=$(mktemp -d /tmp/omarchy-try-layer.XXXXXX)
upper="$work/upper"
merged="$work/merged"

cleanup() {
  local status=$?
  set +e
  if mountpoint -q "$work" 2>/dev/null; then
    umount -R "$work" || { echo "WARNING: $work is still mounted; leaving it" >&2; return $status; }
  fi
  rm -rf "$work"
  return $status
}
trap cleanup EXIT

# On a tmpfs of its own: overlayfs refuses an upper directory on another
# overlay, which is what /tmp is inside the build container.
mount -t tmpfs -o mode=0755 omarchy-try-layer "$work"
mkdir -p "$upper" "$work/work" "$merged"

# index, metacopy and redirect_dir off: the upper directory then holds plain
# files and whiteouts only, nothing that refers back to this particular lower
# layer, so it stays valid when it is mounted over the image again at boot.
mount -t overlay try-layer \
  -o "lowerdir=$image_root,upperdir=$upper,workdir=$work/work,index=off,metacopy=off,redirect_dir=off" \
  "$merged"

in_try() {
  arch-chroot "$merged" "$@"
}

# The image carries no /etc/.updated (the installer stamps the installed
# system), so systemd's ConditionNeedsUpdate= units would run at every Try
# boot: ldconfig alone took 3.7 s from a USB stick on an MSI Z690, all of it
# before sysinit.target. Pacman and its hooks did their work when the
# packages went in; stamp each layer as the installer and the live system
# (customize_airootfs.sh) do.
mark_updated() {
  arch-chroot "$1" /usr/lib/systemd/systemd-update-done
}

# The user. passwd -d: no password, as most live sessions have; the
# session's sudo needs none either.
in_try useradd -m -G wheel -s /bin/bash "$TRY_USER"
in_try passwd -d "$TRY_USER" >/dev/null
install -d -m 0750 "$merged/etc/sudoers.d"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$TRY_USER" >"$merged/etc/sudoers.d/10-omarchy-try"
chmod 0440 "$merged/etc/sudoers.d/10-omarchy-try"

# The user's desktop, as the installer's run_chroot_finalizer makes it
# (orchestrator/phases_impl.py), offline as there. A runtime from before
# Omarchy installed Node lazily unpacks the ISO's bundled Node tarball while
# it does: the installer binds /opt/packages into the target for it
# (_prepare_target_setup), and so does this, for the run only.
#
# Isolate from the build host's hardware: omarchy-provision-user prepends
# $OMARCHY_PATH/bin to PATH and runs install/user/all.sh hardware tweaks
# (vm-no-animations, asus, dell, framework, fix-nouveau-cursor), and
# post-install/pacman.sh checks host platform/PCI. Bind-mount stub scripts
# directly over the real detector files in $merged (outside $merged so nothing
# leaks into $upper; check both /usr/bin and /usr/share/omarchy/bin without
# following absolute chroot symlinks) so building inside a CI VM or on a laptop
# never bakes host-specific toggles (like no-animations.lua) into Try.
host_stubs="$work/host-stubs"
mkdir -p "$host_stubs"
bound_stubs=()
bind_host_stub() {
  local stub=$1 cmd=$2 target
  for target in "$merged/usr/bin/$cmd" "$merged/usr/share/omarchy/bin/$cmd"; do
    if [[ -f $target && ! -L $target ]]; then
      mount --bind "$stub" "$target"
      bound_stubs+=("$target")
    fi
  done
}
for hw_cmd in omarchy-hw-vm omarchy-hw-asus-rog omarchy-hw-match omarchy-hw-pci; do
  printf '#!/bin/sh\nexit 1\n' >"$host_stubs/$hw_cmd"
  chmod 0755 "$host_stubs/$hw_cmd"
  bind_host_stub "$host_stubs/$hw_cmd" "$hw_cmd"
done
for noop_cmd in lspci pactl; do
  printf '#!/bin/sh\nexit 0\n' >"$host_stubs/$noop_cmd"
  chmod 0755 "$host_stubs/$noop_cmd"
  bind_host_stub "$host_stubs/$noop_cmd" "$noop_cmd"
done

node_dir=${OMARCHY_TRY_NODE_DIR:-}
if [[ -d $node_dir ]]; then
  mkdir -p "$merged/opt/packages"
  mount --bind "$node_dir" "$merged/opt/packages"
fi
in_try runuser -u "$TRY_USER" -- env \
  HOME="/home/$TRY_USER" USER="$TRY_USER" LOGNAME="$TRY_USER" \
  OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
  OMARCHY_INSTALL_USER="$TRY_USER" MISE_OFFLINE=1 \
  OMARCHY_PCI_DEVICES_PATH=/dev/null \
  OMARCHY_NOUVEAU_DRIVER_PATH=/dev/null \
  /usr/bin/omarchy-provision-user --force --first-install
if mountpoint -q "$merged/opt/packages"; then
  umount "$merged/opt/packages"
  rmdir "$merged/opt/packages" 2>/dev/null || true
fi

# Baseline system configs the installer writes for an installed machine:
# UTF-8 locale (en_US.UTF-8 is compiled into the root image), a hostname,
# and Chromium/Chrome browser policies & initial_preferences (so Try skips
# Chromium's first-run EULA/ToS prompt and follows the desktop theme).
printf 'LANG=en_US.UTF-8\n' >"$merged/etc/locale.conf"
printf 'omarchy\n' >"$merged/etc/hostname"
for cfg_script in browser-policy.sh theme-system.sh; do
  if [[ -f "$merged/usr/share/omarchy/install/config/$cfg_script" ]]; then
    in_try env OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
      PATH=/usr/share/omarchy/bin:/usr/bin \
      bash -c "source \"\$OMARCHY_INSTALL/config/$cfg_script\"" >/dev/null
  fi
done

# Idle as an install idles: Omarchy's screensaver, then its idle lock, which
# turns itself down here because Try ships no lock screen PAM file
# (omarchy-lock-password), so nobody is locked out of a session with no
# password.

# No lock before a suspend (a closed lid). Try ships no lock screen PAM file,
# so omarchy-system-sleep-lock could only send a critical notification at
# every suspend that it had not locked. The unit stays enableable: first-run
# enables it, and a mask would fail that step and rerun first-run at every
# login.
install -Dm644 /dev/stdin "$merged/etc/systemd/user/omarchy-sleep-lock.service.d/10-omarchy-try.conf" <<'EOF'
[Unit]
ConditionPathExists=/etc/pam.d/omarchy-lock-password
EOF

# The clock. An install turns NTP on and takes its timezone from the setup
# form, which suggests what geo.omarchy.org answers (Omarchy's
# install/provisioning/setup-form.sh). Try asks nothing, so it keeps NTP on
# and takes that answer itself once a network is up. Until then, and without
# a network, the session runs on UTC.
#
# Try must leave the machine's clock alone. With an RTC in UTC, timesyncd lets
# the kernel write the system time to the RTC every 11 minutes, and Windows
# keeps its RTC in local time. Declaring the RTC local makes timesyncd keep
# the kernel from writing it (systemd's timesyncd-manager.c). timedated would
# then write the RTC on set-timezone, so the dispatcher script links
# /etc/localtime itself and restarts a running timedated, which would keep
# reporting the zone it read at start. It runs from no-wait.d, so its retries
# hold up no other dispatcher script.
in_try systemctl enable systemd-timesyncd.service >/dev/null
printf '0.0 0 0\n0\nLOCAL\n' >"$merged/etc/adjtime"
install -Dm755 /dev/stdin "$merged/etc/NetworkManager/dispatcher.d/no-wait.d/50-omarchy-try-timezone" <<'EOF'
#!/bin/bash
# Try Omarchy: the timezone from geo.omarchy.org, the first time a network
# comes up (builder/build-try-layer.sh).
action=$2
[[ $action == "up" || ($action == "connectivity-change" && ${CONNECTIVITY_STATE:-} == "FULL") ]] || exit 0
[[ -e /etc/localtime ]] && exit 0
timezone=""
for attempt in 1 2 3 4 5 6; do
  # One whole answer per attempt: curl's own retries would append to a part.
  if answer=$(curl -fsS --max-time 5 https://geo.omarchy.org/ 2>/dev/null) &&
    timezone=$(jq -r '.timezone // empty' <<<"$answer" 2>/dev/null) && [[ -n $timezone ]]; then
    break
  fi
  timezone=""
  ((attempt < 6)) && sleep 5
done
[[ $timezone =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$timezone ]] || exit 0
# The user may have picked a timezone during the lookup.
[[ -e /etc/localtime ]] && exit 0
ln -s "../usr/share/zoneinfo/$timezone" /etc/localtime
systemctl try-restart systemd-timedated.service
exit 0
EOF
ln -s no-wait.d/50-omarchy-try-timezone "$merged/etc/NetworkManager/dispatcher.d/50-omarchy-try-timezone"

# Devices the live installer ran without what they need: no radio firmware,
# no SOF audio. omarchy-try lets them go before its soft reboot, which keeps
# the kernel's drivers, and udev's coldplug replays uevents without probing a
# loaded driver again. Once udev has loaded what it loads, probe every PCI and
# USB device that still has no driver, with the session's firmware and
# modprobe settings in place (builder/try-layer/).
install -Dm755 "$scripts/omarchy-try-reprobe" "$merged/usr/local/lib/omarchy-try/omarchy-try-reprobe"
install -Dm644 /dev/stdin "$merged/etc/systemd/system/omarchy-try-reprobe.service" <<'EOF'
[Unit]
Description=Try Omarchy: probe the devices the installer's drivers left
DefaultDependencies=no
After=systemd-udev-trigger.service systemd-modules-load.service omarchy-try-nvidia-handover.service
Before=sysinit.target network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/omarchy-try/omarchy-try-reprobe

[Install]
WantedBy=sysinit.target
EOF
in_try systemctl enable omarchy-try-reprobe.service >/dev/null

# The NVIDIA layer's driver can only take a card no driver holds. Try starts
# from the live installer by a soft reboot, and the kernel keeps what the
# installer loaded: nouveau, bound to the card and to the console. Before udev
# loads the NVIDIA driver, give the card up: the console first, then nouveau.
# Only with the NVIDIA layer, the one place /etc/modprobe.d/nvidia.conf comes
# from (builder/try-layer/).
install -Dm755 "$scripts/omarchy-try-nvidia-handover" "$merged/usr/local/lib/omarchy-try/omarchy-try-nvidia-handover"
install -Dm644 /dev/stdin "$merged/etc/systemd/system/omarchy-try-nvidia-handover.service" <<'EOF'
[Unit]
Description=Try Omarchy: hand the NVIDIA card from nouveau to the NVIDIA driver
DefaultDependencies=no
ConditionPathExists=/etc/modprobe.d/nvidia.conf
ConditionPathExists=/sys/module/nouveau
Before=systemd-udev-trigger.service sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/omarchy-try/omarchy-try-nvidia-handover

[Install]
WantedBy=sysinit.target
EOF
in_try systemctl enable omarchy-try-nvidia-handover.service >/dev/null

# Guard Hyprland's NVIDIA env script for cards that run Try on nouveau
# (Maxwell-Volta GPUs, which have no 580xx layer, and non-T2 Macs booting
# linux-t2). default/hypr/nvidia.lua checks sysfs PCI IDs rather than the
# loaded driver, so without a guard it exports __GLX_VENDOR_LIBRARY_NAME=nvidia
# and NVD_BACKEND=egl when nvidia-utils is absent. The guard asks the kernel
# whether nvidia_drm is loaded: a layer on the disk is no driver on the card.
nvidia_lua="$merged/usr/share/omarchy/default/hypr/nvidia.lua"
if [[ -f $nvidia_lua ]]; then
  mv "$nvidia_lua" "$merged/usr/share/omarchy/default/hypr/nvidia_upstream.lua"
  cat >"$nvidia_lua" <<'EOF'
-- Try Omarchy guard: only apply proprietary NVIDIA environment variables when
-- the NVIDIA driver runs. Otherwise NVIDIA GPUs run Try on nouveau (e.g.
-- Maxwell-Volta without 580xx, Macs booting linux-t2, or a card nouveau kept
-- when the handover from the installer failed), where exporting
-- __GLX_VENDOR_LIBRARY_NAME=nvidia breaks GLX and hardware cursors can be
-- invisible.
local f = io.open("/sys/module/nvidia_drm/initstate", "r")
if f then
  f:close()
  require("default.hypr.nvidia_upstream")
else
  local paths = require("default.hypr.paths")
  if o.shell_succeeds(o.shell_quote(paths.omarchy_path .. "/bin/omarchy-hw-nvidia")) then
    hl.config({
      cursor = {
        no_hardware_cursors = true,
      },
    })
  end
end
EOF
fi

# Services Omarchy's install/config/enable-services.sh and hardware/bluetooth.sh
# enable that a live desktop needs. Not cups, avahi or docker: nothing to print
# to, browse or run. Retire systemd-networkd (enabled by systemd's default
# preset in the root image) so it does not compete with NetworkManager.
for unit in systemd-resolved.service NetworkManager.service power-profiles-daemon.service \
  sddm.service systemd-oomd.service bluetooth.service; do
  in_try systemctl enable "$unit" >/dev/null 2>&1 || echo "WARNING: could not enable $unit" >&2
done
for unit in systemd-networkd.service systemd-networkd.socket \
  systemd-networkd-wait-online.service; do
  in_try systemctl disable "$unit" >/dev/null 2>&1 || true
done
for unit in NetworkManager-wait-online.service systemd-networkd-wait-online.service; do
  in_try systemctl mask "$unit" >/dev/null 2>&1 || true
done
ln -sf ../run/systemd/resolve/stub-resolv.conf "$merged/etc/resolv.conf"

# pacman. The image has no mirrorlist (pacstrap -M) and no keyring (-G); an
# install gets both at its end. The channel's pacman.conf and mirrorlist come
# from the step that gives an install them, the image's own
# install/post-install/pacman.sh, which renders them from Omarchy's templates
# with no network, whichever runtime the channel carries.
in_try env OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
  OMARCHY_MIRROR="$channel" \
  PATH=/usr/share/omarchy/bin:/usr/bin \
  OMARCHY_PCI_DEVICES_PATH=/dev/null \
  bash -c 'source "$OMARCHY_INSTALL/post-install/pacman.sh"' >/dev/null
for bound_stub in "${bound_stubs[@]}"; do
  umount "$bound_stub"
done
rm -rf "$host_stubs"
# The keyring is made at boot, so no two sessions share a master key, as no
# two installs do. Keep the package sync databases that ship-sync-databases.sh
# already placed in the root image: they match the exact package versions in
# omarchy-root.sfs, whereas running `pacman -Sy` at boot overwrites them with
# newer indexes (causing partial-upgrade breakage on aged ISOs, lock contention,
# and spurious "Update System" prompts).
#
# Type=exec, not oneshot: multi-user.target does not wait for gpg keygen, and
# neither does power-profiles-daemon (After=multi-user.target), which the
# Omarchy shell waits for at start.
install -Dm644 /dev/stdin "$merged/etc/systemd/system/omarchy-try-keyring.service" <<'EOF'
[Unit]
Description=Try Omarchy: a pacman keyring of this session's own
ConditionPathExists=!/etc/pacman.d/gnupg/trustdb.gpg

[Service]
Type=exec
ExecStart=/usr/bin/bash -c 'pacman-key --init && pacman-key --populate'

[Install]
WantedBy=multi-user.target
EOF
in_try systemctl enable omarchy-try-keyring.service >/dev/null 2>&1

# SDDM straight into the session, as configure_login does for an encrypted
# install, with four guards so Try never strands the user on a password prompt
# or a black screen:
#   1. Wait up to 10 s for udev to settle before starting SDDM: the live
#      initramfs carries no kms hook, so GPU drivers (amdgpu, i915, xe,
#      nvidia_drm) load asynchronously from the USB medium and unbind simpledrm
#      after switch_root; launching Hyprland mid-handoff can kill the session.
#   2. Seed /var/lib/sddm/state.conf (as configure_login does) so SDDM's last
#      user is never empty if it falls back to its greeter before autologin
#      writes state.conf.
#   3. Use a passwordless omarchy-try greeter theme that auto-logs in as
#      $TRY_USER after 500 ms instead of showing a password box.
#   4. Wrap the Wayland session so exit code 1 is remapped to 2: SDDM's
#      sddm-helper exits with the session's raw status, and Display maps 1 to
#      HELPER_AUTH_ERROR and stops restarting the display (breaking Relogin).
install -Dm644 /dev/stdin "$merged/etc/systemd/system/sddm.service.d/10-omarchy-try-udev.conf" <<'EOF'
[Service]
ExecStartPre=-/usr/bin/udevadm settle --timeout=10
EOF

try_theme="$merged/usr/share/sddm/themes/omarchy-try"
install -d "$try_theme"
for theme_file in metadata.desktop theme.conf logo.png; do
  if [[ -f "$merged/usr/share/sddm/themes/omarchy/$theme_file" ]]; then
    cp -a "$merged/usr/share/sddm/themes/omarchy/$theme_file" "$try_theme/$theme_file"
  fi
done
if [[ -f "$try_theme/metadata.desktop" ]]; then
  sed -i -e 's/^Name=.*/Name=omarchy-try/' -e 's/^Theme-Id=.*/Theme-Id=omarchy-try/' "$try_theme/metadata.desktop"
else
  cat >"$try_theme/metadata.desktop" <<'EOF'
[SddmGreeterTheme]
Name=omarchy-try
Type=sddm-theme
MainScript=Main.qml
ConfigFile=theme.conf
Theme-Id=omarchy-try
Theme-API=2.0
QtVersion=6
EOF
fi
[[ -f "$try_theme/theme.conf" ]] || : >"$try_theme/theme.conf"
cat >"$try_theme/Main.qml" <<EOF
import QtQuick 2.0
import SddmComponents 2.0

Rectangle {
  id: root
  width: 640
  height: 480
  color: "#1a1b26"
  focus: true

  property int sessionIndex: {
    for (var i = 0; i < sessionModel.rowCount(); i++) {
      var name = (sessionModel.data(sessionModel.index(i, 0), Qt.DisplayRole) || "").toString()
      if (name.indexOf("Omarchy") !== -1)
        return i
    }
    for (var j = 0; j < sessionModel.rowCount(); j++) {
      var fallback = (sessionModel.data(sessionModel.index(j, 0), Qt.DisplayRole) || "").toString()
      if (fallback.indexOf("uwsm") !== -1)
        return j
    }
    return sessionModel.lastIndex
  }

  Image {
    source: "logo.png"
    width: Math.min(sourceSize.width, root.width * 0.8)
    height: sourceSize.width > 0 ? Math.round(width * sourceSize.height / sourceSize.width) : 0
    fillMode: Image.PreserveAspectFit
    anchors.centerIn: parent
  }

  Timer {
    interval: 500
    running: true
    repeat: false
    onTriggered: sddm.login("$TRY_USER", "", root.sessionIndex)
  }

  Keys.onPressed: {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      sddm.login("$TRY_USER", "", root.sessionIndex)
      event.accepted = true
    }
  }
}
EOF

install -d "$merged/etc/sddm.conf.d"
cat >"$merged/etc/sddm.conf.d/99-omarchy-login.conf" <<EOF
[Theme]
Current=omarchy-try

[Users]
RememberLastUser=true
RememberLastSession=true
EOF
# Relogin: SDDM logs in by itself only once per boot. When the session ends
# (Hyprland exits or crashes, or a logout), it shows its greeter instead of
# starting the session again.
cat >"$merged/etc/sddm.conf.d/autologin.conf" <<EOF
[Autologin]
User=$TRY_USER
Session=omarchy.desktop
Relogin=true
EOF

install -d "$merged/var/lib/sddm"
cat >"$merged/var/lib/sddm/state.conf" <<EOF
[Last]
Session=omarchy.desktop
User=$TRY_USER
EOF
chmod 0644 "$merged/var/lib/sddm/state.conf"
in_try chown sddm:sddm /var/lib/sddm /var/lib/sddm/state.conf

session_desktop="$merged/usr/local/share/wayland-sessions/omarchy.desktop"
if [[ -f $session_desktop ]]; then
  session_exec=$(sed -n 's/^Exec=//p' "$session_desktop" | head -1)
  if [[ -n $session_exec ]]; then
    install -Dm755 /dev/stdin "$merged/usr/local/bin/omarchy-try-session" <<EOF
#!/bin/bash
start=\$(date +%s)
trap '[[ -n \${child:-} ]] && kill -TERM "\$child" 2>/dev/null; wait "\$child" 2>/dev/null; exit 0' TERM INT
$session_exec &
child=\$!
wait "\$child"
rc=\$?
if (( rc != 0 && \$(date +%s) - start < 5 )); then
  sleep 1
fi
(( rc == 1 )) && exit 2
exit "\$rc"
EOF
    sed -i 's|^Exec=.*|Exec=/usr/local/bin/omarchy-try-session|' "$session_desktop"
  fi
fi

# Nothing in Try touches a disk or the host OS's boot/hibernate state.
#   - Snapper and limine-snapper-sync work on the installed btrfs and its ESP;
#     / here is an overlay.
#   - systemd-hibernate-clear.service deletes the host OS's HibernateLocation
#     EFI variable on boot, destroying resume state on a hibernated machine.
#   - lvm2-monitor.service / lvm2-lvmpolld.socket run `lvm vgchange --monitor y`
#     even with 69-dm-lvm.rules masked.
#   - systemd-boot-random-seed.service writes to the ESP when chainloaded from
#     systemd-boot.
for unit in snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer \
  limine-snapper-sync.service systemd-hibernate-clear.service \
  lvm2-monitor.service lvm2-lvmpolld.socket systemd-boot-random-seed.service; do
  in_try systemctl mask "$unit" >/dev/null 2>&1 || true
done
#   systemd-gpt-auto-generator mounts the ESP the boot loader names, and swap
#   on the disk / is on. Try starts by a soft reboot, which keeps the
#   installer's kernel command line, so systemd.gpt_auto=0 cannot be passed
#   there: the generator is turned off here instead.
install -d "$merged/etc/systemd/system-generators"
ln -sf /dev/null "$merged/etc/systemd/system-generators/systemd-gpt-auto-generator"
#   mdadm's udev rule assembles RAID members it finds, and assembly can write
#   to them (a resync); LVM activates volume groups on its own.
install -d "$merged/etc/udev/rules.d"
ln -sf /dev/null "$merged/etc/udev/rules.d/64-md-raid-assembly.rules"
ln -sf /dev/null "$merged/etc/udev/rules.d/69-dm-lvm.rules"
#   Omarchy's Hyprland autostart runs `udiskie --automount`, and a command
#   line option beats udiskie's config file. /usr/local/bin is ahead of
#   /usr/bin on PATH, so this wrapper turns it into --no-automount: Try mounts
#   nothing on its own and never asks to unlock a disk.
install -Dm755 /dev/stdin "$merged/usr/local/bin/udiskie" <<'EOF'
#!/bin/bash
args=()
for arg in "$@"; do
  case $arg in
  -a | --automount) args+=(--no-automount) ;;
  *) args+=("$arg") ;;
  esac
done
exec /usr/bin/udiskie "${args[@]}"
EOF

# The way to the installer: restart from the stick, whose installer asks first
# whether to install or try.
install -Dm755 /dev/stdin "$merged/usr/local/bin/omarchy-try-install" <<'EOF'
#!/bin/bash
# Try Omarchy runs from the stick, and so does the installer: offer the
# restart that gets there.
if gum confirm "Restart into the Omarchy installer?"; then
  systemctl reboot
fi
EOF
install -Dm644 /dev/stdin "$merged/usr/local/share/applications/omarchy-try-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Omarchy
Comment=Restart into the installer
Exec=xdg-terminal-exec omarchy-try-install
Icon=system-software-install
Terminal=false
EOF

# The audio firmware an install adds only where the sound hardware needs it
# (per_machine_packages in build-iso.sh), so the image leaves it out. A Try
# session runs on whatever machine boots it: without SOF's firmware an Intel
# laptop whose audio runs on its DSP has no sound.
if [[ -n $pacman_conf ]]; then
  pacstrap -C "$pacman_conf" -c -G -M "$merged" sof-firmware alsa-firmware >/dev/null
fi

# Built on the build host's clock and identity; the session makes its own.
: >"$merged/etc/machine-id"

mark_updated "$merged"
umount -R "$merged"

try_zstd_level=19
[[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]] && try_zstd_level=1

# Keep xattrs: overlayfs marks opaque directories with one, and a whiteout is
# a 0:0 character device; both must survive for the layer to hide what it
# deleted.
mksquashfs "$upper" "$output" -comp zstd -Xcompression-level "$try_zstd_level" -b 1M -noappend -quiet
echo "Try layer: $(du -h "$output" | cut -f1) at $output"

[[ -n $pacman_conf ]] || exit 0

# Driver layers: what Omarchy's installer adds to a machine with an NVIDIA
# card or a T2 chip, one layer each, which omarchy-try stacks over this one
# on such a machine. Each is made the way an install makes it: Omarchy's own
# install/hardware script runs in a chroot over the image and this layer,
# against a pretend PCI bus, and the packages it asks for are installed from
# the image's offline repository (DKMS builds against the image's kernel and
# headers). What it adds is the layer.
#
# The 32-bit libraries stay out (omarchy-hw-x86 answers no): a session that
# forgets everything has no Steam to run. So do kernels and headers: on a Mac
# omarchy-try gives the session the live system's own linux-t2 modules.
driver_layer() { # name, script, lspci line, PCI vendor, device, class
  local name=$1 script=$2 line=$3 dir="$work/$1"
  local root="$dir/merged" stubs="$dir/merged/omarchy-try-stubs" packages=()

  mkdir -p "$dir/upper" "$dir/work" "$root"
  mount -t overlay "try-$name" \
    -o "lowerdir=$upper:$image_root,upperdir=$dir/upper,workdir=$dir/work,index=off,metacopy=off,redirect_dir=off" \
    "$root"

  mkdir -p "$stubs/pci/0000:01:00.0"
  printf '%s\n' "$4" >"$stubs/pci/0000:01:00.0/vendor"
  printf '%s\n' "$5" >"$stubs/pci/0000:01:00.0/device"
  printf '%s\n' "$6" >"$stubs/pci/0000:01:00.0/class"
  printf '#!/bin/sh\necho "%s"\n' "$line" >"$stubs/lspci"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>/omarchy-try-stubs/packages\n' >"$stubs/omarchy-pkg-add"
  printf '#!/bin/sh\nexit 1\n' >"$stubs/omarchy-hw-x86"
  chmod 0755 "$stubs/lspci" "$stubs/omarchy-pkg-add" "$stubs/omarchy-hw-x86"

  # Twice: first to collect the packages it asks for (with systemctl stubbed
  # because the packages' units are not installed yet), then, with the packages
  # installed and the real systemctl restored, for its files and services.
  printf '#!/bin/sh\nexit 0\n' >"$stubs/systemctl"
  chmod 0755 "$stubs/systemctl"
  local pass
  for pass in packages config; do
    arch-chroot "$root" env PATH=/omarchy-try-stubs:/usr/share/omarchy/bin:/usr/bin \
      OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
      OMARCHY_PCI_DEVICES_PATH=/omarchy-try-stubs/pci \
      bash "/usr/share/omarchy/install/hardware/$script" >/dev/null
    if [[ $pass == packages ]]; then
      rm -f "$stubs/systemctl"
      mapfile -t packages < <(grep -Ev '^(linux-t2|lib32-.*|.*-headers)$' "$stubs/packages")
      ((${#packages[@]})) || { echo "build-try-layer.sh: $script asked for nothing" >&2; exit 1; }
      pacstrap -C "$pacman_conf" -c -G -M "$root" "${packages[@]}" >/dev/null
    fi
  done

  rm -rf "$stubs"
  mark_updated "$root"
  umount -R "$root"
  mksquashfs "$dir/upper" "$(dirname "$output")/omarchy-try-$name.sfs" \
    -comp zstd -Xcompression-level "$try_zstd_level" -b 1M -noappend -quiet
  echo "Try $name layer: $(du -h "$(dirname "$output")/omarchy-try-$name.sfs" | cut -f1) (${packages[*]})"
  rm -rf "$dir"
}

# A T2 Mac's bridge and an Ada card: the hardware install/hardware/
# apple/fix-t2.sh and nvidia.sh look for. Not the 580xx driver for Maxwell to
# Volta (its layer is about 0.55 GB, which the ISO's size limit has no room
# for): those cards run Try on nouveau, and an install still gets 580xx.
driver_layer t2 apple/fix-t2.sh "00:00.0 Non-VGA unclassified device [0000]: Apple Inc. T2 Bridge Controller [106b:1801]" 0x106b 0x1801 0x088000
driver_layer nvidia-open nvidia.sh "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [10de:2684]" 0x10de 0x2684 0x030000
