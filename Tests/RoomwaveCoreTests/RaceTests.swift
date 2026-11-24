import Foundation
import XCTest
@testable import RoomwaveCore

final class RaceTests: XCTestCase {
    // Invented finalized synthetic circuit, with 45-degree turns and a first
    // straight of exactly 20 units. No capture samples or device claims.
    private func rules(tickRate: Int = 2, duration: Int = 100, initial: Double = 4,
                       maximum: Double = 4, acceleration: Double = 0, steering: Double = 3,
                       bankFactor: Double = 0.5, gain: Double = 0.5) -> RaceRules {
        RaceRules(version: "roomwave-rules-1", tickRate: tickRate, durationTicks: duration,
                  initialSpeed: initial, maximumSpeed: maximum, acceleration: acceleration,
                  steeringSpeed: steering, bankSpeedFactor: bankFactor, multiplierGain: gain)
    }

    private func track(_ rules: RaceRules? = nil, gates: Set<Int> = [1], narrowGate: Bool = false) -> TrackDefinition {
        let coordinates: [(Double, Double)] = [
            (0, 0), (20, 0), (30, 10), (30, 30),
            (20, 40), (0, 40), (-10, 30), (-10, 10)
        ]
        return TrackDefinition(schemaVersion: 1, generatorVersion: "synthetic-race-test-1",
            source: .synthetic, seed: 0, rules: rules ?? self.rules(),
            points: coordinates.enumerated().map { index, pair in
                TrackPoint(position: Vector3(x: pair.0, y: 0, z: pair.1),
                           halfWidth: narrowGate && index == 1 ? 0.75 : 2,
                           isGate: gates.contains(index))
            })
    }

    private func changed(_ state: RaceState, tick: Int? = nil, distance: Double? = nil,
                         lateral: Double? = nil, speed: Double? = nil, banked: Double? = nil,
                         chain: Double? = nil, multiplier: Double? = nil,
                         status: RaceStatus? = nil) -> RaceState {
        RaceState(tick: tick ?? state.tick, distance: distance ?? state.distance,
                  lateralOffset: lateral ?? state.lateralOffset, speed: speed ?? state.speed,
                  bankedScore: banked ?? state.bankedScore, unbankedScore: chain ?? state.unbankedScore,
                  multiplier: multiplier ?? state.multiplier, status: status ?? state.status)
    }

    private func assertInvalid(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case RoomwaveError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)", file: file, line: line)
            }
        }
    }

    func testFixedTimingAccelerationAndSpeedCap() throws {
        let circuit = track(rules(maximum: 6, acceleration: 2))
        var state = try RaceSimulation.initialState(rules: circuit.rules)
        state = try RaceSimulation.step(state: state, input: RaceInput(tick: 1, steering: 0, bank: false), track: circuit)
        XCTAssertEqual(state.speed, 5)
        XCTAssertEqual(state.distance, 2.5)
        state = try RaceSimulation.step(state: state, input: RaceInput(tick: 2, steering: 0, bank: false), track: circuit)
        XCTAssertEqual(state.speed, 6)
        XCTAssertEqual(state.distance, 5.5)
        state = try RaceSimulation.step(state: state, input: RaceInput(tick: 3, steering: 0, bank: false), track: circuit)
        XCTAssertEqual(state.speed, 6)
        XCTAssertEqual(state.distance, 8.5)
    }

    func testRepeatedInputsAreDeterministicAndWidthEqualityIsAllowed() throws {
        let circuit = track(rules(steering: 4))
        let inputs = [RaceInput(tick: 1, steering: -1, bank: false),
                      RaceInput(tick: 2, steering: 1, bank: false)]
        var first = try RaceSimulation.initialState(rules: circuit.rules)
        var second = first
        for input in inputs {
            first = try RaceSimulation.step(state: first, input: input, track: circuit)
            second = try RaceSimulation.step(state: second, input: input, track: circuit)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.status, .running)
        }
        XCTAssertEqual(first.lateralOffset, 0)
    }

    func testOffGateBankIsIgnoredAndNotQueued() throws {
        let circuit = track()
        var state = try RaceSimulation.initialState(rules: circuit.rules)
        for tick in 1...10 {
            state = try RaceSimulation.step(state: state,
                input: RaceInput(tick: tick, steering: 0, bank: tick == 1), track: circuit)
            XCTAssertEqual(state.bankedScore, 0)
        }
        XCTAssertEqual(state.distance, 20)
        XCTAssertEqual(state.unbankedScore, 20)
        XCTAssertEqual(state.multiplier, 1.5)
    }

    func testGateBankVersusContinueSplitsScoreAndSlowsNextTick() throws {
        let circuit = track(rules(maximum: 8, acceleration: 2, bankFactor: 0.1))
        var bank = try RaceSimulation.initialState(rules: circuit.rules)
        var risk = bank
        for tick in 1...6 {
            bank = try RaceSimulation.step(state: bank,
                input: RaceInput(tick: tick, steering: 0, bank: tick == 6), track: circuit)
            risk = try RaceSimulation.step(state: risk,
                input: RaceInput(tick: tick, steering: 0, bank: false), track: circuit)
        }
        XCTAssertEqual(bank.distance, 21)
        XCTAssertEqual(bank.bankedScore, 20)
        XCTAssertEqual(bank.unbankedScore, 1)
        XCTAssertEqual(bank.multiplier, 1)
        XCTAssertEqual(bank.speed, 4)
        XCTAssertEqual(risk.distance, 21)
        XCTAssertEqual(risk.unbankedScore, 21.5)
        XCTAssertEqual(risk.multiplier, 1.5)
        XCTAssertEqual(risk.speed, 8)
        let next = try RaceSimulation.step(state: bank,
            input: RaceInput(tick: 7, steering: 0, bank: false), track: circuit)
        XCTAssertEqual(next.distance, 23.5)
    }

    func testBankRequestAppliesOnlyAtFirstGateInTick() throws {
        let circuit = track(rules(tickRate: 1, maximum: 100, acceleration: 96), gates: [1, 2])
        let state = try RaceSimulation.step(state: RaceSimulation.initialState(rules: circuit.rules),
            input: RaceInput(tick: 1, steering: 0, bank: true), track: circuit)
        XCTAssertEqual(state.distance, 100)
        XCTAssertEqual(state.bankedScore, 20)
        XCTAssertEqual(state.speed, 50)
        XCTAssertEqual(state.multiplier, 1.5)
    }

    func testImplicitClosingSegmentAndDistanceBeyondOneLap() throws {
        let circuit = track(gates: [0])
        var state = try RaceSimulation.initialState(rules: circuit.rules)
        for tick in 1...80 {
            state = try RaceSimulation.step(state: state,
                input: RaceInput(tick: tick, steering: 0, bank: false), track: circuit)
        }
        let lap = 80 + 4 * sqrt(200.0)
        XCTAssertEqual(state.distance, 160, accuracy: 1e-10)
        XCTAssertGreaterThan(state.distance, lap)
        XCTAssertEqual(state.multiplier, 1.5)
        XCTAssertEqual(state.unbankedScore, lap + (160 - lap) * 1.5, accuracy: 1e-9)
    }

    func testNarrowingCrashesBeforeBankEvenWhenTickEndpointWouldFit() throws {
        let circuit = track(rules(tickRate: 1, duration: 1, maximum: 44, acceleration: 40, steering: 2), narrowGate: true)
        let state = try RaceSimulation.step(state: RaceSimulation.initialState(rules: circuit.rules),
            input: RaceInput(tick: 1, steering: 1, bank: true), track: circuit)
        XCTAssertEqual(state.status, .crashed)
        XCTAssertEqual(state.distance, 20)
        XCTAssertGreaterThan(state.lateralOffset, 0.75)
        XCTAssertEqual(state.bankedScore, 0)
        XCTAssertEqual(state.unbankedScore, 0)
        XCTAssertEqual(state.multiplier, 1)
        assertInvalid {
            _ = try RaceSimulation.step(state: state,
                input: RaceInput(tick: 2, steering: 0, bank: false), track: circuit)
        }
    }

    func testCrashKeepsEarlierBankAndDiscardsChain() throws {
        let circuit = track(rules(maximum: 8, acceleration: 2))
        var state = try RaceSimulation.initialState(rules: circuit.rules)
        for tick in 1...8 {
            state = try RaceSimulation.step(state: state,
                input: RaceInput(tick: tick, steering: tick >= 7 ? 1 : 0, bank: tick == 6), track: circuit)
        }
        XCTAssertEqual(state.status, .crashed)
        XCTAssertEqual(state.bankedScore, 20)
        XCTAssertEqual(state.unbankedScore, 0)
    }

    func testSuccessfulTimeLimitBanksRemainingChainAndRejectsFurtherTicks() throws {
        let circuit = track(rules(duration: 3))
        var state = try RaceSimulation.initialState(rules: circuit.rules)
        for tick in 1...3 {
            state = try RaceSimulation.step(state: state,
                input: RaceInput(tick: tick, steering: 0, bank: false), track: circuit)
        }
        XCTAssertEqual(state.status, .finished)
        XCTAssertEqual(state.tick, 3)
        XCTAssertEqual(state.bankedScore, 6)
        XCTAssertEqual(state.unbankedScore, 0)
        XCTAssertEqual(state.multiplier, 1)
        assertInvalid {
            _ = try RaceSimulation.step(state: state,
                input: RaceInput(tick: 4, steering: 0, bank: false), track: circuit)
        }
    }

    func testInvalidRulesInputsAndStatesAreExplicitErrors() throws {
        let invalidRules = [rules(tickRate: 0), rules(duration: 0), rules(initial: .nan),
            rules(maximum: 3), rules(acceleration: -1), rules(steering: .infinity),
            rules(bankFactor: 0), rules(bankFactor: 1.1), rules(gain: -1)]
        for rule in invalidRules { assertInvalid { _ = try RaceSimulation.initialState(rules: rule) } }
        let circuit = track()
        let initial = try RaceSimulation.initialState(rules: circuit.rules)
        for input in [RaceInput(tick: 0, steering: 0, bank: false),
                      RaceInput(tick: 2, steering: 0, bank: false),
                      RaceInput(tick: 1, steering: .nan, bank: false),
                      RaceInput(tick: 1, steering: .infinity, bank: false),
                      RaceInput(tick: 1, steering: 1.01, bank: false),
                      RaceInput(tick: 1, steering: -1.01, bank: false)] {
            assertInvalid { _ = try RaceSimulation.step(state: initial, input: input, track: circuit) }
        }
        let invalidStates = [changed(initial, tick: -1), changed(initial, distance: .nan),
            changed(initial, distance: -1), changed(initial, lateral: .infinity),
            changed(initial, speed: 5), changed(initial, speed: 0),
            changed(initial, banked: -1), changed(initial, chain: .infinity),
            changed(initial, multiplier: 0), changed(initial, tick: 100),
            changed(initial, tick: 1, status: .finished), changed(initial, distance: 1),
            changed(initial, tick: 1, lateral: 3),
            changed(initial, tick: 1, distance: .greatestFiniteMagnitude)]
        for state in invalidStates {
            assertInvalid {
                _ = try RaceSimulation.step(state: state,
                    input: RaceInput(tick: state.tick + 1, steering: 0, bank: false), track: circuit)
            }
        }
    }

    func testInvalidTrackIsRejected() throws {
        let valid = track()
        let empty = TrackDefinition(schemaVersion: valid.schemaVersion, generatorVersion: valid.generatorVersion,
            source: .synthetic, seed: valid.seed, rules: valid.rules, points: [])
        XCTAssertThrowsError(try RaceSimulation.step(state: RaceSimulation.initialState(rules: empty.rules),
            input: RaceInput(tick: 1, steering: 0, bank: false), track: empty)) { error in
            guard case RoomwaveError.invalidTrack = error else { return XCTFail("Expected invalidTrack") }
        }
    }

    #if canImport(CryptoKit)
    private func replacing(_ record: ReplayRecord, schema: Int? = nil, trackID: String? = nil,
                           inputs: [RaceInput]? = nil, keyframes: [RaceState]? = nil,
                           final: RaceState? = nil) -> ReplayRecord {
        ReplayRecord(schemaVersion: schema ?? record.schemaVersion, trackID: trackID ?? record.trackID,
            inputs: inputs ?? record.inputs, keyframes: keyframes ?? record.keyframes,
            finalState: final ?? record.finalState)
    }

    private func assertMismatch(_ record: ReplayRecord, track: TrackDefinition,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ReplayEngine.replay(record, track: track), file: file, line: line) { error in
            guard case RoomwaveError.replayMismatch = error else {
                return XCTFail("Expected replayMismatch, got \(error)", file: file, line: line)
            }
        }
    }

    func testReplayRoundTripUsesActualPeriodicStatesAndPreservesSyntheticBoundary() throws {
        let circuit = track(rules(duration: 5))
        let inputs = (1...5).map { RaceInput(tick: $0, steering: $0 == 1 ? 0.1 : 0, bank: false) }
        let record = try ReplayEngine.record(inputs: inputs, track: circuit)
        XCTAssertEqual(record.inputs, inputs)
        XCTAssertEqual(record.keyframes.map { $0.tick }, [0, 2, 4, 5])
        XCTAssertEqual(try ReplayEngine.replay(record, track: circuit), record.finalState)
        XCTAssertEqual(record.finalState.status, .finished)
        XCTAssertEqual(circuit.source, .synthetic)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set(["schemaVersion", "trackID", "inputs", "keyframes", "finalState"]))
    }

    func testReplayRejectsChangedInputsKeyframesFinalStateSchemaAndIdentity() throws {
        let circuit = track(rules(duration: 5))
        let inputs = (1...5).map { RaceInput(tick: $0, steering: 0, bank: false) }
        let record = try ReplayEngine.record(inputs: inputs, track: circuit)
        assertMismatch(replacing(record, schema: 2), track: circuit)
        assertMismatch(replacing(record, trackID: "different-content"), track: circuit)
        var changedInputs = inputs
        changedInputs[0] = RaceInput(tick: 1, steering: 0.1, bank: false)
        assertMismatch(replacing(record, inputs: changedInputs), track: circuit)
        assertMismatch(replacing(record, keyframes: Array(record.keyframes.dropFirst())), track: circuit)
        assertMismatch(replacing(record, keyframes: Array(record.keyframes.reversed())), track: circuit)
        assertMismatch(replacing(record, final: changed(record.finalState, banked: 999)), track: circuit)
        assertMismatch(record, track: track(rules(duration: 5, gain: 0.75)))
        var points = circuit.points
        let first = points[0]
        points[0] = TrackPoint(position: Vector3(x: 1, y: 0, z: 0), halfWidth: first.halfWidth, isGate: first.isGate)
        let altered = TrackDefinition(schemaVersion: circuit.schemaVersion, generatorVersion: circuit.generatorVersion,
            source: .synthetic, seed: circuit.seed, rules: circuit.rules, points: points)
        assertMismatch(record, track: altered)
    }

    func testPartialEmptyAndCrashReplaysAndInvalidSequences() throws {
        let circuit = track()
        let empty = try ReplayEngine.record(inputs: [], track: circuit)
        XCTAssertEqual(empty.keyframes.count, 1)
        XCTAssertEqual(try ReplayEngine.replay(empty, track: circuit).tick, 0)
        let crashInputs = (1...2).map { RaceInput(tick: $0, steering: 1, bank: false) }
        let crash = try ReplayEngine.record(inputs: crashInputs, track: circuit)
        XCTAssertEqual(try ReplayEngine.replay(crash, track: circuit).status, .crashed)
        assertInvalid {
            _ = try ReplayEngine.record(inputs: crashInputs + [RaceInput(tick: 3, steering: 0, bank: false)], track: circuit)
        }
        assertInvalid {
            _ = try ReplayEngine.record(inputs: [RaceInput(tick: 2, steering: 0, bank: false)], track: circuit)
        }
    }
    #else
    func testReplayPropagatesUnsupportedIdentityWithoutFallbackHash() throws {
        let circuit = track()
        XCTAssertThrowsError(try ReplayEngine.record(inputs: [], track: circuit)) { error in
            guard case RoomwaveError.unsupportedPlatform = error else {
                return XCTFail("Expected unsupportedPlatform, got \(error)")
            }
        }
        let state = try RaceSimulation.initialState(rules: circuit.rules)
        let record = ReplayRecord(schemaVersion: 1, trackID: "untrusted", inputs: [], keyframes: [state], finalState: state)
        XCTAssertThrowsError(try ReplayEngine.replay(record, track: circuit)) { error in
            guard case RoomwaveError.unsupportedPlatform = error else {
                return XCTFail("Expected unsupportedPlatform, got \(error)")
            }
        }
    }
    #endif
}
