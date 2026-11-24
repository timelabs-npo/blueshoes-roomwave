import ARKit
import RealityKit
import RoomwaveCore
import SwiftUI
import UIKit
import simd

@MainActor
struct RoomCapturePreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        if view.session !== session { view.session = session }
    }
}

/// Finalized game geometry, shown without a camera feed.
@MainActor
struct TrackScene: UIViewRepresentable {
    let track: TrackDefinition
    let race: RaceState?
    var steering: Double = 0
    var avatarSkeleton = false
    var avatarMuscle = false
    var avatarSkin = true
    var avatarCoat = true

    @MainActor
    final class Coordinator {
        var track: TrackDefinition?
        let root = AnchorEntity(world: .zero)
        let avatar = LayeredAvatarController()
        let camera = PerspectiveCamera()
        var loadTask: Task<Void, Never>?
        var cameraPosition: SIMD3<Float>?
        var cameraTarget: SIMD3<Float>?
        var overviewCenter = SIMD3<Float>.zero
        var overviewHeight: Float = 25
        var wasRacing = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.025, green: 0.018, blue: 0.075, alpha: 1))
        view.environment.lighting.intensityExponent = 1
        view.scene.addAnchor(context.coordinator.root)
        let coordinator = context.coordinator
        coordinator.loadTask = Task { [weak coordinator] in
            await coordinator?.avatar.loadBundledAsset()
        }
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.track != track {
            rebuild(coordinator)
        }
        let position = routePose(distance: race?.distance ?? 0, offset: race?.lateralOffset ?? 0)
        coordinator.avatar.root.position = position.position + SIMD3(0, 0.12, 0)
        let orientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: position.direction)
        coordinator.avatar.root.orientation = simd_slerp(coordinator.avatar.root.orientation, orientation, 0.3)
        coordinator.avatar.setLayerVisibility(skeleton: avatarSkeleton, muscle: avatarMuscle,
                                               skin: avatarSkin, coat: avatarCoat)
        let time = Double(race?.tick ?? 0) / Double(track.rules.tickRate)
        coordinator.avatar.update(speed: race?.speed ?? 0, steering: steering, time: time)

        let racing = race != nil
        if racing != coordinator.wasRacing {
            coordinator.cameraPosition = nil
            coordinator.cameraTarget = nil
            coordinator.wasRacing = racing
        }
        let desiredPosition: SIMD3<Float>
        let desiredTarget: SIMD3<Float>
        if racing {
            // The rider remains large enough to read its pose and layered animation.
            desiredPosition = position.position - position.direction * 4.4 + SIMD3(0, 2.7, 0)
            desiredTarget = routePose(distance: (race?.distance ?? 0) + 5.5, offset: 0).position + SIMD3(0, 0.35, 0)
        } else {
            desiredPosition = coordinator.overviewCenter + SIMD3(0, coordinator.overviewHeight, coordinator.overviewHeight * 0.42)
            desiredTarget = coordinator.overviewCenter
        }
        let cameraPosition = coordinator.cameraPosition.map { $0 + (desiredPosition - $0) * 0.18 } ?? desiredPosition
        let cameraTarget = coordinator.cameraTarget.map { $0 + (desiredTarget - $0) * 0.18 } ?? desiredTarget
        coordinator.cameraPosition = cameraPosition
        coordinator.cameraTarget = cameraTarget
        coordinator.camera.look(at: cameraTarget, from: cameraPosition, relativeTo: nil)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        coordinator.root.children.removeAll()
        view.scene.anchors.removeAll()
    }

    private func rebuild(_ coordinator: Coordinator) {
        coordinator.root.children.removeAll()
        coordinator.track = track
        let positions = track.points.map { vector($0.position) }
        guard positions.count >= 3 else { return }
        let roadMaterial = UnlitMaterial(color: UIColor(red: 0.035, green: 0.13, blue: 0.20, alpha: 1))
        let edgeMaterial = UnlitMaterial(color: UIColor(red: 0.14, green: 0.97, blue: 1, alpha: 1))
        let gateMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.51, blue: 0.2, alpha: 1))
        for index in positions.indices {
            let a = positions[index]
            let b = positions[(index + 1) % positions.count]
            let delta = b - a
            let length = simd_length(delta)
            guard length > 0 else { continue }
            let direction = delta / length
            let orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: direction)
            // Native admission currently guarantees constant width.
            let width = Float(track.points[index].halfWidth + track.points[(index + 1) % positions.count].halfWidth)
            let road = ModelEntity(mesh: .generateBox(size: SIMD3(width, 0.08, length + 0.035)),
                                   materials: [roadMaterial])
            road.position = (a + b) / 2
            road.orientation = orientation
            coordinator.root.addChild(road)
            let rawSide = SIMD3<Float>(-direction.z, 0, direction.x)
            let side = simd_length(rawSide) > 0 ? simd_normalize(rawSide) : SIMD3(1, 0, 0)
            for sign in [Float(-1), Float(1)] {
                let edge = ModelEntity(mesh: .generateBox(size: SIMD3(0.045, 0.08, length + 0.05)),
                                       materials: [edgeMaterial])
                edge.position = (a + b) / 2 + side * (sign * width / 2) + SIMD3(0, 0.055, 0)
                edge.orientation = orientation
                coordinator.root.addChild(edge)
            }
            if track.points[index].isGate {
                let stripe = ModelEntity(mesh: .generateBox(size: SIMD3(width, 0.04, 0.12)),
                                         materials: [gateMaterial])
                stripe.position = a + SIMD3(0, 0.08, 0)
                stripe.orientation = orientation
                coordinator.root.addChild(stripe)
                for sign in [Float(-1), Float(1)] {
                    let post = ModelEntity(mesh: .generateBox(size: SIMD3(0.075, 1.4, 0.075)),
                                           materials: [gateMaterial])
                    post.position = a + side * (sign * (width / 2 + 0.12)) + SIMD3(0, 0.7, 0)
                    coordinator.root.addChild(post)
                }
            }
        }
        let minimum = positions.reduce(positions[0]) { simd_min($0, $1) }
        let maximum = positions.reduce(positions[0]) { simd_max($0, $1) }
        let center = (minimum + maximum) / 2
        let extent = maximum - minimum
        coordinator.overviewCenter = center
        coordinator.overviewHeight = max(simd_length(extent) * 0.9, 12)
        let island = ModelEntity(mesh: .generateBox(size: SIMD3(max(extent.x + 5, 15), 0.3, max(extent.z + 5, 15))),
                                 materials: [UnlitMaterial(color: UIColor(red: 0.075, green: 0.045, blue: 0.16, alpha: 1))])
        island.position = center + SIMD3(0, -0.38, 0)
        coordinator.root.addChild(island)
        let light = DirectionalLight()
        light.light.intensity = 3500
        light.look(at: center, from: center + SIMD3(5, 12, 6), relativeTo: nil)
        coordinator.root.addChild(light)
        let fill = DirectionalLight()
        fill.light.intensity = 1200
        fill.light.color = .cyan
        fill.look(at: center, from: center + SIMD3(-7, 6, -5), relativeTo: nil)
        coordinator.root.addChild(fill)
        coordinator.root.addChild(coordinator.camera)
        coordinator.root.addChild(coordinator.avatar.root)
        coordinator.cameraPosition = nil
        coordinator.cameraTarget = nil
    }

    private func vector(_ point: Vector3) -> SIMD3<Float> {
        SIMD3(Float(point.x), Float(point.y), Float(point.z))
    }

    private func routePose(distance: Double, offset: Double) -> (position: SIMD3<Float>, direction: SIMD3<Float>) {
        let positions = track.points.map { vector($0.position) }
        guard positions.count >= 3 else { return (.zero, SIMD3(0, 0, -1)) }
        let lengths = positions.indices.map { simd_distance(positions[$0], positions[($0 + 1) % positions.count]) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return (.zero, SIMD3(0, 0, -1)) }
        var remaining = Float(distance).truncatingRemainder(dividingBy: total)
        if remaining < 0 { remaining += total }
        for index in positions.indices where lengths[index] > 0 {
            let a = positions[index]
            let direction = (positions[(index + 1) % positions.count] - a) / lengths[index]
            if remaining <= lengths[index] {
                let side = SIMD3<Float>(-direction.z, 0, direction.x)
                let lateral = simd_length(side) > 0 ? simd_normalize(side) * Float(offset) : .zero
                return (a + direction * remaining + lateral, direction)
            }
            remaining -= lengths[index]
        }
        return (positions[0], SIMD3(0, 0, -1))
    }
}
