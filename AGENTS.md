# Roomwave arcade rebuild contract

The owner requested a complete arcade rebuild on 25 November 2026 after rejecting the first pilot's game experience. This replaces the old first-pilot lane assignment and frozen planar-game contract. The delivered pilot is preserved at `archive/20261125-pilot-1002-1`.

## Scope and evidence

Work only in the assigned Roomwave worktree and task paths. Other projects, credentials and host configuration are out of scope. Read `docs/ARCADE_REBUILD.md` and `docs/ARCADE_CONTRACTS.md` before changing code.

The current goal is a native, full-screen kinetic surfing game. A successful build, a correcting bot or a screenshot is not evidence that the game is enjoyable. Report exactly what executed and what was observed. Do not invent device performance, playtester feedback, Apple review approval, public links, or skill installation.

## Ownership

- Coordinator: `Package.swift`, `Sources/RoomwaveArcade/SurfContracts.swift`, `apps/ios/Roomwave/Arcade/ArcadeContracts.swift`, app entry/composition, project settings, source adapters, integration and release decisions. These shared contracts are frozen for workers once the coordinator supplies a baseline SHA.
- Gameplay worker: other files in `Sources/RoomwaveArcade`, `Tests/RoomwaveArcadeTests`, `docs/lanes/GAMEPLAY.md`.
- Presentation worker: `apps/ios/Roomwave/Arcade/ArcadeSceneController.swift`, `ArcadeGeometry.swift`, `ArcadeEffects.swift`, `docs/lanes/PRESENTATION.md`.
- Experience worker: `apps/ios/Roomwave/Arcade/ArcadeSession.swift`, `ArcadeRootView.swift`, `ArcadeAudio.swift`, `ArcadeProfile.swift`, `ArcadeSharing.swift`, `ArcadeRecording.swift`, `docs/lanes/EXPERIENCE.md`. Audio resources may be authored in `Assets/Audio` with provenance. No third-party soundtrack reuse.
- Continuity coordinator: `scripts/continuity`, `tests/continuity`, `.github/workflows/continuity.yml`, `docs/CONTINUITY.md`, `ops/tasks`. Existing native/release workflow changes require root review.

No two workers edit the same file. Request a contract amendment from the coordinator rather than duplicating or silently changing a type. Keep the existing camera/photo acquisition code and licensed avatar available, but do not route first launch through the old workbench.

## Worker execution

Each Codex CLI worker receives one bounded task, its exact base SHA, paths, an attempt directory and a deadline (normally 20 minutes). Workers must not spawn recursively, create daemons, commit, push, merge, change branches, install dependencies, dispatch workflows, mutate accounts, read credentials or send messages. The coordinator may create worktrees, review changes, commit and push, and execute already-authorized release actions. Respect all existing sandbox and approval controls.

Keep simulation independent of UIKit/RealityKit, validate/compile courses once, and update the scene directly rather than publishing every frame through SwiftUI. Scores come from play, never likes/reposts. A photo supplies inferred creative parameters, not measured room geometry. Do not export raw photos, scans, EXIF, local capture identifiers or credentials.

## Release

Keep the authorized existing bundle `org.timelabs.moleculefoundry`. Signing remains in the protected release environment. External TestFlight additionally needs truthful current metadata, a real review contact, Apple review and an observed public link. Missing information or access produces a specific blocked state, not a fabricated pass. Never remove protections to make a release succeed.
