import Foundation

/// Fixed-tick local deterministic simulation. This is not a server attestation protocol.
public enum SurfSimulation {
    private static let scoreLimit = 1_000_000_000
    private static let counterLimit = 1_000_000
    private static let comboLimit = 10_000

    private static func validRules(_ r: SurfRules) -> Bool {
        !r.version.isEmpty && r.version.utf8.count <= 80 && (30...240).contains(r.tickRate)
        && (1...216_000).contains(r.maximumTicks)
        && r.minimumSpeed.isFinite && r.startingSpeed.isFinite && r.maximumSpeed.isFinite
        && r.minimumSpeed >= 0.5 && r.maximumSpeed <= 120 && r.minimumSpeed <= r.startingSpeed
        && r.startingSpeed <= r.maximumSpeed
        && r.gravity.isFinite && r.pressedGravity.isFinite && (2...100).contains(r.gravity)
        && r.pressedGravity > r.gravity && r.pressedGravity <= 200
        && r.maximumCharge.isFinite && (0.1...5).contains(r.maximumCharge)
    }

    private static func validate(_ s: SurfState, course: CompiledSurfCourse, rules r: SurfRules) throws {
        guard validRules(r) else { throw SurfError.invalidInput("Invalid rules") }
        guard (0...r.maximumTicks).contains(s.tick),
              s.distance.isFinite, (0...course.length).contains(s.distance),
              s.speed.isFinite, (r.minimumSpeed...r.maximumSpeed).contains(s.speed),
              s.height.isFinite, s.verticalSpeed.isFinite, (-200...100).contains(s.verticalSpeed),
              s.charge.isFinite, (0...r.maximumCharge).contains(s.charge),
              (0...scoreLimit).contains(s.score), (0...comboLimit).contains(s.combo),
              (s.combo...comboLimit).contains(s.bestCombo), (0...3).contains(s.shields),
              (0...counterLimit).contains(s.rings), (0...counterLimit).contains(s.perfectLandings),
              (0...(r.tickRate * 2)).contains(s.invulnerabilityTicks),
              (0...course.definition.encounters.count).contains(s.encounterCursor),
              (0...r.maximumTicks).contains(s.airtimeTicks) else { throw SurfError.invalidInput("Invalid state bounds") }
        let road = course.pose(at: s.distance).center.y
        guard s.height >= road - 0.000_001, s.height <= road + 128,
              !s.grounded || (abs(s.height - road) <= 0.000_001 && s.verticalSpeed == 0 && s.airtimeTicks == 0),
              s.grounded || s.charge == 0 else { throw SurfError.invalidInput("Invalid rider geometry") }
        let encounters = course.definition.encounters
        guard (s.encounterCursor == 0 || encounters[s.encounterCursor - 1].distance <= s.distance),
              (s.encounterCursor == encounters.count || encounters[s.encounterCursor].distance > s.distance) else {
            throw SurfError.invalidInput("Encounter cursor disagrees with progress")
        }
        switch s.phase {
        case .running:
            guard s.tick < r.maximumTicks, s.distance < course.length, s.shields > 0 else {
                throw SurfError.invalidInput("Running state is terminal")
            }
        case .finished:
            guard s.distance == course.length, s.shields > 0 else { throw SurfError.invalidInput("Invalid finish") }
        case .crashed:
            guard s.shields == 0 || s.tick == r.maximumTicks else { throw SurfError.invalidInput("Invalid crash") }
        }
    }

    public static func start(course: CompiledSurfCourse, rules: SurfRules = .standard) -> SurfState {
        let road = course.pose(at: 0).center.y
        guard validRules(rules) else {
            return SurfState(phase: .crashed, speed: 0, height: road, shields: 0)
        }
        return SurfState(speed: rules.startingSpeed, height: road)
    }

    public static func step(state: SurfState, input: SurfInput, course: CompiledSurfCourse,
                            rules: SurfRules = .standard) throws -> SurfStep {
        try validate(state, course: course, rules: rules)
        guard input.tick == state.tick else { throw SurfError.invalidInput("Input tick must equal state tick") }
        guard state.phase == .running else { return SurfStep(state: state, events: []) }
        var s = state
        s.tick += 1
        if input.cancelled {
            s.charge = 0
            s.previousPressed = false
        }
        s.invulnerabilityTicks = max(0, s.invulnerabilityTicks - 1)
        let dt = 1 / Double(rules.tickRate)
        let oldPose = course.pose(at: state.distance)
        var events: [SurfEvent] = []
        func emit(_ kind: SurfEventKind, _ value: Int = 0, _ intensity: Double = 1) {
            events.append(SurfEvent(tick: s.tick, kind: kind, value: value, intensity: intensity))
        }
        func loseCombo() {
            if s.combo > 0 { emit(.comboLost, s.combo); s.combo = 0 }
        }
        func reward(_ base: Int) -> Int {
            s.combo = min(comboLimit, s.combo + 1)
            s.bestCombo = max(s.bestCombo, s.combo)
            let earned = min(scoreLimit - s.score, base * (1 + min(4, s.combo / 4)))
            s.score += earned
            return earned
        }
        func clampSpeed(_ value: Double) -> Double { min(rules.maximumSpeed, max(rules.minimumSpeed, value)) }

        // Mild return toward cruise; uphill costs momentum, downhill restores it.
        let cruise = min(rules.maximumSpeed, max(rules.minimumSpeed, 18.0))
        s.speed = clampSpeed(s.speed + ((cruise - s.speed) * 0.12 - oldPose.slope * 8 - (s.grounded && input.pressed ? 0.6 : 0)) * dt)
        if s.grounded {
            if input.pressed {
                s.charge = min(rules.maximumCharge, s.charge + rules.maximumCharge * dt / 0.65)
            } else if s.previousPressed && s.charge >= rules.maximumCharge * 0.22 {
                let compression = s.charge / rules.maximumCharge
                s.verticalSpeed = min(18, max(4, 5 + compression * 8 + oldPose.slope * s.speed * 0.5))
                s.speed = clampSpeed(s.speed + compression * 1.1 + max(0, -oldPose.slope) * 2)
                s.grounded = false
                s.charge = 0
                emit(.takeoff, 0, compression)
            } else {
                s.charge = max(0, s.charge - rules.maximumCharge * dt * 2)
            }
        }

        s.distance = min(course.length, s.distance + s.speed * dt)
        let newPose = course.pose(at: s.distance)
        var landingFraction: Double?
        var landingImpact = 0.0
        let flightVelocity = s.verticalSpeed
        let flightGravity = input.pressed ? rules.pressedGravity : rules.gravity
        var flightEnd = state.height
        if !s.grounded {
            flightEnd = state.height + flightVelocity * dt - flightGravity * dt * dt * 0.5
            s.verticalSpeed = max(-180, flightVelocity - flightGravity * dt)
            s.airtimeTicks = min(rules.maximumTicks, s.airtimeTicks + 1)
            let relativeVelocity = s.verticalSpeed - (newPose.center.y - oldPose.center.y) / dt
            if flightEnd <= newPose.center.y && relativeVelocity <= 0 {
                // Solve the ballistic crossing against this tick's road segment. Using endpoint
                // height interpolation shifts narrow rewards and collision timing under a dive.
                let gap = max(0, state.height - oldPose.center.y)
                let roadVelocity = (newPose.center.y - oldPose.center.y) / dt
                let relativeStartVelocity = flightVelocity - roadVelocity
                let root = (relativeStartVelocity * relativeStartVelocity + 2 * flightGravity * gap).squareRoot()
                let contactTime = relativeStartVelocity < 0
                    ? 2 * gap / max(0.000_001, root - relativeStartVelocity)
                    : (relativeStartVelocity + root) / flightGravity
                let boundedContactTime = min(dt, max(0, contactTime))
                landingFraction = boundedContactTime / dt
                landingImpact = flightVelocity - flightGravity * boundedContactTime - roadVelocity
                s.height = newPose.center.y
                s.grounded = true
                s.verticalSpeed = 0
            } else {
                // Terrain can rise into an ascending rider; it catches the foot rather than burying it.
                s.height = min(newPose.center.y + 128, max(newPose.center.y, flightEnd))
            }
        } else {
            s.height = newPose.center.y
            flightEnd = s.height
        }
        var landingPending = landingFraction != nil
        func land() {
            guard landingPending else { return }
            landingPending = false
            guard s.shields > 0 else { s.airtimeTicks = 0; return }
            let clean = !input.pressed && landingImpact >= -16 && landingImpact <= -2
                && s.airtimeTicks >= rules.tickRate / 3
            emit(.landing, 0, clean ? 0.35 : 1)
            if clean {
                s.perfectLandings = min(counterLimit, s.perfectLandings + 1)
                let points = reward(150)
                s.speed = clampSpeed(s.speed + 1.3)
                emit(.perfectLanding, points, 0.8)
            } else {
                loseCombo()
                s.speed = clampSpeed(s.speed * 0.78)
            }
            s.airtimeTicks = 0
        }

        // The cursor and crossing interpolation handle every plane, including several in one tick.
        let encounters = course.definition.encounters
        while s.encounterCursor < encounters.count && encounters[s.encounterCursor].distance <= s.distance {
            let encounter = encounters[s.encounterCursor]
            if s.shields == 0 { s.encounterCursor += 1; continue }
            let fraction = (encounter.distance - state.distance) / max(0.000_001, s.distance - state.distance)
            if let landing = landingFraction, landing <= fraction { land() }
            let road = course.pose(at: encounter.distance).center.y
            let foot: Double
            if state.grounded && landingFraction == nil && s.grounded {
                foot = road
            } else if let landing = landingFraction, fraction >= landing {
                foot = road
            } else {
                let crossingTime = dt * fraction
                let crossingHeight = state.height + flightVelocity * crossingTime
                    - flightGravity * crossingTime * crossingTime * 0.5
                foot = min(road + 128, max(road, crossingHeight))
            }
            let lower = road + encounter.height - encounter.halfHeight
            let upper = road + encounter.height + encounter.halfHeight
            switch encounter.kind {
            case .ring:
                if abs(foot + 0.5 - (road + encounter.height)) <= encounter.halfHeight {
                    s.rings = min(counterLimit, s.rings + 1)
                    let points = reward(encounter.points)
                    emit(.ring, points)
                }
            case .boost:
                if foot + 0.9 >= lower && foot + 0.1 <= upper {
                    s.speed = clampSpeed(s.speed + 3)
                    // Boost is momentum only; passive ground travel cannot farm score/combo.
                    emit(.boost, 0, 0.75)
                }
            case .barrier, .ceiling:
                let intersects = foot + 0.9 >= lower && foot + 0.1 <= upper
                if intersects && s.invulnerabilityTicks == 0 {
                    s.shields -= 1
                    s.invulnerabilityTicks = rules.tickRate
                    s.speed = clampSpeed(s.speed * 0.65)
                    loseCombo()
                    emit(.hit, s.shields)
                } else if !intersects {
                    let separation = max(lower - (foot + 0.9), (foot + 0.1) - upper)
                    if separation < 0.65 && foot > road + 0.05 {
                        let points = reward(40)
                        emit(.nearMiss, points, 0.6)
                    }
                }
            }
            s.encounterCursor += 1
        }
        land()
        if s.grounded { s.airtimeTicks = 0 }
        s.previousPressed = input.pressed
        if s.shields == 0 {
            s.phase = .crashed
        } else if s.distance >= course.length {
            s.phase = .finished
            emit(.finish, s.score)
        } else if s.tick >= rules.maximumTicks {
            s.phase = .crashed
            loseCombo()
        }
        return SurfStep(state: s, events: events)
    }

    public static func result(state: SurfState, course: CompiledSurfCourse,
                              rules: SurfRules = .standard) -> SurfRunResult {
        let valid = (try? validate(state, course: course, rules: rules)) != nil
        let completed = valid && state.phase == .finished
        let score = min(scoreLimit, max(0, state.score))
        let thresholds = course.definition.medalScores
        let medal: SurfMedal = !completed ? .none : score >= thresholds[2] ? .gold
            : score >= thresholds[1] ? .silver : score >= thresholds[0] ? .bronze : .none
        let tickRate = validRules(rules) ? rules.tickRate : SurfRules.standard.tickRate
        return SurfRunResult(courseID: course.definition.id, rulesVersion: String(rules.version.prefix(80)),
                             score: score, seconds: Double(min(216_000, max(0, state.tick))) / Double(tickRate),
                             rings: min(counterLimit, max(0, state.rings)),
                             perfectLandings: min(counterLimit, max(0, state.perfectLandings)),
                             bestCombo: min(comboLimit, max(0, state.bestCombo)), completed: completed, medal: medal)
    }

    public static func verify(replay: SurfReplay, course: CompiledSurfCourse,
                              rules: SurfRules = .standard) throws -> SurfState {
        guard validRules(rules) else { throw SurfError.invalidInput("Invalid rules") }
        guard replay.schemaVersion == 3, replay.courseID == course.definition.id,
              replay.seed == course.definition.seed, replay.rulesVersion == rules.version else {
            throw SurfError.replayMismatch("Course, seed, schema or rules identity")
        }
        guard replay.inputs.count <= rules.maximumTicks else { throw SurfError.replayMismatch("Replay too long") }
        var state = start(course: course, rules: rules)
        for input in replay.inputs {
            guard state.phase == .running else { throw SurfError.replayMismatch("Inputs after terminal state") }
            state = try step(state: state, input: input, course: course, rules: rules).state
        }
        try validate(replay.finalState, course: course, rules: rules)
        guard state == replay.finalState else { throw SurfError.replayMismatch("Final state differs") }
        return state
    }
}
