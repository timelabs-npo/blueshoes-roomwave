# Bounded continuity for the arcade rebuild

This is an executable Python-standard-library coordinator, not a promise of an autonomous service running forever. It can enqueue owner-authored tasks, run up to three bounded local Codex subprocesses, persist receipts, inspect interruption state, require review, and import Wd or release observations. It does not upload builds, sign software, read credentials, call Apple/GitHub APIs, post on X, send mail, purchase anything, install Codex, or start daemons.

The current three Wd game workers are launched by the protected coordinator's existing launcher. Import their receipts instead of launching duplicate local work. The exact arcade baseline is `0f52279e465ae8ec9ebb806254f211722444236f`; use a new reviewed baseline for later tasks.

## What the implementation enforces

| Control | Implemented behavior |
| --- | --- |
| Single writer | OS advisory lock (`flock` on POSIX; `msvcrt.locking` on Windows) over the authoritative state directory. A second writer fails immediately. The OS releases the lock on process exit; a stale JSON heartbeat never grants permission to steal it. |
| Persistence | Each JSON snapshot is written to a unique temporary file, flushed/fsynced, then atomically replaced. POSIX also fsyncs the directory. Private state/attempt directories use mode 0700 where the OS supports it. |
| Lease | The active owner has a UUID, host/PID/start identity and a heartbeat every five seconds. Released leases remain visible for diagnosis. `status` reads snapshots without taking the writer lock. |
| Execution budget | At most three local workers; at most 1,200 seconds per run and per attempt. Each task also has an absolute UTC deadline. No implicit retry loop: the coordinator must inspect and call `resume`. Initial attempt plus at most two retries. |
| Ownership | Clean exact base required at enqueue, exact HEAD and optional branch checked before every launch/resume and after completion. Changed tracked/untracked paths must be owned. Frozen contract, app configuration and workflow files remain coordinator-only even under a broader directory claim. Ownership collisions block enqueue. |
| Interrupted work | Process host, PID and start identity are checked. Existing or unverifiable processes block replacement. Reused PIDs are never signalled. A completed model event without a durable successful exit receipt is interrupted work, not a pass. |
| Attempts | Every attempt has a distinct directory, prompt, event log, stderr, last message, process/session identity and exit receipt. Earlier evidence is preserved. Partial diff acknowledgement is required before retry. |
| Independent review | Successful exit + valid `turn.completed` JSON only gives `REVIEW_REQUIRED`. The coordinator must attach independent evidence to accept the task. A model's prose “PASS” never advances it. |
| Release identity | `claim-release` atomically reserves app/version/build once. Changing the source SHA does not permit a duplicate claim. Existing native/release workflows do not yet call this guard; they remain separately controlled. |
| Remote origin | Wd process IDs are retained only inside imported observations tagged with device ID and source path. They can never become local signalling/resume targets. A running/uncertain Wd task prevents a new local worker batch. |
| Public input | No issue/comment handler, shell command in a task, webhook listener, or public-feedback execution path exists. Owner-authored instructions are still executable authority: review them before enqueueing. |

Use **one stable state directory for the whole project**, shared by every invocation on that coordinator host. Locks and worker/release budgets apply to that directory, not to unrelated copies on different machines. Keep it on a local filesystem with reliable OS locks/atomic replacement; a sync folder or network filesystem needs separate qualification. Back it up with the ordinary protected project operations data. Do not commit runtime state, personal contact details, raw logs, tokens or prompt contents to the public repository. Wd and Linux should exchange sanitized receipts, not share control of each other's PID space.

## Run it

Python 3.10+ and Git are required. Actual local execution additionally needs an already-installed/authenticated `codex` CLI. Tests use a temporary fake executable and do not invoke an AI service or credentials.

```sh
python3 -m unittest discover -s tests/continuity -v
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state status
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state enqueue ops/tasks/external-review-contact.json
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state enqueue ops/tasks/apple-webhook-access.json
```

An owner-authored task is JSON with this shape. The worktree must already exist at the exact base and be clean. This example is a schema illustration; replace its paths and timestamp with a real, reviewed task. No implicit worktree creation or branch switching occurs.

```json
{
  "schema_version": 1,
  "task_id": "arcade-v03-experience-fix-01",
  "kind": "codex",
  "base_sha": "0f52279e465ae8ec9ebb806254f211722444236f",
  "worktree": "/absolute/path/to/isolated-worktree",
  "branch": "arcade-v03/experience-fix-01",
  "owned_paths": ["apps/ios/Roomwave/Arcade/ArcadeSession.swift"],
  "deadline_utc": "2026-11-25T19:00:00Z",
  "max_run_seconds": 1200,
  "max_retries": 2,
  "instructions": "Fix the specifically observed interruption recovery defect. Read the frozen contracts; edit only the assigned file. Record actual checks and remaining gaps.",
  "acceptance": ["Coordinator independently verifies pause, background, foreground and deliberate resume on the integrated native build."]
}
```

Paths are literal repository-relative paths. A trailing `/` claims a directory; no globbing, parent traversal or `.git` access is allowed. Future schemas can add more precise per-file capability controls; this implementation's ownership checks are detection gates in addition to Codex's workspace sandbox, not an operating-system sandbox that prevents every out-of-scope write. Ignore patterns may hide generated/untracked files from Git, so independently inspect task artifacts as well as the diff.

```sh
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state enqueue /protected/tasks/fix-01.json
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state run --max-workers 3 --budget-seconds 1200
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state status
```

`run` uses `codex exec --sandbox workspace-write --json --cd WORKTREE --output-last-message RESULT -`. It never requests an approval bypass. Codex keeps its ordinary authentication, sandbox and approval behavior. Task restrictions also prohibit recursive agents, daemons, commits, installs, credential inspection and external account mutations. A successful CLI exit means the command ran; the JSON state must still be inspected for failed/blocked tasks and acceptance gates.

## Resume after interruption

```sh
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state reconcile
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state status
```

Inspect each attempt's event/exit receipts and the actual diff at the recorded base. If a worker is alive or its origin/start identity is uncertain, inspect the original host and let its bounded owner resolve it. Do not launch another copy, signal an arbitrary PID, delete state to reset a budget, or interpret a stale heartbeat as proof of death.

For a verified local `FAILED`/`INTERRUPTED` task within its original deadline and retry allowance:

```sh
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state resume arcade-v03-experience-fix-01 --acknowledge-changes
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state run --max-workers 1 --budget-seconds 600
```

`resume` only requeues after inspection; `run` launches the next fresh Codex session. The previous session ID and all partial artifacts remain as evidence. It deliberately does not blindly reconnect an old CLI session with unknown context. If the task deadline or retry budget is exhausted, a coordinator reviews the failure and writes a new scoped successor task with a new bounded budget.

There is a narrow crash window between OS process creation and saving its PID identity. Missing/unverifiable identity produces `ORPHAN_RUNNING`, which blocks relaunch and requires inspection on the original host. This implementation does not offer an automatic “assume dead” escape hatch. It also does not guarantee descendant cleanup after an uncatchable coordinator kill/host loss; the original Wd launcher has its own bounded process-tree control. Normal timeout/interruption of a locally owned child terminates only its verified process group/tree.

After independent review:

```sh
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state review arcade-v03-experience-fix-01 --decision ACCEPTED --evidence /protected/review/fix-01.md
```

`CANCELLED` is available for non-running work with an evidence/reason reference. Accepted/cancelled/expired tasks release ownership claims; failed or unreviewed changes retain them. The coordinator remains responsible for commits, integration and reconciling accepted files into the next baseline.

## Import the existing Wd lanes

Copy the **sanitized** receipt from Wd to the coordinator through the already-authorized channel. Do not copy credentials or assume the copied manifest proves its own claims. The November 25 launcher uses `schemaVersion`, `taskID`, `baseCommit`, `startedAtUtc`, `deadlineAtUtc`, `heartbeatAtUtc`, `launcherPID`, `workerHostPID`, `sessionID`, `turnCompleted`, `exitCode`, `eventLog` and `lastMessage`.

```sh
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state reconcile \
  --wd-receipt /protected/receipts/gameplay.json \
  --device-id ce30a863-83e3-462c-9eba-212686435850 \
  --source-path 'C:\Users\wheel\blueshoes-roomwave-ops\arcade-20261125\gameplay\receipt.json' \
  --owned-path Sources/RoomwaveArcade/ \
  --owned-path Tests/RoomwaveArcadeTests/ \
  --owned-path docs/lanes/GAMEPLAY.md
```

Repeat for presentation/experience using their frozen ownership lists. A completed remote receipt with exit zero and `turnCompleted=true` becomes `REVIEW_REQUIRED`, never automatically accepted. Missing exit evidence becomes `EVIDENCE_INCOMPLETE`; an overdue running receipt becomes `EXTERNAL_RECONCILE_REQUIRED`. Import a fresh observation and inspect remote logs/diff before advancing. A repeated first-attempt receipt must retain its device, start time, base and ownership; use a separately reviewed task ID for a new remote attempt. Stale receipts and completed-to-started regressions are rejected.

## Release receipts and public-beta blockers

The signed release path stays under its existing protected environment. This supervisor has no upload implementation. The current workflow allocates `(1000 + run_number).1` only on the first attempt of an explicit dispatch. Signed release reruns are blocked: reconcile the preserved allocation and upload intent instead of assigning a new attempt-derived binary. Allocation and exact signed-binary intent artifacts are preserved before upload, and the upload step consumes an intent once. A **cooperating release coordinator** dispatches the exact reviewed main SHA once, reads the allocated run identity, and reserves that exact app/version/build before approving the protected release job. The validation job does not upload. Never guess the next run number or approve/upload before the claim succeeds:

```json
{
  "app_id": "6837899703",
  "version": "0.3.0",
  "build": "CHOOSE_A_NEW_BUILD_NUMBER",
  "source_sha": "EXACT_VALIDATED_40_CHARACTER_SHA"
}
```

The last example contains deliberate placeholders, not a valid or allocated release. Save a real identity as a private manifest, then:

```sh
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state claim-release /protected/release/identity.json
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state reconcile --release-receipt /protected/release/observed-build.json
```

An observed release receipt includes the same identity plus `state`, `observed_at`, `evidence`, and, once uploaded, `apple_build_id`. Later external stages require `review_submission_id` and `group_id`; `PUBLIC_BETA` additionally requires an actual `https://testflight.apple.com/join/...` URL. Valid stages are `INTENT_RECORDED`, `DISPATCHED`, `UPLOADED`, `PROCESSING`, `VALID`, `EXTERNAL_REVIEW_PENDING`, `EXTERNAL_APPROVED`, `PUBLIC_BETA`. States and build identity cannot regress or change. These are trusted operator observations with evidence, not an Apple API verifier. A failed/ambiguous dispatch keeps its claim: inspect its exact remote run/build before deciding what to do next. Do not upload again to check whether the first upload worked.

Two committed blockers preserve the actual read-only audit:

- **`BLOCKED_INPUT`:** App 6837899703's Beta App Review contact first/last name, phone and email were empty at 17:47 UTC on November 25. The draft production record had no reusable review contact. Obtain the real details privately; do not invent a person or put the values in this public repo.
- **`BLOCKED_ACCESS`:** The app's webhooks endpoint returned HTTP 403 `FORBIDDEN_ERROR` at 17:49 UTC. No receiver was provisioned and no webhook subscription was claimed. This denial does not establish that all other Apple API operations are denied.

The existing 0.2.0 (1002.1) internal pilot is `VALID` with external state `READY_FOR_BETA_SUBMISSION`, not approved public beta. Only an internal group was observed, and the beta description/privacy/marketing URLs still described the chemistry game. Root must update real metadata, supply contact, associate a new qualifying build with an external group, obtain Apple review and then read the public link. Neither the source code nor a `turn.completed` event can assert those outcomes.

Apple's official [external testing instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers), [test information requirements](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information), and [webhook management](https://developer.apple.com/help/app-store-connect/manage-your-team/manage-webhooks) describe the relevant platform operations. The [Apple Arcade program](https://developer.apple.com/apple-arcade/) remains separate from developing a premium-quality game and distributing its TestFlight beta.

## Event-driven GitHub continuity

`.github/workflows/continuity.yml` runs the stdlib tests on a hosted Linux runner for changes to its scoped paths, on explicit dispatch, and on completion of the two existing native/release workflows for main. Workflow-completion handling checks out the trusted default branch, has only `contents: read`, does not persist Git credentials and never executes source, commands, or artifacts from the completed run. Pull-request tests execute on a hosted runner without signing secrets. Public issue/comment events are not triggers.

The workflow writes a small **event observation**, not an acceptance decision, retained as an artifact for 14 days. Import it into the persistent coordinator store:

```sh
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state reconcile --workflow-receipt /protected/receipts/event.json
```

The local store keeps the most recent 200 workflow observations. CI artifacts are finite-lived evidence, not durable supervisor storage. No cron or always-on receiver is configured. Progress occurs when the coordinator invokes a bounded run/resume or imports a real completion event. Apple review waiting remains an explicit pending action until authorized webhook access and an authenticated HTTPS receiver exist; no blind frequent polling is added.

### Recommended integration changes for root review

No existing native or release workflow is changed in this commit. Proposed follow-up changes are:

1. Add code/resource path filters to `unsigned-ios.yml` so docs-only changes avoid a full native archive. Verify the `xcode-27` runner's isolation before accepting public-contributor execution there; a custom runner label alone does not establish its trust boundary.
2. Preserve the native gate's exact source SHA and real frame/input/performance evidence in a reviewable receipt. Add a separate human gameplay review; automated tests cannot certify fun, device thermals or awards.
3. After an authorized dispatch allocates the actual build number, use the same authoritative store's `claim-release` guard before approving the protected release job. Record the workflow run ID, then append exact Apple build/review/group observations. Existing release logic must keep duplicate-build preflight and its bounded processing wait.
4. Replace the processing helper's hardcoded `0.2.0` with a validated explicit version for 0.3.0. Keep app/bundle allowlisting and signing protections.
5. Once real webhook permission and a receiver are available, verify Apple's raw-body HMAC-SHA256 signature, deduplicate event IDs, then read the exact current resource state. Never treat event text as instructions or restart upload as a retry mechanism.

## Verified scope and limits

The tests exercise actual local subprocess execution with a fake Codex JSON stream, timeout cleanup, interrupted receipts, stale/reused process identities, atomic-save failure, lock contention, path ownership, retries, Wd import isolation and duplicate release claims. They do not run a real Codex agent, Xcode, an iPhone, the Windows process-control branch, a GitHub Actions run, or Apple operations. Those integrations need their own observed checks before being described as operational.
