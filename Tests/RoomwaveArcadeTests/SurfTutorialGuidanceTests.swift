import XCTest
@testable import RoomwaveArcade

final class SurfTutorialGuidanceTests: XCTestCase {
    private func course(length: Double = 500) throws -> CompiledSurfCourse {
        try SurfCourseCompiler.compile(SurfCourseDefinition(
            id: "tutorial-guidance-fixture", title: "Guidance", subtitle: "Actual input fixture",
            biome: .dawn, seed: 19,
            samples: [SurfCourseSample(distance: 0, center: SurfVector(x: 0, y: 0, z: 0)),
                      SurfCourseSample(distance: length, center: SurfVector(x: 0, y: 0, z: -length))],
            encounters: [], medalScores: [100, 500, 1_000]))
    }

    private func held(_ count: Int, from initial: SurfState, course: CompiledSurfCourse,
                      rules: SurfRules = .standard) throws -> SurfState {
        var state = initial
        for _ in 0..<count {
            state = try SurfSimulation.step(state: state,
                input: SurfInput(tick: state.tick, pressed: true), course: course, rules: rules).state
        }
        return state
    }

    func testFollowingReleaseCueProducesAnActualTakeoffWithDifferentRules() throws {
        let course = try course()
        for rules in [SurfRules.standard, SurfRules(tickRate: 120, maximumCharge: 2)] {
            var state = SurfSimulation.start(course: course, rules: rules)
            var launched = false
            for _ in 0..<rules.tickRate {
                state = try held(1, from: state, course: course, rules: rules)
                let cue = SurfTutorialGuidance.cue(state: state, pressed: true,
                    cancellationPending: false, course: course, rules: rules)
                if cue == .release {
                    let released = try SurfSimulation.step(state: state,
                        input: SurfInput(tick: state.tick, pressed: false), course: course, rules: rules)
                    XCTAssertTrue(released.events.contains { $0.kind == .takeoff })
                    XCTAssertFalse(released.state.grounded)
                    launched = true
                    break
                }
                XCTAssertEqual(cue, .charge)
            }
            XCTAssertTrue(launched, "The cue must become available for real held input")
        }
    }

    func testAnUnderchargedReleaseLeavesChargeGuidanceAvailable() throws {
        let course = try course()
        let charged = try held(6, from: SurfSimulation.start(course: course), course: course)
        // This passes the old UI threshold but does not qualify for a real jump.
        XCTAssertGreaterThan(charged.charge, 0.12)
        XCTAssertEqual(SurfTutorialGuidance.cue(state: charged, pressed: true,
            cancellationPending: false, course: course), .charge)
        let released = try SurfSimulation.step(state: charged,
            input: SurfInput(tick: charged.tick, pressed: false), course: course)
        XCTAssertTrue(released.state.grounded)
        XCTAssertFalse(released.events.contains { $0.kind == .takeoff })
        XCTAssertEqual(SurfTutorialGuidance.cue(state: released.state, pressed: false,
            cancellationPending: false, course: course), .charge)
        XCTAssertEqual(SurfTutorialGuidance.cue(state: released.state, pressed: true,
            cancellationPending: false, course: course), .charge)
    }

    func testCancellationRearmsGuidanceBeforeAndAfterItsRecordedTick() throws {
        let course = try course()
        let charged = try held(16, from: SurfSimulation.start(course: course), course: course)
        XCTAssertEqual(SurfTutorialGuidance.cue(state: charged, pressed: true,
            cancellationPending: false, course: course), .release)
        for pressed in [false, true] {
            XCTAssertEqual(SurfTutorialGuidance.cue(state: charged, pressed: pressed,
                cancellationPending: true, course: course), .charge)
        }
        let cancelled = try SurfSimulation.step(state: charged,
            input: SurfInput(tick: charged.tick, pressed: false, cancelled: true), course: course)
        XCTAssertTrue(cancelled.state.grounded)
        XCTAssertEqual(cancelled.state.charge, 0)
        XCTAssertFalse(cancelled.events.contains { $0.kind == .takeoff })
        XCTAssertFalse(SurfTutorialGuidance.observedCleanLanding(in: cancelled.events))
        XCTAssertEqual(SurfTutorialGuidance.cue(state: cancelled.state, pressed: false,
            cancellationPending: false, course: course), .charge)
        let recharged = try held(16, from: cancelled.state, course: course)
        XCTAssertEqual(SurfTutorialGuidance.cue(state: recharged, pressed: true,
            cancellationPending: false, course: course), .release)
    }

    func testAirborneGuidanceRespondsToTheCurrentFingerInsteadOfALatchedStage() throws {
        let course = try course()
        let charged = try held(16, from: SurfSimulation.start(course: course), course: course)
        let launched = try SurfSimulation.step(state: charged,
            input: SurfInput(tick: charged.tick, pressed: false), course: course)
        XCTAssertFalse(launched.state.grounded)
        XCTAssertEqual(SurfTutorialGuidance.cue(state: launched.state, pressed: false,
            cancellationPending: false, course: course), .dive)
        XCTAssertEqual(SurfTutorialGuidance.cue(state: launched.state, pressed: true,
            cancellationPending: false, course: course), .releaseBeforeLanding)
        XCTAssertEqual(SurfTutorialGuidance.cue(state: launched.state, pressed: true,
            cancellationPending: true, course: course), .dive)
        XCTAssertFalse(SurfTutorialGuidance.observedCleanLanding(in: launched.events))
    }

    func testRoughDiveDoesNotCompleteLessonButReleasedCleanLandingDoes() throws {
        let course = try course()
        func landing(from initial: SurfState, holdThroughContact: Bool) throws -> SurfStep {
            var state = try held(20, from: initial, course: course)
            let launch = try SurfSimulation.step(state: state,
                input: SurfInput(tick: state.tick, pressed: false), course: course)
            XCTAssertTrue(launch.events.contains { $0.kind == .takeoff })
            state = launch.state
            for airborneTick in 0..<240 {
                let input = SurfInput(tick: state.tick,
                    pressed: holdThroughContact || airborneTick < 10)
                let step = try SurfSimulation.step(state: state, input: input, course: course)
                if step.events.contains(where: { $0.kind == .landing }) { return step }
                state = step.state
            }
            XCTFail("The actual flight must reach a landing within the bounded fixture")
            return SurfStep(state: state, events: [])
        }
        let rough = try landing(from: SurfSimulation.start(course: course), holdThroughContact: true)
        XCTAssertTrue(rough.events.contains { $0.kind == .landing })
        XCTAssertFalse(rough.events.contains { $0.kind == .perfectLanding })
        XCTAssertFalse(SurfTutorialGuidance.observedCleanLanding(in: rough.events))
        let clean = try landing(from: rough.state, holdThroughContact: false)
        XCTAssertTrue(clean.events.contains { $0.kind == .perfectLanding })
        XCTAssertTrue(SurfTutorialGuidance.observedCleanLanding(in: clean.events))
        XCTAssertGreaterThan(clean.state.perfectLandings, rough.state.perfectLandings)
        XCTAssertGreaterThan(clean.state.score, rough.state.score)
    }

    func testTerminalStateDoesNotOfferAnotherControlAction() throws {
        let course = try course()
        let rules = SurfRules(maximumTicks: 1)
        let initial = SurfSimulation.start(course: course, rules: rules)
        let terminal = try SurfSimulation.step(state: initial,
            input: SurfInput(tick: 0, pressed: false), course: course, rules: rules)
        XCTAssertEqual(terminal.state.phase, .crashed)
        XCTAssertNil(SurfTutorialGuidance.cue(state: terminal.state, pressed: true,
            cancellationPending: false, course: course, rules: rules))
        XCTAssertFalse(SurfTutorialGuidance.observedCleanLanding(in: terminal.events))
    }
}
