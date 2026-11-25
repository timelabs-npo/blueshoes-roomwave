# Finalize the existing internal TestFlight pilot

`scripts/release/finalize-internal.mjs` operates only on app `6837899703`, bundle `org.timelabs.moleculefoundry`, iOS version `0.3.0`, and the existing internal group `5a93cfb4-bd7c-4c0c-acbd-ade02816d8c1`. It requires an exact Apple build UUID, observed `VALID`/`APP_STORE_ELIGIBLE`, unexpired build, and matching app/version relationships. It verifies the group's membership in this app and its internal flag. It creates no groups or testers and calls no invitation or notification endpoint. Apple's own internal-tester delivery behavior remains a platform responsibility.

The default is read-only against Apple. It does **not** read or require external Beta App Review contact information. Missing external review contact therefore cannot block the authorized internal pilot.

Use Node 22+ and the same protected `APP_STORE_APP_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY_P8_BASE64` environment as the existing release helper. The imported `protectedClient` holds the key/JWT in memory, limits requests to Apple's fixed API origin, refuses redirects and emits no secret values. No hardcoded credential path is added.

## Preflight and apply

Replace the deliberately invalid UUID/path placeholders below with the actual build and operator directory:

```sh
node scripts/release/finalize-internal.mjs \
  --build-id EXACT_APPLE_BUILD_UUID \
  --compiled-identity-receipt /private/release/compiled-identity.json \
  --state-dir /private/operator/roomwave-testflight

node scripts/release/finalize-internal.mjs --apply \
  --build-id EXACT_APPLE_BUILD_UUID \
  --compiled-identity-receipt /private/release/compiled-identity.json \
  --state-dir /private/operator/roomwave-testflight
```

The optional compiled receipt must come from the verifier run against the actual compiled app/archive/IPA. Its relevant fields are `bundle`, `version`, `build`, `identity_verified: true`, and an **explicit Boolean `usesNonExemptEncryption: false`**. Bundle, marketing version and build number must exactly match the Apple build. An optional `apple_build_id` must also match. The receipt is trusted operator evidence, so do not manufacture or hand-edit a false declaration merely to pass this guard.

If Apple already reports `usesNonExemptEncryption=false`, no receipt or encryption PATCH is required. If the Apple declaration is unset, the matching explicit compiled receipt is mandatory before setting it to false. If Apple reports true, the helper blocks the conflicting declaration even when a false receipt is supplied. A receipt that omits the explicit encryption field is insufficient. The compiled-app verifier emits this explicit field only after checking the actual Info.plist declaration.

`--apply` then:

1. Resolves an unset encryption declaration only from the evidence above.
2. Sets `autoNotifyEnabled=false`.
3. Updates the existing en-US app beta description, repository marketing/privacy URLs and privately reused feedback email.
4. Creates or updates the exact build's en-US **`whatsNew`**. Its control instruction explicitly says: **release before touchdown for a clean landing**.
5. Associates only this build with the verified existing internal group, preserving older builds and testers.
6. Reads back the exact metadata, encryption flag, group membership and internal state.

The marketing and privacy URLs must return HTTP 200 before any mutation. The current policy target is https://github.com/timelabs-npo/blueshoes-roomwave/blob/main/docs/PRIVACY.md . Availability of the URL does not replace the coordinator's policy-content review.

## Results and recovery

`PREFLIGHT_READY` is a read-only result and includes whether staging/availability is already observed. Applied success requires exact membership and Apple `internalBuildState=IN_BETA_TESTING`, producing `INTERNAL_BETA_AVAILABLE`. It still reports `tester_installation_verified=false`; API availability does not prove physical installation.

If membership is visible but Apple's state has not reached `IN_BETA_TESTING`, the result is `INTERNAL_ACTIVATION_PENDING`, exit code 2. Re-run read-only preflight after new state evidence. No upload retry or polling loop is added. Other blockers also return exit 2 with sanitized reasons; no contact or feedback-email value is printed.

This helper reuses the public-beta helper's single-operator `Journal`. Use the **same protected state directory** for related operator calls. Its on-disk names remain `public-beta-journal.json` and `public-beta.lock`; the journal is shared TestFlight operation evidence, not a public-enrollment action. An intent is persisted before localization/association POSTs. Matching readback resolves it; an uncertain outcome with no matching observed resource blocks a repeat POST. A stale lock is never automatically stolen. Inspect the original process before clearing one.

The sanitized final receipt is `internal-BUILD_UUID.json` in that directory. Repeating an already completed finalization makes no duplicate localization/association and makes no unnecessary PATCH.

The protected release script invokes this helper after the exact uploaded build reaches `VALID`, using its actual IPA identity receipt. It preserves the operation journal and sanitized internal receipt in the release artifact. If processing or activation remains pending, reconcile the same Apple build; do not upload again merely because the later stage is incomplete.

Internal and external helpers share the same default description and `whatsNew`, including clean-landing instructions. If a reviewed custom `--content-file` is used, pass that same file to both helpers. Cross-helper regression tests run public staging, internal finalization, and public submission preflight and require the reviewed metadata to remain unchanged.

## Evidence limits

Isolated tests invoke the real JavaScript helper with a stateful fake Apple API and temporary real journal. They cover default read-only behavior, no external-contact dependency, exact identity/internal-group guards, encryption proof and conflict handling, correct `whatsNew`, notification suppression, membership readback, pending activation, idempotency, unknown POST outcomes and PII-free receipts.

No live Apple mutation, private key read, group/tester creation, invitation or device installation was performed while implementing this helper. Local tests ran on Node 24.22.3; GitHub continuity runs also passed with the workflow's Node 22 runtime. Actual release actions and observed outcomes belong in the delivery record.

Official API references: [modify a build](https://developer.apple.com/documentation/appstoreconnectapi/patch-v1-builds-_id_), [build beta details](https://developer.apple.com/documentation/appstoreconnectapi/build-beta-details), [beta build localization fields](https://developer.apple.com/documentation/AppStoreConnectAPI/BetaBuildLocalizationCreateRequest/Data-data.dictionary/Attributes-data.dictionary), and [add builds to an existing beta group](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds).
