# Blueshoes: Roomwave — LiDAR contract and acceptance

Status: initial implementation specification, 24 November 2026. No real-device capture or native build has been established by this document. The frozen `Sources/RoomwaveCore/Contracts.swift` and `docs/CONTRACTS.md` remain the authoritative public interfaces; this note clarifies intended data semantics without introducing replacement types.

## Product boundary

Scan a selected area of approximately 1–3 m containing a few large geometric forms. Convert their coarse shape into a stylized closed circuit for a 60–90 second run. This is not a dimensional survey, small-object reconstruction or a guarantee of accuracy on every surface.

Scanning, preview and racing are distinct states. Freeze the selected geometry before generating a challenge. Stop/pause the ARSession before racing, on backgrounding, cancellation and leaving capture. Speed play happens in a fully virtual RealityKit scene; it never requires running around the real room with the phone. A changed room requires a new scan and new generated track.

## Capture and capability checks

- Check `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)` before enabling reconstruction. If classification is unavailable but mesh is supported, explicitly choose the supported path; never pretend classification occurred.
- Check `supportsFrameSemantics(.sceneDepth)` before adding depth semantics, if depth is used. Mesh capture alone is sufficient for the initial slice.
- Request camera access from explicit Start Scan and include a clear `NSCameraUsageDescription`. Permission denial offers retry/settings guidance and an explicitly synthetic demo.
- Use `ARMeshAnchor` geometry as an approximate reconstruction. Apple does not promise live mesh changes mirror moving objects in real time.
- Copy vertex data with its declared offset/stride/format and transform every local anchor vertex by that anchor's transform into one common AR world frame. Input lengths are in metres. Never concatenate unrelated anchor-local coordinates.
- AR world gravity supplies the vertical axis. Preserve this up direction through normalization; do not arbitrarily rotate height into the ground plane. A scan origin/yaw can vary between captures.
- Bound and deterministically sample selected points before handing them to the core. The first contract suggests at most 4,096 points. Reject nonfinite, empty and degenerate inputs. Reject or request more scanning when tracking/coverage is inadequate instead of silently replacing the capture with a real-labelled fixture.

`sceneDepth` provides measured-depth estimates and a confidence map; this confidence must not be described as a ready-made per-vertex mesh confidence. RoomPlan is optional for a later whole-room/semantic mode, not required for the initial selected-area mesh path.

## Frozen model semantics

### `ScanSample`: local only

`captureID`, `source`, and `points` represent a bounded frozen observation. `source = arkitMesh` is assigned only by the actual ARKit adapter; invented data is `synthetic`. This marker records claimed origin, not cryptographic attestation. `captureID` never enters a shared challenge.

### `NormalizedScan`: local intermediate only

Contains `source`, `normalizationVersion`, and normalized points. Remove absolute translation and normalize scale consistently while retaining relative heights and shape. Use documented centring, scale, ordering and quantization; the generator must not depend on unordered mesh arrival. Preserve `source` exactly. Normalized raw points are still room-derived geometry and are not the public sharing format.

The frozen first slice deliberately has no full coverage grid, classifications or confidence fields. Native capture must therefore enforce capture readiness before creating `ScanSample`. If future quality/provenance fields are required, propose a versioned contract change to the integrator; do not invent parallel public types in a worker lane.

Repeated scans of the same physical scene may differ. Deterministic generation means the same accepted normalized input, seed, generator version and rules produce the same result under the documented implementation. It does not mean two real scanning sessions produce identical bytes.

### `TrackDefinition`: finalized stylized circuit

Fields are `schemaVersion`, `generatorVersion`, `source`, `seed`, `rules`, and ordered `TrackPoint` values. Each point has position in game units, positive `halfWidth`, and `isGate`. Closing segment is implicit from the final point to the first. Do not copy raw scan coordinates directly into this export.

Coarse height changes can affect elevation; large protrusions can affect route shape; broad regions can produce recovery sections. A flat or incomplete scan may be rejected or yield a visibly described low-variation result. A separate synthetic demo must retain its synthetic provenance.

Keep the track bounded (suggested maximum 256 route points). Validate finite values, widths, nonzero segment lengths, rule ranges, spacing and curvature before play. The implemented validator must state its actual limits; structural validity is not a complete reachability proof.

Race simulation and rendering must use the same closed-polyline interpretation, cumulative distance, local-width interpolation and gate positions. Specify boundary handling so crossing a gate at a segment endpoint or across the final-to-first segment is counted exactly once. A bank input in the frozen core is effective only when a gate is crossed during that tick; a native UI should make its request timing visible (for example, held bank input) rather than imply an unimplemented persistent request queue.

### `ChallengeDescriptor`: explicit user export

Only `schemaVersion`, `trackID` and finalized `TrackDefinition`. Do not include raw or normalized scan samples, capture IDs, original room bounds, camera imagery, location, face data or AR world maps. Show the exported stylized geometry before sharing. Derived geometry can retain spatial features and is not claimed to anonymize a home.

`trackID` is SHA-256 of a documented canonical encoding of the final track and rules/versions. Specify field inclusion, numeric quantization, encoding, ordering and signed-zero handling; do not hash ordinary JSON with unspecified ordering. The identifier is content identity, not an anti-cheat signature. Initial implementation must state how `source` and `seed` participate in identity. Cross-platform unsupported hashing must fail explicitly, never silently substitute an algorithm.

Results are comparable within the same finalized track hash, rules version and play mode. A global ranking across unrelated rooms needs a separate normalization design. `CreatorReputation` counts qualifying engagement separately from `RaceScore`; likes, reposts and follower counts cannot change driving rules or race points.

## Initial acceptance evidence

| Gate | Required evidence |
| --- | --- |
| Synthetic core | Invented fixtures are labelled synthetic; normalization preserves origin; invalid and degenerate inputs fail explicitly. |
| Geometry effect | Distinct fixture shapes affect generated geometry; decoration-only random changes do not alter competition. |
| Frozen identity | Equivalent documented canonical inputs preserve ID; changed competitive geometry/rules change ID; metadata privacy boundaries are exercised. |
| Simulation contract | Fixed tick, exact input order, gate crossing, bank/risk behaviour, terminal state and replay mismatch handling have executed checks. |
| Real LiDAR | On-device capture actually supplies transformed ARKit points; cancellation, poor tracking, permissions and background lifecycle are observed. Synthetic tests do not satisfy this gate. |
| Native build | Actual Xcode build/launch result is recorded separately from source review or core test execution. |
| Performance and play | Device frame timing, memory/thermal behaviour, capture/export cost and touch comfort are measured. 60 fps is an initial target, not a result. |

The current hardware specification confirms iPhone 18 Pro Max has LiDAR and a ProMotion display up to 120 Hz. This does not prove a game reaches 120 fps. RoomPlan's support flag also checks LiDAR availability, but room capture is not needed to complete the initial mesh path.

## Primary references

- https://www.apple.com/iphone-18-pro/specs/
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
- https://developer.apple.com/documentation/arkit/armeshanchor
- https://developer.apple.com/documentation/arkit/armeshclassification
- https://developer.apple.com/documentation/arkit/arframe/scenedepth
- https://developer.apple.com/documentation/arkit/ardepthdata
- https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission
- https://developer.apple.com/documentation/roomplan
- https://developer.apple.com/documentation/roomplan/roomcapturesession/issupported
- https://developer.apple.com/documentation/realitykit/arview/cameramode-swift.enum/nonar
