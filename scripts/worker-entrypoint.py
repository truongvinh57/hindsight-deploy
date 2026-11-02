#!/usr/bin/env python3
"""PID 1 for the Hindsight worker: signal forwarding + credential masking.

Why this exists:
  * The upstream worker prints its database URL in cleartext at startup
    ("Database connected: postgresql://user:password@db/..."). That would put
    the Postgres superuser password into "docker compose logs". Every line of
    the worker's stdout/stderr is filtered here before it reaches the log driver.
  * Shelling out through "... | sed" would make the shell PID 1 and break the
    graceful shutdown the worker needs to hand tasks back (up to ~60s). This
    wrapper forwards SIGTERM/SIGINT to the worker and waits for it.

Usage (from docker-compose.yml):
  command: ["/app/api/.venv/bin/python", "-u", "/app/worker-entrypoint.py", "hindsight-worker"]
"""

from __future__ import annotations

import re
import signal
import subprocess
import sys
import threading

# postgresql://user:pass@host -> postgresql://***:***@host (also postgres, oracle)
_CREDENTIAL_RE = re.compile(r"((?:postgresql|postgres|oracle)(?:\+[a-z0-9]+)?://)[^\s@/]+@")


def pump(stream, sink) -> None:
    try:
        for line in iter(stream.readline, ""):
            sink.write(_CREDENTIAL_RE.sub(r"\1***:***@", line))
            sink.flush()
    finally:
        stream.close()


def main() -> None:
    cmd = sys.argv[1:] or ["hindsight-worker"]
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1
    )
    for stream, sink in ((proc.stdout, sys.stdout), (proc.stderr, sys.stderr)):
        threading.Thread(target=pump, args=(stream, sink), daemon=True).start()

    def forward(signum, _frame):
        try:
            proc.send_signal(signum)
        except ProcessLookupError:
            pass

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGQUIT):
        signal.signal(sig, forward)

    code = proc.wait()
    sys.exit(code)


if __name__ == "__main__":
    main()
