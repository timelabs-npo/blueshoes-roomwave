#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/release
python3 scripts/ci/run-bounded.py --seconds 300 --label core-tests -- swift test --parallel
xcodegen generate --spec apps/ios/project.yml --project apps/ios
xcrun simctl list devices available --json > build/release/simulators.json
ROOMWAVE_SIMULATOR_ID=$(python3 - <<'PY'
import json
from pathlib import Path
items=[]
for runtime,devices in json.loads(Path('build/release/simulators.json').read_text())['devices'].items():
    if 'iOS-27' in runtime:
        items.extend(d for d in devices if d.get('isAvailable') and d.get('name','').startswith('iPhone'))
if not items: raise SystemExit('An available iOS 27 iPhone simulator is required')
items.sort(key=lambda d:(d['name']!='iPhone 18 Pro Max',d['name']))
print(items[0]['udid'])
PY
)
python3 scripts/ci/run-bounded.py --seconds 240 --label simulator-boot -- xcrun simctl boot "$ROOMWAVE_SIMULATOR_ID" >/dev/null 2>&1 || true
python3 scripts/ci/run-bounded.py --seconds 240 --label simulator-ready -- xcrun simctl bootstatus "$ROOMWAVE_SIMULATOR_ID" -b
mkdir -p build/release/evidence
collect_native_diagnostics() {
  git rev-parse HEAD > build/release/evidence/source-sha.txt
  python3 scripts/ci/run-bounded.py --seconds 30 --label simulator-description -- xcrun simctl list devices "$ROOMWAVE_SIMULATOR_ID" > build/release/evidence/simulator.txt 2>build/release/simulator-description.log || true
  python3 scripts/ci/run-bounded.py --seconds 60 --label final-screenshot -- xcrun simctl io "$ROOMWAVE_SIMULATOR_ID" screenshot build/release/evidence/Roomwave-full-ui.png >build/release/screenshot.log 2>&1 || true
  if [[ -d build/release/NativeTests.xcresult ]]; then
    python3 scripts/ci/run-bounded.py --seconds 120 --label native-attachments -- xcrun xcresulttool export attachments --path build/release/NativeTests.xcresult \
      --output-path build/release/evidence/ui-attachments > build/release/attachments-export.log 2>&1 || true
  fi
  local app_data
  app_data="$(python3 scripts/ci/run-bounded.py --seconds 30 --label native-app-container -- xcrun simctl get_app_container "$ROOMWAVE_SIMULATOR_ID" org.timelabs.moleculefoundry data 2>build/release/container.log)" || return 0
  if [[ -d "$app_data/Library/Caches/RoomwaveArcadeCaptures" ]]; then
    cp -R "$app_data/Library/Caches/RoomwaveArcadeCaptures/." build/release/evidence/ || true
  fi
}
python3 scripts/ci/watch-arcade-recording.py --simulator "$ROOMWAVE_SIMULATOR_ID" \
  --output build/release/evidence/Roomwave-actual-ui-test.mp4 &
ROOMWAVE_CAPTURE_PID=$!
stop_capture() { kill -TERM "$ROOMWAVE_CAPTURE_PID" 2>/dev/null || true; wait "$ROOMWAVE_CAPTURE_PID" || true; }
trap 'stop_capture; collect_native_diagnostics' EXIT
if ! python3 scripts/ci/run-bounded.py --seconds 1260 --label native-tests -- xcodebuild -project apps/ios/Roomwave.xcodeproj -scheme Roomwave -configuration Debug \
  -destination "platform=iOS Simulator,id=$ROOMWAVE_SIMULATOR_ID" \
  -derivedDataPath build/release/DerivedData -resultBundlePath build/release/NativeTests.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 600 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test > build/release/native-test.log 2>&1; then
  stop_capture
  trap - EXIT
  collect_native_diagnostics
  tail -n 120 build/release/native-test.log
  exit 1
fi
stop_capture
trap - EXIT
tail -n 45 build/release/native-test.log
collect_native_diagnostics
python3 scripts/ci/verify-arcade-evidence.py build/release/evidence
ROOMWAVE_SIM_APP=build/release/DerivedData/Build/Products/Debug-iphonesimulator/Roomwave.app
python3 scripts/release/verify-app.py "$ROOMWAVE_SIM_APP" --build 1 > build/release/simulator-identity.json
ditto -c -k --keepParent "$ROOMWAVE_SIM_APP" build/release/Roomwave-simulator.app.zip
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
