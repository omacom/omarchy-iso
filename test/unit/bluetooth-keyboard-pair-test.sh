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
    [[ ${BLUETOOTH_TEST_MODE:-} == multiple ]] && printf 'Device 22:33:44:55:66:77 Other Keyboard\n'
    ;;
  *" info 22:33:44:55:66:77 "*)
    printf 'Name: Other Keyboard\nIcon: input-keyboard\n'
    ;;
  *" info 11:22:33:44:55:66 "*)
    printf 'Name: Test Keyboard\n'
    if [[ ${BLUETOOTH_TEST_MODE:-} == mouse ]]; then
      printf 'Icon: input-mouse\nAppearance: 0x03c2\nUUID: 00001812-0000-1000-8000-00805f9b34fb\n'
    else
      printf 'Icon: input-keyboard\n'
    fi
    [[ -f $state/paired ]] && printf 'Paired: yes\n'
    [[ -f $state/trusted ]] && printf 'Trusted: yes\n'
    [[ -f $state/connected ]] && printf 'Connected: yes\n'
    ;;
  *" pair 11:22:33:44:55:66 "*)
    echo pair >>"$state/pair-calls"
    touch "$state/attempted"
    if [[ ${BLUETOOTH_TEST_MODE:-} == retry_pair && $(wc -l <"$state/pair-calls") == 1 ]]; then
      exit 1
    fi
    if [[ ${BLUETOOTH_TEST_MODE:-} == hang ]]; then
      echo $$ >"$state/pair-pid"
      exec sleep 30
    fi
    touch "$state/paired"
    ;;
  *" trust 11:22:33:44:55:66 "*)
    touch "$state/trusted"
    ;;
  *" connect 11:22:33:44:55:66 "*)
    echo connect >>"$state/connect-calls"
    if [[ ${BLUETOOTH_TEST_MODE:-} == retry_connect && $(wc -l <"$state/connect-calls") == 1 ]]; then
      exit 1
    fi
    [[ ${BLUETOOTH_TEST_MODE:-} == disconnected ]] || touch "$state/connected"
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

for mode in mouse disconnected multiple; do
  mkdir "$TMP/$mode"
  PATH="$TMP/bin:$PATH" BLUETOOTH_TEST_STATE="$TMP/$mode" BLUETOOTH_TEST_MODE="$mode" \
    OMARCHY_BLUETOOTH_SCAN_SECONDS=1 OMARCHY_BLUETOOTH_POLL_SECONDS=0.1 \
    "$HELPER" "$TMP/$mode/marker.json" "$TMP/$mode/output"
  [[ ! -e $TMP/$mode/marker.json ]]
done
[[ ! -e $TMP/mouse/attempted ]]
[[ ! -e $TMP/multiple/attempted ]]

mkdir "$TMP/hang"
PATH="$TMP/bin:$PATH" BLUETOOTH_TEST_STATE="$TMP/hang" BLUETOOTH_TEST_MODE=hang \
  OMARCHY_BLUETOOTH_SCAN_SECONDS=30 \
  "$HELPER" "$TMP/hang/marker.json" "$TMP/hang/output" &
helper_pid=$!
for ((i = 0; i < 100; i++)); do
  [[ -s $TMP/hang/pair-pid ]] && break
  sleep 0.02
done
[[ -s $TMP/hang/pair-pid ]]
kill "$helper_pid"
# A helper that ignores TERM would otherwise leave the welcome screen waiting.
for ((i = 0; i < 100; i++)); do
  kill -0 "$helper_pid" 2>/dev/null || break
  sleep 0.02
done
if kill -0 "$helper_pid" 2>/dev/null; then
  kill -KILL "$helper_pid" "$(cat "$TMP/hang/pair-pid")" 2>/dev/null || true
  echo 'pairing helper did not exit after TERM' >&2
  exit 1
fi
wait "$helper_pid"
! kill -0 "$(cat "$TMP/hang/pair-pid")" 2>/dev/null
[[ ! -e $TMP/hang/marker.json ]]
printf 'bluetooth keyboard pairing helper: success, mouse rejection, disconnected rejection, cancellation ok\n'

# The greeter must reap its animation before pairing can print a passkey.
python - "$ROOT/configs/airootfs/root/configurator" <<'PYTEST'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
greeter = source.split("greeter() {", 1)[1].split("\n}\n", 1)[0]
assert greeter.index('wait "$anim"') < greeter.index("start_bluetooth_keyboard_pairing")
assert greeter.index("stty sane") < greeter.index("start_bluetooth_keyboard_pairing")
assert greeter.index("start_bluetooth_keyboard_pairing") < greeter.index("IFS= read")
PYTEST

# Exercise the builder's capability marker with supported and older runtimes.
capability_block=$(sed -n '/^bluetooth_unlock_capability=/,/^fi$/p' "$ROOT/builder/build-iso.sh")
build_cache_dir="$TMP/build"
mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
bluetooth_unlock_helper="$TMP/runtime-helper"
eval "$capability_block"
[[ ! -e $bluetooth_unlock_capability ]]
printf '#!/bin/bash\n' >"$bluetooth_unlock_helper"
chmod +x "$bluetooth_unlock_helper"
eval "$capability_block"
[[ -f $bluetooth_unlock_capability ]]
rm "$bluetooth_unlock_helper"
eval "$capability_block"
[[ ! -e $bluetooth_unlock_capability ]]

# Run independent retry cases together; each must cross the real 10-second cooldown.
retry_pids=()
for mode in retry_pair retry_connect; do
  mkdir "$TMP/$mode"
  PATH="$TMP/bin:$PATH" BLUETOOTH_TEST_STATE="$TMP/$mode" BLUETOOTH_TEST_MODE="$mode" \
    OMARCHY_BLUETOOTH_SCAN_SECONDS=15 OMARCHY_BLUETOOTH_POLL_SECONDS=0.1 \
    "$HELPER" "$TMP/$mode/marker.json" "$TMP/$mode/output" &
  retry_pids+=("$!")
done
for pid in "${retry_pids[@]}"; do
  wait "$pid"
done
for mode in retry_pair retry_connect; do
  jq -e '.controller == "AA:BB:CC:DD:EE:FF" and .device == "11:22:33:44:55:66"' \
    "$TMP/$mode/marker.json" >/dev/null
  [[ -f $TMP/$mode/connected ]]
done
[[ $(wc -l <"$TMP/retry_pair/pair-calls") == 2 ]]
[[ $(wc -l <"$TMP/retry_pair/connect-calls") == 1 ]]
[[ $(wc -l <"$TMP/retry_connect/pair-calls") == 1 ]]
[[ $(wc -l <"$TMP/retry_connect/connect-calls") == 2 ]]
printf 'bluetooth keyboard pairing helper: retry pairing, preserve bond on connection retry, multiple candidate refusal ok\n'

# Without runtime support, require acknowledgement of the post-reboot keyboard.
offer_function=$(sed -n '/^offer_bluetooth_disk_unlock() {/,/^}$/p' "$ROOT/configs/airootfs/root/configurator")
offer_function=${offer_function//\/usr\/share\/omarchy-iso\/bluetooth-unlock-supported/$TMP/unsupported-runtime}
(
  eval "$offer_function"
  encrypt_installation=true
  defer_provisioning=false
  BLUETOOTH_KEYBOARD_MARKER="$TMP/marker.json"
  BLUETOOTH_UNLOCK_MARKER="$TMP/consent.json"
  clear_logo() { :; }
  say() { printf '%s\n' "$*" >>"$TMP/warning"; }
  gum() { echo "$*" >>"$TMP/confirmation"; return "${confirmation_result:-0}"; }
  abort() { exit 17; }
  offer_bluetooth_disk_unlock
  [[ ! -e $BLUETOOTH_UNLOCK_MARKER ]]
  grep -q 'wired or 2.4 GHz' "$TMP/warning"
  grep -q 'I have another keyboard' "$TMP/confirmation"
  confirmation_result=1
  if (offer_bluetooth_disk_unlock); then
    echo 'missing-runtime fallback did not abort after rejection' >&2
    exit 1
  else
    [[ $? == 17 ]]
  fi
)
