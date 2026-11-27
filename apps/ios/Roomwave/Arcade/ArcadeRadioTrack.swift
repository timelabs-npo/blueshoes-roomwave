import Foundation

/// Local, credited racing music. No network playback, account or tracking.
struct ArcadeRadioTrack: Sendable {
    let title: String
    let asset: String
    let source: URL

    static let rotation = [
        Self(title: "Neon Sign Circuit (Climax Remake)", asset: "RadioNeonSignCircuit",
             source: URL(string: "https://opengameart.org/content/neon-sign-circuit-remake")!),
        Self(title: "Darkness Road (Climax Remake)", asset: "RadioDarknessRoad",
             source: URL(string: "https://opengameart.org/content/darkness-roadremeke")!)
    ]

    var url: URL? { Bundle.main.url(forResource: asset, withExtension: "mp3") }
}
