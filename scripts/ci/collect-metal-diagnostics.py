#!/usr/bin/env python3
"""Collect only current-run SimMetalHost reports; never diagnose causality.

Host reports belong to a shared runner. A matching time window does not prove
Roomwave caused a service failure. No recursive search or external command runs.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import time
import uuid

MAX_FILES = 8
MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024
MAX_ENTRIES = 2048
MAX_AGE_SECONDS = 3 * 3600
COLLECTION_SECONDS = 50
NAME = re.compile(r"SimMetalHost(?:[-_.][A-Za-z0-9_.-]+)?\.(?:ips|crash)\Z")


class Deadline(Exception):
    pass


def utc(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def timestamp(value):
    if not isinstance(value, str) or len(value) > 80:
        raise ValueError("invalid timestamp")
    value = re.sub(r"\s+([+-]\d{4})$", r"\1", value.strip())
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp requires timezone")
    return parsed.timestamp()


def check_deadline(deadline):
    if time.monotonic() >= deadline:
        raise Deadline()


def directory(path):
    """Open every component without following links, including parent links."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("absolute non-traversing directory required")
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_regular(parent, name, limit, deadline):
    check_deadline(deadline)
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError("not an unlinked regular source")
        if not 0 < before.st_size <= limit:
            raise ValueError("file size outside bound")
        data = bytearray()
        while len(data) <= limit:
            check_deadline(deadline)
            chunk = os.read(descriptor, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(descriptor)
        current = os.stat(name, dir_fd=parent, follow_symlinks=False)
        signature = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
        if (len(data) != before.st_size or signature(before) != signature(after)
                or signature(after) != signature(current) or after.st_nlink != 1):
            raise ValueError("source changed during read")
        return bytes(data), before
    finally:
        os.close(descriptor)


def load_receipt(path, now, deadline, environment=None):
    environment = os.environ if environment is None else environment
    parent = directory(path.parent)
    try:
        data, _ = read_regular(parent, path.name, 8192, deadline)
    finally:
        os.close(parent)
    receipt = json.loads(data)
    if not isinstance(receipt, dict) or receipt.get("schema_version", 1) != 1:
        raise ValueError("invalid start receipt schema")
    start = timestamp(receipt.get("started_at"))
    if not now - MAX_AGE_SECONDS <= start <= now:
        raise ValueError("start receipt is stale or in the future")
    source = receipt.get("source_sha")
    run = receipt.get("run_id")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("invalid receipt source SHA")
    if not isinstance(run, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", run):
        raise ValueError("invalid receipt run ID")
    if environment.get("GITHUB_SHA") and source != environment["GITHUB_SHA"]:
        raise ValueError("receipt source does not match job")
    if environment.get("GITHUB_RUN_ID") and run != environment["GITHUB_RUN_ID"]:
        raise ValueError("receipt run does not match job")
    return {"started_at": utc(start), "source_sha": source, "run_id": run}, start


def report_time(name, data):
    text = data.decode("utf-8")
    if name.endswith(".crash"):
        if not re.search(r"^Process:\s+SimMetalHost\s+\[\d+\]\s*$", text, re.M):
            raise ValueError("report is not SimMetalHost")
        match = re.search(r"^Date/Time:\s*(.+)$", text, re.M)
        if match is None:
            raise ValueError("report has no incident timestamp")
        return timestamp(match.group(1))
    decoder = json.JSONDecoder()
    objects = []
    remainder = text.lstrip()
    # Apple .ips reports may have a separate one-line metadata object.
    for _ in range(2):
        if not remainder:
            break
        value, end = decoder.raw_decode(remainder)
        if not isinstance(value, dict):
            raise ValueError("invalid IPS object")
        objects.append(value)
        remainder = remainder[end:].lstrip()
    if remainder:
        raise ValueError("unexpected IPS content")
    body = next((item for item in reversed(objects) if item.get("procName") == "SimMetalHost"), None)
    if body is None:
        raise ValueError("report is not SimMetalHost")
    return timestamp(body.get("captureTime") or objects[0].get("timestamp"))


def roots(home, simulator):
    parsed = str(uuid.UUID(simulator)).upper()
    if simulator.upper() != parsed:
        raise ValueError("simulator must be a canonical UUID")
    base = home / "Library/Developer/CoreSimulator/Devices" / parsed / "data/Library/Logs"
    return [("host-user", home / "Library/Logs/DiagnosticReports"),
            ("host-system", Path("/Library/Logs/DiagnosticReports")),
            ("simulator-crash", base / "CrashReporter"),
            ("simulator-diagnostic", base / "DiagnosticReports")]


def save(parent, name, data):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=parent)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)


def collect(source_roots, output, start, end, deadline):
    reports, warnings = [], []
    total = 0
    seen = set()
    try:
        for label, path in source_roots:
            check_deadline(deadline)
            try:
                parent = directory(path)
            except FileNotFoundError:
                warnings.append({"root": label, "reason": "directory_absent"})
                continue
            except OSError:
                warnings.append({"root": label, "reason": "directory_inaccessible_or_linked"})
                continue
            try:
                candidates = []
                with os.scandir(parent) as entries:
                    for count, entry in enumerate(entries):
                        check_deadline(deadline)
                        if count >= MAX_ENTRIES:
                            warnings.append({"root": label, "reason": "directory_entry_limit"})
                            break
                        if NAME.fullmatch(entry.name) and len(entry.name) <= 200:
                            candidates.append(entry.name)
                for name in sorted(candidates):
                    check_deadline(deadline)
                    if len(reports) >= MAX_FILES:
                        warnings.append({"root": label, "reason": "report_count_limit"})
                        return reports, warnings
                    try:
                        data, info = read_regular(parent, name, MAX_FILE_BYTES, deadline)
                        incident = report_time(name, data)
                        if not start <= info.st_mtime <= end or not start <= incident <= end:
                            warnings.append({"root": label, "basename": name, "reason": "outside_job_window"})
                            continue
                        digest = hashlib.sha256(data).hexdigest()
                        if digest in seen:
                            continue
                        if total + len(data) > MAX_TOTAL_BYTES:
                            warnings.append({"root": label, "reason": "total_bytes_limit"})
                            continue
                        destination = label + "-" + digest[:16] + "-" + name
                        save(output, destination, data)
                        seen.add(digest)
                        total += len(data)
                        reports.append({"root": label, "original_basename": name,
                                        "file": destination, "sha256": digest,
                                        "size_bytes": len(data), "report_at": utc(incident),
                                        "modified_at": utc(info.st_mtime),
                                        "birth_at": utc(info.st_birthtime) if hasattr(info, "st_birthtime") else None,
                                        "source_device": info.st_dev, "source_inode": info.st_ino})
                    except (OSError, ValueError, UnicodeError, RecursionError):
                        warnings.append({"root": label, "basename": name,
                                         "reason": "unsafe_changed_oversized_or_invalid_report"})
            finally:
                os.close(parent)
    except Deadline:
        warnings.append({"reason": "collection_deadline"})
    return reports, warnings


def scoped_paths(receipt, output, cwd):
    def absolute(value):
        path = Path(value)
        if ".." in path.parts:
            raise ValueError("path traversal rejected")
        return path if path.is_absolute() else cwd / path
    expected = cwd / "build/release"
    if absolute(receipt) != expected / "native-run-start.json":
        raise ValueError("receipt must be this job's native-run-start.json")
    if absolute(output) != expected / "evidence/metal-diagnostics":
        raise ValueError("output must be build/release/evidence/metal-diagnostics")
    return absolute(receipt), absolute(output)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since-receipt", required=True)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args(argv)
    output = None
    alarm = None
    try:
        # This CLI targets the macOS native job. Fail closed on missing primitives.
        if not hasattr(os, "O_NOFOLLOW") or not hasattr(signal, "setitimer"):
            raise ValueError("POSIX no-follow paths and interval timer required")
        alarm = signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Deadline()))
        signal.setitimer(signal.ITIMER_REAL, 55)
        now = time.time()
        deadline = time.monotonic() + COLLECTION_SECONDS
        receipt_path, output_path = scoped_paths(args.since_receipt, args.output_dir, Path.cwd())
        receipt, start = load_receipt(receipt_path, now, deadline)
        source_roots = roots(Path.home(), args.simulator)
        parent = directory(output_path.parent)
        try:
            # A fresh directory avoids mixing artifacts from another invocation.
            os.mkdir(output_path.name, 0o700, dir_fd=parent)
            output = os.open(output_path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        finally:
            os.close(parent)
        reports, warnings = collect(source_roots, output, start, now, deadline)
        index = {"schema_version": 1, "status": "partial" if warnings else "collected",
                 "source": receipt, "simulator": args.simulator.upper(),
                 "window_end": utc(now), "collected_at": utc(time.time()),
                 "scope": "SimMetalHost only; shared-host time-window observations, not app causality",
                 "limits": {"reports": MAX_FILES, "file_bytes": MAX_FILE_BYTES,
                            "total_bytes": MAX_TOTAL_BYTES, "entries_per_directory": MAX_ENTRIES,
                            "collection_seconds": COLLECTION_SECONDS, "hard_seconds": 55},
                 "host_log_query": "not_collected", "reports": reports, "warnings": warnings}
        save(output, "index.json", (json.dumps(index, indent=2, sort_keys=True) + "\n").encode())
        print(json.dumps({"status": index["status"], "reports": len(reports), "warnings": len(warnings)}))
        return 0
    except (OSError, ValueError, TypeError, Deadline) as error:
        # Do not print exception filenames or arbitrary report content.
        print(json.dumps({"status": "blocked", "error_type": type(error).__name__}))
        return 2
    finally:
        if output is not None:
            os.close(output)
        if alarm is not None:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, alarm)


if __name__ == "__main__":
    raise SystemExit(main())
