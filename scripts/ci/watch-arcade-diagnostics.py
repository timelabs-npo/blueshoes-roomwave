#!/usr/bin/env python3
"""Observe only this run's Roomwave evidence launch; never control the app.

Stale trace timestamps are observations, not a diagnosis of an app hang.
macOS supplies xcrun, ps and sample. Only subprocesses created here are stopped.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid

BUNDLE = "org.timelabs.moleculefoundry"
TRACE = Path("Library/Caches/RoomwaveArcadeCaptures/diagnostics.json")
TOLERANCE = 3.0


def utc():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def timestamp(value):
    if not isinstance(value, str) or len(value) > 64:
        raise ValueError("timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset().total_seconds() != 0:
        raise ValueError("UTC required")
    return parsed.timestamp()


def safe_text(value, limit=128):
    if not isinstance(value, str) or not value or len(value) > limit:
        raise ValueError("text")
    if not re.fullmatch(r"[A-Za-z0-9 ._:/+-]+", value):
        raise ValueError("unsafe text")
    return value


def read_trace(path, watcher_started, now):
    try:
        with path.open("rb") as stream:
            payload = stream.read(65537)
        if len(payload) > 65536:
            return None
        trace = json.loads(payload)
        if not isinstance(trace, dict):
            return None
        if type(trace.get("schema_version")) is not int or trace["schema_version"] != 1:
            return None
        if trace.get("bundle") != BUNDLE:
            return None
        if trace.get("version") != "0.3.0" or trace.get("build") != "1":
            return None
        if type(trace.get("pid")) is not int or not 1 < trace["pid"] < 2**31:
            return None
        if type(trace.get("tick")) is not int or trace["tick"] < 0:
            return None
        for key in ("is_loading", "is_active"):
            if type(trace.get(key)) is not bool:
                return None
        for key in ("version", "build", "launch_id", "stage", "screen"):
            safe_text(trace.get(key))
        uuid.UUID(trace["launch_id"])
        started = timestamp(trace.get("started_at"))
        updated = timestamp(trace.get("updated_at"))
        if not watcher_started - TOLERANCE <= started <= now + TOLERANCE:
            return None
        if not started <= updated <= now + TOLERANCE:
            return None
        heartbeat = trace.get("heartbeat_at")
        if heartbeat is not None:
            heartbeat = timestamp(heartbeat)
            if not started <= heartbeat <= now + TOLERANCE:
                return None
        if not isinstance(trace.get("stages"), list) or len(trace["stages"]) > 32:
            return None
        # Stages may contain detail; never copy that arbitrary payload to receipts.
        return {key: trace[key] for key in (
            "schema_version", "bundle", "version", "build", "pid", "launch_id",
            "started_at", "updated_at", "heartbeat_at", "stage", "screen",
            "tick", "is_loading", "is_active")}
    except (OSError, ValueError, TypeError, KeyError, OverflowError):
        return None


class Observer:
    def __init__(self, simulator, output, seconds):
        self.simulator = simulator
        self.output = output
        self.started = time.time()
        self.deadline = time.monotonic() + seconds
        self.stopping = False
        self.child = None
        self.current = None
        self.current_stage = None
        self.stage_since = None
        self.last_trace = None
        self.sampled = set()
        self.events = output / "observer.jsonl"

    def emit(self, event, **fields):
        record = {"at": utc(), "event": event, **fields}
        with self.events.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")

    def stop(self, _signum=None, _frame=None):
        self.stopping = True
        child = self.child
        if child is not None and child.poll() is None:
            try:
                child.terminate()
            except OSError:
                pass

    @staticmethod
    def cleanup(child):
        if child.poll() is None:
            try:
                child.terminate()
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.kill()
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
            except OSError:
                pass

    def command(self, argv, timeout):
        if self.stopping or time.monotonic() >= self.deadline:
            return {"exit": None, "status": "observer_stopped", "stdout": ""}
        child = None
        end = min(self.deadline, time.monotonic() + timeout)
        status = "exited"
        output = ""
        try:
            child = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
                errors="replace", start_new_session=(os.name == "posix"))
            self.child = child
            while True:
                if self.stopping or time.monotonic() >= end:
                    status = "observer_stopped" if self.stopping else "timeout"
                    self.cleanup(child)
                    break
                try:
                    output, _ = child.communicate(
                        timeout=min(0.25, max(0.01, end - time.monotonic())))
                    break
                except subprocess.TimeoutExpired:
                    continue
            return {"exit": child.poll(), "status": status,
                    "stdout": output[:16384]}
        except OSError:
            return {"exit": None, "status": "unavailable", "stdout": ""}
        finally:
            if child is not None:
                try:
                    self.cleanup(child)
                finally:
                    if child.stdout is not None:
                        child.stdout.close()
            self.child = None

    def containers(self):
        paths = {}
        for kind in ("data", "app"):
            result = self.command(
                ["xcrun", "simctl", "get_app_container", self.simulator,
                 BUNDLE, kind], 5)
            raw = result["stdout"].strip()
            if (result["exit"] != 0 or result["status"] != "exited"
                    or not raw or "\n" in raw or "\r" in raw):
                return None
            path = Path(raw)
            if not path.is_absolute():
                return None
            paths[kind] = path
        if paths["app"].name != "Roomwave.app":
            return None
        return paths

    def proof(self, pid, app):
        executable = str(app / "Roomwave")
        result = self.command(["ps", "-ww", "-p", str(pid), "-o", "command="], 4)
        command = result["stdout"].strip()
        if result["exit"] != 0 or result["status"] != "exited":
            return None
        # Match the complete executable, not a suffix or a different app name.
        if not command.startswith(executable + " "):
            return None
        if "\n" in command or "--arcade-evidence" not in command[len(executable):].split():
            return None
        return {"method": "simctl_app_container_and_ps_full_command",
                "exact_executable": True, "evidence_argument": True,
                "executable_suffix": "Roomwave.app/Roomwave",
                "executable_path_sha256": hashlib.sha256(
                    executable.encode("utf-8")).hexdigest()}

    def observe(self):
        # Refresh on every observation: XCTest can reinstall between hosted/UI tests.
        paths = self.containers()
        if paths is None:
            return
        trace_path = paths["data"] / TRACE
        trace = read_trace(trace_path, self.started, time.time())
        if trace is None:
            return
        identity = (trace["pid"], trace["launch_id"], trace["started_at"])
        now = time.monotonic()
        if identity != self.current:
            self.current = identity
            self.current_stage = trace["stage"]
            self.stage_since = now
            self.last_trace = None
            self.emit("launch_observed", trace=trace)
        elif trace["stage"] != self.current_stage:
            self.current_stage = trace["stage"]
            self.stage_since = now
        if trace != self.last_trace:
            self.emit("trace_observed", trace=trace)
            self.last_trace = trace
        reason = None
        age = None
        heartbeat = trace["heartbeat_at"]
        if (not trace["is_loading"] and trace["is_active"]
                and heartbeat is not None):
            age = time.time() - timestamp(heartbeat)
            if age >= 10 and "heartbeat_stale" not in self.sampled:
                reason = "heartbeat_stale"
        if (reason is None and (trace["is_loading"] or heartbeat is None)
                and now - self.stage_since >= 30
                and "startup_stage_unchanged" not in self.sampled):
            reason = "startup_stage_unchanged"
            age = now - self.stage_since
        if reason is None or len(self.sampled) >= 2:
            return
        proof = self.proof(trace["pid"], paths["app"])
        # Recheck atomic trace after ps; refuse replaced launch/PID or newer state.
        fresh = read_trace(trace_path, self.started, time.time())
        if proof is None or fresh != trace or self.stopping:
            return
        self.sampled.add(reason)
        report = self.output / ("sample-" + reason + ".txt")
        began = utc()
        self.emit("sample_start", reason=reason, observed_age_seconds=round(age, 3),
                  pid=trace["pid"], launch_id=trace["launch_id"], proof=proof,
                  report=report.name)
        result = self.command(
            ["/usr/bin/sample", str(trace["pid"]), "3", "-file", str(report)], 15)
        self.emit("sample_end", reason=reason, pid=trace["pid"],
                  launch_id=trace["launch_id"], proof=proof, started_at=began,
                  exit=result["exit"], status=result["status"],
                  report=report.name, report_exists=report.is_file())

    def run(self):
        self.output.mkdir(parents=True, exist_ok=True)
        self.emit("observer_start", bundle=BUNDLE, simulator=self.simulator,
                  watcher_started_at=datetime.fromtimestamp(
                      self.started, timezone.utc).isoformat(),
                  maximum_samples=2, stale_is_not_hang_diagnosis=True)
        outcome = "deadline"
        try:
            while not self.stopping and time.monotonic() < self.deadline:
                self.observe()
                remaining = min(2.5, self.deadline - time.monotonic())
                # Short sleep slices make SIGTERM stop promptly even between queries.
                until = time.monotonic() + max(0, remaining)
                while not self.stopping and time.monotonic() < until:
                    time.sleep(min(0.1, max(0, until - time.monotonic())))
            if self.stopping:
                outcome = "signal"
        except Exception:
            outcome = "error"
            raise
        finally:
            self.stop()
            self.emit("observer_end", status=outcome,
                      samples=len(self.sampled))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--seconds", type=float, default=1800)
    args = parser.parse_args()
    try:
        uuid.UUID(args.simulator)
    except ValueError:
        parser.error("--simulator must be a UUID")
    if not 0 < args.seconds <= 1800:
        parser.error("--seconds must be greater than zero and at most 1800")
    observer = Observer(args.simulator, args.output_dir, args.seconds)
    signal.signal(signal.SIGTERM, observer.stop)
    signal.signal(signal.SIGINT, observer.stop)
    observer.run()


if __name__ == "__main__":
    main()
