# Roomwave TestFlight identity and pilot history

The active arcade rebuild is **0.3.0**. See [arcade acceptance](ARCADE_ACCEPTANCE.md), [continuity](CONTINUITY.md) and [external-beta operations](PUBLIC_BETA.md). The 0.2.0 receipt below is historical and remains preserved at `archive/20261125-pilot-1002-1`; it does not establish the new arcade's readiness.

The user authorized replacing the existing Molecular/Molecule Foundry beta with Roomwave. Roomwave is delivered under the existing Apple identity below. This workflow uploads a TestFlight beta; it does not submit or publish an App Store production update.

## Accepted v0.3 build and current distribution boundary

The active app is **Roomwave · Slipstream 0.3.0**. Apple accepted **0.3.0 (1004.1)** at **11:34:57 Europe/Moscow on 26 November 2026** and processing was observed as **VALID** at **11:36:29**. The exact build is already uploaded; do not dispatch or upload another binary to resolve the distribution-access failure.

| Field | Verified current release |
| --- | --- |
| Existing app / bundle | `6837899703` / `org.timelabs.moleculefoundry` |
| Signed source | `5af27ee4bbc7231d5f45ceba5bec40ade70ea4bc` |
| Version / build | `0.3.0 (1004.1)` |
| Apple build UUID | `d9a65d0d-191b-449c-9780-28c2eafcc551` |
| Protected release run | [45781149685](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45781149685), number 4, attempt 1 |
| Native evidence | 18 hosted tests; ordinary touch UI scenario passed; eight actual ARView captures |
| Upload and processing | Accepted; `VALID` |
| Later distribution outcome | Internal finalization and public staging returned HTTP 403 |
| External state at 11:54:38 Europe/Moscow | `READY_FOR_BETA_SUBMISSION`; target group and review submission absent |
| Public availability | No verified public link or active external testing |

The complete [1004.1 evidence record](evidence/RELEASE_1004_1.md) retains artifact digests, exact source binding, operation outcomes and reconciliation limits. Its successful upload and processing are separate from the workflow's later failure. The later `97daf1ea80c055a43651d5df9ba581c2eeb365f9` changes release-observation logic, documentation and tests; it does not change the source identity of the uploaded IPA.

The ordinary App Store Connect browser fallback reached an Apple Account sign-in wall with a passkey confirmation prompt. An authenticated browser session is needed before that UI can perform the remaining staging and review actions. No UI submission or Apple review approval is claimed.

## Procedure for a future binary

The following allocation/signing procedure applies only when a new binary is deliberately required. **For the current 1004.1 build, continue from its existing UUID and receipts.**

Dispatch `testflight.yml` once from reviewed `main` with the exact `expected_sha`, `export_ipa=true` and `upload=true`. Read the allocated GitHub run identity and require attempt **1**. Claim the resulting `(1000 + run_number).1` build in the authoritative continuity store **before approving the protected release job**. Do not guess the next run number. The main-only environment and required reviewer remain in place.

The protected job persists `release-allocation.json` as an immutable artifact before signing. Signing/export cannot upload. For an upload, the exact compiled identity, signed IPA, SHA-256 and `upload-intent.json` are preserved in a second artifact before the upload step. That step requires both artifact IDs and exclusively consumes the exact intent before invoking Apple's transporter. Workflow reruns are blocked from signing or uploading; a second invocation in the same job also cannot consume the intent twice. After a failed or interrupted upload, inspect the existing allocation/build in Apple and reconcile its actual state. A new binary needs a new explicit dispatch and a new coordinator claim, not an automatic retry.

The preserved signed IPA is a release artifact, not a source-repository file. Neither artifact contains signing keys or private contact data. A receipt proves only its observed stage: `upload_accepted=false` in the pre-upload artifact is expected; the later release receipt records a successful transporter response. Public promotion additionally requires the trusted exact-run source, compiled, upload and processing receipts described in [external-beta operations](PUBLIC_BETA.md).

After signing/upload, the workflow observes the exact Apple build and calls [internal finalization](INTERNAL_BETA.md) with the actual IPA identity receipt. It updates truthful beta metadata and associates only the exact build with the existing internal group. If processing or activation remains pending, reconcile that same UUID; do not upload again to poll it. Credentials and signing material remain protected.

The fresh external preflight and reconciliation on 26 November 2026 verified that a complete review contact is present and available in the existing Apple record. No contact values are copied into the repository, and no replacement contact is required by that observation. [External beta operations](PUBLIC_BETA.md) keeps exact-build review and public-link checks separate from internal availability. No public link, invitation or community post is claimed.

The installed app name is Roomwave. The Apple listing was still **Molecule Foundry**. A guarded name-only PATCH requesting **Roomwave Slipstream** returned HTTP **403** at 20:06:08 UTC on 25 November 2026. No successful rename is claimed. Authorized access to that exact metadata operation, or an owner-performed change, is required. This denial is not bypassed with a different identity or broader mutation.

## Archived 0.2 pilot reference

**Everything below records the earlier pilot and its original procedure. Do not use its 0.2.0 payloads to finalize the new arcade.** The active procedure is above; full historical source remains on [archive/20261125-pilot-1002-1](https://github.com/timelabs-npo/blueshoes-roomwave/tree/archive/20261125-pilot-1002-1).

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

- `expected_sha`: the exact reviewed main commit; the job fails if the dispatched source differs.
- `export_ipa=true`: validate native paths, sign and export.
- `upload=true`: also verify the exact Apple app ID/bundle and unused build number, then upload through Xcode's transporter tooling.

Validation always runs shared Swift tests and the native simulator tests for photo import and the layered model. Validate-only runs then create an unsigned generic-device Release archive and verify its actual bundle, model, icon catalog and elapsed-time privacy manifest. For signed export or upload, validation defers the Release archive to the protected release job, which creates and verifies the signed archive before export/upload; this avoids compiling both unsigned and signed Release archives in one run. A core-only or OpenUSD-only pass does not establish RealityKit loading.

The release job creates an ephemeral keychain, verifies the Apple-issued profile and compiled app identity, exports a signed IPA, and optionally uploads it. Secret material and the temporary keychain are removed on exit; the previous keychain search list is restored. The selected signing certificate must be included in the profile. An already installed byte-identical profile is reused and left intact; a conflicting profile is never overwritten. Artifacts contain validation evidence and receipts; signing material and the IPA are not published as repository artifacts.

Build numbers use `(1000 + GITHUB_RUN_NUMBER).GITHUB_RUN_ATTEMPT`, above the existing `23.1` range. Preflight rejects a number already present in the Apple app. Marketing version now comes from the root `VERSION` file. Receipts record the actual source commit, app ID, version, build, signature verification and IPA SHA-256. Apple's processing result is recorded separately with a bounded wait. Upload acceptance is not TestFlight availability.

## Internal availability

The existing internal group has two testers and does not automatically receive every new build. After the exact `0.2.0` build becomes VALID, associate that build with the existing group using Apple's documented beta-group relationship endpoint. Verify the app/group association, build membership, resolved compliance and internal beta state before announcing availability. Do not create new testers or send invitation emails as part of this release.

If Apple's processing is still pending when the bounded check ends, continue from the recorded exact build number; do not upload a duplicate binary merely to poll its status. Existing installations of the same bundle can be updated by this Roomwave beta, replacing the previous Molecule Foundry app content on those devices.

## Released TestFlight pilot, 24 November 2026 UTC

| Evidence | Confirmed result |
| --- | --- |
| Native app | Roomwave |
| Existing Apple app / bundle | `6837899703` / `org.timelabs.moleculefoundry` |
| Version and build | `0.2.0 (1002.1)` |
| Apple build ID | `e61844d6-732b-4162-a27f-e7ee52c1a817` |
| Source commit | `2d09b2484cd16ceea8ff9bbc85eca6318b94ade4` |
| Release workflow | [45506909397](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45506909397), SUCCESS |
| Validation | Core/native checks, signed archive, export and compiled identity verification passed |
| Upload | Accepted |
| Apple processing | VALID; independently observed 23:28 UTC |
| Encryption compliance | `usesNonExemptEncryption=false` |
| Expiration status | Not expired |
| Internal group availability | `IN_BETA_TESTING`; exact build verified in Molecule Foundry Developers |
| Existing testers | 2; selected account already present |
| Build notes | `en-US` notes independently verified |
| Final availability verification | 23:37:54 UTC |

The earlier attempt `0.2.0 (1001.1)` was rejected during upload because its universal app declaration omitted an iPad multitasking orientation. The source above includes all required iPad orientations and verifies the compiled declaration. The accepted `1002.1` build is the pilot to use; no duplicate upload is needed.

The TestFlight user-facing What to Test text uses the API attribute `whatsNew` on `betaBuildLocalizations`. The final Apple API receipt confirms group membership and internal availability. The selected tester record reports `INSTALLED`; that account-level state does not prove installation of this new build. No new testers or invitations were created, and App Store production metadata was unchanged.

## Requests after the exact build ID is verified

An authorized operator performs these only for app `6837899703`, version `0.2.0`, and the recorded new build number:

1. Read `GET /v1/builds/BUILD_ID?include=app,preReleaseVersion`. Require the expected app/bundle/version/build, `processingState=VALID`, `expired=false`, and `usesNonExemptEncryption=false`.
2. Read `GET /v1/builds/BUILD_ID/betaBuildLocalizations`. If an `en-US` localization does not exist, create it with the payload below; otherwise update that existing localization's `whatsNew` field only.
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
      "whatsNew": "Roomwave pilot: import a photo to generate a stylized map, or start the synthetic demo. Photo conversion uses image features; it does not reconstruct measured depth. On a supported LiDAR device, test room capture and the generated course. Check the rider's skeleton, muscular, skin and coat layers and animation. Test steering, banking, collision and restart. Report frame-rate issues, unreadable obstacles or photo/capture failures."
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

- https://developer.apple.com/documentation/appstoreconnectapi/betabuildlocalizationupdaterequest/data-data.dictionary/attributes-data.dictionary
