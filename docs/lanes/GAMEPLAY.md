# Gameplay v03 handoff

Baseline: `0f52279e465ae8ec9ebb806254f211722444236f`, branch `arcade-v03/gameplay`.
Work started 2026-11-25 at approximately 18:23 UTC, within the assigned 20-minute budget.

## Changed files and ownership

- `Sources/RoomwaveArcade/SurfCourseCompiler.swift`: boundary validation and binary-search pose sampling.
- `Sources/RoomwaveArcade/SurfCatalog.swift`: three authored elevated courses and deterministic daily variations.
- `Sources/RoomwaveArcade/SurfSimulation.swift`: all frozen simulation/result/replay APIs.
- `Tests/RoomwaveArcadeTests/SurfGameplayTests.swift`: XCTest behavior and invalid-input coverage, using production physics exclusively.
- `docs/lanes/GAMEPLAY.md`: this handoff.

The CLI worker made no shared contract, Package, native, legacy, asset, workflow, signing, branch, commit or remote changes.

## Simulation constants and intent

The standard frozen rules remain 60 Hz, 16 initial speed, 10–30 bounded speed, gravity 14,
held airborne gravity 30, maximum charge 1 and 9,000-tick timeout. Input tick equals the
current state tick; start is tick 0, and an advancing step emits the next tick. Terminal
states remain identical with no new events, but rules, state and tick are still checked.

Full grounded compression takes 0.65 seconds; a release needs at least 22% charge
(roughly 0.15 seconds). Launch velocity is bounded 4–18, influenced by compression,
road slope and speed. Grounded holding has a small speed cost. Gravity actually changes
the flight arc. Cruise tends toward 18; uphill costs and downhill restores momentum.
There is no steering input or distance score.

Foot height is absolute Y. Grounded foot equals sampled road Y. Body collision interval
is foot + 0.1 through foot + 0.9; ring target is foot + 0.5. Encounter bands are relative
to road Y. Every crossed plane is swept in descriptor order, using the ballistic absolute
foot height at each crossing, including several planes per tick. A cursor makes encounters one-shot.
Landing events are ordered before/after encounter events by crossing fraction. After a
fatal hit, remaining crossed planes advance the cursor but produce no rewards or damage.

Clean landing requires released input, at least one third second airborne, and relative
impact velocity between -16 and -2. It emits `landing` (intensity 0.35), then
`perfectLanding`, earns base 150 and adds 1.3 speed. Rough landing emits `landing`
(intensity 1), loses combo and multiplies speed by 0.78. Both clamp speed to rules.
Rings and aerial near misses earn points; near misses require clearance below 0.65.
Combo increases the multiplier every four successful actions, capped at 5x. Reward-event
values are actual points added, including at the score cap. Boosts add 3 speed and zero
score/combo. Hits consume one of three shields, multiply speed by 0.65 and grant one
second of invulnerability. Zero shields crash; finish takes precedence over timeout
when both occur in the final tick, but a fatal hit takes precedence over finish.

All arithmetic is bounded: score 1,000,000,000; combo 10,000; counters 1,000,000;
foot no higher than road + 128; downward velocity no lower than -180. These last two
are protective limits for extreme custom rules, rather than authored course targets.
Allowed custom rules: 30–240 Hz, 1–216,000 ticks, speeds 0.5–120 with ordered
minimum/start/maximum, gravity 2–100, stronger held gravity up to 200, charge 0.1–5.
Invalid start rules yield a finite crashed fallback. Step/verify reject invalid rules
and unsafe/inconsistent states. Result clamps integer fields and seconds, and awards
completion/medals only to a valid finished state. No fatal/precondition or floating-point
to-integer conversion is used.

Compiler limits: 2–20,000 samples; distance 0–20,000, length at least 10; widths 2–30;
absolute X/Z at most 100,000, absolute Y at most 10,000; adjacent distance and horizontal
separation at least 0.01; horizontal/distance ratio 0.25–4; absolute slope at most 0.65.
At most 5,000 encounters, unique nonnegative IDs, strictly increasing interior distances,
positive bounded bands and points. Three strictly increasing positive medal thresholds.
Validation happens once in compile. Per-tick validation checks only state/rules and the
two cursor neighbors; it does not walk the course. Pose queries use binary search;
NaN and negative infinity clamp to start, positive infinity to end. Forward is normalized
in increasing course-distance direction; slope is delta Y / delta game-space distance.

## Courses, pacing and reproducible input traces

All route samples are 12 longitudinal game-space units apart, Y-up and forward -Z,
with lateral curves and two composed elevation waves, not scanned geometry.

| Course | Length | Width | Phrases | Medal thresholds | Intent |
| --- | ---: | ---: | ---: | --- | --- |
| neon-dawn / dawn | 1,440 | 8 | 11 | 1,200 / 3,500 / 6,000 | Broad aerial rings; first two phrases have no hazards, roofs start in phrase five |
| low-orbit / orbit | 1,560 | 7 | 12 | 1,500 / 4,500 / 8,000 | Larger elevations, higher rings, normal-arc roofs and recovery boosts |
| black-current / midnight | 1,680 | 6 | 13 | 1,500 / 4,500 / 8,000 | Barrier, earlier roof, optional low aerial ring, recovery lane |

Phrase beds begin at 40 + 120*n. Initial teaching cue: hold while grounded from bed
to bed+18, release, aim for the ring at bed+38 and clear the barrier at bed+46. Slower
approaches can release later in the bed. Neon/Orbit roofs are at bed+86, recovery boosts
at bed+100. Black Current roofs begin in phrase two at bed+65; after the aerial ring,
time a press while clearing the barrier to shorten the arc, then release before contact for better
landing quality. Its optional low aerial ring is at bed+76, center 1.6 above road,
half-height 0.6, so grounded idle travel does not collect it. No required jump is
immediately followed by a roof without a dive/recovery interval.

Lengths target about 60–90 seconds with intentional play and earned momentum. This is
a design target, NOT an observed duration. Fixed standard speed limits alone imply
48–144 / 52–156 / 56–168 seconds respectively; actual timing requires executing the
Swift traces and native playtesting. Geometry, difficulty and enjoyment remain unverified.

The authored Neon test uses grounded hold where `(distance - 40) mod 120 < 18`, otherwise
released. It asserts a finish, rings, clean landings and a greater score than permanent
hold or idle. Other tests compare 2-, 16- and 40-tick holds on a flat production course,
and a 40-tick hold followed by airborne dive. Swept tests use valid custom rules at
120 speed / 30 Hz and distinct planes within four units. These are test inputs to the
production Swift step, not separate test physics. No test trace has executed here.
Even a successful future scripted trace establishes reachability, not fun or human feedback.

Daily uses supplied strict Gregorian `yyyy-MM-dd` only: FNV-1a with explicit wrapping
UInt64 multiplication selects one authored structure, scales elevation 0.94–1.06 and
shifts higher rings 0–0.2. It preserves spacing, dimensions and IDs. Invalid dates use
`2000-01-01`, including impossible leap dates, wrong lengths and non-ASCII digits.
It never reads a clock, hashValue or random generator. Replay checks schema/course/seed/
rules identity and every exact input tick, recomputes through the same engine and compares
the complete final state. Extra terminal input is rejected. This is exact local replay,
not server attestation or a cross-architecture floating-point guarantee.

## Executed validation and remaining integration

- Read `AGENTS.md`, both arcade design/contract documents and frozen `SurfContracts.swift`
  before editing. `git rev-parse HEAD` matched the assigned baseline; branch matched;
  initial `git status --short` was empty.
- `Get-Command swift -ErrorAction SilentlyContinue` and `where.exe swift` found no Swift.
- `swift test --filter SurfGameplayTests`: **could not start**, PowerShell
  `CommandNotFoundException`, exit 1. No Swift tests, compilation or native execution ran.
- `git diff --check`: exit 0. New-file whitespace checks are also run with
  `git diff --no-index --check -- NUL <file>` because normal diff excludes untracked files.
- Static source review only: frozen APIs implemented, no UIKit/RealityKit imports,
  precondition/fatalError, Date clock, hashValue or random generator in this core.
- No Python exploration, alternate physics, dependency installation, device capture,
  FPS measurement, playtester report or release action was performed.

Coordinator must run `swift test --filter SurfGameplayTests` on an existing Swift 6
environment, then native integration/build and real input/render captures. The source
has not been compiler-verified on this host; compiler errors or behavioral failures remain
possible. Neon trace assertions, Orbit/Black reachability across speed ranges, actual
60–90 second pacing, readable landing/roof cues and enjoyment require execution/review.
Renderer must use the absolute-foot and relative-band conventions above; HUD should
display actual reward event values, the shield count and phase transitions. No contract
amendment was needed or made.

## Coordinator gameplay review — 2026-11-25

The bounded worker receipt reports COMPLETED at 18:36:41 UTC, exit 0, turnCompleted true,
and no timeout. Session: `01a213f2-a3c3-7501-90b7-dc643737023d`. Only after this receipt
was observed did the gameplay reviewer modify these owned files.

Review corrections and added gates:

- Encounter crossing height now evaluates the quadratic flight equation at the actual
  sub-tick time. Linear interpolation of tick endpoints could miss a narrow ring or
  ceiling during a strong dive. Landing time and relative impact likewise solve the
  ballistic crossing against the road over the current tick. The road is approximated
  linearly during that tick; this is not a continuous collision solver for arbitrary
  high-frequency terrain.
- Added a strong-gravity swept-ring/ceiling regression, a post-fatal-hit reward regression,
  and intentional full-course traces for all three authored courses. There are now 17
  XCTest methods. These tests call the production Swift engine; no alternate physics
  is committed or substituted into the app.
- The all-course trace holds to phrase offset 18 for Dawn/Orbit. Black Current holds to
  offset 26, dives briefly at offsets 54..<60 only while vertical speed is above -10,
  then releases before contact. It checks completion, execution rewards, remaining shields,
  and a 60–90 second standard-rule duration. Those assertions remain unexecuted until
  the coordinator runs Swift.
- A temporary JavaScript arithmetic exploration was used by the reviewer to choose
  candidate timing traces and investigate collision math. It suggested roughly 63/73/77
  second runs, but is neither Swift execution nor native playability or human feedback.
  It is not shipped, and none of its outcomes marks an engineering or experience gate passed.
- Pause cancellation needs to be recorded as an input. The root coordinator will add
  the agreed input-contract field, core handling and regression test during integration.
  No frozen contract was changed in this lane.

The reviewer will commit and push only the five owned paths after a staged whitespace
and scope check. Native compilation, actual Swift behavior results, rendered input feedback,
real-device performance and human playtesting remain root integration/release gates.
