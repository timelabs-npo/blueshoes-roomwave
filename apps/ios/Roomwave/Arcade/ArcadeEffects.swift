import Foundation
import RealityKit
import RoomwaveArcade
import UIKit
import simd

/// Fixed-capacity visual feedback. The session is the only clock; no subscriptions,
/// timers, async animation tasks, mesh generation or entity creation during a frame.
@MainActor
final class ArcadeEffects {
    let root = Entity()

    private struct Spark {
        let entity: ModelEntity
        var velocity = SIMD3<Float>.zero
        var age: Float = 0
        var lifetime: Float = 0
        var size: Float = 1
    }
    private struct Wave {
        let entity: ModelEntity
        var age: Float = 0
        var lifetime: Float = 0
        var radius: Float = 1
    }

    private let cyan = UnlitMaterial(color: ArcadeGeometry.cyan)
    private let gold = UnlitMaterial(color: ArcadeGeometry.gold)
    private let coral = UnlitMaterial(color: ArcadeGeometry.coral)
    private let white = UnlitMaterial(color: UIColor(white: 0.92, alpha: 1))
    private var sparks: [Spark] = []
    private var waves: [Wave] = []
    private var sparkCursor = 0
    private var waveCursor = 0
    private var trailAccumulator: Float = 0

    init() throws {
        root.name = "BoundedSurfFeedback"
        let sparkMesh = MeshResource.generateBox(size: SIMD3<Float>(repeating: 1))
        for _ in 0..<48 {
            let entity = ModelEntity(mesh: sparkMesh, materials: [cyan])
            entity.isEnabled = false
            root.addChild(entity)
            sparks.append(Spark(entity: entity))
        }
        let waveMesh = try ArcadeGeometry.openRing(radiusX: 1, radiusY: 1, thickness: 0.055, depth: 0.015, segments: 40)
        for _ in 0..<3 {
            let entity = ModelEntity(mesh: waveMesh, materials: [cyan])
            entity.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
            entity.isEnabled = false
            root.addChild(entity)
            waves.append(Wave(entity: entity))
        }
    }

    func event(_ event: SurfEvent, rider: SIMD3<Float>, road: SIMD3<Float>,
               forward: SIMD3<Float>, reducedMotion: Bool) {
        let intensity = Float(max(0, min(1.5, event.intensity.isFinite ? event.intensity : 0)))
        switch event.kind {
        case .takeoff:
            pulse(at: road, forward: forward, radius: 1.2, duration: 0.38, material: cyan)
            burst(at: rider, forward: forward, count: reducedMotion ? 3 : 9,
                  speed: 1.8, size: 0.055, material: cyan, upward: 0.7)
        case .landing, .perfectLanding:
            let perfect = event.kind == .perfectLanding
            pulse(at: road, forward: forward, radius: perfect ? 2.5 : 1.7, duration: reducedMotion ? 0.3 : 0.5,
                  material: perfect ? white : cyan)
            if !reducedMotion {
                burst(at: road, forward: forward, count: perfect ? 12 : 7,
                      speed: perfect ? 3.6 : 2.2, size: 0.045,
                      material: perfect ? white : cyan, upward: 0.5)
            }
        case .ring:
            // Gold only celebrates collected rings, never damage or a generic speed cue.
            burst(at: rider + SIMD3(0, 0.4, 0), forward: forward,
                  count: reducedMotion ? 5 : 16, speed: reducedMotion ? 1.2 : 3.3,
                  size: 0.075, material: gold, upward: 1.1)
        case .hit:
            burst(at: rider + SIMD3(0, 0.45, 0), forward: forward,
                  count: reducedMotion ? 3 : 12, speed: 2.6 * intensity,
                  size: 0.08, material: coral, upward: 0.7)
        case .boost:
            burst(at: rider, forward: forward, count: reducedMotion ? 3 : 10,
                  speed: 3, size: 0.06, material: cyan, upward: 0.4)
        case .nearMiss:
            if !reducedMotion {
                burst(at: rider, forward: forward, count: 3, speed: 1.3,
                      size: 0.035, material: white, upward: 0.2)
            }
        case .finish:
            pulse(at: road, forward: forward, radius: 3, duration: 0.65, material: white)
        case .comboLost:
            break
        }
    }

    func update(deltaTime: Float, rider: SIMD3<Float>, forward: SIMD3<Float>,
                airborne: Bool, speed: Float, reducedMotion: Bool) {
        for index in sparks.indices where sparks[index].lifetime > 0 {
            sparks[index].age += deltaTime
            let fraction = sparks[index].age / sparks[index].lifetime
            if fraction >= 1 {
                sparks[index].entity.isEnabled = false
                sparks[index].lifetime = 0
                continue
            }
            sparks[index].velocity.y -= 2.5 * deltaTime
            sparks[index].entity.position += sparks[index].velocity * deltaTime
            let size = sparks[index].size * max(0.02, 1 - fraction * fraction)
            sparks[index].entity.scale = SIMD3(size, size, size * 2.4)
        }
        for index in waves.indices where waves[index].lifetime > 0 {
            waves[index].age += deltaTime
            let fraction = waves[index].age / waves[index].lifetime
            if fraction >= 1 {
                waves[index].entity.isEnabled = false
                waves[index].lifetime = 0
                continue
            }
            let radius = 0.3 + waves[index].radius * fraction
            waves[index].entity.scale = SIMD3(radius, radius, max(0.01, 1 - fraction))
        }
        // A wake is emitted only for actual flight. Spatially separated fading marks
        // expose the launch/arc; they don't impose an independent motion on the rider.
        if airborne, speed > 8 {
            trailAccumulator += deltaTime
            let interval: Float = reducedMotion ? 0.12 : 0.045
            if trailAccumulator >= interval {
                trailAccumulator.formTruncatingRemainder(dividingBy: interval)
                emit(at: rider - forward * 0.45 + SIMD3(0, 0.03, 0),
                     velocity: -forward * 1.3, duration: reducedMotion ? 0.22 : 0.42,
                     size: 0.055, material: cyan, forward: forward)
            }
        } else { trailAccumulator = 0 }
    }

    func clear() {
        for index in sparks.indices {
            sparks[index].entity.isEnabled = false
            sparks[index].lifetime = 0
        }
        for index in waves.indices {
            waves[index].entity.isEnabled = false
            waves[index].lifetime = 0
        }
        trailAccumulator = 0
        sparkCursor = 0
        waveCursor = 0
    }

    private func pulse(at position: SIMD3<Float>, forward: SIMD3<Float>, radius: Float,
                       duration: Float, material: UnlitMaterial) {
        let index = waveCursor
        waveCursor = (waveCursor + 1) % waves.count
        waves[index].age = 0
        waves[index].lifetime = duration
        waves[index].radius = radius
        waves[index].entity.position = position + SIMD3(0, 0.035, 0)
        let slopeAngle = atan2(forward.y, max(0.001, simd_length(SIMD2(forward.x, forward.z))))
        waves[index].entity.orientation = ArcadeGeometry.yaw(for: forward) *
            simd_quatf(angle: slopeAngle - .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        waves[index].entity.model?.materials = [material]
        waves[index].entity.scale = SIMD3(repeating: 0.3)
        waves[index].entity.isEnabled = true
    }

    private func burst(at position: SIMD3<Float>, forward: SIMD3<Float>, count: Int,
                       speed: Float, size: Float, material: UnlitMaterial, upward: Float) {
        let right = ArcadeGeometry.normalized(simd_cross(forward, SIMD3(0, 1, 0)), fallback: SIMD3(1, 0, 0))
        for index in 0..<count {
            let angle = Float(index) * 2.39996
            let velocity = right * cos(angle) * speed + forward * sin(angle) * speed * 0.6 +
                SIMD3<Float>(0, upward + Float(index % 4) * 0.26, 0)
            emit(at: position, velocity: velocity, duration: 0.38 + Float(index % 4) * 0.08,
                 size: size, material: material, forward: forward)
        }
    }

    private func emit(at position: SIMD3<Float>, velocity: SIMD3<Float>, duration: Float,
                      size: Float, material: UnlitMaterial, forward: SIMD3<Float>) {
        let index = sparkCursor
        sparkCursor = (sparkCursor + 1) % sparks.count
        sparks[index].age = 0
        sparks[index].lifetime = duration
        sparks[index].size = size
        sparks[index].velocity = velocity
        sparks[index].entity.position = position
        sparks[index].entity.orientation = ArcadeGeometry.yaw(for: forward)
        sparks[index].entity.scale = SIMD3(size, size, size * 2.4)
        sparks[index].entity.model?.materials = [material]
        sparks[index].entity.isEnabled = true
    }
}
