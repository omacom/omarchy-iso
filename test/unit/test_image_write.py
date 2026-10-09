"""Unit tests for how the orchestrator writes the root image to the target.

_write_root_image_frames runs omarchy-image-write and decides from its exit
status whether the image is on the target (0), whether the pipe should write it
instead because the tool refused it untouched (2), or whether the install has
failed (1). A stub stands in for the tool; image-write-test.sh tests the tool.

_write_root_image_pipe is run for real, zstdcat and dd against a temp file.
"""

import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class WriteRootImageFramesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        self.tool = self.tmp / "omarchy-image-write"
        self.calls = self.tmp / "calls"
        patcher = mock.patch.object(phases_impl, "IMAGE_WRITE", self.tool)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.logged = []
        patcher = mock.patch.object(phases_impl, "info", self.logged.append)
        patcher.start()
        self.addCleanup(patcher.stop)

    def stub(self, status, stderr=""):
        self.tool.write_text(
            "#!/bin/bash\n"
            f'printf "%s\\n" "$*" >>"{self.calls}"\n'
            f"printf '{stderr}' >&2\n"
            f"exit {status}\n"
        )
        self.tool.chmod(0o755)

    def write(self):
        return phases_impl._write_root_image_frames(Path("/medium/image.zst"), "/dev/mapper/root")

    def test_missing_tool_leaves_the_image_to_the_pipe(self):
        self.assertFalse(self.write())

    def test_success_writes_the_image_and_logs_the_tool(self):
        self.stub(0, "omarchy-image-write: wrote 4.67 of 6.37 GiB\\n")
        self.assertTrue(self.write())
        self.assertEqual(self.calls.read_text(), "write /medium/image.zst /dev/mapper/root\n")
        self.assertIn("› omarchy-image-write: wrote 4.67 of 6.37 GiB", self.logged)

    def test_refused_image_falls_back_to_the_pipe(self):
        self.stub(2, "omarchy-image-write: frame 0 at byte 0: not a framed image\\n")
        self.assertFalse(self.write())
        self.assertTrue(any("not a framed image" in line for line in self.logged))

    def test_failure_partway_is_an_error(self):
        self.stub(1, "omarchy-image-write: write at byte 4096: Input/output error\\n")
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.write()
        self.assertEqual(caught.exception.returncode, 1)
        self.assertIn("Input/output error", caught.exception.stderr)

    def test_killed_tool_is_an_error(self):
        self.stub(0)
        self.tool.write_text("#!/bin/bash\nkill -BUS $$\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.write()


class WriteRootImagePipeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        patcher = mock.patch.object(phases_impl, "info", lambda _message: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        # 5 MiB: two full 2 MiB dd blocks and a partial one, with a run of
        # zeros that conv=sparse skips.
        self.raw = os.urandom(3 << 20) + bytes(1 << 20) + os.urandom(1 << 20)
        self.image = self.tmp / "image.zst"
        subprocess.run(["zstd", "-q", "-o", str(self.image)], input=self.raw, check=True)
        self.target = self.tmp / "target"
        self.target.write_bytes(bytes(len(self.raw)))

    def test_writes_the_image(self):
        phases_impl._write_root_image_pipe(self.image, str(self.target))
        self.assertEqual(self.target.read_bytes(), self.raw)

    def test_truncated_image_is_an_error(self):
        # A shell pipeline reported dd's status alone: zstd stopping partway
        # left a short image written "successfully".
        truncated = self.tmp / "truncated.zst"
        truncated.write_bytes(self.image.read_bytes()[: self.image.stat().st_size // 2])
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            phases_impl._write_root_image_pipe(truncated, str(self.target))
        self.assertEqual(caught.exception.cmd[0], "zstdcat")

    def test_unwritable_target_is_an_error(self):
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            phases_impl._write_root_image_pipe(self.image, str(self.tmp / "no" / "such" / "target"))
        self.assertEqual(caught.exception.cmd[0], "dd")


if __name__ == "__main__":
    unittest.main()
