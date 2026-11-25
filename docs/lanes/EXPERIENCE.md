# Experience lane delivery — 25 November 2026

Baseline verified before edits: `0f52279e465ae8ec9ebb806254f211722444236f`, branch `arcade-v03/experience`, assigned Windows worktree. Working tree was initially clean. Read AGENTS.md, ARCADE_REBUILD.md, ARCADE_CONTRACTS.md and both frozen Swift contracts before implementation. No contracts, app entry, Package.swift, project settings, legacy sources or other lanes changed. No commits, pushes, branch changes, workers, dependencies, workflows or account actions.

## Delivered files

- `apps/ios/Roomwave/Arcade/ArcadeSession.swift`: main actor ObservableObject, one owned ArcadeSceneController, serialized bootstrap/course loading, challenge allowlist, deterministic fixed-step clock, tick input trace, HUD, pause/resume/home/results and errors.
- `ArcadeRootView.swift`: fullscreen scene host, native immediate touch surface, home/course selection, compact HUD/tutorial, pause, results, preferences and share presentation. Landscape results use two columns; portrait/iPad menus have bounded content widths. Controls respect safe areas while the field fills the display.
- `ArcadeAudio.swift`: original generated oscillator loop and six event cues, bounded four-voice pool, event haptics, interruption/unplug handling and sound preference. No external audio assets or soundtrack reuse.
- `ArcadeProfile.swift`: private Application Support JSON settings/bests and latest terminal replay, atomic writes, conservative missing/corrupt/newer record behavior and bounded data.
- `ArcadeSharing.swift`: fixed 540 × 720 point score card rendered at 2× with ImageRenderer, actual result text, whitelisted course/rules URL and native UIActivityViewController.
- This lane note. Optional ArcadeRecording.swift was intentionally omitted.

## Coordinator integration

Compose and retain `ArcadeSession()` once, then `ArcadeRootView(session: session)`. Root calls `bootstrap()` from `.task`, handles `.onOpenURL` and observes scenePhase and system Reduce Motion. External composition can also call `bootstrap() async`, `handle(url:)`, `pause()` and `resume()` directly. Do not instantiate a second renderer in the app entry.

Dependencies are the exact frozen `RoomwaveArcade` API and presentation lane's `ArcadeSceneController()` conforming to ArcadeSceneDriving. These implementations are absent in this isolated baseline as expected. Coordinator must integrate the module/product and app entry/settings; this worker did not edit them. The registered URL scheme must reach root's onOpenURL; app URL registration is coordinator-owned.

Challenge parsing accepts only `roomwave://challenge?course=<neon-dawn|low-orbit|black-current>&rules=3` (query order may vary). Rejects extra/duplicate/missing query keys, wrong rules, nonempty paths, credentials, ports, fragments and all other schemes/hosts/course IDs. No remote loading or arbitrary payload decode. A valid request before/during bootstrap replaces the pending selection; renderer loads remain serialized. Opening a valid challenge ends the current local run and returns to course preview; it never auto-starts play.

## Timing/input decisions

Simulation is exactly 1/60 second per input tick, at most six steps per display callback, with elapsed time and accumulator clamped to 100 ms. Excess wall time is dropped rather than replayed as a large catch-up burst. Display link requests 60 Hz for play, 20–30 Hz for preview. A weak target proxy avoids retaining the session; a callback whose session was released invalidates itself. Entities update directly each display callback. SwiftUI receives HUD at 10 Hz plus event transitions; the state and trace are not Published.

The UIKit touch layer reports touch-down immediately, supports held multitouch and cancels on removal, interruption, pause, background or result. Pause button is a separate foreground target outside the input layer. Held flags clear on every transition. The core has only a pressed Boolean: if paused while charging, the next resumed false input is a deterministic release under core rules. No state is secretly rewritten to suppress that edge, preserving exact replay. Coordinator should assess this edge on-device; a distinct cancel-input semantic would require a coordinator/core contract amendment.

`state.height` passes through unchanged as absolute rider-foot Y. Events drive callouts/audio/haptics; all score/results/medals come only from SurfSimulation. Inputs reserve maximumTicks capacity and append exactly the input supplied to each successful step. Terminal traces construct SurfReplay with course seed, standard rules and final state. Only the latest terminal run is saved (≤9,000 inputs, ≤2 MB); this is local determinism evidence, not server anti-cheat. Abandoned runs are not recorded as completed results. No ghost or replay browser is claimed.

## Expected user flows to verify natively

1. Launch into actual course preview with ROOMWAVE / SLIPSTREAM, all three course selectors and one Play action. No acquisition permission or legacy workbench.
2. Play: hold to charge, release to launch, hold airborne to dive; tutorial advances after observed charge/takeoff and persists learned state after a dive/landing. Check hazard readability with the presentation lane.
3. Pause/background/interruption/unplug: clear touch and suspend clock/audio. Returning foreground leaves a running game paused until Resume. Home preview may resume automatically. Restart begins a fresh trace and real simulation state.
4. Crash/finish: show actual score, medal if earned, previous-best delta, rings/perfect landings/best combo. Retry is one tap. Courses returns to preview. Finish audio has an ≤800 ms tail, then engine pauses.
5. Share: render the actual run card; sheet dismissal preserves the same result. The URL identifies a bundled course/rules, not a run attestation or an app download. No automatic posting, social reward or invented TestFlight link.
6. Settings: sound, haptics and reduced-motion preferences persist atomically. System Reduce Motion combines with player preference. Test VoiceOver surf actions and large text, phone portrait/landscape, iPad and native share presentation.
7. Missing/corrupt/newer profile: defaults permit play with a visible notice, while unreadable/newer file is preserved and disk writes disabled. Missing optional settings acquire defaults; unknown JSON fields are ignored. Save failures remain visible and do not block play. Verify restart persistence and compare saved replay against SurfSimulation.verify after integration.

## Audio provenance and limits

All oscillator formulas, note sequence and envelopes were authored in this lane. A quiet original eight-note D-minor pentatonic phrase and 55/110 Hz drone form a four-second loop; launch/clean landing/ring/boost/hit/finish use bounded sine sweeps and envelopes. Sample arrays are produced by a detached utility task before playback, copied to cached AVAudioPCMBuffer objects on the main actor, and scheduled with explicit completion-handler overloads. There is no real-time synthesis callback. Speed/charge adjust loop level/pan at HUD cadence. Ambient audio respects the device's silent-mode policy and mixes with other audio. Audio failure surfaces a notice and preserves gameplay. Listening/mix/haptic tuning on hardware is still required.

## Executed checks and gaps

- Verified `git branch --show-current`, `git rev-parse HEAD`, initial `git status --short` and read required files.
- Manual source/syntax/API-contract review only. Inspected official Apple documentation for CADisplayLink, AVAudioPlayerNode scheduling and SwiftUI tracking; no native toolchain was inferred from documentation.
- `Get-Command swift -ErrorAction SilentlyContinue` returned no Swift executable. No Swift/Xcode compile, simulation test, replay verification, native rendering, touch capture, playtest, listening session, device FPS/thermal or release check executed.
- `git diff --check` produced no output. Because files are new/untracked, also ran `git diff --no-index --check -- NUL <file>` for every delivered source and this note; no whitespace diagnostics. No-index can return 1 for the expected new-file difference; that is not a compile result.
- Final scope/baseline checks confirm only the six assigned delivery paths are new, with frozen baseline files unchanged.
- `docs/PRIVACY.md` is absent at baseline (verified by read/search). No unverified public privacy URL was added. Coordinator must create/review its current content and wire an accessible repository privacy link before public beta. Preferences include an accurate local arcade data summary, not a substitute for whole-app privacy policy.
- Ghost, ReplayKit recording, X-specific composer, daily/photo/LiDAR course UI and acquisition flows omitted. Existing acquisition code/assets untouched. Native sharing is implemented; no result says a post occurred.
- Native compilation and real player enjoyment remain unverified. Integrate the other lanes, compile under Swift 6, then exercise the flows above on simulator/device. This source delivery establishes neither runtime acceptance nor Apple review/public-beta approval.
