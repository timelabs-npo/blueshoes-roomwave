import Foundation
import RealityKit
import UIKit
import simd

/// Visuals only: TrackScene owns root placement, heading and world scale.
/// The skeleton/muscle overlays are stylized helpers, not medical anatomy.
@MainActor
final class LayeredAvatarController {
    let root: Entity
    private(set) var assetStatus = "Procedural fallback — bundled avatar not loaded."

    private enum Layer: String, CaseIterable, Hashable {
        case skeleton = "SkeletonOverlay"
        case muscle = "MuscleOverlay"
        case skin = "Skin"
        case coat = "Coat"
    }

    private let motionContainer = Entity()
    private let fallback = Entity()
    private var layers: [Layer: [Entity]] = [:]
    private var visibility: [Layer: Bool] = [
        .skeleton: false, .muscle: false, .skin: true, .coat: true
    ]
    private var coatRestPoses: [(entity: Entity, transform: Transform)] = []
    private var bundledAsset: Entity?
    private var animationPlayback: AnimationPlaybackController?
    private var isLoading = false

    init() {
        root = Entity()
        root.name = "RoomwaveAvatarRoot"
        motionContainer.name = "AvatarProceduralMotion"
        fallback.name = "ProceduralFallback_NotBundledAvatar"
        root.addChild(motionContainer)
        motionContainer.addChild(fallback)
        makeFallback()
        applyLayerVisibility()
    }

    /// Local bundle only. Successful loads are idempotent; failed loads may be retried.
    /// Keep the fallback attached until a complete renderable layer set is ready.
    func loadBundledAsset() async {
        guard !isLoading, bundledAsset == nil else { return }
        isLoading = true
        defer { isLoading = false }
        assetStatus = "Loading RoomwavePilot.usdz — procedural fallback visible."

        guard !Task.isCancelled else {
            reportFallback("asset load cancelled")
            return
        }
        guard let url = Bundle.main.url(forResource: "RoomwavePilot", withExtension: "usdz",
                                        subdirectory: "Assets")
            ?? Bundle.main.url(forResource: "RoomwavePilot", withExtension: "usdz") else {
            reportFallback("RoomwavePilot.usdz is missing from Assets and the bundle root")
            return
        }

        do {
            // RealityKit performs its asynchronous load; entity ownership stays on MainActor.
            let asset = try await Entity(contentsOf: url)
            try Task.checkCancellation()
            let entities = hierarchy(of: asset)
            var found: [Layer: [Entity]] = [:]
            for layer in Layer.allCases {
                found[layer] = entities.filter { $0.name == layer.rawValue }
            }
            let missing = Layer.allCases.filter { layer in
                let matches = found[layer] ?? []
                return matches.isEmpty || !matches.allSatisfy { match in
                    hierarchy(of: match).contains { $0.components[ModelComponent.self] != nil }
                }
            }
            guard missing.isEmpty else {
                reportFallback("missing or non-renderable visual layers: " +
                               missing.map(\.rawValue).joined(separator: ", "))
                return
            }

            // Independent toggles need independent layer subtrees. Never hide a rig
            // through a visual layer, or hide an overlay by switching off Skin.
            let visualLayers = Layer.allCases.flatMap { found[$0] ?? [] }
            let overlaps = visualLayers.contains { layer in
                hierarchy(of: layer).dropFirst().contains { descendant in
                    descendant.name == "SkeletonRig" ||
                    visualLayers.contains { $0 === descendant }
                }
            }
            guard !overlaps else {
                reportFallback("visual layers must be separate from each other and SkeletonRig")
                return
            }
            try Task.checkCancellation()

            // No reparenting inside the imported hierarchy: retain authored rig bindings.
            fallback.removeFromParent()
            motionContainer.addChild(asset)
            bundledAsset = asset
            layers = found
            coatRestPoses = (found[.coat] ?? []).map { ($0, $0.transform) }
            applyLayerVisibility() // Includes choices made while the load was suspended.

            // Play just one clip on its owning entity, avoiding competing parent/child
            // clips. Procedural body motion lives outside the imported animation tree.
            var hasEmbeddedAnimation = false
            for entity in entities {
                if let animation = entity.availableAnimations.first {
                    animationPlayback = entity.playAnimation(animation.repeat(),
                                                            transitionDuration: 0.2)
                    hasEmbeddedAnimation = true
                    break
                }
            }
            assetStatus = "Bundled RoomwavePilot.usdz loaded; four visual layers found; " +
                (hasEmbeddedAnimation ? "embedded animation + procedural motion." :
                    "no embedded animation; procedural motion only.") +
                " Skeleton/muscle overlays are stylized, not medical anatomy."
        } catch is CancellationError {
            reportFallback("asset load cancelled")
        } catch {
            reportFallback("RoomwavePilot.usdz could not be loaded: \(error.localizedDescription)")
        }
    }

    /// Inputs are visual cues, never gameplay state. Time is elapsed seconds.
    func update(speed: Double, steering: Double, time: Double) {
        let pace = Float(speed.isFinite ? min(max(speed, 0), 12) / 12 : 0)
        let turn = Float(steering.isFinite ? min(max(steering, -1), 1) : 0)
        // Reduce before converting to Float/multiplying, including extreme finite input.
        // Integer-frequency waves share this period, so wrapping has no phase jump.
        let phase = Float(time.isFinite ? time.truncatingRemainder(dividingBy: 1) : 0) *
            (2 * Float.pi)
        let bounce = sin(phase * 2)
        motionContainer.position = SIMD3(0, 0.008 + (1 + bounce) * 0.012 * pace, 0)
        motionContainer.orientation =
            simd_quatf(angle: -turn * 0.28, axis: SIMD3(0, 0, 1)) *
            simd_quatf(angle: -pace * 0.07, axis: SIMD3(1, 0, 0))
        let squash = bounce * 0.012 * pace
        motionContainer.scale = SIMD3(1 + squash * 0.5, 1 - squash, 1 + squash * 0.5)

        // A small rigid coat accent, not cloth simulation. Always start from the
        // authored local transform, so repeated calls cannot accumulate drift.
        for pose in coatRestPoses {
            var transform = pose.transform
            transform.rotation = pose.transform.rotation *
                simd_quatf(angle: pace * 0.07 + sin(phase * 3) * (0.012 + pace * 0.035),
                           axis: SIMD3(1, 0, 0)) *
                simd_quatf(angle: turn * 0.05, axis: SIMD3(0, 0, 1))
            pose.entity.transform = transform
        }
    }

    func setLayerVisibility(skeleton: Bool, muscle: Bool, skin: Bool, coat: Bool) {
        visibility = [.skeleton: skeleton, .muscle: muscle, .skin: skin, .coat: coat]
        applyLayerVisibility()
    }

    private func applyLayerVisibility() {
        for layer in Layer.allCases {
            for entity in layers[layer] ?? [] {
                entity.isEnabled = visibility[layer] ?? true
            }
        }
    }

    private func reportFallback(_ reason: String) {
        assetStatus = "Procedural fallback — \(reason). No bundled avatar layers loaded."
    }

    private func hierarchy(of entity: Entity) -> [Entity] {
        var result: [Entity] = []
        var pending = [entity]
        while let next = pending.popLast() {
            result.append(next)
            pending.append(contentsOf: next.children.reversed())
        }
        return result
    }

    private func makeFallback() {
        // Approximately 1 m tall, Y-up, front at -Z. Bright unlit helper shapes
        // remain visible in a scene without lighting and never impersonate the CC0 asset.
        for layer in Layer.allCases {
            let group = Entity()
            group.name = "Fallback_" + layer.rawValue
            fallback.addChild(group)
            layers[layer] = [group]
        }
        guard let skin = layers[.skin]?.first, let coat = layers[.coat]?.first,
              let skeleton = layers[.skeleton]?.first, let muscle = layers[.muscle]?.first else {
            return
        }
        let head = ModelEntity(mesh: .generateSphere(radius: 0.12),
                               materials: [UnlitMaterial(color: .systemYellow)])
        head.position = SIMD3(0, 0.86, 0)
        skin.addChild(head)
        addBox(to: skin, size: SIMD3(0.28, 0.34, 0.16), at: SIMD3(0, 0.57, 0), color: .white)
        for side in [Float(-1), Float(1)] {
            addBox(to: skin, size: SIMD3(0.08, 0.32, 0.12),
                   at: SIMD3(side * 0.2, 0.57, 0), color: .white)
            addBox(to: skin, size: SIMD3(0.10, 0.34, 0.12),
                   at: SIMD3(side * 0.08, 0.18, 0), color: .white)
            addBox(to: skeleton, size: SIMD3(0.025, 0.30, 0.025),
                   at: SIMD3(side * 0.08, 0.18, -0.10), color: .systemCyan)
            addBox(to: muscle, size: SIMD3(0.045, 0.22, 0.025),
                   at: SIMD3(side * 0.085, 0.57, -0.12), color: .systemPink)
        }
        addBox(to: skeleton, size: SIMD3(0.025, 0.38, 0.025),
               at: SIMD3(0, 0.56, -0.105), color: .systemCyan)
        addBox(to: skeleton, size: SIMD3(0.28, 0.025, 0.025),
               at: SIMD3(0, 0.68, -0.105), color: .systemCyan)
        // Shoulder pivot makes this simple panel read as a trailing coat.
        coat.position = SIMD3(0, 0.70, 0.13)
        addBox(to: coat, size: SIMD3(0.38, 0.42, 0.035),
               at: SIMD3(0, -0.21, 0), color: .systemPurple)
        coatRestPoses = [(coat, coat.transform)]
    }

    private func addBox(to parent: Entity, size: SIMD3<Float>, at position: SIMD3<Float>,
                        color: UIColor) {
        let model = ModelEntity(mesh: .generateBox(size: size),
                                materials: [UnlitMaterial(color: color)])
        model.position = position
        parent.addChild(model)
    }
}
