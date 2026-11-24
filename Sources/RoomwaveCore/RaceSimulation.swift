import Foundation

/// Custom fixed-step gameplay, with no dependency on a platform physics engine.
public enum RaceSimulation {
    public static func initialState(rules: RaceRules) throws -> RaceState {
        try validate(rules)
        return RaceState(tick: 0, distance: 0, lateralOffset: 0,
                         speed: rules.initialSpeed, bankedScore: 0,
                         unbankedScore: 0, multiplier: 1, status: .running)
    }

    public static func step(state: RaceState, input: RaceInput, track: TrackDefinition) throws -> RaceState {
        let rules = track.rules
        try validate(rules)
        try validate(state, rules: rules)
        guard state.status == .running else {
            throw RoomwaveError.invalidInput("Cannot step a terminal race")
        }
        guard input.tick == state.tick + 1, input.steering.isFinite,
              (-1.0...1.0).contains(input.steering) else {
            throw RoomwaveError.invalidInput("Expected the next tick and finite steering in [-1, 1]")
        }
        // Admit finalized geometry before using it for scoring or bend pressure.
        let issues = TrackValidator.validate(track)
        guard issues.isEmpty else {
            throw RoomwaveError.invalidTrack(issues.map { $0.code }.joined(separator: ", "))
        }
        let route = try Circuit(track.points)
        let dt = 1 / Double(rules.tickRate)
        var speed = min(rules.maximumSpeed, state.speed + rules.acceleration * dt)
        let advance = speed * dt
        let tickSpeed = speed
        guard advance.isFinite, advance > 0,
              (state.distance + advance).isFinite, state.distance + advance > state.distance else {
            throw RoomwaveError.invalidInput("Distance cannot advance finitely at this precision")
        }
        let lateralChange = input.steering * rules.steeringSpeed * dt
        guard lateralChange.isFinite, (state.lateralOffset + lateralChange).isFinite else {
            throw RoomwaveError.invalidInput("Lateral movement overflow")
        }

        var phase = state.distance.truncatingRemainder(dividingBy: route.length)
        var segment = route.segment(at: phase)
        guard abs(state.lateralOffset) <= route.width(segment: segment, phase: phase) else {
            throw RoomwaveError.invalidInput("Running state is already outside the circuit")
        }
        var travelled = 0.0
        var banked = state.bankedScore
        var chain = state.unbankedScore
        var multiplier = state.multiplier
        var bankRequested = input.bank
        var crossings = 0
        var lateral = state.lateralOffset

        // Distance/steering for this tick use accelerated speed. A bank changes
        // the next tick's speed; scoring is split at every crossed gate.
        while travelled < advance {
            crossings += 1
            guard crossings <= 4096 else {
                throw RoomwaveError.invalidInput("Tick exceeds 4096 circuit segments")
            }
            let toVertex = route.ends[segment] - phase
            let amount = min(advance - travelled, toVertex)
            guard amount > 0, travelled + amount > travelled else {
                throw RoomwaveError.invalidInput("Circuit traversal lost numeric precision")
            }
            let reachesVertex = amount == toVertex
            travelled = min(advance, travelled + amount)
            phase += amount
            if rules.version == "roomwave-pilot-2" {
                // A signed turn distributed over this segment pushes outward.
                // Pressure grows with speed squared, capped at 80% of steering
                // authority so correction retains headroom. No hidden velocity
                // or frame-time state is needed for replay. Banks affect only
                // next tick's movement, including this pressure calculation.
                let limit = 0.8 * rules.steeringSpeed
                let raceSeconds = Double(state.tick) / Double(rules.tickRate)
                let onset = min(1.0, max(0.0, (raceSeconds - 2.0) / 3.0))
                let pressure = onset * max(-limit, min(limit, -0.18 * tickSpeed * tickSpeed * route.curvatures[segment]))
                lateral += (input.steering * rules.steeringSpeed + pressure) * (amount / tickSpeed)
            } else {
                // Preserve rules-1's neutral, linear lateral movement exactly.
                lateral = state.lateralOffset + lateralChange * (travelled / advance)
            }
            guard lateral.isFinite else { throw RoomwaveError.invalidInput("Lateral movement overflow") }
            let width = route.width(segment: segment, phase: phase)
            // Width and lateral movement are linear on each segment. Testing
            // every vertex and the endpoint also catches intermediate narrowing.
            if abs(lateral) > width {
                return try checked(RaceState(tick: input.tick, distance: state.distance + travelled,
                    lateralOffset: lateral, speed: speed, bankedScore: banked,
                    unbankedScore: 0, multiplier: 1, status: .crashed), rules: rules)
            }
            chain += amount * multiplier
            guard chain.isFinite else { throw RoomwaveError.invalidInput("Score overflow") }
            if reachesVertex {
                let next = (segment + 1) % track.points.count
                if track.points[next].isGate {
                    if bankRequested {
                        banked += chain
                        chain = 0
                        multiplier = 1
                        speed = max(rules.initialSpeed, speed * rules.bankSpeedFactor)
                        bankRequested = false
                    } else {
                        multiplier += rules.multiplierGain
                    }
                    guard banked.isFinite, multiplier.isFinite else {
                        throw RoomwaveError.invalidInput("Gate score or multiplier overflow")
                    }
                }
                segment = next
                phase = route.starts[segment]
            }
        }
        let finished = input.tick == rules.durationTicks
        if finished {
            banked += chain
            chain = 0
            multiplier = 1
        }
        return try checked(RaceState(tick: input.tick, distance: state.distance + advance,
            lateralOffset: lateral, speed: speed,
            bankedScore: banked, unbankedScore: chain, multiplier: multiplier,
            status: finished ? .finished : .running), rules: rules)
    }

    private static func validate(_ rules: RaceRules) throws {
        guard rules.version == "roomwave-rules-1" || rules.version == "roomwave-pilot-2" else {
            throw RoomwaveError.invalidInput("Unsupported race rules version: \(rules.version)")
        }
        guard (1...240).contains(rules.tickRate), (1...864000).contains(rules.durationTicks),
              rules.initialSpeed.isFinite, rules.initialSpeed > 0,
              rules.maximumSpeed.isFinite, rules.maximumSpeed >= rules.initialSpeed, rules.maximumSpeed <= 100,
              rules.acceleration.isFinite, (0...100).contains(rules.acceleration),
              rules.steeringSpeed.isFinite, rules.steeringSpeed > 0, rules.steeringSpeed <= 100,
              rules.bankSpeedFactor.isFinite, rules.bankSpeedFactor > 0, rules.bankSpeedFactor <= 1,
              rules.multiplierGain.isFinite, rules.multiplierGain > 0, rules.multiplierGain <= 10 else {
            throw RoomwaveError.invalidInput("Invalid race rules")
        }
    }

    private static func validate(_ state: RaceState, rules: RaceRules) throws {
        guard state.tick >= 0, state.tick <= rules.durationTicks,
              state.distance.isFinite, state.distance >= 0,
              state.lateralOffset.isFinite,
              state.speed.isFinite, state.speed >= rules.initialSpeed, state.speed <= rules.maximumSpeed,
              state.bankedScore.isFinite, state.bankedScore >= 0,
              state.unbankedScore.isFinite, state.unbankedScore >= 0,
              state.multiplier.isFinite, state.multiplier >= 1 else {
            throw RoomwaveError.invalidInput("Invalid race state")
        }
        switch state.status {
        case .running:
            guard state.tick < rules.durationTicks else {
                throw RoomwaveError.invalidInput("Running state reached the time limit")
            }
        case .finished:
            guard state.tick == rules.durationTicks, state.unbankedScore == 0, state.multiplier == 1 else {
                throw RoomwaveError.invalidInput("Invalid finished state")
            }
        case .crashed:
            guard state.tick > 0, state.unbankedScore == 0, state.multiplier == 1 else {
                throw RoomwaveError.invalidInput("Invalid crashed state")
            }
        }
        if state.tick == 0, state != (try initialState(rules: rules)) {
            throw RoomwaveError.invalidInput("Tick zero must be the initial state")
        }
    }

    private static func checked(_ state: RaceState, rules: RaceRules) throws -> RaceState {
        try validate(state, rules: rules)
        return state
    }

    private struct Circuit {
        let points: [TrackPoint]
        let starts: [Double]
        let ends: [Double]
        let length: Double
        let curvatures: [Double]

        init(_ points: [TrackPoint]) throws {
            guard (3...256).contains(points.count) else {
                throw RoomwaveError.invalidTrack("Expected 3...256 circuit points")
            }
            var starts: [Double] = []
            var ends: [Double] = []
            var total = 0.0
            for index in points.indices {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                guard a.position.x.isFinite, a.position.y.isFinite, a.position.z.isFinite,
                      a.halfWidth.isFinite, a.halfWidth > 0 else {
                    throw RoomwaveError.invalidTrack("Nonfinite geometry or invalid width")
                }
                let length = hypot(hypot(b.position.x - a.position.x, b.position.y - a.position.y),
                                   b.position.z - a.position.z)
                guard length.isFinite, length > 0, (total + length).isFinite, total + length > total else {
                    throw RoomwaveError.invalidTrack("Degenerate circuit segment")
                }
                starts.append(total)
                total += length
                ends.append(total)
            }
            self.points = points
            self.starts = starts
            self.ends = ends
            self.length = total
            // Include both sides of the implicit closing seam. Each vertex's
            // signed heading change contributes half to each adjacent segment.
            let turns = points.indices.map { i -> Double in
                let a = points[(i + points.count - 1) % points.count].position
                let b = points[i].position
                let c = points[(i + 1) % points.count].position
                let ux = b.x - a.x, uz = b.z - a.z
                let vx = c.x - b.x, vz = c.z - b.z
                return atan2(ux * vz - uz * vx, ux * vx + uz * vz)
            }
            self.curvatures = points.indices.map { i in
                (turns[i] + turns[(i + 1) % points.count]) / (2 * (ends[i] - starts[i]))
            }
        }

        func segment(at phase: Double) -> Int {
            ends.firstIndex(where: { phase < $0 }) ?? 0
        }

        func width(segment: Int, phase: Double) -> Double {
            let fraction = min(1, max(0, (phase - starts[segment]) / (ends[segment] - starts[segment])))
            return (1 - fraction) * points[segment].halfWidth
                + fraction * points[(segment + 1) % points.count].halfWidth
        }
    }
}
