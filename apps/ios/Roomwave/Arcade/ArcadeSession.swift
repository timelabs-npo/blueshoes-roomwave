import Foundation
import Combine
import QuartzCore
import UIKit
import RoomwaveArcade
import RoomwaveCreator

@MainActor
final class ArcadeSession: ObservableObject {
    let scene = ArcadeSceneController()
    @Published private(set) var screen: ArcadeScreen = .home
    @Published private(set) var hud = ArcadeHUD()
    @Published private(set) var selectedID = "neon-dawn"
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var preferences = ArcadePreferences()
    @Published private(set) var result: SurfRunResult?
    @Published private(set) var previousBest: Int?
    @Published private(set) var tutorialCue: SurfTutorialCue? = .charge
    @Published private(set) var selectedBest: ArcadeBest?

    private let rules = SurfRules.standard
    private let profile = ArcadeProfile()
    private let audio = ArcadeAudio()
    private var compiled: [String: CompiledSurfCourse] = [:]
    private var viralBaseCourse: CompiledSurfCourse?
    private(set) var course: CompiledSurfCourse?
    private(set) var state: SurfState?
    private(set) var inputs: [SurfInput] = []
    private var frameEvents: [SurfEvent] = []
    private var pendingCourseID: String?
    private var profileLoaded = false
    private var held = false
    private var cancelInputOnNextTick = false
    private var isActive = true
    private var systemReducedMotion = false
    private var displayLink: CADisplayLink?
    private var displayProxy: ArcadeDisplayProxy?
    private var lastTimestamp: CFTimeInterval?
    private var accumulator = 0.0
    private var previewTime = 0.0
    private var lastHUDTime = 0.0
    private var calloutUntil = 0.0
    private var callout = ""
    private var calloutID = 0

    var reducedMotion: Bool { preferences.reducedMotion || systemReducedMotion }
    var availableCourseIDs: [String] {
        ArcadeProfile.courseIDs + compiled.keys.filter { !ArcadeProfile.courseIDs.contains($0) }.sorted()
    }
    var title: String { course?.definition.title ?? selectedID.replacingOccurrences(of: "-", with: " ").uppercased() }
    var subtitle: String { course?.definition.subtitle ?? "Find your flow above the current." }
    var tutorial: String? {
        guard !preferences.tutorialSeen else { return nil }
        switch tutorialCue {
        case .some(.charge): return "HOLD TO CHARGE"
        case .some(.release): return "RELEASE TO SOAR"
        case .some(.dive): return "HOLD TO DIVE · RELEASE BEFORE LANDING"
        case .some(.releaseBeforeLanding): return "RELEASE BEFORE LANDING"
        case nil: return nil
        }
    }

    /// Read the next upcoming hazard, not decorative effects. The cue is
    /// text/shape based and appears before the collider at maximum speed.
    var masteryCue: String? {
        guard selectedID == "prism-break", screen == .playing,
              let course, let state,
              let hazard = course.definition.encounters.dropFirst(state.encounterCursor).prefix(4)
                  .first(where: { $0.kind == .barrier || $0.kind == .ceiling }),
              (0...24).contains(hazard.distance - state.distance) else { return nil }
        return hazard.kind == .ceiling ? "↓  LOW ARCH" : "↑  CLEAR THE BAR"
    }

    var resultExplanation: String? {
        guard result != nil, let state, state.phase == .crashed else { return nil }
        if state.shields == 0 {
            let finalHit = frameEvents.contains {
                $0.kind == .hit && $0.tick == state.tick && $0.value == 0
            }
            return finalHit ? "An obstacle hit used your last shield." : "No shields remaining."
        }
        if state.tick >= rules.maximumTicks { return "The run time limit was reached." }
        return "This run ended."
    }

    func bootstrap() async {
        guard !isLoading, course == nil else { return }
        isLoading = true
        errorMessage = nil
        #if DEBUG
        traceEvidence("bootstrap_enter")
        #endif
        defer {
            isLoading = false
            #if DEBUG
            traceEvidence("bootstrap_finished")
            #endif
        }
        if !profileLoaded {
            profile.load(); profileLoaded = true
            preferences = profile.preferences
            statusMessage = profile.notice
            inputs.reserveCapacity(rules.maximumTicks)
            frameEvents.reserveCapacity(32)
            audio.onInterruption = { [weak self] in self?.pause() }
            #if DEBUG
            traceEvidence("audio_prepare_begin")
            #endif
            await audio.prepare()
            #if DEBUG
            traceEvidence("audio_prepare_end")
            #endif
            statusMessage = profile.notice ?? audio.notice
        }
        do {
            if compiled.isEmpty {
                var courses: [String: CompiledSurfCourse] = [:]
                for id in ArcadeProfile.courseIDs {
                    guard let definition = SurfCatalog.course(id: id) else {
                        throw SessionError.missingCourse(id)
                    }
                    courses[id] = try SurfCourseCompiler.compile(definition)
                }
                compiled = courses
                #if DEBUG
                traceEvidence("course_compile_end")
                #endif
            }
            if pendingCourseID == nil { pendingCourseID = selectedID }
            try await loadPendingCourses()
        } catch {
            fail("Could not load the course: \(error.localizedDescription)")
        }
    }

    /// Whitelist only. No networking, imported payload, photo metadata or arbitrary decoding.
    func handle(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "roomwave", parts.host?.lowercased() == "challenge",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, parts.path.isEmpty,
              let items = parts.queryItems, items.count == 2,
              items.filter({ $0.name == "course" }).count == 1,
              items.filter({ $0.name == "rules" }).count == 1,
              items.first(where: { $0.name == "rules" })?.value == "3",
              let id = items.first(where: { $0.name == "course" })?.value,
              ArcadeProfile.courseIDs.contains(id) else {
            statusMessage = "This challenge is not supported. Choose a built-in course."
            return
        }
        requestCourse(id)
    }

    func selectCourse(offset: Int) {
        guard !isLoading else { return }
        let ids = availableCourseIDs
        let index = ids.firstIndex(of: selectedID) ?? (offset > 0 ? -1 : 0)
        requestCourse(ids[(index + offset + ids.count) % ids.count])
    }

    func useInspiredCourse(_ next: CompiledSurfCourse) {
        guard next.definition.source == .photoInspired || next.definition.source == .lidarInspired else { return }
        // Retain one local creation alongside the authored catalog, never raw input.
        compiled = compiled.filter { ArcadeProfile.courseIDs.contains($0.key) }
        compiled[next.definition.id] = next
        viralBaseCourse = nil
        requestCourse(next.definition.id)
    }

    /// Social observations select the next immutable course. They never mutate
    /// an active run, grant points, or repeatedly deform a previous social course.
    func useViralCurrent(_ current: ViralCurrent) {
        guard screen != .playing, let selected = course else { return }
        let social = selected.definition.source == .xInspired || selected.definition.source == .xLidarInspired
        let base = social ? (viralBaseCourse ?? selected) : selected
        do {
            let next = try ViralCourseFactory.make(base: base, current: current)
            viralBaseCourse = base
            compiled = compiled.filter { ArcadeProfile.courseIDs.contains($0.key) }
            compiled[next.definition.id] = next
            requestCourse(next.definition.id)
        } catch {
            statusMessage = "Could not shape this current. Refresh X activity and try again."
        }
    }

    private func requestCourse(_ id: String) {
        pendingCourseID = id
        held = false
        stopClock(); audio.stop()
        screen = .home
        result = nil
        // During bootstrap/load, the serialized load loop consumes the newest request.
        guard !isLoading else { return }
        guard !compiled.isEmpty else {
            Task { await bootstrap() }
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do { try await loadPendingCourses() }
            catch { fail("Could not load the course: \(error.localizedDescription)") }
        }
    }

    private func loadPendingCourses() async throws {
        while let id = pendingCourseID {
            pendingCourseID = nil
            guard let next = compiled[id] else { throw SessionError.missingCourse(id) }
            course = nil
            state = nil
            #if DEBUG
            traceEvidence("scene_load_begin")
            #endif
            try await scene.load(course: next)
            #if DEBUG
            traceEvidence("scene_load_end")
            #endif
            selectedID = id
            course = next
            state = SurfSimulation.start(course: next, rules: rules)
            selectedBest = profile.bests[id]
            previewTime = 0
            #if DEBUG
            traceEvidence("state_published")
            #endif
            scene.preview(time: 0, reducedMotion: reducedMotion)
        }
        if isActive {
            startClock(preview: true)
            #if DEBUG
            traceEvidence("clock_started")
            #endif
        }
    }

    func play() {
        guard !isLoading, errorMessage == nil, isActive, let course else { return }
        held = false; cancelInputOnNextTick = false
        accumulator = 0; lastHUDTime = 0; callout = ""; calloutUntil = 0
        inputs.removeAll(keepingCapacity: true)
        state = SurfSimulation.start(course: course, rules: rules)
        result = nil; previousBest = nil; tutorialCue = .charge
        screen = .playing
        publishHUD(now: CACurrentMediaTime())
        audio.configure(preferences, running: true)
        startClock(preview: false)
    }

    func setPressed(_ pressed: Bool) {
        guard screen == .playing, isActive else { held = false; return }
        held = pressed
        updateTutorialCue()
    }

    func cancelTouch() {
        held = false
        if screen == .playing { cancelInputOnNextTick = true }
        updateTutorialCue()
    }

    func pause() {
        if screen == .playing { cancelInputOnNextTick = true }
        held = false
        updateTutorialCue()
        stopClock(); audio.stop()
        if screen == .playing { screen = .paused }
        observeEvidence()
    }

    func resume() {
        guard screen == .paused, isActive, errorMessage == nil else { return }
        held = false
        screen = .playing
        updateTutorialCue()
        audio.configure(preferences, running: true)
        startClock(preview: false)
    }

    func home() {
        held = false
        stopClock(); audio.stop()
        screen = .home
        result = nil
        if let course { state = SurfSimulation.start(course: course, rules: rules) }
        if isActive, course != nil, errorMessage == nil { startClock(preview: true) }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active { pause() }
        else if screen == .home, course != nil, !isLoading, errorMessage == nil { startClock(preview: true) }
        // A paused run always requires the player's explicit Resume action.
    }

    func setSystemReducedMotion(_ enabled: Bool) { systemReducedMotion = enabled }

    func updatePreferences(_ value: ArcadePreferences) {
        preferences = value
        profile.update(preferences: value)
        statusMessage = profile.notice ?? audio.notice
        audio.configure(value, running: screen == .playing && isActive)
    }

    func dismissNotice() { statusMessage = nil }

    func dismissTutorial() { markTutorialSeen() }

    func retryLoad() {
        guard !isLoading else { return }
        held = false
        stopClock(); audio.stop()
        screen = .home
        result = nil
        course = nil
        Task { await bootstrap() }
    }

    private func startClock(preview: Bool) {
        stopClock()
        let proxy = ArcadeDisplayProxy(session: self)
        let link = CADisplayLink(target: proxy, selector: #selector(ArcadeDisplayProxy.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: preview ? 20 : 60,
            maximum: preview ? 30 : 60, preferred: preview ? 30 : 60)
        displayProxy = proxy; displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil; displayProxy = nil
        lastTimestamp = nil; accumulator = 0
    }

    fileprivate func frame(_ link: CADisplayLink) {
        #if DEBUG
        // Persist liveness before any preview/render/snapshot work can block.
        ArcadeEvidenceProbe.heartbeat(screen: screen, tick: state?.tick ?? 0,
                                      isLoading: isLoading, isActive: isActive)
        #endif
        guard isActive else { return }
        let now = link.timestamp
        let rawElapsed = now - (lastTimestamp ?? now)
        guard rawElapsed.isFinite, rawElapsed >= 0 else {
            lastTimestamp = now.isFinite ? now : nil
            accumulator = 0
            return
        }
        // Slow rendering must not masquerade as a lifecycle interruption. Drop
        // excess simulation debt; scene-phase/audio interruptions pause explicitly.
        let elapsed = min(0.1, rawElapsed)
        lastTimestamp = now
        if screen == .home {
            previewTime += elapsed
            scene.preview(time: previewTime, reducedMotion: reducedMotion)
            observeEvidence()
            return
        }
        guard screen == .playing, let course, var current = state else { return }
        accumulator = min(0.1, accumulator + elapsed)
        frameEvents.removeAll(keepingCapacity: true)
        let tickDuration = 1.0 / 60.0
        var significant = false
        do {
            var steps = 0
            while accumulator >= tickDuration, steps < 6, current.phase == .running {
                guard inputs.count < rules.maximumTicks else { throw SessionError.traceLimit }
                let input = SurfInput(tick: current.tick, pressed: held, cancelled: cancelInputOnNextTick)
                let step = try SurfSimulation.step(state: current, input: input, course: course, rules: rules)
                cancelInputOnNextTick = false
                inputs.append(input)
                current = step.state
                accumulator -= tickDuration
                steps += 1
                for event in step.events {
                    frameEvents.append(event)
                    audio.play(event)
                    if event.kind == .takeoff || event.kind == .landing { significant = true }
                    if let message = Self.callout(for: event) {
                        callout = message; calloutUntil = now + 1.1; calloutID += 1
                        significant = true
                    }
                }
                if !preferences.tutorialSeen,
                   SurfTutorialGuidance.observedCleanLanding(in: step.events) {
                    markTutorialSeen()
                }
            }
            state = current
            // height remains the absolute rider-foot Y from the simulation, unmodified.
            scene.render(state: current, events: frameEvents, deltaTime: elapsed,
                         reducedMotion: reducedMotion, ghost: nil)
            observeEvidence(events: frameEvents)
            if significant || now - lastHUDTime >= 0.1 {
                publishHUD(now: now)
                audio.update(speed: current.speed, charge: current.charge)
            }
            if current.phase != .running { finish(current, course: course) }
        } catch {
            state = current
            fail("The run stopped: \(error.localizedDescription)")
        }
    }

    private func finish(_ final: SurfState, course: CompiledSurfCourse) {
        held = false
        stopClock(); audio.endRun()
        let run = SurfSimulation.result(state: final, course: course, rules: rules)
        result = run
        previousBest = profile.record(run)
        selectedBest = profile.bests[course.definition.id]
        profile.save(replay: SurfReplay(courseID: course.definition.id, seed: course.definition.seed,
            rulesVersion: rules.version, inputs: inputs, finalState: final))
        statusMessage = profile.notice ?? audio.notice
        screen = .results
        publishHUD(now: CACurrentMediaTime())
        observeEvidence()
    }

    private func observeEvidence(events: [SurfEvent] = []) {
        #if DEBUG
        ArcadeEvidenceProbe.observe(state: state, course: course, screen: screen, events: events,
                                    view: scene.view, isLoading: isLoading, isActive: isActive)
        #endif
    }

    #if DEBUG
    private func traceEvidence(_ stage: String) {
        ArcadeEvidenceProbe.trace(stage, screen: screen, tick: state?.tick ?? 0,
                                  isLoading: isLoading, isActive: isActive)
    }
    #endif

    private func publishHUD(now: Double) {
        guard let state else { return }
        updateTutorialCue()
        var next = ArcadeHUD()
        next.score = state.score; next.combo = state.combo; next.shields = state.shields
        next.speed = Int(state.speed.rounded())
        next.progress = min(1, max(0, state.distance / max(1, course?.length ?? 1)))
        next.charge = state.charge; next.airborne = !state.grounded
        next.callout = now < calloutUntil ? callout : ""
        next.calloutID = calloutID
        if next != hud { hud = next }
        lastHUDTime = now
    }

    private func updateTutorialCue() {
        guard !preferences.tutorialSeen, let state, let course else { return }
        let next = SurfTutorialGuidance.cue(state: state, pressed: held,
            cancellationPending: cancelInputOnNextTick, course: course, rules: rules)
        if next != tutorialCue { tutorialCue = next }
    }

    private func markTutorialSeen() {
        guard !preferences.tutorialSeen else { return }
        preferences.tutorialSeen = true
        profile.update(preferences: preferences)
    }

    private func fail(_ message: String) {
        held = false
        stopClock(); audio.stop()
        errorMessage = message
        if screen == .playing { screen = .paused }
    }

    private static func callout(for event: SurfEvent) -> String? {
        switch event.kind {
        case .perfectLanding: return "PERFECT LANDING"
        case .ring: return "RING +\(event.value)"
        case .boost: return "BOOST"
        case .hit: return "SHIELD HIT"
        case .comboLost: return "FIND YOUR FLOW"
        case .finish: return "COURSE COMPLETE"
        default: return nil
        }
    }

    private enum SessionError: LocalizedError {
        case missingCourse(String), traceLimit
        var errorDescription: String? {
            switch self {
            case .missingCourse(let id): return "The bundled course \(id) is missing."
            case .traceLimit: return "The bounded run input limit was reached."
            }
        }
    }
}

@MainActor
private final class ArcadeDisplayProxy: NSObject {
    weak var session: ArcadeSession?
    init(session: ArcadeSession) { self.session = session }
    @objc func frame(_ link: CADisplayLink) {
        guard let session else { link.invalidate(); return }
        session.frame(link)
    }
}
