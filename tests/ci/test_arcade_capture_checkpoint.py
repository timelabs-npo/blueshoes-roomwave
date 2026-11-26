"""Offline preservation tests. Synthetic capture bytes are never native-render evidence."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "scripts/ci/arcade-capture-checkpoint.py"
SPEC = importlib.util.spec_from_file_location("capture_checkpoint_tests", SOURCE)
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
LAUNCH_A = "10000000-0000-0000-0000-000000000001"
LAUNCH_B = "20000000-0000-0000-0000-000000000002"


def at(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace("+00:00", "Z")


class CaptureCheckpointTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="capture-checkpoint-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.started = time.time() - 3
        self.context = {"source_sha": "a" * 40, "run_id": "123",
                        "simulator": "00000000-0000-0000-0000-000000000001"}
        self.checkpoints = C.Checkpoints(self.root / "checkpoints", self.context, self.started)
        self.container = self.root / "container"
        self.cache = self.container / C.CACHE
        self.output = self.root / "evidence"
        self.receipt = self.root / "evidence-collection.json"
        self.trace = {"schema_version": 1, "bundle": C.BUNDLE, "version": "0.3.0", "build": "1",
                      "pid": 4242, "launch_id": LAUNCH_A, "started_at": at(self.started + 1),
                      "updated_at": at(time.time()), "stage": "snapshot_accepted", "stages": []}
        self.proof = {"method": "simctl_app_container_and_ps_full_command", "exact_executable": True,
                      "evidence_argument": True, "executable_suffix": "Roomwave.app/Roomwave",
                      "executable_path_sha256": "b" * 64}
        self.write_cache()

    def write_cache(self, trace=None):
        value = self.trace if trace is None else trace
        self.cache.mkdir(parents=True, exist_ok=True)
        (self.cache / "diagnostics.json").write_text(json.dumps(value, indent=3) + "\n", encoding="utf-8")
        (self.cache / "events.json").write_text(
            '[{"run_generation":1,"events":["takeoff","landing"]}]\n', encoding="utf-8")
        for mode in C.REQUIRED:
            receipt = {"schema_version": 4, "mode": mode, "image_filename": mode + ".png",
                       "pid": value["pid"], "bundle": C.BUNDLE, "version": "0.3.0", "build": "1"}
            (self.cache / (mode + ".json")).write_text(json.dumps(receipt, indent=4) + "\n", encoding="utf-8")
            # Deliberately synthetic payload exercises byte preservation, not PNG rendering.
            (self.cache / (mode + ".png")).write_bytes(
                b"\x89PNG\r\n\x1a\n" + (mode.encode() + b" ") * 200)

    def capture(self):
        return self.checkpoints.capture(self.cache, self.trace, self.proof)

    def collect(self, lookup_exit=None, container=""):
        return C.collect(self.checkpoints, self.output, self.receipt, lookup_exit, container)

    def test_local_invocation_is_explicit_unique_and_shared_by_both_readers(self):
        start = {"source_sha": self.context["source_sha"], "run_id": None,
                 "invocation_id": "12345678-1234-1234-1234-123456789abc"}
        first = C.run_context(start, self.context["simulator"], {})
        self.assertEqual(first, C.run_context(start, self.context["simulator"], {}))
        self.assertEqual(first["run_id"], "local:" + start["invocation_id"])
        second = C.run_context({**start, "invocation_id": "22345678-1234-1234-1234-123456789abc"},
                               self.context["simulator"], {})
        self.assertNotEqual(first, second)
        local = C.Checkpoints(self.root / "local", first, self.started)
        local.capture(self.cache, self.trace, self.proof)
        self.assertEqual(local.selected()[0]["context"], first)

    def test_ci_context_requires_exact_source_and_run_and_cannot_fall_back_to_local(self):
        start = {"source_sha": self.context["source_sha"], "run_id": "123",
                 "invocation_id": "12345678-1234-1234-1234-123456789abc"}
        environment = {"GITHUB_ACTIONS": "true", "GITHUB_SHA": self.context["source_sha"],
                       "GITHUB_RUN_ID": "123"}
        self.assertEqual(C.run_context(start, self.context["simulator"], environment), self.context)
        for changed in ({**start, "source_sha": "b" * 40}, {**start, "run_id": "124"},
                        {**start, "run_id": None}):
            with self.subTest(changed=changed):
                with self.assertRaisesRegex(C.Rejected, "run_receipt_mismatch"):
                    C.run_context(changed, self.context["simulator"], environment)
        with self.assertRaisesRegex(C.Rejected, "run_receipt_mismatch"):
            C.run_context({**start, "run_id": None}, self.context["simulator"], {"GITHUB_ACTIONS": "true"})

    def test_original_pair_events_and_diagnostics_bytes_are_preserved(self):
        original = {path.name: path.read_bytes() for path in self.cache.iterdir()}
        manifest = self.capture()
        result = self.collect()
        self.assertEqual(result["status"], "COPIED")
        self.assertEqual(result["collection_source"], "observer_checkpoint")
        for name, payload in original.items():
            self.assertEqual((self.output / name).read_bytes(), payload)
            self.assertEqual(manifest["files"][name]["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertNotIn("launch_id", json.loads((self.output / "home-dawn.json").read_text()))
        self.assertNotIn("native_input_and_render_verified", result)

    def test_lookup_timeout_or_deleted_container_uses_complete_same_launch_checkpoint(self):
        self.capture()
        shutil.rmtree(self.container)
        result = self.collect(124, str(self.container))
        self.assertEqual(result["status"], "COPIED")
        self.assertEqual(result["identity"]["launch_id"], LAUNCH_A)
        self.assertEqual(result["collection_source"], "observer_checkpoint")
        self.assertEqual(result["lookup_exit"], 124)

    def test_partial_pair_is_not_published_as_complete(self):
        (self.cache / "home-dawn.json").unlink()
        manifest = self.capture()
        self.assertNotIn("home-dawn.json", manifest["files"])
        self.assertNotIn("home-dawn.png", manifest["files"])
        result = self.collect(124)
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(result["reason"], "fresh_container_lookup_failed")
        self.assertFalse((self.output / "home-dawn.png").exists())

    def test_wrong_capture_pid_is_rejected_before_any_manifest(self):
        path = self.cache / "home-dawn.json"
        value = json.loads(path.read_text())
        value["pid"] += 1
        path.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(C.Rejected, "wrong_launch"):
            self.capture()
        self.assertFalse((self.checkpoints.root / LAUNCH_A / "manifest.json").exists())

    def test_new_incomplete_launch_cannot_reuse_or_restore_older_complete_launch(self):
        self.capture()
        new = {**self.trace, "pid": 4243, "launch_id": LAUNCH_B, "started_at": at(self.started + 2)}
        self.checkpoints.note(new)
        with self.assertRaisesRegex(C.Rejected, "older_or_ambiguous_launch"):
            self.capture()
        latest = json.loads((self.checkpoints.root / "latest.json").read_text())
        self.assertEqual(latest["identity"]["launch_id"], LAUNCH_B)
        self.assertEqual(self.collect(124)["status"], "BLOCKED")
        self.assertFalse((self.output / "home-dawn.json").exists())

    def test_final_cached_trace_of_new_launch_blocks_older_complete_checkpoint(self):
        self.capture()
        watcher_path = SOURCE.with_name("watch-arcade-diagnostics.py")
        spec = importlib.util.spec_from_file_location("checkpoint_observer_test", watcher_path)
        watcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(watcher)
        observer = watcher.Observer(self.context["simulator"], self.root / "observer", 60,
                                    context=self.context)
        observer.checkpoints = self.checkpoints
        observer.current = (self.trace["pid"], self.trace["launch_id"], self.trace["started_at"])
        observer.stopping = True
        newer = {**self.trace, "pid": 4243, "launch_id": LAUNCH_B, "started_at": at(self.started + 2)}
        with mock.patch.object(observer, "proof") as proof:
            observer.preserve_captures({"data": self.container}, newer, allow_proof=False)
            proof.assert_not_called()
        latest = json.loads((self.checkpoints.root / "latest.json").read_text())
        self.assertEqual(latest["identity"]["launch_id"], LAUNCH_B)
        self.assertEqual(self.collect(124)["status"], "BLOCKED")

    def test_equal_timestamp_different_identity_blocks_older_checkpoint_selection(self):
        self.capture()
        ambiguous = {**self.trace, "pid": 4243, "launch_id": LAUNCH_B}
        with self.assertRaisesRegex(C.Rejected, "older_or_ambiguous_launch"):
            self.checkpoints.note(ambiguous)
        with self.assertRaisesRegex(C.Rejected, "older_or_ambiguous_launch"):
            self.checkpoints.selected()
        self.assertEqual(self.collect(124)["status"], "BLOCKED")

    def test_fresh_container_with_different_launch_never_fills_partial_checkpoint(self):
        (self.cache / "home-dawn.json").unlink()
        self.capture()
        replacement = {**self.trace, "pid": 4243, "launch_id": LAUNCH_B,
                       "started_at": at(self.started + 2)}
        self.write_cache(replacement)
        result = self.collect(0, str(self.container))
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(result["reason"], "fresh_container_different_launch")
        self.assertFalse((self.output / "home-dawn.json").exists())

    def test_fresh_container_can_complete_only_the_same_launch(self):
        original = (self.cache / "home-dawn.json").read_bytes()
        (self.cache / "home-dawn.json").unlink()
        self.capture()
        (self.cache / "home-dawn.json").write_bytes(original)
        result = self.collect(0, str(self.container))
        self.assertEqual(result["status"], "COPIED")
        self.assertEqual(result["collection_source"], "fresh_container")
        self.assertEqual((self.output / "home-dawn.json").read_bytes(), original)

    def test_changed_diagnostics_during_capture_discards_pending_pairs(self):
        original_read = C.read_bytes
        reads = 0
        replacement = {**self.trace, "pid": 4243, "launch_id": LAUNCH_B}
        def read(path, limit):
            nonlocal reads
            value = original_read(path, limit)
            if Path(path) == self.cache / "diagnostics.json":
                reads += 1
                if reads == 2:
                    return json.dumps(replacement).encode(), value[1]
            return value
        with mock.patch.object(C, "read_bytes", side_effect=read):
            with self.assertRaisesRegex(C.Rejected, "diagnostics_launch_changed"):
                self.capture()
        self.assertFalse((self.checkpoints.root / LAUNCH_A / "manifest.json").exists())

    def test_interrupted_mutable_update_preserves_the_previous_complete_snapshot(self):
        self.capture()
        previous, original = self.checkpoints.selected()
        (self.cache / "events.json").write_text('[{"run_generation":2,"events":["landing"]}]\n',
                                                  encoding="utf-8")
        changed_trace = {**self.trace, "stage": "later_stage", "updated_at": at(time.time())}
        (self.cache / "diagnostics.json").write_text(json.dumps(changed_trace), encoding="utf-8")
        original_write = C.atomic_bytes
        for failure in ("write_failure", "cancellation"):
            with self.subTest(failure=failure):
                stopped = False
                def interrupt_after_first_mutable(path, payload):
                    nonlocal stopped
                    original_write(path, payload)
                    if Path(path).name.startswith("events-"):
                        stopped = True
                        if failure == "write_failure":
                            raise OSError("synthetic interrupted checkpoint write")
                with mock.patch.object(C, "atomic_bytes", side_effect=interrupt_after_first_mutable):
                    with self.assertRaises((OSError, C.Rejected)):
                        self.checkpoints.capture(self.cache, self.trace, self.proof,
                                                 cancelled=lambda: stopped)
                selected, preserved = self.checkpoints.selected()
                self.assertEqual(selected, previous)
                self.assertEqual(preserved, original)

    def test_repeated_mutable_updates_keep_storage_bounded(self):
        self.capture()
        for generation in range(2, 6):
            (self.cache / "events.json").write_text(
                json.dumps([{"run_generation": generation, "events": ["landing"]}]), encoding="utf-8")
            self.capture()
        manifest, _ = self.checkpoints.selected()
        directory = self.checkpoints.root / LAUNCH_A
        mutable = [path for path in directory.iterdir() if C.MUTABLE_NAME.fullmatch(path.name)]
        self.assertLessEqual(len(mutable), 4)
        for name in C.MUTABLE:
            self.assertTrue((directory / manifest["files"][name]["stored_as"]).is_file())

    def test_modified_checkpoint_bytes_block_promotion(self):
        self.capture()
        path = self.checkpoints.root / LAUNCH_A / "home-dawn.png"
        path.write_bytes(path.read_bytes() + b"altered")
        result = self.collect()
        self.assertEqual(result["status"], "BLOCKED")
        self.assertFalse((self.output / "home-dawn.png").exists())

    def test_other_run_checkpoint_is_never_selected(self):
        self.capture()
        other = C.Checkpoints(self.checkpoints.root, {**self.context, "run_id": "124"}, self.started)
        with self.assertRaisesRegex(C.Rejected, "other_run"):
            other.selected()

    def test_stopped_capture_cannot_publish_a_manifest(self):
        with self.assertRaisesRegex(C.Rejected, "checkpoint_stopped"):
            self.checkpoints.capture(self.cache, self.trace, self.proof, cancelled=lambda: True)
        self.assertFalse((self.checkpoints.root / LAUNCH_A / "manifest.json").exists())

    def test_source_files_from_before_launch_are_rejected(self):
        import os
        path = self.cache / "home-dawn.png"
        os.utime(path, (self.started - 5, self.started - 5))
        with self.assertRaisesRegex(C.Rejected, "predates_launch"):
            self.capture()


if __name__ == "__main__":
    unittest.main()
