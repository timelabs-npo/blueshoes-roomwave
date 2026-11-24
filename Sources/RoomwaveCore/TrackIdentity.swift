import Foundation
#if canImport(CryptoKit) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
import CryptoKit
#endif

public enum TrackIdentity {
    /// Canonical binary v1; see SCAN_READINESS.md for the exact field order.
    public static func canonicalData(for track: TrackDefinition) throws -> Data {
        let issues = TrackValidator.validate(track)
        guard issues.isEmpty else { throw RoomwaveError.invalidTrack(issues.map(\.code).joined(separator: ",")) }
        var bytes = Data("roomwave-track-identity-v1\0".utf8)
        func u64(_ value: UInt64) {
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        func string(_ value: String) {
            let utf8 = Array(value.utf8)
            let count = UInt32(utf8.count)
            for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: count >> shift)) }
            bytes.append(contentsOf: utf8)
        }
        func number(_ value: Double) { u64((value == 0 ? 0.0 : value).bitPattern) }
        func grid(_ value: Double) { u64(UInt64(bitPattern: Int64((value * 1000).rounded(.toNearestOrAwayFromZero)))) }
        u64(UInt64(track.schemaVersion)); string(track.generatorVersion); string(track.source.rawValue); u64(track.seed)
        let r = track.rules
        string(r.version); u64(UInt64(r.tickRate)); u64(UInt64(r.durationTicks))
        [r.initialSpeed, r.maximumSpeed, r.acceleration, r.steeringSpeed, r.bankSpeedFactor, r.multiplierGain].forEach(number)
        u64(UInt64(track.points.count))
        for point in track.points {
            grid(point.position.x); grid(point.position.y); grid(point.position.z); grid(point.halfWidth)
            bytes.append(point.isGate ? 1 : 0)
        }
        return bytes
    }

    public static func id(for track: TrackDefinition) throws -> String {
        let data = try canonicalData(for: track)
        #if canImport(CryptoKit) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        _ = data
        throw RoomwaveError.unsupportedPlatform("Track identity requires Apple CryptoKit SHA256")
        #endif
    }
}
