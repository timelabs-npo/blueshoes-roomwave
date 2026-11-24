#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/release
swift test --parallel
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
xcrun simctl boot "$ROOMWAVE_SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$ROOMWAVE_SIMULATOR_ID" -b
if ! xcodebuild -project apps/ios/Roomwave.xcodeproj -scheme Roomwave -configuration Debug \
  -destination "platform=iOS Simulator,id=$ROOMWAVE_SIMULATOR_ID" \
  -derivedDataPath build/release/DerivedData -resultBundlePath build/release/NativeTests.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test > build/release/native-test.log 2>&1; then
  tail -n 120 build/release/native-test.log
  exit 1
fi
tail -n 45 build/release/native-test.log
if ! xcodebuild -project apps/ios/Roomwave.xcodeproj -scheme Roomwave -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/release/UnsignedRoomwave.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CURRENT_PROJECT_VERSION=1 MARKETING_VERSION=0.1.0 \
  archive > build/release/unsigned-archive.log 2>&1; then
  tail -n 120 build/release/unsigned-archive.log
  exit 1
fi
python3 scripts/release/verify-app.py build/release/UnsignedRoomwave.xcarchive/Products/Applications/Roomwave.app --build 1 > build/release/unsigned-archive-identity.json
ditto -c -k --keepParent build/release/UnsignedRoomwave.xcarchive build/release/UnsignedRoomwave.xcarchive.zip
