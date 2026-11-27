import XCTest
@testable import RoomwaveArcade

final class SurfAfterglowTests: XCTestCase {
    func testOptInCisternHasAnUnassistedSafeLineAndIndependentIdentity() throws {
        let course = try SurfCourseCompiler.compile(SurfAfterglow.course)
        XCTAssertEqual(SurfCatalog.course(id: SurfAfterglow.id), SurfAfterglow.course)
        XCTAssertEqual(SurfCatalog.all.count, 3)
        XCTAssertFalse(SurfCatalog.all.contains { $0.id == SurfAfterglow.id })
        XCTAssertEqual(SurfCatalog.featured.last?.id, "prism-break")
        var s = SurfSimulation.start(course: course)
        var finale = SurfAfterglow.Finale()
        while s.phase == .running {
            let step = try SurfSimulation.step(state: s, input: SurfInput(tick: s.tick, pressed: false), course: course)
            XCTAssertFalse(finale.observe(courseID: SurfAfterglow.id, previous: s, step: step))
            s = step.state
        }
        XCTAssertEqual(s.phase, .finished)
        XCTAssertEqual(s.shields, 3)
        XCTAssertGreaterThan(Double(s.tick) / 60, 26)
        XCTAssertLessThan(Double(s.tick) / 60, 40)
        XCTAssertEqual(s.rings, 0)
        XCTAssertFalse(finale.caughtCrown)
    }

    func testTimedJumpEarnsCrownAndFinishesExactlyOnce() throws {
        let course = try SurfCourseCompiler.compile(SurfAfterglow.course)
        var state = SurfSimulation.start(course: course)
        var finale = SurfAfterglow.Finale()
        var celebrations = 0
        while state.phase == .running {
            let pressed = (508.0..<524.0).contains(state.distance)
            let input = SurfInput(tick: state.tick, pressed: pressed)
            let step = try SurfSimulation.step(state: state, input: input, course: course)
            if finale.observe(courseID: SurfAfterglow.id, previous: state, step: step) {
                celebrations += 1
            }
            state = step.state
        }
        XCTAssertEqual(state.phase, .finished)
        XCTAssertEqual(state.shields, 3)
        XCTAssertEqual(state.rings, 1)
        XCTAssertEqual(state.perfectLandings, 1)
        XCTAssertGreaterThanOrEqual(state.score, 490)
        XCTAssertEqual(celebrations, 1)
        XCTAssertTrue(finale.earned)
    }

    func testCrownCelebrationOnlyOnLiveCrossingFollowedByCleanLanding() {
        let d = SurfAfterglow.finalRingDistance
        func s(_ distance: Double) -> SurfState { SurfState(distance: distance) }
        let ring = SurfStep(state: s(d + 0.1), events: [.init(tick: 1, kind: .ring)])
        let clean = SurfStep(state: s(d + 20), events: [.init(tick: 2, kind: .landing), .init(tick: 2, kind: .perfectLanding)])
        let rough = SurfStep(state: s(d + 20), events: [.init(tick: 2, kind: .landing)])
        var finale = SurfAfterglow.Finale()
        XCTAssertFalse(finale.observe(courseID: "prism-break", previous: s(d - 0.2), step: ring))
        XCTAssertFalse(finale.observe(courseID: SurfAfterglow.id, previous: s(d + 0.1), step: clean))
        XCTAssertFalse(finale.observe(courseID: SurfAfterglow.id, previous: s(d - 0.2), step: ring))
        XCTAssertFalse(finale.observe(courseID: SurfAfterglow.id, previous: s(d + 0.1), step: rough))
        XCTAssertTrue(finale.caughtCrown)
        XCTAssertFalse(finale.earned)
        XCTAssertFalse(finale.observe(courseID: SurfAfterglow.id, previous: s(d + 20), step: clean))
        XCTAssertFalse(finale.observe(courseID: SurfAfterglow.id, previous: s(d - 0.2), step: ring))
        XCTAssertTrue(finale.observe(courseID: SurfAfterglow.id, previous: s(d + 0.1), step: clean))
        XCTAssertTrue(finale.earned)
        XCTAssertFalse(finale.observe(courseID: SurfAfterglow.id, previous: s(d + 20), step: clean))
    }
}
