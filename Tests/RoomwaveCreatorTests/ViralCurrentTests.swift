import Foundation
import XCTest
import RoomwaveArcade
import RoomwaveCore
@testable import RoomwaveCreator

final class ViralCurrentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(_ id: String = "1991234567890123456", likes: Int = 100,
                      reposts: Int = 10, replies: Int = 5, quotes: Int = 2,
                      age: TimeInterval = 60) -> XPostSnapshot {
        XPostSnapshot(id: id, sampledAt: now.addingTimeInterval(-age),
            metrics: XPostMetrics(likes: likes, reposts: reposts, replies: replies, quotes: quotes))
    }

    private func authored() throws -> CompiledSurfCourse {
        try SurfCourseCompiler.compile(XCTUnwrap(SurfCatalog.course(id: "neon-dawn")))
    }

    func testFrozenAggregateIsOrderIndependentAndDoesNotExportPostIdentifiers() throws {
        let posts = [post(), post("1991234567890123457", likes: 80, replies: 20, age: 120)]
        let first = try ViralCurrentBuilder.make(posts: posts, kind: .personal, now: now)
        let reversed = try ViralCurrentBuilder.make(posts: Array(posts.reversed()), kind: .personal, now: now)
        XCTAssertEqual(first, reversed)
        XCTAssertNil(first.velocity, "A single cumulative observation is not growth")
        XCTAssertEqual(first.comparedPostCount, 0)
        XCTAssertEqual(first.postCount, 2)
        XCTAssertEqual(first.observedAt, now.addingTimeInterval(-120))
        XCTAssertEqual(first.ageSeconds, 120)
        XCTAssertEqual(first.freshness, 1 - 120 / 86_400.0, accuracy: 0.000001)
        let json = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        for source in posts { XCTAssertFalse(json.contains(source.id)) }
        XCTAssertFalse(json.contains("metrics"))
        XCTAssertEqual(try JSONDecoder().decode(ViralCurrent.self, from: JSONEncoder().encode(first)), first)
        XCTAssertEqual(try JSONDecoder().decode(XPostSnapshot.self, from: JSONEncoder().encode(posts[0])), posts[0])
    }

    func testActualActivityChangesTerrainAndRewardPlacementWithoutAwardingEngagementScore() throws {
        let quiet = try ViralCurrentBuilder.make(posts: [post(likes: 0, reposts: 0, replies: 0, quotes: 0)],
            kind: .personal, now: now)
        let active = try ViralCurrentBuilder.make(posts: [post(likes: 20_000, reposts: 500, replies: 8_000, quotes: 300)],
            kind: .personal, now: now)
        let base = try authored()
        let a = try ViralCourseFactory.make(base: base, current: quiet)
        let b = try ViralCourseFactory.make(base: base, current: active)
        XCTAssertLessThan(quiet.intensity, active.intensity)
        XCTAssertNotEqual(a.definition.id, b.definition.id)
        XCTAssertNotEqual(a.definition.samples, b.definition.samples)
        XCTAssertNotEqual(a.definition.encounters, b.definition.encounters)
        XCTAssertEqual(a.definition.title, "PERSONAL CURRENT")
        XCTAssertEqual(a.definition.source, .xInspired)
        XCTAssertEqual(a.definition.medalScores, base.definition.medalScores)
        XCTAssertEqual(a.definition.encounters.map(\.points), base.definition.encounters.map(\.points))
        XCTAssertEqual(b.definition.encounters.map(\.points), base.definition.encounters.map(\.points))
        XCTAssertEqual(a.definition.encounters.filter { $0.kind == .barrier || $0.kind == .ceiling },
                       base.definition.encounters.filter { $0.kind == .barrier || $0.kind == .ceiling })
        XCTAssertEqual(SurfSimulation.start(course: a).score, 0)
        XCTAssertEqual(SurfSimulation.start(course: b).score, 0)
        XCTAssertEqual(try ViralCourseFactory.make(base: base, current: active).definition, b.definition)
        XCTAssertEqual(a.definition.samples.first, base.definition.samples.first)
        XCTAssertEqual(a.definition.samples.last, base.definition.samples.last)
    }

    func testPersonalAndCommunitySnapshotsHaveDistinctPlayableIdentities() throws {
        let personal = try ViralCurrentBuilder.make(posts: [post()], kind: .personal, now: now)
        let community = try ViralCurrentBuilder.make(posts: [post()], kind: .community, now: now)
        XCTAssertNotEqual(personal.seed, community.seed)
        let course = try ViralCourseFactory.make(base: authored(), current: community)
        XCTAssertEqual(course.definition.title, "COMMUNITY CURRENT")
        XCTAssertTrue(course.definition.subtitle.contains("2027-01-15T07:59:00Z"))
        let exported = String(decoding: try JSONEncoder().encode(course.definition), as: UTF8.self)
        XCTAssertFalse(exported.contains(post().id))
    }

    func testCompetitiveBaseChangesCannotReuseDerivedCourseIdentity() throws {
        let current = try ViralCurrentBuilder.make(posts: [post()], kind: .personal, now: now)
        let original = try authored()
        let definition = original.definition
        let originalOutput = try ViralCourseFactory.make(base: original, current: current)
        let first = try XCTUnwrap(definition.encounters.first)
        var changedRewards = definition.encounters
        changedRewards[0] = SurfEncounter(id: first.id, kind: first.kind, distance: first.distance,
            height: first.height, halfHeight: first.halfHeight, points: first.points + 1)
        var changedHazards = definition.encounters
        changedHazards[0] = SurfEncounter(id: first.id, kind: first.kind == .barrier ? .ceiling : .barrier,
            distance: first.distance, height: first.height, halfHeight: first.halfHeight, points: first.points)
        let variants = [
            (changedRewards, definition.medalScores),
            (changedHazards, definition.medalScores),
            (definition.encounters, definition.medalScores.map { $0 + 1 })
        ]
        for (encounters, medals) in variants {
            let changed = try SurfCourseCompiler.compile(SurfCourseDefinition(
                id: definition.id, title: definition.title, subtitle: definition.subtitle,
                biome: definition.biome, source: definition.source, seed: definition.seed,
                samples: definition.samples, encounters: encounters, medalScores: medals))
            let output = try ViralCourseFactory.make(base: changed, current: current)
            XCTAssertNotEqual(output.definition.id, originalOutput.definition.id)
            XCTAssertNotEqual(output.definition.seed, originalOutput.definition.seed)
            XCTAssertEqual(output.definition.encounters.map(\.points), encounters.map(\.points))
            XCTAssertEqual(output.definition.medalScores, medals)
        }
    }

    func testChangedDecodedAggregateCannotKeepIdentityByReusingItsSeed() throws {
        let original = try ViralCurrentBuilder.make(posts: [post()], kind: .personal, now: now)
        let base = try authored()
        let first = try ViralCourseFactory.make(base: base, current: original)
        // The public Codable boundary accepts a syntactically valid aggregate.
        // Its supplied seed must not override the actual gameplay inputs.
        for field in ["intensity", "conversation", "velocity"] {
            let candidate = ViralCurrent(kind: original.kind,
                intensity: field == "intensity" ? 0.99 : original.intensity,
                conversation: field == "conversation" ? 0.99 : original.conversation,
                velocity: field == "velocity" ? 1 : original.velocity,
                observedAt: original.observedAt, freshness: original.freshness,
                ageSeconds: original.ageSeconds, postCount: original.postCount,
                comparedPostCount: field == "velocity" ? 1 : original.comparedPostCount,
                seed: original.seed)
            let changed = try JSONDecoder().decode(ViralCurrent.self, from: JSONEncoder().encode(candidate))
            XCTAssertEqual(changed.seed, original.seed)
            let output = try ViralCourseFactory.make(base: base, current: changed)
            XCTAssertNotEqual(output.definition.id, first.definition.id)
            XCTAssertNotEqual(output.definition.samples, first.definition.samples)
            XCTAssertEqual(SurfSimulation.start(course: output).score, 0)
        }
    }

    func testVelocityUsesOnlySamePostElapsedIntervalsAndClampsCorrectedCounters() throws {
        let previous = [post(likes: 200, reposts: 1, replies: 3, quotes: 2, age: 120),
                        post("1991234567890123499", likes: 0, age: 120)]
        let current = try ViralCurrentBuilder.make(
            posts: [post(likes: 100, reposts: 11, replies: 8, quotes: 2, age: 60),
                    post("1991234567890123457", likes: 9_999, age: 60)],
            previous: previous, kind: .personal, now: now)
        XCTAssertEqual(current.comparedPostCount, 1)
        // Likes were corrected down. 10 reposts*3 + 5 replies*2 over60s.
        XCTAssertEqual(try XCTUnwrap(current.velocity), 40 / 60.0, accuracy: 0.000001)
        let allDown = try ViralCurrentBuilder.make(posts: [post(likes: 0, reposts: 0, replies: 0, quotes: 0)],
            previous: previous, kind: .personal, now: now)
        XCTAssertEqual(allDown.velocity, 0)
    }

    func testTooShortOrUnmatchedObservationsDoNotInventVelocity() throws {
        let short = try ViralCurrentBuilder.make(posts: [post()], previous: [post(likes: 0, age: 74)],
            kind: .community, now: now)
        XCTAssertNil(short.velocity)
        let exact = try ViralCurrentBuilder.make(posts: [post()], previous: [post(likes: 0, age: 75)],
            kind: .community, now: now)
        XCTAssertNotNil(exact.velocity)
        let unmatched = try ViralCurrentBuilder.make(posts: [post()],
            previous: [post("1991234567890123457", likes: 0)], kind: .community, now: now)
        XCTAssertNil(unmatched.velocity)
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [post()], previous: [post(age: 59)],
            kind: .community, now: now))
    }

    func testFreshnessDoesNotMutateFrozenCourseGeometry() throws {
        let first = try ViralCurrentBuilder.make(posts: [post()], kind: .personal, now: now)
        let later = try ViralCurrentBuilder.make(posts: [post()], kind: .personal,
            now: now.addingTimeInterval(600))
        XCTAssertLessThan(later.freshness, first.freshness)
        XCTAssertEqual(first.seed, later.seed)
        let base = try authored()
        XCTAssertEqual(try ViralCourseFactory.make(base: base, current: first).definition,
                       try ViralCourseFactory.make(base: base, current: later).definition)
    }

    func testLidarReliefAndMeasuredSourceProvenanceRemainTheFoundation() throws {
        let mesh = ScanSample(captureID: "private-room-session", source: .arkitMesh,
            points: [Vector3(x: -1, y: -0.5, z: -1), Vector3(x: 1, y: 0.8, z: -1),
                     Vector3(x: -1, y: 0.7, z: 1), Vector3(x: 1, y: -0.4, z: 1)])
        let base = try InspiredCourseFactory.make(from: mesh)
        let current = try ViralCurrentBuilder.make(posts: [post(replies: 800)], kind: .community, now: now)
        let output = try ViralCourseFactory.make(base: base, current: current)
        XCTAssertEqual(output.definition.source, .xLidarInspired)
        XCTAssertEqual(output.length, base.length)
        XCTAssertEqual(output.definition.biome, base.definition.biome)
        XCTAssertEqual(output.definition.samples.count, base.definition.samples.count)
        XCTAssertNotEqual(output.definition.samples, base.definition.samples)
        for (original, changed) in zip(base.definition.samples, output.definition.samples) {
            XCTAssertEqual(changed.distance, original.distance)
            XCTAssertEqual(changed.center.z, original.center.z)
            XCTAssertEqual(changed.width, original.width)
            XCTAssertLessThanOrEqual(abs(changed.center.x - original.center.x), 0.851)
            XCTAssertLessThanOrEqual(abs(changed.center.y - original.center.y), 0.441)
        }
        let exported = String(decoding: try JSONEncoder().encode(output.definition), as: UTF8.self)
        XCTAssertFalse(exported.contains("private-room-session"))
    }

    func testNoDataAndMalformedSnapshotsAreExplicitlyRejected() throws {
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [], kind: .personal, now: now)) {
            XCTAssertEqual($0 as? ViralCurrentError, .noData)
        }
        for invalid in [post(""), post("@account"), post("01"), post("0"),
                        post("123456789012345678901"), post(likes: -1),
                        post(replies: ViralCurrentBuilder.maximumCount + 1),
                        post(age: -0.01), post(age: 86_401)] {
            XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [invalid], kind: .personal, now: now))
        }
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [post(), post()], kind: .personal, now: now))
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [post()], previous: [post(), post()],
            kind: .personal, now: now))
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [post()], previous: [post(age: -1)],
            kind: .personal, now: now))
        let tooMany = (1...101).map { post(String($0)) }
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: tooMany, kind: .personal, now: now))
        let nan = XPostSnapshot(id: "1", sampledAt: Date(timeIntervalSince1970: .nan), metrics: XPostMetrics())
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [nan], kind: .personal, now: now))
        XCTAssertThrowsError(try ViralCurrentBuilder.make(posts: [post()], kind: .personal,
            now: Date(timeIntervalSince1970: .infinity)))
    }

    func testMaximalCountersStayFiniteAndEveryAuthoredCourseStillCompiles() throws {
        let posts = (1...100).map { post(String($0), likes: ViralCurrentBuilder.maximumCount,
            reposts: ViralCurrentBuilder.maximumCount, replies: ViralCurrentBuilder.maximumCount,
            quotes: ViralCurrentBuilder.maximumCount, age: 0) }
        let current = try ViralCurrentBuilder.make(posts: posts, kind: .community, now: now)
        XCTAssertEqual(current.intensity, 1)
        XCTAssertEqual(current.conversation, 0.5)
        XCTAssertEqual(current.freshness, 1)
        for definition in SurfCatalog.all {
            let course = try ViralCourseFactory.make(base: SurfCourseCompiler.compile(definition), current: current)
            XCTAssertTrue(course.definition.samples.allSatisfy { $0.center.x.isFinite && $0.center.y.isFinite })
        }
    }
}
