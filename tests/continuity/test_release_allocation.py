"""Offline release lifecycle tests: no signing, Apple calls or upload occurs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "scripts/release/release-allocation.py"
spec = importlib.util.spec_from_file_location("release_allocation", SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HEAD = "a" * 40


class ReleaseAllocationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "VERSION").write_text("0.3.0\n")
        self.environ = {
            "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": module.REPOSITORY,
            "GITHUB_SHA": HEAD, "ROOMWAVE_EXPECTED_SHA": HEAD,
            "GITHUB_RUN_ID": "123456789", "GITHUB_RUN_NUMBER": "3", "GITHUB_RUN_ATTEMPT": "1",
            "ROOMWAVE_ALLOCATION_ARTIFACT_ID": "567001",
            "ROOMWAVE_UPLOAD_INTENT_ARTIFACT_ID": "567002",
        }
        self.checkout = patch.object(module.subprocess, "check_output", return_value=HEAD + "\n")
        self.checkout.start()
        self.addCleanup(self.checkout.stop)
        self.operator = module.Allocation(self.root, self.environ)
        self.directory = self.root / "build/release"

    def exported(self, upload=True):
        self.operator.allocate(upload)
        export = self.directory / "export"
        export.mkdir()
        self.ipa = export / "Roomwave.ipa"
        # Opaque synthetic bytes exercise identity/hash lifecycle, not code signing.
        self.ipa.write_bytes(b"synthetic binary for offline allocation regression\0")
        compiled = {"bundle": module.BUNDLE, "version": "0.3.0", "build": "1003.1",
                    "identity_verified": True, "usesNonExemptEncryption": False}
        (self.directory / "ipa-identity.json").write_text(json.dumps(compiled))
        # Synthetic policy evidence only; no real signing claim is made by tests.
        signature = {"app_id": module.APP, "bundle_identifier": module.BUNDLE,
                     "version": "0.3.0", "build": "1003.1", "team_id": module.TEAM,
                     "signature_verified": True, "distribution_profile_verified": True,
                     "signer_certificate_sha256": "c" * 64, "ipa_sha256": module.digest(self.ipa)}
        (self.directory / "exported-signature.json").write_text(json.dumps(signature))
        self.operator.record_export()

    def test_one_allocation_one_binary_one_consumption_then_observed_acceptance(self):
        self.exported()
        intent = self.operator.prepare_upload()
        self.assertEqual(intent["build"], "1003.1")
        self.assertEqual(intent["source_sha"], HEAD)
        preserved = (self.directory / "upload-intent.json").read_bytes()
        self.assertEqual(self.operator.verify_upload(), self.ipa)
        self.operator.verify_upload(consume=True)
        with self.assertRaises(FileExistsError):
            self.operator.verify_upload(consume=True)
        receipt = self.operator.record_accepted()
        self.assertTrue(receipt["upload_accepted"])
        self.assertFalse(receipt["tester_access_verified"])
        self.assertEqual(receipt["upload_intent_artifact_id"], "567002")
        self.assertEqual((self.directory / "upload-intent.json").read_bytes(), preserved)
        with self.assertRaises(module.Blocked):
            self.operator.verify_upload(consume=True)

    def test_rerun_is_blocked_without_reallocating_or_changing_recorded_binary(self):
        self.exported()
        original = (self.directory / "release-allocation.json").read_bytes()
        for attempt in ("0", "2", "99", "01", ""):
            with self.subTest(attempt=attempt), self.assertRaises(module.Blocked):
                module.Allocation(self.root, {**self.environ, "GITHUB_RUN_ATTEMPT": attempt})
        self.assertEqual((self.directory / "release-allocation.json").read_bytes(), original)

    def test_changed_source_repository_branch_or_run_cannot_read_original_allocation(self):
        self.exported()
        variants = ({"GITHUB_SHA": "b" * 40}, {"ROOMWAVE_EXPECTED_SHA": "b" * 40},
                    {"GITHUB_REF": "refs/heads/other"}, {"GITHUB_REPOSITORY": "other/repo"},
                    {"GITHUB_RUN_ID": "987654321"}, {"GITHUB_RUN_NUMBER": "4"},
                    {"GITHUB_RUN_NUMBER": "9000"})
        for changes in variants:
            with self.subTest(changes=changes), self.assertRaises(module.Blocked):
                module.Allocation(self.root, {**self.environ, **changes}).read()

    def test_new_explicit_dispatch_allocates_first_attempt_without_reusing_old_intent(self):
        self.exported()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "VERSION").write_text("0.3.0")
            operator = module.Allocation(root, {**self.environ, "GITHUB_RUN_ID": "987654321", "GITHUB_RUN_NUMBER": "4"})
            self.assertEqual(operator.allocate(True)["build"], "1004.1")
            with self.assertRaises(FileNotFoundError):
                operator.verify_upload()

    def test_existing_or_partial_allocation_is_never_overwritten(self):
        first = self.operator.allocate(True)
        with self.assertRaises(FileExistsError):
            self.operator.allocate(False)
        self.assertEqual(self.operator.read(), first)
        path = self.directory / "release-allocation.json"
        path.write_text('{"interrupted":')
        with self.assertRaises(FileExistsError):
            self.operator.allocate(True)
        self.assertEqual(path.read_text(), '{"interrupted":')

    def test_binary_change_after_persisted_intent_blocks_consumption(self):
        self.exported()
        self.operator.prepare_upload()
        self.ipa.write_bytes(b"different binary")
        with self.assertRaises(module.Blocked):
            self.operator.verify_upload(consume=True)
        self.assertFalse((self.directory / "upload-consumed.json").exists())

    def test_forged_export_receipt_or_compiled_identity_cannot_prepare_upload(self):
        self.exported()
        for filename, changes in (
            ("release-receipt.json", {"commit": "b" * 40}),
            ("release-receipt.json", {"app_store_app_id": "111"}),
            ("release-receipt.json", {"signature_verified": False}),
            ("release-receipt.json", {"ipa_sha256": "0" * 64}),
            ("ipa-identity.json", {"build": "1004.1"}),
            ("ipa-identity.json", {"usesNonExemptEncryption": True}),
            ("exported-signature.json", {"bundle_identifier": "org.example.other"}),
            ("exported-signature.json", {"app_id": "111"}),
            ("exported-signature.json", {"version": "0.2.0"}),
            ("exported-signature.json", {"build": "1004.1"}),
            ("exported-signature.json", {"team_id": "OTHERTEAM"}),
            ("exported-signature.json", {"signature_verified": False}),
            ("exported-signature.json", {"distribution_profile_verified": False}),
            ("exported-signature.json", {"ipa_sha256": "0" * 64}),
            ("exported-signature.json", {"signer_certificate_sha256": "invalid"}),
        ):
            with self.subTest(filename=filename, changes=changes):
                path = self.directory / filename
                original = path.read_bytes()
                path.write_text(json.dumps({**json.loads(original), **changes}))
                with self.assertRaises(module.Blocked):
                    self.operator.prepare_upload()
                path.write_bytes(original)
                self.assertFalse((self.directory / "upload-intent.json").exists())

    def test_missing_signature_evidence_blocks_export_and_upload(self):
        self.exported()
        signature_path = self.directory / "exported-signature.json"
        signature_path.unlink()
        with self.assertRaises(FileNotFoundError):
            self.operator.prepare_upload()
        (self.directory / "release-receipt.json").unlink()
        with self.assertRaises(FileNotFoundError):
            self.operator.record_export()
        self.assertFalse((self.directory / "release-receipt.json").exists())

    def test_changed_signature_receipt_after_export_or_intent_is_rejected(self):
        self.exported()
        path = self.directory / "exported-signature.json"
        original = path.read_bytes()
        signature = json.loads(original)
        # Even another valid-shaped observation cannot replace preserved evidence.
        signature["signer_certificate_sha256"] = "d" * 64
        path.write_text(json.dumps(signature))
        with self.assertRaises(module.Blocked):
            self.operator.prepare_upload()
        path.write_bytes(original)
        intent = self.operator.prepare_upload()
        self.assertEqual(intent["signature_receipt_sha256"], module.digest(path))
        path.write_text(json.dumps(signature))
        with self.assertRaises(module.Blocked):
            self.operator.verify_upload(consume=True)
        self.assertFalse((self.directory / "upload-consumed.json").exists())

    def test_missing_persisted_artifact_ids_block_consumption(self):
        self.exported()
        self.operator.prepare_upload()
        for key in ("ROOMWAVE_ALLOCATION_ARTIFACT_ID", "ROOMWAVE_UPLOAD_INTENT_ARTIFACT_ID"):
            with self.subTest(key=key):
                original = self.environ[key]
                self.environ[key] = ""
                with self.assertRaises(module.Blocked):
                    self.operator.verify_upload(consume=True)
                self.environ[key] = original
                self.assertFalse((self.directory / "upload-consumed.json").exists())

    def test_no_acceptance_without_prior_consumption_or_with_replaced_intent(self):
        self.exported()
        self.operator.prepare_upload()
        with self.assertRaises(FileNotFoundError):
            self.operator.record_accepted()
        self.operator.verify_upload(consume=True)
        path = self.directory / "upload-intent.json"
        intent = json.loads(path.read_text())
        intent["intent_recorded_at_utc"] = "changed after consumption"
        path.write_text(json.dumps(intent))
        with self.assertRaises(module.Blocked):
            self.operator.record_accepted()
        self.assertFalse(module.read_json(self.directory / "release-receipt.json")["upload_accepted"])

    def test_export_only_dispatch_cannot_prepare_upload(self):
        self.exported(upload=False)
        with self.assertRaises(module.Blocked):
            self.operator.prepare_upload()
        self.assertFalse((self.directory / "upload-intent.json").exists())


if __name__ == "__main__":
    unittest.main()
