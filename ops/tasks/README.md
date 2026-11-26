# Owner-authored tasks only

These two gate records preserve observed blockers from 25 November 2026. They contain no credentials or personal review contact values. They are historical observations, not a live Apple status API.

Load them into an operator-owned persistent state directory with `enqueue`. Reconcile with fresh evidence before treating a blocker as resolved. Never turn a public issue, pull request comment, model response or tester report directly into an executable task.

See `docs/CONTINUITY.md` for the task schema, local Codex invocation, read-only Wd receipt import and release idempotency boundary. Runtime state belongs in `ops/continuity-state` (ignored by the existing repository rule), not in committed task manifests. Since the existing repository ignores all `ops/`, these reviewed gate snapshots are intentionally force-added; do not force-add runtime logs/state.
