# Arcade v03 presentation handoff

Baseline: `0f52279e465ae8ec9ebb806254f211722444236f`, assigned branch
`arcade-v03/presentation`. Work is restricted to this lane's three new Swift files
and this note. No contracts, avatar helper, app composition, project settings or
other lanes were edited. The initial worker did not commit, install, dispatch
workflows or run native tools. Later independent reviews are recorded below.

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

The portrait vertical FOV is explicitly 59-63 degrees in gameplay (61 with
reduced motion); preview fixes it at 61. Near/far planes remain 0.08/1600. Camera
composition now has explicit preview and gameplay modes. Preview sits 6.8 units
behind and 3.8 above the foot, aiming 0.8 forward and 0.35 above it. Gameplay sits
8.4-9.0 behind and 5.4 above the foot, aiming 5.0-5.5 forward and 0.90 above it.
A sample 18-24 units ahead contributes at most 0.25 units of crest lift to both
position and aim; it no longer becomes a distant aim point. Camera offsets,
heading and FOV use `1 - exp(-rate * deltaTime)` smoothing; frame delta is bounded
at 0.1 seconds. The current foot's full translation is applied before offset
smoothing, preventing speed-dependent positional lag or height-dependent loss
of rider framing. Tiny turn roll and a decaying real-hit shake are bounded.
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

At the initial worker handoff, no Swift/Xcode compiler, simulator, iPhone,
screenshot, input capture, device performance measurement or playtest was
available/executed. That handoff asserts no native compile/runtime/experience
PASS. Its likely compile/integration risk was the exact
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

## Camera correction after actual native capture

Correction baseline: `03ae2106b6be4c4ed584a3363c2e20d68c590ed4`, isolated branch
`fix/arcade-camera-composition`. Only `ArcadeSceneController.swift` and this note
changed. The coordinator supplied real native screenshots extracted from failed
CI run `45678649494` at the integrated `e7f6468` revision. The reviewer inspected
the actual Neon Dawn home (`813d99dbde2fb82aed8d.png`), Low Orbit home
(`b7235741d71440fbd104.png`) and paused scene (`04e744b73037c3b49275.png`). These
showed the bundled rider behind the home controls near the screen bottom and
excess empty sky. The paused scene also showed the old distant aim. They are
evidence of the previous camera's problem, not screenshots of this correction.

The correction separates preview/gameplay composition even when reduced motion
sets preview drift to zero. It replaces the old 20-34-unit weighted aim with a
near aim and bounded crest lift. Preview's low aim leaves room for the board's
rear tip on the opening uphill. Gameplay maintains the rider's absolute foot
translation before smoothing relative offsets: otherwise smoothing world
positions creates several units of unintended trailing distance at speed.
The same full vertical translation applies to position and aim through a jump.
The new follow-origin cache resets on teardown, retry rewind and return to
preview, alongside the existing camera caches. Asset scale remains 1.0 and no
physics, collision bands, mesh, material, lighting, UI or evidence hook changed.

A local mathematical perspective-projection sweep used the three authored
catalogues' actual 12-unit samples and linear pose interpolation. It evaluated
30/60/120 Hz offset smoothing at speeds 12/21/30, the portrait 1320:2868 aspect,
the real opening ramp pitches, home drift extrema, and a constructed continuous
0-16-unit foot-height sweep. This was a camera calculation, not a gameplay run
or a rendered image. Screen Y is normalized from top (0) to bottom (1):

| Projected point | Neon Dawn | Low Orbit | Black Current |
| --- | --- | --- | --- |
| Preview pitched body midpoint, including drift | 0.5256-0.5260 | 0.5275-0.5280 | 0.5268-0.5272 |
| Preview foot | 0.5705-0.5710 | 0.5705-0.5710 | 0.5705-0.5710 |
| Gameplay body midpoint across sweep | 0.6609-0.6928 | 0.6601-0.6997 | 0.6604-0.6973 |
| Gameplay foot across sweep | 0.6992-0.7270 | 0.6992-0.7320 | 0.6992-0.7303 |

The preview board's rear centre projected at 0.6166-0.6211 across all three
openings, close to the start of the course selector; its final UI clearance
still needs native inspection. Sampled road 20 units ahead projected at
0.2696-0.8649 and 40 units ahead at 0.1783-0.6932 across the constructed flight
sweep, so those sample points remained within the vertical viewport. This does
not prove terrain/encounter occlusion, asset pose, text clearance or frame rate.

Executed: source/lifecycle review, the projection calculation and
`git diff --check`. This correction has not been compiled or rendered locally.
Next gate: capture the real updated home/play/retry views in all three biomes;
check the rider and full board above home controls, landings through crests,
ceiling/barrier occlusion behind the rider, peak jumps and reduced motion. The
coordinator owns the separate home interruption-message correction and native CI.
