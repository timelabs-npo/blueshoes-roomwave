import Foundation

public enum ScanNormalizer {
    /// Local intermediate only. No capture identifier survives normalization.
    public static func normalize(_ sample: ScanSample) throws -> NormalizedScan {
        guard (3...4096).contains(sample.points.count) else {
            throw RoomwaveError.invalidScan("Expected 3...4096 points")
        }
        guard sample.points.allSatisfy({ p in
            [p.x, p.y, p.z].allSatisfy { $0.isFinite && abs($0) <= 1000 }
        }) else { throw RoomwaveError.invalidScan("Nonfinite or out-of-bounds coordinates") }
        let xs = sample.points.map(\.x), ys = sample.points.map(\.y), zs = sample.points.map(\.z)
        let lo = Vector3(x: xs.min()!, y: ys.min()!, z: zs.min()!)
        let hi = Vector3(x: xs.max()!, y: ys.max()!, z: zs.max()!)
        let spans = [hi.x - lo.x, hi.y - lo.y, hi.z - lo.z]
        guard spans.allSatisfy({ $0 <= 100 }), max(spans[0], spans[2]) >= 0.05 else {
            throw RoomwaveError.invalidScan("Extent must be at most 100; horizontal extent at least 0.05")
        }
        let scale = spans.max()! / 2
        let points = sample.points.map {
            Vector3(x: ($0.x - (lo.x + hi.x) / 2) / scale,
                    y: ($0.y - (lo.y + hi.y) / 2) / scale,
                    z: ($0.z - (lo.z + hi.z) / 2) / scale)
        }
        try ScanGeometry.requireArea(points)
        return NormalizedScan(source: sample.source, normalizationVersion: 1, points: points)
    }
}

// Internal helpers, not additional shared models or public contract.
enum ScanGeometry {
    static func requireArea(_ points: [Vector3]) throws {
        let n = Double(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n
        let mz = points.reduce(0) { $0 + $1.z } / n
        var xx = 0.0, zz = 0.0, xz = 0.0
        for p in points {
            let x = p.x - mx, z = p.z - mz
            xx += x * x; zz += z * z; xz += x * z
        }
        let trace = xx + zz
        guard trace > 1e-8, xx * zz - xz * xz > trace * trace * 1e-6 else {
            throw RoomwaveError.invalidScan("Horizontal points are degenerate or nearly collinear")
        }
    }

    static func quantize(_ value: Double) -> Double {
        let result = (value * 1000).rounded(.toNearestOrAwayFromZero) / 1000
        return result == 0 ? 0 : result
    }
}
