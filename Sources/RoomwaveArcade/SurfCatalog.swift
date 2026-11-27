import Foundation

public enum SurfCatalog {
    /// Stable, authored phrases: charge bed -> aerial ring -> barrier -> low roof -> recovery.
    public static var all: [SurfCourseDefinition] { authored }
    /// The launch catalog stays fixed for older fixtures and daily seeds.
    /// Featured courses include opt-in routes with their own score/replay identity.
    public static var featured: [SurfCourseDefinition] { authored + [SurfAfterglow.course, prismBreak] }
    public static func course(id: String) -> SurfCourseDefinition? {
        featured.first { $0.id == id }
    }

    private static let prismBreak: SurfCourseDefinition = {
        // Deliberately irregular breathing room. None of these movements modifies
        // the starter courses, the global speed curve, or the meaning of a shield.
        let beds: [Double] = [40, 174, 296, 448, 566, 692, 840, 953, 1074]
        let samples = stride(from: 0, through: 1212, by: 6).map { metre in
            let d = Double(metre)
            let y = 1.15 * sin(d * .pi / 72) + 3.2 * sin(d * .pi / 258)
            let x = 11 * sin(d * .pi / 220) + 3 * sin(d * .pi / 95)
            return SurfCourseSample(distance: d, center: SurfVector(x: x, y: y, z: -d), width: 7)
        }
        var encounters: [SurfEncounter] = []
        for (i, bed) in beds.enumerated() {
            func place(_ kind: SurfEncounterKind, _ offset: Double, _ height: Double,
                       _ aperture: Double, _ points: Int) {
                encounters.append(SurfEncounter(id: encounters.count, kind: kind, distance: bed + offset,
                                               height: height, halfHeight: aperture, points: points))
            }
            // Act I: enter on a clean arc. Act II: hold height over the bar,
            // then dive under a roof. Act III: thread two scored bands on a
            // single arc. Missing a ring costs opportunity, not a shield.
            let highDistance: Double = [38, 40, 37, 41, 38, 40, 36, 40, 38][i]
            place(.ring, highDistance, i < 3 ? 4.4 : 4.8, i < 3 ? 1.9 : (i < 6 ? 1.35 : 1.05), 120)
            place(.barrier, 46, 0.95, 0.9, 80)
            if i >= 3 {
                // A clean finish does not require the low ring. The scored low
                // line rewards the additional dive and stable recovery.
                let roof: Double = i < 6 ? 74 : [68, 71, 67][i - 6]
                place(.ceiling, roof, 4.0, 1.0, 80)
                place(.ring, roof + 3, 1.45, i < 6 ? 0.72 : 0.62, 240)
            }
            place(.boost, 99, 0.50, 0.45, 50)
        }
        return SurfCourseDefinition(id: "prism-break", title: "PRISM BREAK",
            subtitle: "MASTER COURSE · Find height, dive under the arch, thread the low ring.",
            biome: .midnight, seed: 407, samples: samples, encounters: encounters,
            medalScores: [1_600, 5_500, 11_000])
    }()

    private static let authored: [SurfCourseDefinition] = [
        make(id: "neon-dawn", title: "NEON DAWN", subtitle: "Find the pulse. Compress, release, catch the gold.",
             biome: .dawn, seed: 301, length: 1_440, phrases: 11),
        make(id: "low-orbit", title: "LOW ORBIT", subtitle: "Long arcs over tidal hills. Leave room to come home.",
             biome: .orbit, seed: 302, length: 1_560, phrases: 12),
        make(id: "black-current", title: "BLACK CURRENT", subtitle: "Rise over coral. Dive beneath the current. Recover your flow.",
             biome: .midnight, seed: 303, length: 1_680, phrases: 13)
    ]

    private static func make(id: String, title: String, subtitle: String, biome: SurfBiome,
                             seed: UInt64, length: Int, phrases: Int) -> SurfCourseDefinition {
        let samples = stride(from: 0, through: length, by: 12).map { metre -> SurfCourseSample in
            let d = Double(metre)
            let y: Double
            let x: Double
            switch biome {
            case .dawn:
                y = 2 * sin(d * .pi / 60) + 3 * sin(d * .pi / 180)
                x = 8 * sin(d * .pi / 240)
            case .orbit:
                y = 5 * sin(d * .pi / 90) + 3 * sin(d * .pi / 240)
                x = 14 * sin(d * .pi / 300)
            case .midnight:
                y = 4 * sin(d * .pi / 80) + 2 * sin(d * .pi / 180)
                x = 10 * sin(d * .pi / 180)
            }
            return SurfCourseSample(distance: d, center: SurfVector(x: x, y: y, z: -d),
                                    width: biome == .dawn ? 8 : biome == .orbit ? 7 : 6)
        }
        var encounters: [SurfEncounter] = []
        func add(_ kind: SurfEncounterKind, _ d: Double, _ height: Double, _ half: Double, _ points: Int) {
            encounters.append(SurfEncounter(id: encounters.count, kind: kind, distance: d,
                                            height: height, halfHeight: half, points: points))
        }
        for phrase in 0..<phrases {
            let bed = 40.0 + Double(phrase) * 120
            // Eighteen longitudinal units of charge bed; release around bed+18.
            add(.ring, bed + 38, biome == .orbit ? 6 : 5, biome == .dawn ? 2.5 : 2.2, 120)
            if biome != .dawn || phrase >= 2 {
                add(.barrier, bed + 46, 0.95, 0.9, 80)
            }
            if biome == .midnight && phrase >= 1 {
                // At high speed the post-barrier dive opens this low line.
                add(.ceiling, bed + 65, 3.5, 1.2, 80)
                add(.ring, bed + 76, 1.6, 0.6, 160)
            } else if biome == .orbit || (biome == .dawn && phrase >= 4) {
                // Roof comes after a full normal arc, with a grounded interval before the next charge.
                add(.ceiling, bed + 86, 3.8, 1.1, 80)
            }
            add(.boost, bed + 100, 0.5, 0.45, 50)
        }
        return SurfCourseDefinition(id: id, title: title, subtitle: subtitle, biome: biome,
                                    seed: seed, samples: samples, encounters: encounters,
                                    medalScores: biome == .dawn ? [1_200, 3_500, 6_000] : [1_500, 4_500, 8_000])
    }

    /// Caller supplies the UTC date. No clock, process-random hash or unseeded randomness.
    /// Invalid dates deterministically use 2000-01-01 (including impossible Gregorian dates).
    public static func daily(day: String) -> SurfCourseDefinition {
        let date = validDate(day) ? day : "2000-01-01"
        var seed: UInt64 = 14_695_981_039_346_656_037
        for byte in date.utf8 { seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211 }
        let base = authored[Int(seed % UInt64(authored.count))]
        let scale = 0.94 + Double((seed >> 8) % 13) / 100
        let samples = base.samples.map {
            SurfCourseSample(distance: $0.distance,
                             center: SurfVector(x: $0.center.x, y: $0.center.y * scale, z: $0.center.z), width: $0.width)
        }
        let rings = base.encounters.map {
            SurfEncounter(id: $0.id, kind: $0.kind, distance: $0.distance,
                          height: $0.height + ($0.kind == .ring && $0.height > 1 ? Double(seed % 3) * 0.1 : 0),
                          halfHeight: $0.halfHeight, points: $0.points)
        }
        return SurfCourseDefinition(id: "daily-" + date.replacingOccurrences(of: "-", with: ""),
                                    title: "DAILY CURRENT", subtitle: date + " · " + base.title,
                                    biome: base.biome, source: .daily, seed: seed, samples: samples,
                                    encounters: rings, medalScores: base.medalScores)
    }

    private static func validDate(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
        for index in [0, 1, 2, 3, 5, 6, 8, 9] where !(48...57).contains(bytes[index]) { return false }
        let year = Int(bytes[0] - 48) * 1000 + Int(bytes[1] - 48) * 100 + Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
        let month = Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)
        let date = Int(bytes[8] - 48) * 10 + Int(bytes[9] - 48)
        guard year >= 1, (1...12).contains(month) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[month - 1]).contains(date)
    }
}
