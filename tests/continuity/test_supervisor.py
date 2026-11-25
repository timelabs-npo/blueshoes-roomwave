"""Failure-path and end-to-end tests; fake Codex is a real bounded subprocess."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/continuity/supervisor.py"
SPEC = importlib.util.spec_from_file_location("supervisor", SCRIPT)
s = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(s)


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.command("git", "init", "-q", str(self.repo))
        self.command("git", "-C", str(self.repo), "config", "user.name", "Test")
        self.command("git", "-C", str(self.repo), "config", "user.email", "test@example.invalid")
        (self.repo / "seed.txt").write_text("seed\n")
        self.command("git", "-C", str(self.repo), "add", "seed.txt")
        self.command("git", "-C", str(self.repo), "commit", "-qm", "seed")
        self.sha = self.command("git", "-C", str(self.repo), "rev-parse", "HEAD").strip()
        self.store = s.Store(self.root / "state")
        self.codex = self.root / "fake-codex"
        self.codex.write_text(f"#!{sys.executable}\n" + '''import json, pathlib, sys, time
prompt = sys.stdin.read()
print(json.dumps({"type":"thread.started","thread_id":"fake-session","time":time.monotonic()}), flush=True)
if "MODE_WAIT" in prompt:
    time.sleep(0.15)
if "MODE_HANG" in prompt:
    time.sleep(30)
if "MODE_PARTIAL" in prompt:
    pathlib.Path("owned").mkdir(exist_ok=True)
    pathlib.Path("owned/partial.txt").write_text("partial")
if "MODE_ESCAPE" in prompt:
    pathlib.Path("outside.txt").write_text("outside")
if "MODE_FAIL" in prompt:
    print(json.dumps({"type":"turn.failed"}), flush=True)
    sys.exit(7)
print(json.dumps({"type":"turn.completed","time":time.monotonic()}), flush=True)
result = pathlib.Path(sys.argv[sys.argv.index("--output-last-message")+1])
result.write_text("Worker claim only; independent review still required.")
''')
        self.codex.chmod(0o700)

    def tearDown(self):
        self.temp.cleanup()

    def command(self, *args):
        return subprocess.run(args, check=True, text=True, capture_output=True).stdout

    def task(self, task_id="work", instructions="Produce a scoped change", paths=None):
        return {"schema_version": 1, "task_id": task_id, "kind": "codex", "base_sha": self.sha,
                "worktree": str(self.repo), "owned_paths": paths or ["owned/"],
                "deadline_utc": s.stamp(s.utcnow() + dt.timedelta(minutes=20)),
                "max_run_seconds": 5, "max_retries": 2, "instructions": instructions,
                "acceptance": ["Independent reviewer examines the diff and executed evidence"]}

    def state_task(self, state=None, task_id="work"):
        return (state or self.store.read())["tasks"][task_id]

    def interrupted(self, receipt=None, process=None):
        s.enqueue(self.store, self.task())
        directory = self.store.directory / "attempts/work/001"
        directory.mkdir(parents=True)
        (directory / "events.jsonl").write_text(json.dumps({"type": "turn.completed"}) + "\n")
        if receipt:
            s.atomic_json(directory / "exit.json", receipt)
        with self.store.writer():
            state = self.store.read()
            task = state["tasks"]["work"]
            task["state"] = "RUNNING"
            task["attempts"].append({"number": 1, "directory": str(directory),
                                     "process": process or {"host": s.HOST, "pid": 99999999, "start_marker": "old"}})
            self.store.save(state)

    def wd_receipt(self, status="STARTED", exit_code=None):
        return {"schemaVersion": 1, "taskID": "arcade-v03-gameplay", "lane": "gameplay", "status": status,
                "startedAtUtc": "2026-11-25T17:00:00Z", "deadlineAtUtc": "2099-11-25T17:20:00Z",
                "heartbeatAtUtc": "2026-11-25T17:01:00Z", "launcherPID": os.getpid(), "workerHostPID": os.getpid(),
                "worktree": "C:\\worktrees\\gameplay", "branch": "arcade-v03/gameplay", "baseCommit": self.sha,
                "sessionID": "remote-session", "turnCompleted": status != "STARTED", "exitCode": exit_code,
                "eventLog": "C:\\ops\\events.jsonl", "lastMessage": "C:\\ops\\result.md"}

    def test_atomic_replace_failure_preserves_previous_snapshot(self):
        path = self.root / "checkpoint.json"
        s.atomic_json(path, {"revision": 1})
        with patch.object(s.os, "replace", side_effect=OSError("simulated interruption")):
            with self.assertRaises(OSError):
                s.atomic_json(path, {"revision": 2})
        self.assertEqual(s.read_json(path), {"revision": 1})
        self.assertEqual(list(self.root.glob("*.tmp")), [])

    def test_os_lock_blocks_second_writer_and_releases(self):
        second = s.Store(self.store.directory)
        with self.store.writer():
            with self.assertRaisesRegex(s.Problem, "Another coordinator"):
                with second.writer():
                    self.fail("second writer acquired")
            self.assertEqual(s.read_json(self.store.lease_path)["state"], "ACTIVE")
        with second.writer():
            second.save(second.read())
        self.assertEqual(s.read_json(second.lease_path)["state"], "RELEASED")

    def test_exact_base_and_clean_worktree_required(self):
        task = self.task()
        task["base_sha"] = "0" * 40
        with self.assertRaisesRegex(s.Problem, "exact clean base"):
            s.enqueue(self.store, task)
        (self.repo / "unexpected.txt").write_text("unreviewed")
        with self.assertRaisesRegex(s.Problem, "exact clean base"):
            s.enqueue(self.store, self.task())

    def test_paths_cannot_escape_or_overlap(self):
        for path in ("../secret", "/etc/passwd", ".git/config", "A/../../B", "A//B", "A\\B", "*"):
            with self.subTest(path=path), self.assertRaises(s.Problem):
                s.owned_path(path)
        s.enqueue(self.store, self.task())
        with self.assertRaisesRegex(s.Problem, "overlaps"):
            s.enqueue(self.store, self.task("other", paths=["owned/nested/"]))
        s.enqueue(self.store, self.task("sibling", paths=["owned2/"]))

    def test_codex_exit_and_event_only_request_independent_review(self):
        s.enqueue(self.store, self.task())
        state = s.run(self.store, str(self.codex), budget_seconds=5)
        task = self.state_task(state)
        self.assertEqual(task["state"], "REVIEW_REQUIRED")
        self.assertEqual(task["attempts"][0]["session_id"], "fake-session")
        self.assertEqual(task["attempts"][0]["exit_code"], 0)
        self.assertTrue((Path(task["attempts"][0]["directory"]) / "exit.json").exists())
        self.assertNotIn("playtest_pass", task)

    def test_out_of_ownership_change_blocks_integration(self):
        s.enqueue(self.store, self.task(instructions="MODE_ESCAPE"))
        task = self.state_task(s.run(self.store, str(self.codex), budget_seconds=5))
        self.assertEqual(task["state"], "BLOCKED_OWNERSHIP")
        self.assertEqual(task["inspection"]["ownership_violations"], ["outside.txt"])
        with self.assertRaises(s.Problem):
            s.review(self.store, "work", "ACCEPTED", "worker claimed pass")

    def test_interrupted_without_exit_is_not_success(self):
        self.interrupted()
        state = s.reconcile(self.store)
        self.assertEqual(self.state_task(state)["state"], "INTERRUPTED")
        s.resume(self.store, "work")
        final = self.state_task(s.run(self.store, str(self.codex), budget_seconds=5))
        self.assertEqual(final["state"], "REVIEW_REQUIRED")
        self.assertEqual([item["number"] for item in final["attempts"]], [1, 2])
        self.assertNotEqual(final["attempts"][0]["directory"], final["attempts"][1]["directory"])

    def test_interrupted_with_exit_receipt_reconciles_without_rerun(self):
        self.interrupted({"exit_code": 0, "ended_at": s.stamp(), "reason": None})
        task = self.state_task(s.reconcile(self.store))
        self.assertEqual(task["state"], "REVIEW_REQUIRED")
        self.assertEqual(len(task["attempts"]), 1)

    def test_live_or_reused_pid_is_never_blindly_restarted(self):
        self.interrupted(process=s.identity(os.getpid()))
        self.assertEqual(self.state_task(s.reconcile(self.store))["state"], "ORPHAN_RUNNING")
        with self.assertRaisesRegex(s.Problem, "reconciliation"):
            s.run(self.store, str(self.codex), budget_seconds=1)
        with self.store.writer():
            state = self.store.read()
            state["tasks"]["work"]["attempts"][0]["process"]["start_marker"] = "wrong-start"
            self.store.save(state)
        self.assertEqual(self.state_task(s.reconcile(self.store))["state"], "INTERRUPTED")

    def test_resume_requires_diff_acknowledgement_and_two_retry_limit(self):
        s.enqueue(self.store, self.task(instructions="MODE_PARTIAL MODE_FAIL"))
        s.run(self.store, str(self.codex), budget_seconds=5)
        with self.assertRaisesRegex(s.Problem, "Partial changes"):
            s.resume(self.store, "work")
        for number in (2, 3):
            s.resume(self.store, "work", acknowledge_changes=True)
            state = s.run(self.store, str(self.codex), budget_seconds=5)
            self.assertEqual(len(self.state_task(state)["attempts"]), number)
        with self.assertRaisesRegex(s.Problem, "Retry budget exhausted"):
            s.resume(self.store, "work", acknowledge_changes=True)

    def test_deadline_terminates_only_owned_child_and_records_failure(self):
        task = self.task(instructions="MODE_HANG")
        task["max_run_seconds"] = 1
        s.enqueue(self.store, task)
        observed = self.state_task(s.run(self.store, str(self.codex), budget_seconds=3))
        self.assertEqual(observed["state"], "FAILED")
        self.assertEqual(observed["attempts"][0]["reason"], "Attempt deadline exceeded")
        self.assertIn(s.process_state(observed["attempts"][0]["process"]), ("GONE", "REUSED"))

    def test_worker_and_budget_caps_are_enforced(self):
        for kwargs in ({"max_workers": 4}, {"budget_seconds": 1201}):
            with self.assertRaises(s.Problem):
                s.run(self.store, str(self.codex), **kwargs)
        task = self.task()
        task["max_retries"] = 3
        with self.assertRaises(s.Problem):
            s.enqueue(self.store, task)

    def test_four_queued_tasks_run_in_batches_of_at_most_three(self):
        for number in range(4):
            s.enqueue(self.store, self.task(f"work-{number}", "MODE_WAIT", paths=[f"owned-{number}/"]))
        state = s.run(self.store, str(self.codex), max_workers=3, budget_seconds=5)
        events = []
        for task in state["tasks"].values():
            self.assertEqual(task["state"], "REVIEW_REQUIRED")
            lines = (Path(task["attempts"][0]["directory"]) / "events.jsonl").read_text().splitlines()
            for line in lines:
                item = json.loads(line)
                events.append((item["time"], 1 if item["type"] == "thread.started" else -1))
        current = peak = 0
        for _, change in sorted(events):
            current += change
            peak = max(peak, current)
        self.assertEqual(peak, 3)
        self.assertEqual(current, 0)

    def test_broad_path_claim_cannot_edit_frozen_contract(self):
        s.enqueue(self.store, self.task(paths=["Sources/RoomwaveArcade/"]))
        frozen = self.repo / "Sources/RoomwaveArcade/SurfContracts.swift"
        frozen.parent.mkdir(parents=True)
        frozen.write_text("unauthorized contract change")
        report = s.inspection(self.state_task())
        self.assertIn("Sources/RoomwaveArcade/SurfContracts.swift", report["ownership_violations"])

    def test_wd_pid_is_import_only_and_never_a_local_resume_target(self):
        receipt = self.wd_receipt()
        result = s.import_wd(self.store, receipt, "wd-device", "C:\\ops\\receipt.json", ["Sources/RoomwaveArcade/"])
        self.assertEqual(result["origin"]["kind"], "wd")
        self.assertNotIn("process", result)
        with self.assertRaisesRegex(s.Problem, "imported PIDs"):
            s.resume(self.store, receipt["taskID"])
        with self.assertRaisesRegex(s.Problem, "reconciliation"):
            s.run(self.store, str(self.codex), budget_seconds=1)
        receipt["status"] = "COMPLETED"
        receipt["turnCompleted"] = True
        receipt["heartbeatAtUtc"] = "2026-11-25T17:02:00Z"
        result = s.import_wd(self.store, receipt, "wd-device", "C:\\ops\\receipt.json", ["Sources/RoomwaveArcade/"])
        self.assertEqual(result["state"], "EVIDENCE_INCOMPLETE")
        receipt["exitCode"] = 0
        result = s.import_wd(self.store, receipt, "wd-device", "C:\\ops\\receipt.json", ["Sources/RoomwaveArcade/"])
        self.assertEqual(result["state"], "REVIEW_REQUIRED")

    def test_stale_remote_receipt_cannot_regress(self):
        receipt = self.wd_receipt("COMPLETED", 0)
        s.import_wd(self.store, receipt, "wd-device", "C:\\ops\\receipt.json", ["Sources/RoomwaveArcade/"])
        receipt["heartbeatAtUtc"] = "2026-11-25T17:00:30Z"
        with self.assertRaisesRegex(s.Problem, "Stale"):
            s.import_wd(self.store, receipt, "wd-device", "C:\\ops\\receipt.json", ["Sources/RoomwaveArcade/"])

    def test_release_claim_prevents_duplicate_even_with_different_sha(self):
        manifest = {"app_id": "6837899703", "version": "0.3.0", "build": "1003", "source_sha": self.sha}
        s.claim_release(self.store, manifest)
        with self.assertRaisesRegex(s.Problem, "already claimed"):
            s.claim_release(self.store, manifest)
        manifest["source_sha"] = "1" * 40
        with self.assertRaisesRegex(s.Problem, "already claimed"):
            s.claim_release(self.store, manifest)
        self.assertEqual(len(self.store.read()["releases"]), 1)

    def test_public_beta_requires_observed_url_and_exact_build(self):
        record = {"app_id": "6837899703", "version": "0.3.0", "build": "1003", "source_sha": self.sha}
        s.claim_release(self.store, record)
        record.update({"state": "PUBLIC_BETA", "observed_at": s.stamp(), "evidence": "Example assertion"})
        with self.assertRaisesRegex(s.Problem, "Apple build ID"):
            s.record_release(self.store, record)
        record["apple_build_id"] = "observed-build"
        with self.assertRaisesRegex(s.Problem, "observed Apple public"):
            s.record_release(self.store, record)

    def test_known_external_blockers_never_run(self):
        gate = {"schema_version": 1, "task_id": "external-contact", "kind": "gate", "base_sha": self.sha,
                "state": "BLOCKED_INPUT", "reason": "Review contact empty", "required_evidence": ["Real contact"],
                "observed_at": s.stamp()}
        s.enqueue(self.store, gate)
        state = s.run(self.store, str(self.codex), budget_seconds=1)
        self.assertEqual(state["tasks"]["external-contact"]["state"], "BLOCKED_INPUT")
        self.assertEqual(state["tasks"]["external-contact"]["attempts"], [])

    def test_cli_status_and_validation_exit_codes(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--state-dir", str(self.store.directory), "status"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["tasks"], {})
        result = subprocess.run([sys.executable, str(SCRIPT), "--state-dir", str(self.store.directory),
                                 "resume", "unknown"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Unknown task", json.loads(result.stderr)["error"])

    def test_workflow_observation_import_never_advances_gameplay(self):
        record = {"schema_version": 1, "origin": "github_actions", "source_sha": self.sha,
                  "workflow_run_id": 123, "workflow_name": "Unsigned iOS readiness", "conclusion": "success",
                  "observed_at": s.stamp(), "trigger": "workflow_run", "evidence_url": "https://example.invalid/run/123"}
        s.record_workflow(self.store, record)
        s.record_workflow(self.store, record)
        state = self.store.read()
        self.assertEqual(len(state["signals"]), 1)
        self.assertEqual(state["tasks"], {})
        self.assertEqual(state["releases"], {})
        record["source_sha"] = "1" * 40
        with self.assertRaisesRegex(s.Problem, "cannot change"):
            s.record_workflow(self.store, record)


if __name__ == "__main__":
    unittest.main()
