# Blueshoes: Roomwave

An early native iOS game research project: scan a small space, turn its coarse shape into a stylized racing circuit, and share an equal-rules challenge.

**Status: contracts and parallel implementation in progress. No iOS build, physical LiDAR capture, gameplay acceptance, TestFlight delivery, or live X integration is verified.**

- Target: iOS 27, SwiftUI, ARKit scene reconstruction, RealityKit.
- Core: Swift 6 package; scan normalization, bounded track generation, deterministic custom racing state and replay contracts.
- Scan first, stop capture, then race. Synthetic fixtures remain explicitly synthetic.
- Share final stylized track geometry and rules after user review; never raw scans, camera frames, room labels or world maps.
- RaceScore measures gameplay; CreatorReputation is separate. Social likes/reposts never improve race score.
- X: user-initiated system sharing only in the first slice. No OAuth, API posting, scraping or engagement rewards.
- Hugging Face: optional cosmetic/style tooling may be evaluated later. No remote inference, scan uploads or model downloads in this slice.

## Layout

- Sources/RoomwaveCore/Contracts.swift — frozen shared data models.
- Sources/RoomwaveCore — isolated scan and race implementation lanes.
- Tests/RoomwaveCoreTests — authored acceptance tests; execution evidence must be recorded separately.
- apps/ios — native shell prepared by the platform lane.
- docs/CONCEPT.md — gameplay and scope.
- docs/CONTRACTS.md — API ownership and invariants.

Run `swift test` on a compatible Swift host. Native builds require an Xcode 27 macOS environment and separate device acceptance. No command in this README claims it has already passed.

Original code: MIT. Dependencies, optional model weights and external assets retain their licenses. This repository is separate from the existing Blueshoes networking project, WORLD.EXE, Rhea RF Spanner and Molecule Foundry.
