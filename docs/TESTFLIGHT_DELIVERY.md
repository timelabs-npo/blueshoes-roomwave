# Roomwave TestFlight delivery

The user authorized replacing the existing Molecular/Molecule Foundry beta with Roomwave. Roomwave is delivered under the existing Apple identity below. This workflow uploads a TestFlight beta; it does not submit or publish an App Store production update.

| Field | Verified identity |
| --- | --- |
| App Store Connect record | Molecule Foundry |
| Apple app ID | `6837899703` |
| Bundle identifier | `org.timelabs.moleculefoundry` |
| Team | `398XACWZ7G` |
| Existing SKU | `timelabs-molecule-foundry-ios` |
| New Roomwave beta version | `0.2.0` |
| Profile | `Molecule Foundry App Store 20261122` |
| Profile resource ID | `9Z3RDGACJK` |
| Profile UUID | `992b95c3-e451-48f8-b3bd-c4cc541173a3` |
| Internal group | Molecule Foundry Developers |
| Internal group ID | `5a93cfb4-bd7c-4c0c-acbd-ade02816d8c1` |

The native app name and content are Roomwave. TestFlight's app listing can still display the existing Molecule Foundry record name. The original Molecule Foundry source/release configuration and its App Store draft are unchanged.

## Verified configuration, 24 November 2026 UTC

The Apple API inventory uniquely matched the existing app to the Molecule Foundry release configuration. Its previous TestFlight build is `0.1.0 (23.1)`, with processing state VALID. The App Store draft is `1.0`, PREPARE_FOR_SUBMISSION; this beta release does not change it.

The matching profile is IOS_APP_STORE, ACTIVE, expires 7 November 2027, and contains the same existing distribution certificate as the protected P12. Its application identifier is `398XACWZ7G.org.timelabs.moleculefoundry`. It contains no development device list and has `get-task-allow=false`.

The profile was transferred in memory to the Roomwave repository's protected `testflight` environment. All four required encrypted secrets are configured: `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD`, `APP_STORE_PROFILE_BASE64`, and `ASC_PRIVATE_KEY_P8_BASE64`. The team, bundle, profile name, numeric Apple app ID, ASC key ID and issuer variables are configured. No credential content or signing files are committed.

Release source must be the reviewed default branch `main`. The environment remains restricted to main and requires approval of the exact run by the release owner. An already authorized operator can approve the concrete run while preserving its protections.

The abandoned new-bundle plan received an Apple registration 403 and had no app record. The authorized reuse uses the existing correctly matched identity; it requires no new Bundle ID creation or browser sign-in. Do not issue new provisioning writes to work around the earlier denial.

## Release workflow

`testflight.yml` is manual and accepts:

- `export_ipa=true`: validate native paths, sign and export.
- `upload=true`: also verify the exact Apple app ID/bundle and unused build number, then upload through Xcode's transporter tooling.

Validation always runs shared Swift tests and the native simulator tests for photo import and the layered model. Validate-only runs then create an unsigned generic-device Release archive and verify its actual bundle, model, icon catalog and elapsed-time privacy manifest. For signed export or upload, validation defers the Release archive to the protected release job, which creates and verifies the signed archive before export/upload; this avoids compiling both unsigned and signed Release archives in one run. A core-only or OpenUSD-only pass does not establish RealityKit loading.

The release job creates an ephemeral keychain, verifies the Apple-issued profile and compiled app identity, exports a signed IPA, and optionally uploads it. Secret material and the temporary keychain are removed on exit; the previous keychain search list is restored. The selected signing certificate must be included in the profile. An already installed byte-identical profile is reused and left intact; a conflicting profile is never overwritten. Artifacts contain validation evidence and receipts; signing material and the IPA are not published as repository artifacts.

Build numbers use `(1000 + GITHUB_RUN_NUMBER).GITHUB_RUN_ATTEMPT`, above the existing `23.1` range. Preflight rejects a number already present in the Apple app. Marketing version is `0.2.0`. Receipts record the actual source commit, app ID, version, build, signature verification and IPA SHA-256. Apple's processing result is recorded separately with a bounded wait. Upload acceptance is not TestFlight availability.

## Internal availability

The existing internal group has two testers and does not automatically receive every new build. After the exact `0.2.0` build becomes VALID, associate that build with the existing group using Apple's documented beta-group relationship endpoint. Verify the app/group association, build membership, resolved compliance and internal beta state before announcing availability. Do not create new testers or send invitation emails as part of this release.

If Apple's processing is still pending when the bounded check ends, continue from the recorded exact build number; do not upload a duplicate binary merely to poll its status. Existing installations of the same bundle can be updated by this Roomwave beta, replacing the previous Molecule Foundry app content on those devices.

## Requests after the exact build ID is verified

An authorized operator performs these only for app `6837899703`, version `0.2.0`, and the recorded new build number:

1. Read `GET /v1/builds/BUILD_ID?include=app,preReleaseVersion`. Require the expected app/bundle/version/build, `processingState=VALID`, `expired=false`, and `usesNonExemptEncryption=false`.
2. Read `GET /v1/builds/BUILD_ID/betaBuildLocalizations`. If an `en-US` localization does not exist, create it with the payload below; otherwise update that existing localization's `whatToTest` field only.
3. Read `GET /v1/betaGroups/5a93cfb4-bd7c-4c0c-acbd-ade02816d8c1/app` and require app `6837899703`. Require the group to remain internal. Read its existing build relationships, then add the exact new build only if absent.
4. Read `GET /v1/builds/BUILD_ID/buildBetaDetail` and the group's build relationship again. Confirm `internalBuildState=IN_BETA_TESTING`, resolved encryption compliance, and the build ID in the existing group. Confirm tester membership count without printing addresses. Do not claim a physical installation from API availability alone.

Create the build-specific TestFlight notes:

```http
POST /v1/betaBuildLocalizations
Content-Type: application/json
```

```json
{
  "data": {
    "type": "betaBuildLocalizations",
    "attributes": {
      "locale": "en-US",
      "whatToTest": "Roomwave pilot: import a photo to generate a stylized map, or start the synthetic demo. Photo conversion uses image features; it does not reconstruct measured depth. On a supported LiDAR device, test room capture and the generated course. Check the rider's skeleton, muscular, skin and coat layers and animation. Test steering, banking, collision and restart. Report frame-rate issues, unreadable obstacles or photo/capture failures."
    },
    "relationships": { "build": { "data": { "type": "builds", "id": "BUILD_ID" } } }
  }
}
```

Add access for the existing internal group:

```http
POST /v1/betaGroups/5a93cfb4-bd7c-4c0c-acbd-ade02816d8c1/relationships/builds
Content-Type: application/json
```

```json
{"data":[{"type":"builds","id":"BUILD_ID"}]}
```

These requests update only build-specific test notes and existing-group access. They do not create testers, send invitation requests, rename the App Store record, change the App Store draft, or submit the app for production review.

## Primary references

- https://developer.apple.com/documentation/appstoreconnectapi/apps
- https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/
- https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds
- https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate

- https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betabuildlocalizations
