#!/usr/bin/env python3
"""Print the reason from QEMU's QMP SHUTDOWN event.

QEMU is the server (`-qmp unix:PATH,server=on,wait=off`). This connects, completes
the capabilities handshake, and prints the last shutdown reason
(`guest-reset`, `host-ui`, `guest-shutdown`, ...). Prints nothing when the
socket never appears or the guest never shuts down.
"""

import json
import os
import socket
import sys
import time


def read_message(stream):
    line = stream.readline()
    if not line:
        return None
    return json.loads(line)


def connect(path):
    try:
        wait = float(os.environ.get("QMP_CONNECT_SECONDS", "30"))
    except ValueError:
        wait = 30
    deadline = time.monotonic() + wait
    while True:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            return sock
        except (FileNotFoundError, ConnectionRefusedError, OSError):
            sock.close()
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.1)


def shutdown_reason(path):
    sock = connect(path)
    if sock is None:
        return ""
    stream = sock.makefile("rw", encoding="utf-8")
    try:
        if read_message(stream) is None:
            return ""
        stream.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
        stream.flush()
        reason = ""
        while True:
            message = read_message(stream)
            if message is None:
                return reason
            if message.get("event") == "SHUTDOWN":
                reason = message.get("data", {}).get("reason") or ""
    finally:
        stream.close()
        sock.close()


def main():
    if len(sys.argv) != 2:
        print("usage: qmp-shutdown-reason.py SOCKET", file=sys.stderr)
        return 2
    print(shutdown_reason(sys.argv[1]), end="")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (json.JSONDecodeError, OSError, TimeoutError):
        sys.exit(0)
