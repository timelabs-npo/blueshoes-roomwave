import Foundation

public enum TrackValidator {
    /// Static planar geometry checks; not a full vehicle dynamics/reachability proof.
    public static func validate(_ track: TrackDefinition) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func issue(_ code: String, _ message: String) { issues.append(ValidationIssue(code: code, message: message)) }
        if track.schemaVersion != 1 || track.generatorVersion.isEmpty || track.generatorVersion.utf8.count > 128 {
            issue("version", "Unsupported schema or invalid generator version")
        }
        let r = track.rules
        let numbers = [r.initialSpeed, r.maximumSpeed, r.acceleration, r.steeringSpeed, r.bankSpeedFactor, r.multiplierGain]
        if r.version.isEmpty || r.version.utf8.count > 128 || !(1...240).contains(r.tickRate)
            || !(1...864000).contains(r.durationTicks) || !numbers.allSatisfy({ $0.isFinite })
            || r.initialSpeed <= 0 || r.maximumSpeed < r.initialSpeed || r.maximumSpeed > 100
            || r.acceleration < 0 || r.acceleration > 100 || r.steeringSpeed <= 0 || r.steeringSpeed > 100
            || r.bankSpeedFactor <= 0 || r.bankSpeedFactor > 1 || r.multiplierGain <= 0 || r.multiplierGain > 10 {
            issue("rules", "Invalid timing, speed, steering, banking, multiplier or rule version")
        }
        guard (3...256).contains(track.points.count) else {
            issue("pointCount", "Expected 3...256 route points")
            return issues
        }
        var usable = true
        for (i, p) in track.points.enumerated() {
            let values = [p.position.x, p.position.y, p.position.z, p.halfWidth]
            guard values.allSatisfy({ $0.isFinite }) else {
                issue("nonfinite", "Point \(i) contains a nonfinite value"); usable = false; continue
            }
            if abs(p.position.x) > 100 || abs(p.position.z) > 100 || p.position.y != 0
                || p.halfWidth < 0.25 || p.halfWidth > 5 {
                issue("bounds", "Point \(i) violates planar coordinate or width bounds"); usable = false
            }
            if values.contains(where: { $0 != ScanGeometry.quantize($0) }) {
                issue("quantization", "Point \(i) must be finalized on a 0.001 game-unit grid")
            }
        }
        if !track.points.contains(where: \.isGate) { issue("gates", "At least one gate is required") }
        guard usable else { return issues }
        let n = track.points.count
        for i in 0..<n {
            let previous = track.points[(i + n - 1) % n].position
            let a = track.points[i], b = track.points[(i + 1) % n]
            let ux = a.position.x - previous.x, uz = a.position.z - previous.z
            let vx = b.position.x - a.position.x, vz = b.position.z - a.position.z
            let incoming = hypot(ux, uz), outgoing = hypot(vx, vz)
            if outgoing < max(0.1, 1.5 * max(a.halfWidth, b.halfWidth)) {
                issue("spacing", "Segment \(i) is zero-length or too short for its width")
            }
            if incoming > 0, outgoing > 0 {
                let cosine = max(-1, min(1, (ux * vx + uz * vz) / (incoming * outgoing)))
                if acos(cosine) > 0.75 * Double.pi { issue("curvature", "Excessive turn at point \(i)") }
            }
            for j in (i + 1)..<n where j != (i + 1) % n && (j + 1) % n != i {
                let c = track.points[j], d = track.points[(j + 1) % n]
                let clearance = max(a.halfWidth, b.halfWidth) + max(c.halfWidth, d.halfWidth)
                if segmentDistance(a.position, b.position, c.position, d.position) <= clearance {
                    issue("clearance", "Nonadjacent segments \(i) and \(j) intersect or have insufficient clearance")
                }
            }
        }
        return issues
    }

    private static func segmentDistance(_ a: Vector3, _ b: Vector3, _ c: Vector3, _ d: Vector3) -> Double {
        func cross(_ p: Vector3, _ q: Vector3, _ r: Vector3) -> Double {
            (q.x - p.x) * (r.z - p.z) - (q.z - p.z) * (r.x - p.x)
        }
        func distance(_ p: Vector3, _ q: Vector3, _ r: Vector3) -> Double {
            let x = r.x - q.x, z = r.z - q.z, length2 = x * x + z * z
            let t = length2 == 0 ? 0 : max(0, min(1, ((p.x - q.x) * x + (p.z - q.z) * z) / length2))
            return hypot(p.x - q.x - t * x, p.z - q.z - t * z)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if ((abC > 0 && abD < 0) || (abC < 0 && abD > 0))
            && ((cdA > 0 && cdB < 0) || (cdA < 0 && cdB > 0)) { return 0 }
        return min(distance(a, c, d), distance(b, c, d), distance(c, a, b), distance(d, a, b))
    }
}
