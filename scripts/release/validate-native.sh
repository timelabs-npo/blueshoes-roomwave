#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ -n "${ROOMWAVE_DIAGNOSTIC_RUNTIME:-}" ]]; then
  # An explicit, isolated comparison cannot change the protected release gate.
  [[ "$ROOMWAVE_DIAGNOSTIC_RUNTIME" == 27.0 &&
     "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
     "${GITHUB_WORKFLOW:-}" == 'Unsigned iOS readiness' ]] || {
    echo 'Runtime overrides are restricted to the explicit unsigned diagnostic workflow.'
    exit 2
  }
fi
python3 - <<'PY'
from datetime import datetime, timezone
import json, os, subprocess
from pathlib import Path
from uuid import uuid4
release = Path('build/release')
if release.exists():
    history = Path('build/native-history')
    history.mkdir(parents=True, exist_ok=True)
    attempt = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid4().hex[:8]
    release.rename(history / attempt)
release.mkdir(parents=True)
record = {
    'schema_version': 1,
    'started_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
    'source_sha': os.environ.get('GITHUB_SHA') or subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'run_id': os.environ.get('GITHUB_RUN_ID'),
    'invocation_id': str(uuid4()),
    'purpose': 'diagnostic-runtime-comparison' if os.environ.get('ROOMWAVE_DIAGNOSTIC_RUNTIME') else 'sdk-matched-native-gate',
    'requested_runtime': os.environ.get('ROOMWAVE_DIAGNOSTIC_RUNTIME') or None,
}
(release / 'native-run-start.json').write_text(json.dumps(record, indent=2) + '\n')
PY
python3 scripts/ci/run-bounded.py --seconds 300 --label core-tests -- swift test --parallel
xcodegen generate --spec apps/ios/project.yml --project apps/ios
xcrun simctl list devices available --json > build/release/simulators.json
xcrun simctl list runtimes --json > build/release/simulator-runtimes.json
ROOMWAVE_SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-version)"
ROOMWAVE_SELECTOR_ARGUMENTS=(
  --devices build/release/simulators.json --runtimes build/release/simulator-runtimes.json
  --sdk-version "$ROOMWAVE_SIMULATOR_SDK" --model "iPhone 18 Pro Max"
  --receipt build/release/simulator-selection.json
)
if [[ -n "${ROOMWAVE_DIAGNOSTIC_RUNTIME:-}" ]]; then
  ROOMWAVE_SELECTOR_ARGUMENTS+=(--runtime-version "$ROOMWAVE_DIAGNOSTIC_RUNTIME")
fi
ROOMWAVE_SIMULATOR_ID=$(python3 scripts/ci/select-simulator.py "${ROOMWAVE_SELECTOR_ARGUMENTS[@]}")
python3 - <<'PY'
import json, os, platform
from pathlib import Path
record = {'source_sha': os.environ.get('GITHUB_SHA'), 'workflow_run_id': os.environ.get('GITHUB_RUN_ID'),
          'runner_image_version': os.environ.get('ImageVersion'), 'runner_image_os': os.environ.get('ImageOS'),
          'runner_architecture': os.environ.get('RUNNER_ARCH'), 'machine': platform.machine(),
          'macos_version': platform.mac_ver()[0]}
Path('build/release/runner-identity.json').write_text(json.dumps(record, indent=2) + '\n')
PY
python3 scripts/ci/run-bounded.py --seconds 240 --label simulator-boot -- xcrun simctl boot "$ROOMWAVE_SIMULATOR_ID" >/dev/null 2>&1 || true
python3 scripts/ci/run-bounded.py --seconds 240 --label simulator-ready -- xcrun simctl bootstatus "$ROOMWAVE_SIMULATOR_ID" -b
mkdir -p build/release/evidence
collect_capture_evidence() {
  local app_data lookup_status
  local -a capture_arguments
  capture_arguments=(
    --checkpoint-dir build/release/evidence/live-diagnostics/capture-checkpoints
    --output-dir build/release/evidence --run-receipt build/release/native-run-start.json
    --simulator "$ROOMWAVE_SIMULATOR_ID" --receipt build/release/evidence-collection.json
  )
  if python3 scripts/ci/arcade-capture-checkpoint.py "${capture_arguments[@]}"; then return 0; fi
  lookup_status=0
  app_data="$(python3 scripts/ci/run-bounded.py --seconds 30 --label native-app-container -- xcrun simctl get_app_container "$ROOMWAVE_SIMULATOR_ID" org.timelabs.moleculefoundry data 2>build/release/container.log)" || lookup_status=$?
  python3 scripts/ci/arcade-capture-checkpoint.py "${capture_arguments[@]}" \
    --lookup-exit "$lookup_status" --fresh-container "$app_data"
}
collect_native_diagnostics() {
  local capture_status=0
  # Preserve the already-observed bytes before slow screenshots/attachments/Metal collection.
  collect_capture_evidence || capture_status=$?
  git rev-parse HEAD > build/release/evidence/source-sha.txt
  python3 scripts/ci/run-bounded.py --seconds 30 --label simulator-description -- xcrun simctl list devices "$ROOMWAVE_SIMULATOR_ID" > build/release/evidence/simulator.txt 2>build/release/simulator-description.log || true
  python3 scripts/ci/run-bounded.py --seconds 60 --label final-screenshot -- xcrun simctl io "$ROOMWAVE_SIMULATOR_ID" screenshot build/release/evidence/Roomwave-full-ui.png >build/release/screenshot.log 2>&1 || true
  if [[ -d build/release/NativeTests.xcresult ]]; then
    python3 scripts/ci/run-bounded.py --seconds 120 --label native-attachments -- xcrun xcresulttool export attachments --path build/release/NativeTests.xcresult \
      --output-path build/release/evidence/ui-attachments > build/release/attachments-export.log 2>&1 || true
  fi
  python3 scripts/ci/run-bounded.py --seconds 60 --label metal-service-diagnostics -- \
    python3 scripts/ci/collect-metal-diagnostics.py \
      --since-receipt build/release/native-run-start.json --simulator "$ROOMWAVE_SIMULATOR_ID" \
      --output-dir build/release/evidence/metal-diagnostics >build/release/metal-diagnostics.log 2>&1 || true
  return "$capture_status"
}
python3 scripts/ci/watch-arcade-recording.py --simulator "$ROOMWAVE_SIMULATOR_ID" \
  --output build/release/evidence/Roomwave-actual-ui-test.mp4 >build/release/recording-observer.log 2>&1 &
ROOMWAVE_CAPTURE_PID=$!
python3 scripts/ci/watch-arcade-diagnostics.py --simulator "$ROOMWAVE_SIMULATOR_ID" \
  --output-dir build/release/evidence/live-diagnostics --seconds 1800 \
  --run-receipt build/release/native-run-start.json >build/release/diagnostic-observer.log 2>&1 &
ROOMWAVE_DIAGNOSTIC_PID=$!
stop_observers() {
  local pid running
  for pid in "$ROOMWAVE_CAPTURE_PID" "$ROOMWAVE_DIAGNOSTIC_PID"; do
    # Signal only a still-owned background job, never a recycled host PID.
    for running in $(jobs -pr); do
      if [[ "$running" == "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; fi
    done
    wait "$pid" || true
  done
}
trap 'stop_observers; collect_native_diagnostics' EXIT
if ! python3 scripts/ci/run-bounded.py --seconds 1260 --label native-tests -- xcodebuild -project apps/ios/Roomwave.xcodeproj -scheme Roomwave -configuration Debug \
  -destination "platform=iOS Simulator,id=$ROOMWAVE_SIMULATOR_ID" \
  -derivedDataPath build/release/DerivedData -resultBundlePath build/release/NativeTests.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 600 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test > build/release/native-test.log 2>&1; then
  stop_observers
  trap - EXIT
  collect_native_diagnostics || true
  tail -n 120 build/release/native-test.log
  exit 1
fi
stop_observers
trap - EXIT
tail -n 45 build/release/native-test.log
collect_native_diagnostics
python3 scripts/ci/verify-arcade-evidence.py build/release/evidence
ROOMWAVE_SIM_APP=build/release/DerivedData/Build/Products/Debug-iphonesimulator/Roomwave.app
python3 scripts/release/verify-app.py "$ROOMWAVE_SIM_APP" --build 1 > build/release/simulator-identity.json
ditto -c -k --keepParent "$ROOMWAVE_SIM_APP" build/release/Roomwave-simulator.app.zip
if [[ -n "${ROOMWAVE_DIAGNOSTIC_RUNTIME:-}" ]]; then
  echo 'Explicit runtime comparison completed. This diagnostic run does not satisfy the SDK-matched release gate.'
  exit 0
fi
if [[ "${DEFER_ARCHIVE_TO_SIGNED_RELEASE:-false}" == true ]]; then
  echo "Native tests passed; the protected release job will archive and verify the signed app."
  exit 0
fi
if ! python3 scripts/ci/run-bounded.py --seconds 600 --label unsigned-archive -- xcodebuild -project apps/ios/Roomwave.xcodeproj -scheme Roomwave -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/release/UnsignedRoomwave.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CURRENT_PROJECT_VERSION=1 MARKETING_VERSION="$(cat VERSION)" \
  archive > build/release/unsigned-archive.log 2>&1; then
  tail -n 120 build/release/unsigned-archive.log
  exit 1
fi
python3 scripts/release/verify-app.py build/release/UnsignedRoomwave.xcarchive/Products/Applications/Roomwave.app --build 1 > build/release/unsigned-archive-identity.json
ditto -c -k --keepParent build/release/UnsignedRoomwave.xcarchive build/release/UnsignedRoomwave.xcarchive.zip