# Release evidence — 0.3.0 (1004.1)

**Apple accepted the signed upload and processed the exact build to `VALID`.**
Subsequent distribution API operations returned HTTP 403. This record preserves
those distinct outcomes, the readback observed through **26 November 2026,
08:54:38 UTC / 11:54:38 Europe/Moscow**, and the browser sign-in boundary captured
at 08:56:40 UTC / 11:56:40 Europe/Moscow. It does not claim public TestFlight
availability. Fractional seconds are omitted.

## Exact binary and source binding

| Field | Verified value |
| --- | --- |
| Repository | `timelabs-npo/blueshoes-roomwave` |
| Uploaded source | [`5af27ee4bbc7231d5f45ceba5bec40ade70ea4bc`](https://github.com/timelabs-npo/blueshoes-roomwave/commit/5af27ee4bbc7231d5f45ceba5bec40ade70ea4bc) |
| Uploaded source tree | `f0442be562fd4b268c953af4e9f89018272f3045` |
| Workflow | [Run `45781149685`](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45781149685), number **4**, attempt **1** |
| Allocation | `github:timelabs-npo/blueshoes-roomwave:45781149685:1` |
| App / bundle | `6837899703` / `org.timelabs.moleculefoundry` |
| Version / build | `0.3.0` / `1004.1` |
| Apple build UUID | `d9a65d0d-191b-449c-9780-28c2eafcc551` |
| Signed IPA SHA-256 | `3960c56c03e976a48847e02628d976cf254913c1a4d7e1162903b0728ec6b9fd` |
| dSYM archive SHA-256 | `38775a9f44d05ef290b698fc85d6d74880e3bc7e5f04ed078d441fad9f656dec` |
| Matching executable/dSYM arm64 UUID | `2949FC5F-DB56-3B14-AF48-4C5A41CECB5B` |

The later main commit
[`97daf1ea80c055a43651d5df9ba581c2eeb365f9`](https://github.com/timelabs-npo/blueshoes-roomwave/commit/97daf1ea80c055a43651d5df9ba581c2eeb365f9)
adds release-observation and public-beta receipt hardening. The diff from the
uploaded source contains documentation, continuity/public-beta scripts and their
tests; no native app source changed in that diff. The uploaded binary's source
remains **`5af27ee4…`** and must not be relabeled as built from the later commit.

## Native validation and signed artifact evidence

Validation job `139776657521` used the exact uploaded source. All **18 hosted
native tests** passed. The ordinary touch/pause/background/results/retry/course
UI scenario passed in **135.895 seconds**. The validation record also retains
60 core XCTest labels. The unchanged native verifier accepted these eight actual
ARView captures: `home-dawn`, `home-orbit`, `home-midnight`, `charged`, `airborne`,
`landing`, `paused` and `results`.

The collector used `observer_checkpoint`; no capture pairs were missing.
Independent inspection verified **40 manifest file entries** by exact size and
SHA-256 across the evidence sets, with source/run and launch identity binding.
The Simulator identity was version `0.3.0`, build `1`; the separately allocated
signed distribution build is `1004.1`.

The protected macOS job executed exported-signature and distribution-profile
verification. Its preserved receipt reports those checks and dSYM verification
successful. An independent Linux reader verified the immutable upload-intent ZIP,
IPA identity, contained digests and the executable/dSYM UUID relationship. That
reader did not re-execute macOS `codesign`.

| Independently verified artifact | ID | Bytes | SHA-256 |
| --- | ---: | ---: | --- |
| Native validation review | `15099406816` | 21,503,115 | `da08bd035b6ba9956a5018179c5a2995449b73cc70393fb6b781ced496bf1085` |
| Preserved signed upload intent | `15100240352` | 7,004,965 | `1a86627b220f633eb6a09e01498c2d0d0bd74216ceb5440e333c46321a633d8d` |
| Final release evidence | `15099891903` | 2,037,128 | `faf12517c76936b2cc9124aa7ace693ab2de5fe7e5fe2061512c542283b068a1` |

The final and pre-upload artifacts contain matching allocation, signature,
identity and dSYM bytes. The trusted promotion tuple was independently checked.
Human playtesting and physical-device performance remain unmeasured.

## Upload and processing timeline

| Event, 26 November 2026 | UTC | Europe/Moscow | Observation |
| --- | --- | --- | --- |
| Release allocation | 08:32:00 | 11:32:00 | Build `1004.1` reserved for this run |
| Preserved intent consumed | 08:33:42 | 11:33:42 | One upload attempt began |
| Upload accepted | **08:34:57** | **11:34:57** | `upload_accepted: true` in final receipt |
| Apple processing observed | **08:36:29** | **11:36:29** | `VALID`, exact Apple UUID above |
| Internal-distribution helper stopped | 08:36:35 | 11:36:35 | Apple PATCH returned HTTP 403 |
| Release job completed | 08:36:42 | 11:36:42 | Overall job conclusion: failure |

The earlier `upload-consumed.json` records an initially unconfirmed outcome;
the later accepted-upload and `VALID` processing receipts resolve that upload
outcome. The workflow's overall failure occurred **after** successful upload and
processing. **Do not reupload this binary or allocate another build to repair a
distribution-access failure.** Continue with the existing Apple build UUID.

## Distribution API observations

The internal helper's last preserved inspection had non-exempt encryption false
and automatic notification enabled. Source control flow therefore indicates its
first PATCH would disable automatic notification in `buildBetaDetails`. This is
an inference from the inspected state and helper sequence; the original generic
HTTP 403 report does not identify the denied resource or the account's role.
Its empty confirmed-mutation list is not an exhaustive proof of server state.

The public-beta checks used the ordinary protected provider and the accepted
binary's verified source/allocation tuple. Review-contact presence and availability
were verified; contact values and proposed metadata are omitted from this record.

| Public-beta observation | UTC | Europe/Moscow | Result |
| --- | --- | --- | --- |
| Preflight | 08:44:10 | 11:44:10 | `PREFLIGHT_READY`, HTTP 200 |
| Requested staging | 08:45:57 | 11:45:57 | `BLOCKED_ERROR`, HTTP 403, `uncertain_write: true`, `mutations: []` |
| Fresh read-only reconciliation | **08:54:38** | **11:54:38** | `PREFLIGHT_READY`, HTTP 200, read request `uncertain_write: false` |

Both the preflight and fresh reconciliation observed the existing build as
`VALID`, `APP_STORE_ELIGIBLE` and `READY_FOR_BETA_SUBMISSION`. For the target
external-beta configuration, the inspected `group_id` and `review_submission_id`
were null, exact-build association was false, metadata staging was incomplete and
no enabled public link was observed. Automatic notification remained enabled. Review
contact presence and availability remained true.

The staging report's empty `mutations` list records no confirmed completed
mutation. Its `uncertain_write: true` required a fresh readback. The later
reconciliation confirms the **tracked distribution fields** above; it does not
prove that no partial metadata write occurred anywhere. No role, entitlement or
account restriction is inferred solely from the HTTP status.

## Continuation boundary

The coordinator opened the ordinary existing App Store Connect page after the
API failures. The browser screenshot captured at **08:56:40 UTC / 11:56:40
Europe/Moscow** shows an Apple Account sign-in wall and a Windows Security passkey
confirmation prompt. The existing session therefore did not expose authenticated
TestFlight controls at that observation. No UI distribution mutation was performed.
The screenshot remains private because it contains authentication UI. External
review approval, active external testing, tester installation and public-link
access still require their own observed evidence.

Operator proof references retained outside the public repository include
`verified-validation.json`, `verified-upload-intent.json`,
`verified-accepted-processing-blocker.json`, `promotion-binding-verified.json`,
and the final release receipts. Distribution observations are identified by
`public-preflight-20261126T084403060Z.json`,
`public-stage-20261126T084549073Z.json` and
`public-reconcile-20261126T085431420Z.json`. No credentials, contacts, raw proposed
metadata, absolute host paths or unrelated account data are copied here.
