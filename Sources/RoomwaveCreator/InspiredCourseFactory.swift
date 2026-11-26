import Foundation
import RoomwaveCore
import RoomwaveArcade

/// Turns local visual/mesh features into restrained variations of authored
/// terrain. It preserves encounter spacing. This is creative interpretation,
/// not photogrammetry or a metric reconstruction of the captured space.
public enum InspiredCourseFactory {
    public static func make(from sample: ScanSample) throws -> CompiledSurfCourse {
        guard sample.source == .photoDerived || sample.source == .arkitMesh else {
            throw RoomwaveError.invalidScan("Choose a real photo or device mesh for an inspired course")
        }
        let normalized = try ScanNormalizer.normalize(sample)
        guard let base = SurfCatalog.course(id: "neon-dawn"),
              let end = base.samples.last?.distance, end > 0 else {
            throw SurfError.invalidCourse("The authored creator foundation is unavailable")
        }

        // Sixteen coarse spatial features, not image bytes or capture metadata.
        // Canonical accumulation order prevents floating-point rounding at a
        // bin boundary from changing identity when mesh point order changes.
        var sums = [Double](repeating: 0, count: 16)
        var weights = [Double](repeating: 0, count: 16)
        let ordered = normalized.points.sorted {
            if $0.z != $1.z { return $0.z < $1.z }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.y < $1.y
        }
        for point in ordered {
            let bin = min(15, max(0, Int((point.z + 1) * 8)))
            let weight = 1 + min(1, abs(point.x)) * 0.25
            sums[bin] += (point.y * 0.7 + point.x * point.x * 0.3) * weight
            weights[bin] += weight
        }
        let features = (0..<16).map { index -> Double in
            let mean = weights[index] > 0 ? sums[index] / weights[index] : 0
            return (min(1, max(-1, mean)) * 100).rounded() / 100
        }
        var seed: UInt64 = 14_695_981_039_346_656_037
        for value in features {
            let encoded = UInt64(Int((value + 1) * 1000))
            seed = (seed ^ encoded) &* 1_099_511_628_211
        }
        let lateral = features.enumerated().reduce(0.0) { $0 + $1.element * sin(Double($1.offset) * 0.63) } / 16
        let relief = features.enumerated().reduce(0.0) { $0 + $1.element * cos(Double($1.offset) * 0.41) } / 16
        let bias = features.reduce(0, +) / 16
        let samples = base.samples.map { point in
            let fraction = point.distance / end
            let envelope = pow(sin(.pi * fraction), 2)
            let xOffset = envelope * (2.2 * lateral * sin(4 * .pi * fraction)
                                     + 1.2 * bias * sin(2 * .pi * fraction))
            let yOffset = envelope * (1.5 * relief * sin(4 * .pi * fraction)
                                     + 0.8 * bias * sin(2 * .pi * fraction))
            return SurfCourseSample(distance: point.distance,
                center: SurfVector(x: point.center.x + xOffset,
                                   y: point.center.y + yOffset, z: point.center.z),
                width: point.width)
        }
        let photo = sample.source == .photoDerived
        let definition = SurfCourseDefinition(
            id: (photo ? "photo-" : "lidar-") + String(seed, radix: 16),
            title: photo ? "PHOTO CURRENT" : "ROOM CURRENT",
            subtitle: photo ? "Your picture, reimagined as a ride." : "Your space, reimagined as a ride.",
            biome: relief > 0.03 ? .orbit : bias < -0.05 ? .midnight : .dawn,
            source: photo ? .photoInspired : .lidarInspired, seed: seed,
            samples: samples, encounters: base.encounters, medalScores: base.medalScores)
        return try SurfCourseCompiler.compile(definition)
    }
}
