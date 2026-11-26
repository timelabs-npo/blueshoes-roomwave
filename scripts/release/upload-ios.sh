#!/usr/bin/env bash
# Consume one preserved upload intent. Reconcile uncertain outcomes; never rerun.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
ROOMWAVE_RELEASE_VERSION="$(cat VERSION)"
ROOMWAVE_RELEASE_BUILD="$(python3 scripts/release/release-allocation.py build)"
export ROOMWAVE_RELEASE_VERSION ROOMWAVE_RELEASE_BUILD
IPA="$(python3 scripts/release/release-allocation.py verify-upload)"
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_P8_BASE64 APP_STORE_APP_ID; do
  [[ -n "${!name:-}" ]] || { echo "Missing protected upload value: $name"; exit 2; }
done
# This final read is independent of the earlier signing preflight.
node scripts/release/apple-status.mjs app
ROOMWAVE_UPLOAD_WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/roomwave-upload.XXXXXX")
export ROOMWAVE_UPLOAD_WORK
trap 'rm -rf "$ROOMWAVE_UPLOAD_WORK"' EXIT
mkdir -p "$ROOMWAVE_UPLOAD_WORK/private_keys"
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['ROOMWAVE_UPLOAD_WORK']) / 'private_keys'
(root / ('AuthKey_' + os.environ['ASC_KEY_ID'] + '.p8')).write_bytes(
    base64.b64decode(os.environ['ASC_PRIVATE_KEY_P8_BASE64'], validate=True))
PY
# Requires both preceding upload-artifact steps to have returned real IDs.
# Exclusive consumption also blocks a second invocation in the same job.
python3 scripts/release/release-allocation.py consume-upload >/dev/null
if ! API_PRIVATE_KEYS_DIR="$ROOMWAVE_UPLOAD_WORK/private_keys" \
  python3 scripts/ci/run-bounded.py --seconds 900 --label testflight-upload -- \
  xcrun altool --upload-app --type ios -f "$IPA" --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" > build/release/upload.log 2>&1; then
  tail -n 70 build/release/upload.log
  echo 'Upload outcome is unconfirmed. Inspect this exact allocation in Apple before any new dispatch.'
  exit 1
fi
python3 scripts/release/release-allocation.py record-accepted
node scripts/release/apple-status.mjs processing
ROOMWAVE_PROCESSED_BUILD_ID=$(node --input-type=module -e '
  import {readFileSync} from "node:fs";
  const receipt = JSON.parse(readFileSync("build/release/apple-processing.json", "utf8"));
  if (receipt.apple_processing === "VALID") {
    if (!/^[0-9a-f-]{36}$/i.test(receipt.apple_build_id || "")) throw new Error("Missing processed build UUID");
    process.stdout.write(receipt.apple_build_id);
  }
')
if [[ -n "$ROOMWAVE_PROCESSED_BUILD_ID" ]]; then
  node scripts/release/finalize-internal.mjs --apply \
    --build-id "$ROOMWAVE_PROCESSED_BUILD_ID" \
    --compiled-identity-receipt build/release/ipa-identity.json \
    --state-dir build/release/testflight-operations
else
  echo 'Apple processing remains pending. Reconcile this upload before finalizing internal access; do not re-upload.'
fi
