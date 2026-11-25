#!/usr/bin/env python3
"""Run one POSIX command with a deadline and an exclusively owned process group.

Usage: run-bounded.py --seconds 900 --label native-tests -- xcodebuild ...

The command inherits stdin/stdout/stderr. JSON lifecycle records go to stderr.
On timeout or parent cancellation, the child leader is deliberately left unreaped
until every group signal has been sent. Its reserved PID prevents a later signal
from targeting an unrelated group that reused the same number. Normal completion
returns immediately with the command's shell-style exit status. Detached services
that deliberately leave the new session are outside this process group's scope.
"""

from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime, timezone
import json
import math
import os
import signal
import subprocess
import sys
import time


def duration(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("duration must be a finite nonnegative number")
    return number


def emit(label: str, phase: str, **fields: object) -> None:
    record = {
        "utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "label": label,
        "phase": phase,
        **fields,
    }
    try:
        print(json.dumps(record, sort_keys=True), file=sys.stderr, flush=True)
    except OSError:
        # A closed diagnostic stream must not bypass command cleanup.
        pass


def shell_status(returncode: int) -> int:
    return returncode if returncode >= 0 else 128 - returncode


def run(command: list[str], seconds: float, label: str, grace: float) -> int:
    received: deque[int] = deque(maxlen=8)
    previous_handlers = {}

    def remember_signal(number: int, _frame: object) -> None:
        received.append(number)

    for number in (signal.SIGTERM, signal.SIGINT):
        previous_handlers[number] = signal.signal(number, remember_signal)
    # Do not inherit SIGCHLD=SIG_IGN, which would auto-reap the leader and remove
    # the PID reservation relied on during group cleanup.
    previous_handlers[signal.SIGCHLD] = signal.signal(signal.SIGCHLD, signal.SIG_DFL)

    started = time.monotonic()
    child: subprocess.Popen[bytes] | None = None
    try:
        emit(label, "start", seconds=seconds, grace_seconds=grace)
        try:
            child = subprocess.Popen(command, start_new_session=True)
        except OSError as error:
            emit(label, "end", outcome="launch_error", error=str(error), returncode=127,
                 elapsed_seconds=round(time.monotonic() - started, 3))
            return 127

        # start_new_session makes this direct child's PID the new PGID and SID.
        group = child.pid
        if group <= 1 or group == os.getpgrp():
            # This cannot occur after a successful start_new_session. Never fall
            # back to broad PID/name matching or the caller's process group.
            child.kill()
            child.wait(timeout=5)
            emit(label, "end", outcome="invalid_owned_group", returncode=125)
            return 125
        emit(label, "spawned", pid=child.pid, pgid=group)
        deadline = started + seconds
        reason = ""
        first_signal = signal.SIGTERM
        while True:
            if received:
                reason = "cancelled"
                first_signal = received.popleft()
                break
            returncode = child.poll()
            if returncode is not None:
                status = shell_status(returncode)
                emit(label, "end", outcome="completed", child_returncode=returncode,
                     returncode=status, elapsed_seconds=round(time.monotonic() - started, 3))
                return status
            if time.monotonic() >= deadline:
                reason = "timeout"
                break
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))

        # Do not poll/wait from this point until after SIGKILL. Even a leader that
        # exits on TERM remains our unreaped child and pins the PGID against reuse.
        def send_group(number: int) -> None:
            try:
                os.killpg(group, number)
                emit(label, "signal", pgid=group, signal=signal.Signals(number).name)
            except ProcessLookupError:
                emit(label, "signal", pgid=group, signal=signal.Signals(number).name,
                     group_exists=False)
            except PermissionError as error:
                emit(label, "cleanup_error", pgid=group, error=str(error))

        emit(label, reason, pid=child.pid, pgid=group,
             elapsed_seconds=round(time.monotonic() - started, 3))
        send_group(first_signal)
        grace_deadline = time.monotonic() + grace
        while time.monotonic() < grace_deadline:
            while received:
                send_group(received.popleft())
            time.sleep(min(0.05, max(0, grace_deadline - time.monotonic())))
        send_group(signal.SIGKILL)
        cleanup_complete = True
        try:
            returncode = child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # An uninterruptible kernel wait may outlast KILL. Keep this wrapper
            # bounded, and report that reaping could not be confirmed.
            returncode = None
            cleanup_complete = False
        status = 124 if reason == "timeout" else 128 + first_signal
        emit(label, "end", outcome=reason, child_returncode=returncode, returncode=status,
             cleanup_complete=cleanup_complete,
             elapsed_seconds=round(time.monotonic() - started, 3))
        return status
    finally:
        for number, previous in previous_handlers.items():
            signal.signal(number, previous)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", required=True, type=duration)
    parser.add_argument("--label", required=True)
    parser.add_argument("--grace-seconds", type=duration, default=10.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.seconds <= 0:
        parser.error("--seconds must be greater than zero")
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    if os.name != "posix":
        parser.error("this runner requires a POSIX host (macOS or Linux)")
    return run(args.command, args.seconds, args.label, args.grace_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
