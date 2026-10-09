#!/bin/bash
#
# The chosen keyboard layout and locale must survive the install — the layout
# all the way into the initramfs the LUKS passphrase prompt types with.
#
# Either can be lost without another scenario noticing, because the others ask
# for the defaults (us / en_US.UTF-8), where a dropped choice is
# indistinguishable from a kept one:
#
#   * The pre-built UKI is made at image build time, when mkinitcpio's `keymap`
#     hook compiles whatever /etc/vconsole.conf names: nothing, so us. The
#     installer writes the user's choice to the target afterwards, which cannot
#     reach a UKI that is only copied: on a UK install the target had KEYMAP=uk
#     while the UKI initramfs had us.map.gz and no vconsole.conf. A passphrase
#     enrolled under a non-US layout is then untypeable at the prompt, locking
#     the owner out of a fresh install with no recovery but reinstalling
#     (upstream omarchy#8196). Such an install builds its own UKI.
#
#   * build-root-image.sh pre-uncomments en_US.UTF-8 in locale.gen to skip
#     0.77 s of locale-gen, but archinstall's set_locale only matches
#     *commented* entries, so it returns False without writing locale.conf.
#     Unless the installer writes it, the install is left on systemd's
#     LANG=C.UTF-8 fallback.
#
# The keymap half only asserts something when OMARCHY_INTEGRATION_KB_LAYOUT is
# not us; with us the scenario logs that the assertion proves nothing.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

# The UKI's embedded initramfs, listed the way the firmware would see it.
#
# lsinitcpio, not objcopy | cpio. An initramfs is an uncompressed early cpio
# (microcode) concatenated with the compressed main image, and plain cpio stops
# at the first trailer: on a locally rebuilt UKI that lists ~500 microcode
# entries, no /init, and no keymaps, indistinguishable from a UKI that genuinely
# has none. It reads the pre-built UKI in full only because that one is
# uncompressed throughout. lsinitcpio understands both segments and the
# compression, and mkinitcpio ships it, so the guest always has it.
uki_initramfs_manifest() {
  ssh_sudo 'uki=$(ls /boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi 2>/dev/null | head -1); \
    [ -n "$uki" ] || exit 1; \
    lsinitcpio -l "$uki" 2>/dev/null | grep -E "keymap\.bin|share/kbd/keymaps/.*\.map|etc/vconsole\.conf"'
}

# The KEYMAP= the initramfs's own bundled vconsole.conf names.
#
# The two hook sets store the keymap differently, and a check that knows only
# one reports a false failure against the other:
#
#   busybox (omarchy_hooks.conf: keymap, consolefont) compiles it to
#     /keymap.bin, and the runtime hook does `loadkmap < /keymap.bin`;
#   systemd (sd-vconsole) ships usr/share/kbd/keymaps/**/<layout>.map.gz.
#
# keymap.bin does not carry its layout's name, so asserting on the manifest
# alone cannot tell uk from us. But the keymap hook compiles from exactly the
# vconsole.conf it bundles, so "a keymap is present" plus "the bundled
# vconsole.conf names the chosen layout" pins it for both hook sets without
# decoding kbd's binary format here.
# lsinitcpio -x extracts to the current directory and has no -d; --cpio limits
# it to the main image, skipping the microcode early cpio.
initramfs_bundled_keymap() {
  ssh_sudo 'uki=$(ls /boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi 2>/dev/null | head -1); \
    [ -n "$uki" ] || exit 1; \
    d=$(mktemp -d); trap "rm -rf $d" EXIT; \
    ( cd "$d" && lsinitcpio -x --cpio "$uki" ) >/dev/null 2>&1 || exit 1; \
    . "$d/etc/vconsole.conf" 2>/dev/null; printf "%s" "${KEYMAP:-}"'
}

# A manifest that lists no /init is a truncated read, not a broken initramfs.
# Without this an extraction bug reads as a clean pass on the locale half and a
# confident (wrong) failure on the keymap half.
uki_manifest_is_complete() {
  ssh_sudo 'uki=$(ls /boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi 2>/dev/null | head -1); \
    [ -n "$uki" ] && lsinitcpio -l "$uki" 2>/dev/null | grep -qx "init"'
}

verify_keymap_and_locale() {
  log "Booting the installed base image to check keymap and locale survival"
  start_vm_from_base
  wait_for_ssh "$BOOT_TIMEOUT"

  # --- the installed target -------------------------------------------------
  check "/etc/vconsole.conf records the chosen keymap ($KB_LAYOUT)" \
    ssh_guest ". /etc/vconsole.conf && [ \"\$KEYMAP\" = $(printf %q "$KB_LAYOUT") ]"

  # An exact value, not "non-empty": C.UTF-8 is the bug this scenario exists
  # for and would pass a laxer check.
  #
  # The expected value comes from OMARCHY_INTEGRATION_LOCALE. Every install
  # gets en_US.UTF-8 today, because the installer picks a keyboard layout and
  # nothing else; an install that legitimately gets another locale sets the
  # variable.
  local expect_locale="${OMARCHY_INTEGRATION_LOCALE:-en_US.UTF-8}"
  check "/etc/locale.conf is LANG=$expect_locale, not systemd's C.UTF-8 fallback" \
    ssh_guest ". /etc/locale.conf && [ \"\${LANG//\\\"/}\" = $(printf %q "$expect_locale") ]"

  # locale.conf naming a locale that was never generated is the other half of
  # the same bug, so check the archive too. locale -a spells it without the
  # dash (en_US.utf8).
  check "$expect_locale is actually compiled into the locale archive" \
    ssh_guest "locale -a 2>/dev/null | grep -qix $(printf %q "${expect_locale/UTF-8/utf8}")"

  # --- the initramfs the LUKS prompt runs from ------------------------------
  local manifest
  manifest=$(uki_initramfs_manifest) || manifest=""
  log "UKI initramfs keymap payload: ${manifest//$'\n'/ }"

  # Before trusting anything read out of the initramfs, prove the read itself
  # reached the main image.
  check "the UKI's initramfs reads completely (contains /init)" uki_manifest_is_complete

  if [[ $KB_LAYOUT == us ]]; then
    # Not a pass: with the default layout this scenario cannot tell a kept
    # choice from a dropped one.
    log "NOTE: KB_LAYOUT is us — the keymap assertion is a tautology here."
    log "      Run with OMARCHY_INTEGRATION_KB_LAYOUT=uk for the real check."
  else
    # Both halves, because either alone passes on a broken build: a keymap with
    # no vconsole.conf is the image's us default (us.map.gz and nothing else),
    # and a vconsole.conf with no keymap is an initramfs that knows the layout
    # and has nothing to load it with.
    manifest_has_a_keymap() {
      grep -qE "keymap\.bin|/${KB_LAYOUT}\.map" <<<"$manifest"
    }
    check "the UKI initramfs carries a compiled keymap" manifest_has_a_keymap
    check "the UKI initramfs's bundled vconsole.conf names $KB_LAYOUT, so the LUKS prompt uses it" \
      test "$(initramfs_bundled_keymap)" = "$KB_LAYOUT"
  fi

  capture_console "success-keymap-locale"
  stop_vm
}

verify_keymap_and_locale
finish
