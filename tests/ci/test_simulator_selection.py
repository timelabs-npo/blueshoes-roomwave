"""Offline CLI tests for SDK-aligned selection; no native tools or host mutation."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SELECTOR = Path(__file__).resolve().parents[2] / "scripts/ci/select-simulator.py"
OLD = "10000000-0000-4000-8000-000000000001"
CURRENT = "20000000-0000-4000-8000-000000000002"
PATCH = "30000000-0000-4000-8000-000000000003"
MODEL = "iPhone 18 Pro Max"


def runtime(version, **changes):
    item = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
            "name": "iOS " + version, "version": version, "buildversion": "24C101",
            "isAvailable": True, "isInternal": False}
    item.update(changes)
    return item


def device(udid, **changes):
    item = {"name": MODEL, "udid": udid, "state": "Shutdown", "isAvailable": True,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"}
    item.update(changes)
    return item


def fixture():
    old, current = runtime("27.0"), runtime("27.2")
    return {"devices": {old["identifier"]: [device(OLD)],
                         current["identifier"]: [device(CURRENT)]}}, {"runtimes": [old, current]}


def invoke(devices, runtimes, sdk="27.2", extra=(), stale_receipt=None):
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        devices_path, runtimes_path = root / "devices.json", root / "runtimes.json"
        receipt_path = root / "output" / "selection.json"
        devices_path.write_text(json.dumps(devices), encoding="utf-8")
        runtimes_path.write_text(json.dumps(runtimes), encoding="utf-8")
        if stale_receipt is not None:
            receipt_path.parent.mkdir()
            receipt_path.write_text(json.dumps(stale_receipt), encoding="utf-8")
        command = [sys.executable, "-B", str(SELECTOR), "--devices", str(devices_path),
                   "--runtimes", str(runtimes_path), "--sdk-version", sdk,
                   "--receipt", str(receipt_path), *extra]
        result = subprocess.run(command, text=True, encoding="utf-8", capture_output=True, timeout=10)
        receipt = json.loads(receipt_path.read_text()) if receipt_path.is_file() else None
        assert json.loads(devices_path.read_text()) == devices
        assert json.loads(runtimes_path.read_text()) == runtimes
        assert not list(root.rglob("*.tmp")), "An atomic-write temporary file was leaked"
        return result, receipt


class SimulatorSelectionTests(unittest.TestCase):
    def assert_blocked(self, result, receipt, code):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(receipt["status"], "BLOCKED")
        self.assertEqual(receipt["code"], code)
        self.assertEqual(json.loads(result.stderr)["code"], code)
        self.assertNotIn("device", receipt)

    def test_27_0_first_does_not_override_actual_27_2_sdk(self):
        devices, runtimes = fixture()
        runtimes["runtimes"][1]["buildversion"] = "24C109"
        devices["devices"][runtimes["runtimes"][1]["identifier"]][0]["state"] = "Booted"
        result, receipt = invoke(devices, runtimes)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, CURRENT + "\n")
        self.assertEqual(result.stderr, "")
        self.assertEqual(receipt["sdkVersion"], "27.2")
        self.assertEqual(receipt["runtime"]["version"], "27.2")
        self.assertEqual(receipt["runtime"]["buildVersion"], "24C109")
        self.assertEqual(receipt["device"]["state"], "Booted")
        self.assertEqual(receipt["device"]["name"], MODEL)
        self.assertTrue(receipt["observedAtUtc"].endswith("Z"))

    def test_unavailable_runtime_or_device_blocks_without_old_os_fallback(self):
        for unavailable in ("runtime", "device"):
            with self.subTest(unavailable=unavailable):
                devices, runtimes = fixture()
                if unavailable == "runtime":
                    runtimes["runtimes"][1]["isAvailable"] = False
                    code = "NO_MATCHING_RUNTIME"
                else:
                    devices["devices"][runtimes["runtimes"][1]["identifier"]][0]["isAvailable"] = False
                    code = "NO_MATCHING_DEVICE"
                self.assert_blocked(*invoke(devices, runtimes), code)

    def test_observed_device_specific_runtime_does_not_block_generic_sdk_runtime(self):
        devices, runtimes = fixture()
        specialized = runtime("27.2",
            identifier="com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
            buildversion="24B91016s", platform="iOS")
        runtimes["runtimes"].insert(1, specialized)
        devices["devices"][specialized["identifier"]] = [device(PATCH)]
        result, receipt = invoke(devices, runtimes)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, CURRENT + "\n")
        self.assertEqual(receipt["runtime"]["identifier"], "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        self.assert_blocked(*invoke(devices, {"runtimes": [specialized]}), "NO_MATCHING_RUNTIME")

    def test_missing_matching_runtime_or_exact_model_blocks(self):
        devices, runtimes = fixture()
        self.assert_blocked(*invoke(devices, {"runtimes": runtimes["runtimes"][:1]}),
                            "NO_MATCHING_RUNTIME")
        key = runtimes["runtimes"][1]["identifier"]
        devices["devices"][key][0]["name"] = "iPhone 18 Pro"
        self.assert_blocked(*invoke(devices, runtimes), "NO_MATCHING_DEVICE")
        result, receipt = invoke(devices, runtimes, extra=("--model", "iPhone 18 Pro"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt["device"]["name"], "iPhone 18 Pro")

    def test_highest_numeric_patch_and_udid_tie_break_are_order_independent(self):
        versions = [runtime("27.2.9"), runtime("27.2.10"), runtime("27.2"), runtime("27.3")]
        devices = {"devices": {item["identifier"]: [device(OLD)] for item in versions}}
        devices["devices"][versions[1]["identifier"]] = [device(PATCH), device(CURRENT)]
        for reverse in (False, True):
            with self.subTest(reverse=reverse):
                listed = copy.deepcopy(versions[::-1] if reverse else versions)
                copied = copy.deepcopy(devices)
                if reverse:
                    for values in copied["devices"].values():
                        values.reverse()
                result, receipt = invoke(copied, {"runtimes": listed})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, CURRENT + "\n")
                self.assertEqual(receipt["runtime"]["version"], "27.2.10")
                self.assertEqual(receipt["matchingAvailableDeviceCount"], 4)

    def test_explicit_beta_and_internal_runtimes_are_not_fallbacks(self):
        for labels in ({"name": "iOS 27.2.9 Beta 3"}, {"isBeta": True}, {"isInternal": True}):
            with self.subTest(labels=labels):
                devices, runtimes = fixture()
                prerelease = runtime("27.2.9", **labels)
                runtimes["runtimes"].append(prerelease)
                devices["devices"][prerelease["identifier"]] = [device(PATCH)]
                result, receipt = invoke(devices, runtimes)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(receipt["device"]["udid"], CURRENT)
                self.assert_blocked(*invoke(devices, {"runtimes": [prerelease]}),
                                    "NO_MATCHING_RUNTIME")

    def test_invalid_sdk_runtime_identity_or_device_uuid_is_blocked(self):
        devices, runtimes = fixture()
        self.assert_blocked(*invoke(devices, runtimes, sdk="27.x"), "INVALID_SDK_VERSION")
        broken = copy.deepcopy(runtimes)
        broken["runtimes"][1]["version"] = "27.3"
        self.assert_blocked(*invoke(devices, broken), "RUNTIME_VERSION_MISMATCH")
        broken = copy.deepcopy(devices)
        broken["devices"][runtimes["runtimes"][1]["identifier"]][0]["udid"] = "not-a-uuid"
        self.assert_blocked(*invoke(broken, runtimes), "INVALID_DEVICE_UDID")
        broken = copy.deepcopy(runtimes)
        broken["runtimes"].append(copy.deepcopy(broken["runtimes"][1]))
        self.assert_blocked(*invoke(devices, broken), "AMBIGUOUS_RUNTIME_IDENTIFIER")

    def test_failure_replaces_stale_success_receipt(self):
        devices, runtimes = fixture()
        result, receipt = invoke(devices, runtimes, sdk="28.0",
                                 stale_receipt={"status": "SELECTED", "device": {"udid": OLD}})
        self.assert_blocked(result, receipt, "NO_MATCHING_RUNTIME")


if __name__ == "__main__":
    unittest.main()
