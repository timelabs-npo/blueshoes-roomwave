# Pilot gameplay lane

Implemented 24 November 2026, within the gameplay ownership boundary. Frozen
`Contracts.swift`, `Package.swift`, normalization, identity, replay and native app
files were not edited. The coordinator-prepared standard rules remain
`roomwave-pilot-2`.

## Simulation behavior

- Pilot 2 adds signed outward bend pressure. Each vertex turn is
  `atan2(cross(incoming, outgoing), dot(incoming, outgoing))`; segment curvature
  is the mean of its endpoint turns divided by segment length. Both endpoint
  turns include the implicit closing segment.
- Lateral velocity is `steering * steeringSpeed + pressure`, where pressure is
  `-0.45 * speedSquared * curvature`, clamped to plus/minus
  `0.8 * steeringSpeed`. Pressure is constant within each segment during a tick.
  There is no new hidden state or platform physics dependency. Full correction
  has headroom; this is a custom arcade rule, not a physical vehicle model.
- Movement uses the accelerated speed fixed at tick start. Integration splits
  at every crossed vertex, checking interpolated width before gate scoring.
  Banking affects the stored speed for the next tick, including its pressure.
  Off-gate requests are not queued; only the first crossed gate consumes a bank
  request. Crash discards the chain; successful finish banks it.
- `roomwave-rules-1` retains its original neutral/linear steering behavior.
  Unknown rule versions are explicitly rejected by simulation and admission.
  The existing canonical bytes and SHA256 fixture now explicitly use legacy
  rules, preserving that compatibility vector as standard rules change.
- Fixed ticks, strict outside-width crashes, terminal-state rejection, gate
  multipliers and replay inputs/keyframes/final-state checking remain in use.
  Rules are already part of content identity. Determinism is scoped to this
  implementation/toolchain; replay does not authenticate a remote score.

## Generator behavior

`sector-contour-splitmix64-2` summarizes eight angular sectors from sorted
normalized points. Sector radius, point density and mean height perturb a
bounded radial contour; empty sectors use global radius/height means. Three
periodic `[1,2,1]/4` smoothing passes and cosine interpolation retain broad
features. Aspect remains clamped, with the same three seeded SplitMix64 draws
for scale/rotation. Height evidence changes planar turns; route Y stays zero.

Output has 32 points, uniform halfWidth 0.65, four gates, implicit closure and
coordinates on a 0.001 game-unit grid. Every output goes through the existing
spacing, curvature, bounds and nonadjacent-clearance validator; invalid output
throws rather than returning an unvalidated fallback. This is static admission,
not a complete reachability proof or a guarantee for every possible scan.

`synthetic`, `arkitMesh` and `photoDerived` provenance is preserved. A photo map
is inferred stylized geometry, not calibrated depth or a measured room. No raw
points, photos or capture IDs are added to finalized tracks or challenge export.

## Verification and handoff

Added Swift behavior tests cover idle failure on a generated challenge,
offset-feedback correction through all 5400 standard ticks at maximum speed,
signed/speed-dependent bounded pressure, repeated input equality, Apple replay
round-trip, legacy neutrality/version rejection, seam pressure/banking versus
the same geometry rotated into the route interior, repeated banking, identical
AABB with changed layout/height, provenance and sparse/skewed/dense admission.
The correction driver reads only observed offset, not the pressure equation.
Existing race tests exercise legacy gate scoring, interpolated narrowing,
multi-gate ticks, seams, crashes and replay tampering.

Executed locally on Windows:

- `git diff --check`: passed.
- Frozen-file diff check for `Contracts.swift` and `Package.swift`: no changes.
- `Get-Command swift` / `Get-Command xcodebuild`: neither available. Swift unit
  tests, Swift compilation, Xcode builds and device operation were **not run**.
  Prior GitHub/Xcode 27.2 test success is user-reported baseline evidence; no
  failure of that baseline is inferred here.
- An independent inline Node arithmetic model of the new contour, static
  geometry checks and step integration passed 320 layout/seed admission cases
  (five invented layouts, seeds 0...63). The seed-42 rectangle model crashed
  with idle input at tick 44; offset-feedback correction finished at tick 5400,
  distance 760.067, maximum absolute offset 0.2, and repeated identically.
  Continuous banking survived 1200 ticks. Equal-bounds photo-height fixtures
  differed in vertex turn by up to 0.07518 radians. The closing-seam bank model
  matched the rotated route, saving 15.05 points. These are arithmetic-model
  checks, **not execution of the Swift implementation or ReplayEngine**.

Required coordinator follow-up: run `swift test` on the Apple toolchain and
exercise steering feel/native rendering on device. No native timing, UI,
artwork, signing, build configuration or release state is certified by this lane.
