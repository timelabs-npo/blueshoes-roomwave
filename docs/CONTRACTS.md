# Frozen first-slice contracts

This document and Sources/RoomwaveCore/Contracts.swift define shared interfaces. Worker implementations must not modify these files or Package.swift. Missing dependency implementations from other lanes may temporarily prevent compilation; do not replace or duplicate them.

## Data and provenance

All shared models have immutable public fields and explicit initializers. ScanSample and NormalizedScan are local capture/intermediate data. Preserve ScanSource exactly through normalization and generation. Synthetic points cannot be relabeled arkitMesh by normalizer/generator. arkitMesh is an adapter-reported origin, not cryptographic attestation of a device.

TrackDefinition is finalized stylized geometry plus all RaceRules. ChallengeDescriptor contains only schemaVersion, trackID and TrackDefinition. Never add raw points, captureID, exact raw room bounds, camera frames, faces, labels, locations or world maps to a challenge. Sharing derived geometry still needs user preview/consent and is not claimed to anonymize a home.

Geometry should be quantized consistently before identity/export. Identity is SHA-256 of a documented canonical encoding of finalized track points and rules (including versions), not a JSON hash with nondeterministic key order and not an anti-cheat signature. TrackIdentity may conditionally import CryptoKit on Apple; unsupported platforms must throw explicitly rather than substitute another hash. Gameplay algorithms otherwise use Foundation only.

## Scan lane public signatures

- public enum ScanNormalizer { public static func normalize(_ sample: ScanSample) throws -> NormalizedScan }
- public enum TrackGenerator { public static func makeTrack(from scan: NormalizedScan, seed: UInt64) throws -> TrackDefinition }
- public enum TrackValidator { public static func validate(_ track: TrackDefinition) -> [ValidationIssue] }
- public enum TrackIdentity { public static func canonicalData(for track: TrackDefinition) throws -> Data; public static func id(for track: TrackDefinition) throws -> String }

Return a bounded closed circuit (closing segment implicit between last and first point), stylized in game units. TrackPoint has center position, halfWidth and isGate. Normalization must reject empty/degenerate/nonfinite/oversized input with explicit errors. Keep bounds reasonable (suggest <=4096 input points, <=256 route points). Validate positive widths, finite values, nonzero segments, valid rules and problematic curvature/spacing. Do not claim a complete reachability proof without implementing one. Use a specified local seeded PRNG; decorative randomness must not change gameplay layout.

Fixtures under Fixtures/scan must include source=synthetic and nonpersonal invented points. Tests cover provenance preservation, boundedness, determinism under this implementation, invalid inputs and identity differences after geometry/rule changes. CryptoKit identity tests conditional on availability, with explicit unsupported-path tests otherwise.

## Race lane public signatures

- public enum RaceSimulation { public static func initialState(rules: RaceRules) throws -> RaceState; public static func step(state: RaceState, input: RaceInput, track: TrackDefinition) throws -> RaceState }
- public enum ReplayEngine { public static func record(inputs: [RaceInput], track: TrackDefinition) throws -> ReplayRecord; public static func replay(_ record: ReplayRecord, track: TrackDefinition) throws -> RaceState }

A tick is fixed at 1/rules.tickRate. Input.tick must equal prior state.tick+1. steering is finite in [-1,1]; bank is a player request applied at the next gate crossed during that tick, otherwise ignored. At a gate, bank saves unbanked score, clears that chain, resets multiplier to 1 and reduces speed by bankSpeedFactor but not below initialSpeed. Continuing through a gate increases multiplier by multiplierGain. Crash when abs(lateralOffset) exceeds local halfWidth. Distance advances along the closed circuit and may exceed one lap. Stop at durationTicks; bank the remaining chain on successful finish. Ignore no illegal values silently; validate and throw on invalid state/rules/input. Running a tick on a terminal state returns that same state or throws a documented invalidInput error consistently.

Replay uses the track's exact rules and content identity. Record inputs and periodic actual states, then validate supplied keyframes/finalState during replay. A numeric determinism claim is restricted to this custom step implementation/toolchain, not arbitrary Apple/Godot physics or all CPUs. If TrackIdentity is unsupported, propagate that status. Never claim replay proves remote score authenticity.

## Native lane

Implement apps/ios with XcodeGen project.yml, iOS27 target and local package dependency on RoomwaveCore. Include SwiftUI scanner/preview/race shell and RealityKit representation as feasible. Compile status must remain NOT VERIFIED until actual Xcode execution.

Use ARWorldTrackingConfiguration.supportsSceneReconstruction before enabling capture, and request camera access on explicit Start. Finish/pause/background must stop ARSession. Respect bounded mesh copying; actual ARKit sample adapter labels arkitMesh, invented demo labels synthetic. Transform mesh vertices into one consistent coordinate frame before supplying ScanSample. Race only after a completed frozen track preview.

Provide user-initiated share of ChallengeDescriptor as a local file through UIActivityViewController; no OAuth, X API calls, cloud upload, remote inference, new web endpoints or hidden recording. Demonstration fallback works without LiDAR and is visibly synthetic. Public challenge link/backend and capture clips may be marked planned, never faked.

## Ownership

scan: Normalization.swift, TrackGenerator.swift, TrackValidator.swift, TrackIdentity.swift, ScanTests.swift, Fixtures/scan/**, docs/SCAN_READINESS.md.
race: RaceSimulation.swift, Replay.swift, RaceTests.swift, docs/RACE_READINESS.md.
native: apps/ios/**, docs/NATIVE_READINESS.md.

If a contract blocks implementation, write the issue in lane readiness notes and report it to the coordinator. Do not edit another lane or frozen file.
