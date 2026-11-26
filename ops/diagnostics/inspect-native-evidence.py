#!/usr/bin/env python3
"""Inspect two pinned native artifacts without changing their original bytes."""
import base64, hashlib, io, json, os, re, signal, stat, sys, tempfile, time, urllib.error, urllib.parse, urllib.request, zipfile
from pathlib import Path, PurePosixPath

REPO = "timelabs-npo/blueshoes-roomwave"
PINS = {
    15076946459: [45729132932,"81a92749d5b08ad2c525db9e45715051604d7eec","3eb06083436a3aabc169dda0a544215f6ebc407e","roomwave-native-review",18399086,"c1ad6f3a78f1f0d1102efe32fe597f75a0f2bf6d68fd2c392de26b68b74ee701"],
    15076614755: [45729709518,"1fa4d86072734bacbc3e6a8c66ff310033fdb9b3","cf7d08cffb85a242ae5784c3988dc9b8b300224e","roomwave-native-review",4577229,"bde5a6dd8b9c58864cfcada6d0e4b2c51f5950c858b5c0bd36e25bcda362fc2a"],
    15076488863: [45729132932,"81a92749d5b08ad2c525db9e45715051604d7eec","3eb06083436a3aabc169dda0a544215f6ebc407e","roomwave-arcade-evidence",485855549,"baeeb54cbe43401507a8201aab2cca36c8746492de0462fd1de4a8238b13207d"],
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
    run_id, source, tree, artifact_name, size, digest = pin
    artifact_id = request["artifact_id"]
    expected = dict(schema_version=1, repository=REPO, run_id=run_id, run_attempt=1,
                    source_sha=source, tree_sha=tree, artifact_id=artifact_id,
                    artifact_name=artifact_name, size_bytes=size, sha256=digest)
    require(set(request) == set(expected) and all(type(request[k]) is type(v) and request[k] == v for k, v in expected.items()), "request_pin_mismatch")
    prefix = "/repos/" + REPO
    run = api(prefix + "/actions/runs/" + str(request["run_id"]))
    require(run["id"] == request["run_id"] and run["head_sha"] == source and run["run_attempt"] == 1 and run["status"] == "completed", "run_identity")
    commit = api(prefix + "/git/commits/" + source)
    require(commit["sha"] == source and commit["tree"]["sha"] == tree, "source_tree")
    artifact = api(prefix + "/actions/artifacts/" + str(artifact_id))
    require(artifact["id"] == artifact_id and artifact["name"] == expected["artifact_name"] and not artifact["expired"], "artifact_identity")
    require(artifact["workflow_run"]["id"] == request["run_id"] and artifact["workflow_run"]["head_sha"] == source, "artifact_run")
    require(artifact["size_in_bytes"] == size and artifact.get("digest") == "sha256:" + digest, "artifact_metadata_digest")
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
    checkout = text(one("source-sha.txt")).strip()
    require(re.fullmatch(r"[0-9a-f]{40}", checkout), "checkout_sha")
    actual = commit if checkout == source else api(prefix + "/git/commits/" + checkout)
    require(actual["tree"]["sha"] == tree and (checkout == source or any(p["sha"] == source for p in actual["parents"])), "checkout_tree_or_parent")
    start = json.loads(text(one("native-run-start.json")))
    require(start["source_sha"] == checkout and str(start["run_id"]) == str(request["run_id"]) and start["purpose"] == "sdk-matched-native-gate" and start.get("requested_runtime") is None, "start_identity")
    emit({"verified": expected, "conclusion": run["conclusion"], "event": run["event"], "checkout_sha": checkout, "native_run_start": start})
    emit({"inventory": [{"name": n, "bytes": i.file_size} for n, i in sorted(names.items())][:300], "total_entries": len(names), "inventory_truncated": len(names) > 300})
    manifests = []
    selected = [n for n in sorted(names) if PurePosixPath(n).name in {"runner-identity.json", "simulator-selection.json", "container.log", "diagnostics.json", "diagnostic-observer.log", "recording-observer.log", "attachments-export.log", "metal-diagnostics.log", "evidence-summary.json", "events.json", "home-dawn.json", "home-orbit.json", "home-midnight.json", "charged.json", "airborne.json", "landing.json", "paused.json", "results.json"} or ("live-diagnostics/" in n and n.endswith(".json")) or ("ui-attachments/" in n and n.endswith("manifest.json")) or n.endswith("metal-diagnostics/index.json")]
    for name in selected[:40]:
        remaining()
        if names[name].file_size > 262144: emit({"entry": name, "omitted": "text_size_limit"}); continue
        value = text(name)
        if name.endswith(".json"):
            try: value = json.loads(value)
            except json.JSONDecodeError: value = {"invalid_json": True}
        if "ui-attachments/" in name and name.endswith("manifest.json"): manifests.append((name, value))
        emit({"entry": name, "value": value if not isinstance(value, str) else value.splitlines()[:40]})
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
    native = one("native-test.log")
    pattern = re.compile(r"XActivityClientTests|Test (?:Case|Suite)|Executed \d|TEST (?:SUCCEEDED|FAILED)|error:|GPU|METAL|SimMetalHost|Compiler failed|renderPipeline|render.target|Critical process|not running|Timed out|timeout", re.I)
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
    used = set()
    for label, expression in [("home", r"01-home|home-neon|home-dawn"), ("play", r"04-release-and-air")]:
        match = next(((description, name) for description, name in candidates if name not in used and re.search(expression, description, re.I)), None)
        if not match: emit({"preview": label, "omitted": "no_matching_UI_attachment"}); continue
        description, name = match; original = archive.read(name); image = Image.open(io.BytesIO(original))
        require(image.format == "PNG" and image.width * image.height <= 8000000, "preview_png_bounds")
        dimensions = image.size; image = image.convert("RGB"); image.thumbnail((540, 1100), Image.Resampling.LANCZOS)
        output = io.BytesIO(); image.save(output, "JPEG", quality=72); encoded = base64.b64encode(output.getvalue()).decode()
        if len(encoded) > 180000: emit({"preview": label, "omitted": "preview_size_limit"}); continue
        emit({"label": label, "entry": clean(name), "original_sha256": hashlib.sha256(original).hexdigest(), "original_dimensions": dimensions, "preview_dimensions": image.size, "transform": "RGB; LANCZOS thumbnail within540x1100; JPEG quality72", "jpeg_base64": encoded}, "EVIDENCE_PREVIEW", True); used.add(name)
def deadline_signal(signum, frame): raise Blocked("overall_deadline")
signal.signal(signal.SIGALRM, deadline_signal); signal.alarm(160)
try:
    main()
except Exception as error:
    emit({"blocked": str(error) if isinstance(error, Blocked) else "inspection_exception", "exception_type": type(error).__name__})
    sys.exit(1)
