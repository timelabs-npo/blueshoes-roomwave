"""GitHub source/observer identity and receipt compatibility tests, without network."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/continuity/workflow_receipt.py"
SPEC = importlib.util.spec_from_file_location("workflow_receipt", SCRIPT)
w = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(w)


class WorkflowReceiptTests(unittest.TestCase):
    def environment(self, trigger="workflow_run"):
        return {"GITHUB_EVENT_NAME": trigger, "GITHUB_REPOSITORY": "example/roomwave",
                "GITHUB_RUN_ID": "999", "GITHUB_RUN_ATTEMPT": "7", "GITHUB_WORKFLOW": "Observer",
                "GITHUB_SHA": "b" * 40}

    def event(self):
        return {"workflow_run": {"id": 123, "run_attempt": 2, "name": "Native readiness",
                                  "head_sha": "a" * 40, "status": "completed", "conclusion": "failure",
                                  "updated_at": "2026-11-25T20:00:20Z"}}

    def test_observed_attempt_comes_from_payload_not_observer_environment(self):
        result = w.build_receipt(self.event(), self.environment(), "2026-11-25T20:00:30Z")
        self.assertEqual(result["schema_version"], 2)
        self.assertEqual(result["workflow_run_id"], 123)
        self.assertEqual(result["run_attempt"], 2)
        self.assertEqual(result["source_sha"], "a" * 40)
        self.assertEqual(result["run_status"], "completed")
        self.assertEqual(result["conclusion"], "failure")
        self.assertEqual(result["run_updated_at"], "2026-11-25T20:00:20Z")
        self.assertEqual(result["attempt_evidence"], "workflow_run_payload")
        self.assertTrue(result["evidence_url"].endswith("/123/attempts/2"))

    def test_workflow_event_never_falls_back_to_observer_identity_or_time(self):
        for key in ("id", "run_attempt", "updated_at", "status", "head_sha"):
            event = self.event()
            event["workflow_run"].pop(key)
            with self.assertRaises(KeyError):
                w.build_receipt(event, self.environment())
        environment = self.environment()
        for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "GITHUB_WORKFLOW"):
            environment.pop(key)
        self.assertEqual(w.build_receipt(self.event(), environment)["run_attempt"], 2)

    def test_self_run_uses_environment_attempt_and_does_not_claim_completion(self):
        result = w.build_receipt({}, self.environment("pull_request"))
        self.assertEqual(result["workflow_run_id"], 999)
        self.assertEqual(result["run_attempt"], 7)
        self.assertEqual(result["run_status"], "in_progress")
        self.assertEqual(result["conclusion"], "CONTINUITY_CHECKS_OBSERVED")
        self.assertIsNone(result["run_updated_at"])
        self.assertEqual(result["attempt_evidence"], "github_run_environment")

    def test_missing_or_invalid_attempt_is_not_inferred_as_one(self):
        environment = self.environment("workflow_dispatch")
        environment.pop("GITHUB_RUN_ATTEMPT")
        with self.assertRaises(KeyError):
            w.build_receipt({}, environment)
        for value in (0, -1, True, "2.5"):
            event = self.event()
            event["workflow_run"]["run_attempt"] = value
            with self.assertRaises(ValueError):
                w.build_receipt(event, self.environment())
        event["workflow_run"]["run_attempt"] = 2
        event["workflow_run"]["updated_at"] = "2026-11-25T20:00:20"
        with self.assertRaises(ValueError):
            w.build_receipt(event, self.environment())

    def test_real_cli_writes_receipt_and_rejects_missing_subject_attempt(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            event_path, output = root / "event.json", root / "out" / "receipt.json"
            event_path.write_text(json.dumps(self.event()), encoding="utf-8")
            environment = {**os.environ, **self.environment(), "GITHUB_EVENT_PATH": str(event_path)}
            run = subprocess.run([sys.executable, str(SCRIPT), str(output)], env=environment,
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(json.loads(output.read_text())["run_attempt"], 2)
            event = self.event()
            event["workflow_run"].pop("run_attempt")
            event_path.write_text(json.dumps(event), encoding="utf-8")
            output.unlink()
            run = subprocess.run([sys.executable, str(SCRIPT), str(output)], env=environment,
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 2)
            self.assertFalse(output.exists())
            self.assertIn("run_attempt", json.loads(run.stderr)["error"])


if __name__ == "__main__":
    unittest.main()
