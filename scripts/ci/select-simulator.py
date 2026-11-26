#!/usr/bin/env python3
"""Select an available iPhone on the actual SDK major.minor; never fall back.

An explicit --runtime-version permits a diagnostic comparison on an installed
generic runtime in the same SDK major and no newer than that SDK. It selects
the exact normalized version, not a nearby patch, and is labeled diagnostic
in the receipt. Such a comparison is not SDK-matched release evidence.

Reads simctl JSON only. Does not boot, create, erase, or delete a simulator.
On success stdout contains exactly the selected UDID. A JSON receipt records
the actual selected device/runtime. Errors go to stderr and produce BLOCKED
receipts when the receipt path is writable. Explicit prerelease/internal labels
are excluded: a numeric SDK version cannot establish their release channel.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import uuid

VERSION = re.compile(r"([0-9]+)\.([0-9]+)(?:\.([0-9]+))?\Z")
RUNTIME_ID = re.compile(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-([0-9]+)-([0-9]+)(?:-([0-9]+))?\Z")
DEVICE_RUNTIME_ID = re.compile(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9]+-[0-9]+(?:-[0-9]+)?-iPhone[0-9]+-[0-9]+\Z")
UDID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
PRERELEASE = re.compile(r"\b(?:beta|alpha|seed|preview|rc|release\s+candidate|internal)\b", re.IGNORECASE)
DEFAULT_POLICY = "exact-model-exact-sdk-major-minor-highest-runtime-patch"
DIAGNOSTIC_POLICY = "diagnostic-exact-model-exact-runtime-version-no-newer-than-sdk"
DIAGNOSTIC_MODEL = "iPhone 18 Pro Max"
DIAGNOSTIC_DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"


class SelectionError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def require(condition, code, message):
    if not condition:
        raise SelectionError(code, message)


def version_tuple(value, code):
    match = VERSION.fullmatch(value) if isinstance(value, str) else None
    require(match is not None, code, "Version must contain numeric major.minor or major.minor.patch.")
    values = tuple(int(part or 0) for part in match.groups())
    require(values[0] > 0, code, "Version major must be positive.")
    return values


def selection_metadata(runtime_version):
    return {
        "selectionPolicy": DIAGNOSTIC_POLICY if runtime_version is not None else DEFAULT_POLICY,
        "diagnosticRuntimeOverride": runtime_version is not None,
        "requestedRuntimeVersion": runtime_version,
    }


def select_simulator(devices_document, runtimes_document, sdk_version, model, runtime_version=None):
    sdk = version_tuple(sdk_version, "INVALID_SDK_VERSION")
    require(isinstance(model, str) and model and model == model.strip(),
            "INVALID_MODEL", "An exact nonempty device model is required.")
    requested = None
    if runtime_version is not None:
        requested = version_tuple(runtime_version, "INVALID_RUNTIME_OVERRIDE")
        require(requested[0] == sdk[0], "DIAGNOSTIC_RUNTIME_MAJOR_MISMATCH",
                "Diagnostic runtime must have the same major version as the actual SDK.")
        require(requested <= sdk, "DIAGNOSTIC_RUNTIME_NEWER_THAN_SDK",
                "Diagnostic runtime must not be newer than the actual SDK.")
        require(model == DIAGNOSTIC_MODEL, "INVALID_DIAGNOSTIC_MODEL",
                "Diagnostic runtime comparison requires the exact iPhone 18 Pro Max model.")
    require(isinstance(devices_document, dict) and isinstance(devices_document.get("devices"), dict),
            "INVALID_DEVICES_DOCUMENT", "Expected a simctl devices object.")
    require(isinstance(runtimes_document, dict) and isinstance(runtimes_document.get("runtimes"), list),
            "INVALID_RUNTIMES_DOCUMENT", "Expected a simctl runtimes list.")
    devices_by_runtime = devices_document["devices"]
    candidates, seen_runtime_ids, matching_runtimes = [], set(), 0

    for runtime in runtimes_document["runtimes"]:
        require(isinstance(runtime, dict), "INVALID_RUNTIME_RECORD", "Runtime entries must be objects.")
        identifier = runtime.get("identifier")
        if not isinstance(identifier, str) or not identifier.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        if runtime.get("isAvailable") is not True:
            continue
        # simctl also inventories device-specific runtimes, e.g. the observed
        # iOS-27-2-iPhone19-4. They are not the general SDK runtime selected by
        # this policy; their presence must not invalidate an installed match.
        if DEVICE_RUNTIME_ID.fullmatch(identifier):
            continue
        name = runtime.get("name")
        require(isinstance(name, str) and name, "INVALID_RUNTIME_NAME", "Available iOS runtime has no name.")
        # No inferred release channel from a build-number suffix.
        if runtime.get("isInternal") is True or runtime.get("isBeta") is True or PRERELEASE.search(name):
            continue
        version = version_tuple(runtime.get("version"), "INVALID_RUNTIME_VERSION")
        identifier_match = RUNTIME_ID.fullmatch(identifier)
        require(identifier_match is not None, "INVALID_RUNTIME_IDENTIFIER", "Expected a canonical iOS runtime identifier.")
        identifier_version = tuple(int(part or 0) for part in identifier_match.groups())
        require(identifier_version == version, "RUNTIME_VERSION_MISMATCH", "Runtime identifier and version disagree.")
        require(identifier not in seen_runtime_ids, "AMBIGUOUS_RUNTIME_IDENTIFIER", "An available runtime identifier occurs more than once.")
        seen_runtime_ids.add(identifier)
        if (version != requested if requested is not None else version[:2] != sdk[:2]):
            continue
        require(runtime.get("platform", "iOS") == "iOS",
                "RUNTIME_PLATFORM_MISMATCH", "The selected runtime must be iOS.")
        build = runtime.get("buildversion")
        require(isinstance(build, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", build) is not None,
                "INVALID_RUNTIME_BUILD", "Matching iOS runtime must provide its actual buildversion.")
        matching_runtimes += 1
        devices = devices_by_runtime.get(identifier, [])
        require(isinstance(devices, list), "INVALID_DEVICE_LIST", "Runtime device entries must be a list.")
        seen_udids = set()
        for device in devices:
            require(isinstance(device, dict), "INVALID_DEVICE_RECORD", "Device entries must be objects.")
            if device.get("name") != model or device.get("isAvailable") is not True:
                continue
            if requested is not None:
                require(device.get("deviceTypeIdentifier") == DIAGNOSTIC_DEVICE_TYPE,
                        "DEVICE_TYPE_MISMATCH", "Diagnostic device name and type identifier must agree.")
            udid = device.get("udid")
            require(isinstance(udid, str) and UDID.fullmatch(udid) is not None and uuid.UUID(udid).int != 0,
                    "INVALID_DEVICE_UDID", "Matching device must provide a nonzero canonical UUID.")
            require(udid.casefold() not in seen_udids, "AMBIGUOUS_DEVICE_UDID", "Matching device UDID occurs more than once.")
            seen_udids.add(udid.casefold())
            state = device.get("state")
            require(isinstance(state, str) and state, "INVALID_DEVICE_STATE", "Matching device must provide its actual state.")
            candidates.append((version, identifier, build, udid.casefold(), device, runtime))

    missing_runtime = (
        f"No available non-prerelease generic iOS runtime matches diagnostic version {runtime_version}."
        if requested is not None else
        f"No available non-prerelease iOS runtime matches SDK {sdk[0]}.{sdk[1]}.")
    require(matching_runtimes > 0, "NO_MATCHING_RUNTIME", missing_runtime)
    require(candidates, "NO_MATCHING_DEVICE",
            f"No available exact model {model!r} exists on a matching iOS runtime.")
    # Default: highest numeric patch. Diagnostic: all candidates have the exact
    # requested version. Ties never depend on JSON order or boot state.
    candidates.sort(key=lambda item: (-item[0][2], item[1], item[2], item[3]))
    version, identifier, build, _, device, runtime = candidates[0]
    return {
        "schemaVersion": 1,
        "status": "SELECTED",
        **selection_metadata(runtime_version),
        "sdkVersion": sdk_version,
        "sdkMajorMinor": f"{sdk[0]}.{sdk[1]}",
        "requestedModel": model,
        "device": {
            "udid": device["udid"], "name": device["name"],
            "state": device["state"], "isAvailable": device["isAvailable"],
            "deviceTypeIdentifier": device.get("deviceTypeIdentifier"),
        },
        "runtime": {
            "identifier": identifier, "name": runtime["name"],
            "version": runtime["version"], "buildVersion": build,
            "isAvailable": runtime["isAvailable"],
            "isInternal": runtime.get("isInternal"),
        },
        "matchingAvailableDeviceCount": len(candidates),
    }


def load_document(path):
    with path.open("rb") as stream:
        payload = stream.read(8_000_001)
    require(len(payload) <= 8_000_000, "INPUT_TOO_LARGE", "Simulator inventory exceeds the input budget.")
    return json.loads(payload.decode("utf-8-sig"))


def write_receipt(path, receipt):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--devices", type=Path, required=True)
    parser.add_argument("--runtimes", type=Path, required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--runtime-version",
                        help="Diagnostic-only exact installed runtime version, within the SDK major and not newer.")
    parser.add_argument("--model", default="iPhone 18 Pro Max")
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(argv)
    receipt = {"schemaVersion": 1, "status": "BLOCKED",
               "sdkVersion": args.sdk_version, "requestedModel": args.model,
               **selection_metadata(args.runtime_version)}
    receipt_is_input = args.receipt.resolve() in {args.devices.resolve(), args.runtimes.resolve()}
    try:
        require(not receipt_is_input, "RECEIPT_OVERWRITES_INPUT", "Receipt must not overwrite an input inventory.")
        receipt = select_simulator(load_document(args.devices), load_document(args.runtimes),
                                   args.sdk_version, args.model, args.runtime_version)
    except SelectionError as error:
        receipt.update(code=error.code, message=str(error))
    except (OSError, ValueError, TypeError):
        receipt.update(code="INVALID_OR_UNREADABLE_INPUT", message="Could not read valid simulator inventory JSON.")
    receipt["observedAtUtc"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    if not receipt_is_input:
        try:
            write_receipt(args.receipt, receipt)
        except OSError:
            print(json.dumps({"status": "BLOCKED", "code": "RECEIPT_WRITE_FAILED"}), file=sys.stderr)
            return 2
    if receipt["status"] != "SELECTED":
        print(json.dumps(receipt, sort_keys=True), file=sys.stderr)
        return 2
    print(receipt["device"]["udid"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
