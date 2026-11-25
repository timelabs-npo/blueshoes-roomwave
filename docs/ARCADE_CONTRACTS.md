# Frozen arcade v3 interfaces

The coordinator owns `SurfContracts.swift`, `ArcadeContracts.swift` and Package.swift. Workers request amendments instead of editing them. The planar v1/v2 descriptors remain legacy records and are never silently interpreted as v3 courses.

## Gameplay API to implement

```swift
public enum SurfCourseCompiler {
    public static func compile(_ definition: SurfCourseDefinition) throws -> CompiledSurfCourse
}
public extension CompiledSurfCourse {
    func pose(at distance: Double) -> SurfPose
}
public enum SurfCatalog {
    public static var all: [SurfCourseDefinition] { get }
    public static func course(id: String) -> SurfCourseDefinition?
    public static func daily(day: String) -> SurfCourseDefinition // yyyy-MM-dd UTC supplied by caller
}
public enum SurfSimulation {
    public static func start(course: CompiledSurfCourse, rules: SurfRules = .standard) -> SurfState
    public static func step(state: SurfState, input: SurfInput, course: CompiledSurfCourse,
                            rules: SurfRules = .standard) throws -> SurfStep
    public static func result(state: SurfState, course: CompiledSurfCourse,
                              rules: SurfRules = .standard) -> SurfRunResult
    public static func verify(replay: SurfReplay, course: CompiledSurfCourse,
                              rules: SurfRules = .standard) throws -> SurfState
}
```

Stable authored IDs: `neon-dawn`, `low-orbit`, `black-current`. A course begins at distance0 and has monotonically increasing samples, real elevations and bounded slopes/widths. Pose sampling must clamp endpoints and use cached/ordered samples without per-frame full validation. Forward points in the direction of increasing course distance; scene convention is Y-up and roughly forward -Z. Encounters have unique integer IDs and increasing distance; their heights are relative to the road. Keep a forgiving opening before lethal obstacle sequences. Grounded state.height is the absolute road elevation (rider foot), not the body center.

`step` advances exactly one fixed tick and requires `input.tick == state.tick`. It returns ordered one-shot events. `previousPressed` encodes release edges. Press builds grounded charge and increases airborne gravity; release can launch with enough charge. Timing and slope affect momentum and clean landings. Outcomes must remain finite/bounded, collision tests swept over progress, terminal state stable, and score arithmetic bounded. Do not award points for simply holding forever. Replay verification is local determinism, not server attestation.

Core behavior tests should show different timing gives different trajectory/score; successful intentional play and a distinct mistimed trace; encounters cannot tunnel at max speed; invalid course/input rejection; exact replay; stable terminal states. Do not create a test whose only achievement is a constant correcting bot surviving an empty course.

## Presentation

Implement `@MainActor final class ArcadeSceneController: ArcadeSceneDriving` with `init()`. Use the protocol in `ArcadeContracts.swift` verbatim. Load/render real track elevation and typed encounters with consistent simulation collision dimensions. Reuse bundled RoomwavePilot.usdz visibly; skin/coat default on, helper overlays off. Art direction: navy/ink void, faceted teal/violet landscape, cyan luminous road edges, warm gold rings, coral hazards. Keep the center readable. Three biomes should be recognizable. Use time-based camera smoothing, bounded effects and cached entities. No fake capture/PASS marker or alternate CI-only gameplay. Emit actual render/error evidence when asked by coordinator.

## Experience

Implement `@MainActor final class ArcadeSession: ObservableObject` and `ArcadeRootView(session: ArcadeSession)` with session-owned renderer `ArcadeSceneController`. Coordinator replaces the app entry separately. Own timing/input/pause, native audio/haptics, persisted profile, UI flow and player-initiated sharing. Use the common core APIs above; a compile dependency on the presentation class is expected, not a reason to duplicate it.

Drive simulation at60Hz with a bounded elapsed-time accumulator. Render directly every display frame; publish HUD at around10Hz and phase/event changes. Backgrounding pauses a run and clears held input; resume deliberately. Persist scores/settings with an atomic app-private Codable file (avoid adding UserDefaults required-reason APIs). All three authored courses are available for beta learning, with medal progress rather than grind gates.

Build a full-screen game, not a ScrollView workbench. Home: atmospheric real scene, brand, selected course, one Play action; course selector and settings secondary. Play: score/combo, shields, small progress, pause; tutorial gestures integrated briefly. Results: score, personal best delta, medal, Retry and Share. Preview/configuration controls must not cover the playfield. Include sound/haptics/reduced-motion preferences.

Use original procedural/synthesized audio or explicitly permitted sources; never borrow reference-game music. An on-demand generated audio buffer is acceptable if bounded and off the real-time render callback. Share a rendered result card plus stable course/rules text; implement safe `roomwave://challenge?course=<whitelisted-id>&rules=3` handling. X composer/native share is user initiated; never infer posting or award social-engagement points. Do not put absent public TestFlight URLs in the app. Optional ReplayKit recording must be explicitly enabled by the player and must capture actual gameplay.

## Review and truthful limits

The current build/release path remains the authority for native compilation and signing. Wd/Linux workers cannot claim Xcode results. Record executed commands and failures, changed files, known gaps and suggested next actions in the assigned lane note. No hidden placeholder may be presented as the requested experience. Contract changes go to root first.
