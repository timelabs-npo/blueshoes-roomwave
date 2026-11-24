# Pilot swarm execution receipt

Three bounded Codex CLI sessions ran on Wd with separate worktrees and default existing configuration.
Baseline: 581148bb387ff9dd189f78c207db2aebbf1f3d1f.
Each used workspace-write sandboxing, a 20-minute maximum and no remote account or deployment authority.

| Lane | Branch | Started UTC, 24 Nov 2026 | Completed UTC | OS exit | Codex turn |
| --- | --- | --- | --- | --- | --- |
| Gameplay | pilot/gameplay | 20:17:32 | 20:25:55 | 0 | completed |
| Photo | pilot/photo | 20:17:38 | 20:25:21 | 0 | completed |
| Avatar | pilot/avatar | 20:17:45 | 20:24:10 | 0 | completed |

Original commits: gameplay a10eeff8898d2395be47b46ca5e530746dde037c; photo de7ab45926860f0a1eaf3d69194e4af5aaf18d50; avatar 52648069a1b933bdb8cd330bbd75568db649be8b.
All workers kept frozen Contracts.swift and Package.swift unchanged. Their scoped output was reviewed and cherry-picked by the coordinator.

The wrapper captured explicit exit-code files, correcting the prior first-slice receipt limitation.
No worker timed out or was restarted. Raw prompts, event streams, session IDs and process receipts remain outside the repository.

## Coordinator integration

- Root-authored UI adds PhotosPicker, live LiDAR preview, source labels and layer controls.
- Native integration adds photo import, display-link fixed-step accumulation, interruption handling, haptics, a close chase camera and a lit layered rider.
- Gameplay is tuned for onboarding: pressure gain 0.18, zero pressure in the first two seconds and a three-second ramp, with pressure capped at 80% of steering authority. Meaningful tests require idle failure after a learnable interval and a feedback controller that finishes.
- Native host tests verify actual RealityKit asset loading, four renderable layers, imported animation, independent layer visibility, root-placement preservation and two real image payloads producing distinct tracks.

## Evidence boundary

Windows workers performed source checks but could not execute Swift/Xcode.
Successful worker completion is not a build, simulator, device, signing or TestFlight result.
Read the actual CI and release run records for those independent outcomes.
