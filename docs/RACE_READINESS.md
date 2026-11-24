# Race lane readiness

Implemented the frozen RaceSimulation and ReplayEngine APIs in the four owned files. Contracts.swift, Package.swift, other lanes, host configuration and external services were not changed.

## Gameplay semantics

- Each tick is 1 / track.rules.tickRate seconds. Acceleration is units/second squared; steeringSpeed is lateral units/second. Speed is capped by maximumSpeed.
- Movement uses accelerated speed for the whole tick. Banking affects the next tick's speed, with initialSpeed as the floor. Distance is cumulative 3D polyline arc length including the implicit closing segment; it may exceed one lap.
- Each crossed gate splits distance-based scoring. Continuing increases the multiplier for subsequent distance. A bank request applies once at the first gate in that tick, saves the chain and resets the multiplier; off-gate requests are discarded.
- Half-width is linearly interpolated between track points. Lateral movement is linear during a tick. Check each crossed vertex and the tick endpoint, with collision before a coincident gate. A crash is reported at the first sampled boundary outside the width, rather than a continuous contact time; it preserves prior banks and discards the chain. Equality with half-width is allowed.
- Successful durationTicks completion banks the remaining chain. Stepping either terminal status throws invalidInput. Nonfinite/out-of-range inputs, inconsistent states, invalid rules, numeric overflow/lost precision and more than 4096 traversed segments per tick throw explicitly.
- TrackValidator.validate is a required scan-lane admission call. Internal arc-length construction checks numeric safety; it does not replace track validation or establish reachability. State validation checks invariants, not proof that an arbitrary supplied state is reachable.

## Replay and provenance

Replay schema 1 retains actual inputs, tick-zero state, every whole simulated second and the final partial-second state. Empty/partial running records are allowed. Full replay recomputes the exact keyframe array and final state with track.rules; omissions, reordering or unequal supplied states are mismatches. Invalid input sequences remain invalidInput errors. Extra inputs after crash/finish are rejected.

TrackIdentity.id(for:) remains the frozen scan-lane dependency. Identity errors, including unsupportedPlatform, propagate without substitute hashes. Exact state equality is scoped to this custom implementation/toolchain; cross-platform floating-point determinism and anti-cheat/remote authenticity are not established. Inputs that have no gameplay effect can produce the same states; this is consistency checking, not input authenticity.

Only finalized synthetic geometry is constructed in tests. No ScanSample, capture ID, camera data or social metrics enter race/replay; source markers are not upgraded to device attestation. RaceScore and public challenge models remain unchanged.

## Checks and remaining integration

- Read AGENTS.md, docs/CONTRACTS.md, frozen Contracts.swift/Package.swift and existing ContractTests.swift.
- Executed Get-Command swift: no Swift executable found on PATH (SWIFT_NOT_FOUND_ON_PATH). No compiler, swift test, Xcode, iOS build or device execution occurred.
- Added behavior tests for fixed timing/speed caps, off-gate requests, bank/continue scoring, multiple gates, closed-circuit laps, intermediate narrowing, crash loss/preserved banks, finish banking, invalid rules/inputs/states/tracks, replay tampering and unsupported identity. These tests are NOT EXECUTED.
- At initial inventory, TrackValidator.swift and TrackIdentity.swift were absent. Their implementations are required before package compilation; no stubs or other-lane replacements were added. Synthetic fixture admission and canonical identity must be checked with that lane on a Swift-capable host.
- Executed git status --short --untracked-files=all: exactly the four owned files are new. Executed git diff --exit-code -- Sources/RoomwaveCore/Contracts.swift Package.swift docs/CONTRACTS.md AGENTS.md: exit 0, no frozen-file changes.
- Executed git diff --no-index --check against NUL for each owned file: no whitespace diagnostics (exit 1 reflects new content). An explicit PowerShell Select-String trailing-whitespace scan over all four files returned OWNED_FILES_TRAILING_WHITESPACE_PASS. Source inspection confirmed the four frozen public signatures and retained TrackValidator/TrackIdentity calls.
- Native integration, compiler acceptance, runtime behavior and performance remain unverified.
