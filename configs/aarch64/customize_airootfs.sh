#!/bin/bash
# Reconcile Arch Linux ARM kernel paths with the names expected by archiso.
set -euo pipefail

if [[ $(uname -m) != aarch64 ]]; then
  exit 0
fi

# linux-aarch64 does not provide the thunderbolt module.
if [[ -f /etc/mkinitcpio.conf.d/thunderbolt_module.conf ]]; then
  sed -i 's/^MODULES+=(thunderbolt)/#MODULES+=(thunderbolt)  # not built for aarch64/' \
    /etc/mkinitcpio.conf.d/thunderbolt_module.conf
fi

# Give mkarchiso the kernel filename it copies into the ISO.
if [[ ! -e /boot/vmlinuz-linux-aarch64 ]]; then
  if [[ -e /boot/Image ]]; then
    cp -a /boot/Image /boot/vmlinuz-linux-aarch64
  else
    echo "customize_airootfs: no kernel image at /boot/Image or /boot/vmlinuz-linux-aarch64" >&2
    exit 1
  fi
fi

# Drop presets whose kernel image is absent.
for preset in /etc/mkinitcpio.d/*.preset; do
  [[ -e $preset ]] || continue
  kname="$(basename "$preset" .preset)"
  if [[ $kname != linux-aarch64 && ! -e /boot/vmlinuz-$kname ]]; then
    echo "customize_airootfs: dropping $kname.preset (no kernel image)"
    rm -f "$preset"
  fi
done

# Keep drop-ins enabled so the aarch64 live hooks override installed-system hooks.
cat > /etc/mkinitcpio.d/linux-aarch64.preset <<'PRESET'
# Live-ISO preset for Arch Linux ARM's linux-aarch64.
PRESETS=('archiso')

ALL_kver='/boot/vmlinuz-linux-aarch64'
archiso_image="/boot/initramfs-linux-aarch64.img"
PRESET

# Restore the normal pacman sandbox in the live system after cross-build extraction.
sed -i '/^DisableSandbox$/d' /etc/pacman.conf

echo "customize_airootfs: building the live initramfs with aarch64 overrides"
rm -f /boot/initramfs-linux*.img

mkinitcpio -p linux-aarch64

# Fail the build if GRUB's initramfs was not produced.
if [[ ! -s /boot/initramfs-linux-aarch64.img ]]; then
  echo "customize_airootfs: no live initramfs was produced; the ISO would not boot" >&2
  exit 1
fi
echo "customize_airootfs: initramfs present ($(stat -c %s /boot/initramfs-linux-aarch64.img) bytes)"

# Inspect the image, not just the source configuration. A package hook can
# successfully build an installed-system initramfs that cannot boot live media.
contents=$(lsinitcpio /boot/initramfs-linux-aarch64.img)
for hook in archiso archiso_loop_mnt; do
  if ! grep -Eq "(^|/)hooks/$hook$" <<<"$contents"; then
    echo "customize_airootfs: live initramfs is missing $hook" >&2
    exit 1
  fi
done

# Generic UEFI media uses the hardware description supplied by firmware.
# Snapdragon media keeps its tested DTB-carrying UKI path.
case "$(cat /root/omarchy_media_target)" in
  aarch64/snapdragon)
    for firmware in qcom/gen70500_sqe.fw qcom/gen70500_gmu.bin qcom/x1e80100/gen70500_zap.mbn; do
      if ! grep -Eq "usr/lib/firmware/${firmware//./[.]}([.](xz|zst))?$" <<<"$contents"; then
        echo "customize_airootfs: missing early GPU firmware $firmware" >&2
        exit 1
      fi
    done
    if ! grep -q '^hooks/dragon_hp_thinkpad$' <<<"$contents"; then
      echo 'customize_airootfs: missing early boot diagnostic hook' >&2
      exit 1
    fi
    for dtb in /boot/dtbs/qcom/*thinkpad-t14s*.dtb; do
      if grep -aq 'pcie-m2-' "$dtb" && ! grep -Eq 'pwrseq-pcie-m2[.]ko([.](xz|zst|gz))?$' <<<"$contents"; then
        echo "customize_airootfs: $dtb requires an absent M.2 power sequencer" >&2
        exit 1
      fi
    done
    # Check the actual storage providers in the initramfs, before publishing an ISO.
    kernel_dirs=(/usr/lib/modules/*)
    if ((${#kernel_dirs[@]} != 1)); then
      echo "customize_airootfs: expected one live kernel module tree" >&2
      exit 1
    fi
    for module in nvme phy-qcom-qmp-pcie pwrseq-qcom-wcn pci-pwrctrl-pwrseq; do
      if [[ $(modinfo -k "${kernel_dirs[0]##*/}" -F filename "$module") == '(builtin)' ]]; then
        continue
      fi
      if ! grep -Eq "${module}[.]ko([.](xz|zst|gz))?$" <<<"$contents"; then
        echo "customize_airootfs: missing early storage/power driver $module" >&2
        exit 1
      fi
    done
    for firmware in \
      qcom/x1e80100/hp/elitebook-ultra-g1q/qcadsp8380.mbn \
      qcom/x1e80100/hp/elitebook-ultra-g1q/qccdsp8380.mbn \
      qcom/x1e80100/hp/elitebook-ultra-g1q/cdsp_dtbs.elf \
      qcom/x1e80100/LENOVO/21N1/qcadsp8380.mbn \
      qcom/x1e80100/LENOVO/21N1/qccdsp8380.mbn \
      qcom/x1e80100/LENOVO/21N1/cdsp_dtbs.elf; do
      if ! grep -Fq "usr/lib/firmware/updates/$firmware" <<<"$contents"; then
        echo "customize_airootfs: missing experimental firmware $firmware" >&2
        exit 1
      fi
    done
    if ! grep -Eq 'panel-edp[.]ko([.](xz|zst|gz))?$' <<<"$contents"; then
      echo "customize_airootfs: missing early LCD panel driver" >&2
      exit 1
    fi
    base_dtb=/boot/dtbs/qcom/x1e78100-lenovo-thinkpad-t14s.dtb
    echo "f21573bd4946bf7118e467326b22de228cfd64c61255ed7b51baa71185808df9  $base_dtb" | sha256sum -c -
    echo '8061768e6ac74eaf3cc0039e060cb63c1a56d452850c7dcc6e756aa9f5cde3fb  /root/t14-bluetooth.dtb' | sha256sum -c -
    install -m644 /root/t14-bluetooth.dtb "$base_dtb"
    rm /root/t14-bluetooth.dtb
    /root/live-uki.sh
    ;;
  aarch64/generic) ;;
  *) echo "customize_airootfs: unsupported media target" >&2; exit 1 ;;
esac

exit 0
