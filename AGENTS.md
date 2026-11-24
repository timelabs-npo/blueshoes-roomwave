# Blueshoes: Roomwave agent contract

Scope: only this new repository/worktree. Never alter existing Blueshoes networking, Rhea, WORLD.EXE, Molecule Foundry, other worktrees, host configuration, credentials or permissions.

## Frozen interfaces

Read docs/CONTRACTS.md before work. Sources/RoomwaveCore/Contracts.swift and Package.swift are frozen for this first parallel slice. Request coordinator review before changing a public type/signature. Do not duplicate shared types.

## Ownership

- scan lane: Normalization.swift, TrackGenerator.swift, TrackValidator.swift, TrackIdentity.swift; Tests/RoomwaveCoreTests/ScanTests.swift; Fixtures/scan/**; docs/SCAN_READINESS.md.
- race lane: RaceSimulation.swift, Replay.swift; Tests/RoomwaveCoreTests/RaceTests.swift; docs/RACE_READINESS.md.
- native lane: apps/ios/**; docs/NATIVE_READINESS.md.

## Execution

- One bounded task per worker; maximum 12 minutes, no recursive spawning, no background daemons or periodic retries.
- Do not commit, push, merge, change branches, install packages, call remote AI, post messages, dispatch workflows or mutate external accounts.
- No secrets, credential files, home-folder search or unrelated network/filesystem access. Do not weaken existing sandbox or approval rules.
- Preserve synthetic versus device provenance. A client marker is not proof of remote attestation.
- Share final stylized track geometry only; never raw LiDAR samples, room geometry, camera frames or local capture IDs.
- Race score is independent of social popularity. HF and X networking remain unconnected.
- Report exact executed checks and limitations. Windows without Swift/Xcode cannot establish an iOS build or device pass.
- Leave concise lane readiness notes. Tests must verify behavior, invalid inputs and replay/provenance boundaries rather than mirror implementation.
