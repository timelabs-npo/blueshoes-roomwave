import Foundation

/// Validation belongs at the boundary, never in the per-frame track sampler.
public enum SurfCourseCompiler {
    public static func compile(_ definition: SurfCourseDefinition) throws -> CompiledSurfCourse {
        func reject(_ reason: String) throws -> Never { throw SurfError.invalidCourse(reason) }
        guard definition.schemaVersion == 3 else { try reject("Unsupported schema") }
        guard !definition.id.isEmpty, definition.id.utf8.count <= 80,
              definition.id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }),
              !definition.title.isEmpty, definition.title.count <= 100,
              !definition.subtitle.isEmpty, definition.subtitle.count <= 240 else {
            try reject("Invalid identity or display text")
        }
        guard (2...20_000).contains(definition.samples.count) else { try reject("Sample count") }
        guard definition.samples[0].distance == 0 else { try reject("Samples must begin at zero") }
        var previous: SurfCourseSample?
        for sample in definition.samples {
            let p = sample.center
            guard sample.distance.isFinite, (0...20_000).contains(sample.distance),
                  p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  abs(p.x) <= 100_000, abs(p.y) <= 10_000, abs(p.z) <= 100_000,
                  sample.width.isFinite, (2...30).contains(sample.width) else {
                try reject("Nonfinite or out-of-bounds sample")
            }
            if let prior = previous {
                let delta = sample.distance - prior.distance
                let dx = p.x - prior.center.x, dy = p.y - prior.center.y, dz = p.z - prior.center.z
                let horizontal = (dx * dx + dz * dz).squareRoot()
                guard delta >= 0.01, horizontal >= 0.01,
                      horizontal / delta >= 0.25, horizontal / delta <= 4,
                      abs(dy / delta) <= 0.65 else { try reject("Unordered, degenerate or unusable segment") }
            }
            previous = sample
        }
        let length = definition.samples[definition.samples.count - 1].distance
        guard length >= 10 else { try reject("Course too short") }
        guard definition.encounters.count <= 5_000 else { try reject("Encounter count") }
        var identifiers = Set<Int>()
        var priorDistance = 0.0
        for encounter in definition.encounters {
            guard encounter.id >= 0, identifiers.insert(encounter.id).inserted,
                  encounter.distance.isFinite, encounter.distance > priorDistance, encounter.distance < length,
                  encounter.height.isFinite, (0.05...40).contains(encounter.height),
                  encounter.halfHeight.isFinite, (0.05...10).contains(encounter.halfHeight),
                  encounter.height >= encounter.halfHeight,
                  (1...10_000).contains(encounter.points) else { try reject("Invalid or unordered encounter") }
            priorDistance = encounter.distance
        }
        guard definition.medalScores.count == 3,
              definition.medalScores[0] > 0,
              definition.medalScores[0] < definition.medalScores[1],
              definition.medalScores[1] < definition.medalScores[2],
              definition.medalScores[2] <= 1_000_000_000 else { try reject("Medals must be bronze < silver < gold") }
        return CompiledSurfCourse(validatedDefinition: definition)
    }
}

public extension CompiledSurfCourse {
    /// O(log samples). Nonfinite queries use a documented safe endpoint: NaN/-inf start, +inf end.
    func pose(at distance: Double) -> SurfPose {
        let samples = definition.samples
        let d = distance.isNaN ? 0 : min(length, max(0, distance))
        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let middle = low + (high - low) / 2
            if samples[middle].distance <= d { low = middle } else { high = middle }
        }
        let a = samples[low], b = samples[high]
        let span = b.distance - a.distance
        let t = min(1, max(0, (d - a.distance) / span))
        let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y, dz = b.center.z - a.center.z
        let magnitude = (dx * dx + dy * dy + dz * dz).squareRoot()
        return SurfPose(center: SurfVector(x: a.center.x + dx * t, y: a.center.y + dy * t, z: a.center.z + dz * t),
                        forward: SurfVector(x: dx / magnitude, y: dy / magnitude, z: dz / magnitude),
                        slope: dy / span, width: a.width + (b.width - a.width) * t)
    }
}
