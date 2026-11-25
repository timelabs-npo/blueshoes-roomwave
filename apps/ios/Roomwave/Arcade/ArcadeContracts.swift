import Foundation
import UIKit
import RoomwaveArcade

/// Native scene lifetime and frame delivery. SwiftUI observes HUD/session changes,
/// not the entity graph or the 60 Hz simulation state.
@MainActor
protocol ArcadeSceneDriving: AnyObject {
    var view: UIView { get }
    func load(course: CompiledSurfCourse) async throws
    func render(state: SurfState, events: [SurfEvent], deltaTime: TimeInterval,
                reducedMotion: Bool, ghost: SurfState?)
    func preview(time: TimeInterval, reducedMotion: Bool)
    func teardown()
}

enum ArcadeScreen: Equatable { case home, playing, paused, results }

struct ArcadeHUD: Equatable {
    var score = 0
    var combo = 0
    var shields = 3
    var speed = 0
    var progress = 0.0
    var charge = 0.0
    var airborne = false
    var callout = ""
    var calloutID = 0
}

struct ArcadePreferences: Codable, Equatable {
    var soundEnabled = true
    var hapticsEnabled = true
    var reducedMotion = false
    var tutorialSeen = false
}
