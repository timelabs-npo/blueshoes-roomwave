# Roomwave TestFlight delivery

Bundle: `org.timelabs.blueshoes.roomwave`; version: `0.1.0`.
Release source must be the reviewed default branch `main`.
The `testflight` environment is restricted to main and requires approval of the exact run by the release owner, matching the existing team delivery pattern. An already authorized operator can approve that run without weakening environment protections.

## Actual setup, 24 November 2026

- Repository visibility is public; an all-ref source/history scan found no credential material before publication.
- Existing Apple distribution identity is available in the protected environment and expires 7 November 2027.
- Distribution P12, its password and ASC key are encrypted environment secrets. No signing files or secret values are in this repository.
- Team, intended bundle, ASC key identifier and issuer variables are configured.
- Registration of this new bundle through the current API credential returned HTTP 403 FORBIDDEN_ERROR. A bundle or provisioning profile was not created.
- Creating a new App Store Connect app record requires Apple's website. That authenticated website step is currently blocked separately.
- `APP_STORE_PROFILE_BASE64`, `PROVISIONING_PROFILE_NAME` and `APP_STORE_APP_ID` are still missing. Signed export and upload are not ready.

## Required Apple completion

An authorized Apple team administrator must register the exact explicit bundle above and issue an App Store Connect distribution profile using the existing valid team distribution certificate. The proposed app record is **Blueshoes Roomwave**, primary language English (U.S.), SKU `blueshoes-roomwave-pilot`.

The API credential can read existing apps, but the attempted provisioning write was denied. The response does not establish whether role scope, team policy or another account condition caused the denial. Do not retry through undocumented APIs or use another application's provisioning profile.

After the app record and matching profile exist, set the three missing protected values. Verify the profile's application identifier equals the selected team plus the exact Roomwave bundle, is unexpired, contains the intended signing certificate, has no development devices, and has `get-task-allow=false`.

## Release workflow

`testflight.yml` is manual and accepts:
- `export_ipa=true`: validate native paths, sign and export.
- `upload=true`: also verify the numeric Apple app record and upload through Xcode's transporter tooling.

Validation runs shared Swift tests and the real native simulator tests for photo import and the layered model, then creates an unsigned generic-device Release archive and verifies its actual bundle, model, icon catalog and elapsed-time privacy manifest. A core-only or OpenUSD-only pass does not establish RealityKit loading.

The release job creates an ephemeral keychain, verifies the Apple-issued profile and compiled app identity, exports a signed IPA, and optionally uploads it. Secret material and the temporary keychain are removed on exit; the previous keychain search list is restored. The selected signing certificate must be included in the profile. Artifacts contain validation evidence and receipts; private signing material and the IPA are not published as repository artifacts.

Build numbers use the workflow run number and attempt. Receipts record the actual source commit, version, build, signature verification and IPA SHA-256. Apple's processing result is recorded separately with a bounded wait. Upload acceptance is not TestFlight availability.

Before announcing availability, verify the exact Apple build is VALID, compliance is resolved, the intended internal group can access it and intended tester membership is known. Sending new tester invitation emails requires its own user authorization.

## Primary references

- https://developer.apple.com/documentation/appstoreconnectapi/apps
- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/
