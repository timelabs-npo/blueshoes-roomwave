# Arcade v03 presentation handoff

Baseline: `0f52279e465ae8ec9ebb806254f211722444236f`, assigned branch
`arcade-v03/presentation`. Work is restricted to this lane's three new Swift files
and this note. No contracts, avatar helper, app composition, project settings or
other lanes were edited. No commits, installs, workflows or native runs occurred.

## Implemented source

- `ArcadeSceneController.swift`: `@MainActor final class ArcadeSceneController:
  ArcadeSceneDriving`, `init()`, and all four frozen protocol methods, plus the
  `UIView` getter. Owns a full-screen-capable non-AR `ARView`, a perspective camera,
  world anchor, two directional lights, bundled rider, board, contact patch and
  optional translucent ghost board. The experience lane must place `view` edge to
  edge; this controller adds no panels, overlays or alternate capture renderer.
- `ArcadeGeometry.swift`: load-time `MeshDescriptor` geometry, densely sampled
  continuous elevated ribbon, shared smooth surface normals, real sample widths,
  cyan edge strips and dim aprons, contour seams, faceted scenery and fixed distant
  horizon. Every original course sample is retained; each longitudinal interval
  is subdivided to at most 1.4 game-distance units. It uses `course.pose(at:)`, so
  visual center elevation follows the same interpolation as gameplay. No spline
  is invented that could diverge from collision elevation. The defensive upper
  bound is 32,000 ribbon stations; a larger input throws a descriptive mesh error.
- Gold rings are genuinely open annular tubes in the vertical XY plane, with
  their inner top/bottom at `roadY + height +/- halfHeight`. Coral barrier and
  ceiling bodies have center `roadY + height` and full vertical size
  `2 * halfHeight`. Encounter yaw follows the route; pitch does not rotate a
  horizontal collision band. Ceiling supports sit outside the road. Cyan boosts
  are forward chevrons 0.018 units above the road, aligned to its local pitch,
  with no raised body across the corridor.
- Dawn uses angular teal/violet mountains, warm directional light and a warm
  sun/horizon. Orbit uses detached double-ended shards, fixed stars, a blue planet
  and tilted orbital band. Midnight uses narrow tall ink/obsidian spires, a small
  cool moon/horizon and lower cool lighting. Terrain triangles are excluded by a
  load-time projected intersection/distance check against the sampled road plus
  a 2.5-unit clearance. Scenery and stars are batched into a few meshes; art does
  not spin. The sky follows camera XZ translation, retaining a fixed world axis.
- Encounter entities are built once and cached in course order. Binary searches
  select a -14/+150-distance window; only changed visibility ranges and newly
  passed encounter indices are updated. Passed rings/boosts disappear whether
  successful or missed; only a real `.ring` event produces a gold collection
  burst. `SurfEvent.value` is not assumed to contain an encounter ID. The art
  container is a reference type to avoid copying its full encounter array on a
  consumption update.
- `ArcadeEffects.swift`: 48 reused spark entities and three reused landing/launch
  waves. All resources are constructed at load time. Real takeoff, landing,
  perfect landing, collection, boost, hit, near-miss and finish events trigger
  bounded feedback. Launch/landing waves follow local road pitch. Actual airborne
  state emits a short cyan wake. There are no
  per-frame entity/mesh factories, timers or scene-update subscriptions.

## Avatar and camera assumptions

The renderer awaits the existing helper's `loadBundledAsset()`. Skin and coat
are enabled, skeleton/muscle overlays disabled. It preserves the imported USDZ
hierarchy and embedded playback. A fallback node, missing renderable skin/coat,
or load cancellation causes `load` to throw rather than report readiness.
Failures are logged with `NSLog`; the original helper status is included.

The helper's root position is exactly `(pose.center.x, state.height,
pose.center.z)`; `state.height` is absolute. The local -Z facing convention is
retained, yaw follows route forward, and reviewed visual root scale is 1.0 to
match the authored metre height and gameplay body envelope. Helper speed
is normalized to `12 * clamp(state.speed, 0...30) / 30`. A parent transform applies
foot-pivoted charge compression, landing squash, slope/flight pitch and modest
turn lean without touching imported bones/layers. The helper already owns its
small motion bob; no additional positional bob is layered on it. The board is
attached near the foot; the elliptical contact patch follows sampled road pitch and shrinks
with separation. Native review must confirm the authored asset's scale, alignment,
coat visibility and board contact; these were not observed here.

The portrait vertical FOV is explicitly 59-63 degrees (61 with reduced motion),
near/far planes 0.08/1600. Camera distance is 8.4-9.6 units behind the rider, with
20-34 units of forward route lookahead. Position, aim, heading and FOV use
`1 - exp(-rate * deltaTime)` smoothing; frame delta is bounded at 0.1 seconds.
Vertical follow retains most of the jump elevation so the rider remains framed
while the landing road is visible. Intended framing is lower-middle, not a top
down track overview. Tiny turn roll and a decaying real-hit shake are bounded.
Reduced motion removes shake, roll, FOV changes, preview drift and helper bob
phase advancement, and reduces bursts/wake density; necessary follow and gameplay
compression remain. Preview uses distance zero of the actual loaded course,
a poised bundled rider and bounded slow home drift (none with reduced motion).

Road/terrain/board use `SimpleMaterial` under directional lights; edges, rings,
markings, horizon and particles use `UnlitMaterial`. These are self-lit colors,
not a claim of HDR bloom, physical fog or custom post-processing. Transparent
contact/ghost/horizon materials explicitly select transparent blending and their
respective opacity values. No image assets, textures or
third-party art/audio were added.

## Lifetime and integration

Each `load` first tears down the previous scene. Generation invalidation plus
task cancellation checks prevent a suspended avatar load attaching to a newer
scene. A stale completion stops its own animation subtree and throws cancellation
without cleaning up a newer scene. Teardown removes the owned anchor/camera,
stops imported animations, clears the effects pool and releases scene references.
There is no second clock or retained subscription. A run rewind resets consumed
art/effects; returning to preview resets that presentation once.

`CompiledSurfCourse.pose(at:)` is the documented gameplay dependency. It was
absent at the frozen baseline and is supplied by the concurrent gameplay lane.
The coordinator owns adding the arcade package product to the native target and
integrating the experience lane; those files were deliberately not changed.

## Checks and limitations

Executed locally: baseline/status reads, required contract/helper reads,
`git diff --check`, and `git diff --no-index --check -- NUL <file>` for all four new
lane files. The tracked diff check returned 0; the four no-index checks each
returned 1 (new-file difference) with zero whitespace diagnostics. The ordinary diff check
does not include untracked files; the explicit no-index checks cover them.
No-index reports a difference exit code for a new file; this is not a compile
or test result. Source consistency review checked protocol signatures, absolute
height, normalized helper speed, ring/beam bands, upward road/boost winding,
inward-facing stars, closed annular winding, matched position/normal/UV buffers,
effect pool bounds, event watermarking, encounter indexing and stale-load guards.
Two exploratory `rg` commands using a Windows wildcard path were rejected by
`rg`; subsequent searches used a directory and `-g '*.swift'`. No files were
changed by those failed searches.

Apple primary documentation was consulted for
[MeshDescriptor](https://developer.apple.com/documentation/realitykit/meshdescriptor),
[PerspectiveCameraComponent](https://developer.apple.com/documentation/realitykit/perspectivecameracomponent),
[vertical FOV](https://developer.apple.com/documentation/realitykit/perspectivecameracomponent/fieldofviewindegrees),
and [recursive animation stop](https://developer.apple.com/documentation/realitykit/entity/stopallanimations(recursive:)).
Some direct Apple pages returned JavaScript-only or inaccessible responses;
documentation lookup is not SDK compilation evidence.

No Swift/Xcode compiler, simulator, iPhone, screenshot, input capture, device
performance measurement or playtest was available/executed. There is no native
compile/runtime/experience PASS. Likely compile/integration risk is the exact
Swift 6 / iOS 27 RealityKit SDK surface for mesh-buffer aliases, the vertical-FOV
initializer, nested actor isolation and imported module wiring. Runtime review
must inspect camera clearance through crests/turns, peak-jump framing, material
alpha, terrain readability, ring/collision-band alignment, paired landing event
feedback, asset playback under the compression parent and full retry lifecycle.
Terrain build cost, draw cost, blending and device thermals are unmeasured.

Next native gate: compile the integrated target; capture the real three-course
preview and playfield on a portrait iPhone; deliberately launch, dive through a
ceiling, clear/hit a barrier, collect/miss a ring and land; compare reduced motion;
exercise load interruption, retry and teardown. Enjoyment requires observed play.

## Independent presentation review after worker completion

Codex session `01a213ef-cc91-70b1-ba74-7148d8c58acd` completed at
2026-11-25 18:35:33 UTC with exit code 0 and no timeout. The coordinator-authorized
presentation reviewer began mutations only after observing that terminal receipt.
The frozen baseline/branch and the four-file ownership boundary were checked.

The worker's final pass already repaired boost winding/pitch, slope-aligned
contact/wave geometry, retry visibility invalidation, the one-time preview reset,
and stale asynchronous load isolation. A run rewind disables the old visible
range, clears collection flags, resets the range to empty, then repopulates the
initial visibility window; retained rings are therefore eligible to reappear.

The independent review made these further scoped corrections:

- Reversed the two non-orbit terrain-apron branches. A direct cross-product check
  showed the original straight-course triangles faced down on both sides; the
  reviewed triangles face up. The already corrected boost faces remain unchanged.
- Set avatar and ghost world scale to 1.0. The asset is authored around one metre;
  a 1.55 scale would visually exceed the simulation's rider body interval
  `foot + 0.1 ... foot + 0.9`. Ring targeting uses `foot + 0.5`; encounter mesh
  bands remain `roadY + height +/- halfHeight`.
- Explicitly configured `UnlitMaterial.blending = .transparent(opacity: ...)`
  for contact shadow, ghost, and distant horizon instead of relying on UIColor
  alpha. Apple documents this requirement:
  https://developer.apple.com/documentation/realitykit/unlitmaterial
- Anchored outside-road ceiling supports at road height and their beam's upper
  edge, and corrected the ring comment to describe the actual target semantics.

The reviewer ran a focused mathematical winding check for both road sides, read
the completed scene lifecycle and fixed effect-pool code, and checked the exact
staged file scope and whitespace. These are source/mathematical checks, not native
compilation or rendering tests. Existing camera framing is intentionally left for
actual native screenshots instead of treating a calculated view as visual proof.
The smaller semantically correct rider particularly needs that framing review.

No Swift/Xcode compiler, simulator or physical-device result is asserted by this
review. Integration still requires real rendering of all biomes, peak jumps,
ring/barrier/ceiling decisions, return-home/retry, and reduced-motion behavior.
