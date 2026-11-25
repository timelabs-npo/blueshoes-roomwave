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

- Local coordinator: 58 continuity/internal/public-beta helper tests (including 11 real-file permission, size and descriptor-race regressions) and six owned-process deadline tests passed on 25 November. Shell, Node/Python syntax, plist/YAML parsing and whitespace checks passed. These do not execute iOS.
- GitHub continuity run [45678649976](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45678649976) passed for integration `e7f6468`.
- Initial Mac native validation [45678649494](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45678649494), integration `e7f6468`: production Swift package tests, native compilation, and all six hosted native tests passed. The real UI test failed after 103 seconds because the app was already paused when it attempted the Pause action. That initial gate **FAILED**; it was not accepted for release.
- Actual screenshots from that run confirmed the false interruption message on Home and the rider obscured by the lower Home controls. The frame clock now drops bounded excess simulation time instead of treating slow frames as lifecycle events. Background/audio interruption still pauses explicitly. Camera composition and audio activation receive separate corrections before the next native run.
- The recording observer also terminated on a CoreSimulator query timeout. Transient queries are now tolerated within an overall deadline. Failure paths preserve app-cache observations and export XCTest attachments, with command deadlines and reserved artifact-upload time.
- Corrected Mac native validation [45686764139](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45686764139), source `41ed282b47bc2231f5b444914f1c8389e5635859`, completed **SUCCESS** on 25 November at 19:57 UTC. It passed the production package tests, hosted native tests, ordinary-touch UI flow, all eight required actual ARView captures, simulator identity verification, and unsigned device archive. The captured gameplay includes takeoff, landing, perfect landing, ring, boost, collision and lost-combo events from one run generation. Native evidence artifact `15057372926` also contains the actual UI-test video and eight XCTest UI attachments; artifact SHA-256 is `dd695acf76ce8333ce0e7cf3ac3035d3b4da8f85bda0c2e0a6965e9dcac8d098`.
- CodeQL identified a check/read file race in the release contact/content loader. The subsequent source correction opens one descriptor, checks it with `fstat`, reads at most 20,001 bytes from that same descriptor and closes it. This release-helper change does not alter the native game; its own CodeQL rescan and the updated-commit CI remain separate gates.
- UI automation uses the ordinary game and ordinary touch input. It must capture all three biome previews, charge/flight/landing, pause/background/resume, a genuine terminal result and retry. DEBUG observations use actual ARView snapshots and include course, run generation, request/capture ticks and asset hierarchy.
- Simulator screenshots/video and deterministic traces are engineering evidence. They are not a human playtest or physical-device performance measurement.

## Current art-pass validation and capture correction

The art-pass source `390cb5f36bcf77c6ec5484802019e18f082f4c18` passed continuity [45695085085](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45695085085) and all four CodeQL analyses [45695078368](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45695078368). Native [45695085209](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45695085209) **failed**, despite all 43 package tests and six hosted tests passing: the first Home `app.screenshot()` timed out while resolving the application's accessibility snapshot. No gameplay touch sequence or unsigned archive completed in that run.

Its artifact `15061539312` has verified ZIP SHA-256 `c1ac501a11d46a0a8a6124a294856c65ec4bcd43d6177722c5b2e88358775784`. The checked-out PR merge `5b89edb929a34e9d1706b0fe141ad00449c719d4` has the same tree `f4f5abe54b19a9dcbdba14ef505fda495e3617ad` as the reviewed source. The Home ARView capture was uniform; the final diagnostic UI showed SpringBoard after the test ended. The exported spindump contained no samples. The render-pipeline warning was also present in the earlier successful run and does not establish an art regression.

The focused correction captures XCTest attachments with `XCUIScreen.main.screenshot()` while retaining every actual tap and assertion. DEBUG render observations now reject uniform clear frames using a small actual RGB-pixel sample and retry at most twice per second per mode. Schema 4 receipts include that sampled range, and the evidence verifier requires it. These changes do not alter the Release game. They require a new successful ordinary-input/native-render run; neither the screenshot correction nor a visible Home frame alone proves gameplay responsiveness.

## Human and device gates still open

Observe at least a few first-time players without spoken coaching. Record device/build, time to first meaningful input, whether the charge/release/dive/landing relationship is understood, whether collision causes are readable, and whether players voluntarily retry. Keep actual observations and disagreements; do not convert an automated survival trace into a PASS.

Measure sustained frame pacing, thermals, audio/haptics and battery behavior on an actual supported iPhone. The app requests 60 Hz gameplay; no sustained 60/120 Hz result is claimed from that setting. Inspect iPad safe areas, Reduce Motion, large text and accessibility actions separately.

## External distribution gates

The existing Apple identity is authorized, but 0.2.0 (1002.1) was an internal pilot. External v0.3 needs its exact processed build, truthful metadata, a real review contact, Apple Beta App Review approval and a read-back public URL. An enabled URL alone does not prove an external install/play/report cycle. No social post or tester message is implied by this record.

The durable coordinator state is on the already-authorized Wd operations host. It imports the actual lane receipts and preserves separate blocked-input/access records. It is a bounded, explicitly resumable supervisor with GitHub event observations, not an unobserved always-running autonomous service.
