#!/usr/bin/env python3
"""Wait for this app process to render the requested real pilot scene."""
import argparse
import json
import hashlib
import shutil
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("marker", type=Path)
parser.add_argument("mode", choices=("preview", "race"))
parser.add_argument("--pid", required=True, type=int)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--image-output", required=True, type=Path)
args = parser.parse_args()
expected_layers = {"Skin", "Coat", "SkeletonOverlay", "MuscleOverlay"}
deadline = time.monotonic() + 45
last = None
while time.monotonic() < deadline:
    try:
        last = json.loads(args.marker.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        time.sleep(0.2)
        continue
    if last.get("pid") != args.pid:
        time.sleep(0.2)
        continue
    if last.get("state") == "failed":
        raise SystemExit("The real app did not render the bundled rider: " + json.dumps(last))
    if args.mode == "race" and last.get("mode") == "result":
        raise SystemExit("The race ended before a valid capture: " + json.dumps(last))
    if last.get("state") == "ready" and last.get("mode") == args.mode:
        assert last.get("bundle") == "org.timelabs.moleculefoundry", last
        assert last.get("version") == "0.2.0" and last.get("build") == "1", last
        assert set(last.get("renderable_layers", [])) == expected_layers, last
        assert set(last.get("glide_layers", [])) == expected_layers, last
        assert last.get("load_completed") is True and last.get("fallback_present") is False, last
        assert last.get("scene_updates_after_load", 0) >= 2, last
        assert last.get("snapshot_rendered") is True, last
        assert last.get("capture_mode") == args.mode and last.get("generation"), last
        assert last.get("capture_tick", -1) >= last.get("request_tick", 0), last
        if args.mode == "race":
            assert last.get("race_running_at_capture") is True, last
        filename = last.get("image_filename", "")
        assert filename == Path(filename).name and filename.endswith(".png"), last
        image = args.marker.parent / filename
        pixels = image.read_bytes()
        assert pixels.startswith(b"\x89PNG\r\n\x1a\n"), "Missing captured PNG"
        shutil.copyfile(image, args.image_output)
        last["captured_png_sha256"] = hashlib.sha256(pixels).hexdigest()
        args.output.write_text(json.dumps(last, indent=2, sort_keys=True) + "\n")
        print(json.dumps(last, sort_keys=True))
        break
    time.sleep(0.2)
else:
    raise SystemExit("Timed out waiting for the real " + args.mode + " scene: " + json.dumps(last))
