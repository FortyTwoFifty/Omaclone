#!/usr/bin/env python3
"""Run a helper with a process deadline, TERM then KILL, and a stdout byte cap."""
from __future__ import annotations

import os
import signal
import subprocess
import sys

MAX_ERR = 4096


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        print("usage: run-helper.py MAX_BYTES TIMEOUT_SEC KILL_SEC -- CMD...", file=sys.stderr)
        return 2
    max_bytes = int(argv[1])
    timeout_sec = float(argv[2])
    kill_sec = float(argv[3])
    args = argv[4:]
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        return 2
    try:
        proc = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    try:
        out, err = proc.communicate(timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            proc.terminate()
        try:
            out, err = proc.communicate(timeout=kill_sec)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                proc.kill()
            out, err = proc.communicate()
            proc.wait()
            sys.stderr.buffer.write((err or b"")[:MAX_ERR])
            return 124
    rc = proc.returncode if proc.returncode is not None else 1
    if len(out) > max_bytes:
        sys.stdout.buffer.write(out[:max_bytes])
        sys.stderr.buffer.write((err or b"")[:MAX_ERR])
        return 1
    sys.stdout.buffer.write(out)
    sys.stderr.buffer.write((err or b"")[:MAX_ERR])
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
