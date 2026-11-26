# Roomwave 0.3: a game before a generator

The owner rejected the 0.2 pilot as an arcade game on 25 November 2026. The audit confirmed a flat loop, corrective steering, no jumps/encounters/audio, a small playfield inside a form, no persistent mastery loop, and sharing that exposed JSON instead of an achievement. This rebuild changes those product decisions. The signing identity and verified asset provenance remain useful.

## Working direction

Until the owner supplies different creative choices: a portrait, one-touch kinetic surfing score-attack game in a dark low-poly neon landscape. Original reference: the owner's luminous rider and winding mountain ribbon. No new paid services or purchases are authorized by these defaults.

**Hold to compress. Release to launch. Hold in the air to dive. Land cleanly to keep your flow.**

Timing must change the visible arc, speed and earned score. The rider follows a sculpted 3D route; this iteration does not combine a second independent steering mechanic. The first seconds teach movement through forgiving terrain. Later barriers require height, ceilings require a dive, and aerial rings reward choosing a better line. A mistake can lose momentum/combo; repeated obstacle hits end the run. A complete course produces a medal and a personal-best comparison, followed by immediate retry.

## First complete slice

- Three authored courses: NEON DAWN, LOW ORBIT, BLACK CURRENT; distinct palettes and encounter pacing.
- Full-screen playfield, compact HUD, large legible touch targets, a clear first Play action.
- Actual elevation, launch/air/landing state, shields, rings, combo and readable consequences.
- Authored synthesized music/SFX, event haptics, speed cues, time-based camera smoothing and restrained effects.
- Results, medals, saved bests, pause/resume and interruption recovery.
- A score card and a playable course identity; sharing remains explicitly initiated by the player.
- Photo/LiDAR creation is secondary and cannot block first play. Raw input is kept local. Model layers remain an asset/garage concern rather than a gameplay HUD.

## Architecture and ownership

Pure deterministic `RoomwaveArcade` simulation feeds a RealityKit scene. SwiftUI owns menus and a throttled HUD. Compile/validate courses once; do not validate the entire track every tick. The coordinator freezes contracts, three bounded Codex workers own gameplay/presentation/experience, and a separate review examines the integrated artifact. Follow `AGENTS.md` and `ARCADE_CONTRACTS.md`.

## Evidence gates

Engineering: meaningful simulation/replay tests; native compilation and actual render/input captures; complete start/play/pause/fail/retry/finish flows; exact signed identity; observed Apple state. Device FPS/thermals require actual device evidence, not a simulator or a frame-rate preference.

Game experience: test the verbs, look at readable hazard/landing states, listen to feedback, and watch new players play without coaching. Suggested formative targets: understand the basic action within 30 seconds; a complete intentional run; voluntary retry. These are hypotheses for a small playtest, not statistically established retention targets. A green test count cannot mark this gate passed.

Public beta: current game description/privacy URLs, real Beta App Review contact, a new external group, exact-build review submission and Apple approval, then an observed public TestFlight URL. The existing 1002.1 internal availability is not public-beta approval. Official Apple Arcade selection and awards are separate outcomes; do not label this project selected or award-winning without evidence.

## Skills and references

Official OpenAI Game Studio source inspected: `openai/plugins`, revision `981b02c0c44058b595f3b4180002c3ae3c806d40`, especially game-playtest, game-ui-frontend and web-game-foundations. These target browser games; we adopt their separation and real-playtest methods, not their browser engine defaults. No installable Game Studio plugin was confirmed in this session.

Available SwiftUI performance audit is applicable to the native shell. Simulator/debugger/performance skills additionally need a reachable Mac and their actual backends. A skill's presence does not establish runtime access.

Primary references:
- https://github.com/openai/plugins/tree/main/plugins/game-studio/skills
- https://developer.apple.com/documentation/realitykit/bringing-your-scenekit-projects-to-realitykit
- https://developer.apple.com/games/get-started/
- https://www.andreasilliger.com/
- https://www.altosodyssey.com/
- https://thumpergame.com/pocket-edition/
- https://simogo.com/work/sayonara-wild-hearts/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers

These games are design references, not a verified bestseller ranking. No art, code or soundtrack is licensed merely by being publicly viewable.
