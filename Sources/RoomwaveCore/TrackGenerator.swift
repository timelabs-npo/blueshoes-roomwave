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
        // Only a coarse, clamped aspect ratio survives. This is not reconstruction.
        var random = SplitMix64(state: seed)
        let rx = 18 * max(0.65, dx / largest) * (0.96 + 0.08 * random.unit())
        let rz = 18 * max(0.65, dz / largest) * (0.96 + 0.08 * random.unit())
        let rotation = random.unit() * 2 * Double.pi
        let c = cos(rotation), s = sin(rotation)
        let points = (0..<32).map { i -> TrackPoint in
            let angle = Double(i) * 2 * Double.pi / 32
            let x = rx * cos(angle), z = rz * sin(angle)
            return TrackPoint(position: Vector3(x: ScanGeometry.quantize(x * c - z * s), y: 0,
                                                z: ScanGeometry.quantize(x * s + z * c)),
                              halfWidth: 0.65, isGate: i % 8 == 0)
        }
        let track = TrackDefinition(schemaVersion: 1, generatorVersion: "coarse-ellipse-splitmix64-1",
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
