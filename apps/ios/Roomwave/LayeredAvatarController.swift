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
    private var animationPlaybacks: [AnimationPlaybackController] = []
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

            // Each layer now owns its own rig and can be disabled independently.
            // Visual layer subtrees must still not contain one another.
            let visualLayers = Layer.allCases.flatMap { found[$0] ?? [] }
            let overlaps = visualLayers.contains { layer in
                hierarchy(of: layer).dropFirst().contains { descendant in
                    visualLayers.contains { $0 === descendant }
                }
            }
            guard !overlaps else {
                reportFallback("visual layers must be separate from each other")
                return
            }
            try Task.checkCancellation()

            // This ordinary art policy is identical on device and simulator.
            // Reject unsupported imported materials before replacing the visible fallback.
            let materialStyle = try AvatarOpaqueUnlitStyle.apply(to: asset)

            // No reparenting inside the imported hierarchy: retain authored rig bindings.
            fallback.removeFromParent()
            motionContainer.addChild(asset)
            bundledAsset = asset
            layers = found
            // The imported Coat is a complete skinned outfit (including trousers
            // and hood). Its authored tail joint supplies cloth-like motion.
            // Rotating that whole SkelRoot would detach the outfit from Skin.
            coatRestPoses.removeAll()
            applyLayerVisibility() // Includes choices made while the load was suspended.

            // Four independent SkelRoots may expose one clip per layer or a
            // root animation library. Choose one ownership level, never both.
            let perLayerOwners = Layer.allCases.compactMap { layer -> Entity? in
                (found[layer] ?? []).flatMap { hierarchy(of: $0) }
                    .first { !$0.availableAnimations.isEmpty }
            }
            animationPlaybacks.removeAll()
            if perLayerOwners.count == Layer.allCases.count {
                for owner in perLayerOwners {
                    if let clip = owner.availableAnimations.first {
                        animationPlaybacks.append(owner.playAnimation(clip.repeat(), transitionDuration: 0))
                    }
                }
            } else if !asset.availableAnimations.isEmpty {
                // The imported root resources have disjoint authored rig bindings.
                for clip in asset.availableAnimations {
                    animationPlaybacks.append(asset.playAnimation(clip.repeat(), transitionDuration: 0))
                }
            } else {
                // No overlapping ancestor/descendant playback. Missing clips stay
                // visible in status rather than claiming four animated layers.
                for owner in perLayerOwners {
                    if let clip = owner.availableAnimations.first {
                        animationPlaybacks.append(owner.playAnimation(clip.repeat(), transitionDuration: 0))
                    }
                }
            }
            #if DEBUG
            print("AVATAR_MATERIAL_STYLE opaque_unlit models=\(materialStyle.modelCount) slots=\(materialStyle.materialCount) pbr=\(materialStyle.physicallyBasedCount) simple=\(materialStyle.simpleCount) unlit=\(materialStyle.unlitCount) animation_owners=\(animationPlaybacks.count)")
            #endif
            let hasEmbeddedAnimation = !animationPlaybacks.isEmpty
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

        // Only the procedural fallback has a rigid coat panel. The bundled
        // outfit keeps its rig transform and uses its embedded skinned animation.
        for pose in coatRestPoses {
            var transform = pose.transform
            transform.rotation = pose.transform.rotation *
                simd_quatf(angle: pace * 0.07 + sin(phase * 3) * (0.012 + pace * 0.035),
                           axis: SIMD3(1, 0, 0)) *
                simd_quatf(angle: turn * 0.05, axis: SIMD3(0, 0, 1))
            pose.entity.transform = transform
        }
    }

    /// Roomwave's ordinary imported materials are unlit. Style only the exact
    /// authored coat meshes; preserve the original rig, mesh, depth and eye tint.
    /// This is opt-in for Arcade and never mutates the underlying USDZ resource.
    func tintArcadeCoat(cloth: UIColor, panel: UIColor, trim: UIColor, badge: UIColor) {
        let authoredColors: [String: UIColor] = [
            "Coat_Jacket": cloth, "Coat_Hood": cloth, "Coat_Tail": cloth,
            "Coat_Trousers": panel, "Coat_KneePanels": panel, "Coat_BlueBoots": panel,
            "Coat_Gauntlets": panel, "Coat_BootCuffs": trim, "Coat_Piping_0": trim,
            "Coat_Piping_1": trim, "Coat_CyanDiamond": badge
        ]
        for layer in layers[.coat] ?? [] {
            for entity in hierarchy(of: layer) {
                guard let tint = authoredColors[entity.name],
                      var model = entity.components[ModelComponent.self],
                      model.materials.count == 1,
                      var unlit = model.materials.first as? UnlitMaterial else { continue }
                unlit.color = .init(tint: tint)
                model.materials = [unlit]
                entity.components.set(model)
            }
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

/// Ordinary avatar art policy on simulator and device. The USDZ, mesh resources,
/// skin bindings and animation owners remain authored; only material slots change.
@MainActor
enum AvatarOpaqueUnlitStyle {
    struct Summary {
        var modelCount = 0
        var materialCount = 0
        var physicallyBasedCount = 0
        var simpleCount = 0
        var unlitCount = 0
    }

    struct Unsupported: LocalizedError {
        let reason: String
        var errorDescription: String? { "Opaque avatar styling unavailable: \(reason)" }
    }

    /// Validate the complete import first, so rejection cannot leave a partly styled asset.
    static func apply(to root: Entity) throws -> Summary {
        var pending = [root]
        var replacements: [(Entity, ModelComponent)] = []
        var summary = Summary()
        while let entity = pending.popLast() {
            pending.append(contentsOf: entity.children.reversed())
            guard var model = entity.components[ModelComponent.self] else { continue }
            guard !model.materials.isEmpty else {
                throw Unsupported(reason: "\(entity.name) has no material slots")
            }
            var styled: [any Material] = []
            for (slot, material) in model.materials.enumerated() {
                styled.append(try convert(material, location: "\(entity.name)[\(slot)]"))
                summary.materialCount += 1
                if material is PhysicallyBasedMaterial { summary.physicallyBasedCount += 1 }
                else if material is SimpleMaterial { summary.simpleCount += 1 }
                else if material is UnlitMaterial { summary.unlitCount += 1 }
            }
            // Preserve the imported ModelComponent, including its exact mesh resource.
            model.materials = styled
            replacements.append((entity, model))
            summary.modelCount += 1
        }
        guard summary.modelCount > 0 else {
            throw Unsupported(reason: "the import has no renderable models")
        }
        for (entity, model) in replacements { entity.components.set(model) }
        return summary
    }

    private static func convert(_ material: any Material, location: String) throws -> UnlitMaterial {
        let tint: UIColor
        var result: UnlitMaterial
        switch material {
        case let value as PhysicallyBasedMaterial:
            let textures: [(String, Bool)] = [
                ("base color", value.baseColor.texture != nil),
                ("roughness", value.roughness.texture != nil),
                ("metallic", value.metallic.texture != nil),
                ("normal", value.normal.texture != nil),
                ("ambient occlusion", value.ambientOcclusion.texture != nil),
                ("specular", value.specular.texture != nil),
                ("clearcoat", value.clearcoat.texture != nil),
                ("clearcoat roughness", value.clearcoatRoughness.texture != nil),
                ("clearcoat normal", value.clearcoatNormal.texture != nil),
                ("sheen", value.sheen?.texture != nil),
                ("anisotropy level", value.anisotropyLevel.texture != nil),
                ("anisotropy angle", value.anisotropyAngle.texture != nil),
                ("emissive color", value.emissiveColor.texture != nil),
                ("subsurface color", value.subsurfaceColor.texture != nil),
                ("subsurface weight", value.subsurfaceWeight.texture != nil),
                ("subsurface radius", value.subsurfaceRadius.texture != nil),
                ("subsurface radius scale", value.subsurfaceRadiusScale.texture != nil),
                ("subsurface anisotropy", value.subsurfaceScatterAnisotropy.texture != nil),
                ("bent normal", value.bentNormal.texture != nil)
            ]
            if let texture = textures.first(where: { $0.1 }) {
                throw Unsupported(reason: "\(location) uses an unsupported \(texture.0) texture")
            }
            guard case .opaque = value.blending else {
                throw Unsupported(reason: "\(location) uses transparent PBR blending")
            }
            tint = value.baseColor.tint
            result = UnlitMaterial(color: tint)
            result.faceCulling = value.faceCulling
            result.triangleFillMode = value.triangleFillMode
            result.readsDepth = value.readsDepth
            result.writesDepth = value.writesDepth
        case let value as SimpleMaterial:
            guard value.color.texture == nil,
                  isConstant(value.roughness), isConstant(value.metallic) else {
                throw Unsupported(reason: "\(location) uses an unsupported SimpleMaterial texture")
            }
            tint = value.color.tint
            result = UnlitMaterial(color: tint)
            result.faceCulling = value.faceCulling
            result.triangleFillMode = value.triangleFillMode
            result.readsDepth = value.readsDepth
            result.writesDepth = value.writesDepth
        case let value as UnlitMaterial:
            guard value.color.texture == nil else {
                throw Unsupported(reason: "\(location) uses an unsupported UnlitMaterial texture")
            }
            guard case .opaque = value.blending else {
                throw Unsupported(reason: "\(location) uses transparent unlit blending")
            }
            tint = value.color.tint
            result = value
        default:
            throw Unsupported(reason: "\(location) uses unsupported \(String(describing: type(of: material)))")
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              [red, green, blue, alpha].allSatisfy({ $0.isFinite }),
              abs(alpha - 1) < 0.000_001 else {
            throw Unsupported(reason: "\(location) has a nonfinite, non-RGB or nonopaque base tint")
        }
        // Use the imported color itself, preserving its color space and components.
        result.color = .init(tint: tint)
        result.blending = .opaque
        return result
    }

    private static func isConstant(_ parameter: MaterialScalarParameter) -> Bool {
        if case .float(let value) = parameter { return value.isFinite }
        return false
    }
}
