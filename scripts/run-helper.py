#!/usr/bin/env python3
"""Run a helper with a process deadline, incremental pipe caps, and group reaping."""
from __future__ import annotations

import atexit
import os
import select
import signal
import subprocess
import sys
import time

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

    proc: subprocess.Popen[bytes] | None = None
    finishing = False

    def terminate_group(sig: int = signal.SIGTERM) -> None:
        if proc is None or proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, sig)
        except OSError:
            try:
                proc.send_signal(sig)
            except OSError:
                pass

    def reap(kill_after: float) -> None:
        if proc is None:
            return
        terminate_group(signal.SIGTERM)
        deadline = time.monotonic() + kill_after
        while proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        if proc.poll() is None:
            terminate_group(signal.SIGKILL)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass

    def on_signal(signum: int, _frame: object) -> None:
        nonlocal finishing
        finishing = True
        terminate_group(signum if signum != signal.SIGPIPE else signal.SIGTERM)
        if signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            reap(kill_sec)
            os._exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGPIPE):
        try:
            signal.signal(sig, on_signal)
        except OSError:
            pass

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

    atexit.register(lambda: reap(kill_sec) if proc is not None and proc.poll() is None else None)

    assert proc.stdout is not None and proc.stderr is not None
    for pipe in (proc.stdout, proc.stderr):
        os.set_blocking(pipe.fileno(), False)

    out = bytearray()
    err = bytearray()
    stdout_open = True
    stderr_open = True
    deadline = time.monotonic() + timeout_sec
    rc = 1
    try:
        while stdout_open or stderr_open:
            if finishing:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                reap(kill_sec)
                sys.stderr.buffer.write(bytes(err[:MAX_ERR]))
                return 124
            readable: list[int] = []
            if stdout_open:
                readable.append(proc.stdout.fileno())
            if stderr_open:
                readable.append(proc.stderr.fileno())
            try:
                ready, _, _ = select.select(readable, [], [], min(remaining, 0.25))
            except InterruptedError:
                continue
            if proc.stdout.fileno() in ready:
                chunk = os.read(proc.stdout.fileno(), 4096)
                if not chunk:
                    stdout_open = False
                else:
                    out.extend(chunk)
                    if len(out) > max_bytes:
                        reap(kill_sec)
                        sys.stdout.buffer.write(bytes(out[:max_bytes]))
                        sys.stderr.buffer.write(bytes(err[:MAX_ERR]))
                        return 1
            if proc.stderr.fileno() in ready:
                chunk = os.read(proc.stderr.fileno(), 4096)
                if not chunk:
                    stderr_open = False
                else:
                    err.extend(chunk)
                    if len(err) > MAX_ERR:
                        err = err[:MAX_ERR]
                        reap(kill_sec)
                        sys.stdout.buffer.write(bytes(out[:max_bytes]))
                        sys.stderr.buffer.write(bytes(err))
                        return 1
        rc = proc.wait()
    except Exception:
        reap(kill_sec)
        raise
    sys.stdout.buffer.write(bytes(out))
    sys.stderr.buffer.write(bytes(err[:MAX_ERR]))
    return rc if rc is not None else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
