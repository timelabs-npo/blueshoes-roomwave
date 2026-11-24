# Bounded Codex swarm receipt

Project: private `timelabs-npo/blueshoes-roomwave`.
Host: Wd / Windows. Codex CLI 0.162.1, existing ChatGPT login and default model/config.
All workers used `codex exec --sandbox workspace-write --json --output-last-message`.
Each was bounded to 12 minutes, used its own worktree/branch, and started at exact baseline
`5f7cd8a7cddd5e8b60e0313218fec02a1c3fe44a`.

| Lane | Session ID | Started UTC, 24 Nov 2026 | End observed UTC | Branch | Original lane commit |
| --- | --- | --- | --- | --- | --- |
| scan | 01a20f0f-e39b-7312-b560-a490a1e8b8be | 19:37:08.7466210 | 19:45:51.5952971 | lane/scan | 5af64c5c05f5c8e8dbd95f1894f8d294719b5746 |
| race | 01a20f0f-d434-7731-bea0-433d91b487d1 | 19:37:04.3194497 | 19:45:15.0820464 | lane/race | 183f1d6df06024077dd58139de5d3c2d27e0aa9a |
| native | 01a20f0f-f889-7e03-be83-707124b07ef2 | 19:37:14.0739235 | 19:45:36.8611813 | lane/native | 41f323ce11e9e718b775ce2bc395120425e12463 |

All three emitted `turn.completed`, wrote their requested final summaries and
had exited worker-host processes when the coordinator checked them. None timed out
or was relaunched. The launcher read a null PowerShell Process.ExitCode after exit,
which caused its original receipt to label each FAILED. **OS exit codes remain
unknown**; a completed Codex turn is recorded separately and is not described as an
exit-zero or build/test pass.

Ownership review found exactly 7 scan, 4 race and 9 native additions. Frozen public
contracts, Package.swift and unrelated projects were unchanged by workers.
The coordinator committed each lane, then cherry-picked onto
`integration/first-slice` from documentation main
`40b8eca4582c757df5c66a68013d2d55eda4a273`.
The integration branch includes small documented review fixes and unsigned CI.
It has not been merged to main.

The Windows workers had no Swift/Xcode/XcodeGen on PATH. They authored tests and
performed source/whitespace checks; no compilation or physical-device result
comes from these worker receipts. CI evidence must be reviewed separately.

Raw event streams, stderr, prompts and process receipts remain outside the
repository in the isolated Wd ops directory. This sanitized receipt deliberately
contains no credentials, raw room data or worker reasoning logs.
