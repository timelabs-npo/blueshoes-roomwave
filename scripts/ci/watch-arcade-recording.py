#!/usr/bin/env python3
"""Wait for this test run's app container, then record actual simulator output."""
import argparse
import signal
import subprocess
import sys
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--simulator", required=True)
p.add_argument("--output", type=Path, required=True)
args = p.parse_args()
started = time.time()
# Compilation and first simulator boot can exceed five minutes on a cold runner.
# The parent validation process always stops this owned watcher on exit.
deadline = time.monotonic() + 1800
stopping = False
child = None

def stop(_signum, _frame):
    global stopping
    stopping = True
    if child is not None and child.poll() is None:
        child.terminate()

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    while not stopping and time.monotonic() < deadline:
        try:
            result = subprocess.run(["xcrun", "simctl", "get_app_container", args.simulator,
                "org.timelabs.moleculefoundry", "data"], text=True, capture_output=True, timeout=15)
        except subprocess.TimeoutExpired:
            # CoreSimulator can be busy while the test app installs. The overall
            # deadline still bounds this observer; a transient probe is not fatal.
            continue
        if result.returncode == 0:
            marker = Path(result.stdout.strip()) / "Library/Caches/RoomwaveArcadeCaptures/home-dawn.json"
            if marker.is_file() and marker.stat().st_mtime >= started:
                child = subprocess.Popen([sys.executable, "scripts/ci/record-arcade.py",
                    "--simulator", args.simulator, "--marker", str(marker), "--output", str(args.output)])
                child.wait(timeout=255)
                break
        time.sleep(1)
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=12)
        except subprocess.TimeoutExpired:
            child.kill()
