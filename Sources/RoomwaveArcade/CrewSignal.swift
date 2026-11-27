import Foundation

/// A local, unranked crew decision. No X metrics or user text can enter this type.
/// For remote ballots a first-party service must authenticate, deduplicate and freeze
/// the seed/rules/options before launch. This value alone does not authenticate votes.
public struct CrewSignal: Equatable, Sendable {
    public enum Ability: String, CaseIterable, Hashable, Sendable {
        case trajectory, wind, recovery
    }
    public enum Mode: String, Equatable, Sendable { case ranked, crew }
    public struct Loadout: Equatable, Sendable {
        public let mode: Mode
        public let trackID: String
        public let beaconID: String
        public let rulesVersion: String
        public let available: [Ability]
    }
    public let trackID: String
    public let beaconID: String
    public private(set) var loadout: Loadout?
    private var ballots: [String: Ability] = [:]

    public init?(trackID: String, beaconID: String) {
        guard Self.valid(trackID), Self.valid(beaconID) else { return nil }
        self.trackID = trackID
        self.beaconID = beaconID
    }

    @discardableResult
    public mutating func cast(participant: String, ability: Ability) -> Bool {
        guard loadout == nil, Self.valid(participant), ballots.count < 64,
              ballots[participant] == nil else { return false }
        ballots[participant] = ability
        return true
    }

    public mutating func start(mode: Mode, rulesVersion: String) -> Loadout? {
        guard loadout == nil, Self.valid(rulesVersion) else { return nil }
        let limit = mode == .ranked ? 0 : ballots.count >= 3 ? 2 : ballots.isEmpty ? 0 : 1
        let counts = Dictionary(grouping: ballots.values, by: { $0 }).mapValues { $0.count }
        let options = Ability.allCases.enumerated()
            .filter { counts[$0.element, default: 0] > 0 }
            .sorted { a, b in
                let one = counts[a.element, default: 0], two = counts[b.element, default: 0]
                return one == two ? a.offset < b.offset : one > two
            }
            .prefix(limit)
            .map { $0.element }
        let result = Loadout(mode: mode, trackID: trackID, beaconID: beaconID,
                             rulesVersion: rulesVersion, available: options)
        loadout = result
        return result
    }

    private static func valid(_ raw: String) -> Bool {
        (1...64).contains(raw.utf8.count) && raw.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }
}
