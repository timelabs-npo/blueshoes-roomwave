import Foundation

// Frozen public data contract. Source markers are provenance labels, not remote attestation.
public enum ScanSource: String, Codable, Sendable { case synthetic, arkitMesh, photoDerived }
public enum RaceStatus: String, Codable, Sendable { case running, finished, crashed }
public enum RoomwaveError: Error, Equatable, Sendable {
    case invalidScan(String)
    case invalidTrack(String)
    case invalidInput(String)
    case replayMismatch(String)
    case unsupportedPlatform(String)
}

public struct Vector3: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct ScanSample: Codable, Equatable, Sendable {
    public let captureID: String
    public let source: ScanSource
    public let points: [Vector3]

    public init(captureID: String, source: ScanSource, points: [Vector3]) {
        self.captureID = captureID
        self.source = source
        self.points = points
    }
}

public struct NormalizedScan: Codable, Equatable, Sendable {
    public let source: ScanSource
    public let normalizationVersion: Int
    public let points: [Vector3]

    public init(source: ScanSource, normalizationVersion: Int, points: [Vector3]) {
        self.source = source
        self.normalizationVersion = normalizationVersion
        self.points = points
    }
}

public struct TrackPoint: Codable, Equatable, Sendable {
    public let position: Vector3
    public let halfWidth: Double
    public let isGate: Bool

    public init(position: Vector3, halfWidth: Double, isGate: Bool) {
        self.position = position
        self.halfWidth = halfWidth
        self.isGate = isGate
    }
}

public struct RaceRules: Codable, Equatable, Sendable {
    public let version: String
    public let tickRate: Int
    public let durationTicks: Int
    public let initialSpeed: Double
    public let maximumSpeed: Double
    public let acceleration: Double
    public let steeringSpeed: Double
    public let bankSpeedFactor: Double
    public let multiplierGain: Double

    public init(version: String, tickRate: Int, durationTicks: Int, initialSpeed: Double, maximumSpeed: Double, acceleration: Double, steeringSpeed: Double, bankSpeedFactor: Double, multiplierGain: Double) {
        self.version = version
        self.tickRate = tickRate
        self.durationTicks = durationTicks
        self.initialSpeed = initialSpeed
        self.maximumSpeed = maximumSpeed
        self.acceleration = acceleration
        self.steeringSpeed = steeringSpeed
        self.bankSpeedFactor = bankSpeedFactor
        self.multiplierGain = multiplierGain
    }
}

public struct TrackDefinition: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatorVersion: String
    public let source: ScanSource
    public let seed: UInt64
    public let rules: RaceRules
    public let points: [TrackPoint]

    public init(schemaVersion: Int, generatorVersion: String, source: ScanSource, seed: UInt64, rules: RaceRules, points: [TrackPoint]) {
        self.schemaVersion = schemaVersion
        self.generatorVersion = generatorVersion
        self.source = source
        self.seed = seed
        self.rules = rules
        self.points = points
    }
}

public struct RaceInput: Codable, Equatable, Sendable {
    public let tick: Int
    public let steering: Double
    public let bank: Bool

    public init(tick: Int, steering: Double, bank: Bool) {
        self.tick = tick
        self.steering = steering
        self.bank = bank
    }
}

public struct RaceState: Codable, Equatable, Sendable {
    public let tick: Int
    public let distance: Double
    public let lateralOffset: Double
    public let speed: Double
    public let bankedScore: Double
    public let unbankedScore: Double
    public let multiplier: Double
    public let status: RaceStatus

    public init(tick: Int, distance: Double, lateralOffset: Double, speed: Double, bankedScore: Double, unbankedScore: Double, multiplier: Double, status: RaceStatus) {
        self.tick = tick
        self.distance = distance
        self.lateralOffset = lateralOffset
        self.speed = speed
        self.bankedScore = bankedScore
        self.unbankedScore = unbankedScore
        self.multiplier = multiplier
        self.status = status
    }
}

public struct ReplayRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let trackID: String
    public let inputs: [RaceInput]
    public let keyframes: [RaceState]
    public let finalState: RaceState

    public init(schemaVersion: Int, trackID: String, inputs: [RaceInput], keyframes: [RaceState], finalState: RaceState) {
        self.schemaVersion = schemaVersion
        self.trackID = trackID
        self.inputs = inputs
        self.keyframes = keyframes
        self.finalState = finalState
    }
}

public struct ChallengeDescriptor: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let trackID: String
    public let track: TrackDefinition

    public init(schemaVersion: Int, trackID: String, track: TrackDefinition) {
        self.schemaVersion = schemaVersion
        self.trackID = trackID
        self.track = track
    }
}

public struct RaceScore: Codable, Equatable, Sendable {
    public let trackID: String
    public let points: Double
    public let ticks: Int

    public init(trackID: String, points: Double, ticks: Int) {
        self.trackID = trackID
        self.points = points
        self.ticks = ticks
    }
}

public struct CreatorReputation: Codable, Equatable, Sendable {
    public let completedChallenges: Int
    public let uniqueChallengers: Int

    public init(completedChallenges: Int, uniqueChallengers: Int) {
        self.completedChallenges = completedChallenges
        self.uniqueChallengers = uniqueChallengers
    }
}

public struct ValidationIssue: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public extension RaceRules {
    static let standard = RaceRules(
        version: "roomwave-pilot-2", tickRate: 60, durationTicks: 5400,
        initialSpeed: 4, maximumSpeed: 12, acceleration: 0.10,
        steeringSpeed: 3, bankSpeedFactor: 0.75, multiplierGain: 0.25
    )
}
