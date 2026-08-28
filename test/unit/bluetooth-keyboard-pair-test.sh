#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HELPER="$ROOT/configs/airootfs/usr/local/bin/omarchy-bluetooth-keyboard-pair"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

for command in systemctl rfkill; do
  printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/$command"
  chmod +x "$TMP/bin/$command"
done

cat >"$TMP/bin/timeout" <<'SH'
#!/bin/bash
shift
exec "$@"
SH
chmod +x "$TMP/bin/timeout"

cat >"$TMP/bin/bluetoothctl" <<'SH'
#!/bin/bash
state=${BLUETOOTH_TEST_STATE:?}
case " $* " in
  *" devices "*)
    printf 'Device 11:22:33:44:55:66 Test Keyboard\n'
    ;;
  *" info 11:22:33:44:55:66 "*)
    printf 'Name: Test Keyboard\nIcon: input-keyboard\n'
    [[ -f $state/paired ]] && printf 'Paired: yes\n'
    [[ -f $state/trusted ]] && printf 'Trusted: yes\n'
    ;;
  *" pair 11:22:33:44:55:66 "*)
    touch "$state/paired"
    ;;
  *" trust 11:22:33:44:55:66 "*)
    touch "$state/trusted"
    ;;
  *" show "*)
    printf 'Controller AA:BB:CC:DD:EE:FF live-iso\n'
    ;;
esac
SH
chmod +x "$TMP/bin/bluetoothctl"

mkdir "$TMP/state"
PATH="$TMP/bin:$PATH" \
  BLUETOOTH_TEST_STATE="$TMP/state" \
  OMARCHY_BLUETOOTH_SCAN_SECONDS=5 \
  "$HELPER" "$TMP/marker.json" "$TMP/output"

jq -e '
  .controller == "AA:BB:CC:DD:EE:FF" and
  .device == "11:22:33:44:55:66" and
  .name == "Test Keyboard"
' "$TMP/marker.json" >/dev/null
[[ $(stat -c %a "$TMP/marker.json") == 600 ]]

printf 'bluetooth keyboard pairing helper: ok\n'
