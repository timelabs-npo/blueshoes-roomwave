/// Presentation-only guidance derived from the same input/state as actual play.
public enum SurfTutorialCue: Equatable, Sendable {
    case charge, release, dive, releaseBeforeLanding
}

public enum SurfTutorialGuidance {
    public static func cue(state: SurfState, pressed: Bool, cancellationPending: Bool,
                           course: CompiledSurfCourse, rules: SurfRules = .standard) -> SurfTutorialCue? {
        guard state.phase == .running else { return nil }
        if !state.grounded {
            return pressed && !cancellationPending ? .releaseBeforeLanding : .dive
        }
        guard pressed, !cancellationPending, state.previousPressed else { return .charge }
        // Predict only the release affordance on a value copy. Do not duplicate
        // the simulation's charge threshold or mutate/record a synthetic input.
        let released = try? SurfSimulation.step(state: state,
            input: SurfInput(tick: state.tick, pressed: false), course: course, rules: rules)
        return released?.events.contains(where: { $0.kind == .takeoff }) == true ? .release : .charge
    }

    public static func observedCleanLanding(in events: [SurfEvent]) -> Bool {
        // Ordinary .landing also represents rough impacts. Only the core's
        // explicit clean-landing reward establishes completion of this lesson.
        events.contains { $0.kind == .perfectLanding }
    }
}
