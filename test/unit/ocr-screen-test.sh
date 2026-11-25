#!/bin/bash
# The harnesses read the console with tesseract. The install's last screen
# puts "Reboot Now" on a focused button, dark text on a light bar, which the
# plain negated image reads as "Reboot Nou": the harness then never sees the
# install finish and waits out its timeout.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCREEN="$ROOT/test/unit/fixtures/install-finished-screen.png"

for tool in magick tesseract; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool is not installed"
    exit 0
  fi
done

RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
screendump() { cp "$SCREEN" "$1"; }
# The integration harness retries a blank read after a Shift wake-up.
press() { :; }

for harness in bin/omarchy-iso-test test/integration.d/base-test.sh; do
  unset -f ocr_screen ocr_screen_once
  eval "$(sed -n '/^ocr_screen\(_once\)\{0,1\}() {$/,/^}$/p' "$ROOT/$harness")"
  text=$(ocr_screen)
  if ! grep -qi "Reboot Now" <<<"$text"; then
    printf '%s read the finished install as:\n%s\n' "$harness" "$text" >&2
    exit 1
  fi
done
echo "ok - both harnesses read the Reboot Now button on the finished install"

# Only the installer harness walks the wizard, whose console font draws "w"
# as a "u" with a 1-px stem. While gum's blinking cursor is off, OCR reads the
# Password step as "Passuord>", and the free-space install timed out on this
# screen in CI. Run the harness's own wait for that step, as
# drive_configurator has it.
SCREEN="$ROOT/test/unit/fixtures/installer-password-screen.png"
harness=bin/omarchy-iso-test
unset -f ocr_screen ocr_screen_once
for name in ocr_screen wait_for_screen wait_for_screen_any; do
  eval "$(sed -n "/^$name() {\$/,/^}\$/p" "$ROOT/$harness")"
done
step=$(sed -n '/^drive_configurator() {$/,/^}$/p' "$ROOT/$harness" |
  grep -m1 -E '^[[:space:]]*wait_for_screen(_any)? "Password' || true)
if [[ -z $step ]]; then
  echo "$harness no longer waits for the Password step in drive_configurator" >&2
  exit 1
fi
vm_running() { true; }
capture_console() { :; }
sleep() { :; }
if ! eval "$step"; then
  printf '%s read the Password step as:\n%s\n' "$harness" "$(ocr_screen)" >&2
  exit 1
fi
echo "ok - the installer harness sees the Password step while gum's cursor is off"
