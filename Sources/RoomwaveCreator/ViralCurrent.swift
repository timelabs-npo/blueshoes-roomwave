import Foundation
import RoomwaveArcade

/// Only public engagement counters cross this boundary. Text, account identity,
/// credentials and API response payloads are deliberately absent.
public struct XPostMetrics: Codable, Equatable, Sendable {
    public let likes: Int
    public let reposts: Int
    public let replies: Int
    public let quotes: Int

    public init(likes: Int = 0, reposts: Int = 0, replies: Int = 0, quotes: Int = 0) {
        self.likes = likes; self.reposts = reposts; self.replies = replies; self.quotes = quotes
    }
}

public struct XPostSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let sampledAt: Date
    public let metrics: XPostMetrics

    public init(id: String, sampledAt: Date, metrics: XPostMetrics) {
        self.id = id; self.sampledAt = sampledAt; self.metrics = metrics
    }
}

public enum ViralFeedKind: String, Codable, CaseIterable, Sendable { case personal, community }

public enum ViralCurrentError: Error, Equatable, Sendable {
    case noData
    case invalidSnapshot(String)
}

/// A frozen, bounded aggregate suitable for a playable course and sharing.
/// Its fingerprint is a deterministic dataset identity, not an attestation or
/// anonymization guarantee. It never contains source IDs or post content.
public struct ViralCurrent: Codable, Equatable, Sendable {
    public let kind: ViralFeedKind
    public let intensity: Double
    public let conversation: Double
    /// Weighted positive counter changes per second, across comparable posts.
    /// Nil means no same-post interval of at least 15 seconds was observed.
    public let velocity: Double?
    /// Oldest sample in the aggregate: freshness must not hide a stale member.
    public let observedAt: Date
    public let freshness: Double
    public let ageSeconds: Double
    public let postCount: Int
    public let comparedPostCount: Int
    public let seed: UInt64
    public var id: String { "x-current-" + String(seed, radix: 16) }
}

public enum ViralCurrentBuilder {
    public static let maximumAge: TimeInterval = 24 * 60 * 60
    public static let maximumCount = 1_000_000_000_000

    public static func make(posts: [XPostSnapshot], previous: [XPostSnapshot] = [],
                            kind: ViralFeedKind, now: Date) throws -> ViralCurrent {
        guard now.timeIntervalSince1970.isFinite else {
            throw ViralCurrentError.invalidSnapshot("Invalid reference time")
        }
        guard !posts.isEmpty else { throw ViralCurrentError.noData }
        let ordered = try validated(posts, now: now)
        let prior = try validated(previous, now: now)
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
        var weightedTotal = 0.0, allTotal = 0.0, conversationTotal = 0.0
        var velocity = 0.0, compared = 0
        var fingerprint = CurrentFingerprint()
        fingerprint.add("viral-current-v1")
        fingerprint.add(kind.rawValue)
        for post in ordered {
            let metrics = post.metrics
            weightedTotal += weighted(metrics)
            allTotal += Double(metrics.likes) + Double(metrics.reposts) + Double(metrics.replies) + Double(metrics.quotes)
            conversationTotal += Double(metrics.replies) + Double(metrics.quotes)
            fingerprint.add(post.id)
            fingerprint.add(String(post.sampledAt.timeIntervalSince1970.bitPattern))
            for counter in counters(metrics) { fingerprint.add(String(counter)) }
            if let old = priorByID[post.id] {
                let elapsed = post.sampledAt.timeIntervalSince(old.sampledAt)
                guard elapsed >= 0 else {
                    throw ViralCurrentError.invalidSnapshot("Previous sample is newer than current sample")
                }
                if elapsed >= 15 {
                    // Moderation and corrected counters cannot produce reverse
                    // velocity or conceal growth in a different counter.
                    let delta = XPostMetrics(likes: max(0, metrics.likes - old.metrics.likes),
                        reposts: max(0, metrics.reposts - old.metrics.reposts),
                        replies: max(0, metrics.replies - old.metrics.replies),
                        quotes: max(0, metrics.quotes - old.metrics.quotes))
                    velocity += weighted(delta) / elapsed
                    compared += 1
                }
            }
        }
        let measuredVelocity: Double? = compared > 0 ? velocity : nil
        fingerprint.add(measuredVelocity.map { String($0.bitPattern) } ?? "unmeasured")
        let observedAt = ordered.map(\.sampledAt).min()!
        let age = now.timeIntervalSince(observedAt)
        // A logarithmic response keeps small currents legible and huge feeds
        // bounded. It is a terrain parameter, never a score multiplier.
        let intensity = min(1, max(0, log1p(weightedTotal) / log1p(10_000_000)))
        let conversation = allTotal > 0 ? min(1, conversationTotal / allTotal) : 0
        return ViralCurrent(kind: kind, intensity: intensity, conversation: conversation,
            velocity: measuredVelocity, observedAt: observedAt,
            freshness: max(0, 1 - age / maximumAge), ageSeconds: age,
            postCount: ordered.count, comparedPostCount: compared, seed: fingerprint.value)
    }

    private static func counters(_ value: XPostMetrics) -> [Int] {
        [value.likes, value.reposts, value.replies, value.quotes]
    }

    private static func weighted(_ value: XPostMetrics) -> Double {
        Double(value.likes) + 3 * Double(value.reposts) + 2 * Double(value.replies) + 3 * Double(value.quotes)
    }

    private static func validated(_ posts: [XPostSnapshot], now: Date) throws -> [XPostSnapshot] {
        guard posts.count <= 100 else { throw ViralCurrentError.invalidSnapshot("At most 100 posts per snapshot") }
        var identifiers = Set<String>()
        for post in posts {
            let bytes = Array(post.id.utf8)
            guard (1...20).contains(bytes.count), bytes.first != 48,
                  bytes.allSatisfy({ (48...57).contains($0) }) else {
                throw ViralCurrentError.invalidSnapshot("Invalid canonical X post identifier")
            }
            guard identifiers.insert(post.id).inserted else {
                throw ViralCurrentError.invalidSnapshot("Duplicate post in snapshot")
            }
            guard counters(post.metrics).allSatisfy({ (0...maximumCount).contains($0) }) else {
                throw ViralCurrentError.invalidSnapshot("Engagement counter out of bounds")
            }
            let timestamp = post.sampledAt.timeIntervalSince1970
            let age = now.timeIntervalSince(post.sampledAt)
            guard timestamp.isFinite, age.isFinite, age >= 0, age <= maximumAge else {
                throw ViralCurrentError.invalidSnapshot("Snapshot must be in the past 24 hours")
            }
        }
        return posts.sorted { $0.id < $1.id }
    }
}

public enum ViralCourseFactory {
    /// Creates one immutable snapshot course. Refreshing the source does not
    /// mutate a compiled course or a replay that is already in progress.
    public static func make(base: CompiledSurfCourse, current: ViralCurrent) throws -> CompiledSurfCourse {
        guard current.intensity.isFinite, (0...1).contains(current.intensity),
              current.conversation.isFinite, (0...1).contains(current.conversation),
              current.freshness.isFinite, (0...1).contains(current.freshness),
              current.ageSeconds.isFinite, (0...ViralCurrentBuilder.maximumAge).contains(current.ageSeconds),
              current.observedAt.timeIntervalSince1970.isFinite,
              (1...100).contains(current.postCount),
              (0...current.postCount).contains(current.comparedPostCount),
              (current.velocity == nil) == (current.comparedPostCount == 0),
              current.velocity.map({ $0.isFinite && $0 >= 0 && $0 <= 100_000_000_000_000 }) ?? true else {
            throw ViralCurrentError.invalidSnapshot("Invalid current aggregate")
        }
        let definition = base.definition
        let lidar = definition.source == .lidarInspired || definition.source == .xLidarInspired
        var fingerprint = CurrentFingerprint(value: current.seed)
        fingerprint.add("viral-course-v2")
        // Bind every frozen current value that can affect the generated course,
        // rather than trusting that a decoded aggregate's seed describes it.
        // Age/freshness are observations at use time, not course identity.
        fingerprint.add(current.kind.rawValue)
        fingerprint.add(String(current.intensity.bitPattern))
        fingerprint.add(String(current.conversation.bitPattern))
        fingerprint.add(current.velocity.map { String($0.bitPattern) } ?? "unmeasured")
        fingerprint.add(String(current.observedAt.timeIntervalSince1970.bitPattern))
        fingerprint.add(String(current.postCount))
        fingerprint.add(String(current.comparedPostCount))
        fingerprint.add(String(definition.schemaVersion))
        fingerprint.add(String(definition.seed))
        fingerprint.add(definition.id)
        fingerprint.add(definition.source.rawValue)
        fingerprint.add(definition.biome.rawValue)
        fingerprint.add("samples")
        fingerprint.add(String(definition.samples.count))
        for sample in definition.samples {
            for number in [sample.distance, sample.center.x, sample.center.y, sample.center.z, sample.width] {
                fingerprint.add(String(number.bitPattern))
            }
        }
        fingerprint.add("encounters")
        fingerprint.add(String(definition.encounters.count))
        for encounter in definition.encounters {
            fingerprint.add(String(encounter.id))
            fingerprint.add(encounter.kind.rawValue)
            fingerprint.add(String(encounter.distance.bitPattern))
            fingerprint.add(String(encounter.height.bitPattern))
            fingerprint.add(String(encounter.halfHeight.bitPattern))
            fingerprint.add(String(encounter.points))
        }
        fingerprint.add("medal-scores")
        for score in definition.medalScores { fingerprint.add(String(score)) }
        let seed = fingerprint.value
        let phase = Double(seed % 10_000) / 10_000 * 2 * .pi
        let speed = current.velocity.map { min(1, log1p($0) / log1p(10_000)) } ?? 0
        let lateral = 0.25 + 0.45 * current.intensity + 0.15 * speed
        let relief = 0.12 + 0.22 * current.conversation + 0.1 * speed
        // Preserve longitudinal geometry, widths, opening/end and the entire
        // original spatial relief. X adds a restrained wave to that foundation.
        let timestamp = ISO8601DateFormatter().string(from: current.observedAt)
        let encounters = definition.encounters.enumerated().map { index, encounter -> SurfEncounter in
            guard encounter.kind == .ring || encounter.kind == .boost else { return encounter }
            let before = index > 0 ? definition.encounters[index - 1].distance : 0
            let after = index + 1 < definition.encounters.count ? definition.encounters[index + 1].distance : base.length
            let margin = min(1.5, min(encounter.distance - before, after - encounter.distance) * 0.2)
            let mix = seed &+ UInt64(encounter.id) &* 0x9e3779b97f4a7c15
            let signed = Double((mix ^ (mix >> 29)) % 2001) / 1000 - 1
            let shifted = encounter.distance + signed * margin * (0.25 + 0.75 * current.intensity)
            let height = encounter.kind == .ring
                ? min(40, max(encounter.halfHeight, encounter.height + signed * 0.35 * current.conversation))
                : encounter.height
            return SurfEncounter(id: encounter.id, kind: encounter.kind, distance: shifted,
                height: height, halfHeight: encounter.halfHeight, points: encounter.points)
        }
        // Extreme but valid input bases can sit at the compiler's exact slope
        // limit. Reduce only the added wave until the original base still fits.
        var lastError: Error = SurfError.invalidCourse("Current terrain does not fit the base")
        for attenuation in [1.0, 0.5, 0.25, 0.125, 0.0625] {
            let samples = definition.samples.map { sample in
                let t = sample.distance / base.length
                let envelope = t <= 0 || t >= 1 ? 0 : pow(sin(.pi * t), 2)
                let x = attenuation * envelope * lateral * sin(4 * .pi * t + phase)
                let y = attenuation * envelope * relief * sin(6 * .pi * t + phase)
                return SurfCourseSample(distance: sample.distance,
                    center: SurfVector(x: sample.center.x + x, y: sample.center.y + y, z: sample.center.z),
                    width: sample.width)
            }
            let output = SurfCourseDefinition(id: (lidar ? "x-lidar-" : "x-") + String(seed, radix: 16),
                title: current.kind == .personal ? "PERSONAL CURRENT" : "COMMUNITY CURRENT",
                subtitle: "X activity snapshot · " + timestamp,
                biome: definition.biome, source: lidar ? .xLidarInspired : .xInspired,
                seed: seed, samples: samples, encounters: encounters, medalScores: definition.medalScores)
            do { return try SurfCourseCompiler.compile(output) } catch { lastError = error }
        }
        throw lastError
    }
}

private struct CurrentFingerprint {
    var value: UInt64 = 14_695_981_039_346_656_037
    mutating func add(_ text: String) {
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        // Domain-separate fields so ["1", "23"] cannot equal ["12", "3"].
        value = (value ^ 255) &* 1_099_511_628_211
    }
}
