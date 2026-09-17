# ThinkPad T14s and HP EliteBook hardware port

This is a first port from [omarchy-snapdragon](https://github.com/bprendie/omarchy-snapdragon)
to the `dragon` installer. The originating project installs Omarchy 4.0.3 on
Arch Linux ARM with a repackaged Ubuntu Qualcomm kernel. It has physical
installation, encrypted unlock and desktop results on a ThinkPad T14s Gen 6
LCD (LENOVO `21N10000US`) and HP EliteBook Ultra G1q (HP board `8CBE`).
Those results do **not** validate this port with `dragon`'s `linux-aarch64`
kernel. This contribution needs an ARM image build and physical retest.

## Included in this installer change

Exact vendor/product profiles select the two laptops. Other ThinkPad SKUs,
OLED variants and other HP products are intentionally not inferred from these
two samples. Camera userspace packages enter the Snapdragon offline package
closure and are installed only for the matching laptops.

### Visible encrypted-root unlock

Both laptops originally accepted the disk password with a black LCD. The
desktop appeared after unlocking because root userspace supplied drivers
missing from the initramfs. On the ThinkPad, the successful fix included
Qualcomm platform suppliers, QFPROM/SDAM, the hardware spinlock and external
display bridges. On the HP, `gpio_sbu_mux` was also necessary: a USB-C SBU
switch in the PMIC GLINK display graph delayed display initialization even
when only the internal panel was being used.

The build-only `omarchy-qcom-x1e-lcd` hook includes these DT-probed supplier
modules. DT supplier relationships are not fully described by ordinary
module dependencies. The subsystem inclusion follows the working prototype;
it is deliberately conservative and could be narrowed after hardware testing.
The two profiles share the hook. There is no runtime hook and no change to
the existing encryption, Plymouth or snapshot hook sequence.

The installer copies the build hook with executable permissions and appends
it through a persistent mkinitcpio drop-in **before** final `limine-update`.
Later normal initramfs rebuilds read the same drop-in. The live image's
initramfs is unchanged by this patch.

Unlike the source prototype, this port does not copy a versioned Ubuntu
firmware directory into the initramfs. It uses mkinitcpio's module firmware
discovery and the existing firmware extraction pipeline. Review the actual
archive for DT-requested firmware that is not discoverable from module
metadata, especially ADSP/display firmware. A missing module in the target
kernel must be resolved as a kernel prerequisite; suppressing an error does
not establish that the display graph works.

### ThinkPad camera

The tested kernel already provided the OV02C10 sensor and CAMSS media graph.
The missing pieces were `libcamera`, `libcamera-tools`, `pipewire-libcamera`
and `gst-plugin-libcamera`, including their dependencies. Installing these
enabled direct capture and PipeWire camera access, with a usable preview
confirmed by the owner. These packages are selected by the new profiles.

The HP needs this userspace too, but also needed an OV05C10 driver and
board-specific device-tree changes in the source project. Installing these
packages alone is **not** a claim that the HP camera works on this kernel.

## Remaining fixes and their integration owners

| Hardware / feature | Source-project result | Remaining upstream work |
| --- | --- | --- |
| ThinkPad LCD unlock | Graphical unlock physically passed | Retest this hook with `linux-aarch64` and its DT/firmware |
| ThinkPad RGB camera | Direct capture, PipeWire and visible preview passed | Verify OV02C10/CAMSS support and dependencies on the selected kernel |
| ThinkPad TrackPoint | Device-specific no-scroll workaround included | Port user configuration in the Omarchy runtime; hardware button/EC behavior remains unresolved |
| ThinkPad audio, Wi-Fi, Bluetooth, brightness | Physically working on source images | Regression test with upstream kernel and OEM firmware extraction |
| ThinkPad NPU | Calculator, validator and QNN HTP workload passed | Preserve the matched Lenovo cDSP firmware pair; Qualcomm SDK/runtime is a separate test dependency |
| HP LCD unlock | Graphical unlock physically passed | Retest the shared hook, especially the SBU mux and firmware |
| HP audio | Playback and audible preview passed with a custom topology/UCM alias | Package the topology against upstream card names and firmware layout |
| HP RGB camera | OV05C10 driver, board overlay and startup service produced usable preview | Compare target kernel/DT support before porting any driver; never reuse Ubuntu-built `.ko` files |
| HP hotkeys | Model-gated Super+F3/F4 and Super+F6/F7/F8 workaround passed | Port bindings in the Omarchy runtime; native Fn delivery is unresolved |
| Charging, keyboard backlights | Remaining issues; replug can restore charging | No speculative EC writes or unvalidated reset workaround |

The source project's TrackPoint workaround is limited to the affected
ThinkPad SKU and this input device:

```lua
hl.device({
  name = "hid-over-i2c-04f3:000d-mouse",
  scroll_method = "no_scroll",
  scroll_button_lock = false,
})
```

It was appended idempotently to the user's Hyprland input configuration after
backing up the original. It sacrifices button scrolling to avoid stuck-button
scroll behavior; it does not repair physical buttons. The test unit later had
its TrackPoint cable disconnected while awaiting a keyboard replacement.
Apply this in the runtime's hardware/user provisioning layer after checking
its current configuration syntax, rather than editing home directories from
the ISO installer.

Source implementation and evidence:

- [Early display build hook](https://github.com/bprendie/omarchy-snapdragon/blob/main/profiles/t14s-lcd/initcpio/oma_snap_qcom)
- [ThinkPad unlock investigation](https://github.com/bprendie/omarchy-snapdragon/blob/main/docs/unlock-screen-investigation.md)
- [ThinkPad camera and NPU results](https://github.com/bprendie/omarchy-snapdragon/blob/main/docs/t14s-camera-backlight-npu.md)
- [Runtime patch, including TrackPoint](https://github.com/bprendie/omarchy-snapdragon/blob/main/patches/0002-quattro-arm-profile.patch)
- [HP camera implementation](https://github.com/bprendie/omarchy-snapdragon/tree/main/packages/hp-camera)
- [HP audio packaging](https://github.com/bprendie/omarchy-snapdragon/tree/main/packages/hp-audio)

These links describe source-project code, not additional files applied by
this PR. The old whole-installer patch is not suitable for direct application:
it changes boot/kernel ownership that `dragon` already implements differently.
OEM firmware licensing must be reviewed independently; this PR adds no blobs.
ASUS A14/A16 work remains a separate port with separate validation.

## Review and test loop

1. Run `./test/all`. These tests cover profile selection, camera package
   scoping, existing configuration preservation and executable hook staging.
   They do not exercise mkinitcpio against an ARM kernel.
2. Build Snapdragon media using the README's ARM build procedure. Check
   package resolution, the matching DTBs and extracted OEM firmware. Install
   on each laptop with encryption enabled and retain known-good recovery media.
3. Inspect `/etc/mkinitcpio.conf.d/80-omarchy-aarch64-platform.conf` and
   `/usr/lib/initcpio/install/omarchy-qcom-x1e-lcd`. Inspect the generated
   initramfs with `lsinitcpio` (extract the `.initrd` section first for a UKI).
   Verify modules, required firmware, keyboard and the existing unlock hooks.
4. Reboot and confirm the prompt is **visible before typing**, the password
   unlocks the disk, and the desktop loads. Save the boot journal, kernel
   release, DMI identity, package versions and initramfs listing. A QEMU boot
   can validate encryption plumbing but cannot emulate the laptop display graph.
5. Test the camera outside the browser: `cam -l`, then
   `cam -c 1 --capture=10`; check `wpctl status` for the camera. Obtain consent
   before showing or saving a preview. Browser permission failures are separate
   from sensor or frame-capture failures.
6. Run the normal Omarchy update, verify the drop-in survives, and repeat the
   visible-unlock/desktop reboot. Also check audio, wireless and brightness.

Do not infer successful snapshot rollback from successful Limine boot. The
source project has a separate manual snapshot-overlay experiment; it is not
part of this port. Secure Boot is outside this work's scope.
