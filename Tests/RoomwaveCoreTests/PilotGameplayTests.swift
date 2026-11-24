import Foundation
import XCTest
@testable import RoomwaveCore

final class PilotGameplayTests: XCTestCase {
    private func challenge(seed: UInt64 = 42) throws -> TrackDefinition {
        let sample = ScanSample(captureID: "invented-pilot-fixture", source: .synthetic, points: [
            Vector3(x: -3, y: 0, z: -2), Vector3(x: 3, y: 0, z: -2),
            Vector3(x: 3, y: 1, z: 2), Vector3(x: -3, y: 1, z: 2)
        ])
        return try TrackGenerator.makeTrack(from: ScanNormalizer.normalize(sample), seed: seed)
    }

    private func replacingRules(_ track: TrackDefinition, version: String) -> TrackDefinition {
        let r = track.rules
        let rules = RaceRules(version: version, tickRate: r.tickRate, durationTicks: r.durationTicks,
            initialSpeed: r.initialSpeed, maximumSpeed: r.maximumSpeed, acceleration: r.acceleration,
            steeringSpeed: r.steeringSpeed, bankSpeedFactor: r.bankSpeedFactor, multiplierGain: r.multiplierGain)
        return TrackDefinition(schemaVersion: track.schemaVersion, generatorVersion: track.generatorVersion,
            source: track.source, seed: track.seed, rules: rules, points: track.points)
    }

    private func lengths(_ track: TrackDefinition) -> [Double] {
        track.points.indices.map { i in
            let a = track.points[i].position, b = track.points[(i + 1) % track.points.count].position
            return hypot(b.x - a.x, b.z - a.z)
        }
    }

    // A simple driver reacts only to observed offset, without reading curvature
    // or copying simulation equations. It must steer continuously to survive.
    private func correctingInput(_ state: RaceState, bank: Bool = false) -> RaceInput {
        RaceInput(tick: state.tick + 1, steering: max(-1, min(1, -4 * state.lateralOffset)), bank: bank)
    }

    func testGeneratedBendsDefeatIdleButCorrectionFinishesAndReplays() throws {
        let track = try challenge()
        XCTAssertTrue(TrackValidator.validate(track).isEmpty)
        XCTAssertEqual(track.rules.version, "roomwave-pilot-2")
        var idle = try RaceSimulation.initialState(rules: track.rules)
        while idle.status == .running {
            idle = try RaceSimulation.step(state: idle,
                input: RaceInput(tick: idle.tick + 1, steering: 0, bank: false), track: track)
        }
        XCTAssertEqual(idle.status, .crashed)
        XCTAssertLessThan(idle.tick, 600)
        XCTAssertEqual(idle.bankedScore, 0)
        XCTAssertEqual(idle.unbankedScore, 0)

        var corrected = try RaceSimulation.initialState(rules: track.rules)
        var inputs: [RaceInput] = []
        while corrected.status == .running {
            let input = correctingInput(corrected)
            inputs.append(input)
            corrected = try RaceSimulation.step(state: corrected, input: input, track: track)
            XCTAssertLessThan(abs(corrected.lateralOffset), 0.65)
        }
        XCTAssertEqual(corrected.status, .finished)
        XCTAssertEqual(corrected.tick, RaceRules.standard.durationTicks)
        XCTAssertGreaterThan(corrected.distance, 4 * lengths(track).reduce(0, +))
        XCTAssertEqual(corrected.speed, track.rules.maximumSpeed)
        XCTAssertGreaterThan(corrected.bankedScore, 0)
        XCTAssertEqual(corrected.unbankedScore, 0)
        XCTAssertTrue(inputs.contains { abs($0.steering) > 0.1 })

        #if canImport(CryptoKit) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        let record = try ReplayEngine.record(inputs: inputs, track: track)
        XCTAssertEqual(record.finalState, corrected)
        XCTAssertEqual(record.keyframes.first?.tick, 0)
        XCTAssertEqual(record.keyframes.last?.tick, corrected.tick)
        XCTAssertEqual(record.keyframes.count, 91)
        XCTAssertEqual(try ReplayEngine.replay(record, track: track), corrected)
        // Replaying the same geometry under neutral legacy semantics is a
        // different challenge identity, not an implicit rules migration.
        XCTAssertThrowsError(try ReplayEngine.replay(record,
            track: replacingRules(track, version: "roomwave-rules-1")))
        #else
        // Determinism still gets exercised where Apple identity is unavailable.
        var repeated = try RaceSimulation.initialState(rules: track.rules)
        for input in inputs { repeated = try RaceSimulation.step(state: repeated, input: input, track: track) }
        XCTAssertEqual(repeated, corrected)
        #endif
    }

    func testLegacyNeutralSteeringStaysNeutralAndUnknownRulesAreRejected() throws {
        let track = try challenge()
        let legacy = replacingRules(track, version: "roomwave-rules-1")
        var state = try RaceSimulation.initialState(rules: legacy.rules)
        for tick in 1...600 {
            state = try RaceSimulation.step(state: state,
                input: RaceInput(tick: tick, steering: 0, bank: false), track: legacy)
        }
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.lateralOffset, 0)
        let unknown = replacingRules(track, version: "roomwave-future-99")
        XCTAssertTrue(TrackValidator.validate(unknown).contains { $0.code == "rules" })
        XCTAssertThrowsError(try RaceSimulation.initialState(rules: unknown.rules)) { error in
            guard case RoomwaveError.invalidInput = error else { return XCTFail("Expected invalidInput") }
        }
    }

    func testPressureChangesSignWithTurnAndGrowsWithSpeedWithinSteeringAuthority() throws {
        let track = try challenge()
        let mirrored = TrackDefinition(schemaVersion: track.schemaVersion, generatorVersion: track.generatorVersion,
            source: track.source, seed: track.seed, rules: track.rules,
            points: track.points.map {
                TrackPoint(position: Vector3(x: -$0.position.x, y: 0, z: $0.position.z),
                           halfWidth: $0.halfWidth, isGate: $0.isGate)
            })
        func moving(speed: Double) -> RaceState {
            RaceState(tick: 1, distance: 0, lateralOffset: 0, speed: speed,
                bankedScore: 0, unbankedScore: 0, multiplier: 1, status: .running)
        }
        let neutral = RaceInput(tick: 2, steering: 0, bank: false)
        let slow = try RaceSimulation.step(state: moving(speed: 4), input: neutral, track: track)
        let fast = try RaceSimulation.step(state: moving(speed: 12), input: neutral, track: track)
        let reflected = try RaceSimulation.step(state: moving(speed: 4), input: neutral, track: mirrored)
        XCTAssertNotEqual(slow.lateralOffset, 0)
        XCTAssertGreaterThan(abs(fast.lateralOffset), abs(slow.lateralOffset))
        XCTAssertLessThanOrEqual(abs(fast.lateralOffset), 0.8 * 3 / 60 + 1e-12)
        XCTAssertEqual(slow.lateralOffset, -reflected.lateralOffset, accuracy: 1e-12)
        let correction = RaceInput(tick: 2, steering: slow.lateralOffset < 0 ? 1 : -1, bank: false)
        let steered = try RaceSimulation.step(state: moving(speed: 12), input: correction, track: track)
        XCTAssertLessThan(steered.lateralOffset * fast.lateralOffset, 0)
        let legacy = replacingRules(track, version: "roomwave-rules-1")
        let linear = try RaceSimulation.step(state: moving(speed: 4),
            input: RaceInput(tick: 2, steering: 0.25, bank: false), track: legacy)
        XCTAssertEqual(linear.lateralOffset, 0.25 * 3 / 60, accuracy: 1e-12)
    }

    func testClosingSeamPressureAndBankMatchSameSegmentInsideRotatedRoute() throws {
        let track = try challenge()
        let distances = lengths(track)
        let lap = distances.reduce(0, +)
        let rotated = TrackDefinition(schemaVersion: track.schemaVersion, generatorVersion: track.generatorVersion,
            source: track.source, seed: track.seed, rules: track.rules,
            points: [track.points.last!] + Array(track.points.dropLast()))
        XCTAssertTrue(TrackValidator.validate(rotated).isEmpty)
        func beforeGate(distance: Double) -> RaceState {
            RaceState(tick: 1, distance: distance, lateralOffset: 0, speed: track.rules.initialSpeed,
                bankedScore: 5, unbankedScore: 10, multiplier: 2, status: .running)
        }
        let input = RaceInput(tick: 2, steering: 0.2, bank: true)
        let seam = try RaceSimulation.step(state: beforeGate(distance: lap - 0.025), input: input, track: track)
        let interior = try RaceSimulation.step(state: beforeGate(distance: distances.last! - 0.025),
                                               input: input, track: rotated)
        XCTAssertEqual(seam.status, .running)
        XCTAssertEqual(seam.lateralOffset, interior.lateralOffset, accuracy: 1e-12)
        XCTAssertEqual(seam.bankedScore, 15.05, accuracy: 1e-10)
        XCTAssertEqual(seam.bankedScore, interior.bankedScore, accuracy: 1e-10)
        XCTAssertEqual(seam.unbankedScore, interior.unbankedScore, accuracy: 1e-10)
        XCTAssertEqual(seam.multiplier, 1)
        XCTAssertEqual(seam.speed, track.rules.initialSpeed)
        // The same input sequence remains deterministic while banking across
        // many laps, rather than using a separate bank-specific physics path.
        var first = try RaceSimulation.initialState(rules: track.rules)
        var second = first
        for _ in 0..<1200 {
            let input = correctingInput(first, bank: true)
            first = try RaceSimulation.step(state: first, input: input, track: track)
            second = try RaceSimulation.step(state: second, input: input, track: track)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.status, .running)
        }
        XCTAssertGreaterThan(first.bankedScore, 0)
    }

    func testPhotoHeightFeaturesAffectPlanarTurnsWithIdenticalBounds() throws {
        func scan(heightAlongX: Bool) -> NormalizedScan {
            var points: [Vector3] = []
            for row in 0...8 {
                for column in 0...8 {
                    let x = Double(column) / 4 - 1, z = Double(row) / 4 - 1
                    points.append(Vector3(x: x, y: heightAlongX ? x : z, z: z))
                }
            }
            return NormalizedScan(source: .photoDerived, normalizationVersion: 1, points: points)
        }
        let a = try TrackGenerator.makeTrack(from: scan(heightAlongX: true), seed: 7)
        let b = try TrackGenerator.makeTrack(from: scan(heightAlongX: false), seed: 7)
        XCTAssertEqual(a.source, .photoDerived)
        XCTAssertEqual(b.source, .photoDerived)
        XCTAssertTrue(TrackValidator.validate(a).isEmpty)
        XCTAssertTrue(TrackValidator.validate(b).isEmpty)
        XCTAssertNotEqual(a.points, b.points)
        func turns(_ track: TrackDefinition) -> [Double] {
            track.points.indices.map { i in
                let n = track.points.count
                let p = track.points[(i + n - 1) % n].position
                let q = track.points[i].position, r = track.points[(i + 1) % n].position
                return atan2((q.x - p.x) * (r.z - q.z) - (q.z - p.z) * (r.x - q.x),
                             (q.x - p.x) * (r.x - q.x) + (q.z - p.z) * (r.z - q.z))
            }
        }
        XCTAssertGreaterThan(zip(turns(a), turns(b)).map { abs($0.0 - $0.1) }.max() ?? 0, 0.001)
        XCTAssertEqual(Set(a.points.map(\.halfWidth)), Set([0.65]))
        XCTAssertTrue(a.points.allSatisfy { $0.position.y == 0 })
    }

    func testPilotChecksNarrowingBeforeBankAndRejectsTerminalTick() throws {
        let original = try challenge()
        var points = original.points
        points[0] = TrackPoint(position: points[0].position, halfWidth: 0.25, isGate: true)
        let track = TrackDefinition(schemaVersion: original.schemaVersion, generatorVersion: original.generatorVersion,
            source: original.source, seed: original.seed, rules: original.rules, points: points)
        XCTAssertTrue(TrackValidator.validate(track).isEmpty)
        let lap = lengths(track).reduce(0, +)
        let before = RaceState(tick: 1, distance: lap - 0.025, lateralOffset: 0.249, speed: 4,
            bankedScore: 5, unbankedScore: 10, multiplier: 2, status: .running)
        let crash = try RaceSimulation.step(state: before,
            input: RaceInput(tick: 2, steering: 1, bank: true), track: track)
        XCTAssertEqual(crash.status, .crashed)
        XCTAssertEqual(crash.distance, lap, accuracy: 1e-10)
        XCTAssertGreaterThan(crash.lateralOffset, 0.25)
        XCTAssertEqual(crash.bankedScore, 5)
        XCTAssertEqual(crash.unbankedScore, 0)
        XCTAssertEqual(crash.multiplier, 1)
        XCTAssertThrowsError(try RaceSimulation.step(state: crash,
            input: RaceInput(tick: 3, steering: 0, bank: false), track: track))
    }

    func testSectorContourAdmissionAcrossSparseDenseAndSkewedSamples() throws {
        let samples = [
            [Vector3(x: -1, y: 0, z: -0.02), Vector3(x: 1, y: 1, z: -0.02), Vector3(x: 0, y: -1, z: 0.02)],
            (0..<64).map { i in
                let angle = Double(i) * 2 * Double.pi / 64
                return Vector3(x: cos(angle), y: sin(3 * angle), z: sin(angle))
            }
        ]
        for points in samples {
            let scan = NormalizedScan(source: .arkitMesh, normalizationVersion: 1, points: points)
            for seed in [UInt64(0), 1, 42, UInt64.max] {
                let track = try TrackGenerator.makeTrack(from: scan, seed: seed)
                XCTAssertEqual(track.source, .arkitMesh)
                XCTAssertTrue(TrackValidator.validate(track).isEmpty)
                XCTAssertEqual(track.points.count, 32)
                XCTAssertEqual(Set(track.points.map(\.halfWidth)), Set([0.65]))
            }
        }
    }
}
