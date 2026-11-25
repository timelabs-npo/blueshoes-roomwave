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

### Second failure and the next diagnostic gate

Source `ad02eb8c30032b7eab97d405665399e2305ecfcb` passed continuity [45701085602](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45701085602) and CodeQL [45701074990](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45701074990). Native [45701085647](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45701085647) **FAILED** at `waitForEnabled(arcade.play)`, before its first screenshot. All 43 package tests and six hosted tests passed; the ordinary gameplay flow and archive did not complete. Artifact `15064237959` has verified ZIP SHA-256 `d4cfa83ad9009d478a6c5547f1a5c11478ba170507f09240f5b828aa40aa98c9`. The checked-out PR merge `f30574ed6bbbf19802a2c05348e98f910169ec51` has the same source tree as `ad02eb8`.

Decoded actual UI-test recordings show a rendered art-pass Home after loading: at 25 seconds in the `ad02eb8` recording, and at 130 seconds in the `390cb5f` recording. The later sampled `ad02eb8` frame is identical. These frames establish that the new scene can render; they neither establish responsive input nor prove a freeze. No sampled frame reaches gameplay. The screenshot API correction was not exercised by the second failed test.

All three inspected native runs used Xcode 27.2 with the iOS 27.0 simulator even though an iOS 27.2 iPhone 18 Pro Max was installed. They used different hosted worker IDs, so cancellation residue on one shared live host is not established. The next gate selects the exact requested model on the actual SDK major/minor, records the runtime and runner identity, and refuses an older-runtime fallback.

For this next gate only, DEBUG evidence requests are deferred beyond the display-link callback, and pixel contrast is checked before PNG encoding. A bounded trace records bootstrap phases and at most one heartbeat per second. An observer refreshes the actual app/data containers, verifies the exact current evidence process before sampling, and collects at most two process samples when startup or heartbeat observations stop advancing. Staleness is evidence to inspect, not an automatic hang diagnosis. The pipeline publishes a lightweight review artifact as well as the complete native evidence. Actual gameplay assertions, render receipt requirements, release configuration, and unsigned archive gates remain required. No successful native result is recorded for this pending correction.

The first selector integration, source `1954e2170312c31c9c932115bf2866562e023fe6`, failed in [45711024334](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45711024334) **before simulator launch or native compilation**. Package tests passed, but `simctl` also listed `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`; the selector incorrectly treated that device-specific runtime as an invalid general runtime. Artifact `15067154396` has verified ZIP SHA-256 `cf99246763076067d563aa20607258ab8961728facc7d60466e6d54c4e81dc05`. The corrected selector excludes that specialized variant without rejecting the installed general runtime. Replaying both actual inventory files now selects the available iPhone 18 Pro Max on general iOS 27.2 build `24B8117`. A regression test preserves this observed case. This offline inventory replay is not a successful native game test.

### Renewed independent Codex review

Three new real Codex CLI sessions started on Wd on 26 November at 01:04 Moscow time, each from the exact published `ad02eb8` baseline, in separate worktrees with a 20-minute deadline and read-only review instructions. Their launch receipts and event logs are recorded by the coordinator; launch alone is not a completed or accepted review.

All three returned source-review results. The gameplay review identified premature release guidance and misleading combo notation; the release review identified rerun allocation, source-binding, review-time metadata, final membership readback, stale workflow receipt and phone-format gaps. Focused source corrections and regressions address these findings before release. Their static review results do not replace native input or external Apple review evidence.

The consolidated corrections passed 100 local continuity/release tests and 31 CI-helper tests on 26 November, including bounded subprocess cleanup, exact binary/intent consumption and the observed simulator inventory case. Shell, Python, Node and workflow YAML checks also passed. Six additional Swift tutorial behavior tests are included for the next native run; they were not executed in the Linux coordinator environment.

| Review | Session |
| --- | --- |
| Native startup and evidence | `01a214bc-c141-7b52-bc5d-2b2318a970ec` |
| Gameplay and beta usability | `01a214bc-c165-7352-ace9-17d8558e6d6e` |
| Public TestFlight continuity | `01a214bc-c11c-72f3-8f03-9466fb85059f` |

### Confirmed Metal simulator failure and controlled comparison

Source `ee74d5d146ef97daa3cbf5fe32113551abc385b6` passed continuity [45713637714](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45713637714) and all four CodeQL analyses [45713627574](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45713627574). Native [45713637769](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45713637769), attempt 1, **FAILED** on 26 November at 01:49 Moscow time. It selected iPhone 18 Pro Max on the general iOS 27.2 runtime, build `24B8117`, with SDK 27.2. The core-test command succeeded. Four hosted tests passed, two hosted tests crashed, and the UI app crashed during launch before the Play query. No required gameplay captures or unsigned archive completed.

Three recovered `.ips` reports show `EXC_CRASH/SIGABRT`, termination namespace `METAL`, code `102`, and an interrupted connection to `SimMetalHost`. Two hosted processes detected the lost service during skeletal-pose buffer updates; the UI process detected it during `ARView.snapshot`. These are client abort sites, not proof of what killed the service. The UI startup trace completed audio preparation, scene loading and bootstrap before the crash. A PID-verified sample attempt timed out without a report. The post-test screenshot shows SpringBoard, not a playable game.

The lightweight artifact `15069542700` has SHA-256 `29665242be4fa9995b2b3c43d09744b0a0494fff68f63e4c06f9575125afca4d`; the full evidence artifact `15070540593`, used to recover the three manifest-listed crash reports, has SHA-256 `bd635ecda54b012f249c8741799e3aefa4b44e203f35118ebeb9f744e2f31156`. The checked-out merge `da1edea70648d8fd6a8899babe9b33dcb7a2e66c` and reviewed source share tree `07c2d289def47de8c5fad2f2b88953208c1f0516`.

The next diagnostic compares unchanged application/asset source across the installed general iOS 27.0 and SDK-matched 27.2 runtimes. The unsigned workflow exposes an explicit `runtime_version=27.0` comparison option; its receipt retains the actual SDK and marks the runtime override. This comparison runs the same ordinary-input, render and hosted tests. It does not satisfy the SDK-matched release gate or create a signed release; an unsigned archive is unnecessary for this diagnostic. The normal PR and protected TestFlight validation continue to require the SDK-matched runtime, with no automatic fallback.

Native diagnostics now retain application crash attachments and collect bounded, time-filtered `SimMetalHost` service crash reports. These reports are evidence about the same job window, not proof of exclusive ownership or a specific root cause. A unified-log query is not implemented. Failed or partial collection remains visible in its receipt. No production rendering change is justified solely by the client abort stacks.

## Human and device gates still open

Observe at least a few first-time players without spoken coaching. Record device/build, time to first meaningful input, whether the charge/release/dive/landing relationship is understood, whether collision causes are readable, and whether players voluntarily retry. Keep actual observations and disagreements; do not convert an automated survival trace into a PASS.

Measure sustained frame pacing, thermals, audio/haptics and battery behavior on an actual supported iPhone. The app requests 60 Hz gameplay; no sustained 60/120 Hz result is claimed from that setting. Inspect iPad safe areas, Reduce Motion, large text and accessibility actions separately.

## External distribution gates

The existing Apple identity is authorized, but 0.2.0 (1002.1) was an internal pilot. External v0.3 needs its exact processed build, truthful metadata, a real review contact, Apple Beta App Review approval and a read-back public URL. An enabled URL alone does not prove an external install/play/report cycle. No social post or tester message is implied by this record.

The durable coordinator state is on the already-authorized Wd operations host. It imports the actual lane receipts and preserves separate blocked-input/access records. It is a bounded, explicitly resumable supervisor with GitHub event observations, not an unobserved always-running autonomous service.
