#!/bin/bash
# Add board packages without replacing Dragon's published Omarchy repository.
set -euo pipefail
config=${1:?online pacman configuration}
work=/var/cache/omarchy-hardware
repo=$work/repo
pacman --noconfirm -S --needed git python curl 7zip innoextract squashfs-tools libisoburn zstd alsa-utils alsa-ucm-conf dtc
python /hardware/fetch-firmware.py --work-dir "$work"
python /hardware/prepare-packages.py --work-dir "$work"
bash /builder/fetch-snapdragon-recipes.sh "$work/hardware"

# Build the exact tested Bluetooth tree from the selected Arch kernel package.
# Fail closed when the kernel DT changes; do not overwrite an unknown tree.
mkdir -p "$work/kernel" "$repo"
pacman --config "$config" --noconfirm -Sw --cachedir "$work/kernel" linux-aarch64
kernel=$(pacman --config "$config" -Sp --print-format '%n %f' linux-aarch64 | awk '$1 == "linux-aarch64" { print $2 }')
[[ -n $kernel && $kernel != *$'\n'* ]]
base=$work/base
mkdir -p "$base"
bsdtar -xf "$work/kernel/$kernel" -C "$base" boot/dtbs/qcom/x1e78100-lenovo-thinkpad-t14s.dtb
base_dtb=$base/boot/dtbs/qcom/x1e78100-lenovo-thinkpad-t14s.dtb
echo "f21573bd4946bf7118e467326b22de228cfd64c61255ed7b51baa71185808df9  $base_dtb" | sha256sum -c -
bt=$work/hardware/omarchy-hw-t14s-bluetooth-experimental
mkdir -p "$bt"
cp /hardware/t14-bluetooth-package/* "$bt/"
dtc -@ -I dts -O dtb -o "$work/t14.dtbo" /hardware/t14-bluetooth.dtso
fdtoverlay -i "$base_dtb" -o "$bt/x1e78100-lenovo-thinkpad-t14s.dtb" "$work/t14.dtbo"
echo "8061768e6ac74eaf3cc0039e060cb63c1a56d452850c7dcc6e756aa9f5cde3fb  $bt/x1e78100-lenovo-thinkpad-t14s.dtb" | sha256sum -c -
# Live image gets the same tree through customize_airootfs, before ukify.
install -Dm644 "$bt/x1e78100-lenovo-thinkpad-t14s.dtb" /var/cache/airootfs/root/t14-bluetooth.dtb
id omarchy-builder &>/dev/null || useradd -m omarchy-builder
for source in "$work"/hardware/*; do
  chown -R omarchy-builder:omarchy-builder "$source"
  (cd "$source" && runuser -u omarchy-builder -- makepkg --nodeps --noconfirm --force)
  shopt -s nullglob
  packages=("$source"/*.pkg.tar.zst "$source"/*.pkg.tar.xz)
  ((${#packages[@]} == 1))
  cp "${packages[@]}" "$repo/"
done
repo-add "$repo/omarchy-hardware.db.tar.gz" "$repo"/*.pkg.tar.*
# A distinct, first-priority repository preserves the published Omarchy channel.
awk -v repo="$repo" '
  /^\[/ && $0 != "[options]" && !inserted {
    print "[omarchy-hardware]\nSigLevel = Optional TrustAll\nServer = file://" repo "\n"
    inserted=1
  }
  { print }
' "$config" > "$config.hardware"
mv "$config.hardware" "$config"
