#!/usr/bin/env python3
"""Run a command, forward its stdout, and end it if it falls silent.

    ts-stall-guard.py [--silence S] [--grace G] [--log FILE] [--pidfile FILE] -- <command> [args...]

A supervisor that restarts a client only when it exits misses the client that stays up and stops
writing. This one forwards the child's stdout to its own, and when nothing arrives for S seconds
(default 10; G, default 30, before the first byte) it logs a `stall` line, sends the child SIGINT
(the CLI's clean close), then SIGKILL after 5 s, and exits 3. SIGINT or SIGTERM to the guard is
passed to the child. Otherwise it exits with the child's status. The child's stderr is the guard's.
"""

import argparse
import os
import select
import signal
import subprocess
import sys
import time


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--silence", type=float, default=10.0, help="seconds without output before ending the child")
    ap.add_argument("--grace", type=float, default=30.0, help="the same, before the first byte")
    ap.add_argument("--log", default="", help="append one line per stall here")
    ap.add_argument("--pidfile", default="", help="write the child's PID here")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not cmd:
        ap.error("no command")

    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=0)
    if args.pidfile:
        with open(args.pidfile, "w") as f:
            f.write(f"{child.pid}\n")

    def stop(_sig=None, _frame=None):
        if child.poll() is None:
            child.send_signal(signal.SIGINT)
            try:
                child.wait(5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()

    def forward(sig, frame):
        stop()
        sys.exit(128 + sig)

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    src = child.stdout.fileno()
    out = sys.stdout.buffer
    last = time.monotonic()
    total = 0
    while True:
        ready, _, _ = select.select([src], [], [], 1.0)
        if ready:
            chunk = os.read(src, 1 << 16)
            if not chunk:
                break
            out.write(chunk)
            out.flush()
            total += len(chunk)
            last = time.monotonic()
        elif time.monotonic() - last >= (args.silence if total else args.grace):
            if args.log:
                with open(args.log, "a") as f:
                    f.write(f"{utc()} stall pid={child.pid} bytes={total}\n")
            stop()
            sys.exit(3)
    sys.exit(child.wait())


if __name__ == "__main__":
    main()
