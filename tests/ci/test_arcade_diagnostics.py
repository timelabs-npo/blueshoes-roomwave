"""Portable observer safety checks; macOS discovery/sampling calls are faked."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "scripts/ci/watch-arcade-diagnostics.py"
SPEC = importlib.util.spec_from_file_location("arcade_diagnostic_observer", SOURCE)
WATCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WATCHER)
SIMULATOR = "00000000-0000-0000-0000-000000000001"
LAUNCH_A = "10000000-0000-0000-0000-000000000001"
LAUNCH_B = "20000000-0000-0000-0000-000000000002"


def stamp(seconds_ago=0):
    return WATCHER.datetime.fromtimestamp(
        time.time() - seconds_ago, WATCHER.timezone.utc).isoformat()


def trace():
    at = stamp()
    return dict(schema_version=1, bundle=WATCHER.BUNDLE, version="0.3.0", build="1",
                pid=4242, launch_id=LAUNCH_A, started_at=at, updated_at=at,
                stage="scene.loading", heartbeat_at=None, screen="home", tick=0,
                is_loading=True, is_active=True, stages=[])


class FakeObserver(WATCHER.Observer):
    def __init__(self, root):
        super().__init__(SIMULATOR, root / "output", 120)
        self.output.mkdir(parents=True)
        self.app = root / "Roomwave.app"
        self.data = root / "container-one"
        self.calls = []
        self.executable_override = None
        self.argument = " --arcade-evidence"
        self.replace_on_proof = None

    def command(self, argv, timeout):
        self.calls.append((argv, timeout))
        if argv[0] == "xcrun":
            path = self.data if argv[-1] == "data" else self.app
            return dict(exit=0, status="exited", stdout=str(path))
        if argv[0] == "ps":
            if self.replace_on_proof is not None:
                self.write(self.replace_on_proof)
            executable = self.executable_override or str(self.app / "Roomwave")
            return dict(exit=0, status="exited", stdout=executable + self.argument)
        if argv[0] == "/usr/bin/sample":
            Path(argv[-1]).write_text("fake sample", encoding="utf-8")
            return dict(exit=0, status="exited", stdout="")
        raise AssertionError("Unexpected external command: " + repr(argv))

    def write(self, value):
        path = self.data / WATCHER.TRACE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def samples(self):
        return [call for call in self.calls if call[0][0] == "/usr/bin/sample"]

    def make_stalled_startup(self):
        self.write(trace())
        self.observe()
        self.stage_since -= 31


class ArcadeDiagnosticTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="roomwave-observer-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.observer = FakeObserver(self.root)

    def test_current_trace_is_accepted(self):
        path = self.observer.write(trace())
        self.assertIsNotNone(WATCHER.read_trace(path, self.observer.started, time.time()))

    def test_old_and_future_launches_are_rejected(self):
        value = trace()
        path = self.observer.write(value)
        self.assertIsNone(WATCHER.read_trace(path, time.time() + 10, time.time() + 10))
        value.update(started_at=stamp(-10), updated_at=stamp(-10))
        path = self.observer.write(value)
        self.assertIsNone(WATCHER.read_trace(path, self.observer.started, time.time()))

    def test_bundle_version_build_and_launch_uuid_are_required(self):
        for key, value in (("bundle", "other.bundle"), ("version", "0.2.0"),
                           ("build", "2"), ("build", 1), ("launch_id", "launch-a")):
            with self.subTest(key=key, value=value):
                payload = trace()
                payload[key] = value
                path = self.observer.write(payload)
                self.assertIsNone(WATCHER.read_trace(path, self.observer.started, time.time()))

    def test_trace_uses_one_bounded_descriptor_read(self):
        path = mock.MagicMock(spec=["open"])
        stream = mock.MagicMock()
        stream.read.return_value = json.dumps(trace()).encode()
        path.open.return_value.__enter__.return_value = stream
        self.assertIsNotNone(WATCHER.read_trace(path, self.observer.started, time.time()))
        path.open.assert_called_once_with("rb")
        stream.read.assert_called_once_with(65537)

    def test_oversized_and_non_object_json_are_rejected(self):
        path = self.observer.data / WATCHER.TRACE
        path.parent.mkdir(parents=True)
        for payload in (b" " * 65537, b"[]", b"null", b"{invalid", b"\xff"):
            with self.subTest(size=len(payload)):
                path.write_bytes(payload)
                self.assertIsNone(WATCHER.read_trace(path, self.observer.started, time.time()))

    def test_no_sample_before_startup_threshold(self):
        self.observer.write(trace())
        self.observer.observe()
        self.assertEqual(self.observer.samples(), [])

    def test_foreign_executable_is_never_sampled(self):
        self.observer.make_stalled_startup()
        self.observer.executable_override = str(self.root / "Other.app" / "Roomwave")
        self.observer.observe()
        self.assertEqual(self.observer.samples(), [])

    def test_hosted_or_similar_argument_is_never_sampled(self):
        self.observer.make_stalled_startup()
        for argument in ("", " --arcade-evidence-extra"):
            with self.subTest(argument=argument):
                self.observer.argument = argument
                self.observer.observe()
                self.assertEqual(self.observer.samples(), [])

    def test_replaced_trace_between_proof_and_sample_is_rejected(self):
        self.observer.make_stalled_startup()
        replacement = trace()
        replacement.update(pid=4243, launch_id=LAUNCH_B)
        self.observer.replace_on_proof = replacement
        self.observer.observe()
        self.assertEqual(self.observer.samples(), [])

    def test_startup_is_sampled_once_with_bounded_command(self):
        self.observer.make_stalled_startup()
        self.observer.observe()
        self.observer.observe()
        self.assertEqual(self.observer.sampled, {"startup_stage_unchanged"})
        self.assertEqual(len(self.observer.samples()), 1)
        argv, timeout = self.observer.samples()[0]
        self.assertEqual(argv[1:3], ["4242", "3"])
        self.assertEqual(timeout, 15)

    def test_reinstalled_container_and_launch_reset_observation(self):
        self.observer.make_stalled_startup()
        self.observer.data = self.root / "container-two"
        replacement = trace()
        replacement.update(pid=4243, launch_id=LAUNCH_B)
        self.observer.write(replacement)
        self.observer.observe()
        self.assertEqual(self.observer.current[:2], (4243, LAUNCH_B))
        self.assertLess(time.monotonic() - self.observer.stage_since, 2)
        self.assertEqual(self.observer.samples(), [])

    def test_loaded_stale_heartbeat_and_global_two_sample_limit(self):
        self.observer.make_stalled_startup()
        self.observer.observe()
        self.observer.started = time.time() - 25
        replacement = trace()
        replacement.update(pid=4243, launch_id=LAUNCH_B, started_at=stamp(20),
                           is_loading=False, heartbeat_at=stamp(15), stage="loaded")
        self.observer.write(replacement)
        self.observer.observe()
        self.observer.observe()
        self.assertEqual(self.observer.sampled,
                         {"startup_stage_unchanged", "heartbeat_stale"})
        self.assertEqual(len(self.observer.samples()), 2)

    def test_static_healthy_loaded_stage_is_not_sampled(self):
        value = trace()
        value.update(is_loading=False, heartbeat_at=value["updated_at"])
        self.observer.write(value)
        self.observer.observe()
        self.observer.stage_since -= 60
        self.observer.observe()
        self.assertEqual(self.observer.samples(), [])

    def test_receipt_contains_proof_exit_and_times_without_full_command(self):
        self.observer.make_stalled_startup()
        self.observer.observe()
        text = self.observer.events.read_text(encoding="utf-8")
        records = [json.loads(line) for line in text.splitlines()]
        end = next(record for record in records if record["event"] == "sample_end")
        self.assertEqual(end["pid"], 4242)
        self.assertEqual(end["launch_id"], LAUNCH_A)
        self.assertEqual(end["exit"], 0)
        self.assertTrue(end["proof"]["exact_executable"])
        self.assertTrue(end["proof"]["evidence_argument"])
        self.assertTrue(end["at"].endswith("Z"))
        self.assertTrue(end["started_at"].endswith("Z"))
        self.assertNotIn(str(self.observer.app), text)

    def test_real_owned_child_success_and_nonzero(self):
        observer = WATCHER.Observer(SIMULATOR, self.root / "real", 10)
        success = observer.command([sys.executable, "-c", "print('ok')"], 3)
        self.assertEqual((success["exit"], success["stdout"].strip()), (0, "ok"))
        failed = observer.command([sys.executable, "-c", "raise SystemExit(7)"], 3)
        self.assertEqual(failed["exit"], 7)
        self.assertIsNone(observer.child)

    def test_real_owned_child_timeout_is_bounded_and_reaped(self):
        observer = WATCHER.Observer(SIMULATOR, self.root / "real", 10)
        began = time.monotonic()
        result = observer.command(
            [sys.executable, "-c", "import time; time.sleep(30)"], .25)
        self.assertEqual(result["status"], "timeout")
        self.assertLess(time.monotonic() - began, 3)
        self.assertIsNotNone(result["exit"])
        self.assertIsNone(observer.child)

    def test_cli_invalid_limits_exit_before_any_native_command(self):
        for seconds in ("0", "1801", "nan"):
            with self.subTest(seconds=seconds):
                result = subprocess.run(
                    [sys.executable, str(SOURCE), "--simulator", SIMULATOR,
                     "--output-dir", str(self.root / "cli"), "--seconds", seconds],
                    text=True, capture_output=True, timeout=4)
                self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "cli").exists())


if __name__ == "__main__":
    unittest.main()
