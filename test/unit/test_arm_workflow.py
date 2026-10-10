import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/aarch64-build.yml"


class ArmWorkflowTest(unittest.TestCase):
    def test_published_channels_invoke_the_iso_builder_without_a_local_repo(self):
        workflow = WORKFLOW.read_text()
        step = re.search(r"        id: build\n        run: \|\n(.*?)(?=\n      - name:)", workflow, re.S).group(1)
        script = textwrap.dedent(step)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            launcher = root / "bin/omarchy-iso-make"
            launcher.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARG_LOG"\n')
            launcher.chmod(0o755)
            log = root / "args"
            for channel, flag in (("edge", "--edge"), ("rc", "--rc"), ("stable", None)):
                for target in ("aarch64/snapdragon", "aarch64/generic"):
                    with self.subTest(channel=channel, target=target):
                        env = dict(os.environ, PACKAGE_CHANNEL=channel, MEDIA_TARGET=target, ARG_LOG=str(log))
                        result = subprocess.run(["bash", "-eo", "pipefail", "-c", script], cwd=root, env=env, text=True, capture_output=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        expected = ["--keep-pkg-cache", "--no-boot-offer"]
                        if flag:
                            expected.append(flag)
                        self.assertEqual(log.read_text().splitlines(), expected + ["--arch", "aarch64", "--media-target", target])
            log.unlink()
            env["PACKAGE_CHANNEL"] = "unknown"
            result = subprocess.run(["bash", "-eo", "pipefail", "-c", script], cwd=root, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(log.exists())

    def test_no_separate_package_build_or_unsigned_artifact_repository(self):
        workflow = WORKFLOW.read_text()
        for old_input in ("pkgs_ref", "iso_make_args", "needs: packages", "build-aarch64.yml", "download-artifact", "--local-repo"):
            self.assertNotIn(old_input, workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("contents: read", workflow)
