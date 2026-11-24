# Roomwave concept — first slice

## Promise

Turn a coarse scan of a small space into a stylized neon circuit. Scan first, preview the generated route, stop the camera session and race seated or standing still. The game never requires running around a real room while watching a fast race.

## First playable hypothesis

One 60–90 second single-player run. Steering changes lateral offset on a track. A gate lets a player bank the current chain and reduce speed; continuing at a gate raises the multiplier. This hypothesis needs human playtests. No commercial-success or virality claim is made.

Room capture contributes coarse normalized spatial features, not a literal obstacle course or a scientific reconstruction. Generation smooths and bounds curvature/width, inserts gates and produces final self-contained geometry. A preview may be rejected/regenerated. A fixture is explicitly marked SYNTHETIC and never presented as a device capture.

## Sharing

A challenge contains the exact finalized stylized track and racing rules plus its content identity. Repeated physical scans need not produce the same geometry. Shared ghost/video clips are representations of actual recorded runs, not proof of anti-cheat. Raw room data remains local. Publishing is explicitly initiated by the player.

The first slice may prepare a standard iOS share sheet with a challenge file. It must not invent a working public universal-link service, upload, or X publishing connection. RaceScore and CreatorReputation are separate concepts; no reward for X likes/reposts.

## Acceptance boundaries

1. Authored Swift tests passing is source/core evidence only.
2. Xcode simulator/device compilation is a separate gate.
3. Physical LiDAR capture, lifecycle, camera permission, performance and touch comfort require real-device evidence.
4. TestFlight requires a separate registered app, app-specific signing and observed distribution state.

## References

- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- https://developer.apple.com/documentation/arkit/armeshanchor
- https://developer.apple.com/documentation/realitykit
- https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios
- https://developer.apple.com/documentation/uikit/uiactivityviewcontroller
- https://docs.x.com/x-api/getting-started/pricing
