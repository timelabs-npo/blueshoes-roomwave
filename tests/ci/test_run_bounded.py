"""Real subprocess tests; no native tools, credentials, or external services."""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).resolve().parents[2] / "scripts/ci/run-bounded.py"


def command(code, *arguments, seconds=3, grace=0.15):
    return [sys.executable, str(RUNNER), "--seconds", str(seconds), "--label", "bounded-test",
            "--grace-seconds", str(grace), "--", sys.executable, "-u", "-c", code, *arguments]


def records(stderr):
    return [json.loads(line) for line in stderr.splitlines() if line.startswith('{"')]


def wait_for_file(path, timeout=3):
    deadline = time.monotonic() + timeout
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not path.exists():
        raise AssertionError(f"child did not create {path.name}")
    return json.loads(path.read_text())


def can_bind(port):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as handle:
        try:
            handle.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


HOLD_PORT = """
import json, os, signal, socket, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
handle = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
handle.bind(('127.0.0.1', 0))
Path(sys.argv[1]).write_text(json.dumps({'pid': os.getpid(), 'pgid': os.getpgrp(),
                                     'port': handle.getsockname()[1]}))
while True: time.sleep(1)
"""


@unittest.skipUnless(os.name == "posix", "POSIX process groups are required")
class BoundedRunnerTests(unittest.TestCase):
    def test_success_preserves_stdio_and_utc_phase_records(self):
        result = subprocess.run(command("import sys; print(sys.stdin.read()); print('child-error', file=sys.stderr)"),
                                input="inherited-input", text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "inherited-input\n")
        self.assertIn("child-error", result.stderr)
        entries = records(result.stderr)
        self.assertEqual([entry["phase"] for entry in entries], ["start", "spawned", "end"])
        self.assertTrue(all(entry["utc"].endswith("Z") for entry in entries))
        self.assertEqual(entries[-1]["child_returncode"], 0)
        self.assertEqual(entries[1]["pid"], entries[1]["pgid"])

    def test_nonzero_exit_is_preserved(self):
        result = subprocess.run(command("raise SystemExit(23)"), text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(records(result.stderr)[-1]["child_returncode"], 23)

    def test_timeout_kills_child_and_descendant_but_not_unrelated_process(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            unrelated_file = directory / "unrelated.json"
            unrelated = subprocess.Popen([sys.executable, "-u", "-c", HOLD_PORT, str(unrelated_file)],
                                         start_new_session=True)
            try:
                unrelated_info = wait_for_file(unrelated_file)
                child_file, descendant_file = directory / "child.json", directory / "descendant.json"
                parent_code = """
import subprocess, sys
subprocess.Popen([sys.executable, '-u', '-c', sys.argv[3], sys.argv[2]])
exec(sys.argv[3])
"""
                result = subprocess.run(command(parent_code, str(child_file), str(descendant_file), HOLD_PORT,
                                                seconds=0.6, grace=0.15),
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 124, result.stderr)
                parent_info = wait_for_file(child_file)
                descendant_info = wait_for_file(descendant_file)
                self.assertEqual(parent_info["pgid"], parent_info["pid"])
                self.assertEqual(descendant_info["pgid"], parent_info["pgid"])
                self.assertTrue(can_bind(parent_info["port"]), "direct child still owns its socket")
                self.assertTrue(can_bind(descendant_info["port"]), "descendant still owns its socket")
                self.assertIsNone(unrelated.poll(), "an unrelated process was terminated")
                self.assertFalse(can_bind(unrelated_info["port"]))
                entries = records(result.stderr)
                self.assertIn("timeout", [entry["phase"] for entry in entries])
                self.assertEqual([entry["signal"] for entry in entries if entry["phase"] == "signal"],
                                 ["SIGTERM", "SIGKILL"])
                self.assertTrue(entries[-1]["cleanup_complete"])
                self.assertEqual(entries[-1]["child_returncode"], -signal.SIGKILL)
            finally:
                unrelated.kill()
                unrelated.wait(timeout=3)

    def test_parent_term_and_int_are_forwarded_and_reported(self):
        for sent_signal in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sent_signal), tempfile.TemporaryDirectory() as folder:
                ready = Path(folder) / "ready.json"
                observed = Path(folder) / "signal.json"
                code = """
import json, signal, sys, time
from pathlib import Path
def received(number, _frame):
    Path(sys.argv[2]).write_text(json.dumps({'signal': number}))
    raise SystemExit(0)
signal.signal(signal.SIGTERM, received)
signal.signal(signal.SIGINT, received)
Path(sys.argv[1]).write_text('{}')
while True: time.sleep(1)
"""
                wrapper = subprocess.Popen(command(code, str(ready), str(observed)),
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    wait_for_file(ready)
                    wrapper.send_signal(sent_signal)
                    _, stderr = wrapper.communicate(timeout=5)
                    self.assertEqual(wrapper.returncode, 128 + sent_signal, stderr)
                    self.assertEqual(wait_for_file(observed)["signal"], sent_signal)
                    end = records(stderr)[-1]
                    self.assertEqual(end["outcome"], "cancelled")
                    self.assertEqual(end["child_returncode"], 0)
                    self.assertTrue(end["cleanup_complete"])
                finally:
                    if wrapper.poll() is None:
                        wrapper.kill()
                        wrapper.wait(timeout=3)

    def test_descendant_is_killed_after_leader_exits_on_term(self):
        with tempfile.TemporaryDirectory() as folder:
            descendant_file = Path(folder) / "descendant.json"
            code = """
import subprocess, sys, time
subprocess.Popen([sys.executable, '-u', '-c', sys.argv[2], sys.argv[1]])
while True: time.sleep(1)
"""
            result = subprocess.run(command(code, str(descendant_file), HOLD_PORT, seconds=0.6),
                                    text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 124, result.stderr)
            descendant = wait_for_file(descendant_file)
            self.assertTrue(can_bind(descendant["port"]), "surviving descendant retained its socket")
            end = records(result.stderr)[-1]
            self.assertEqual(end["child_returncode"], -signal.SIGTERM)
            self.assertTrue(end["cleanup_complete"])

    def test_invalid_deadline_does_not_start_command(self):
        for value in ("0", "-1", "nan", "inf"):
            result = subprocess.run([sys.executable, str(RUNNER), "--seconds", value,
                "--label", "invalid", "--", sys.executable, "-c", "print('must-not-run')"],
                text=True, capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
