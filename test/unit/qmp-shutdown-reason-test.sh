#!/bin/bash
#
# qmp-shutdown-reason.py against a fake QMP server. The install launcher needs
# the SHUTDOWN reason, not just the process exit code: a closed window and an
# installer reboot both make QEMU exit.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - <<PY &
import json, os, socket, time
path = "$fixture/qmp.sock"
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
server.settimeout(10)
conn, _ = server.accept()
conn.sendall(json.dumps({"QMP": {"version": {"qemu": {}}}}).encode() + b"\n")
line = b""
while b"\n" not in line:
    chunk = conn.recv(4096)
    if not chunk:
        raise SystemExit(1)
    line += chunk
request = json.loads(line.decode())
assert request["execute"] == "qmp_capabilities", request
conn.sendall(json.dumps({"return": {}}).encode() + b"\n")
conn.sendall(json.dumps({"event": "STOP"}).encode() + b"\n")
conn.sendall(json.dumps({"event": "SHUTDOWN", "data": {"guest": False, "reason": "host-ui"}}).encode() + b"\n")
conn.sendall(json.dumps({"event": "SHUTDOWN", "data": {"guest": True, "reason": "guest-reset"}}).encode() + b"\n")
time.sleep(0.2)
conn.close()
server.close()
PY
server_pid=$!

# Give the server a moment to bind before the client retries.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -S $fixture/qmp.sock ]] && break
  sleep 0.05
done

reason=$(python3 "$ROOT/bin/lib/qmp-shutdown-reason.py" "$fixture/qmp.sock")
wait "$server_pid"
[[ $reason == guest-reset ]] || fail "last shutdown reason was '$reason', not guest-reset"

missing=$(QMP_CONNECT_SECONDS=0.3 python3 "$ROOT/bin/lib/qmp-shutdown-reason.py" "$fixture/no-such.sock")
[[ -z $missing ]] || fail "a missing socket printed '$missing'"

echo "qmp shutdown-reason checks passed"
