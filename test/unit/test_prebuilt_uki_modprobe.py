#!/usr/bin/python

"""When a driver blacklist forces the UKI to be rebuilt.

The pre-built UKI is built without autodetect, so its initramfs carries every
driver, and udev binds them by modalias before switch-root. The modconf hook
copies modprobe.d into it at image build. A blacklist that arrives later with a
hardware script's package is in the installed system but not in that
initramfs: on a 2011-2012 MacBook Pro, fix-bcm43xx.sh installs broadcom-wl-dkms,
whose blacklist for bcma never reaches a copied UKI. bcma then claims the
BCM4331 in the initrd and wl has no device, so Wi-Fi never comes up.

Both directions matter:

  * missing the new blacklist ships a machine without Wi-Fi;
  * counting options lines would rebuild on nearly every install, because
    fix-fkeys.sh writes options hid_apple fnmode=2 everywhere.
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

BROADCOM_WL = """\
blacklist b43
blacklist b43legacy
blacklist bcm43xx
blacklist bcma
blacklist brcm80211
blacklist brcmfmac
blacklist brcmsmac
blacklist ssb
"""


class PrebuiltUkiModprobeTest(unittest.TestCase):
    def target(self, *, recorded=None, etc=None, usr=None) -> Path:
        """A stand-in install target. recorded=None omits the record (an image
        built before it existed); etc and usr map file names to contents."""
        root = Path(tempfile.mkdtemp())
        (root / "var/lib/omarchy-iso").mkdir(parents=True)
        for directory, files in (("etc/modprobe.d", etc), ("usr/lib/modprobe.d", usr)):
            (root / directory).mkdir(parents=True)
            for name, text in (files or {}).items():
                (root / directory / name).write_text(text)
        if recorded is not None:
            (root / "var/lib/omarchy-iso/prebuilt-uki.modprobe").write_text(recorded)
        return root

    def missing(self, **kwargs) -> list[str]:
        return phases_impl._prebuilt_uki_missing_blacklists(self.target(**kwargs))

    # --- the fast path must stay fast ---------------------------------------

    def test_an_ordinary_install_uses_the_prebuilt_uki(self):
        """What every install has: the image's own options files and the
        hid_apple option fix-fkeys.sh writes. No blacklist, no rebuild."""
        self.assertEqual(
            self.missing(
                recorded="",
                etc={
                    "omarchy-usb-autosuspend.conf": "options usbcore autosuspend=-1\n",
                    "hid_apple.conf": "options hid_apple fnmode=2\n",
                },
                usr={"systemd.conf": "options bonding max_bonds=0\noptions dummy numdummies=0\n"},
            ),
            [],
        )

    def test_a_blacklist_already_in_the_image_uses_the_prebuilt_uki(self):
        self.assertEqual(
            self.missing(recorded="blacklist pcspkr\n", etc={"nobeep.conf": "blacklist  pcspkr\n"}),
            [],
        )

    def test_files_other_than_conf_are_ignored(self):
        """modconf only copies *.conf; usr/lib/modprobe.d ships a README."""
        self.assertEqual(self.missing(recorded="", usr={"README": "blacklist nothing\n"}), [])

    # --- the missing blacklist must be caught --------------------------------

    def test_broadcom_wl_blacklist_rebuilds(self):
        """The 2011 MacBook Pro: broadcom-wl-dkms adds its blacklist after the
        image's UKI was built."""
        missing = self.missing(recorded="", usr={"broadcom-wl-dkms.conf": BROADCOM_WL})
        self.assertIn("blacklist bcma", missing)
        self.assertIn("blacklist b43", missing)

    def test_install_override_rebuilds(self):
        """install <module> /bin/false keeps a driver off as surely as a
        blacklist, and modprobe honours it for alias loads too."""
        self.assertEqual(
            self.missing(recorded="", etc={"nouveau.conf": "install nouveau /bin/false\n"}),
            ["install nouveau /bin/false"],
        )

    def test_an_image_without_the_record_rebuilds_on_any_blacklist(self):
        self.assertEqual(
            self.missing(recorded=None, etc={"x.conf": "blacklist bcma\n"}),
            ["blacklist bcma"],
        )


if __name__ == "__main__":
    unittest.main()
