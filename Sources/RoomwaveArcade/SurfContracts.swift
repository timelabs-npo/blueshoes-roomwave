import Foundation

// Arcade v3 contract. Course distance is a game-space longitudinal coordinate,
// not a calibrated measurement of a photographed or scanned room.
public enum SurfBiome: String, Codable, CaseIterable, Sendable { case dawn, orbit, midnight }
public enum SurfSource: String, Codable, Sendable { case authored, daily, photoInspired, lidarInspired }
public enum SurfPhase: String, Codable, Sendable { case running, finished, crashed }
public enum SurfEncounterKind: String, Codable, Sendable { case ring, barrier, ceiling, boost }
public enum SurfMedal: String, Codable, Sendable { case none, bronze, silver, gold }
public enum SurfEventKind: String, Codable, Sendable {
    case takeoff, landing, perfectLanding, ring, boost, nearMiss, hit, comboLost, finish
}
public enum SurfError: Error, Equatable, Sendable {
    case invalidCourse(String), invalidInput(String), replayMismatch(String)
}

public struct SurfVector: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

public struct SurfCourseSample: Codable, Equatable, Sendable {
    public let distance: Double
    public let center: SurfVector
    public let width: Double
    public init(distance: Double, center: SurfVector, width: Double = 7) {
        self.distance = distance; self.center = center; self.width = width
    }
}

public struct SurfEncounter: Codable, Equatable, Sendable {
    public let id: Int
    public let kind: SurfEncounterKind
    public let distance: Double
    /// Center height above the road; the rider's foot height is the simulation coordinate.
    public let height: Double
    public let halfHeight: Double
    public let points: Int
    public init(id: Int, kind: SurfEncounterKind, distance: Double, height: Double,
                halfHeight: Double, points: Int = 100) {
        self.id = id; self.kind = kind; self.distance = distance; self.height = height
        self.halfHeight = halfHeight; self.points = points
    }
}

public struct SurfCourseDefinition: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let title: String
    public let subtitle: String
    public let biome: SurfBiome
    public let source: SurfSource
    public let seed: UInt64
    public let samples: [SurfCourseSample]
    public let encounters: [SurfEncounter]
    /// Ordered bronze / silver / gold thresholds for completed runs.
    public let medalScores: [Int]
    public init(id: String, title: String, subtitle: String, biome: SurfBiome,
                source: SurfSource = .authored, seed: UInt64, samples: [SurfCourseSample],
                encounters: [SurfEncounter], medalScores: [Int], schemaVersion: Int = 3) {
        self.schemaVersion = schemaVersion; self.id = id; self.title = title; self.subtitle = subtitle
        self.biome = biome; self.source = source; self.seed = seed; self.samples = samples
        self.encounters = encounters; self.medalScores = medalScores
    }
}

public struct CompiledSurfCourse: Sendable {
    public let definition: SurfCourseDefinition
    public var length: Double { definition.samples.last?.distance ?? 0 }
    // Only the validated compiler path inside this module constructs this type.
    init(validatedDefinition: SurfCourseDefinition) { definition = validatedDefinition }
}

public struct SurfPose: Equatable, Sendable {
    public let center: SurfVector
    public let forward: SurfVector
    public let slope: Double
    public let width: Double
    public init(center: SurfVector, forward: SurfVector, slope: Double, width: Double) {
        self.center = center; self.forward = forward; self.slope = slope; self.width = width
    }
}

public struct SurfRules: Codable, Equatable, Sendable {
    public let version: String
    public let tickRate: Int
    public let maximumTicks: Int
    public let startingSpeed: Double
    public let minimumSpeed: Double
    public let maximumSpeed: Double
    public let gravity: Double
    public let pressedGravity: Double
    public let maximumCharge: Double
    public init(version: String = "roomwave-surf-3", tickRate: Int = 60, maximumTicks: Int = 9000,
                startingSpeed: Double = 16, minimumSpeed: Double = 10, maximumSpeed: Double = 30,
                gravity: Double = 14, pressedGravity: Double = 30, maximumCharge: Double = 1) {
        self.version = version; self.tickRate = tickRate; self.maximumTicks = maximumTicks
        self.startingSpeed = startingSpeed; self.minimumSpeed = minimumSpeed
        self.maximumSpeed = maximumSpeed; self.gravity = gravity
        self.pressedGravity = pressedGravity; self.maximumCharge = maximumCharge
    }
    public static let standard = SurfRules()
}

public struct SurfInput: Codable, Equatable, Sendable {
    public let tick: Int
    public let pressed: Bool
    /// Explicit interruption cancellation is recorded, so a resumed run does not
    /// turn a cleared finger into an unintended release/launch edge.
    public let cancelled: Bool
    public init(tick: Int, pressed: Bool, cancelled: Bool = false) {
        self.tick = tick; self.pressed = pressed; self.cancelled = cancelled
    }
}

public struct SurfState: Codable, Equatable, Sendable {
    public var tick: Int
    public var phase: SurfPhase
    public var distance: Double
    public var speed: Double
    /// Absolute rider-foot elevation, not height above the current road.
    public var height: Double
    public var verticalSpeed: Double
    public var grounded: Bool
    public var charge: Double
    public var score: Int
    public var combo: Int
    public var bestCombo: Int
    public var shields: Int
    public var rings: Int
    public var perfectLandings: Int
    public var previousPressed: Bool
    public var invulnerabilityTicks: Int
    public var encounterCursor: Int
    public var airtimeTicks: Int
    public init(tick: Int = 0, phase: SurfPhase = .running, distance: Double = 0,
                speed: Double = 16, height: Double = 0, verticalSpeed: Double = 0,
                grounded: Bool = true, charge: Double = 0, score: Int = 0,
                combo: Int = 0, bestCombo: Int = 0, shields: Int = 3, rings: Int = 0,
                perfectLandings: Int = 0, previousPressed: Bool = false,
                invulnerabilityTicks: Int = 0, encounterCursor: Int = 0, airtimeTicks: Int = 0) {
        self.tick = tick; self.phase = phase; self.distance = distance; self.speed = speed
        self.height = height; self.verticalSpeed = verticalSpeed; self.grounded = grounded
        self.charge = charge; self.score = score; self.combo = combo; self.bestCombo = bestCombo
        self.shields = shields; self.rings = rings; self.perfectLandings = perfectLandings
        self.previousPressed = previousPressed; self.invulnerabilityTicks = invulnerabilityTicks
        self.encounterCursor = encounterCursor; self.airtimeTicks = airtimeTicks
    }
}

public struct SurfEvent: Codable, Equatable, Sendable {
    public let tick: Int
    public let kind: SurfEventKind
    public let value: Int
    public let intensity: Double
    public init(tick: Int, kind: SurfEventKind, value: Int = 0, intensity: Double = 1) {
        self.tick = tick; self.kind = kind; self.value = value; self.intensity = intensity
    }
}

public struct SurfStep: Equatable, Sendable {
    public let state: SurfState
    public let events: [SurfEvent]
    public init(state: SurfState, events: [SurfEvent]) { self.state = state; self.events = events }
}

public struct SurfRunResult: Codable, Equatable, Sendable {
    public let courseID: String
    public let rulesVersion: String
    public let score: Int
    public let seconds: Double
    public let rings: Int
    public let perfectLandings: Int
    public let bestCombo: Int
    public let completed: Bool
    public let medal: SurfMedal
    public init(courseID: String, rulesVersion: String, score: Int, seconds: Double,
                rings: Int, perfectLandings: Int, bestCombo: Int, completed: Bool, medal: SurfMedal) {
        self.courseID = courseID; self.rulesVersion = rulesVersion; self.score = score
        self.seconds = seconds; self.rings = rings; self.perfectLandings = perfectLandings
        self.bestCombo = bestCombo; self.completed = completed; self.medal = medal
    }
}

public struct SurfReplay: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let courseID: String
    public let seed: UInt64
    public let rulesVersion: String
    public let inputs: [SurfInput]
    public let finalState: SurfState
    public init(courseID: String, seed: UInt64, rulesVersion: String, inputs: [SurfInput],
                finalState: SurfState, schemaVersion: Int = 3) {
        self.schemaVersion = schemaVersion; self.courseID = courseID; self.seed = seed
        self.rulesVersion = rulesVersion; self.inputs = inputs; self.finalState = finalState
    }
}
