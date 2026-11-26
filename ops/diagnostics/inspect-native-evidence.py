#!/usr/bin/env python3
"""Inspect exact pinned native attempts without changing original evidence bytes."""
import base64, hashlib, io, json, os, re, signal, stat, sys, tempfile, time, urllib.error, urllib.parse, urllib.request, zipfile
from pathlib import Path, PurePosixPath

REPO = "timelabs-npo/blueshoes-roomwave"
PINS = {
    15082062466: [45739502906,2,"751726dae45137ca36457b72a83966b8ca455f42","b876756b66876c4f9deb92946a2b3bc0c22508f2","roomwave-native-review",21528611,"9b97fae5f03bef31194b0f720fb1bda662029e009e13a96a87b41d5397fddac4"],
    15080354005: [45739502906,1,"751726dae45137ca36457b72a83966b8ca455f42","b876756b66876c4f9deb92946a2b3bc0c22508f2","roomwave-arcade-evidence",6337,"2d2c40785510951087df0d82660e1bfcbaa2c517267790009e7a5cc7c727c36f"],
    15076946459: [45729132932,1,"81a92749d5b08ad2c525db9e45715051604d7eec","3eb06083436a3aabc169dda0a544215f6ebc407e","roomwave-native-review",18399086,"c1ad6f3a78f1f0d1102efe32fe597f75a0f2bf6d68fd2c392de26b68b74ee701"],
    15076614755: [45729709518,1,"1fa4d86072734bacbc3e6a8c66ff310033fdb9b3","cf7d08cffb85a242ae5784c3988dc9b8b300224e","roomwave-native-review",4577229,"bde5a6dd8b9c58864cfcada6d0e4b2c51f5950c858b5c0bd36e25bcda362fc2a"],
    15076488863: [45729132932,1,"81a92749d5b08ad2c525db9e45715051604d7eec","3eb06083436a3aabc169dda0a544215f6ebc407e","roomwave-arcade-evidence",485855549,"baeeb54cbe43401507a8201aab2cca36c8746492de0462fd1de4a8238b13207d"],
}
DEADLINE, OUTPUT = time.monotonic() + 150, 0
class Blocked(Exception): pass
def require(ok, reason):
    if not ok: raise Blocked(reason)
def remaining():
    value = DEADLINE - time.monotonic()
    require(value > 0, "overall_deadline")
    return min(20, value)
def clean(value):
    if isinstance(value, dict): return {str(k)[:160]: clean(v) for k, v in list(value.items())[:100]}
    if isinstance(value, (list, tuple)): return [clean(v) for v in value[:300]]
    if not isinstance(value, str): return value
    value = re.sub(r"https?://[^\s\"<>]+", "<url>", value)
    value = re.sub(r"(?i)\bBearer\s+\S+|github_pat_[A-Za-z0-9_]+|\bgh[pousr]_[A-Za-z0-9_]+|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", "<credential>", value)
    value = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "<email>", value)
    value = re.sub(r"/(?:Users|home)/[^/\s]+", "/<user>", value)
    return value[:700]
def emit(value, marker="EVIDENCE_JSON", raw=False):
    global OUTPUT
    line = marker + " " + json.dumps(value if raw else clean(value), separators=(",", ":"), ensure_ascii=True)
    require(OUTPUT + len(line.encode()) + 1 <= 680000, "output_budget")
    print(line, flush=True); OUTPUT += len(line.encode()) + 1
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl): return None
OPENER = urllib.request.build_opener(NoRedirect())
def api(path, redirect=False):
    require(path.startswith("/repos/" + REPO + "/"), "api_scope")
    request = urllib.request.Request("https://api.github.com" + path, headers={
        "Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with OPENER.open(request, timeout=remaining()) as response:
            require(not redirect, "artifact_redirect_missing")
            data = response.read(2097153); require(len(data) <= 2097152, "metadata_size")
            return json.loads(data)
    except urllib.error.HTTPError as error:
        if redirect and error.code in (302, 303, 307, 308): return error.headers.get("Location", "")
        raise Blocked("github_http_" + str(error.code)) from None
def allowed(url):
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    return (parsed.scheme == "https" and parsed.port in (None, 443) and not parsed.username
            and not parsed.password and not parsed.fragment and
            (bool(re.fullmatch(r"productionresultssa[0-9]+\.blob\.core\.windows\.net", host))
             or host in {"objects.githubusercontent.com", "pipelines.actions.githubusercontent.com", "results-receiver.actions.githubusercontent.com"}))
def download(url, expected, digest):
    require(expected <= 536870912, "download_expected_size")
    for hop in range(4):
        require(allowed(url), "download_host_not_allowlisted")
        try:
            with OPENER.open(urllib.request.Request(url), timeout=remaining()) as response:
                length = response.headers.get("Content-Length")
                require(length is None or int(length) == expected, "download_content_length")
                output, size, hasher = tempfile.TemporaryFile(), 0, hashlib.sha256()
                try:
                    while True:
                        remaining(); chunk = response.read(1048576)
                        if not chunk: break
                        size += len(chunk); require(size <= expected, "download_size")
                        hasher.update(chunk); output.write(chunk)
                    require(size == expected and hasher.hexdigest() == digest, "artifact_bytes_digest")
                    output.seek(0)
                    return output
                except BaseException:
                    output.close()
                    raise
        except urllib.error.HTTPError as error:
            if error.code not in (301, 302, 303, 307, 308): raise Blocked("download_http_" + str(error.code)) from None
            url = urllib.parse.urljoin(url, error.headers.get("Location", ""))
    raise Blocked("download_redirect_limit")
def main():
    require(len(sys.argv) == 2, "request_argument")
    path = Path(sys.argv[1])
    require(path.parent == Path("ops/diagnostics") and path.suffix == ".json" and not path.is_symlink() and path.stat().st_size <= 4096, "request_path")
    request = json.loads(path.read_text()); pin = PINS.get(request.get("artifact_id"))
    require(pin is not None, "unapproved_artifact")
    run_id, attempt, source, tree, artifact_name, size, digest = pin
    artifact_id = request["artifact_id"]
    expected = dict(schema_version=1, repository=REPO, run_id=run_id, run_attempt=attempt,
                    source_sha=source, tree_sha=tree, artifact_id=artifact_id,
                    artifact_name=artifact_name, size_bytes=size, sha256=digest)
    require(set(request) == set(expected) and all(type(request[k]) is type(v) and request[k] == v for k, v in expected.items()), "request_pin_mismatch")
    prefix = "/repos/" + REPO
    run = api(prefix + "/actions/runs/" + str(run_id) + "/attempts/" + str(attempt))
    require(run["id"] == request["run_id"] and run["head_sha"] == source and run["run_attempt"] == attempt and run["status"] == "completed", "run_identity")
    commit = api(prefix + "/git/commits/" + source)
    require(commit["sha"] == source and commit["tree"]["sha"] == tree, "source_tree")
    artifact = api(prefix + "/actions/artifacts/" + str(artifact_id))
    require(artifact["id"] == artifact_id and artifact["name"] == expected["artifact_name"] and not artifact["expired"], "artifact_identity")
    require(artifact["workflow_run"]["id"] == request["run_id"] and artifact["workflow_run"]["head_sha"] == source, "artifact_run")
    require(artifact["size_in_bytes"] == size and artifact.get("digest") == "sha256:" + digest, "artifact_metadata_digest")
    require(run["run_started_at"] <= artifact["created_at"] <= run["updated_at"], "artifact_outside_pinned_attempt")
    data = download(api(prefix + "/actions/artifacts/" + str(artifact_id) + "/zip", True), size, digest)
    archive = zipfile.ZipFile(data); infos = archive.infolist()
    require(len(infos) <= 2000 and sum(x.file_size for x in infos) <= 805306368, "zip_total_bounds")
    names, folded = {}, set()
    for entry in infos:
        remaining()
        name, mode = entry.filename, entry.external_attr >> 16
        require(entry.orig_filename == name and name and len(name) <= 512 and not name.startswith("/") and "\\" not in name and ":" not in name and "\0" not in name and ".." not in PurePosixPath(name).parts, "zip_path")
        require(name.casefold() not in folded and not entry.flag_bits & 1 and entry.file_size <= 536870912, "zip_member_bounds")
        require(not stat.S_ISLNK(mode) and stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), "zip_member_type")
        names[name] = entry; folded.add(name.casefold())
    def one(basename):
        found = [n for n in names if PurePosixPath(n).name == basename]
        require(len(found) == 1, "missing_or_ambiguous_" + basename)
        return found[0]
    def text(name, limit=262144):
        require(names[name].file_size <= limit, "selected_text_size")
        return archive.read(name).decode("utf-8", errors="replace")
    if artifact_id == 15080354005:
        # This exact pinned attempt stopped before the normal evidence directory existed.
        required = {"native-run-start.json", "simulators.json", "simulator-runtimes.json",
                    "simulator-selection.json", "runner-identity.json", "runner-metal.json"}
        require(len(names) == len(required)
                and {PurePosixPath(name).name for name in names} == required, "boot_inventory_mismatch")
        documents = {name: json.loads(text(one(name))) for name in sorted(required)}
        start = documents["native-run-start.json"]
        checkout = start["source_sha"]
        require(isinstance(checkout, str) and re.fullmatch(r"[0-9a-f]{40}", checkout), "checkout_sha")
        actual = commit if checkout == source else api(prefix + "/git/commits/" + checkout)
        require(actual["sha"] == checkout and actual["tree"]["sha"] == tree
                and (checkout == source or any(p["sha"] == source for p in actual["parents"])),
                "checkout_tree_or_parent")
        require(str(start["run_id"]) == str(run_id) and start["purpose"] == "sdk-matched-native-gate"
                and start.get("requested_runtime") is None, "start_identity")
        data.seek(0)
        original = data.read(size + 1)
        require(len(original) == size and hashlib.sha256(original).hexdigest() == digest,
                "preserved_original_digest")
        destination = Path("build/diagnostic-originals")
        destination.mkdir(parents=True, exist_ok=True)
        stem = "native-run-45739502906-attempt-1-artifact-15080354005"
        with (destination / (stem + ".zip")).open("xb") as saved:
            saved.write(original)
        receipt = {"schema_version": 1, "verified": expected, "checkout_sha": checkout,
                   "original_zip": stem + ".zip", "original_bytes_preserved": True,
                   "scope": "pre-native-simulator-readiness", "native_evidence_verified": False}
        with (destination / (stem + ".json")).open("x", encoding="utf-8") as saved:
            saved.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        emit({**receipt, "conclusion": run["conclusion"], "event": run["event"],
              "checkout_source": "native-run-start.json",
              "absent": ["source-sha.txt", "native-test.log", "boot log", "xcresult",
                         "ARView captures", "UI attachments", "evidence-collection.json"]})
        emit({"inventory": [{"name": n, "bytes": entry.file_size} for n, entry in sorted(names.items())]})
        for name, value in documents.items():
            emit({"entry": one(name), "value": value})
        return
    checkout = text(one("source-sha.txt")).strip()
    require(re.fullmatch(r"[0-9a-f]{40}", checkout), "checkout_sha")
    actual = commit if checkout == source else api(prefix + "/git/commits/" + checkout)
    require(actual["tree"]["sha"] == tree and (checkout == source or any(p["sha"] == source for p in actual["parents"])), "checkout_tree_or_parent")
    start = json.loads(text(one("native-run-start.json")))
    require(start["source_sha"] == checkout and str(start["run_id"]) == str(request["run_id"]) and start["purpose"] == "sdk-matched-native-gate" and start.get("requested_runtime") is None, "start_identity")
    emit({"verified": expected, "conclusion": run["conclusion"], "event": run["event"], "checkout_sha": checkout, "native_run_start": start})
    emit({"inventory": [{"name": n, "bytes": i.file_size} for n, i in sorted(names.items())][:300], "total_entries": len(names), "inventory_truncated": len(names) > 300})
    manifests, ar_candidates = [], {}
    required_modes = ("home-dawn", "home-orbit", "home-midnight", "charged", "airborne", "landing", "paused", "results")
    selected = [n for n in sorted(names) if PurePosixPath(n).name in {"runner-identity.json", "runner-metal.json", "simulator-identity.json", "unsigned-archive-identity.json", "simulator-selection.json", "evidence-collection.json", "container.log", "diagnostics.json", "diagnostic-observer.log", "recording-observer.log", "attachments-export.log", "metal-diagnostics.log", "evidence-summary.json", "events.json", "home-dawn.json", "home-orbit.json", "home-midnight.json", "charged.json", "airborne.json", "landing.json", "paused.json", "results.json"} or ("live-diagnostics/" in n and n.endswith(".json")) or ("ui-attachments/" in n and n.endswith("manifest.json")) or n.endswith("metal-diagnostics/index.json")]
    selected = [n for n in selected if "/capture-checkpoints/" not in n]
    for name in selected[:40]:
        remaining()
        if names[name].file_size > 262144: emit({"entry": name, "omitted": "text_size_limit"}); continue
        value = text(name)
        if name.endswith(".json"):
            try: value = json.loads(value)
            except json.JSONDecodeError: value = {"invalid_json": True}
        if "ui-attachments/" in name and name.endswith("manifest.json"): manifests.append((name, value))
        emit({"entry": name, "sha256": hashlib.sha256(archive.read(name)).hexdigest(),
              "value": value if not isinstance(value, str) else value.splitlines()[:40]})
    for name in sorted(names):
        if not name.endswith("live-diagnostics/observer.jsonl"): continue
        rows = [json.loads(line) for line in text(name, 1048576).splitlines() if line.strip()]
        chosen = rows if len(rows) <= 100 else rows[:20] + rows[-80:]
        stages = []
        previous = None
        for row in rows:
            trace = row.get("trace") or {}
            state = tuple(trace.get(k) for k in ("stage", "screen", "is_loading", "is_active"))
            if row.get("event") != "trace_observed" or state != previous:
                stages.append(row)
            previous = state
        emit({"entry": name, "total_records": len(rows), "records": chosen, "stage_transitions": stages[:200], "stage_transitions_total": len(stages)})
    for name in sorted(names):
        if "metal-diagnostics/" not in name or not name.endswith(".ips"): continue
        raw = text(name, 4194304).lstrip()
        decoder = json.JSONDecoder()
        first, offset = decoder.raw_decode(raw)
        rest = raw[offset:].lstrip()
        report = decoder.raw_decode(rest)[0] if rest else first
        details = {key: report.get(key) for key in ("procName", "pid", "parentProc", "parentPid", "captureTime", "exception", "termination", "asi", "faultingThread")}
        threads = report.get("threads") or []
        fault = report.get("faultingThread")
        details["faulting_frames"] = threads[fault].get("frames", [])[:20] if type(fault) is int and 0 <= fault < len(threads) else []
        details["images"] = [{"name": x.get("name"), "index": i} for i, x in enumerate(report.get("usedImages") or [])]
        emit({"entry": name, "sha256": hashlib.sha256(archive.read(name)).hexdigest(), "report": details})
    checkpoint_latest = [n for n in names if n.endswith("/capture-checkpoints/latest.json")]
    require(len(checkpoint_latest) <= 1, "ambiguous_checkpoint_latest")
    if checkpoint_latest:
        latest_name = checkpoint_latest[0]
        latest = json.loads(text(latest_name, 65536))
        context, identity = latest["context"], latest["identity"]
        require(context.get("source_sha") == checkout and context.get("run_id") == str(run_id),
                "checkpoint_run_identity")
        launch = identity.get("launch_id")
        require(isinstance(launch, str) and re.fullmatch(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", launch),
                "checkpoint_launch_identity")
        manifest_name = str(PurePosixPath(latest_name).parent / launch / "manifest.json")
        emit({"entry": latest_name, "sha256": hashlib.sha256(archive.read(latest_name)).hexdigest(), "value": latest})
        if manifest_name in names:
            manifest = json.loads(text(manifest_name, 262144))
            require(manifest.get("context") == context and manifest.get("identity") == identity,
                    "checkpoint_manifest_identity")
            records = manifest["files"]
            allowed_names = {mode + suffix for mode in required_modes + ("running",) for suffix in (".json", ".png")}
            allowed_names |= {"events.json", "diagnostics.json"}
            require(isinstance(records, dict) and set(records) <= allowed_names, "checkpoint_file_allowlist")
            verified_files = {}
            for original_name, record in records.items():
                remaining()
                expected_digest = record["sha256"]
                require(isinstance(expected_digest, str) and re.fullmatch(r"[0-9a-f]{64}", expected_digest), "checkpoint_digest")
                expected_name = original_name[:-5] + "-" + expected_digest + ".json" if original_name in {"events.json", "diagnostics.json"} else original_name
                require(record.get("stored_as", original_name) == expected_name, "checkpoint_storage_name")
                entry = str(PurePosixPath(manifest_name).parent / expected_name)
                require(entry in names and names[entry].file_size <= (33554432 if original_name.endswith(".png") else 524288), "checkpoint_member_bounds")
                payload = archive.read(entry)
                require(record["bytes"] == len(payload) and hashlib.sha256(payload).hexdigest() == expected_digest,
                        "checkpoint_member_hash")
                verified_files[original_name] = entry
            emit({"entry": manifest_name, "sha256": hashlib.sha256(archive.read(manifest_name)).hexdigest(),
                  "value": manifest, "member_hashes_verified": len(verified_files), "native_gate_inferred": False})
            if not latest.get("ambiguous_launch"):
                for mode in required_modes:
                    if mode + ".json" in verified_files and mode + ".png" in verified_files:
                        receipt = json.loads(text(verified_files[mode + ".json"], 65536))
                        ar_candidates[mode] = (verified_files[mode + ".png"], receipt, "latest_checkpoint")
        else:
            emit({"checkpoint_manifest": manifest_name, "omitted": "latest_launch_has_no_manifest"})
    evidence_parent = PurePosixPath(one("source-sha.txt")).parent
    for mode in required_modes:
        receipt_name, image_name = str(evidence_parent / (mode + ".json")), str(evidence_parent / (mode + ".png"))
        if receipt_name in names and image_name in names:
            ar_candidates[mode] = (image_name, json.loads(text(receipt_name, 65536)), "promoted_capture")
    native_entries = [n for n in names if PurePosixPath(n).name == "native-test.log"]
    require(len(native_entries) <= 1, "ambiguous_native_log")
    if not native_entries:
        emit({"entry": "native-test.log", "omitted": "not_in_original_artifact", "native_gate_inferred": False})
    else:
        native = native_entries[0]
        pattern = re.compile(r"AVATAR_MATERIAL_STYLE|XActivityClientTests|Test (?:Case|Suite)|Executed \d|TEST (?:SUCCEEDED|FAILED)|error:|GPU|METAL|SimMetalHost|Compiler failed|renderPipeline|render.target|Critical process|not running|Timed out|timeout", re.I)
        native_lines = text(native, 33554432).splitlines()
        asset_lines = [(i + 1, line[:1000]) for i, line in enumerate(native_lines) if "ASSET_TREE " in line]
        emit({"asset_tree_lines": asset_lines[:180], "asset_tree_total": len(asset_lines)})
        hits = [(i + 1, line[:650]) for i, line in enumerate(native_lines) if pattern.search(line)]
        ui_start = next((i for i, line in enumerate(native_lines) if "Test Case '-[RoomwaveUITests.ArcadeFlowUITests" in line and "started." in line), None)
        if ui_start is not None:
            ui_end = next((i for i in range(ui_start + 1, len(native_lines)) if "Test Case '-[RoomwaveUITests.ArcadeFlowUITests" in native_lines[i] and ("passed (" in native_lines[i] or "failed (" in native_lines[i])), min(ui_start + 249, len(native_lines) - 1))
            emit({"ui_test_lines": [(i + 1, native_lines[i][:650]) for i in range(ui_start, min(ui_end + 1, ui_start + 250))]})
        chosen = hits if len(hits) <= 180 else hits[:75] + hits[-105:]
        emit({"xactivity_test_lines": [row for row in hits if "XActivityClientTests" in row[1]][:60]})
        emit({"entry": native, "matching_lines": len(hits), "omitted_matching_lines": len(hits)-len(chosen), "lines": chosen})
    try: from PIL import Image
    except ImportError: emit({"previews": "Pillow_not_installed"}); return
    Image.MAX_IMAGE_PIXELS = 8000000
    candidates = []
    def walk(node, parent):
        if isinstance(node, dict):
            for value in node.values():
                if isinstance(value, str) and value.endswith(".png") and PurePosixPath(value).name == value:
                    candidate = str(PurePosixPath(parent).parent / value)
                    if candidate in names: candidates.append((json.dumps(node), candidate))
            for value in node.values(): walk(value, parent)
        elif isinstance(node, list):
            for value in node: walk(value, parent)
    for name, value in manifests: walk(value, name)
    def preview(label, name, category, thumbnail, quality, encoded_limit, receipt=None):
        remaining()
        require(names[name].file_size <= 33554432, "preview_member_size")
        original = archive.read(name)
        with Image.open(io.BytesIO(original)) as decoded:
            require(decoded.format == "PNG" and decoded.width * decoded.height <= 8000000, "preview_png_bounds")
            dimensions = decoded.size
            if receipt is not None:
                require(receipt.get("schema_version") == 4 and receipt.get("mode") == label
                        and receipt.get("image_filename") == label + ".png"
                        and receipt.get("actual_arview_snapshot") is True
                        and (receipt.get("width"), receipt.get("height")) == dimensions, "preview_receipt_mismatch")
            image = decoded.convert("RGB")
        image.thumbnail(thumbnail, Image.Resampling.LANCZOS)
        output = io.BytesIO(); image.save(output, "JPEG", quality=quality)
        encoded = base64.b64encode(output.getvalue()).decode()
        if len(encoded) > encoded_limit or OUTPUT + len(encoded) + 2048 > 680000:
            emit({"preview": label, "category": category, "omitted": "preview_output_budget"}); return
        emit({"label": label, "category": category, "entry": clean(name),
              "original_sha256": hashlib.sha256(original).hexdigest(), "original_dimensions": dimensions,
              "preview_dimensions": image.size, "transform": "RGB; LANCZOS thumbnail; JPEG quality" + str(quality),
              "native_gate_inferred": False, "jpeg_base64": encoded}, "EVIDENCE_PREVIEW", True)
    for mode in required_modes:
        if mode not in ar_candidates:
            emit({"preview": mode, "category": "ARView", "omitted": "no_original_receipt_and_image_pair"}); continue
        name, receipt, origin = ar_candidates[mode]
        preview(mode, name, "ARView:" + origin, (270, 550), 66, 45000, receipt)
    used = set()
    for label, expression in [("home", r"01-home|home-neon|home-dawn"), ("play", r"04-release-and-air")]:
        match = next(((description, name) for description, name in candidates if name not in used and re.search(expression, description, re.I)), None)
        if not match: emit({"preview": label, "category": "UI_attachment", "omitted": "no_matching_UI_attachment"}); continue
        description, name = match
        preview(label, name, "UI_attachment", (360, 734), 68, 90000)
        used.add(name)
def deadline_signal(signum, frame): raise Blocked("overall_deadline")
signal.signal(signal.SIGALRM, deadline_signal); signal.alarm(160)
try:
    main()
except Exception as error:
    emit({"blocked": str(error) if isinstance(error, Blocked) else "inspection_exception", "exception_type": type(error).__name__})
    sys.exit(1)
