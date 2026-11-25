#!/usr/bin/python

"""When a chosen keyboard layout forces the UKI to be rebuilt.

The pre-built UKI is baked at image build time, where mkinitcpio's `keymap`
hook compiles the layout named by /etc/vconsole.conf into the initramfs. The
installer writes the user's choice to the target afterwards, so a UKI that is
only copied keeps the image's layout — and the LUKS passphrase prompt runs from
that initramfs. A passphrase enrolled under AZERTY is then untypeable at a
QWERTY prompt and the owner is locked out of a fresh install (omarchy#8196).

Two failure directions, and the test pins both, because they trade off against
each other and the tempting default is wrong in one of them:

  * missing the mismatch ships the lockout;
  * reporting a mismatch that is not there costs every ordinary install a ~4 s
    UKI rebuild it does not need.

The empty-file case is the live one: images carry no /etc/vconsole.conf, so
build-root-image.sh records an empty keymap, which means "mkinitcpio fell back
to us" and not "a keymap of ''". Reading it literally would make every us
install rebuild.
"""

import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402


class PrebuiltUkiKeymapTest(unittest.TestCase):
    def target(self, *, recorded=None, chosen=None) -> Path:
        """A stand-in install target. recorded=None omits the file entirely
        (an image built before it existed); chosen=None omits vconsole.conf."""
        root = Path(tempfile.mkdtemp())
        (root / "var/lib/omarchy-iso").mkdir(parents=True)
        (root / "etc").mkdir()
        if recorded is not None:
            (root / "var/lib/omarchy-iso/prebuilt-uki.keymap").write_text(recorded)
        if chosen is not None:
            (root / "etc/vconsole.conf").write_text(
                f"KEYMAP={chosen}\nXKBLAYOUT=gb\nFONT=default8x16\n"
            )
        return root

    def stale(self, **kwargs) -> str:
        return phases_impl._prebuilt_uki_keymap_stale(self.target(**kwargs))

    # --- the fast path must stay fast ---------------------------------------

    def test_empty_record_means_us_not_a_keymap_of_empty_string(self):
        """The live case: no /etc/vconsole.conf in the image, so the recorded
        keymap is empty. A plain us install must NOT be pushed off the
        pre-built UKI by it."""
        self.assertEqual(self.stale(recorded="\n", chosen="us"), "")

    def test_matching_keymap_uses_the_prebuilt_uki(self):
        self.assertEqual(self.stale(recorded="uk\n", chosen="uk"), "")

    def test_no_keyboard_choice_uses_the_prebuilt_uki(self):
        self.assertEqual(self.stale(recorded="", chosen=None), "")

    # --- the lockout must be caught -----------------------------------------

    def test_non_us_layout_against_an_empty_record_rebuilds(self):
        """omarchy#8196 exactly: image baked us, user picked uk."""
        self.assertEqual(self.stale(recorded="\n", chosen="uk"), "uk")

    def test_non_us_layout_against_an_absent_record_rebuilds(self):
        """An image predating the recording is assumed to have baked us, so a
        different choice still rebuilds rather than silently shipping the
        lockout."""
        self.assertEqual(self.stale(recorded=None, chosen="fr"), "fr")

    def test_differing_recorded_keymap_rebuilds(self):
        self.assertEqual(self.stale(recorded="us\n", chosen="de-latin1"), "de-latin1")

    # --- parsing ------------------------------------------------------------

    def test_quoted_and_padded_keymap_is_read(self):
        root = self.target(recorded="uk\n")
        (root / "etc/vconsole.conf").write_text('  KEYMAP="uk"  \nFONT=default8x16\n')
        self.assertEqual(phases_impl._prebuilt_uki_keymap_stale(root), "")

    def test_commented_keymap_is_not_a_choice(self):
        root = self.target(recorded="\n")
        (root / "etc/vconsole.conf").write_text("#KEYMAP=fr\nFONT=default8x16\n")
        self.assertEqual(phases_impl._prebuilt_uki_keymap_stale(root), "")


if __name__ == "__main__":
    unittest.main()
