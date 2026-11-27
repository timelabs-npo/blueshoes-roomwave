import Foundation

/// An opt-in authored sprint. Nothing here changes the daily course or the scoring contract.
public enum SurfAfterglow {
    public static let id = "afterglow-cistern"
    public static let finalRingDistance = 536.0
    public static let landingWindow = 50.0

    public static let course: SurfCourseDefinition = {
        let samples = stride(from: 0, through: 612, by: 6).map { metre in
            let d = Double(metre)
            let x = 8 * sin(d * .pi / 107) + 4 * sin(d * .pi / 221)
            let y = 1.3 * sin(d * .pi / 81) + 2.2 * sin(d * .pi / 190)
            return SurfCourseSample(distance: d, center: SurfVector(x: x, y: y, z: -d), width: 8)
        }
        func e(_ id: Int, _ kind: SurfEncounterKind, _ d: Double, _ h: Double,
               _ aperture: Double, _ points: Int) -> SurfEncounter {
            SurfEncounter(id: id, kind: kind, distance: d, height: h, halfHeight: aperture, points: points)
        }
        return SurfCourseDefinition(id: id, title: "AFTERGLOW CISTERN",
            subtitle: "SPRINT · Ride low to finish, or catch the crown and land clean.",
            biome: .midnight, seed: 681, samples: samples, encounters: [
                e(0, .ring, 62, 3.6, 2.5, 120),
                e(1, .boost, 124, 0.5, 0.45, 50),
                e(2, .ring, 210, 4.2, 2.1, 160),
                e(3, .boost, 260, 0.5, 0.45, 50),
                e(4, .ring, 319, 4.9, 1.7, 180),
                e(5, .ceiling, 341, 4.6, 1.3, 80),
                e(6, .boost, 399, 0.5, 0.45, 50),
                e(7, .ring, finalRingDistance, 5.0, 1.65, 340),
                e(8, .boost, 597, 0.5, 0.45, 50)
            ], medalScores: [300, 700, 1_250])
    }()

    /// Presentation consequence of play only, derived from the exact simulation step.
    /// Never touches score, event identity, persisted results, or sharing eligibility.
    public struct Finale: Equatable, Sendable {
        private var crownArmed = false
        public private(set) var caughtCrown = false
        public private(set) var earned = false
        public init() {}

        /// True for the one step that earns a celebration. Ring and landing planes are far
        /// enough apart that multiple ring events cannot be confused on a single fixed tick.
        public mutating func observe(courseID: String, previous: SurfState, step: SurfStep) -> Bool {
            guard courseID == SurfAfterglow.id, !earned, previous.phase == .running else { return false }
            let distance = SurfAfterglow.finalRingDistance
            if step.state.phase == .crashed || step.events.contains(where: { $0.kind == .hit }) {
                crownArmed = false
                return false
            }
            if previous.distance < distance, step.state.distance >= distance,
               step.events.contains(where: { $0.kind == .ring }) {
                crownArmed = true
                caughtCrown = true
            }
            guard crownArmed else { return false }
            guard step.state.distance <= distance + SurfAfterglow.landingWindow else {
                crownArmed = false
                return false
            }
            guard let landing = step.events.first(where: { $0.kind == .landing }) else { return false }
            crownArmed = false
            guard step.events.contains(where: { $0.kind == .perfectLanding && $0.tick == landing.tick }) else {
                return false
            }
            earned = true
            return true
        }
    }
}
