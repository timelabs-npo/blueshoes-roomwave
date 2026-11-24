import RealityKit
import RoomwaveCore
import SwiftUI
import simd

/// A tabletop rendering of finalized game geometry; never an AR room overlay.
@MainActor
struct TrackScene: UIViewRepresentable {
    let track: TrackDefinition
    let race: RaceState?

    @MainActor
    final class Coordinator {
        var track: TrackDefinition?
        let root = AnchorEntity(world: .zero)
        let player = ModelEntity(mesh: .generateSphere(radius: 0.25),
                                 materials: [UnlitMaterial(color: .white)])
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.black)
        view.scene.addAnchor(context.coordinator.root)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.track != track {
            coordinator.root.children.removeAll()
            coordinator.track = track
            let positions = track.points.map { vector($0.position) }
            guard positions.count >= 3 else { return }
            for index in positions.indices {
                let a = positions[index]
                let b = positions[(index + 1) % positions.count]
                let delta = b - a
                let length = simd_length(delta)
                guard length > 0 else { continue }
                let width = Float(track.points[index].halfWidth + track.points[(index + 1) % positions.count].halfWidth)
                let road = ModelEntity(mesh: .generateBox(size: SIMD3(width, 0.08, length)),
                                       materials: [UnlitMaterial(color: .systemTeal)])
                road.position = (a + b) / 2
                road.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: delta / length)
                coordinator.root.addChild(road)
                if track.points[index].isGate {
                    let gate = ModelEntity(mesh: .generateBox(size: SIMD3(width, 0.12, 0.16)),
                                           materials: [UnlitMaterial(color: .systemOrange)])
                    gate.position = a + SIMD3(0, 0.12, 0)
                    gate.orientation = road.orientation
                    coordinator.root.addChild(gate)
                }
            }
            let minimum = positions.reduce(positions[0]) { simd_min($0, $1) }
            let maximum = positions.reduce(positions[0]) { simd_max($0, $1) }
            let center = (minimum + maximum) / 2
            let height = max(simd_length(maximum - minimum) * 1.15, 12)
            let camera = PerspectiveCamera()
            camera.look(at: center, from: center + SIMD3(0, height, height * 0.25), relativeTo: nil)
            coordinator.root.addChild(camera)
            coordinator.root.addChild(coordinator.player)
        }
        coordinator.player.position = playerPosition(distance: race?.distance ?? 0,
                                                      offset: race?.lateralOffset ?? 0)
    }

    private func vector(_ point: Vector3) -> SIMD3<Float> {
        SIMD3(Float(point.x), Float(point.y), Float(point.z))
    }

    private func playerPosition(distance: Double, offset: Double) -> SIMD3<Float> {
        let positions = track.points.map { vector($0.position) }
        guard positions.count >= 3 else { return .zero }
        let lengths = positions.indices.map { simd_distance(positions[$0], positions[($0 + 1) % positions.count]) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return .zero }
        var remaining = Float(distance).truncatingRemainder(dividingBy: total)
        for index in positions.indices where lengths[index] > 0 {
            let a = positions[index]
            let direction = (positions[(index + 1) % positions.count] - a) / lengths[index]
            if remaining <= lengths[index] {
                let side = SIMD3<Float>(-direction.z, 0, direction.x)
                let sideLength = simd_length(side)
                let lateral = sideLength > 0 ? side / sideLength * Float(offset) : .zero
                return a + direction * remaining + lateral + SIMD3(0, 0.3, 0)
            }
            remaining -= lengths[index]
        }
        return positions[0]
    }
}
