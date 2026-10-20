"""omarchy-iso-connect reads iwctl's tables the way iwd prints them."""
import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
script = (ROOT / "configs/airootfs/usr/local/bin/omarchy-iso-connect").read_text()
helpers = "\n".join(
    re.search(rf"^{name}\(\) \{{\n.*?^\}}", script, re.M | re.S).group()
    for name in ("wifi_station", "wifi_networks")
)

# iwd colours its tables; the escapes are part of what has to be parsed.
STATIONS = """\
                            Devices in Station Mode
--------------------------------------------------------------------------------
  Name                  State            Scanning
--------------------------------------------------------------------------------
  \x1b[1;90mwlan0\x1b[0m                 disconnected
"""

NETWORKS = """\
                               Available networks
--------------------------------------------------------------------------------
      Network name                      Security            Signal
--------------------------------------------------------------------------------
  \x1b[1;90m>\x1b[0m   Home Net 5G                       psk                 ****
      Cafe                              open                ***
"""


def run(call):
    stub = 'iwctl() { case "$*" in "station list") printf "%s" "$STATIONS" ;; *get-networks) printf "%s" "$NETWORKS" ;; esac; }\n'
    return subprocess.run(
        ["bash", "-c", stub + helpers + "\n" + call],
        env={**os.environ, "STATIONS": STATIONS, "NETWORKS": NETWORKS},
        check=True, capture_output=True, text=True,
    ).stdout


class IsoConnectTest(unittest.TestCase):
    def test_finds_the_station(self):
        self.assertEqual(run("wifi_station").strip(), "wlan0")

    def test_lists_network_names_with_spaces_and_without_the_marker(self):
        self.assertEqual(run("wifi_networks wlan0").splitlines(), ["Home Net 5G", "Cafe"])


if __name__ == "__main__":
    unittest.main()
