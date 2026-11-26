"""The welcome screen is drawn again when the console changes size.

It is laid out once, for the size the console has when it is drawn, and then
waits for Return. A console that grows after that (KMS taking over late in a
VM, a VM window resized) left the logo clipped at the left edge, its
animation beside it and the tagline overwritten, while every later screen,
which measures as it draws, was centered. Tested by running the
configurator's own greeter in a pseudo-terminal and resizing it.
"""

import fcntl
import os
import pty
import re
import select
import struct
import tempfile
import termios
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIGURATOR = ROOT / "configs/airootfs/root/configurator"
SHARE = ROOT / "configs/airootfs/usr/share/omarchy-iso"


def function(name: str) -> str:
    return re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", CONFIGURATOR.read_text(), re.MULTILINE | re.DOTALL).group(0)


# The greeter with a 10-column logo, gum reporting where it was asked to pad
# to, and an animation that only waits to be killed.
SCRIPT = f"""
source {SHARE / 'i18n.sh'}; i18n_load en
LOGO_WIDTH=10
gum() {{ echo "LOGO-PADDED-$PADDING_LEFT"; }}
ttfx() {{ sleep 30; }}
{function('measure_terminal')}
{function('greeter')}
greeter
echo GREETER-DONE
"""


def set_size(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class GreeterResizeTest(unittest.TestCase):
    def read_until(self, fd: int, marker: bytes, seconds: float = 10) -> bytes:
        seen, deadline = b"", time.monotonic() + seconds
        while marker not in seen:
            ready, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                self.fail(f"no {marker!r} within {seconds} s; the terminal showed {seen[-300:]!r}")
            try:
                seen += os.read(fd, 4096)
            except OSError:
                self.fail(f"the greeter ended before {marker!r}; the terminal showed {seen[-300:]!r}")
        return seen

    def test_a_console_that_grows_is_drawn_again_and_return_still_ends_it(self):
        logo = Path(self.enterContext(tempfile.TemporaryDirectory())) / "logo.txt"
        logo.write_text("LOGO-LOGO-\n")
        pid, fd = pty.fork()
        if pid == 0:
            set_size(0, 24, 80)
            os.environ["LOGO_PATH"] = str(logo)
            os.execvp("bash", ["bash", "-c", SCRIPT])
        try:
            # 80 columns: the 10-column logo is padded to (80 - 10) / 2.
            self.read_until(fd, b"LOGO-PADDED-35")
            set_size(fd, 40, 120)
            redrawn = self.read_until(fd, b"LOGO-PADDED-55")
            self.assertIn(b"\033[2J", redrawn, "the old layout was not cleared before the new one")
            self.assertNotIn(b"GREETER-DONE", redrawn, "a resize ended the welcome screen")
            os.write(fd, b"\n")
            self.read_until(fd, b"GREETER-DONE")
        finally:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
            os.close(fd)


if __name__ == "__main__":
    unittest.main()
