import Foundation

public enum TrackGenerator {
    public static func makeTrack(from scan: NormalizedScan, seed: UInt64) throws -> TrackDefinition {
        guard scan.normalizationVersion == 1, (3...4096).contains(scan.points.count),
              scan.points.allSatisfy({ p in
                  [p.x, p.y, p.z].allSatisfy { $0.isFinite && abs($0) <= 1.000000001 }
              }) else { throw RoomwaveError.invalidScan("Invalid normalized scan or version") }
        try ScanGeometry.requireArea(scan.points)
        let xs = scan.points.map(\.x), zs = scan.points.map(\.z)
        let dx = xs.max()! - xs.min()!, dz = zs.max()! - zs.min()!
        let largest = max(dx, dz)
        // Eight angular summaries retain point distribution and image-derived
        // height as planar shape evidence. This is stylization, not measured
        // reconstruction or calibrated depth. Sort so input ordering cannot
        // change floating-point accumulation or finalized geometry.
        let ordered = scan.points.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.z != $1.z { return $0.z < $1.z }
            return $0.y < $1.y
        }
        var counts = Array(repeating: 0, count: 8)
        var radii = Array(repeating: 0.0, count: 8)
        var heights = Array(repeating: 0.0, count: 8)
        for p in ordered {
            let angle = atan2(p.z, p.x) + 2 * Double.pi
            let sector = Int((angle / (2 * Double.pi) * 8).rounded(.down)) % 8
            counts[sector] += 1
            radii[sector] += hypot(p.x, p.z) / sqrt(2)
            heights[sector] += p.y
        }
        let population = Double(ordered.count)
        let meanRadius = radii.reduce(0, +) / population
        let meanHeight = heights.reduce(0, +) / population
        var contour = (0..<8).map { i -> Double in
            let radius = counts[i] == 0 ? meanRadius : radii[i] / Double(counts[i])
            let height = counts[i] == 0 ? meanHeight : heights[i] / Double(counts[i])
            let density = Double(counts[i]) / population
            return max(-0.18, min(0.18, 0.16 * (radius - 0.5) + 0.12 * height + 0.16 * (density - 0.125)))
        }
        // Periodic low-pass filtering bounds local turns, including the seam.
        // Three [1,2,1]/4 passes retain broad features without tracing clutter.
        for _ in 0..<3 {
            contour = (0..<8).map { index -> Double in
                let left: Double = contour[(index + 7) % 8]
                let center: Double = 2.0 * contour[index]
                let right: Double = contour[(index + 1) % 8]
                return ((left + center) + right) / 4.0
            }
        }
        var random = SplitMix64(state: seed)
        let rx = 18 * max(0.65, dx / largest) * (0.96 + 0.08 * random.unit())
        let rz = 18 * max(0.65, dz / largest) * (0.96 + 0.08 * random.unit())
        let rotation = random.unit() * 2 * Double.pi
        let c = cos(rotation), s = sin(rotation)
        let points = (0..<32).map { i -> TrackPoint in
            let angle = Double(i) * 2 * Double.pi / 32
            let sector = i / 4
            let fraction = Double(i % 4) / 4
            let blend = (1 - cos(fraction * Double.pi)) / 2
            let radius = 1 + contour[sector] * (1 - blend) + contour[(sector + 1) % 8] * blend
            let x = rx * radius * cos(angle), z = rz * radius * sin(angle)
            return TrackPoint(position: Vector3(x: ScanGeometry.quantize(x * c - z * s), y: 0,
                                                z: ScanGeometry.quantize(x * s + z * c)),
                              halfWidth: 0.65, isGate: i % 8 == 0)
        }
        let track = TrackDefinition(schemaVersion: 1, generatorVersion: "sector-contour-splitmix64-2",
                                    source: scan.source, seed: seed, rules: .standard, points: points)
        let issues = TrackValidator.validate(track)
        guard issues.isEmpty else { throw RoomwaveError.invalidTrack(issues.map(\.code).joined(separator: ",")) }
        return track
    }
}

/// SplitMix64, modulo 2^64; the high 53 bits map to [0,1) by division by 2^53.
/// These three draws affect layout; there is no decorative random stream.
private struct SplitMix64 {
    var state: UInt64
    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / 9007199254740992.0
    }
}
