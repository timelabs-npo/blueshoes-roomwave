# Arcade v0.3 acceptance record

This record distinguishes implemented source, observed engineering results and player experience. It is not an Apple Arcade selection or award claim.

## What is being evaluated

A native full-screen, one-touch surfing game. Hold to charge, release to launch, hold in flight to dive, and release before touchdown for a clean landing. Three authored courses provide repeatable timing decisions. Optional local photo/LiDAR features alter the terrain of a known encounter sequence. The existing layered CC0 avatar remains visible; anatomy helper layers are disabled during play.

## Source production and review

Three real Wd Codex CLI sessions ran from frozen base `0f52279e465ae8ec9ebb806254f211722444236f` with separate worktrees and 20-minute deadlines. All returned exit 0 and `turn.completed` before deadline. Gameplay and presentation received separate post-worker reviews; root reviewed and integrated experience code.

| Lane | Session | Reviewed lane commit |
| --- | --- | --- |
| Gameplay | `01a213f2-a3c3-7501-90b7-dc643737023d` | `562df2d59ba1f8567d95fab71d51cb787d5868f8` |
| Presentation | `01a213ef-cc91-70b1-ba74-7148d8c58acd` | `c5a49213eb3efad3a236ac7fa5df3c6448be75b7` |
| Experience | `01a213ef-e1a4-79d3-b258-0f2079b2364f` | `071f06176c3ba559bf166b5890fab2454e9482c5` |

Independent corrections include ballistic encounter crossing, no rewards after a fatal hit, avatar/collision scale agreement, terrain winding and transparent materials, retry visibility, recorded interruption/touch cancellation, stable feature accumulation order, access to the latest created course, and generation-scoped asynchronous render receipts.

## Engineering gates

- Local coordinator: 34 continuity/public-beta helper tests passed on 25 November; shell, Node/Python syntax, plist/YAML parsing and whitespace checks passed. These do not execute iOS.
- GitHub continuity run [45678649976](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45678649976) passed for integration `e7f6468`.
- Initial Mac native validation [45678649494](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45678649494) is the first v0.3 native gate; its outcome and any subsequent exact-source runs must be recorded in the delivery receipt.
- UI automation uses the ordinary game and ordinary touch input. It must capture all three biome previews, charge/flight/landing, pause/background/resume, a genuine terminal result and retry. DEBUG observations use actual ARView snapshots and include course, run generation, request/capture ticks and asset hierarchy.
- Simulator screenshots/video and deterministic traces are engineering evidence. They are not a human playtest or physical-device performance measurement.

## Human and device gates still open

Observe at least a few first-time players without spoken coaching. Record device/build, time to first meaningful input, whether the charge/release/dive/landing relationship is understood, whether collision causes are readable, and whether players voluntarily retry. Keep actual observations and disagreements; do not convert an automated survival trace into a PASS.

Measure sustained frame pacing, thermals, audio/haptics and battery behavior on an actual supported iPhone. The app requests 60 Hz gameplay; no sustained 60/120 Hz result is claimed from that setting. Inspect iPad safe areas, Reduce Motion, large text and accessibility actions separately.

## External distribution gates

The existing Apple identity is authorized, but 0.2.0 (1002.1) was an internal pilot. External v0.3 needs its exact processed build, truthful metadata, a real review contact, Apple Beta App Review approval and a read-back public URL. An enabled URL alone does not prove an external install/play/report cycle. No social post or tester message is implied by this record.

The durable coordinator state is on the already-authorized Wd operations host. It imports the actual lane receipts and preserves separate blocked-input/access records. It is a bounded, explicitly resumable supervisor with GitHub event observations, not an unobserved always-running autonomous service.
