# Afterglow Cistern: one race worth repeating

Prototype scope: one opt-in 612-unit sprint with its own score identity. Ordinary Play, legacy maps, daily seeds, existing radio, sharing, release and accounts are unchanged.

- **Invitation (opening):** a wide first ring with no penalty for passing below it. Let the player understand the hold–release rhythm before asking for precision.
- **Pressure (middle):** height pays in rings but a low arch interrupts the high line. Going low is allowed; the first finish is not a test of lore or social login.
- **Payoff (last stretch):** ride the floor to finish or jump to catch the Crown and then let go for a clean landing. Only the latter earns **THE DUST BOWS**, an original camp victory line and a pink horizon of seven dust folds. An optional result share remains a choice, never a gate or a reward multiplier.

The campaign premise is a desert cistern in a world where people conserve water, not joy. Treat queer exuberance as a player-owned celebration, not as cosmetic shorthand. Take the quick setup–pause–reply rhythm of internet jokes and the ecology/constraint principle of a desert epic, not their props, lines, franchise identities, music, or artwork. No new third-party assets were introduced.

This slice has testable timing, a text cue and an earned result treatment, not a new world renderer or licensed franchise. Motion reduction preserves the result message and static art. The proposed next art pass should use a quiet start, blue-black arch silhouette, then a color reveal; no flash over hazards. Do not report enjoyment, visual legibility or real frame rate from hosted checks. Acceptance on phone: five uncoached people; at least 4 finish, at least 3 independently explain how to earn the Crown, and at least 3 choose a second run before any moderator prompt. Record first failure and timings, not just ratings. The target duration of the safe line is 26–40 seconds.

Compare three result outcomes: skipped the Crown, caught it and missed the landing, or earned the finale. After recording unprompted Retry, ask what the player would change next, not before. Test a pale former waterline tracing the safe route in a separate render pass, with sound off and Reduce Motion on, before attributing any cue-comprehension gain to it.

### Verify before promoting

- Run 45983717863 (`8711bf1`): 18 Swift core tests passed; simulator UI timed out in the optional Creator → Settings transition before any ride. Native readiness failed and no signed upload occurred. It did not retest the previous run's missing independent Results snapshot.
- Revised real-touch script runs Play → Pause → Result → Retry before optional character, creator and X sheet coverage. Those checks remain required, and the independent RealityKit verifier is unchanged. Results capture now reports a bounded diagnostic reason only if the candidate frame is stale, empty or rejected by the same validation.

- Run 45987856503 (`723c3e0`): real-touch test passes and a clean arch crossing reaches the Safe Line result in 31.2 in-game seconds, 1,680 points. Retry works. Two Results ARView frames were rejected by the pixel verifier; the XCTest UI screenshot is not a substitute. Afterglow's frozen finish now frames the actual traveled path rather than pointing beyond its end; verify visual composition and the same strict capture on the next run.

- Run 45992146446 attempt 2: independently captured native Results frame at tick 1794 with RGB range 176; strict capture files copied without verifier changes. XCTest logged Retry at an invalid computed hit point (-1, -1) and did not resume Play. The rendered background is now explicitly noninteractive while the real touch overlay stays active in gameplay; Play and Retry use the full visible capsule as a hit target. The test now also requires Retry to be hittable, without second-tap fallback.
