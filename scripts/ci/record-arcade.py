#!/usr/bin/env python3
"""Record the real simulator during the UI test; stop only our own recorder."""
import argparse
import signal
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--simulator", required=True)
p.add_argument("--marker", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
args = p.parse_args()
stopping = False

def stop(_signum, _frame):
    global stopping
    stopping = True

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
deadline = time.monotonic() + 300
while not stopping and not args.marker.exists() and time.monotonic() < deadline:
    time.sleep(0.2)
if not stopping and args.marker.exists():
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.with_suffix(".log").open("w") as log:
        process = subprocess.Popen(["xcrun", "simctl", "io", args.simulator,
            "recordVideo", "--codec=h264", "--force", str(args.output)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 180
            while not stopping and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.2)
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=3)
