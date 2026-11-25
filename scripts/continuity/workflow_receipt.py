#!/usr/bin/env python3
"""Write a GitHub event observation, without executing any event-provided text."""
import datetime
import json
import os
from pathlib import Path
import sys


def positive_integer(value, name):
    if isinstance(value, bool) or not str(value).isdigit() or int(value) < 1:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


def build_receipt(event, environment, observed_at=None):
    """The observed run and the observer's run may have different attempts.

    workflow_run fields come exclusively from its payload. In particular, using
    GITHUB_RUN_ATTEMPT there would attribute the observer's retry to its subject.
    A receipt emitted inside our own job cannot attest that job's final result.
    """
    trigger = environment["GITHUB_EVENT_NAME"]
    repository = environment["GITHUB_REPOSITORY"]
    if trigger == "workflow_run":
        source = event["workflow_run"]
        run_id = positive_integer(source["id"], "workflow_run.id")
        attempt = positive_integer(source["run_attempt"], "workflow_run.run_attempt")
        updated_at = source["updated_at"]
        if not isinstance(updated_at, str):
            raise ValueError("workflow_run.updated_at requires an observed timestamp")
        parsed = datetime.datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("workflow_run.updated_at requires a timezone")
        status = source["status"]
        conclusion = source["conclusion"]
        name, sha = source["name"], source["head_sha"]
        attempt_evidence = "workflow_run_payload"
    else:
        run_id = positive_integer(environment["GITHUB_RUN_ID"], "GITHUB_RUN_ID")
        attempt = positive_integer(environment["GITHUB_RUN_ATTEMPT"], "GITHUB_RUN_ATTEMPT")
        name, sha = environment["GITHUB_WORKFLOW"], environment["GITHUB_SHA"]
        status, conclusion = "in_progress", "CONTINUITY_CHECKS_OBSERVED"
        updated_at = None  # No GitHub API timestamp is available in the environment.
        attempt_evidence = "github_run_environment"
    return {
        "schema_version": 2,
        "origin": "github_actions",
        "trigger": trigger,
        "workflow_run_id": run_id,
        "run_attempt": attempt,
        "attempt_evidence": attempt_evidence,
        "run_status": status,
        "run_updated_at": updated_at,
        "workflow_name": name,
        "source_sha": sha,
        "conclusion": conclusion,
        "observed_at": observed_at or datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "evidence_url": f"https://github.com/{repository}/actions/runs/{run_id}/attempts/{attempt}",
    }


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        receipt = build_receipt(event, os.environ)
        output = Path(sys.argv[1])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(receipt, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        return 0
    except (KeyError, TypeError, ValueError, IndexError, OSError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
