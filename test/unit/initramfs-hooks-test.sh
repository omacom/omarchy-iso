#!/bin/bash
# shellcheck disable=SC2329 # the mkinitcpio stubs below are called by the sourced hooks
#
# The live initramfs's block and filesystems hooks are this repository's own,
# under mkinitcpio's names (configs/airootfs/etc/initcpio/install/): the same
# drivers for the devices an install medium can be on, without the server
# storage controllers and the network and cluster filesystems. These cases run
# both hooks against stubbed mkinitcpio helpers:
#
# - block's filter drops the Fibre Channel, iSCSI and RAID HBAs and keeps
#   everything a medium is reached through: USB storage, SATA and NVMe,
#   SD cards, optical drives, and the VM controllers (virtio, Hyper-V, VMware,
#   Xen, the LSI Logic one QEMU and VMware emulate).
# - on x86 block leaves out the power (regulator) and clock chips of device
#   tree boards, which an aarch64 kernel keeps; everywhere it leaves out the
#   cs42l43 codec's SPI and MFD parts and keeps the other SPI controllers and
#   MFD drivers (Intel's LPSS: the SPI keyboards of older MacBooks).
# - the rest of block is mkinitcpio's own, line for line, when mkinitcpio is
#   installed here: an upstream change to it shows up as a failure.
# - filesystems adds the ISO's and a host partition's filesystems and the
#   character sets they default to, and no network filesystem, other code
#   page or mount helper.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALL="$ROOT/configs/airootfs/etc/initcpio/install"

failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# Stubs: record what the hook asks mkinitcpio for (the hooks call them).
calls=()
map() { local f=$1 a; shift; for a in "$@"; do "$f" "$a"; done; }
add_module() { calls+=("module $1"); }
add_all_modules() { calls+=("all $*"); }
add_binary() { calls+=("binary $*"); }
filter=''
add_checked_modules() {
  if [[ $1 == -f && $3 == '/(block|ata|scsi|fusion|nvme)/' ]]; then filter=$2; fi
  calls+=("checked $*")
}

# The kernel's module tree: an x86 one, with arch/x86.
kmod=$(mktemp -d)
trap 'rm -rf "$kmod"' EXIT
mkdir -p "$kmod/x86/kernel/arch/x86" "$kmod/arm64/kernel/arch/arm64"
_d_kmoduledir=$kmod/x86
# shellcheck source=/dev/null
source "$INSTALL/block"
build
if [[ -n $filter ]]; then ok "block filters the pata/sata/scsi/nvme set"; else fail "block has no filter on its scsi line"; fi

k=/usr/lib/modules/7.2.8-9-omarchy/kernel
dropped() { [[ $k/$1 =~ $filter ]]; }
for m in drivers/scsi/lpfc/lpfc.ko.zst drivers/scsi/qla2xxx/qla2xxx.ko.zst drivers/scsi/megaraid/megaraid_sas.ko.zst \
  drivers/scsi/hpsa.ko.zst drivers/scsi/mpt3sas/mpt3sas.ko.zst drivers/scsi/smartpqi/smartpqi.ko.zst \
  drivers/scsi/aacraid/aacraid.ko.zst drivers/scsi/cxgbi/cxgb4i/cxgb4i.ko.zst drivers/scsi/bfa/bfa.ko.zst \
  drivers/scsi/libiscsi.ko.zst drivers/scsi/qla2xxx/tcm_qla2xxx.ko.zst drivers/target/target_core_mod.ko.zst \
  drivers/scsi/device_handler/scsi_dh_alua.ko.zst drivers/scsi/scsi_debug.ko.zst drivers/scsi/st.ko.zst \
  drivers/scsi/ch.ko.zst drivers/scsi/pcmcia/aha152x_cs.ko.zst drivers/scsi/ips.ko.zst \
  drivers/block/floppy.ko.zst drivers/block/rbd.ko.zst drivers/block/zram/zram.ko.zst drivers/block/aoe/aoe.ko.zst \
  drivers/block/rnbd/rnbd-client.ko.zst drivers/nvme/host/nvme-tcp.ko.zst drivers/nvme/host/nvme-rdma.ko.zst \
  drivers/nvme/target/nvmet.ko.zst drivers/block/nbd.ko.zst drivers/ata/pata_parport/pata_parport.ko.zst \
  drivers/ata/pata_parport/bpck.ko.zst; do
  if dropped "$m"; then ok "drops ${m##*/}"; else fail "keeps ${m##*/}"; fi
done
for m in drivers/scsi/sd_mod.ko.zst drivers/scsi/sr_mod.ko.zst drivers/scsi/scsi_mod.ko.zst drivers/scsi/sg.ko.zst \
  drivers/scsi/virtio_scsi.ko.zst drivers/scsi/vmw_pvscsi.ko.zst drivers/scsi/hv_storvsc.ko.zst \
  drivers/scsi/xen-scsifront.ko.zst drivers/scsi/scsi_transport_sas.ko.zst drivers/scsi/scsi_transport_fc.ko.zst \
  drivers/scsi/scsi_transport_spi.ko.zst drivers/scsi/raid_class.ko.zst drivers/message/fusion/mptspi.ko.zst \
  drivers/message/fusion/mptsas.ko.zst drivers/ata/ahci.ko.zst drivers/ata/ata_piix.ko.zst \
  drivers/nvme/host/nvme.ko.zst drivers/nvme/host/nvme-core.ko.zst drivers/block/loop.ko.zst \
  drivers/block/xen-blkfront.ko.zst drivers/block/mtip32xx/mtip32xx.ko.zst drivers/block/virtio_blk.ko.zst \
  drivers/usb/storage/uas.ko.zst; do
  if dropped "$m"; then fail "drops ${m##*/}"; else ok "keeps ${m##*/}"; fi
done
# usb-storage, uas, mmc and the rest come from their own lines, unfiltered.
# The virtio line's filter: the disk transports, the IOMMU and the keyboard stay.
vfilter=$(printf '%s\n' "${calls[@]}" | sed -n "s/^checked -f \(.*\) virtio$/\1/p")
for m in drivers/virtio/virtio_mmio.ko.zst drivers/iommu/virtio-iommu.ko.zst drivers/virtio/virtio_input.ko.zst; do
  if [[ $k/$m =~ $vfilter ]]; then fail "the virtio filter drops ${m##*/}"; else ok "the virtio filter keeps ${m##*/}"; fi
done
for m in drivers/net/virtio_net.ko.zst drivers/gpu/drm/virtio/virtio-gpu.ko.zst sound/virtio/virtio_snd.ko.zst net/9p/9pnet_virtio.ko.zst; do
  if [[ $k/$m =~ $vfilter ]]; then ok "the virtio filter drops ${m##*/}"; else fail "the virtio filter keeps ${m##*/}"; fi
done
for want in 'checked /drivers/usb/storage/' 'checked /(drivers/mmc|tifm_)' 'module usb_storage?' 'module uas?'; do
  if printf '%s\n' "${calls[@]}" | grep -qxF -- "$want"; then ok "block still asks for: $want"; else fail "block no longer asks for: $want"; fi
done

# The boards' power and clock chips: not for an x86 kernel, for an arm64 one.
x86_calls=$(printf '%s\n' "${calls[@]}")
for dir in regulator clk; do
  if grep -q "^checked /drivers/$dir/" <<<"$x86_calls"; then fail "x86: block adds /drivers/$dir/"; else ok "x86: no /drivers/$dir/"; fi
done
calls=()
_d_kmoduledir=$kmod/arm64 build
for dir in regulator clk; do
  if printf '%s\n' "${calls[@]}" | grep -qx "checked /drivers/$dir/"; then ok "arm64: block adds /drivers/$dir/"; else fail "arm64: no /drivers/$dir/"; fi
done
# The cs42l43 codec's SPI controller and MFD core and its buses out, the rest in.
for dir in spi mfd; do
  f=$(sed -n "s|^checked -f \(.*\) /drivers/$dir/\$|\1|p" <<<"$x86_calls")
  [[ -n $f ]] || { fail "no filter on /drivers/$dir/"; continue; }
  for m in drivers/spi/spi-cs42l43.ko.zst drivers/mfd/cs42l43.ko.zst drivers/mfd/cs42l43-sdw.ko.zst drivers/mfd/cs42l43-i2c.ko.zst; do
    [[ $m == drivers/$dir/* ]] || continue
    if [[ $k/$m =~ $f ]]; then ok "drops ${m##*/}"; else fail "keeps ${m##*/}"; fi
  done
  for m in drivers/spi/spi-pxa2xx-pci.ko.zst drivers/spi/spi-intel-pci.ko.zst drivers/mfd/intel-lpss-pci.ko.zst \
    drivers/mfd/intel-lpss-acpi.ko.zst drivers/mfd/lpc_ich.ko.zst drivers/mfd/cros_ec_dev.ko.zst; do
    [[ $m == drivers/$dir/* ]] || continue
    if [[ $k/$m =~ $f ]]; then fail "drops ${m##*/}"; else ok "keeps ${m##*/}"; fi
  done
done

# The rest of the hook is mkinitcpio's own.
upstream=/usr/lib/initcpio/install/block
if [[ -r $upstream ]]; then
  # Our header (from line 3 to the first blank line) out, and each of our
  # filters (a line after a comment that starts "# Not") back to mkinitcpio's
  # line without it.
  ours=$(awk '
    NR >= 3 && !header_done { if ($0 == "") { header_done = 1; print }; next }
    /^    # Not / { ours = 1; next }
    ours && /^    #/ { next }
    ours { sub(/-f \047[^\047]*\047 /, ""); sub(/\[\[ [^]]* \]\] \|\| /, ""); ours = 0 }
    { print }' "$INSTALL/block")
  if diff <(printf '%s\n' "$ours") "$upstream" >/dev/null; then
    ok "the rest of block matches mkinitcpio's $(pacman -Q mkinitcpio 2>/dev/null | cut -d' ' -f2)"
  else
    fail "block differs from mkinitcpio's beyond the filter:"
    diff <(printf '%s\n' "$ours") "$upstream" || true
  fi
else
  echo "skip: no mkinitcpio here to compare block against"
fi

calls=()
# shellcheck source=/dev/null
source "$INSTALL/filesystems"
build
added=$(printf '%s\n' "${calls[@]}")
for m in isofs udf squashfs overlay vfat exfat ntfs3 ext4 btrfs xfs; do
  if grep -qx "module $m?" <<<"$added"; then ok "filesystems adds $m"; else fail "filesystems lacks $m"; fi
done
for m in nls_utf8 nls_iso8859-1; do
  if grep -qx "module $m?" <<<"$added"; then ok "filesystems adds $m"; else fail "filesystems lacks $m"; fi
done
if grep -q '^all /kernel/fs/nls' <<<"$added"; then fail "filesystems adds every code page"; else ok "not every code page"; fi
if grep -qE '^module (nfs|nfsv4|cifs|ceph|ocfs2|gfs2)\?' <<<"$added" || grep -q '^all /kernel/fs ' <<<"$added"; then
  fail "filesystems adds network or cluster filesystems: $added"
else
  ok "no network or cluster filesystems"
fi
if grep -q '^binary' <<<"$added"; then fail "filesystems adds mount helpers"; else ok "no mount helpers"; fi

exit "$((failures > 0))"
