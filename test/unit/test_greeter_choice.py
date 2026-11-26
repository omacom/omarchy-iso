"""Just try is a key on the welcome screen: Return installs, Space tries.

The boot menus read keys through the firmware, which drives only keyboards
that speak the USB boot protocol: a wired Apple Magic Keyboard reached nothing
in GRUB. So the welcome, where Linux reads the keyboard, offers it, in a faded
line under Start Install. Tested by running the configurator's own greeter in
a pseudo-terminal and typing the keys' bytes.
"""

import os
import pty
import re
import select
import struct
import tempfile
import fcntl
import termios
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIGURATOR = ROOT / "configs/airootfs/root/configurator"
SHARE = ROOT / "configs/airootfs/usr/share/omarchy-iso"

DOWN, UP = b"\x1b[B", b"\x1b[A"


def function(name: str) -> str:
    return re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", CONFIGURATOR.read_text(), re.MULTILINE | re.DOTALL).group(0)


SCRIPT = f"""
source {SHARE / 'i18n.sh'}; i18n_load en
LOGO_WIDTH=10
gum() {{ echo "LOGO"; }}
ttfx() {{ sleep 30; }}
{function('measure_terminal')}
{function('greeter_choices')}
{function('greeter')}
greeter
echo "CHOICE-$greeter_choice"
"""


class GreeterChoiceTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (self.dir / "logo.txt").write_text("LOGO-LOGO-\n")
        self.layer = self.dir / "omarchy-try.sfs"

    def run_greeter(self, keys, layer=True):
        if layer:
            self.layer.touch()
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            os.environ["LOGO_PATH"] = str(self.dir / "logo.txt")
            os.environ["TRY_LAYER"] = str(self.layer)
            os.execvp("bash", ["bash", "-c", SCRIPT])
        seen = b""
        try:
            seen = self.read_until(fd, b"Start Install", seen)
            for key in keys:
                time.sleep(0.3)
                os.write(fd, key)
            seen = self.read_until(fd, b"CHOICE-", seen)
            deadline = time.monotonic() + 5
            while not re.search(rb"CHOICE-\w+\r?\n", seen) and time.monotonic() < deadline:
                seen = self.read_until(fd, b"\n", seen)
        finally:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
            os.close(fd)
        return re.search(rb"CHOICE-(\w+)", seen).group(1).decode(), seen

    def read_until(self, fd, marker, seen=b"", seconds=10):
        deadline = time.monotonic() + seconds
        while marker not in seen:
            ready, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                self.fail(f"no {marker!r} within {seconds} s; the terminal showed {seen[-300:]!r}")
            try:
                seen += os.read(fd, 4096)
            except OSError:
                break
        return seen

    def test_return_installs(self):
        choice, seen = self.run_greeter([b"\n"])
        self.assertEqual(choice, "install")
        # Start Install keeps the look it had; the Space line sits under it, fainter.
        self.assertIn(b"\x1b[2mPress Return to Start Install", seen)
        self.assertIn(b"\x1b[90mOr press Space to just try", seen)

    def test_a_raw_return_installs_too(self):
        self.assertEqual(self.run_greeter([b"\r"])[0], "install")

    def test_space_tries(self):
        self.assertEqual(self.run_greeter([b" "])[0], "try")

    def test_other_keys_choose_nothing(self):
        self.assertEqual(self.run_greeter([b"x", DOWN, UP, b"\x1b", b"\n"])[0], "install")

    def test_media_without_try_offer_only_install(self):
        choice, seen = self.run_greeter([b" ", b"\n"], layer=False)
        self.assertEqual(choice, "install")
        self.assertNotIn(b"Space", seen)


if __name__ == "__main__":
    unittest.main()
