#!/usr/bin/env bash
# Sign Roomwave only under the user-authorized existing Molecule Foundry identity. Never enable shell tracing.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
ROOMWAVE_RELEASE_VERSION="$(cat VERSION)"
[[ "$ROOMWAVE_RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid marketing version.'; exit 2; }
export ROOMWAVE_RELEASE_VERSION
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || { echo 'Release requires main.'; exit 2; }
for name in DEVELOPMENT_TEAM PRODUCT_BUNDLE_IDENTIFIER PROVISIONING_PROFILE_NAME APPLE_DISTRIBUTION_P12_BASE64 APPLE_DISTRIBUTION_P12_PASSWORD APP_STORE_PROFILE_BASE64; do
  [[ -n "${!name:-}" ]] || { echo "Missing protected release value: $name"; exit 2; }
done
[[ "$PRODUCT_BUNDLE_IDENTIFIER" == org.timelabs.moleculefoundry ]] || { echo 'Unexpected app identity.'; exit 2; }
[[ "$DEVELOPMENT_TEAM" == 398XACWZ7G ]] || { echo 'Unexpected Apple team.'; exit 2; }
BUILD_NUMBER="$(python3 scripts/release/release-allocation.py build)"
export ROOMWAVE_RELEASE_BUILD="$BUILD_NUMBER"
mkdir -p build/release/export
if [[ "${UPLOAD_TO_TESTFLIGHT:-false}" == true ]]; then
  node scripts/release/apple-status.mjs app
fi
ROOMWAVE_SIGNING_WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/roomwave-signing.XXXXXX")
export ROOMWAVE_SIGNING_WORK
KEYCHAIN="$ROOMWAVE_SIGNING_WORK/roomwave.keychain-db"
PROFILE_PATH=''
ORIGINAL_KEYCHAINS=()
while IFS= read -r item; do ORIGINAL_KEYCHAINS+=("$item"); done < <(security list-keychains -d user | python3 -c 'import shlex,sys; print("\n".join(shlex.split(sys.stdin.read())))')
[[ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]] || { echo 'Could not preserve original keychain search list.'; rm -rf "$ROOMWAVE_SIGNING_WORK"; exit 2; }
cleanup() {
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  if [[ -n "$PROFILE_PATH" ]]; then rm -f "$PROFILE_PATH"; fi
  rm -rf "$ROOMWAVE_SIGNING_WORK"
}
trap cleanup EXIT
KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
echo "::add-mask::$KEYCHAIN_PASSWORD"
python3 - <<'PY'
import base64,os
from pathlib import Path
root=Path(os.environ['ROOMWAVE_SIGNING_WORK'])
for env,name in [('APPLE_DISTRIBUTION_P12_BASE64','identity.p12'),('APP_STORE_PROFILE_BASE64','profile.mobileprovision')]:
    (root/name).write_bytes(base64.b64decode(os.environ[env],validate=True))
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$ROOMWAVE_SIGNING_WORK/identity.p12" -P "$APPLE_DISTRIBUTION_P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/[0-9A-F]{40}/ {print $2; exit}')
[[ ${#IDENTITY} -eq 40 ]] || { echo 'No usable signing identity.'; exit 2; }
export ROOMWAVE_SIGNING_IDENTITY="$IDENTITY"
security cms -D -i "$ROOMWAVE_SIGNING_WORK/profile.mobileprovision" > "$ROOMWAVE_SIGNING_WORK/profile.plist"
PROFILE_UUID=$(python3 - <<'PY'
import datetime,hashlib,os,plistlib
from pathlib import Path
p=plistlib.loads((Path(os.environ['ROOMWAVE_SIGNING_WORK'])/'profile.plist').read_bytes())
assert p['Entitlements']['application-identifier']==os.environ['DEVELOPMENT_TEAM']+'.org.timelabs.moleculefoundry'
assert p['Name']==os.environ['PROVISIONING_PROFILE_NAME']
assert any(hashlib.sha1(c).hexdigest().upper()==os.environ['ROOMWAVE_SIGNING_IDENTITY'].upper() for c in p['DeveloperCertificates']), 'Signing certificate is not contained in this profile'
assert p['ExpirationDate']>datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
assert p['Entitlements'].get('get-task-allow') is False
assert not p.get('ProvisionedDevices') and not p.get('ProvisionsAllDevices'), 'App Store profile required'
print(p['UUID'])
PY
)
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
INSTALLED_PROFILE_PATH="$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
if [[ -e "$INSTALLED_PROFILE_PATH" ]]; then
  cmp -s "$ROOMWAVE_SIGNING_WORK/profile.mobileprovision" "$INSTALLED_PROFILE_PATH" || { echo 'An existing profile has different content; refusing to replace it.'; exit 2; }
else
  PROFILE_PATH="$INSTALLED_PROFILE_PATH"
  cp "$ROOMWAVE_SIGNING_WORK/profile.mobileprovision" "$PROFILE_PATH"
fi
xcodegen generate --spec apps/ios/project.yml --project apps/ios
if ! xcodebuild -project apps/ios/Roomwave.xcodeproj -scheme Roomwave -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/release/Roomwave.xcarchive \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_NAME" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  MARKETING_VERSION="$ROOMWAVE_RELEASE_VERSION" archive > build/release/archive.log 2>&1; then
  tail -n 100 build/release/archive.log; exit 1
fi
APP=build/release/Roomwave.xcarchive/Products/Applications/Roomwave.app
codesign --verify --deep --strict "$APP"
python3 scripts/release/verify-app.py "$APP" --build "$BUILD_NUMBER" > build/release/archive-identity.json
python3 - <<'PY'
import os,plistlib
from pathlib import Path
options={'method':'app-store-connect','destination':'export','signingStyle':'manual','teamID':os.environ['DEVELOPMENT_TEAM'],
         'provisioningProfiles':{'org.timelabs.moleculefoundry':os.environ['PROVISIONING_PROFILE_NAME']},
         'manageAppVersionAndBuildNumber':False,'uploadSymbols':True}
Path('build/release/ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
if ! xcodebuild -exportArchive -archivePath build/release/Roomwave.xcarchive \
  -exportPath build/release/export -exportOptionsPlist build/release/ExportOptions.plist > build/release/export.log 2>&1; then
  tail -n 100 build/release/export.log; exit 1
fi
IPA=$(find build/release/export -maxdepth 1 -name '*.ipa' -print -quit)
[[ -n "$IPA" ]] || { echo 'Signed IPA not produced.'; exit 2; }
python3 scripts/release/verify-app.py "$IPA" --build "$BUILD_NUMBER" > build/release/ipa-identity.json
python3 scripts/release/verify-exported-signature.py "$IPA" --build "$BUILD_NUMBER" \
  --output build/release/exported-signature.json
# Retain the actual archive's symbols before preserving any upload intent.
DSYM_ROOT=build/release/Roomwave.xcarchive/dSYMs
[[ -s "$DSYM_ROOT/Roomwave.app.dSYM/Contents/Resources/DWARF/Roomwave" ]] || {
  echo 'The signed archive has no application debug symbols.'; exit 2
}
ditto -c -k --keepParent "$DSYM_ROOT" build/release/Roomwave-dSYMs.zip
# Upload occurs in a separate step only after its immutable intent and signed
# binary have been preserved as a GitHub artifact. This stage never uploads.
python3 scripts/release/release-allocation.py record-export
