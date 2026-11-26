import Foundation
import XCTest
@testable import RoomwaveArcade

final class SurfCancellationTests: XCTestCase {
    func testRecordedInterruptionCancelsLaunchAndReplaysExactly() throws {
        let definition = try XCTUnwrap(SurfCatalog.course(id: "neon-dawn"))
        let course = try SurfCourseCompiler.compile(definition)
        var state = SurfSimulation.start(course: course)
        var inputs: [SurfInput] = []
        for _ in 0..<50 {
            let input = SurfInput(tick: state.tick, pressed: true)
            inputs.append(input)
            state = try SurfSimulation.step(state: state, input: input, course: course).state
        }
        XCTAssertTrue(state.grounded)
        XCTAssertGreaterThan(state.charge, 0.5)
        let interrupted = SurfInput(tick: state.tick, pressed: false, cancelled: true)
        inputs.append(interrupted)
        let resumed = try SurfSimulation.step(state: state, input: interrupted, course: course)
        XCTAssertTrue(resumed.state.grounded)
        XCTAssertEqual(resumed.state.charge, 0)
        XCTAssertFalse(resumed.events.contains { $0.kind == .takeoff })
        let ordinaryRelease = try SurfSimulation.step(state: state,
            input: SurfInput(tick: state.tick, pressed: false), course: course)
        XCTAssertFalse(ordinaryRelease.state.grounded)
        let replay = SurfReplay(courseID: definition.id, seed: definition.seed,
            rulesVersion: SurfRules.standard.version, inputs: inputs, finalState: resumed.state)
        let roundTrip = try JSONDecoder().decode(SurfReplay.self, from: JSONEncoder().encode(replay))
        XCTAssertEqual(try SurfSimulation.verify(replay: roundTrip, course: course), resumed.state)
    }
}
