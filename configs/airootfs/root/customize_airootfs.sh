#!/usr/bin/env bash
#
# Post-pacstrap live-ISO customization (archiso customize_airootfs.sh).
#
# The omarchy runtime hard-depends on limine-mkinitcpio-hook, whose
# 90-mkinitcpio-install.hook lands in the chroot's /etc/pacman.d/hooks/ -- the
# exact directory archiso points pacman's HookDir at. That hook therefore
# replaces the standard mkinitcpio preset run with a Limine/UKI install into an
# EFI system partition. The ISO boots grub/syslinux and has no ESP, so the hook
# aborts during pacstrap and leaves /boot without the initramfs (nor the copied
# vmlinuz) that mkarchiso expects (install: cannot stat '/boot/initramfs-*.img').
#
# Fix: drop the Limine hook and wrapper, place each kernel's vmlinuz where its
# preset names (ALL_kver=/boot/vmlinuz-<pkgbase>), and rebuild the initramfs
# through the real /usr/bin/mkinitcpio -- the Limine wrapper at
# /usr/local/bin/mkinitcpio shadows it and aborts looking for an ESP.
#
# Every installed kernel is built, so the live medium ships both stock linux
# (the default try-desktop boot) and linux-t2 (T2/Mac keyboards and trackpads).
# Each kernel package installs /usr/lib/modules/<kver>/vmlinuz, records its
# pkgbase in /usr/lib/modules/<kver>/pkgbase, and ships the matching
# /etc/mkinitcpio.d/<pkgbase>.preset. We write the archiso presets ourselves so
# a kernel package's default preset cannot diverge from the archiso initramfs
# the boot loaders reference, then build one per kernel.
#
# Limine is the installer's bootloader on an installed system, not the ISO's.
set -euo pipefail

# 1. Remove the Limine kernel hook + wrapper so they can neither block mkinitcpio
#    nor persist into the live image. Tolerate a version that ships no such file.
rm -f \
  /etc/pacman.d/hooks/90-mkinitcpio-install.hook \
  /usr/local/bin/mkinitcpio \
  /usr/share/libalpm/hooks/60-limine-mkinitcpio-remove-pre.hook \
  /usr/share/libalpm/hooks/80-limine-efi-deploy.hook \
  /usr/share/libalpm/hooks/90-limine-mkinitcpio-remove-post.hook \
  /usr/share/libalpm/hooks/10-limine-snapper-lock.hook

# Identify the stock linux kernel's version.
linux_kver=""
for kver in /usr/lib/modules/*/; do
  kver="${kver%/}"
  [[ -f "$kver/pkgbase" ]] || continue
  pkgbase="$(cat "$kver/pkgbase")"
  if [[ $pkgbase == "linux" ]]; then
    linux_kver="${kver##*/}"
  fi
done

# 2. Compile the NVIDIA open driver (nvidia-open-dkms) ONCE here, at ISO-build
#    time, for the stock linux kernel using the linux-headers + base-devel
#    installed into this chroot. This drops the nvidia modules under
#    /usr/lib/modules/<linux-kver>/updates/dkms/, which the linux initramfs
#    below then bakes in. The result: the stock-linux try-desktop boot gets
#    NVIDIA modesetting with NO DKMS compile at live boot. linux-t2 has no
#    nvidia module (ABI mismatch; T2 Macs use Mesa/IGP) and is left untouched.
nvidia_present=0
if [[ -n $linux_kver && -d /usr/src && $(find /usr/src -maxdepth 1 -type d -name 'nvidia-open-*' 2>/dev/null | wc -l) -gt 0 ]]; then
  echo "customize_airootfs.sh: building nvidia-open-dkms for linux $linux_kver"
  if dkms autoinstall -k "$linux_kver"; then
    if compgen -G "/usr/lib/modules/$linux_kver/updates/dkms/nvidia*.ko*" >/dev/null; then
      nvidia_present=1
    fi
  else
    echo "customize_airootfs.sh: nvidia-open-dkms DKMS build failed; the linux initramfs will omit nvidia" >&2
  fi
fi

# 3. Write the canonical archiso presets for every kernel we boot, so the build
#    is deterministic regardless of what a kernel package shipped. The stock
#    linux preset uses the NVIDIA config (nvidia modules baked in) when the
#    driver compiled at step 2; otherwise it falls back to the plain config so a
#    DKMS hiccup degrades gracefully instead of hard-failing the ISO. linux-t2
#    always uses the plain config.
mkdir -p /etc/mkinitcpio.d

cat > /etc/mkinitcpio.d/linux.preset <<EOF
# mkinitcpio preset for the stock 'linux' kernel on the Omarchy live medium.
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux'
archiso_config='/etc/mkinitcpio.conf.d/$([ "$nvidia_present" = 1 ] && echo archiso-nvidia.conf || echo archiso.conf)'
archiso_image="/boot/initramfs-linux.img"
EOF

cat > /etc/mkinitcpio.d/linux-t2.preset <<'EOF'
# mkinitcpio preset for the 'linux-t2' kernel on the Omarchy live medium.
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux-t2'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image="/boot/initramfs-linux-t2.img"
EOF

# 4. Stage each kernel's vmlinuz where its preset names, then build the live
#    initramfs (/boot/initramfs-<pkgbase>.img) through the real mkinitcpio. The
#    linux preset points at archiso-nvidia.conf, whose MODULES list the nvidia
#    modules — present now because step 2 compiled them — so they end up inside
#    /boot/initramfs-linux.img.
built=0
for kver in /usr/lib/modules/*/; do
  kver="${kver%/}"
  [[ -f "$kver/pkgbase" && -f "$kver/vmlinuz" ]] || continue
  pkgbase="$(cat "$kver/pkgbase")"
  [[ -n $pkgbase && -f "/etc/mkinitcpio.d/$pkgbase.preset" ]] || continue
  install -D -m 0644 "$kver/vmlinuz" "/boot/vmlinuz-$pkgbase"
  /usr/bin/mkinitcpio --preset "$pkgbase"
  built=1
done

if ((built == 0)); then
  echo "customize_airootfs.sh: no kernel found under /usr/lib/modules" >&2
  exit 1
fi

# 5. Size hygiene: the nvidia module is baked into the live initramfs (step 2+4),
#    so the heavyweight build-only packages needed only to compile it have no
#    further purpose on the live medium. linux-headers is the large one
#    (~1.5-2GB); gcc/make/binutils are the rest of the compiler from base-devel.
#    Remove them without dependency resolution (-Rdd) so nothing cascades away
#    and gcc-libs / binutils-libs (which live apps link against) are kept. dkms
#    is kept too: nvidia-open-dkms lists it as a runtime dependency, and keeping
#    that dependency unbroken is worth its small footprint.
if [[ -n $linux_kver ]]; then
  pacman --noconfirm -Rdd linux-headers gcc make binutils 2>/dev/null || true
fi
