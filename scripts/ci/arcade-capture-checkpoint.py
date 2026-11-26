#!/usr/bin/env python3
"""Preserve original native capture bytes from one observed launch, then collect them."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time
import uuid

BUNDLE = "org.timelabs.moleculefoundry"
REQUIRED = ("home-dawn", "home-orbit", "home-midnight", "charged",
            "airborne", "landing", "paused", "results")
MODES = REQUIRED + ("running",)
NAMES = frozenset([mode + suffix for mode in MODES for suffix in (".json", ".png")]
                  + ["diagnostics.json", "events.json"])
CACHE = Path("Library/Caches/RoomwaveArcadeCaptures")
LIMIT_JSON, LIMIT_PNG = 524288, 33554432
MUTABLE = frozenset(("diagnostics.json", "events.json"))
MUTABLE_NAME = re.compile(r"(?:diagnostics|events)-[0-9a-f]{64}\.json")


class Rejected(Exception):
    pass


def require(condition, code):
    if not condition:
        raise Rejected(code)


def stamp():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def timestamp(value):
    require(isinstance(value, str) and len(value) <= 64, "invalid_timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None and parsed.utcoffset().total_seconds() == 0, "timestamp_not_utc")
    return parsed.timestamp()


def identity(trace):
    require(isinstance(trace, dict) and type(trace.get("schema_version")) is int
            and trace["schema_version"] == 1, "invalid_diagnostics")
    require(trace.get("bundle") == BUNDLE and trace.get("version") == "0.3.0"
            and trace.get("build") == "1", "wrong_app_identity")
    require(type(trace.get("pid")) is int and 1 < trace["pid"] < 2**31, "invalid_pid")
    launch = str(uuid.UUID(trace["launch_id"])).upper()
    timestamp(trace["started_at"])
    return {"bundle": BUNDLE, "version": "0.3.0", "build": "1", "pid": trace["pid"],
            "launch_id": launch, "started_at": trace["started_at"]}


def validate_context(value):
    require(isinstance(value, dict) and set(value) == {"source_sha", "run_id", "simulator"},
            "invalid_run_context")
    require(isinstance(value["source_sha"], str)
            and re.fullmatch(r"[0-9a-f]{40}", value["source_sha"]), "invalid_source_sha")
    require(isinstance(value["run_id"], str), "invalid_run_id")
    if value["run_id"].startswith("local:"):
        local_id = value["run_id"][6:]
        require(str(uuid.UUID(local_id)) == local_id, "invalid_local_invocation")
    else:
        require(re.fullmatch(r"[1-9][0-9]*", value["run_id"]), "invalid_run_id")
    uuid.UUID(value["simulator"])


def run_context(start, simulator, environment=None):
    environment = os.environ if environment is None else environment
    source = start["source_sha"]
    github_source, github_run = environment.get("GITHUB_SHA"), environment.get("GITHUB_RUN_ID")
    if environment.get("GITHUB_ACTIONS") == "true" or github_source is not None or github_run is not None:
        require(isinstance(github_run, str) and re.fullmatch(r"[1-9][0-9]*", github_run)
                and source == github_source and start.get("run_id") == github_run, "run_receipt_mismatch")
        run = github_run
    else:
        require(start.get("run_id") is None, "local_run_has_github_identity")
        invocation = start["invocation_id"]
        require(isinstance(invocation, str) and str(uuid.UUID(invocation)) == invocation,
                "invalid_local_invocation")
        run = "local:" + invocation
    context = {"source_sha": source, "run_id": run, "simulator": simulator}
    validate_context(context)
    return context


def read_bytes(path, limit):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        first = os.fstat(descriptor)
        named = os.stat(path, follow_symlinks=False)
        require(stat.S_ISREG(first.st_mode) and stat.S_ISREG(named.st_mode)
                and (first.st_dev, first.st_ino) == (named.st_dev, named.st_ino)
                and first.st_size <= limit, "invalid_capture_file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            payload = stream.read(limit + 1)
        last = os.fstat(descriptor)
        named = os.stat(path, follow_symlinks=False)
        require(stat.S_ISREG(named.st_mode)
                and (first.st_dev, first.st_ino, first.st_size, first.st_mtime_ns)
                == (named.st_dev, named.st_ino, named.st_size, named.st_mtime_ns),
                "capture_path_replaced_during_read")
        require(len(payload) <= limit and len(payload) == first.st_size
                and (first.st_dev, first.st_ino, first.st_size, first.st_mtime_ns)
                == (last.st_dev, last.st_ino, last.st_size, last.st_mtime_ns),
                "capture_changed_during_read")
        return payload, first.st_mtime_ns
    finally:
        os.close(descriptor)


def atomic_bytes(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".capture-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8"))


def file_record(payload, modified):
    return {"sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload),
            "source_mtime_ns": modified}


def stored_name(name, record):
    if name in MUTABLE:
        digest = record.get("sha256")
        require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest),
                "invalid_checkpoint_digest")
        expected = name[:-5] + "-" + digest + ".json"
        require(record.get("stored_as") == expected, "invalid_mutable_snapshot_name")
        return expected
    require("stored_as" not in record, "invalid_fixed_snapshot_name")
    return name


def prune_unreferenced_mutable(directory, records):
    if not directory.exists():
        return
    retained = {stored_name(name, record) for name, record in records.items() if name in MUTABLE}
    # Only our bounded, hash-named mutable snapshots may be removed. The current
    # manifest's files survive every cancellation and every failed update.
    count = 0
    for entry in directory.iterdir():
        count += 1
        require(count <= 64, "checkpoint_directory_limit")
        if MUTABLE_NAME.fullmatch(entry.name) and entry.name not in retained:
            require(stat.S_ISREG(entry.lstat().st_mode), "invalid_mutable_snapshot_file")
            entry.unlink()


def checked_proof(proof):
    require(isinstance(proof, dict), "missing_container_proof")
    method = proof.get("method")
    if method == "simctl_app_container_and_ps_full_command":
        require(proof.get("exact_executable") is True and proof.get("evidence_argument") is True
                and proof.get("executable_suffix") == "Roomwave.app/Roomwave"
                and isinstance(proof.get("executable_path_sha256"), str)
                and re.fullmatch(r"[0-9a-f]{64}", proof["executable_path_sha256"]), "invalid_process_proof")
        return {key: proof[key] for key in ("method", "exact_executable", "evidence_argument",
                                           "executable_suffix", "executable_path_sha256")}
    require(method == "fresh_simctl_data_container" and proof.get("lookup_exit") == 0,
            "invalid_container_proof")
    return {"method": method, "lookup_exit": 0}


def checked_pair(mode, receipt, pixels, launch):
    require(isinstance(receipt, dict) and receipt.get("schema_version") == 4
            and receipt.get("mode") == mode and receipt.get("image_filename") == mode + ".png",
            "capture_pair_identity")
    require(type(receipt.get("pid")) is int and receipt["pid"] == launch["pid"]
            and all(receipt.get(key) == launch[key] for key in ("bundle", "version", "build")),
            "capture_pair_wrong_launch")
    require(pixels.startswith(b"\x89PNG\r\n\x1a\n") and len(pixels) > 1024, "invalid_capture_png")


class Checkpoints:
    def __init__(self, root, context, not_before):
        self.root, self.context, self.not_before = Path(root), context, not_before

    def note(self, trace):
        validate_context(self.context)
        launch = identity(trace)
        began = timestamp(launch["started_at"])
        require(self.not_before - 3 <= began <= time.time() + 3, "capture_outside_run")
        if self.root.exists() or self.root.is_symlink():
            require(stat.S_ISDIR(self.root.lstat().st_mode), "invalid_checkpoint_directory")
        latest = self.root / "latest.json"
        if latest.exists():
            previous = json.loads(read_bytes(latest, LIMIT_JSON)[0])
            require(previous.get("context") == self.context, "checkpoint_from_other_run")
            if previous.get("identity") == launch:
                require(not previous.get("ambiguous_launch"), "older_or_ambiguous_launch")
                return launch
            previous_started = timestamp(previous["identity"]["started_at"])
            if began == previous_started:
                atomic_json(latest, {**previous, "ambiguous_launch": True})
            require(began > previous_started, "older_or_ambiguous_launch")
        # Advance before process proof or file eligibility. Never select an older
        # complete launch when the latest observed one is incomplete/unproven.
        atomic_json(latest, {"schema_version": 1, "context": self.context, "identity": launch})
        return launch

    def capture(self, cache, trace, proof, seconds=5, cancelled=None):
        deadline = time.monotonic() + seconds
        def within_budget():
            require(time.monotonic() < deadline and not (cancelled and cancelled()), "checkpoint_stopped")
        within_budget()
        launch = self.note(trace)
        proof = checked_proof(proof)
        cache = Path(cache)
        require(stat.S_ISDIR(cache.lstat().st_mode), "invalid_capture_directory")
        diagnostic_bytes, _ = read_bytes(cache / "diagnostics.json", 65536)
        require(identity(json.loads(diagnostic_bytes)) == launch, "diagnostics_launch_changed")
        directory = self.root / launch["launch_id"]
        if directory.exists() or directory.is_symlink():
            require(stat.S_ISDIR(directory.lstat().st_mode), "invalid_checkpoint_directory")
        manifest_path = directory / "manifest.json"
        if manifest_path.exists():
            manifest = json.loads(read_bytes(manifest_path, LIMIT_JSON)[0])
            require(manifest.get("context") == self.context and manifest.get("identity") == launch,
                    "checkpoint_identity_changed")
            files = dict(manifest["files"])
        else:
            files = {}
        within_budget()
        prune_unreferenced_mutable(directory, files)
        pending, partial = {}, []
        began_ns = int(timestamp(launch["started_at"]) * 1_000_000_000)
        for mode in MODES:
            within_budget()
            receipt_name, image_name = mode + ".json", mode + ".png"
            if receipt_name in files and image_name in files:
                continue  # These mode pairs are immutable for this app launch.
            try:
                receipt_bytes, receipt_time = read_bytes(cache / receipt_name, 65536)
                pixels, image_time = read_bytes(cache / image_name, LIMIT_PNG)
                repeat, _ = read_bytes(cache / receipt_name, 65536)
                require(repeat == receipt_bytes, "capture_pair_changed")
                require(min(receipt_time, image_time) >= began_ns, "capture_predates_launch")
                checked_pair(mode, json.loads(receipt_bytes), pixels, launch)
                pending[receipt_name] = (receipt_bytes, receipt_time)
                pending[image_name] = (pixels, image_time)
            except FileNotFoundError:
                partial.append(mode)
        try:
            events, modified = read_bytes(cache / "events.json", LIMIT_JSON)
            parsed = json.loads(events)
            require(isinstance(parsed, list) and len(parsed) <= 600, "invalid_events")
            require(modified >= began_ns, "events_predate_launch")
            pending["events.json"] = (events, modified)
        except FileNotFoundError:
            pass
        # Heartbeats may advance; the launch identity must remain exactly equal.
        diagnostic_bytes, modified = read_bytes(cache / "diagnostics.json", 65536)
        require(identity(json.loads(diagnostic_bytes)) == launch and modified >= began_ns,
                "diagnostics_launch_changed")
        pending["diagnostics.json"] = (diagnostic_bytes, modified)
        for name, (payload, modified) in pending.items():
            within_budget()
            record = file_record(payload, modified)
            if name in MUTABLE:
                record["stored_as"] = name[:-5] + "-" + record["sha256"] + ".json"
            atomic_bytes(directory / stored_name(name, record), payload)
            files[name] = record
        manifest = {"schema_version": 1, "context": self.context, "identity": launch,
                    "proof": proof, "captured_at": stamp(), "files": files, "missing_pairs": partial}
        # Only this final manifest makes complete, hash-bound pairs selectable.
        within_budget()
        atomic_json(manifest_path, manifest)
        return manifest

    def selected(self):
        validate_context(self.context)
        require(stat.S_ISDIR(self.root.lstat().st_mode), "invalid_checkpoint_directory")
        latest = json.loads(read_bytes(self.root / "latest.json", LIMIT_JSON)[0])
        require(latest.get("context") == self.context, "checkpoint_from_other_run")
        require(not latest.get("ambiguous_launch"), "older_or_ambiguous_launch")
        launch = latest["identity"]
        require(identity({"schema_version": 1, **launch}) == launch, "invalid_checkpoint_identity")
        began = timestamp(launch["started_at"])
        require(self.not_before - 3 <= began <= time.time() + 3, "capture_outside_run")
        directory = self.root / launch["launch_id"]
        require(stat.S_ISDIR(directory.lstat().st_mode), "invalid_checkpoint_directory")
        manifest = json.loads(read_bytes(directory / "manifest.json", LIMIT_JSON)[0])
        require(manifest.get("context") == self.context and manifest.get("identity") == launch,
                "checkpoint_identity_changed")
        checked_proof(manifest.get("proof"))
        records = manifest.get("files")
        require(isinstance(records, dict) and set(records) <= NAMES, "invalid_checkpoint_files")
        needed = {mode + suffix for mode in REQUIRED for suffix in (".json", ".png")}
        needed |= {"events.json", "diagnostics.json"}
        require(needed <= set(records), "checkpoint_incomplete")
        payloads = {}
        for name, record in records.items():
            require(isinstance(record, dict), "invalid_checkpoint_file_record")
            payload, _ = read_bytes(directory / stored_name(name, record),
                                    LIMIT_PNG if name.endswith(".png") else LIMIT_JSON)
            require(record.get("bytes") == len(payload)
                    and record.get("sha256") == hashlib.sha256(payload).hexdigest(), "checkpoint_hash_mismatch")
            payloads[name] = payload
        require(identity(json.loads(payloads["diagnostics.json"])) == launch, "checkpoint_diagnostics_mismatch")
        for mode in MODES:
            if mode + ".json" in payloads or mode + ".png" in payloads:
                require(mode + ".json" in payloads and mode + ".png" in payloads, "checkpoint_partial_pair")
                checked_pair(mode, json.loads(payloads[mode + ".json"]), payloads[mode + ".png"], launch)
        return manifest, payloads

    def promote(self, output):
        manifest, payloads = self.selected()
        output = Path(output)
        existing = [name for name in NAMES if (output / name).exists()]
        if existing:
            require((output / "diagnostics.json").is_file(), "existing_unowned_capture_files")
            diagnostic, _ = read_bytes(output / "diagnostics.json", 65536)
            require(identity(json.loads(diagnostic)) == manifest["identity"], "output_from_other_launch")
        for name, payload in payloads.items():
            atomic_bytes(output / name, payload)
        # This receipt is separate from the unchanged app-produced evidence.
        return manifest


def collect(checkpoints, output, receipt_path, lookup_exit=None, fresh_container=""):
    result = {"schema_version": 1, "observed_at": stamp(), "context": checkpoints.context,
              "status": "BLOCKED", "lookup_exit": lookup_exit, "verifier_unchanged": True}
    try:
        try:
            manifest = checkpoints.promote(output)
            result.update(status="COPIED", collection_source="observer_checkpoint",
                          identity=manifest["identity"], files=manifest["files"])
        except (FileNotFoundError, Rejected):
            if lookup_exit is None:
                raise Rejected("fresh_container_lookup_required")
            require(lookup_exit == 0, "fresh_container_lookup_failed")
            require(fresh_container and "\n" not in fresh_container and "\r" not in fresh_container,
                    "invalid_fresh_container")
            container = Path(fresh_container)
            require(container.is_absolute(), "invalid_fresh_container")
            raw, _ = read_bytes(container / CACHE / "diagnostics.json", 65536)
            trace = json.loads(raw)
            launch = identity(trace)
            latest_path = checkpoints.root / "latest.json"
            if latest_path.exists():
                latest = json.loads(read_bytes(latest_path, LIMIT_JSON)[0])
                require(latest.get("context") == checkpoints.context and latest.get("identity") == launch,
                        "fresh_container_different_launch")
            checkpoints.capture(container / CACHE, trace,
                                {"method": "fresh_simctl_data_container", "lookup_exit": 0})
            manifest = checkpoints.promote(output)
            result.update(status="COPIED", collection_source="fresh_container",
                          identity=manifest["identity"], files=manifest["files"])
    except (OSError, ValueError, TypeError, KeyError, Rejected) as error:
        result["reason"] = str(error) if isinstance(error, Rejected) else "capture_collection_error"
    atomic_json(Path(receipt_path), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--run-receipt", type=Path, required=True)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--lookup-exit", type=int)
    parser.add_argument("--fresh-container", default="")
    args = parser.parse_args()
    try:
        start = json.loads(read_bytes(args.run_receipt, 65536)[0])
        context = run_context(start, args.simulator)
        checkpoints = Checkpoints(args.checkpoint_dir, context, timestamp(start["started_at"]))
        result = collect(checkpoints, args.output_dir, args.receipt, args.lookup_exit, args.fresh_container)
        print(json.dumps({key: value for key, value in result.items() if key != "files"}, sort_keys=True))
        return 0 if result["status"] == "COPIED" else 2
    except (OSError, ValueError, TypeError, KeyError, Rejected) as error:
        result = {"schema_version": 1, "status": "BLOCKED", "observed_at": stamp(),
                  "reason": str(error) if isinstance(error, Rejected) else "capture_collection_error"}
        atomic_json(args.receipt, result)
        print(json.dumps(result, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
