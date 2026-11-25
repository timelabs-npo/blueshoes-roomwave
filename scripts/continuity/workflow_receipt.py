#!/usr/bin/env python3
"""Write a GitHub event observation, without executing any event-provided text."""
import datetime
import json
import os
from pathlib import Path
import sys


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    trigger = os.environ["GITHUB_EVENT_NAME"]
    source = event.get("workflow_run", {}) if trigger == "workflow_run" else {}
    run_id = int(source.get("id", os.environ["GITHUB_RUN_ID"]))
    repository = os.environ["GITHUB_REPOSITORY"]
    receipt = {
        "schema_version": 1,
        "origin": "github_actions",
        "trigger": trigger,
        "workflow_run_id": run_id,
        "workflow_name": source.get("name", os.environ["GITHUB_WORKFLOW"]),
        "source_sha": source.get("head_sha", os.environ["GITHUB_SHA"]),
        "conclusion": source.get("conclusion", "CONTINUITY_CHECKS_OBSERVED"),
        "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "evidence_url": f"https://github.com/{repository}/actions/runs/{run_id}",
    }
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
