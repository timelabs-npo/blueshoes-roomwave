import Foundation

/// Local deterministic consistency checking, not remote score authentication.
public enum ReplayEngine {
    public static func record(inputs: [RaceInput], track: TrackDefinition) throws -> ReplayRecord {
        let trackID = try TrackIdentity.id(for: track)
        let result = try simulate(inputs: inputs, track: track)
        return ReplayRecord(schemaVersion: 1, trackID: trackID, inputs: inputs,
                            keyframes: result.keyframes, finalState: result.finalState)
    }

    public static func replay(_ record: ReplayRecord, track: TrackDefinition) throws -> RaceState {
        guard record.schemaVersion == 1 else {
            throw RoomwaveError.replayMismatch("Unsupported replay schema")
        }
        let trackID = try TrackIdentity.id(for: track)
        guard record.trackID == trackID else {
            throw RoomwaveError.replayMismatch("Track content identity differs")
        }
        let result = try simulate(inputs: record.inputs, track: track)
        guard record.keyframes == result.keyframes else {
            throw RoomwaveError.replayMismatch("Actual keyframes differ from supplied keyframes")
        }
        guard record.finalState == result.finalState else {
            throw RoomwaveError.replayMismatch("Actual final state differs from supplied final state")
        }
        return result.finalState
    }

    private static func simulate(inputs: [RaceInput], track: TrackDefinition) throws
        -> (keyframes: [RaceState], finalState: RaceState) {
        var state = try RaceSimulation.initialState(rules: track.rules)
        let issues = TrackValidator.validate(track)
        guard issues.isEmpty else {
            throw RoomwaveError.invalidTrack(issues.map { $0.code }.joined(separator: ", "))
        }
        guard inputs.count <= track.rules.durationTicks else {
            throw RoomwaveError.invalidInput("Replay has more inputs than the duration")
        }
        // Include tick zero, each whole simulated second, and a final partial
        // second. Partial running records are permitted and checked as supplied.
        var keyframes = [state]
        for input in inputs {
            state = try RaceSimulation.step(state: state, input: input, track: track)
            if state.tick % track.rules.tickRate == 0 {
                keyframes.append(state)
            }
        }
        if keyframes.last != state { keyframes.append(state) }
        return (keyframes, state)
    }
}
