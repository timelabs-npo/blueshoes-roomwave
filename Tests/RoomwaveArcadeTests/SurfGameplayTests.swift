import Foundation
import XCTest
@testable import RoomwaveArcade

final class SurfGameplayTests: XCTestCase {
    private func flat(_ encounters: [SurfEncounter] = [], length: Double = 100, elevation: Double = 0) throws -> CompiledSurfCourse {
        try SurfCourseCompiler.compile(SurfCourseDefinition(id: "test-ribbon", title: "Ribbon", subtitle: "Test fixture",
            biome: .dawn, seed: 1,
            samples: [SurfCourseSample(distance: 0, center: SurfVector(x: 0, y: elevation, z: 0)),
                      SurfCourseSample(distance: length, center: SurfVector(x: 0, y: elevation, z: -length))],
            encounters: encounters, medalScores: [100, 500, 1_000]))
    }

    private func run(_ course: CompiledSurfCourse, rules: SurfRules = .standard,
                     input: (SurfState) -> Bool) throws -> (SurfState, [SurfInput], [SurfEvent]) {
        var state = SurfSimulation.start(course: course, rules: rules)
        var inputs: [SurfInput] = [], events: [SurfEvent] = []
        while state.phase == .running {
            let action = SurfInput(tick: state.tick, pressed: input(state))
            let next = try SurfSimulation.step(state: state, input: action, course: course, rules: rules)
            state = next.state
            inputs.append(action)
            events.append(contentsOf: next.events)
        }
        return (state, inputs, events)
    }

    /// Distance cues on the authored charge beds; calls the production step, with no substitute physics.
    private func intentional(_ state: SurfState) -> Bool {
        guard state.distance >= 40 else { return false }
        let phraseDistance = (state.distance - 40).truncatingRemainder(dividingBy: 120)
        return state.grounded && phraseDistance < 18
    }

    func testAuthoredCoursesAreDistinctElevatedAndCompile() throws {
        XCTAssertEqual(SurfCatalog.all.map(\.id), ["neon-dawn", "low-orbit", "black-current"])
        XCTAssertEqual(SurfCatalog.all.map(\.biome), [.dawn, .orbit, .midnight])
        for definition in SurfCatalog.all {
            let course = try SurfCourseCompiler.compile(definition)
            XCTAssertGreaterThan(course.length, 1_000)
            XCTAssertGreaterThan((definition.samples.map { $0.center.y }.max() ?? 0)
                                 - (definition.samples.map { $0.center.y }.min() ?? 0), 7)
            XCTAssertGreaterThan(definition.encounters.count, 25)
            XCTAssertTrue(definition.encounters.contains { $0.kind == .ring })
            XCTAssertTrue(definition.encounters.contains { $0.kind == .barrier })
            XCTAssertTrue(definition.encounters.contains { $0.kind == .ceiling })
            XCTAssertTrue(definition.encounters.contains { $0.kind == .boost })
            XCTAssertEqual(SurfCatalog.course(id: definition.id), definition)
        }
        XCTAssertNotEqual(SurfCatalog.all[0].samples, SurfCatalog.all[1].samples)
        XCTAssertNotEqual(SurfCatalog.all[1].encounters, SurfCatalog.all[2].encounters)
        XCTAssertNil(SurfCatalog.course(id: "missing"))
    }

    func testPosesClampInterpolateAndPointForward() throws {
        let definition = SurfCourseDefinition(id: "sloped", title: "Slope", subtitle: "Pose fixture", biome: .dawn,
            seed: 2, samples: [SurfCourseSample(distance: 0, center: SurfVector(x: 0, y: 12, z: 0), width: 6),
                              SurfCourseSample(distance: 20, center: SurfVector(x: 4, y: 16, z: -20), width: 8)],
            encounters: [], medalScores: [1, 2, 3])
        let course = try SurfCourseCompiler.compile(definition)
        XCTAssertEqual(course.pose(at: -99).center, definition.samples[0].center)
        XCTAssertEqual(course.pose(at: .nan).center, definition.samples[0].center)
        XCTAssertEqual(course.pose(at: .infinity).center, definition.samples[1].center)
        let middle = course.pose(at: 10)
        XCTAssertEqual(middle.center, SurfVector(x: 2, y: 14, z: -10))
        XCTAssertEqual(middle.width, 7)
        XCTAssertEqual(middle.slope, 0.2, accuracy: 0.000_001)
        let f = middle.forward
        XCTAssertEqual(f.x * f.x + f.y * f.y + f.z * f.z, 1, accuracy: 0.000_001)
        XCTAssertLessThan(f.z, 0)
        XCTAssertEqual(SurfSimulation.start(course: course).height, 12)
        let step = try SurfSimulation.step(state: SurfSimulation.start(course: course), input: SurfInput(tick: 0, pressed: true), course: course)
        XCTAssertEqual(step.state.height, course.pose(at: step.state.distance).center.y)
    }

    func testTickZeroChargeThresholdReleaseAndDiveChangeRealArcs() throws {
        let course = try flat(length: 300)
        func arc(holdTicks: Int, dive: Bool) throws -> (Double, SurfState, [SurfEvent]) {
            var s = SurfSimulation.start(course: course)
            var peak = s.height
            var events: [SurfEvent] = []
            for _ in 0..<180 {
                let pressed = s.tick < holdTicks || (dive && !s.grounded && s.tick > holdTicks + 12)
                let next = try SurfSimulation.step(state: s, input: SurfInput(tick: s.tick, pressed: pressed), course: course)
                XCTAssertEqual(next.state.tick, s.tick + 1)
                s = next.state
                peak = max(peak, s.height)
                events += next.events
            }
            return (peak, s, events)
        }
        let tap = try arc(holdTicks: 2, dive: false)
        let small = try arc(holdTicks: 16, dive: false)
        let large = try arc(holdTicks: 40, dive: false)
        let dived = try arc(holdTicks: 40, dive: true)
        XCTAssertEqual(tap.0, 0)
        XCTAssertFalse(tap.2.contains { $0.kind == .takeoff })
        XCTAssertGreaterThan(large.0, small.0 + 1)
        XCTAssertLessThan(dived.0, large.0)
        XCTAssertNotEqual(dived.1, large.1)
        XCTAssertTrue(large.2.contains { $0.kind == .perfectLanding })
        XCTAssertFalse(dived.2.contains { $0.kind == .perfectLanding })
        XCTAssertTrue(dived.2.contains { $0.kind == .landing && $0.intensity == 1 })
        XCTAssertGreaterThan(large.1.score, dived.1.score)
        XCTAssertGreaterThan(large.1.speed, dived.1.speed)
    }

    func testIntentionalAuthoredTraceFinishesAndEarnsExecutionRewards() throws {
        let course = try XCTUnwrap(SurfCatalog.course(id: "neon-dawn")).compiled()
        let played = try run(course, input: intentional)
        let mistimed = try run(course) { _ in true }
        let idle = try run(course) { _ in false }
        XCTAssertEqual(played.0.phase, .finished)
        XCTAssertGreaterThan(played.0.rings, 3)
        XCTAssertGreaterThan(played.0.perfectLandings, 3)
        XCTAssertGreaterThan(played.0.score, 1_200)
        XCTAssertTrue(played.2.contains { $0.kind == .ring })
        XCTAssertTrue(played.2.contains { $0.kind == .perfectLanding })
        XCTAssertGreaterThan(played.0.score, mistimed.0.score)
        XCTAssertGreaterThan(played.0.score, idle.0.score)
        XCTAssertEqual(mistimed.0.score, 0)
        XCTAssertEqual(idle.0.score, 0)
        XCTAssertNotEqual(mistimed.0.phase, .finished)
        XCTAssertNotEqual(SurfSimulation.result(state: idle.0, course: course).medal, .gold)
    }

    func testIdleAndPermanentHoldNeverEarnPassiveAuthoredScore() throws {
        for definition in SurfCatalog.all {
            let course = try SurfCourseCompiler.compile(definition)
            for pressed in [false, true] {
                let played = try run(course) { _ in pressed }
                XCTAssertEqual(played.0.score, 0, definition.id)
                XCTAssertEqual(played.0.rings, 0, definition.id)
                XCTAssertEqual(played.0.perfectLandings, 0, definition.id)
                XCTAssertEqual(SurfSimulation.result(state: played.0, course: course).medal, .none)
            }
        }
    }

    func testPrismBreakCreatesASeparateOptInMasteryRoute() throws {
        let definition = try XCTUnwrap(SurfCatalog.course(id: "prism-break"))
        XCTAssertFalse(SurfCatalog.all.contains { $0.id == definition.id })
        XCTAssertEqual(SurfCatalog.featured.last, definition)
        let course = try definition.compiled()
        let lowRings = definition.encounters.filter { $0.kind == .ring && $0.height < 2 }
        XCTAssertEqual(lowRings.count, 6)
        XCTAssertTrue(lowRings.allSatisfy { $0.height - $0.halfHeight > 0.5 })
        XCTAssertLessThan(lowRings.last!.halfHeight, lowRings.first!.halfHeight)
        for pressed in [false, true] {
            let idle = try run(course) { _ in pressed }
            XCTAssertEqual(idle.0.score, 0)
            XCTAssertNotEqual(idle.0.phase, .finished)
        }
        let spam = try run(course) { $0.tick % 30 < 12 }
        XCTAssertLessThan(spam.0.score, definition.medalScores[0])
        XCTAssertNotEqual(spam.0.phase, .finished)
    }

    func testPrismBreakMasterTraceCollectsBothBandsAndReplays() throws {
        let course = try XCTUnwrap(SurfCatalog.course(id: "prism-break")).compiled()
        let beds: [Double] = [40, 174, 296, 448, 566, 692, 840, 953, 1074]
        let roofs: [Double] = [74, 74, 74, 74, 74, 74, 68, 71, 67]
        // Recorded windows from the independent design model; the test runs the Swift physics.
        let windows: [[Double]] = [[0,17,0,0],[-4,29,0,0],[8,17,0,0],[16,32,6,4],
                                   [16,32,6,8],[16,32,12,8],[0,26,6,0],[0,32,6,8],[12,32,12,4]]
        let played = try run(course) { state in
            guard let i = beds.lastIndex(where: { state.distance >= $0 - 8 }) else { return false }
            let x = state.distance - beds[i], w = windows[i]
            if state.grounded { return x >= w[0] && x < w[1] }
            return i >= 3 && x >= roofs[i] - w[2] && x < roofs[i] - w[3] && state.verticalSpeed > -22
        }
        XCTAssertEqual(played.0.phase, .finished)
        XCTAssertGreaterThanOrEqual(played.0.rings, 10) // only nine high rings exist
        XCTAssertGreaterThanOrEqual(played.0.shields, 2)
        XCTAssertEqual(SurfSimulation.result(state: played.0, course: course).medal, .gold)
        let replay = SurfReplay(courseID: course.definition.id, seed: course.definition.seed,
                                rulesVersion: SurfRules.standard.version, inputs: played.1, finalState: played.0)
        XCTAssertEqual(try SurfSimulation.verify(replay: replay, course: course), played.0)
    }

    func testSweepsEveryEncounterAtMaximumSpeedInOrderAndDoesNotRepeat() throws {
        let course = try flat([
            SurfEncounter(id: 0, kind: .ring, distance: 1, height: 1.5, halfHeight: 0.1),
            SurfEncounter(id: 1, kind: .barrier, distance: 2, height: 1.2, halfHeight: 0.4),
            SurfEncounter(id: 2, kind: .ceiling, distance: 3, height: 2, halfHeight: 0.4)
        ])
        let rules = SurfRules(tickRate: 30, startingSpeed: 120, minimumSpeed: 120, maximumSpeed: 120)
        var state = SurfSimulation.start(course: course, rules: rules)
        state.grounded = false; state.height = 1; state.airtimeTicks = 10
        let first = try SurfSimulation.step(state: state, input: SurfInput(tick: 0, pressed: false), course: course, rules: rules)
        XCTAssertEqual(first.state.encounterCursor, 3)
        XCTAssertEqual(first.state.rings, 1)
        XCTAssertEqual(first.state.shields, 2)
        XCTAssertEqual(first.events.map(\.kind), [.ring, .comboLost, .hit])
        let next = try SurfSimulation.step(state: first.state, input: SurfInput(tick: 1, pressed: false), course: course, rules: rules)
        XCTAssertEqual(next.state.rings, 1)
        XCTAssertEqual(next.state.shields, 2)
        XCTAssertFalse(next.events.contains { [.ring, .hit].contains($0.kind) })
        let roof = try flat([SurfEncounter(id: 0, kind: .ceiling, distance: 2, height: 2, halfHeight: 0.4)])
        let ceiling = try SurfSimulation.step(state: state, input: SurfInput(tick: 0, pressed: false), course: roof, rules: rules)
        XCTAssertEqual(ceiling.state.shields, 2)
    }

    func testCrossingInterpolatesHeightInsteadOfUsingEndHeight() throws {
        let course = try flat([SurfEncounter(id: 0, kind: .ring, distance: 0.5, height: 1.53, halfHeight: 0.05)])
        let rules = SurfRules(tickRate: 30, startingSpeed: 120, minimumSpeed: 120, maximumSpeed: 120)
        var state = SurfSimulation.start(course: course, rules: rules)
        state.height = 1; state.verticalSpeed = 8; state.grounded = false
        let next = try SurfSimulation.step(state: state, input: SurfInput(tick: 0, pressed: false), course: course, rules: rules)
        XCTAssertGreaterThan(next.state.height, 1.2)
        XCTAssertEqual(next.state.rings, 1, "Ring is at the early crossing height, far below endpoint target")
    }

    func testInvulnerabilityExpiresAndThreeSeparatedHitsCrash() throws {
        let course = try flat([10.0, 40, 70].enumerated().map {
            SurfEncounter(id: $0.offset, kind: .barrier, distance: $0.element, height: 0.6, halfHeight: 0.5)
        }, length: 100)
        let played = try run(course) { _ in false }
        XCTAssertEqual(played.0.phase, .crashed)
        XCTAssertEqual(played.0.shields, 0)
        XCTAssertEqual(played.2.filter { $0.kind == .hit }.count, 3)
        XCTAssertFalse(played.2.contains { $0.kind == .finish })
        let stable = try SurfSimulation.step(state: played.0, input: SurfInput(tick: played.0.tick, pressed: true), course: course)
        XCTAssertEqual(stable.state, played.0)
        XCTAssertTrue(stable.events.isEmpty)
    }

    func testFinishAndTimeoutAreStableButRejectMalformedTerminalInput() throws {
        let course = try flat(length: 10)
        let finish = try run(course) { _ in false }
        XCTAssertEqual(finish.0.phase, .finished)
        XCTAssertEqual(finish.2.filter { $0.kind == .finish }.count, 1)
        let stable = try SurfSimulation.step(state: finish.0, input: SurfInput(tick: finish.0.tick, pressed: false), course: course)
        XCTAssertEqual(stable.state, finish.0)
        XCTAssertTrue(stable.events.isEmpty)
        XCTAssertThrowsError(try SurfSimulation.step(state: finish.0, input: SurfInput(tick: -1, pressed: false), course: course))
        XCTAssertThrowsError(try SurfSimulation.step(state: finish.0, input: SurfInput(tick: finish.0.tick, pressed: false), course: course, rules: SurfRules(tickRate: 0)))
        let short = SurfRules(maximumTicks: 1)
        let timeout = try run(course, rules: short) { _ in false }
        XCTAssertEqual(timeout.0.phase, .crashed)
        XCTAssertEqual(timeout.0.tick, 1)
        XCTAssertFalse(SurfSimulation.result(state: timeout.0, course: course, rules: short).completed)
    }

    func testSlopeChangesLaunchAndLandingAndPointsStayBounded() throws {
        func slope(_ rise: Double) throws -> CompiledSurfCourse {
            try SurfCourseCompiler.compile(SurfCourseDefinition(id: "incline", title: "Incline", subtitle: "Slope fixture",
                biome: .orbit, seed: 3,
                samples: [SurfCourseSample(distance: 0, center: SurfVector(x: 0, y: 0, z: 0)),
                          SurfCourseSample(distance: 300, center: SurfVector(x: 0, y: rise, z: -300))],
                encounters: [], medalScores: [1, 2, 3]))
        }
        func launch(_ course: CompiledSurfCourse) throws -> SurfState {
            var s = SurfSimulation.start(course: course)
            for _ in 0..<40 {
                s = try SurfSimulation.step(state: s, input: SurfInput(tick: s.tick, pressed: true), course: course).state
            }
            return try SurfSimulation.step(state: s, input: SurfInput(tick: s.tick, pressed: false), course: course).state
        }
        let up = try launch(slope(45))
        let down = try launch(slope(-45))
        XCTAssertNotEqual(up.verticalSpeed, down.verticalSpeed)
        XCTAssertNotEqual(up.speed, down.speed)

        let course = try flat([SurfEncounter(id: 0, kind: .ring, distance: 1, height: 1.5, halfHeight: 0.1)])
        var state = SurfSimulation.start(course: course)
        state.height = 1; state.grounded = false; state.score = 999_999_999
        state.combo = 10_000; state.bestCombo = 10_000
        var awarded = 0
        for _ in 0..<5 {
            let step = try SurfSimulation.step(state: state, input: SurfInput(tick: state.tick, pressed: false), course: course)
            awarded += step.events.filter { $0.kind == .ring }.reduce(0) { $0 + $1.value }
            state = step.state
        }
        XCTAssertEqual(state.score, 1_000_000_000)
        XCTAssertEqual(awarded, 1)
        XCTAssertEqual(state.combo, 10_000)
    }

    func testInvalidRulesStateTicksAndSanitizedResults() throws {
        let course = try flat()
        let invalidRules = [SurfRules(tickRate: 0), SurfRules(maximumTicks: Int.max),
                            SurfRules(startingSpeed: .nan), SurfRules(gravity: .infinity),
                            SurfRules(pressedGravity: 10), SurfRules(maximumCharge: 0)]
        for rules in invalidRules {
            let fallback = SurfSimulation.start(course: course, rules: rules)
            XCTAssertEqual(fallback.phase, .crashed)
            XCTAssertTrue(fallback.height.isFinite && fallback.speed.isFinite)
            XCTAssertThrowsError(try SurfSimulation.step(state: fallback, input: SurfInput(tick: 0, pressed: false), course: course, rules: rules))
            XCTAssertFalse(SurfSimulation.result(state: fallback, course: course, rules: rules).completed)
        }
        let initial = SurfSimulation.start(course: course)
        XCTAssertEqual(initial.tick, 0)
        XCTAssertThrowsError(try SurfSimulation.step(state: initial, input: SurfInput(tick: 1, pressed: false), course: course))
        var malformed: [SurfState] = []
        var s = initial; s.height = .nan; malformed.append(s)
        s = initial; s.speed = .infinity; malformed.append(s)
        s = initial; s.distance = -1; malformed.append(s)
        s = initial; s.tick = Int.max; malformed.append(s)
        s = initial; s.score = Int.max; malformed.append(s)
        s = initial; s.combo = Int.max; malformed.append(s)
        s = initial; s.encounterCursor = Int.max; malformed.append(s)
        s = initial; s.height = 2; malformed.append(s)
        s = initial; s.phase = .finished; malformed.append(s)
        s = initial; s.phase = .crashed; malformed.append(s)
        for bad in malformed {
            XCTAssertThrowsError(try SurfSimulation.step(state: bad, input: SurfInput(tick: bad.tick, pressed: false), course: course))
            let result = SurfSimulation.result(state: bad, course: course)
            XCTAssertTrue(result.seconds.isFinite)
            XCTAssertTrue((0...1_000_000_000).contains(result.score))
            XCTAssertFalse(result.completed)
        }
    }

    func testInvalidCourseBoundariesAreRejected() throws {
        func definition(samples: [SurfCourseSample], encounters: [SurfEncounter] = [], medals: [Int] = [1, 2, 3]) -> SurfCourseDefinition {
            SurfCourseDefinition(id: "invalid-fixture", title: "Fixture", subtitle: "Validation", biome: .dawn,
                                 seed: 1, samples: samples, encounters: encounters, medalScores: medals)
        }
        let a = SurfCourseSample(distance: 0, center: SurfVector(x: 0, y: 0, z: 0))
        let b = SurfCourseSample(distance: 100, center: SurfVector(x: 0, y: 0, z: -100))
        let invalidSamples: [[SurfCourseSample]] = [[], [a], [b, a], [a, a],
            [SurfCourseSample(distance: 1, center: a.center), b],
            [a, SurfCourseSample(distance: 100, center: SurfVector(x: 0, y: .nan, z: -100))],
            [a, SurfCourseSample(distance: 100, center: a.center)],
            [a, SurfCourseSample(distance: 100, center: SurfVector(x: 0, y: 100, z: -100))],
            [a, SurfCourseSample(distance: 100, center: b.center, width: 0)]]
        for samples in invalidSamples { XCTAssertThrowsError(try SurfCourseCompiler.compile(definition(samples: samples))) }
        let ring = SurfEncounter(id: 1, kind: .ring, distance: 20, height: 4, halfHeight: 1)
        for encounters in [[ring, ring], [ring, SurfEncounter(id: 2, kind: .ring, distance: 19, height: 1, halfHeight: 1)],
                           [SurfEncounter(id: 2, kind: .ring, distance: 101, height: 1, halfHeight: 1)],
                           [SurfEncounter(id: 2, kind: .ring, distance: .nan, height: 1, halfHeight: 1)],
                           [SurfEncounter(id: 2, kind: .ring, distance: 20, height: .infinity, halfHeight: 1)],
                           [SurfEncounter(id: 2, kind: .ring, distance: 20, height: 1, halfHeight: 0)],
                           [SurfEncounter(id: 2, kind: .ring, distance: 20, height: 1, halfHeight: 1, points: Int.max)]] {
            XCTAssertThrowsError(try SurfCourseCompiler.compile(definition(samples: [a, b], encounters: encounters)))
        }
        for medals in [[], [1, 2], [2, 1, 3], [1, 1, 3], [-1, 2, 3], [1, 2, Int.max]] {
            XCTAssertThrowsError(try SurfCourseCompiler.compile(definition(samples: [a, b], medals: medals)))
        }
    }

    func testExactReplayRejectsWrongIdentityAndTamperedFinalState() throws {
        let course = try XCTUnwrap(SurfCatalog.course(id: "neon-dawn")).compiled()
        let played = try run(course, input: intentional)
        func replay(id: String? = nil, seed: UInt64? = nil, version: String = SurfRules.standard.version,
                    final: SurfState? = nil, inputs: [SurfInput]? = nil) -> SurfReplay {
            SurfReplay(courseID: id ?? course.definition.id, seed: seed ?? course.definition.seed,
                       rulesVersion: version, inputs: inputs ?? played.1, finalState: final ?? played.0)
        }
        XCTAssertEqual(try SurfSimulation.verify(replay: replay(), course: course), played.0)
        XCTAssertThrowsError(try SurfSimulation.verify(replay: replay(id: "low-orbit"), course: course))
        XCTAssertThrowsError(try SurfSimulation.verify(replay: replay(seed: 999), course: course))
        XCTAssertThrowsError(try SurfSimulation.verify(replay: replay(version: "other"), course: course))
        var forged = played.0; forged.score += 1
        XCTAssertThrowsError(try SurfSimulation.verify(replay: replay(final: forged), course: course))
        let padded = played.1 + [SurfInput(tick: played.0.tick, pressed: false)]
        XCTAssertThrowsError(try SurfSimulation.verify(replay: replay(inputs: padded), course: course))
        XCTAssertThrowsError(try SurfSimulation.verify(replay: replay(), course: course, rules: SurfRules(tickRate: 0)))
    }


    func testAllAuthoredCoursesHaveIntentionalFinishTraces() throws {
        for definition in SurfCatalog.all {
            let course = try SurfCourseCompiler.compile(definition)
            var diveTicks = 0
            let played = try run(course) { state in
                guard state.distance >= 40 else { return false }
                let phrase = (state.distance - 40).truncatingRemainder(dividingBy: 120)
                if definition.biome != .midnight { return self.intentional(state) }
                if state.grounded { return phrase < 26 }
                let dive = phrase >= 54 && phrase < 60 && state.verticalSpeed > -10
                if dive { diveTicks += 1 }
                return dive
            }
            XCTAssertEqual(played.0.phase, .finished, definition.id)
            XCTAssertGreaterThan(played.0.shields, 0, definition.id)
            XCTAssertGreaterThan(played.0.rings, 3, definition.id)
            XCTAssertGreaterThan(played.0.perfectLandings, 3, definition.id)
            XCTAssertGreaterThan(played.0.score, definition.medalScores[0], definition.id)
            let result = SurfSimulation.result(state: played.0, course: course)
            XCTAssertTrue((60...90).contains(result.seconds), definition.id)
            if definition.biome == .midnight { XCTAssertGreaterThan(diveTicks, 0) }
        }
    }

    func testSweptCrossingsUseTheBallisticArcDuringADive() throws {
        // At t = 1/60, foot is 1.10556. Interpolating the tick endpoints yields
        // 1.07778 and incorrectly misses both this narrow ring and the ceiling.
        let course = try flat([
            SurfEncounter(id: 0, kind: .ring, distance: 2, height: 1.645, halfHeight: 0.05),
            SurfEncounter(id: 1, kind: .ceiling, distance: 2.1, height: 2.045, halfHeight: 0.05)
        ])
        let rules = SurfRules(tickRate: 30, startingSpeed: 120, minimumSpeed: 120,
                              maximumSpeed: 120, pressedGravity: 200)
        var state = SurfSimulation.start(course: course, rules: rules)
        state.height = 1; state.verticalSpeed = 8; state.grounded = false
        let step = try SurfSimulation.step(state: state, input: SurfInput(tick: 0, pressed: true),
                                           course: course, rules: rules)
        XCTAssertEqual(step.state.rings, 1)
        XCTAssertEqual(step.state.shields, 2)
        XCTAssertEqual(step.events.map(\.kind), [.ring, .comboLost, .hit])
    }

    func testFatalHitStopsRewardsAtLaterCrossedPlanes() throws {
        let course = try flat([
            SurfEncounter(id: 0, kind: .barrier, distance: 1, height: 0.5, halfHeight: 0.5),
            SurfEncounter(id: 1, kind: .ring, distance: 2, height: 0.5, halfHeight: 0.1),
            SurfEncounter(id: 2, kind: .boost, distance: 3, height: 0.5, halfHeight: 0.4)
        ])
        let rules = SurfRules(tickRate: 30, startingSpeed: 120, minimumSpeed: 120, maximumSpeed: 120)
        var state = SurfSimulation.start(course: course, rules: rules)
        state.shields = 1
        let step = try SurfSimulation.step(state: state, input: SurfInput(tick: 0, pressed: false),
                                           course: course, rules: rules)
        XCTAssertEqual(step.state.phase, .crashed)
        XCTAssertEqual(step.state.encounterCursor, 3)
        XCTAssertEqual(step.state.score, 0)
        XCTAssertEqual(step.state.rings, 0)
        XCTAssertEqual(step.events.map(\.kind), [.hit])
        let terminal = try SurfSimulation.step(state: step.state,
            input: SurfInput(tick: step.state.tick, pressed: false), course: course, rules: rules)
        XCTAssertEqual(terminal.state, step.state)
        XCTAssertTrue(terminal.events.isEmpty)
    }

    func testDailyIsReproducibleValidAndHasSafeGregorianFallback() throws {
        let first = SurfCatalog.daily(day: "2026-11-25")
        XCTAssertEqual(first, SurfCatalog.daily(day: "2026-11-25"))
        XCTAssertNotEqual(first.seed, SurfCatalog.daily(day: "2026-11-26").seed)
        XCTAssertEqual(first.source, .daily)
        for date in ["2026-11-25", "2024-02-29", "2000-02-29", "2026-12-31", "0001-01-01"] {
            XCTAssertNoThrow(try SurfCourseCompiler.compile(SurfCatalog.daily(day: date)))
        }
        for date in ["", "bad", "2026-02-29", "1900-02-29", "2026-04-31", "2026-13-01", "0000-01-01", "２０２６-11-25"] {
            XCTAssertEqual(SurfCatalog.daily(day: date), SurfCatalog.daily(day: "2000-01-01"))
        }
    }
}

private extension SurfCourseDefinition {
    func compiled() throws -> CompiledSurfCourse { try SurfCourseCompiler.compile(self) }
}
