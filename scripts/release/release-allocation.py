#!/usr/bin/env python3
"""Bind one protected workflow attempt to one signed binary and upload intent.

This helper performs no network requests. A rerun cannot allocate another build
or consume a second upload. Reconcile the preserved intent after any uncertain
upload outcome; a new binary requires a new explicit workflow dispatch.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

APP = "6837899703"
BUNDLE = "org.timelabs.moleculefoundry"
TEAM = "398XACWZ7G"
REPOSITORY = "timelabs-npo/blueshoes-roomwave"
SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


class Blocked(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Blocked(message)


def stamp():
    return datetime.now(timezone.utc).isoformat()


def read_json(path):
    with path.open("rb") as stream:
        payload = stream.read(65537)
    require(len(payload) <= 65536, "Release receipt exceeds the bounded input size")
    value = json.loads(payload)
    require(isinstance(value, dict), "Expected a release receipt object")
    return value


def write_once(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation is intentional: a partial or existing intent is never
    # silently replaced after a crash. It requires operator reconciliation.
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def replace_observation(path, value):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def identity(root, environ):
    require(environ.get("GITHUB_REF") == "refs/heads/main", "Release requires main")
    require(environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Unexpected release repository")
    source = environ.get("GITHUB_SHA", "")
    require(SHA.fullmatch(source) and source == environ.get("ROOMWAVE_EXPECTED_SHA"),
            "An exact independently reviewed source SHA is required")
    actual = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    require(actual == source, "Checked-out source differs from the reviewed release")
    require(environ.get("GITHUB_RUN_ATTEMPT") == "1",
            "Release reruns are blocked: reconcile the original allocation and upload intent")
    run = environ.get("GITHUB_RUN_ID", "")
    number = environ.get("GITHUB_RUN_NUMBER", "")
    require(re.fullmatch(r"[1-9][0-9]{0,19}", run), "Invalid workflow run identity")
    require(re.fullmatch(r"[1-9][0-9]{0,3}", number) and int(number) <= 8999,
            "Invalid workflow build allocation")
    version = (root / "VERSION").read_text().strip()
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid marketing version")
    return {"schema_version": 1, "allocation_id": f"github:{REPOSITORY}:{run}:1",
            "repository": REPOSITORY, "source_sha": source, "app_id": APP,
            "bundle_identifier": BUNDLE, "version": version,
            "build": f"{1000 + int(number)}.1", "workflow_run_id": run,
            "workflow_run_number": int(number), "workflow_run_attempt": 1}


class Allocation:
    def __init__(self, root, environ):
        self.root = root
        self.environ = environ
        self.directory = root / "build/release"
        self.expected = identity(root, environ)

    def read(self):
        value = read_json(self.directory / "release-allocation.json")
        require(all(value.get(key) == expected for key, expected in self.expected.items()),
                "Persisted allocation differs from this reviewed workflow")
        require(type(value.get("upload_requested")) is bool, "Missing explicit upload intent")
        return value

    def allocate(self, upload):
        value = {**self.expected, "upload_requested": upload, "allocated_at_utc": stamp(),
                 "rerun_policy": "reconcile-existing-allocation"}
        write_once(self.directory / "release-allocation.json", value)
        return value

    def binary(self, allocation):
        folder = self.directory / "export"
        paths = sorted(folder.glob("*.ipa"))
        require(len(paths) == 1 and paths[0].is_file() and not paths[0].is_symlink(),
                "Exactly one regular exported IPA is required")
        path = paths[0]
        require(path.resolve().parent == folder.resolve(), "IPA must remain inside its export directory")
        compiled = read_json(self.directory / "ipa-identity.json")
        require(compiled.get("bundle") == BUNDLE and compiled.get("version") == allocation["version"]
                and compiled.get("build") == allocation["build"]
                and compiled.get("identity_verified") is True
                and compiled.get("usesNonExemptEncryption") is False,
                "Compiled binary identity differs from the allocation")
        checksum = digest(path)
        signature = read_json(self.directory / "exported-signature.json")
        require(signature.get("app_id") == APP and signature.get("bundle_identifier") == BUNDLE
                and signature.get("version") == allocation["version"]
                and signature.get("build") == allocation["build"] and signature.get("team_id") == TEAM
                and signature.get("ipa_sha256") == checksum and signature.get("signature_verified") is True
                and signature.get("distribution_profile_verified") is True
                and isinstance(signature.get("signer_certificate_sha256"), str)
                and DIGEST.fullmatch(signature["signer_certificate_sha256"]),
                "Exported signature receipt differs from this exact signed IPA")
        symbols = self.directory / "Roomwave-dSYMs.zip"
        require(symbols.is_file() and not symbols.is_symlink()
                and signature.get("dsym_verified") is True
                and signature.get("dsym_sha256") == digest(symbols),
                "Debug symbols differ from the UUID-verified archive")
        return path, checksum

    def record_export(self):
        allocation = self.read()
        _, checksum = self.binary(allocation)
        receipt = {"commit": allocation["source_sha"], "app_store_app_id": APP,
                   "bundle_identifier": BUNDLE, "version": allocation["version"],
                   "build": allocation["build"], "signature_verified": True,
                   "ipa_sha256": checksum,
                   "signature_receipt_sha256": digest(self.directory / "exported-signature.json"),
                   "dsym_sha256": digest(self.directory / "Roomwave-dSYMs.zip"),
                   "upload_accepted": False,
                   "tester_access_verified": False, "observed_utc": stamp(),
                   **{key: allocation[key] for key in ("allocation_id", "workflow_run_id",
                      "workflow_run_number", "workflow_run_attempt")}}
        write_once(self.directory / "release-receipt.json", receipt)
        return receipt

    def export_receipt(self, allocation, checksum):
        receipt = read_json(self.directory / "release-receipt.json")
        fields = {"commit": allocation["source_sha"], "app_store_app_id": APP,
                  "bundle_identifier": BUNDLE, "version": allocation["version"],
                  "build": allocation["build"], "ipa_sha256": checksum,
                  "allocation_id": allocation["allocation_id"],
                  "workflow_run_id": allocation["workflow_run_id"],
                  "dsym_sha256": digest(self.directory / "Roomwave-dSYMs.zip"),
                  "signature_receipt_sha256": digest(self.directory / "exported-signature.json")}
        require(all(receipt.get(key) == value for key, value in fields.items())
                and receipt.get("signature_verified") is True,
                "Export receipt does not identify this exact binary and allocation")
        return receipt

    def prepare_upload(self):
        allocation = self.read()
        require(allocation["upload_requested"], "Allocation does not authorize an upload")
        path, checksum = self.binary(allocation)
        receipt = self.export_receipt(allocation, checksum)
        require(receipt.get("upload_accepted") is False, "Upload was already accepted; reconcile it")
        value = {**allocation, "ipa_filename": path.name, "ipa_sha256": checksum,
                 "signature_receipt_sha256": receipt["signature_receipt_sha256"],
                 "dsym_sha256": receipt["dsym_sha256"],
                 "intent_recorded_at_utc": stamp(), "state": "UPLOAD_INTENT_RECORDED"}
        write_once(self.directory / "upload-intent.json", value)
        return value

    def verify_upload(self, consume=False):
        allocation = self.read()
        intent = read_json(self.directory / "upload-intent.json")
        require(all(intent.get(key) == value for key, value in allocation.items())
                and allocation["upload_requested"] and intent.get("state") == "UPLOAD_INTENT_RECORDED",
                "Upload intent does not match the persisted allocation")
        path, checksum = self.binary(allocation)
        require(intent.get("ipa_filename") == path.name and intent.get("ipa_sha256") == checksum
                and intent.get("signature_receipt_sha256") == digest(self.directory / "exported-signature.json")
                and intent.get("dsym_sha256") == digest(self.directory / "Roomwave-dSYMs.zip")
                and DIGEST.fullmatch(checksum), "Signed binary changed after upload intent")
        receipt = self.export_receipt(allocation, checksum)
        require(receipt.get("upload_accepted") is False, "Upload already accepted; never upload again to reconcile")
        if consume:
            artifacts = {"allocation_artifact_id": self.environ.get("ROOMWAVE_ALLOCATION_ARTIFACT_ID", ""),
                         "upload_intent_artifact_id": self.environ.get("ROOMWAVE_UPLOAD_INTENT_ARTIFACT_ID", "")}
            require(all(re.fullmatch(r"[1-9][0-9]{0,19}", value) for value in artifacts.values()),
                    "Allocation and upload intent must be preserved successfully before consumption")
            write_once(self.directory / "upload-consumed.json",
                       {"allocation_id": allocation["allocation_id"], "ipa_sha256": checksum,
                        "upload_intent_sha256": digest(self.directory / "upload-intent.json"),
                        "consumed_at_utc": stamp(), "state": "UPLOAD_OUTCOME_UNCONFIRMED", **artifacts})
        return path

    def record_accepted(self):
        allocation = self.read()
        self.verify_upload()
        consumed = read_json(self.directory / "upload-consumed.json")
        _, checksum = self.binary(allocation)
        require(consumed.get("allocation_id") == allocation["allocation_id"]
                and consumed.get("ipa_sha256") == checksum
                and consumed.get("upload_intent_sha256") == digest(self.directory / "upload-intent.json"),
                "Accepted upload requires the exact previously consumed intent")
        receipt = self.export_receipt(allocation, checksum)
        receipt.update(upload_accepted=True, observed_utc=stamp(),
                       upload_intent_sha256=consumed["upload_intent_sha256"],
                       allocation_artifact_id=consumed["allocation_artifact_id"],
                       upload_intent_artifact_id=consumed["upload_intent_artifact_id"])
        replace_observation(self.directory / "release-receipt.json", receipt)
        return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("allocate", "build", "record-export", "prepare-upload",
                                           "verify-upload", "consume-upload", "record-accepted"))
    parser.add_argument("--upload", choices=("true", "false"), default="false")
    args = parser.parse_args(argv)
    try:
        operator = Allocation(Path(__file__).resolve().parents[2], os.environ)
        if args.action == "allocate": result = operator.allocate(args.upload == "true")
        elif args.action == "build": result = operator.read()["build"]
        elif args.action == "record-export": result = operator.record_export()
        elif args.action == "prepare-upload": result = operator.prepare_upload()
        elif args.action in ("verify-upload", "consume-upload"):
            result = str(operator.verify_upload(consume=args.action == "consume-upload"))
        else: result = operator.record_accepted()
        print(result if isinstance(result, str) else json.dumps(result, sort_keys=True))
        return 0
    except (Blocked, OSError, ValueError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, Blocked) else "Release allocation is missing, invalid, already consumed, or unreadable; reconcile preserved evidence"
        print(json.dumps({"state": "BLOCKED_RELEASE_ALLOCATION", "reason": message}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
