# External TestFlight staging for Roomwave 0.3.0

`scripts/release/public-beta.mjs` prepares the external beta under the existing authorized app. It has **no upload, signing, tester-invitation, notification, social-posting or purchasing operation**. The default action is read-only against Apple. Each mutation stage requires its named action and `--apply`.

The helper is restricted to:

| Identity | Required value |
| --- | --- |
| App | `6837899703` |
| Bundle | `org.timelabs.moleculefoundry` |
| Prerelease version/platform | `0.3.0` / `IOS` |
| Build | An explicitly supplied Apple build UUID, verified through its app and prerelease relationships |
| Build eligibility | `VALID`, `APP_STORE_ELIGIBLE`, `expired=false`, future expiration |
| External group | `Roomwave Public Beta`, restricted to the exact build |
| Public enrollment cap | 200, limit enabled |

The existing 0.2.0 internal pilot cannot pass these identity checks. An archive, upload receipt or successful CI run is not a substitute for Apple's observed build state.

## Protected inputs

Use Node 22 or later and the existing protected release environment:

- `APP_STORE_APP_ID=6837899703`
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY_P8_BASE64`

The helper constructs a short-lived ES256 JWT in memory. It accepts only the fixed Apple API origin, refuses redirects, bounds each request, and never prints key/token values or Apple error details that could echo private input. It has no hardcoded secret-file path. Do not put credential values into commands, task manifests, output logs, GitHub issue text or this repository.

The real Beta App Review contact remains required. Supply it in a private JSON file **outside the repository**, with owner-only file permissions on POSIX and an appropriately restricted ACL on Windows. Its keys are `firstName`, `lastName`, `email`, and `phone`; the phone must begin with `+` and its country code. These fields must identify a real available person. No name, email or phone is invented by the helper. It can reuse a complete existing Apple contact after one has been entered privately.

The contact file's values are used only in the Apple review-detail PATCH. Receipts record whether contact information is present, never its values. The existing Apple `feedbackEmail` is reused in memory without printing or writing its value to receipts. A missing feedback email blocks staging; the helper does not guess one.

## Review the actual metadata

The default en-US content is exported as `DEFAULT_CONTENT` near the top of the script. It describes the new hold/compress, release/launch, airborne dive, three-course score-attack game, local bests and deliberate sharing. The build's **`whatsNew`** asks testers to exercise controls, collision readability, pause/background behavior, audio/haptics, persistence and sharing. It does not claim device measurements, Apple Arcade selection, awards, viral success or completed public review.

Before applying it, the coordinator must compare this copy with the actual validated 0.3.0 build. A reviewed JSON override can supply `description`, `whatsNew` and `reviewNotes` with `--content-file`. These values must describe the real build; do not put contact details or credentials in descriptions or notes. The helper stages `demoAccountRequired=false` because the intended core experience is available offline without login. If that changes, do not use this configuration until the review flow and helper are updated.

Marketing URL: https://github.com/timelabs-npo/blueshoes-roomwave

Privacy URL: https://github.com/timelabs-npo/blueshoes-roomwave/blob/main/docs/PRIVACY.md

Both must return an observed HTTP 200 without redirects before any mutation. Root has prepared the new policy separately; this gate remains until it is actually public. A successful URL request only establishes availability: the coordinator must also verify the policy accurately describes the shipped data flows.

This helper supports the currently observed en-US metadata. If Apple has additional app/build locales, it reports `BLOCKED_LOCALIZATION` so the coordinator can prepare real translations. It will not silently replace other languages with English or leave stale chemistry descriptions unexamined.

## Sequence

Choose one protected, persistent operator directory for the app and reuse it for every action. The examples below use placeholders deliberately; replace the UUID/path with the actual verified build and private operator paths. Do not copy a proposed number from this document as an allocated build.

### 1. Read-only preflight

```sh
node scripts/release/public-beta.mjs preflight \
  --build-id EXACT_APPLE_BUILD_UUID \
  --contact-file /private/operator/review-contact.json \
  --state-dir /private/operator/roomwave-public-beta
```

It reads the app, build ownership/version, eligibility, beta details, review submission, review contact, localizations, groups and exact group/build associations. It prints a sanitized report and proposed public metadata. `PREFLIGHT_READY` means the current input and eligibility checks passed; it does not mean metadata has been staged, Apple has approved the build, or a tester can install it.

An action without `--apply` remains a read-only preview. `submit` previews additionally require staged metadata; `enable-public-link` previews require both staging and observed approval. Plain `preflight` intentionally remains useful before staging.

### 2. Stage private metadata and group

```sh
node scripts/release/public-beta.mjs stage --apply \
  --build-id EXACT_APPLE_BUILD_UUID \
  --contact-file /private/operator/review-contact.json \
  --state-dir /private/operator/roomwave-public-beta
```

This action updates only the beta metadata, disables automatic tester notifications, creates/updates the en-US `whatsNew`, creates or reuses the external group, sets the enrollment cap to 200, and associates only the exact build. It leaves `publicLinkEnabled=false` and verifies the resulting metadata/relationship through fresh reads. Repeating a completed stage produces no duplicate group/localization/association.

The helper refuses an ambiguous group name, an internal target group, access-to-all-builds configuration, or a target group containing another build. It will not delete testers, remove someone else's build, or broaden access. A group that is already public requires coordinator review before restaging. A build with an existing review submission is preserved rather than silently changing its review metadata.

### 3. Submit the exact build for Beta App Review

```sh
node scripts/release/public-beta.mjs submit --apply \
  --build-id EXACT_APPLE_BUILD_UUID \
  --state-dir /private/operator/roomwave-public-beta
```

Actual Apple metadata, complete contact, no-login review instructions, `whatsNew`, disabled automatic notification and the exact group/build association must already match the reviewed content. The build must be `READY_FOR_BETA_SUBMISSION` if no submission exists. The helper creates one `betaAppReviewSubmissions` relationship to that UUID, preserves the returned submission ID, and reads it back.

Repeated invocation reuses `WAITING_FOR_REVIEW`, `IN_REVIEW` or `APPROVED` submissions. A rejected/unknown submission blocks automatic resubmission. No retry loop or waiting poll is added. Re-run read-only preflight when there is new evidence that Apple state changed.

### 4. Enable the public link after observed approval

```sh
node scripts/release/public-beta.mjs enable-public-link --apply \
  --build-id EXACT_APPLE_BUILD_UUID \
  --state-dir /private/operator/roomwave-public-beta
```

This requires the exact build's review submission to report **`APPROVED`** and its external state to report **`BETA_APPROVED` or `IN_BETA_TESTING`**. Eligibility, group membership and approval are refreshed immediately before enabling. The helper then reads back the enabled link and 200-person cap.

The result is `PUBLIC_LINK_ENABLED` with the actual Apple URL. It separately reports whether the build is already `IN_BETA_TESTING`. It always leaves `tester_access_verified=false`: an actual external installation still needs observation. No notification endpoint is called. If Apple still requires an activation/notification step for availability, that remains an explicit coordinator action with appropriate messaging authorization; the script does not present a merely enabled link as a verified installation.

## Interrupted operations and receipts

The operator directory contains an app-wide `public-beta-journal.json`, a single-operator lock and a sanitized receipt for each build UUID. The journal records a write intent **before** a resource-creating/associating POST, then the response ID and later readback. It stores methods, resource paths/IDs and timestamps, never request bodies, tokens or contact details.

If a response is lost or the process stops, a later preflight reads Apple's real resources. A matching observed group/localization/submission resolves the existing intent. If no matching resource is visible, another POST is blocked as `BLOCKED_RECONCILE`. Do not delete the intent or upload again to test whether an operation succeeded. Inspect the exact Apple state and protected operator evidence first. A changed resource ID conflicts with the preserved receipt rather than overwriting it.

PATCH operations are idempotent desired-state updates and are checked through readback. The lock uses exclusive file creation and is not automatically stolen: after a hard crash, inspect the original host/process before removing a stale lock. All invocations for this app must use the same protected operator directory; separate directories cannot provide cross-process idempotency.

Exit code 0 means the selected operation's checks/readback completed. Exit code 2 means a specific input, access, identity, metadata, approval, readback or reconciliation blocker. Receipts describe observed responses; they are not proof of game quality, Apple Arcade selection or a tester's installation.

## Official schema references checked

- [Beta app localization fields](https://developer.apple.com/documentation/appstoreconnectapi/betaapplocalizationupdaterequest/data-data.dictionary/attributes-data.dictionary): `description`, `feedbackEmail`, `marketingUrl`, `privacyPolicyUrl`.
- [Beta review contact/detail](https://developer.apple.com/documentation/appstoreconnectapi/betaappreviewdetail/attributes-data.dictionary) and [update endpoint](https://developer.apple.com/documentation/appstoreconnectapi/patch-v1-betaappreviewdetails-_id_): contact fields, `demoAccountRequired`, `notes`.
- [Beta build localization creation](https://developer.apple.com/documentation/AppStoreConnectAPI/BetaBuildLocalizationCreateRequest/Data-data.dictionary/Attributes-data.dictionary): `locale` and **`whatsNew`**.
- [Group creation attributes](https://developer.apple.com/documentation/appstoreconnectapi/betagroupcreaterequest/data-data.dictionary/attributes-data.dictionary) and [exact build association](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds).
- [Submit a build for beta review](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betaappreviewsubmissions), [submission build relationship](https://developer.apple.com/documentation/appstoreconnectapi/betaappreviewsubmissioncreaterequest/data-data.dictionary/relationships-data.dictionary), and [review states](https://developer.apple.com/documentation/appstoreconnectapi/betareviewstate).
- [External TestFlight process](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers): internal group prerequisite, external review, public link, and notification distinction.

## Validation performed

The Python test module invokes the actual JavaScript functions with a stateful, in-memory Apple API and a real temporary journal. It covers read-only defaults, app/version/audience/expiration guards, contact and privacy-URL blockers, correct `whatsNew`, exact private-group staging, repeated staging, PII-free receipts, one submission with preserved ID, rejected/pending review guards, approval-gated public links, unknown write outcomes and absence of upload/notification operations.

No live Apple mutation, private contact read, real key/token use, API write permission, external review, or tester installation was exercised during helper implementation. Local tests ran on Node 24.22.3; GitHub continuity runs also passed with the workflow's Node 22 runtime. Actual release actions and observed outcomes belong in the delivery record.
