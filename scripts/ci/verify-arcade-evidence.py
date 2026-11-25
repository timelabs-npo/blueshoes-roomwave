#!/usr/bin/env python3
"""Validate actual native render/input receipts, never a human enjoyment gate."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
args = parser.parse_args()
version = (Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()
expected = ["home-dawn", "home-orbit", "home-midnight", "charged", "airborne", "landing", "paused", "results"]
receipts = []
for mode in expected:
    receipt = json.loads((args.directory / (mode + ".json")).read_text())
    assert receipt["mode"] == mode
    assert receipt["bundle"] == "org.timelabs.moleculefoundry"
    assert receipt["version"] == version
    assert isinstance(receipt["pid"], int) and receipt["pid"] > 0
    assert isinstance(receipt["run_generation"], int) and receipt["run_generation"] > 0
    assert receipt["capture_tick"] >= receipt["request_tick"] >= 0
    assert receipt["actual_arview_snapshot"] is True
    assert receipt["fallback_present"] is False
    assert set(receipt["renderable_layers"]) == {"Skin", "Coat", "SkeletonOverlay", "MuscleOverlay"}
    assert receipt["human_playtest"] is False
    filename = receipt["image_filename"]
    assert filename == Path(filename).name and filename.endswith(".png")
    pixels = (args.directory / filename).read_bytes()
    assert pixels.startswith(b"\x89PNG\r\n\x1a\n") and len(pixels) > 1024
    receipt["png_sha256"] = hashlib.sha256(pixels).hexdigest()
    if mode == "airborne":
        assert receipt["grounded_at_request"] is False
        assert receipt["foot_y_at_request"] > receipt["road_y_at_request"]
    receipts.append(receipt)
events = json.loads((args.directory / "events.json").read_text())
gameplay = [row for row in receipts if not row["mode"].startswith("home-")]
assert len({(row["pid"], row["course_id"], row["run_generation"]) for row in gameplay}) == 1
generation = gameplay[0]["run_generation"]
kinds = {kind for event in events if event["run_generation"] == generation for kind in event["events"]}
assert "takeoff" in kinds and ("landing" in kinds or "perfectLanding" in kinds)
summary = {"version": version, "native_input_and_render_verified": True,
           "human_playtest": False, "device_performance_measured": False,
           "event_kinds": sorted(kinds), "captures": receipts}
(args.directory / "evidence-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({k: v for k, v in summary.items() if k != "captures"}))
