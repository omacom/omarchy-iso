#!/bin/bash
#
# Build the Try layer: what turns the root image into a live Omarchy session
# when the ISO's "Try Omarchy" entry boots it (configs/airootfs/etc/initcpio/
# hooks/omarchy_try). The image itself stays exactly the bytes an install
# writes; this layer goes on top of it, read-only, under a tmpfs.
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
node_dir=${OMARCHY_TRY_NODE_DIR:-}
if [[ -d $node_dir ]]; then
  mkdir -p "$merged/opt/packages"
  mount --bind "$node_dir" "$merged/opt/packages"
fi
in_try runuser -u "$TRY_USER" -- env \
  HOME="/home/$TRY_USER" USER="$TRY_USER" LOGNAME="$TRY_USER" \
  OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
  OMARCHY_INSTALL_USER="$TRY_USER" MISE_OFFLINE=1 \
  /usr/bin/omarchy-provision-user --force --first-install
if mountpoint -q "$merged/opt/packages"; then
  umount "$merged/opt/packages"
  rmdir "$merged/opt/packages" 2>/dev/null || true
fi

# Stay awake: no screensaver and no idle lock in a session someone is trying
# out (the state omarchy-toggle-idle stay-awake writes).
in_try runuser -u "$TRY_USER" -- install -D -m 0644 /dev/null \
  "/home/$TRY_USER/.local/state/omarchy/indicators/stay-awake"

# Services Omarchy's install/config/enable-services.sh enables that a live
# desktop needs. Not cups, avahi or docker: nothing to print to, browse or run.
for unit in systemd-resolved.service NetworkManager.service power-profiles-daemon.service \
  sddm.service systemd-oomd.service; do
  in_try systemctl enable "$unit" >/dev/null 2>&1 || echo "WARNING: could not enable $unit" >&2
done
in_try systemctl mask NetworkManager-wait-online.service >/dev/null 2>&1 || true
ln -sf ../run/systemd/resolve/stub-resolv.conf "$merged/etc/resolv.conf"

# pacman. The image has no mirrorlist (pacstrap -M) and no keyring (-G); an
# install gets both at its end. The channel's pacman.conf and mirrorlist come
# from the step that gives an install them, the image's own
# install/post-install/pacman.sh, which renders them from Omarchy's templates
# with no network, whichever runtime the channel carries.
in_try env OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
  OMARCHY_MIRROR="$channel" PATH=/usr/share/omarchy/bin:/usr/bin \
  bash -c 'source "$OMARCHY_INSTALL/post-install/pacman.sh"' >/dev/null
# The keyring is made at boot, so no two sessions share a master key, as no
# two installs do. Then the package databases, which Omarchy's Install menu
# expects to be there (it runs pacman -S without -y): best effort, retried
# while the network comes up, and nothing is lost without one.
#
# Type=exec, not oneshot: multi-user.target would wait for those retries, and
# with it power-profiles-daemon (After=multi-user.target), which the Omarchy
# shell waits for at start. As a oneshot it held the desktop back by the
# whole wait for the network, 8.8 s on an MSI Z690. The keys are in 3.3 s
# after the unit starts, before the shell has loaded; a pacman run that meets
# the database sync fails on its lock, as during any update.
install -Dm644 /dev/stdin "$merged/etc/systemd/system/omarchy-try-keyring.service" <<'EOF'
[Unit]
Description=Try Omarchy: a pacman keyring of this session's own
ConditionPathExists=!/etc/pacman.d/gnupg/trustdb.gpg

[Service]
Type=exec
ExecStart=/usr/bin/bash -c 'pacman-key --init && pacman-key --populate || exit 1; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do pacman -Sy --noconfirm && break; sleep 5; done; exit 0'

[Install]
WantedBy=multi-user.target
EOF
in_try systemctl enable omarchy-try-keyring.service >/dev/null 2>&1

# SDDM straight into the session, as configure_login does for an encrypted
# install.
install -d "$merged/etc/sddm.conf.d"
cat >"$merged/etc/sddm.conf.d/99-omarchy-login.conf" <<EOF
[Theme]
Current=omarchy

[Users]
RememberLastUser=true
RememberLastSession=true
EOF
cat >"$merged/etc/sddm.conf.d/autologin.conf" <<EOF
[Autologin]
User=$TRY_USER
Session=omarchy.desktop
EOF

# Nothing in Try touches a disk.
#   Snapper and limine-snapper-sync work on the installed btrfs and its ESP;
#   / here is an overlay.
for unit in snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer \
  limine-snapper-sync.service; do
  in_try systemctl mask "$unit" >/dev/null 2>&1 || true
done
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

# The way to the installer: reboot and pick Install in the boot menu.
install -Dm755 /dev/stdin "$merged/usr/local/bin/omarchy-try-install" <<'EOF'
#!/bin/bash
# Try Omarchy runs from the stick. Installing is the other entry of its boot
# menu; offer the reboot that gets there.
if gum confirm "Omarchy installs from the boot menu: restart now and pick \"Install Omarchy\"?"; then
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

# Keep xattrs: overlayfs marks opaque directories with one, and a whiteout is
# a 0:0 character device; both must survive for the layer to hide what it
# deleted.
mksquashfs "$upper" "$output" -comp zstd -Xcompression-level 19 -b 1M -noappend -quiet
echo "Try layer: $(du -h "$output" | cut -f1) at $output"

[[ -n $pacman_conf ]] || exit 0

# Driver layers: what Omarchy's installer adds to a machine with an NVIDIA
# card or a T2 chip, one layer each, which the Try hook stacks over this one
# on such a machine. Each is made the way an install makes it: Omarchy's own
# install/hardware script runs in a chroot over the image and this layer,
# against a pretend PCI bus, and the packages it asks for are installed from
# the image's offline repository (DKMS builds against the image's kernel and
# headers). What it adds is the layer.
#
# The 32-bit libraries stay out (omarchy-hw-x86 answers no): a session that
# forgets everything has no Steam to run. So do kernels and headers: on a Mac
# the hook uses the live system's own linux-t2 modules.
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

  # Twice: first for the packages it asks for, then, with them installed,
  # for what it does with them (its files, its services).
  local pass
  for pass in packages config; do
    arch-chroot "$root" env PATH=/omarchy-try-stubs:/usr/share/omarchy/bin:/usr/bin \
      OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
      OMARCHY_PCI_DEVICES_PATH=/omarchy-try-stubs/pci \
      bash "/usr/share/omarchy/install/hardware/$script" >/dev/null
    if [[ $pass == packages ]]; then
      mapfile -t packages < <(grep -Ev '^(linux-t2|lib32-.*|.*-headers)$' "$stubs/packages")
      ((${#packages[@]})) || { echo "build-try-layer.sh: $script asked for nothing" >&2; exit 1; }
      pacstrap -C "$pacman_conf" -c -G -M "$root" "${packages[@]}" >/dev/null
    fi
  done

  rm -rf "$stubs"
  mark_updated "$root"
  umount -R "$root"
  mksquashfs "$dir/upper" "$(dirname "$output")/omarchy-try-$name.sfs" \
    -comp zstd -Xcompression-level 19 -b 1M -noappend -quiet
  echo "Try $name layer: $(du -h "$(dirname "$output")/omarchy-try-$name.sfs" | cut -f1) (${packages[*]})"
  rm -rf "$dir"
}

# A T2 Mac's bridge and an Ada card: the hardware install/hardware/
# apple/fix-t2.sh and nvidia.sh look for. Not the 580xx driver for Maxwell to
# Volta (its layer is about 0.55 GB, which the ISO's size limit has no room
# for): those cards run Try on nouveau, and an install still gets 580xx.
driver_layer t2 apple/fix-t2.sh "00:00.0 Non-VGA unclassified device [0000]: Apple Inc. T2 Bridge Controller [106b:1801]" 0x106b 0x1801 0x088000
driver_layer nvidia-open nvidia.sh "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [10de:2684]" 0x10de 0x2684 0x030000
