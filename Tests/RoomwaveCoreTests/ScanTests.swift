import Foundation
import Testing
@testable import RoomwaveCore

private let inventedPoints = [Vector3(x: -3, y: 0, z: -2), Vector3(x: 3, y: 0, z: -2),
                              Vector3(x: 3, y: 1, z: 2), Vector3(x: -3, y: 1, z: 2)]

private func sample(_ points: [Vector3] = inventedPoints, source: ScanSource = .synthetic,
                    captureID: String = "invented-local-only") -> ScanSample {
    ScanSample(captureID: captureID, source: source, points: points)
}

private func square(source: ScanSource = .synthetic, seed: UInt64 = 42,
                    rules: RaceRules = .standard, points: [TrackPoint]? = nil,
                    schema: Int = 1, generator: String = "fixture-1") -> TrackDefinition {
    let route = [(-10.0, -10.0), (10.0, -10.0), (10.0, 10.0), (-10.0, 10.0)]
        .enumerated().map { i, p in
            TrackPoint(position: Vector3(x: p.0, y: 0, z: p.1), halfWidth: 1, isGate: i == 0)
        }
    return TrackDefinition(schemaVersion: schema, generatorVersion: generator, source: source,
                           seed: seed, rules: rules, points: points ?? route)
}

private func rule(tickRate: Int = 60, duration: Int = 5400, initial: Double = 4,
                  maximum: Double = 12, acceleration: Double = 0.10, steering: Double = 3,
                  bank: Double = 0.75, gain: Double = 0.25, version: String = "roomwave-rules-1") -> RaceRules {
    RaceRules(version: version, tickRate: tickRate, durationTicks: duration, initialSpeed: initial,
              maximumSpeed: maximum, acceleration: acceleration, steeringSpeed: steering,
              bankSpeedFactor: bank, multiplierGain: gain)
}

@Test func normalizationPreservesOriginAndDropsCaptureIdentity() throws {
    for source in [ScanSource.synthetic, .arkitMesh] {
        let normalized = try ScanNormalizer.normalize(sample(source: source))
        #expect(normalized.source == source)
        #expect(normalized.normalizationVersion == 1)
        #expect(normalized.points.count == inventedPoints.count)
        #expect(normalized.points.allSatisfy { p in [p.x, p.y, p.z].allSatisfy { $0.isFinite && abs($0) <= 1 } })
        #expect(try normalized == ScanNormalizer.normalize(sample(source: source, captureID: "different-private-id")))
        #expect(try TrackGenerator.makeTrack(from: normalized, seed: 9).source == source)
        let json = String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self)
        #expect(!json.contains("captureID"))
    }
    let translated = inventedPoints.map { Vector3(x: $0.x * 2 + 20, y: $0.y * 2 - 4, z: $0.z * 2 + 8) }
    #expect(try ScanNormalizer.normalize(sample()).points == ScanNormalizer.normalize(sample(translated)).points)
    let limit = (0..<4096).map { inventedPoints[$0 % inventedPoints.count] }
    #expect(try ScanNormalizer.normalize(sample(limit)).points.count == 4096)
}

@Test func normalizationRejectsInvalidAndDegenerateInputs() {
    let lines = (0..<4).map { Vector3(x: Double($0), y: 0, z: Double($0)) }
    let nearLine = [Vector3(x: 0, y: 0, z: 0), Vector3(x: 1, y: 0, z: 1), Vector3(x: 2, y: 0, z: 2.000001)]
    let invalid = [[], [inventedPoints[0]], Array(repeating: inventedPoints[0], count: 4097),
                   Array(repeating: inventedPoints[0], count: 3), lines, nearLine,
                   [Vector3(x: 1001, y: 0, z: 0)] + inventedPoints,
                   [Vector3(x: 101, y: 0, z: 0)] + inventedPoints,
                   [Vector3(x: .nan, y: 0, z: 0)] + inventedPoints,
                   [Vector3(x: 0, y: .infinity, z: 0)] + inventedPoints,
                   [Vector3(x: 0, y: 0, z: -.infinity)] + inventedPoints]
    for points in invalid {
        #expect(throws: RoomwaveError.self) { try ScanNormalizer.normalize(sample(points)) }
    }
    let tiny = inventedPoints.map { Vector3(x: $0.x / 1000, y: 0, z: $0.z / 1000) }
    #expect(throws: RoomwaveError.self) { try ScanNormalizer.normalize(sample(tiny)) }
}

@Test func generationIsDeterministicBoundedAndCoarse() throws {
    let normalized = try ScanNormalizer.normalize(sample())
    let track = try TrackGenerator.makeTrack(from: normalized, seed: 42)
    #expect(track == (try TrackGenerator.makeTrack(from: normalized, seed: 42)))
    #expect(track.points != (try TrackGenerator.makeTrack(from: normalized, seed: 43)).points)
    #expect(track.points.count == 32)
    #expect(Array(track.points.prefix(3)).map(\.position) == [Vector3(x: -3.280, y: 0, z: 18.052),
                                                            Vector3(x: -5.457, y: 0, z: 17.298),
                                                            Vector3(x: -7.425, y: 0, z: 15.880)])
    #expect(track.points.filter(\.isGate).count == 4)
    #expect(track.points.first != track.points.last) // Closure is implicit, not a duplicate vertex.
    #expect(track.points.allSatisfy { abs($0.position.x) <= 27 && abs($0.position.z) <= 27 && $0.position.y == 0 })
    #expect(TrackValidator.validate(track).isEmpty)
    // Same bounds with an invented interior point changes local data, not finalized layout.
    let withInterior = try ScanNormalizer.normalize(sample(inventedPoints + [Vector3(x: 0, y: 0.5, z: 0)]))
    #expect(track == (try TrackGenerator.makeTrack(from: withInterior, seed: 42)))
    for seed in [UInt64(0), 1, 123456, UInt64.max] {
        #expect(TrackValidator.validate(try TrackGenerator.makeTrack(from: normalized, seed: seed)).isEmpty)
    }
}

@Test func generationRejectsForgedNormalizedIntermediates() {
    let invalid = [NormalizedScan(source: .synthetic, normalizationVersion: 2, points: inventedPoints),
                   NormalizedScan(source: .synthetic, normalizationVersion: 1, points: []),
                   NormalizedScan(source: .synthetic, normalizationVersion: 1, points: inventedPoints),
                   NormalizedScan(source: .synthetic, normalizationVersion: 1,
                                  points: Array(repeating: Vector3(x: 0, y: 0, z: 0), count: 3)),
                   NormalizedScan(source: .synthetic, normalizationVersion: 1,
                                  points: [Vector3(x: .nan, y: 0, z: 0)] + inventedPoints)]
    for scan in invalid { #expect(throws: RoomwaveError.self) { try TrackGenerator.makeTrack(from: scan, seed: 0) } }
}

@Test func validatorRejectsGeometryAndRuleFailures() {
    #expect(TrackValidator.validate(square()).isEmpty)
    let base = square().points
    func replacing(_ index: Int, _ point: TrackPoint) -> [TrackPoint] {
        var points = base; points[index] = point; return points
    }
    let badRoutes: [[TrackPoint]] = [[], Array(repeating: base[0], count: 257),
        replacing(1, base[0]),
        replacing(0, TrackPoint(position: Vector3(x: .nan, y: 0, z: 0), halfWidth: 1, isGate: true)),
        replacing(0, TrackPoint(position: base[0].position, halfWidth: 0, isGate: true)),
        replacing(0, TrackPoint(position: Vector3(x: -10, y: 1, z: -10), halfWidth: 1, isGate: true)),
        replacing(0, TrackPoint(position: Vector3(x: -10.0001, y: 0, z: -10), halfWidth: 1, isGate: true)),
        replacing(0, TrackPoint(position: Vector3(x: -101, y: 0, z: -10), halfWidth: 1, isGate: true)),
        [base[0], base[2], base[1], base[3]], // Crossing, including implicit closing segment checks.
        base.map { TrackPoint(position: $0.position, halfWidth: $0.halfWidth, isGate: false) }]
    for points in badRoutes { #expect(!TrackValidator.validate(square(points: points)).isEmpty) }
    let narrow = [(-10.0, -10.0), (10.0, -10.0), (10.0, -9.0), (-10.0, -9.0)].enumerated().map { i, p in
        TrackPoint(position: Vector3(x: p.0, y: 0, z: p.1), halfWidth: 1, isGate: i == 0)
    }
    #expect(TrackValidator.validate(square(points: narrow)).contains { $0.code == "clearance" })
    let sharp = [(-10.0, 0.0), (10.0, 0.0), (-9.0, 1.0), (-10.0, 10.0)].enumerated().map { i, p in
        TrackPoint(position: Vector3(x: p.0, y: 0, z: p.1), halfWidth: 1, isGate: i == 0)
    }
    #expect(TrackValidator.validate(square(points: sharp)).contains { $0.code == "curvature" })
    let invalidRules = [rule(tickRate: 0), rule(tickRate: Int.max), rule(duration: 0), rule(duration: Int.max),
                        rule(initial: 0), rule(maximum: 3), rule(acceleration: -1), rule(steering: .nan),
                        rule(bank: 0), rule(bank: 1.1), rule(gain: .infinity), rule(gain: 0), rule(version: "")]
    for rules in invalidRules { #expect(TrackValidator.validate(square(rules: rules)).contains { $0.code == "rules" }) }
    #expect(!TrackValidator.validate(square(schema: 2)).isEmpty)
    #expect(!TrackValidator.validate(square(generator: "")).isEmpty)
}

@Test func canonicalIdentityCoversRulesGeometryAndProvenance() throws {
    let baseline = try TrackIdentity.canonicalData(for: square())
    #expect(baseline == (try TrackIdentity.canonicalData(for: square())))
    #expect(baseline.count == 293)
    #expect(baseline.map { String(format: "%02x", $0) }.joined() == "726f6f6d776176652d747261636b2d6964656e746974792d763100000000000000000100000009666978747572652d310000000973796e746865746963000000000000002a00000010726f6f6d776176652d72756c65732d31000000000000003c0000000000001518401000000000000040280000000000003fb999999999999a40080000000000003fe80000000000003fd00000000000000000000000000004ffffffffffffd8f00000000000000000ffffffffffffd8f000000000000003e80100000000000027100000000000000000ffffffffffffd8f000000000000003e80000000000000027100000000000000000000000000000271000000000000003e800ffffffffffffd8f00000000000000000000000000000271000000000000003e800")
    #expect(baseline.starts(with: Data("roomwave-track-identity-v1\0".utf8)))
    let changedRules = [rule(tickRate: 30), rule(duration: 100), rule(initial: 5), rule(maximum: 13),
                        rule(acceleration: 0.2), rule(steering: 4), rule(bank: 0.5), rule(gain: 0.5), rule(version: "v2")]
    for rules in changedRules { #expect(baseline != (try TrackIdentity.canonicalData(for: square(rules: rules)))) }
    #expect(baseline != (try TrackIdentity.canonicalData(for: square(source: .arkitMesh))))
    #expect(baseline != (try TrackIdentity.canonicalData(for: square(seed: 43))))
    #expect(baseline != (try TrackIdentity.canonicalData(for: square(generator: "fixture-2"))))
    var changed = square().points
    changed[0] = TrackPoint(position: Vector3(x: -9.999, y: 0, z: -10), halfWidth: 1, isGate: true)
    #expect(baseline != (try TrackIdentity.canonicalData(for: square(points: changed))))
    changed = square().points
    changed[1] = TrackPoint(position: changed[1].position, halfWidth: 1, isGate: true)
    #expect(baseline != (try TrackIdentity.canonicalData(for: square(points: changed))))
    changed = square().points
    changed[0] = TrackPoint(position: changed[0].position, halfWidth: 1.001, isGate: true)
    #expect(baseline != (try TrackIdentity.canonicalData(for: square(points: changed))))
    changed = square().points.map { TrackPoint(position: Vector3(x: $0.position.x, y: -0.0, z: $0.position.z), halfWidth: 1, isGate: $0.isGate) }
    #expect(baseline == (try TrackIdentity.canonicalData(for: square(points: changed))))
    #expect(try TrackIdentity.canonicalData(for: square(rules: rule(acceleration: 0)))
        == TrackIdentity.canonicalData(for: square(rules: rule(acceleration: -0.0))))
    let reordered = Array(square().points.dropFirst()) + [square().points[0]]
    #expect(baseline != (try TrackIdentity.canonicalData(for: square(points: reordered))))
    #expect(throws: RoomwaveError.self) { try TrackIdentity.canonicalData(for: square(points: [])) }
    #expect(throws: RoomwaveError.self) { try TrackIdentity.id(for: square(points: [])) }
}

@Test func identityUsesAppleSHA256OrExplicitUnsupportedError() throws {
    #if canImport(CryptoKit) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
    let identity = try TrackIdentity.id(for: square())
    #expect(identity.count == 64)
    #expect(identity == "b966931b9cb91268f35a4f5cc03f27d642add4b99a95b959fd2e594b54187813")
    #expect(identity == (try TrackIdentity.id(for: square())))
    #expect(identity != (try TrackIdentity.id(for: square(rules: rule(duration: 100)))))
    #else
    do {
        _ = try TrackIdentity.id(for: square())
        Issue.record("Expected unsupportedPlatform outside Apple CryptoKit")
    } catch let error as RoomwaveError {
        guard case .unsupportedPlatform = error else { Issue.record("Unexpected error: \(error)"); return }
    }
    #endif
}

@Test func challengeContainsFinalizedTrackOnly() throws {
    let track = try TrackGenerator.makeTrack(from: ScanNormalizer.normalize(sample()), seed: 42)
    // Descriptor construction does not require pretending a digest exists on unsupported hosts.
    let descriptor = ChallengeDescriptor(schemaVersion: 1, trackID: "test-placeholder-not-an-attestation", track: track)
    let data = try JSONEncoder().encode(descriptor)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == Set(["schemaVersion", "trackID", "track"]))
    let finalized = try #require(json["track"] as? [String: Any])
    #expect(Set(finalized.keys) == Set(["schemaVersion", "generatorVersion", "source", "seed", "rules", "points"]))
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("captureID"))
    #expect(!text.contains("invented-local-only"))
    #expect(!text.contains("normalizationVersion"))
    #expect(track.source == .synthetic)
}

@Test func syntheticFixtureDecodesAndGenerates() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/scan/synthetic-rectangle.json"))
    let fixture = try JSONDecoder().decode(ScanSample.self, from: data)
    #expect(fixture.source == .synthetic)
    #expect(fixture.points.count == 4)
    #expect(TrackValidator.validate(try TrackGenerator.makeTrack(from: ScanNormalizer.normalize(fixture), seed: 0)).isEmpty)
}
