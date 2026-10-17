# Qualcomm live startup

The live UKI uses its own initramfs, built by `live-uki.sh`. The direct-boot
kernel/initramfs pair is unchanged. Only the Qualcomm GRUB entry enables the
`qcom_early_startup` hook with `omarchy.qcom_early=1`.

Before loading drivers, the hook checks every ADSP firmware name in the running
device tree. It accepts the normal firmware search directories and compressed
files. If a required file is missing, or the firmware owner is unknown, it leaves
the original mount handler and automatic-load blacklist in place. The existing
Yoga-only late-start service remains available under its original RAM-copy
checks. This preserves the existing path; it does not establish board support.

When the files are present, the hook explicitly loads the firmware driver,
bypassing the automatic-load blacklist. It starts ADSP on X1/SC8280XP, or attaches
to UEFI's SOCCP on Glymur without requiring fallback firmware files. It starts
the transport and suppliers before waiting, then checks the processor state and
current udev queue before calling the final Archiso mount handler. Failed startup
stops the disk search and never falls back after a partial start. The 30-second
timeout bounds failure; it is not a fixed USB settling delay.

`early-startup-install` includes the matching kernel modules and asks
`early-firmware.py` for firmware names from the same DTBs passed to ukify.
mkinitcpio resolves available firmware with its normal updates/compression
search. Missing blobs are reported at build time; listing a DTB does not make
its board supported when its required firmware is unavailable.

This orders firmware startup before mounting the live medium. It does not
provide a kernel guarantee that no later Type-C or USB reconfiguration can
occur. A successful boot is evidence for that machine and image, not a universal
USB-readiness contract.
