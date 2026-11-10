# Qualcomm live startup

The live UKI uses its own initramfs, built by `live-uki.sh`. The direct-boot
kernel/initramfs pair is unchanged. Only the Qualcomm GRUB entry enables the
`qcom_early_startup` hook with `omarchy.qcom_early=1`.

Before loading drivers, the hook checks every ADSP firmware name in the running
device tree. It accepts the normal firmware search directories and compressed
files. The initramfs carries only linux-firmware's blobs: the OEM packages'
ADSP files are over 300 MiB, too big for a UKI that GRUB must place in memory.
`build-iso.sh` puts them on the medium under `arch/<arch>/qcom-firmware` with a
`SHA256SUMS` list. `stage-medium-firmware.sh` picks them from the device trees
the UKI embeds: each ADSP owner's required names, whatever they are called.
A required file shipped as a symlink fails the build. A file missing from the initramfs is copied from there: the
hook triggers coldplug (the firmware driver stays blacklisted), mounts the
medium read-only, copies and checks only the names its device tree requests,
and unmounts before any driver loads. Without its ADSP a laptop reports no
USB-C plug orientation, so a stick plugged in one way round runs at USB 2.
If a required file is still missing, or the firmware owner is unknown, it leaves
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

## USB-C on the live ISO

USB-C needs Type-C notifications: they tell the combo PHY which way the plug is in, power and configure retimers, and give dual-role controllers their role. On X1/SC8280XP they come from the ADSP, through `pmic_glink`'s UCSI and altmode clients; on Glymur they come from the SOCCP. (The Matebook E Go is the exception: its USB-C ports belong to its embedded controller.) The hook decides whether they reach the live system:

- **Glymur:** the hook attaches to the SOCCP that UEFI already runs, without firmware files, so every Glymur board gets notifications.
- **Early start:** an X1/SC8280XP board gets them when every file its ADSP node names in `firmware-name` is in the live UKI's initramfs; the hook then starts the ADSP before the disk search. That initramfs carries linux-firmware's ADSP images (the live root itself drops its qcom firmware) but none of the per-laptop firmware packages, so today that is the ThinkPad X13s and T14s Gen 6, the XPS 13 9345, the Yoga Slim 7x (X1E), and Qualcomm's X1 CRDs, X1E QCP and Hamoa IoT EVK. The build log names each missing file as `Qualcomm device-tree firmware unavailable`.
- **Legacy path:** every other X1/SC8280XP board leaves the DSP driver blacklisted, so no notification comes for the whole live session.

On the legacy path, what a USB-C device gets follows from the board's tree:

- **Controllers:** every X1/SC8280XP laptop tree sets `dr_mode = "host"` on its USB-C controllers, so devices enumerate without a notification. A controller with `usb-role-switch` instead, like the X1E devkit's first USB-C port, starts in device mode and enumerates nothing.
- **No retimer:** nothing tells the PHY the orientation, so it keeps its default, and a USB 3 device runs at SuperSpeed in one plug orientation and at USB 2 in the other.
- **PS8830 retimers** (`parade,ps8830` nodes, and `parade,ps8833` nodes, which list it as their fallback): since kernel 7.2 (commit b38fa168a848), `ps883x` powers the retimer off at probe until a notification, so every device on those ports, the boot stick included, runs at USB 2 in both orientations; only the USB 2 pins bypass the retimer. The Zenbook A14 (UX3407QA, UX3407RA) is one such board.

The board's tree shows which kind it is: count its retimers and GPIO SBU muxes in the tree the machine booted, as below, or in any tree under `/boot/dtbs/linux-omarchy/qcom/` (both readable by root only). A few HP trees have a retimer on one port and a GPIO SBU mux on the other.

```bash
sudo grep -ao -e parade,ps8830 -e gpio-sbu-mux /sys/firmware/fdt | sort | uniq -c
```

The live entry boots with `copytoram=n`: the live root pages in from the stick and the installer streams the root image from it, so a stick at USB 2 slows the whole session and the install. A USB-A port is not a Type-C port, so booting from one, on a laptop that has it, avoids all of this.

Where notifications run (Glymur and the early start), the live initramfs needs a driver for every switch a USB-C connector reaches, because UCSI's port registration and `pmic_glink_altmode` wait for all of them. That is why omarchy-iso#410 added `gpio-sbu-mux` beside `ps883x` in `builder/archiso-aarch64-mkinitcpio.sh`: on a board whose SBU lines go through GPIO muxes (`gpio-sbu-mux` nodes), UCSI otherwise retries for 10 s, resetting the port controller each time, and gives up for that boot if the driver hasn't bound by then. A new kind of mux needs its driver there too.

For a "slow" or "not seen" report, ask which port and plug orientation, and for the output below. On a board without retimers, flipping the plug over is the quick workaround.

```bash
tr -d '\0' </proc/device-tree/model; echo     # which board's tree the UKI picked
journalctl -k -b | grep qcom-startup          # "keeping legacy startup: missing …" or "firmware started: …"
lsusb -t                                      # 5000M or faster is SuperSpeed, 480M is USB 2
ls /sys/class/typec                           # empty until notifications register the ports
```
