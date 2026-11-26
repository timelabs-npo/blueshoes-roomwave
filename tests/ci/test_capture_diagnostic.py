"""Exercise the real shell policy with fake native tools, never native PASS evidence."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CaptureDiagnosticTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="roomwave-capture-policy-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in ["scripts/release/validate-native.sh", "scripts/ci/verify-arcade-evidence.py", "VERSION"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tool("python3", "#!" + sys.executable + "\n" + r'''
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
if args and args[0].endswith('run-bounded.py'):
    label = args[args.index('--label') + 1]
    if label == 'native-tests':
        assert 'xcodebuild' in args and args[-1] == 'test'
        mode = os.environ.get('TEST_RUNNER_ROOMWAVE_CAPTURE_DIAGNOSTIC', '')
        Path('native-invocation.json').write_text(json.dumps({'mode': mode}))
        if os.environ.get('FAKE_NATIVE_FAIL'):
            sys.exit(65)
        if not os.environ.get('FAKE_MISSING_CAPTURE_CONFIRMATION'):
            Path('build/release/evidence/diagnostics.json').write_text(json.dumps({
                'capture_diagnostic': mode == 'metadata-only',
                'app_snapshots_enabled': mode != 'metadata-only'}))
    sys.exit(0)
if args and args[0].endswith('select-simulator.py'):
    print('00000000-0000-0000-0000-000000000001')
    sys.exit(0)
if args and args[0].endswith(('watch-arcade-recording.py', 'watch-arcade-diagnostics.py')):
    sys.exit(0)
os.execv(sys.executable, [sys.executable] + args)
''')
        self.tool("xcodegen", "#!/bin/sh\nexit 0\n")
        self.tool("xcrun", "#!/bin/sh\ncase \"$*\" in\n  *--show-sdk-version*) echo 27.2;;\n  *) echo '{}';;\nesac\n")
        self.tool("git", "#!/bin/sh\necho 1111111111111111111111111111111111111111\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "ROOMWAVE_", "TEST_RUNNER_"))}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_WORKFLOW="Unsigned iOS readiness",
                        GITHUB_SHA="1" * 40, GITHUB_RUN_ID="unit-test", GITHUB_STEP_SUMMARY=str(self.root / "summary.md"))

    def tool(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_policy(self, **values):
        return subprocess.run(["bash", "scripts/release/validate-native.sh"], cwd=self.root,
                              env={**self.env, **values}, text=True, capture_output=True, timeout=10)

    def receipt(self):
        return self.root / "build/release/evidence/capture-diagnostic.json"

    def test_protected_release_rejects_capture_override_before_any_native_work(self):
        result = self.run_policy(GITHUB_WORKFLOW="Roomwave TestFlight pilot", ROOMWAVE_CAPTURE_DIAGNOSTIC="metadata-only")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse((self.root / "native-invocation.json").exists())
        self.assertFalse(self.receipt().exists())

    def test_nonmanual_or_mixed_runtime_diagnostics_are_rejected(self):
        for values in [dict(GITHUB_EVENT_NAME="pull_request"), dict(ROOMWAVE_DIAGNOSTIC_RUNTIME="27.0")]:
            with self.subTest(values=values):
                result = self.run_policy(ROOMWAVE_CAPTURE_DIAGNOSTIC="metadata-only", **values)
                self.assertEqual(result.returncode, 2)
                self.assertFalse((self.root / "native-invocation.json").exists())

    def test_direct_test_runner_environment_cannot_bypass_release_policy(self):
        result = self.run_policy(GITHUB_WORKFLOW="Roomwave TestFlight pilot",
                                 TEST_RUNNER_ROOMWAVE_CAPTURE_DIAGNOSTIC="metadata-only")
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "native-invocation.json").exists())

    def test_explicit_diagnostic_requires_native_success_and_observed_app_flag(self):
        result = self.run_policy(ROOMWAVE_CAPTURE_DIAGNOSTIC="metadata-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / "native-invocation.json").read_text())["mode"], "metadata-only")
        receipt = json.loads(self.receipt().read_text())
        self.assertTrue(receipt["diagnostic_only"])
        self.assertTrue(receipt["native_input_verified"])
        self.assertFalse(receipt["render_evidence_verified"])
        self.assertFalse(receipt["release_ready"])
        self.assertIn("does not satisfy the release gate", (self.root / "summary.md").read_text())
        self.assertFalse((self.root / "build/release/UnsignedRoomwave.xcarchive.zip").exists())

    def test_native_failure_cannot_publish_diagnostic_success(self):
        result = self.run_policy(ROOMWAVE_CAPTURE_DIAGNOSTIC="metadata-only", FAKE_NATIVE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.receipt().exists())

    def test_missing_app_confirmation_cannot_publish_diagnostic_success(self):
        result = self.run_policy(ROOMWAVE_CAPTURE_DIAGNOSTIC="metadata-only", FAKE_MISSING_CAPTURE_CONFIRMATION="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.receipt().exists())

    def test_normal_run_still_rejects_missing_render_evidence(self):
        result = self.run_policy()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("home-dawn.json", result.stderr)
        self.assertFalse(self.receipt().exists())
        self.assertEqual(json.loads((self.root / "native-invocation.json").read_text())["mode"], "")


if __name__ == "__main__":
    unittest.main()
