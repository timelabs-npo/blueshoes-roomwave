"""Offline safety checks; no real host logs or simulator are accessed."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "scripts/ci/collect-metal-diagnostics.py"
SPEC = importlib.util.spec_from_file_location("metal_diagnostics", SOURCE)
METAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METAL)
SIMULATOR = "00000000-0000-0000-0000-000000000001"


class MetalDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="roomwave-metal-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "reports"
        self.source.mkdir()
        self.output = self.root / "output"
        self.output.mkdir()
        self.descriptor = METAL.directory(self.output)
        self.addCleanup(os.close, self.descriptor)
        self.now = time.time()
        self.start = self.now - 60

    def report(self, name="SimMetalHost-one.ips", process="SimMetalHost", when=None):
        when = self.now - 5 if when is None else when
        header = {"timestamp": METAL.utc(when)}
        body = {"procName": process, "captureTime": METAL.utc(when), "test": name}
        path = self.source / name
        path.write_text(json.dumps(header) + "\n" + json.dumps(body))
        os.utime(path, (self.now - 1, self.now - 1))
        return path

    def collect(self, deadline=None, source=None):
        return METAL.collect([("host-user", source or self.source)], self.descriptor,
                             self.start, self.now, deadline or time.monotonic() + 5)

    def test_current_ips_and_crash_preserve_hash_size_and_provenance(self):
        self.report()
        legacy = self.source / "SimMetalHost-two.crash"
        legacy.write_text("Process: SimMetalHost [44]\nDate/Time: " + METAL.utc(self.now - 4) + "\n")
        os.utime(legacy, (self.now - 1, self.now - 1))
        reports, warnings = self.collect()
        self.assertEqual(len(reports), 2)
        self.assertEqual(warnings, [])
        for report in reports:
            payload = (self.output / report["file"]).read_bytes()
            self.assertEqual(METAL.hashlib.sha256(payload).hexdigest(), report["sha256"])
            self.assertEqual(len(payload), report["size_bytes"])
            self.assertEqual(report["root"], "host-user")
            self.assertIn("source_inode", report)

    def test_wrong_name_process_and_old_incident_are_not_collected(self):
        self.report("OtherApp-one.ips")
        self.report("SimMetalHost-wrong.ips", process="OtherApp")
        self.report("SimMetalHost-old.ips", when=self.start - 100)
        self.assertEqual(self.collect()[0], [])
        self.assertEqual(list(self.output.iterdir()), [])

    def test_old_file_mtime_blocks_recent_report_and_subdirs_are_not_scanned(self):
        path = self.report()
        os.utime(path, (self.start - 2, self.start - 2))
        nested = self.source / "nested"
        nested.mkdir()
        (nested / path.name).write_bytes(path.read_bytes())
        self.assertEqual(self.collect()[0], [])

    def test_file_root_and_parent_symlinks_are_rejected(self):
        target = self.report()
        (self.source / "SimMetalHost-linked.ips").symlink_to(target)
        target.rename(self.root / "outside.ips")
        self.assertEqual(self.collect()[0], [])
        linked = self.root / "linked"
        linked.symlink_to(self.source, target_is_directory=True)
        self.assertEqual(self.collect(source=linked)[0], [])
        with self.assertRaises(OSError):
            METAL.directory(linked / "child")

    def test_hardlink_is_not_accepted_as_regular_source(self):
        target = self.report()
        os.link(target, self.root / "hardlink.ips")
        self.assertEqual(self.collect()[0], [])

    def test_count_and_bytes_limits_are_enforced(self):
        for number in range(4):
            self.report(f"SimMetalHost-{number}.ips")
        with mock.patch.object(METAL, "MAX_FILES", 2):
            reports, warnings = self.collect()
        self.assertEqual(len(reports), 2)
        self.assertIn("report_count_limit", [item["reason"] for item in warnings])
        with mock.patch.object(METAL, "MAX_FILE_BYTES", 10):
            self.assertEqual(self.collect()[0], [])
        with mock.patch.object(METAL, "MAX_TOTAL_BYTES", 1):
            self.assertEqual(self.collect()[0], [])

    def test_expired_deadline_stops_without_output(self):
        self.report()
        reports, warnings = self.collect(deadline=time.monotonic() - 1)
        self.assertEqual(reports, [])
        self.assertEqual(warnings, [{"reason": "collection_deadline"}])
        self.assertEqual(list(self.output.iterdir()), [])

    def test_scanning_has_an_entry_bound(self):
        self.report()
        with mock.patch.object(METAL, "MAX_ENTRIES", 0):
            reports, warnings = self.collect()
        self.assertEqual(reports, [])
        self.assertEqual(warnings[0]["reason"], "directory_entry_limit")

    def test_only_fixed_selected_simulator_paths_and_canonical_uuid(self):
        values = METAL.roots(self.root, SIMULATOR)
        self.assertEqual(len(values), 4)
        self.assertEqual(values[2][1], self.root / "Library/Developer/CoreSimulator/Devices" /
                         SIMULATOR / "data/Library/Logs/CrashReporter")
        for bad in ("../other", SIMULATOR.replace("-", ""), "booted"):
            with self.assertRaises(ValueError):
                METAL.roots(self.root, bad)

    def test_cli_output_and_receipt_cannot_escape_owned_paths(self):
        expected = self.root / "build/release/evidence/metal-diagnostics"
        _, actual = METAL.scoped_paths("build/release/native-run-start.json", str(expected), self.root)
        self.assertEqual(actual, expected)
        for output in ("elsewhere", "build/release/evidence/../metal-diagnostics", "/tmp/dump"):
            with self.assertRaises(ValueError):
                METAL.scoped_paths("build/release/native-run-start.json", output, self.root)

    def test_receipt_identity_time_and_source_are_not_inferred(self):
        path = self.root / "receipt.json"
        receipt = {"started_at": METAL.utc(self.start), "source_sha": "a" * 40, "run_id": "123"}
        path.write_text(json.dumps(receipt))
        result, start = METAL.load_receipt(path, self.now, time.monotonic() + 5, {})
        self.assertEqual(result["source_sha"], "a" * 40)
        self.assertAlmostEqual(start, self.start, places=5)
        with self.assertRaises(ValueError):
            METAL.load_receipt(path, self.now, time.monotonic() + 5, {"GITHUB_SHA": "b" * 40})
        for when in (self.now + 60, self.now - METAL.MAX_AGE_SECONDS - 1):
            receipt["started_at"] = METAL.utc(when)
            path.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                METAL.load_receipt(path, self.now, time.monotonic() + 5, {})


if __name__ == "__main__":
    unittest.main()
