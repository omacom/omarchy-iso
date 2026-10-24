"""Exercise the live Wi-Fi helper and failure menu in a real pseudo-terminal."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "configs/airootfs/usr/local/bin"


class LiveWifiTest(unittest.TestCase):
  def setUp(self):
    self.temp = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp.cleanup)
    self.work = Path(self.temp.name)
    self.stubs = self.work / "bin"
    self.stubs.mkdir()
    self.env = {
      **os.environ,
      "PATH": f"{self.stubs}:{os.environ['PATH']}",
      "CASE_DIR": str(self.work),
      "TERM": "xterm",
      "OMARCHY_PATH": str(self.work),
      "OMARCHY_DASHBOARD_TTY": "/dev/tty",
      "OMARCHY_UI_INTERACTIVE": "yes",
      "OMARCHY_UI_FAILURE_ACTION": "",
      "WIFI_AVAILABLE": "1",
      "WIFI_START_STATUS": "0",
      "PICKER_STATUS": "0",
      "CONNECTS": "1",
      "CONFIRM_STATUS": "0",
      "UPLOAD_STATUS": "0",
    }
    self.stub("nmcli", '''
if [[ $* == "radio wifi on" ]]; then
  echo 'nmcli radio wifi on' >>"$CASE_DIR/calls"
elif [[ $WIFI_AVAILABLE == "1" ]]; then
  echo wifi
else
  echo ethernet
fi
''')
    self.stub("systemctl", '''
printf 'systemctl %s\n' "$*" >>"$CASE_DIR/calls"
exit "$WIFI_START_STATUS"
''')
    self.stub("nmtui-connect", '''
[[ -t 0 && -t 1 && -t 2 ]] || exit 99
printf 'nmtui-connect%s\n' "$*" >>"$CASE_DIR/calls"
if [[ $CONNECTS == "1" && $PICKER_STATUS == "0" ]]; then
  touch "$CASE_DIR/online"
fi
exit "$PICKER_STATUS"
''')
    self.stub("curl", '''
printf 'curl %s\n' "$*" >>"$CASE_DIR/calls"
[[ -f $CASE_DIR/online ]]
''')
    self.stub("omarchy-upload-log", '''
printf 'upload %s\n' "$*" >>"$CASE_DIR/calls"
echo 'Share this URL: https://logs.example.test/test'
exit "$UPLOAD_STATUS"
''')
    self.stub("omarchy-install-diagnose-media", "exit 1")
    self.stub("gum", '''
[[ -t 0 && -t 2 ]] || exit 99
case "$1" in
  choose)
    printf '%s\n' "$@" >>"$CASE_DIR/menu"
    choice="Drop to shell"
    if [[ -s $CASE_DIR/choices ]]; then
      IFS= read -r choice <"$CASE_DIR/choices"
      sed -i '1d' "$CASE_DIR/choices"
    fi
    printf '%s\n' "$choice"
    ;;
  confirm)
    echo confirm >>"$CASE_DIR/calls"
    exit "$CONFIRM_STATUS"
    ;;
  *) exit 99 ;;
esac
''')
    (self.stubs / "omarchy-iso-wifi").symlink_to(BIN / "omarchy-iso-wifi")

  def stub(self, name, body):
    path = self.stubs / name
    path.write_text(f"#!/bin/bash\n{body}\n")
    path.chmod(0o755)

  def calls(self):
    path = self.work / "calls"
    return path.read_text() if path.exists() else ""

  def run_tty(self, command):
    result = subprocess.run(
      ["script", "-qefc", "stty rows 40 cols 120; " + shlex.join(command), "/dev/null"],
      input="\n" * 20, text=True, capture_output=True, env=self.env, timeout=20,
    )
    self.assertNotEqual(result.returncode, 99, result.stdout + result.stderr)
    return result

  def dashboard(self, *choices):
    (self.work / "choices").write_text("\n".join((*choices, "Drop to shell")) + "\n")
    result = self.run_tty([
      str(BIN / "omarchy-install-dashboard"), str(self.work / "install.log"),
      str(self.work / "state.json"), "--", "bash", "-c", "exit 42",
    ])
    self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
    return result.stdout

  def test_wifi_enables_radio_and_opens_picker_on_tty(self):
    result = self.run_tty([str(BIN / "omarchy-iso-wifi")])
    self.assertEqual(result.returncode, 0, result.stdout)
    self.assertEqual(self.calls().splitlines(), [
      "systemctl --no-ask-password start NetworkManager", "nmcli radio wifi on", "nmtui-connect",
    ])

  def test_picker_error_restores_terminal_settings(self):
    self.stub("nmtui-connect", "stty raw -echo; exit 1")
    result = self.run_tty(["bash", "-c", '''
before=$(stty -g)
omarchy-iso-wifi
status=$?
[[ $(stty -g) == "$before" && $status == "1" ]]
'''])
    self.assertEqual(result.returncode, 0, result.stdout)

  def test_missing_adapter_explains_alternatives(self):
    self.env["WIFI_AVAILABLE"] = "0"
    result = self.run_tty([str(BIN / "omarchy-iso-wifi")])
    self.assertEqual(result.returncode, 1)
    self.assertIn("No Wi-Fi adapter", result.stdout)
    self.assertIn("USB phone tethering", result.stdout)
    self.assertEqual(self.calls(), "systemctl --no-ask-password start NetworkManager\n")

  def test_networkmanager_failure_does_not_launch_picker(self):
    self.env["WIFI_START_STATUS"] = "1"
    result = self.run_tty([str(BIN / "omarchy-iso-wifi")])
    self.assertEqual(result.returncode, 1)
    self.assertIn("Could not start networking", result.stdout)
    self.assertNotIn("nmtui-connect", self.calls())

  def test_failure_menu_connects_then_returns_without_uploading(self):
    self.dashboard("Connect to Wi-Fi")
    self.assertIn("Connect to Wi-Fi", (self.work / "menu").read_text())
    self.assertIn("nmtui-connect", self.calls())
    self.assertNotIn("upload", self.calls())

  def test_online_upload_does_not_open_wifi(self):
    (self.work / "online").touch()
    output = self.dashboard("Upload log for support")
    self.assertIn("https://logs.example.test/test", output)
    self.assertIn("upload install", self.calls())
    self.assertNotIn("nmtui-connect", self.calls())
    self.assertNotIn("confirm", self.calls())
    self.assertIn("--connect-timeout 5 --max-time 10", self.calls())

  def test_offline_upload_connects_and_uploads(self):
    output = self.dashboard("Upload log for support")
    self.assertIn("Cannot reach logs.omarchy.org", output)
    calls = self.calls().splitlines()
    self.assertIn("confirm", calls)
    self.assertLess(calls.index("nmtui-connect"), calls.index("upload install"))
    self.assertEqual(sum(line.startswith("curl ") for line in calls), 2)

  def test_declining_connection_returns_without_uploading(self):
    self.env["CONFIRM_STATUS"] = "1"
    self.dashboard("Upload log for support")
    self.assertNotIn("nmtui-connect", self.calls())
    self.assertNotIn("upload", self.calls())

  def test_leaving_picker_disconnected_does_not_upload(self):
    self.env["CONNECTS"] = "0"
    output = self.dashboard("Upload log for support")
    self.assertIn("Still unable to reach logs.omarchy.org", output)
    self.assertNotIn("upload", self.calls())

  def test_picker_failure_returns_to_menu(self):
    self.env["PICKER_STATUS"] = "1"
    self.dashboard("Upload log for support")
    self.assertIn("nmtui-connect", self.calls())
    self.assertNotIn("upload", self.calls())

  def test_no_adapter_during_upload_returns_to_menu(self):
    self.env["WIFI_AVAILABLE"] = "0"
    output = self.dashboard("Upload log for support")
    self.assertIn("No Wi-Fi adapter", output)
    self.assertNotIn("upload", self.calls())

  def test_upload_error_returns_to_menu(self):
    (self.work / "online").touch()
    self.env["UPLOAD_STATUS"] = "1"
    output = self.dashboard("Upload log for support")
    self.assertIn("Log upload failed", output)

  def test_unattended_failure_never_prompts_or_changes_network(self):
    self.env["OMARCHY_UI_INTERACTIVE"] = "no"
    self.dashboard()
    self.assertEqual(self.calls(), "")
    self.assertFalse((self.work / "menu").exists())


if __name__ == "__main__":
  unittest.main()
