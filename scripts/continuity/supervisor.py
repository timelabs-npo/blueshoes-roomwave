#!/usr/bin/env python3
"""Bounded Roomwave coordinator. Standard library only; never uploads or posts.

Task files are trusted, owner-authored instructions, not public issue bodies.
All state mutations hold an OS advisory lock and replace one JSON snapshot.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

SCHEMA = 1
MAX_WORKERS = 3
MAX_RETRIES = 2
MAX_SECONDS = 1200
TERMINAL = {"ACCEPTED", "CANCELLED", "EXPIRED"}
LIVE = {"RUNNING", "ORPHAN_RUNNING"}
HOST = socket.gethostname()
SHA = re.compile(r"^[0-9a-f]{40}$")
IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
FROZEN_PATHS = {"Package.swift", "Sources/RoomwaveArcade/SurfContracts.swift",
                "apps/ios/Roomwave/Arcade/ArcadeContracts.swift", "apps/ios/project.yml",
                "apps/ios/Roomwave/Info.plist", "AGENTS.md"}


class Problem(Exception):
    pass


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def stamp(value=None):
    return (value or utcnow()).isoformat().replace("+00:00", "Z")


def instant(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("timezone required")
        return parsed.astimezone(dt.timezone.utc)
    except (AttributeError, TypeError, ValueError) as error:
        raise Problem("Expected a timezone-qualified ISO timestamp") from error


def read_json(path):
    try:
        with Path(path).open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        raise Problem(f"Cannot read JSON: {path}: {error}") from error


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        if os.name == "posix":
            descriptor = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def process_marker(pid):
    """Read process start identity; None means absent, '?' means unverifiable."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    if sys.platform.startswith("linux"):
        try:
            record = Path(f"/proc/{pid}/stat").read_text()
            rest = record.rsplit(") ", 1)[1].split()
            if rest[0] == "Z":
                return None
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            return boot + ":" + rest[19]
        except FileNotFoundError:
            return None
        except (OSError, IndexError):
            return "?"
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000 | 0x100000, False, pid)
        if not handle:
            return None if ctypes.get_last_error() == 87 else "?"
        try:
            if kernel.WaitForSingleObject(handle, 0) == 0:
                return None
            created, exited, system, user = (wintypes.FILETIME() for _ in range(4))
            if not kernel.GetProcessTimes(handle, *(ctypes.byref(x) for x in (created, exited, system, user))):
                return "?"
            return str((created.dwHighDateTime << 32) | created.dwLowDateTime)
        finally:
            kernel.CloseHandle(handle)
    try:
        result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                                text=True, capture_output=True, timeout=5)
        return result.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return "?"


def identity(pid):
    return {"host": HOST, "pid": pid, "start_marker": process_marker(pid)}


def process_state(record):
    if not record or record.get("host") != HOST:
        return "UNKNOWN"
    actual = process_marker(record.get("pid"))
    if actual is None:
        return "GONE"
    expected = record.get("start_marker")
    if expected in (None, "?") or actual == "?":
        return "UNKNOWN"
    return "ALIVE" if expected == actual else "REUSED"


class Store:
    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / "state.json"
        self.lock_path = self.directory / "writer.lock"
        self.lease_path = self.directory / "writer-lease.json"
        self.lock_file = None
        self.token = None

    def read(self):
        if not self.path.exists():
            return {"schema_version": SCHEMA, "revision": 0, "tasks": {}, "releases": {}, "signals": []}
        state = read_json(self.path)
        if state.get("schema_version") != SCHEMA:
            raise Problem("Unsupported state schema; refusing to overwrite it")
        return state

    @contextlib.contextmanager
    def writer(self):
        if self.lock_file is not None:
            raise Problem("Writer lease is not reentrant")
        descriptor = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        handle = os.fdopen(descriptor, "r+b", buffering=0)
        try:
            if os.fstat(descriptor).st_size == 0:
                handle.write(b"0")
            handle.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError) as error:
            handle.close()
            raise Problem("Another coordinator holds the writer lease; inspect status, do not bypass it") from error
        self.lock_file = handle
        self.token = uuid.uuid4().hex
        try:
            self.heartbeat()
            yield self
        finally:
            try:
                atomic_json(self.lease_path, {"token": self.token, "owner": identity(os.getpid()),
                                             "released_at": stamp(), "state": "RELEASED"})
            finally:
                handle.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                handle.close()
                self.lock_file = None
                self.token = None

    def heartbeat(self):
        if self.lock_file is None:
            raise Problem("A writer lease is required")
        atomic_json(self.lease_path, {"token": self.token, "owner": identity(os.getpid()),
                                     "heartbeat_at": stamp(), "state": "ACTIVE"})

    def save(self, state):
        if self.lock_file is None:
            raise Problem("State mutation requires the writer lease")
        state["revision"] += 1
        state["updated_at"] = stamp()
        atomic_json(self.path, state)


def git(worktree, *arguments):
    try:
        result = subprocess.run(["git", "-C", str(worktree), *arguments], capture_output=True,
                                timeout=15, check=True)
        return result.stdout.decode("utf-8", errors="surrogateescape")
    except (OSError, subprocess.SubprocessError) as error:
        raise Problem(f"Cannot inspect git worktree ({arguments[0]}): {worktree}") from error


def owned_path(value):
    if not isinstance(value, str) or not value or "\\" in value or "*" in value:
        raise Problem("Owned paths must be literal repository-relative paths; directories end in /")
    raw = value.rstrip("/")
    path = PurePosixPath(raw)
    if path.is_absolute() or raw != str(path) or any(part in ("..", ".git") for part in path.parts):
        raise Problem(f"Unsafe owned path: {value}")
    if raw in ("", ".") or ":" in raw:
        raise Problem(f"Unsafe owned path: {value}")
    return value


def owns(path, claims):
    return any(path == claim.rstrip("/") or (claim.endswith("/") and path.startswith(claim)) for claim in claims)


def paths_overlap(first, second):
    return any(owns(path.rstrip("/"), second) for path in first) or any(owns(path.rstrip("/"), first) for path in second)


def check_claims(state, task_id, paths):
    for other_id, other in state["tasks"].items():
        if other_id != task_id and other["state"] not in TERMINAL and paths_overlap(paths, other.get("owned_paths", [])):
            raise Problem(f"Path ownership overlaps {other_id}; coordinator must resolve the claim")


def bounded_integer(value, lower, upper, name):
    if not isinstance(value, int) or isinstance(value, bool) or not lower <= value <= upper:
        raise Problem(f"{name} must be an integer in [{lower}, {upper}]")
    return value


def validate_task(task):
    if not isinstance(task, dict) or task.get("schema_version") != SCHEMA:
        raise Problem("Task schema_version must be 1")
    if not IDENTIFIER.fullmatch(task.get("task_id", "")) or not SHA.fullmatch(task.get("base_sha", "")):
        raise Problem("A safe task_id and exact lowercase 40-character base_sha are required")
    if task.get("kind") == "gate":
        if task.get("state") not in ("BLOCKED_INPUT", "BLOCKED_ACCESS"):
            raise Problem("Gate records must report BLOCKED_INPUT or BLOCKED_ACCESS")
        if not task.get("reason") or not task.get("required_evidence"):
            raise Problem("A blocked gate needs a reason and required_evidence")
        instant(task["observed_at"])
        return task
    if task.get("kind") != "codex":
        raise Problem("Only owner-authored codex tasks or honest blocked gates may be enqueued")
    if not Path(task.get("worktree", "")).is_absolute():
        raise Problem("Codex worktree must be an absolute local path")
    if not isinstance(task.get("owned_paths"), list) or not task["owned_paths"]:
        raise Problem("Codex tasks need explicit owned_paths")
    for value in task["owned_paths"]:
        owned_path(value)
    if not isinstance(task.get("instructions"), str) or not task["instructions"].strip():
        raise Problem("Task instructions are required; never copy an untrusted issue into this field")
    if len(task["instructions"]) > 32768:
        raise Problem("Keep each bounded task's instructions below 32768 characters")
    if not isinstance(task.get("acceptance"), list) or not task["acceptance"]:
        raise Problem("Independent acceptance criteria are required")
    instant(task.get("deadline_utc"))
    bounded_integer(task.get("max_run_seconds", MAX_SECONDS), 1, MAX_SECONDS, "max_run_seconds")
    bounded_integer(task.get("max_retries", MAX_RETRIES), 0, MAX_RETRIES, "max_retries")
    return task


def inspection(task):
    worktree = Path(task["worktree"]).resolve()
    head = git(worktree, "rev-parse", "HEAD").strip()
    branch = git(worktree, "branch", "--show-current").strip()
    changed = set(git(worktree, "diff", "--name-only", "-z", "HEAD").split("\0"))
    changed.update(git(worktree, "ls-files", "--others", "--exclude-standard", "-z").split("\0"))
    changed.discard("")
    changed = sorted(changed)
    violations = [path for path in changed if not owns(path, task["owned_paths"])
                  or path in FROZEN_PATHS or path.startswith(".github/workflows/")]
    reasons = []
    if head != task["base_sha"]:
        reasons.append("HEAD differs from the exact authorized base SHA")
    if task.get("branch") and task["branch"] != branch:
        reasons.append("Branch differs from the task branch")
    if violations:
        reasons.append("Changes exist outside assigned paths")
    return {"at": stamp(), "head": head, "branch": branch, "changed_paths": changed,
            "ownership_violations": violations, "problems": reasons}


def enqueue(store, task):
    validate_task(task)
    with store.writer():
        state = store.read()
        task_id = task["task_id"]
        if task_id in state["tasks"]:
            raise Problem("Task ID already exists; inspect/resume it instead of duplicating work")
        record = dict(task)
        record.update({"attempts": [], "created_at": stamp(), "origin": {"kind": "local", "host": HOST}})
        if task["kind"] == "codex":
            check_claims(state, task_id, task["owned_paths"])
            record["inspection"] = inspection(task)
            if record["inspection"]["problems"] or record["inspection"]["changed_paths"]:
                raise Problem("Enqueue requires the exact clean base and valid ownership: " + json.dumps(record["inspection"]))
            record["state"] = "QUEUED"
        state["tasks"][task_id] = record
        store.save(state)
        return record


def event_summary(path):
    result = {"session_id": None, "turn_completed": False, "turn_failed": False, "malformed_lines": 0}
    if not Path(path).exists():
        return result
    with Path(path).open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except ValueError:
                result["malformed_lines"] += 1
                continue
            if not isinstance(event, dict):
                result["malformed_lines"] += 1
                continue
            if event.get("type") == "thread.started":
                result["session_id"] = event.get("thread_id")
            if event.get("type") == "turn.completed":
                result["turn_completed"] = True
            if event.get("type") in ("turn.failed", "error"):
                result["turn_failed"] = True
    return result


def finish_attempt(task, attempt, exit_code=None, reason=None):
    # Exit receipt is durable authority for process exit; a model PASS is not.
    receipt_path = Path(attempt["directory"]) / "exit.json"
    if exit_code is not None:
        atomic_json(receipt_path, {"exit_code": exit_code, "ended_at": stamp(), "reason": reason})
    receipt = read_json(receipt_path) if receipt_path.exists() else {}
    attempt.update(event_summary(Path(attempt["directory"]) / "events.jsonl"))
    attempt.update({"exit_code": receipt.get("exit_code"), "ended_at": receipt.get("ended_at", stamp()),
                    "reason": reason or receipt.get("reason")})
    try:
        task["inspection"] = inspection(task)
    except Problem as error:
        task["inspection"] = {"at": stamp(), "problems": [str(error)], "changed_paths": []}
    if task["inspection"]["problems"]:
        task["state"] = "BLOCKED_OWNERSHIP"
    elif attempt["exit_code"] == 0 and attempt["turn_completed"] and not attempt["turn_failed"] \
            and not attempt["malformed_lines"] and not attempt["reason"]:
        task["state"] = "REVIEW_REQUIRED"
    elif attempt["exit_code"] is None:
        task["state"] = "INTERRUPTED"
    else:
        task["state"] = "FAILED"
    attempt["state"] = task["state"]
    atomic_json(Path(attempt["directory"]) / "receipt.json", attempt)


def reconcile_state(state):
    """Inspect only. Never launches a process, uploads, or treats a reused PID as ours."""
    for task in state["tasks"].values():
        if task.get("origin", {}).get("kind") == "wd":
            if task["state"] == "EXTERNAL_RUNNING" and instant(task["deadline_utc"]) <= utcnow():
                task["state"] = "EXTERNAL_RECONCILE_REQUIRED"
                task["reason"] = "Remote deadline passed; import a fresh Wd receipt and inspect remotely"
            continue
        if task["state"] in LIVE:
            attempt = task["attempts"][-1]
            status = process_state(attempt.get("process"))
            attempt["process_observation"] = {"at": stamp(), "state": status}
            if status == "ALIVE":
                task["state"] = "ORPHAN_RUNNING"
                task["reason"] = "Existing worker still alive; no replacement may be launched"
            elif status == "UNKNOWN":
                task["state"] = "ORPHAN_RUNNING"
                task["reason"] = "Worker identity cannot be verified; inspect its original host"
            else:
                finish_attempt(task, attempt)
        elif task["state"] == "QUEUED" and instant(task["deadline_utc"]) <= utcnow():
            task["state"] = "EXPIRED"
    return state


def reconcile(store):
    with store.writer():
        state = reconcile_state(store.read())
        store.save(state)
        return state


def resume(store, task_id, acknowledge_changes=False):
    with store.writer():
        state = reconcile_state(store.read())
        task = state["tasks"].get(task_id)
        if task is None:
            raise Problem("Unknown task")
        if task.get("kind") != "codex" or task.get("origin", {}).get("kind") != "local":
            raise Problem("Only a local Codex task can resume; imported PIDs are never local control targets")
        if task["state"] not in ("FAILED", "INTERRUPTED"):
            raise Problem(f"Cannot resume {task['state']}; reconcile/review first")
        if len(task["attempts"]) >= 1 + task.get("max_retries", MAX_RETRIES):
            raise Problem("Retry budget exhausted; create a deliberately reviewed successor task")
        if instant(task["deadline_utc"]) <= utcnow():
            raise Problem("Task deadline expired; a new bounded task requires coordinator review")
        check_claims(state, task_id, task["owned_paths"])
        report = inspection(task)
        if report["problems"]:
            raise Problem("Resume inspection failed: " + json.dumps(report))
        if report["changed_paths"] and not acknowledge_changes:
            raise Problem("Partial changes exist. Inspect the diff, then use --acknowledge-changes")
        task["inspection"] = report
        task["resume_authorized_at"] = stamp()
        task["state"] = "QUEUED"
        task.pop("reason", None)
        store.save(state)
        return task


def stop_child(process, record):
    if process.poll() is not None:
        return
    if process_state(record) != "ALIVE":
        raise Problem("Refusing to signal an unverified or reused process identity")
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
    else:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)


def prompt_for(task, attempt):
    return ("Roomwave bounded worker task. Read AGENTS.md and docs/ARCADE_CONTRACTS.md.\n"
            f"Task: {task['task_id']}\nExact base: {task['base_sha']}\n"
            f"Owned paths: {json.dumps(task['owned_paths'])}\n"
            f"Deadline UTC: {attempt['deadline_utc']}\nAttempt: {attempt['number']}\n"
            "Do not spawn workers or daemons; do not commit/push/merge/change branch/install dependencies.\n"
            "Do not read credentials, call remote AI, dispatch releases, mutate accounts or send messages.\n"
            "Edit only assigned paths. Request contract changes; do not duplicate shared types.\n"
            "Do not claim native/device/playtest/Apple evidence that did not execute.\n"
            "Partial changes from earlier attempts may exist; inspect them before continuing.\n\n"
            + task["instructions"] + "\n\nAcceptance criteria (independent review required):\n"
            + "\n".join("- " + str(item) for item in task["acceptance"]))


def run(store, codex_bin="codex", max_workers=MAX_WORKERS, budget_seconds=MAX_SECONDS):
    bounded_integer(max_workers, 1, MAX_WORKERS, "max_workers")
    bounded_integer(budget_seconds, 1, MAX_SECONDS, "budget_seconds")
    binary = shutil.which(codex_bin)
    if not binary:
        raise Problem("Codex executable is unavailable; no task was launched")
    active = {}
    deadline = utcnow() + dt.timedelta(seconds=budget_seconds)
    monotonic_deadline = time.monotonic() + budget_seconds
    with store.writer():
        state = reconcile_state(store.read())
        store.save(state)
        if any(task["state"] in ("RUNNING", "ORPHAN_RUNNING", "EXTERNAL_RUNNING", "EXTERNAL_RECONCILE_REQUIRED")
               for task in state["tasks"].values()):
            raise Problem("Existing local/remote workers need reconciliation; this run will not exceed the shared worker cap")
        queue = [task for task in state["tasks"].values()
                 if task["state"] == "QUEUED" and task.get("kind") == "codex" and task["origin"]["kind"] == "local"]
        next_heartbeat = 0.0
        failure = None
        try:
            while (queue or active) and time.monotonic() < monotonic_deadline:
                while queue and len(active) < max_workers and time.monotonic() < monotonic_deadline:
                    task = queue.pop(0)
                    if instant(task["deadline_utc"]) <= utcnow():
                        task["state"] = "EXPIRED"
                        store.save(state)
                        continue
                    check_claims(state, task["task_id"], task["owned_paths"])
                    report = inspection(task)
                    task["inspection"] = report
                    if report["problems"] or (report["changed_paths"] and not task.get("resume_authorized_at")):
                        task["state"] = "BLOCKED_OWNERSHIP"
                        store.save(state)
                        continue
                    if len(task["attempts"]) >= 1 + task.get("max_retries", MAX_RETRIES):
                        task["state"] = "FAILED"
                        task["reason"] = "Retry budget exhausted"
                        store.save(state)
                        continue
                    number = len(task["attempts"]) + 1
                    directory = store.directory / "attempts" / task["task_id"] / f"{number:03d}"
                    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
                    attempt_deadline = min(deadline, instant(task["deadline_utc"]),
                                           utcnow() + dt.timedelta(seconds=task.get("max_run_seconds", MAX_SECONDS)))
                    attempt = {"number": number, "directory": str(directory), "started_at": stamp(),
                               "deadline_utc": stamp(attempt_deadline), "state": "STARTING", "process": None}
                    task["attempts"].append(attempt)
                    task["state"] = "RUNNING"
                    # Commit launch intent before Popen. Missing PID means uncertain, never relaunch silently.
                    atomic_json(directory / "task.json", {key: task[key] for key in
                                ("task_id", "base_sha", "worktree", "owned_paths", "acceptance")})
                    atomic_json(directory / "receipt.json", attempt)
                    store.save(state)
                    command = [binary, "exec", "--sandbox", "workspace-write", "--json", "--cd", task["worktree"],
                               "--output-last-message", str(directory / "result.md"), "-"]
                    events = (directory / "events.jsonl").open("wb")
                    errors = (directory / "stderr.log").open("wb")
                    prompt_path = directory / "prompt.txt"
                    prompt_path.write_text(prompt_for(task, attempt), encoding="utf-8")
                    options = {"start_new_session": True} if os.name != "nt" else {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
                    try:
                        # A file avoids blocking the coordinator on a worker that never drains stdin.
                        with prompt_path.open("rb") as prompt_handle:
                            process = subprocess.Popen(command, stdin=prompt_handle, stdout=events, stderr=errors,
                                                       cwd=task["worktree"], **options)
                        attempt["process"] = identity(process.pid)
                        attempt["state"] = "RUNNING"
                        active[task["task_id"]] = (task, attempt, process, events, errors)
                        atomic_json(directory / "receipt.json", attempt)
                        store.save(state)
                    except OSError as error:
                        if task["task_id"] not in active:
                            events.close()
                            errors.close()
                            finish_attempt(task, attempt, exit_code=127, reason=f"Launch failed: {type(error).__name__}")
                            store.save(state)
                        else:
                            raise
                for task_id, (task, attempt, process, events, errors) in list(active.items()):
                    reason = None
                    if process.poll() is None and instant(attempt["deadline_utc"]) <= utcnow():
                        reason = "Attempt deadline exceeded"
                        stop_child(process, attempt["process"])
                    code = process.poll()
                    if code is not None:
                        events.close()
                        errors.close()
                        finish_attempt(task, attempt, exit_code=code, reason=reason)
                        store.save(state)
                        del active[task_id]
                if time.monotonic() >= next_heartbeat:
                    store.heartbeat()
                    next_heartbeat = time.monotonic() + 5
                if active:
                    time.sleep(0.1)
        except BaseException as error:
            failure = error
        finally:
            for task, attempt, process, events, errors in active.values():
                try:
                    stop_child(process, attempt["process"])
                    events.close()
                    errors.close()
                    finish_attempt(task, attempt, exit_code=process.returncode,
                                   reason="Coordinator interrupted" if failure else "Run budget exceeded")
                except (Problem, OSError, subprocess.SubprocessError) as error:
                    task["state"] = "ORPHAN_RUNNING"
                    task["reason"] = str(error)
                store.save(state)
        if failure:
            raise failure
        return state


def import_wd(store, receipt, device_id, source_path, paths):
    """Whitelisted observation only: remote Windows PIDs can never become local processes."""
    if receipt.get("schemaVersion") != 1 or not IDENTIFIER.fullmatch(receipt.get("taskID", "")):
        raise Problem("Invalid Wd receipt schema/taskID")
    if not SHA.fullmatch(receipt.get("baseCommit", "")) or not device_id or not source_path:
        raise Problem("Wd import requires exact baseCommit, device ID and receipt source path")
    if not paths:
        raise Problem("Wd import requires explicit owned paths from the frozen contract")
    for path in paths:
        owned_path(path)
    instant(receipt.get("startedAtUtc"))
    instant(receipt.get("deadlineAtUtc"))
    status = receipt.get("status")
    mapping = {"STARTED": "EXTERNAL_RUNNING", "COMPLETED": "REVIEW_REQUIRED",
               "TIMED_OUT": "FAILED", "FAILED": "FAILED",
               "TURN_COMPLETED_EXIT_UNVERIFIED": "EVIDENCE_INCOMPLETE"}
    if status not in mapping:
        raise Problem("Unknown Wd status")
    target = mapping[status]
    if status == "COMPLETED" and (type(receipt.get("exitCode")) is not int or receipt.get("exitCode") != 0
                                  or receipt.get("turnCompleted") is not True or receipt.get("timedOut") is True):
        target = "EVIDENCE_INCOMPLETE"
    allowed = ("schemaVersion", "taskID", "lane", "status", "startedAtUtc", "deadlineAtUtc", "heartbeatAtUtc",
               "launcherPID", "workerHostPID", "worktree", "branch", "baseCommit", "sessionID", "turnCompleted",
               "exitCode", "endedAtUtc", "timedOut", "eventLog", "lastMessage")
    snapshot = {key: receipt.get(key) for key in allowed}
    with store.writer():
        state = store.read()
        task_id = receipt["taskID"]
        old = state["tasks"].get(task_id)
        if old and old.get("origin", {}).get("kind") != "wd":
            raise Problem("Cannot replace a local task with an imported receipt")
        if old and (old["origin"]["device_id"] != device_id or old["base_sha"] != receipt["baseCommit"]
                    or old["owned_paths"] != paths or old["external_receipt"]["startedAtUtc"] != receipt["startedAtUtc"]):
            raise Problem("Wd identity/attempt/ownership changed; use a new explicitly reviewed task ID")
        if old:
            previous = old["external_receipt"].get("heartbeatAtUtc") or old["external_receipt"]["startedAtUtc"]
            current = receipt.get("heartbeatAtUtc") or receipt["startedAtUtc"]
            if instant(current) < instant(previous):
                raise Problem("Stale Wd receipt cannot overwrite a newer observation")
            if old["external_receipt"]["status"] != "STARTED" and status == "STARTED":
                raise Problem("Completed Wd attempt cannot regress to STARTED")
        check_claims(state, task_id, paths)
        record = {"schema_version": SCHEMA, "task_id": task_id, "kind": "external", "base_sha": receipt["baseCommit"],
                  "owned_paths": paths, "deadline_utc": receipt["deadlineAtUtc"], "state": target,
                  "origin": {"kind": "wd", "device_id": device_id, "source_path": source_path},
                  "external_receipt": snapshot, "imported_at": stamp(), "attempts": [],
                  "verification": "Receipt imported; remote logs, diff and independent acceptance still required"}
        state["tasks"][task_id] = record
        reconcile_state(state)
        store.save(state)
        return record


def release_key(record):
    if not SHA.fullmatch(record.get("source_sha", "")):
        raise Problem("Release requires exact source_sha")
    for field in ("app_id", "version", "build"):
        if not isinstance(record.get(field), str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", record[field]):
            raise Problem(f"Invalid release {field}")
    # Build identity, not source SHA, is the idempotency key: changing SHA cannot re-upload a build number.
    return ":".join(record[field] for field in ("app_id", "version", "build"))


def claim_release(store, record):
    key = release_key(record)
    with store.writer():
        state = store.read()
        if key in state["releases"]:
            raise Problem("Release identity already claimed. Reconcile the existing upload; never upload again to poll it")
        item = {field: record[field] for field in ("app_id", "version", "build", "source_sha")}
        item.update({"state": "INTENT_RECORDED", "claimed_at": stamp(), "claim_id": uuid.uuid4().hex,
                     "next_action": "Protected release operator may dispatch once, then attach observed receipts"})
        state["releases"][key] = item
        store.save(state)
        return item


RELEASE_RUN_FIELDS = ("workflow_run_id", "workflow_run_number", "workflow_run_attempt", "allocation_id")
RELEASE_PUBLIC_FLAGS = ("apple_external_approval_observed", "public_link_enabled", "external_testing_active",
                        "exact_build_associated", "tester_access_verified", "promotion_evidence_verified")


def release_run_observation(record):
    """Keep absent legacy bindings absent; normalize only explicitly supplied fields."""
    result = {}
    for canonical, alias in (("workflow_run_id", "run_id"), ("workflow_run_number", "run_number"),
                             ("workflow_run_attempt", "run_attempt")):
        for field in (canonical, alias):
            if field not in record:
                continue
            value = record[field]
            if canonical == "workflow_run_id":
                if not (type(value) is int or isinstance(value, str)) or not re.fullmatch(r"[1-9][0-9]{0,19}", str(value)):
                    raise Problem("Release workflow_run_id must be an observed positive numeric run ID")
                value = str(value)
            elif type(value) is not int or not 1 <= value <= (8999 if canonical == "workflow_run_number" else 1):
                raise Problem("Release workflow number/attempt must match the first-attempt allocation")
            if canonical in result and result[canonical] != value:
                raise Problem("Conflicting release workflow aliases")
            result[canonical] = value
    if "workflow_run_number" in result and record["build"] != f'{1000 + result["workflow_run_number"]}.1':
        raise Problem("Release build differs from the observed workflow allocation")
    if "allocation_id" in record:
        allocation = record["allocation_id"]
        match = re.fullmatch(r"github:timelabs-npo/blueshoes-roomwave:([1-9][0-9]{0,19}):1", allocation) if isinstance(allocation, str) else None
        if not match or ("workflow_run_id" in result and match[1] != result["workflow_run_id"]):
            raise Problem("Release allocation ID conflicts with the observed workflow")
        result["allocation_id"] = allocation
    return result


def record_release(store, record):
    key = release_key(record)
    stages = ["INTENT_RECORDED", "DISPATCHED", "UPLOADED", "PROCESSING", "VALID",
              "EXTERNAL_REVIEW_PENDING", "EXTERNAL_APPROVED", "PUBLIC_LINK_ENABLED", "PUBLIC_BETA"]
    target = record.get("state")
    if target not in stages:
        raise Problem("Unknown release observation state")
    if not record.get("evidence") or not record.get("observed_at"):
        raise Problem("Release observations require evidence and observed_at, not an inferred success")
    observed_at = instant(record["observed_at"])
    if stages.index(target) >= stages.index("UPLOADED") and not record.get("apple_build_id"):
        raise Problem("Uploaded/review observations require the exact Apple build ID")
    public = target in ("PUBLIC_LINK_ENABLED", "PUBLIC_BETA")
    if public and not re.fullmatch(r"https://testflight\.apple\.com/join/[A-Za-z0-9]+", record.get("public_url", "")):
        raise Problem("Public beta observations require an observed Apple public TestFlight URL")
    if stages.index(target) >= stages.index("EXTERNAL_REVIEW_PENDING"):
        if not record.get("review_submission_id") or not record.get("group_id"):
            raise Problem("External beta observations require exact review submission and group IDs")
    run = release_run_observation(record)
    for field in RELEASE_PUBLIC_FLAGS:
        if field in record and type(record[field]) is not bool:
            raise Problem(f"Release {field} requires an explicit boolean observation")
    if public:
        if len(run) != len(RELEASE_RUN_FIELDS):
            raise Problem("Public beta requires a complete observed workflow allocation; legacy identity is unproven")
        if (record.get("apple_external_approval_observed") is not True
                or record.get("review_state") != "APPROVED"
                or record.get("external_build_state") not in ("BETA_APPROVED", "IN_BETA_TESTING")
                or record.get("public_link_enabled") is not True
                or record.get("exact_build_associated") is not True):
            raise Problem("Public beta requires observed approval, enabled link and exact group/build membership")
        active = record.get("external_build_state") == "IN_BETA_TESTING"
        if record.get("external_testing_active") is not active or (target == "PUBLIC_BETA" and not active):
            raise Problem("PUBLIC_BETA requires observed active external testing; an enabled link alone is insufficient")
    fields = ("state", "evidence", "observed_at", "apple_build_id", "review_submission_id", "group_id", "public_url",
              "review_state", "external_build_state", *RELEASE_PUBLIC_FLAGS)
    observation = {field: record[field] for field in fields if field in record}
    observation.update(run)
    observation["run_identity_evidence"] = "observed_allocation" if len(run) == len(RELEASE_RUN_FIELDS) else "legacy_unproven"
    with store.writer():
        state = store.read()
        old = state["releases"].get(key)
        if old is None or old["source_sha"] != record["source_sha"]:
            raise Problem("Release observation must match an existing claim and exact source SHA")
        previous_run = release_run_observation(old)
        if any(run.get(field) != value for field, value in previous_run.items()):
            raise Problem("Release workflow run/attempt/allocation identity changed or was omitted")
        if old.get("observed_at"):
            previous_time = instant(old["observed_at"])
            if observed_at < previous_time:
                raise Problem("Stale release observation cannot overwrite a newer receipt")
            if observed_at == previous_time and any(field in old and old[field] != value
                    for field, value in observation.items() if field not in RELEASE_RUN_FIELDS
                    and field not in ("observed_at", "run_identity_evidence")):
                raise Problem("Conflicting release observations at the same timestamp")
        if stages.index(target) < stages.index(old["state"]):
            raise Problem("Release state cannot regress")
        if old.get("apple_build_id") and old["apple_build_id"] != record.get("apple_build_id"):
            raise Problem("Apple build identity changed")
        old = {**old, **observation}
        state["releases"][key] = old
        store.save(state)
        return old


WORKFLOW_PHASE = {"requested": 0, "pending": 0, "waiting": 0, "queued": 0,
                  "in_progress": 1, "completed": 2}
WORKFLOW_CONCLUSIONS = {"success", "failure", "neutral", "cancelled", "skipped", "timed_out",
                        "action_required", "stale", "startup_failure"}
WORKFLOW_ATTEMPT_EVIDENCE = {"workflow_run_payload", "github_run_environment",
                             "github_api_latest", "github_api_attempt"}


def workflow_observation(record):
    """Normalize without inventing attempt numbers or API update timestamps."""
    if record.get("schema_version") not in (1, 2) or record.get("origin") != "github_actions":
        raise Problem("Expected a GitHub Actions observation receipt")
    run_id = record.get("workflow_run_id")
    if (not isinstance(record.get("source_sha"), str) or not SHA.fullmatch(record["source_sha"])
            or type(run_id) is not int or run_id <= 0):
        raise Problem("Workflow observation requires an exact source SHA and positive numeric run ID")
    instant(record.get("observed_at"))
    allowed = ("schema_version", "origin", "source_sha", "workflow_run_id", "workflow_name", "conclusion",
               "observed_at", "trigger", "evidence_url", "run_attempt", "attempt_evidence",
               "run_status", "run_updated_at")
    item = {key: record.get(key) for key in allowed}
    attempt = item["run_attempt"]
    if attempt is None:
        if record["schema_version"] != 1:
            raise Problem("Schema-2 workflow receipts require an observed run_attempt")
        item["attempt_evidence"] = "legacy_unproven"
    else:
        if type(attempt) is not int or attempt < 1:
            raise Problem("Workflow run_attempt must be a positive integer")
        if item["attempt_evidence"] not in WORKFLOW_ATTEMPT_EVIDENCE:
            raise Problem("Workflow attempt requires its GitHub payload, environment or API evidence source")
        if item["run_status"] not in WORKFLOW_PHASE:
            raise Problem("Workflow attempt requires an observed run_status")
        if item["attempt_evidence"] == "github_run_environment":
            if (item["run_status"] != "in_progress" or item["run_updated_at"] is not None
                    or item["conclusion"] != "CONTINUITY_CHECKS_OBSERVED"):
                raise Problem("Current-job environment cannot attest completion or an API update timestamp")
        else:
            instant(item["run_updated_at"])
            if item["run_status"] == "completed":
                if item["conclusion"] not in WORKFLOW_CONCLUSIONS:
                    raise Problem("Completed workflow attempts require a known terminal conclusion")
            elif item["conclusion"] is not None:
                raise Problem("Nonterminal workflow attempts cannot carry a terminal conclusion")
    if item["run_updated_at"] is not None:
        instant(item["run_updated_at"])
    item["interpretation"] = "Observed workflow event only; no gameplay, native, signing or Apple gate inferred"
    item["observation_id"] = hashlib.sha256(json.dumps(item, sort_keys=True, separators=(",", ":"),
                                                       allow_nan=False).encode()).hexdigest()
    return item


def workflow_transition(previous, item):
    """Freshness is GitHub's update time, not a delayed delivery's receipt time."""
    if previous["conclusion"] in WORKFLOW_CONCLUSIONS:
        if item["conclusion"] != previous["conclusion"]:
            raise Problem("Workflow attempt terminal conclusion is immutable; reconcile an exact newer attempt")
    if WORKFLOW_PHASE.get(item["run_status"], 0) < WORKFLOW_PHASE.get(previous["run_status"], 0):
        raise Problem("Workflow attempt status cannot regress")
    before, after = previous["run_updated_at"], item["run_updated_at"]
    if before is not None and after is None:
        raise Problem("Workflow observation lacks freshness evidence for this recorded attempt")
    if before is not None and after is not None:
        if instant(after) < instant(before):
            raise Problem("Stale workflow update timestamp")
        if (instant(after) == instant(before) and previous["run_status"] != item["run_status"]
                and WORKFLOW_PHASE.get(item["run_status"], 0) <= WORKFLOW_PHASE.get(previous["run_status"], 0)):
            raise Problem("Conflicting workflow status at the same update timestamp")
    # An authoritative newer update can arrive with an older local receipt time.
    if not (before is not None and after is not None and instant(after) > instant(before)):
        if instant(item["observed_at"]) < instant(previous["observed_at"]):
            raise Problem("Stale workflow observation timestamp")


def record_workflow(store, record):
    item = workflow_observation(record)
    with store.writer():
        state = store.read()
        # Additive schema-1 migration occurs only during an explicit import, never status/read.
        migrating = "workflow_observations" not in state
        signals = [workflow_observation(entry) for entry in state["signals"]]
        history = list(state.get("workflow_observations", signals))
        related = [entry for entry in history if entry["workflow_run_id"] == item["workflow_run_id"]]
        current = next((entry for entry in signals if entry["workflow_run_id"] == item["workflow_run_id"]), None)
        if any(entry["source_sha"] != item["source_sha"] for entry in related):
            raise Problem("Workflow run identity cannot change its source SHA")
        duplicate = next((entry for entry in related if entry["observation_id"] == item["observation_id"]), None)
        if duplicate:
            if migrating:
                state["signals"], state["workflow_observations"] = signals, history
                store.save(state)
            return {**duplicate, "latest_for_run": current["observation_id"] == duplicate["observation_id"]}
        if current is not None and current["run_attempt"] is not None and item["run_attempt"] is None:
            raise Problem("Legacy unproven attempt cannot replace a proven workflow attempt")
        same_attempt = [entry for entry in related if entry["run_attempt"] == item["run_attempt"]]
        if same_attempt:
            workflow_transition(same_attempt[-1], item)
        advance = current is None
        if current is not None:
            old_attempt, new_attempt = current["run_attempt"], item["run_attempt"]
            if new_attempt is None:
                advance = True
            elif old_attempt is None:
                # A legacy event may describe an unknown later rerun. A delayed event
                # cannot resolve it; obtain a fresh latest-run API observation instead.
                current_api = (item["attempt_evidence"] == "github_api_latest"
                               and instant(item["observed_at"]) >= instant(current["observed_at"]))
                later_event = (item["run_updated_at"] is not None
                               and instant(item["run_updated_at"]) >= instant(current["observed_at"]))
                if not (current_api or later_event):
                    raise Problem("Legacy attempt is unproven; require a fresh latest-run API observation")
                advance = True
            else:
                advance = new_attempt >= old_attempt
                if (new_attempt > old_attempt and current["run_updated_at"] is not None
                        and item["run_updated_at"] is not None
                        and instant(item["run_updated_at"]) < instant(current["run_updated_at"])):
                    raise Problem("Newer workflow attempt has a stale update timestamp")
        history.append(item)  # Append only: never overwrite an attempt's prior observations.
        if advance:
            signals = [entry for entry in signals if entry["workflow_run_id"] != item["workflow_run_id"]]
            signals.append(item)
        state["signals"], state["workflow_observations"] = signals, history
        store.save(state)
        return {**item, "latest_for_run": advance}


def review(store, task_id, decision, evidence):
    if decision not in ("ACCEPTED", "CANCELLED") or not evidence.strip():
        raise Problem("Review needs ACCEPTED/CANCELLED and an evidence reference")
    with store.writer():
        state = store.read()
        task = state["tasks"].get(task_id)
        if not task or task["state"] in LIVE or task["state"] in ("EXTERNAL_RUNNING", "EXTERNAL_RECONCILE_REQUIRED"):
            raise Problem("Cannot review an unknown or possibly running task")
        if decision == "ACCEPTED" and task["state"] != "REVIEW_REQUIRED":
            raise Problem("Only a completed task awaiting independent review may be accepted")
        if decision == "ACCEPTED" and task.get("origin", {}).get("kind") == "local":
            task["inspection"] = inspection(task)
            if task["inspection"]["problems"]:
                raise Problem("Current worktree no longer satisfies the reviewed ownership/base")
        task["review"] = {"decision": decision, "evidence": evidence, "at": stamp()}
        task["state"] = decision
        store.save(state)
        return task


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", default="ops/continuity-state")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    enqueue_parser = commands.add_parser("enqueue")
    enqueue_parser.add_argument("manifest")
    run_parser = commands.add_parser("run")
    run_parser.add_argument("--codex-bin", default="codex")
    run_parser.add_argument("--max-workers", type=int, default=MAX_WORKERS)
    run_parser.add_argument("--budget-seconds", type=int, default=MAX_SECONDS)
    resume_parser = commands.add_parser("resume")
    resume_parser.add_argument("task_id")
    resume_parser.add_argument("--acknowledge-changes", action="store_true")
    reconcile_parser = commands.add_parser("reconcile")
    reconcile_parser.add_argument("--wd-receipt")
    reconcile_parser.add_argument("--device-id")
    reconcile_parser.add_argument("--source-path")
    reconcile_parser.add_argument("--owned-path", action="append", default=[])
    reconcile_parser.add_argument("--release-receipt")
    reconcile_parser.add_argument("--workflow-receipt")
    claim_parser = commands.add_parser("claim-release")
    claim_parser.add_argument("manifest")
    review_parser = commands.add_parser("review")
    review_parser.add_argument("task_id")
    review_parser.add_argument("--decision", required=True, choices=["ACCEPTED", "CANCELLED"])
    review_parser.add_argument("--evidence", required=True)
    options = parser.parse_args(argv)
    try:
        store = Store(options.state_dir)
        if options.command == "status":
            output = store.read()
            output["writer_lease"] = read_json(store.lease_path) if store.lease_path.exists() else None
        elif options.command == "enqueue":
            output = enqueue(store, read_json(options.manifest))
        elif options.command == "run":
            output = run(store, options.codex_bin, options.max_workers, options.budget_seconds)
        elif options.command == "resume":
            output = resume(store, options.task_id, options.acknowledge_changes)
        elif options.command == "claim-release":
            output = claim_release(store, read_json(options.manifest))
        elif options.command == "review":
            output = review(store, options.task_id, options.decision, options.evidence)
        elif options.wd_receipt:
            if options.release_receipt or options.workflow_receipt:
                raise Problem("Import one receipt type per command")
            output = import_wd(store, read_json(options.wd_receipt), options.device_id,
                               options.source_path, options.owned_path)
        elif options.release_receipt:
            if options.workflow_receipt:
                raise Problem("Import one receipt type per command")
            output = record_release(store, read_json(options.release_receipt))
        elif options.workflow_receipt:
            output = record_workflow(store, read_json(options.workflow_receipt))
        else:
            output = reconcile(store)
        print(json.dumps(output, indent=2, sort_keys=True, allow_nan=False))
        return 0
    except (Problem, KeyError, TypeError, ValueError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print(json.dumps({"error": "Interrupted; inspect status and reconcile before resuming"}), file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
