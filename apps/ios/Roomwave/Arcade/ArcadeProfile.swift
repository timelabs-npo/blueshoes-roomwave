import Foundation
import RoomwaveArcade

struct ArcadeBest: Codable {
    var score: Int
    var medal: SurfMedal
}

/// Small, app-private records. No capture metadata or identifiers enter this store.
@MainActor
final class ArcadeProfile {
    static let courseIDs = SurfCatalog.featured.map(\.id)
    private(set) var preferences = ArcadePreferences()
    private(set) var bests: [String: ArcadeBest] = [:]
    private(set) var notice: String?
    private var directory: URL?
    private var writable = true

    // Optional fields allow older records to acquire conservative defaults without
    // making the frozen ArcadePreferences contract depend on storage migrations.
    private struct Settings: Codable {
        var soundEnabled: Bool?
        var hapticsEnabled: Bool?
        var reducedMotion: Bool?
        var tutorialSeen: Bool?

        init(_ value: ArcadePreferences) {
            soundEnabled = value.soundEnabled; hapticsEnabled = value.hapticsEnabled
            reducedMotion = value.reducedMotion; tutorialSeen = value.tutorialSeen
        }

        var value: ArcadePreferences {
            var result = ArcadePreferences()
            result.soundEnabled = soundEnabled ?? true
            result.hapticsEnabled = hapticsEnabled ?? true
            result.reducedMotion = reducedMotion ?? false
            result.tutorialSeen = tutorialSeen ?? false
            return result
        }
    }

    private struct Record: Codable {
        var schemaVersion: Int?
        var settings: Settings?
        var bests: [String: ArcadeBest]?
    }

    func load() {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = base.appendingPathComponent("RoomwaveArcade", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            let url = folder.appendingPathComponent("profile.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 128_001) ?? Data()
            guard data.count <= 128_000 else { throw StoreError.oversized }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.schemaVersion == nil || record.schemaVersion == 1 else {
                throw StoreError.newerVersion
            }
            preferences = record.settings?.value ?? ArcadePreferences()
            bests = (record.bests ?? [:]).filter {
                Self.courseIDs.contains($0.key) && (0...1_000_000_000).contains($0.value.score)
            }
        } catch {
            // Preserve unreadable/newer files rather than overwriting recovery evidence.
            writable = false
            notice = "Saved progress could not be read. This session can play; existing data is preserved."
        }
    }

    func update(preferences: ArcadePreferences) {
        self.preferences = preferences
        save()
    }

    @discardableResult
    func record(_ result: SurfRunResult) -> Int? {
        let previous = bests[result.courseID]?.score
        guard Self.courseIDs.contains(result.courseID), result.score >= 0 else { return previous }
        let old = bests[result.courseID]
        let rank: [SurfMedal: Int] = [.none: 0, .bronze: 1, .silver: 2, .gold: 3]
        let medal = (rank[result.medal, default: 0] > rank[old?.medal ?? .none, default: 0])
            ? result.medal : (old?.medal ?? .none)
        bests[result.courseID] = ArcadeBest(score: max(previous ?? 0, result.score), medal: medal)
        save()
        return previous
    }

    func save(replay: SurfReplay) {
        guard writable, let directory else { return }
        guard replay.inputs.count <= SurfRules.standard.maximumTicks,
              Self.courseIDs.contains(replay.courseID) else { return }
        do {
            let data = try JSONEncoder().encode(replay)
            guard data.count <= 2_000_000 else { throw StoreError.oversized }
            try data.write(to: directory.appendingPathComponent("last-run.json"), options: .atomic)
        } catch {
            notice = "The run played normally, but its local replay could not be saved."
        }
    }

    private func save() {
        guard writable, let directory else { return }
        do {
            let record = Record(schemaVersion: 1, settings: Settings(preferences), bests: bests)
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("profile.json"),
                                                   options: .atomic)
        } catch {
            notice = "Progress is available this session, but could not be saved."
        }
    }

    private enum StoreError: Error { case oversized, newerVersion }
}
