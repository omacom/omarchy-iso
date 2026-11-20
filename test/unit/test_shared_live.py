"""Regression tests for overlay visibility and mksquashfs's inode-based exclusions."""

import io
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
describe_layer = runpy.run_path(str(ROOT / "builder/live-layer/compare.py"))["describe_layer"]


class LiveLayerTest(unittest.TestCase):
    def test_only_identical_files_are_shared_and_absent_files_stay_hidden(self):
        with tempfile.TemporaryDirectory() as temp:
            live = Path(temp) / "live"
            base = Path(temp) / "base"
            for root in (live, base):
                root.mkdir()
                for name in ("common", "changed", "mode", "hard", "partial"):
                    (root / name).write_text("identical")
                    os.utime(root / name, (1, 1))
                os.link(root / "hard", root / "hard alias")
                (root / "link").symlink_to("common")
                os.utime(root / "link", (1, 1), follow_symlinks=False)
            (base / "changed").write_text("different")
            os.utime(base / "changed", (1, 1))
            (base / "mode").chmod(0o700)
            os.link(live / "partial", live / "only in live")
            os.link(base / "partial", base / 'only in "base"')
            excluded, masks = io.StringIO(), io.StringIO()
            with patch.dict(os.environ, SOURCE_DATE_EPOCH="1"), redirect_stdout(io.StringIO()):
                describe_layer(live, base, excluded, masks)
            self.assertEqual(set(excluded.getvalue().splitlines()), {"common", "link", "hard"})
            self.assertEqual(masks.getvalue().strip(), r'"only in \"base\"" c 0000 0 0 0 0')

            # A file newer than the image's reproducible timestamp must go
            # through mksquashfs even if its bytes match the installed copy.
            excluded = io.StringIO()
            with patch.dict(os.environ, SOURCE_DATE_EPOCH="0"), redirect_stdout(io.StringIO()):
                describe_layer(live, base, excluded, io.StringIO())
            self.assertEqual(excluded.getvalue(), "")
