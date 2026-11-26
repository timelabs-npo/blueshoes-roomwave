import XCTest
import RealityKit
import UIKit
import RoomwaveCore
@testable import Roomwave

final class PilotNativeTests: XCTestCase {
    @MainActor
    func testBundledAssetHasFourRenderableLayersAndAnimation() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "RoomwavePilot", withExtension: "usdz", subdirectory: "Assets")
            ?? Bundle.main.url(forResource: "RoomwavePilot", withExtension: "usdz"))
        let asset = try await Entity(contentsOf: url)
        let entities = allEntities(in: asset)
        reportEntityTree(asset)
        for name in ["Skin", "Coat", "SkeletonOverlay", "MuscleOverlay"] {
            let layer = try XCTUnwrap(entities.first { $0.name == name }, "Missing \(name)")
            XCTAssertTrue(allEntities(in: layer).contains { $0.components[ModelComponent.self] != nil },
                          "\(name) has no imported renderable mesh")
        }
        XCTAssertTrue(entities.contains { !$0.availableAnimations.isEmpty },
                      "The authored glide animation did not import into RealityKit")
    }

    @MainActor
    func testControllerLoadsLayersWithoutMovingExternalRoot() async throws {
        let avatar = LayeredAvatarController()
        await avatar.loadBundledAsset()
        XCTAssertTrue(avatar.assetStatus.hasPrefix("Bundled RoomwavePilot.usdz loaded"),
                      avatar.assetStatus)
        let styledModels = allEntities(in: avatar.root).compactMap { $0.components[ModelComponent.self] }
        XCTAssertEqual(styledModels.count, 4)
        XCTAssertTrue(styledModels.allSatisfy { model in
            !model.materials.isEmpty && model.materials.allSatisfy { $0 is UnlitMaterial }
        }, "Ordinary controller loading must apply the same style used by the focused tests")
        avatar.root.position = SIMD3(4, 1, 7)
        avatar.setLayerVisibility(skeleton: true, muscle: true, skin: false, coat: false)
        XCTAssertEqual(avatar.root.findEntity(named: "SkeletonOverlay")?.isEnabled, true)
        XCTAssertEqual(avatar.root.findEntity(named: "MuscleOverlay")?.isEnabled, true)
        XCTAssertEqual(avatar.root.findEntity(named: "Skin")?.isEnabled, false)
        XCTAssertEqual(avatar.root.findEntity(named: "Coat")?.isEnabled, false)
        let coat = try XCTUnwrap(avatar.root.findEntity(named: "Coat"))
        let outfitTransform = coat.transform
        avatar.update(speed: 9, steering: 0.7, time: 1.3)
        XCTAssertEqual(avatar.root.position, SIMD3(4, 1, 7))
        XCTAssertEqual(coat.position, outfitTransform.translation)
        XCTAssertEqual(coat.scale, outfitTransform.scale)
        XCTAssertEqual(coat.orientation.vector, outfitTransform.rotation.vector,
                       "The complete skinned outfit must not rotate away from the body")
        avatar.setLayerVisibility(skeleton: false, muscle: false, skin: true, coat: true)
        XCTAssertEqual(avatar.root.findEntity(named: "Skin")?.isEnabled, true)
        XCTAssertEqual(avatar.root.findEntity(named: "Coat")?.isEnabled, true)
    }

    @MainActor
    func testOpaqueAvatarStylePreservesTintsSlotsAndMesh() throws {
        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor = .init(tint: UIColor(red: 0.12, green: 0.38, blue: 0.72, alpha: 1))
        pbr.faceCulling = .none
        pbr.readsDepth = false
        pbr.writesDepth = false
        let simple = SimpleMaterial(color: UIColor(red: 0.68, green: 0.21, blue: 0.36, alpha: 1),
                                    roughness: 0.7, isMetallic: false)
        let unlit = UnlitMaterial(color: UIColor(red: 0.17, green: 0.76, blue: 0.42, alpha: 1))
        let original: [any Material] = [pbr, simple, unlit, pbr, simple, unlit]
        let mesh = MeshResource.generateBox(width: 0.2, height: 0.3, depth: 0.4,
                                            cornerRadius: 0, splitFaces: true)
        let model = ModelEntity(mesh: mesh, materials: original)
        model.position = SIMD3(3, 2, 1)
        model.scale = SIMD3(0.8, 1.2, 0.9)
        let originalTransform = model.transform
        let summary = try AvatarOpaqueUnlitStyle.apply(to: model)
        let after = try XCTUnwrap(model.components[ModelComponent.self])
        XCTAssertTrue(after.mesh === mesh)
        XCTAssertEqual(after.materials.count, original.count)
        XCTAssertEqual(summary.modelCount, 1)
        XCTAssertEqual(summary.materialCount, 6)
        XCTAssertEqual(summary.physicallyBasedCount, 2)
        XCTAssertEqual(summary.simpleCount, 2)
        XCTAssertEqual(summary.unlitCount, 2)
        XCTAssertEqual(model.position, originalTransform.translation)
        XCTAssertEqual(model.scale, originalTransform.scale)
        XCTAssertEqual(model.orientation.vector, originalTransform.rotation.vector)
        for (before, material) in zip(original, after.materials) {
            let styled = try XCTUnwrap(material as? UnlitMaterial)
            assertSameTint(try importedTint(before), styled.color.tint)
            XCTAssertNil(styled.color.texture)
            XCTAssertEqual(styled.blending, .opaque)
        }
        let first = try XCTUnwrap(after.materials.first as? UnlitMaterial)
        XCTAssertEqual(first.faceCulling, .none)
        XCTAssertFalse(first.readsDepth)
        XCTAssertFalse(first.writesDepth)
    }

    @MainActor
    func testOpaqueAvatarStyleRejectsUnsupportedInputAtomically() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
        let texture = try await TextureResource(image: XCTUnwrap(image.cgImage), withName: nil,
                                               options: .init(semantic: .color))
        var baseTexture = PhysicallyBasedMaterial()
        baseTexture.baseColor = .init(tint: .white, texture: .init(texture))
        var normalTexture = PhysicallyBasedMaterial()
        normalTexture.normal = .init(texture: .init(texture))
        var simpleTexture = SimpleMaterial(color: .white, isMetallic: false)
        simpleTexture.roughness = .texture(texture)
        var unlitTexture = UnlitMaterial(color: .white)
        unlitTexture.color = .init(tint: .white, texture: .init(texture))
        let translucent = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.5))
        let rejected: [any Material] = [
            baseTexture, normalTexture, simpleTexture, unlitTexture, translucent, OcclusionMaterial()
        ]
        for material in rejected {
            let root = Entity()
            let first = ModelEntity(mesh: .generateBox(size: 0.1),
                                    materials: [SimpleMaterial(color: .red, isMetallic: false)])
            let second = ModelEntity(mesh: .generateBox(size: 0.1), materials: [material])
            root.addChild(first)
            root.addChild(second)
            XCTAssertThrowsError(try AvatarOpaqueUnlitStyle.apply(to: root))
            let unchanged = try XCTUnwrap(first.components[ModelComponent.self])
            XCTAssertTrue(unchanged.materials.first is SimpleMaterial,
                          "A later rejected slot must not leave earlier entities partly styled")
            XCTAssertTrue(first.parent === root)
            XCTAssertTrue(second.parent === root)
        }
    }

    @MainActor
    func testBundledOpaqueStylePreservesLayersMeshAndAnimationOwnership() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "RoomwavePilot", withExtension: "usdz", subdirectory: "Assets")
            ?? Bundle.main.url(forResource: "RoomwavePilot", withExtension: "usdz"))
        let asset = try await Entity(contentsOf: url)
        let entities = allEntities(in: asset)
        let identities = entities.map { ObjectIdentifier($0) }
        let parents = entities.map { $0.parent.map { ObjectIdentifier($0) } }
        let poses = entities.map(\.transform)
        let animations = entities.map { $0.availableAnimations.map { $0.name } }
        let models = try entities.compactMap { entity -> (Entity, ModelComponent, [UIColor])? in
            guard let model = entity.components[ModelComponent.self] else { return nil }
            return (entity, model, try model.materials.map { try importedTint($0) })
        }
        XCTAssertEqual(models.count, 4, "The authored four-layer import must remain intact")
        let summary = try AvatarOpaqueUnlitStyle.apply(to: asset)
        XCTAssertEqual(summary.modelCount, models.count)
        XCTAssertEqual(summary.materialCount, models.reduce(0) { $0 + $1.1.materials.count })
        XCTAssertEqual(allEntities(in: asset).map { ObjectIdentifier($0) }, identities)
        for (index, entity) in entities.enumerated() {
            XCTAssertEqual(entity.parent.map { ObjectIdentifier($0) }, parents[index])
            XCTAssertEqual(entity.position, poses[index].translation)
            XCTAssertEqual(entity.scale, poses[index].scale)
            XCTAssertEqual(entity.orientation.vector, poses[index].rotation.vector)
            XCTAssertEqual(entity.availableAnimations.map { $0.name }, animations[index])
        }
        for name in ["Skin", "Coat", "SkeletonOverlay", "MuscleOverlay"] {
            let layer = try XCTUnwrap(entities.first { $0.name == name })
            XCTAssertNotNil(layer.components[ModelComponent.self])
            XCTAssertEqual(layer.availableAnimations.count, 3)
            XCTAssertEqual(layer.availableAnimations.first?.name,
                           "/RoomwavePilot/\(name)/RoomwaveGlide[0]")
        }
        for (entity, original, colors) in models {
            let after = try XCTUnwrap(entity.components[ModelComponent.self])
            XCTAssertTrue(after.mesh === original.mesh)
            XCTAssertEqual(after.materials.count, original.materials.count)
            for (color, material) in zip(colors, after.materials) {
                let styled = try XCTUnwrap(material as? UnlitMaterial)
                assertSameTint(color, styled.color.tint)
                XCTAssertEqual(styled.blending, .opaque)
            }
        }
    }

    @MainActor
    private func importedTint(_ material: any Material) throws -> UIColor {
        if let value = material as? PhysicallyBasedMaterial { return value.baseColor.tint }
        if let value = material as? SimpleMaterial { return value.color.tint }
        if let value = material as? UnlitMaterial { return value.color.tint }
        XCTFail("The known fixture must expose a supported base tint")
        throw AvatarOpaqueUnlitStyle.Unsupported(reason: "unexpected fixture material")
    }

    @MainActor
    private func assertSameTint(_ expected: UIColor, _ actual: UIColor,
                                file: StaticString = #filePath, line: UInt = #line) {
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        XCTAssertTrue(expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea), file: file, line: line)
        XCTAssertTrue(actual.getRed(&ar, green: &ag, blue: &ab, alpha: &aa), file: file, line: line)
        for (lhs, rhs) in zip([er, eg, eb, ea], [ar, ag, ab, aa]) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.000_001, file: file, line: line)
        }
    }

    @MainActor
    func testRealImagePixelsProduceDistinctPhotoTracks() async throws {
        let first = try await PhotoMapImporter.sample(from: makePhoto(vertical: true))
        let second = try await PhotoMapImporter.sample(from: makePhoto(vertical: false))
        XCTAssertEqual(first.source, .photoDerived)
        XCTAssertEqual(second.source, .photoDerived)
        XCTAssertNotEqual(first.points, second.points)
        let trackA = try TrackGenerator.makeTrack(from: ScanNormalizer.normalize(first), seed: 27)
        let trackB = try TrackGenerator.makeTrack(from: ScanNormalizer.normalize(second), seed: 27)
        XCTAssertEqual(trackA.source, .photoDerived)
        XCTAssertEqual(trackB.source, .photoDerived)
        XCTAssertNotEqual(trackA.points, trackB.points,
                          "Different picture structure must affect actual track geometry")
        XCTAssertTrue(TrackValidator.validate(trackA).isEmpty)
        XCTAssertTrue(TrackValidator.validate(trackB).isEmpty)
    }

    @MainActor
    private func makePhoto(vertical: Bool) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor.black.setFill()
            if vertical {
                context.fill(CGRect(x: 12, y: 5, width: 24, height: 80))
                context.fill(CGRect(x: 65, y: 20, width: 20, height: 45))
            } else {
                context.fill(CGRect(x: 5, y: 12, width: 80, height: 24))
                context.fill(CGRect(x: 20, y: 65, width: 45, height: 20))
            }
        }
        return try XCTUnwrap(image.pngData())
    }

    @MainActor
    private func allEntities(in root: Entity) -> [Entity] {
        [root] + root.children.flatMap { allEntities(in: $0) }
    }
    // Runtime import evidence: USD validation cannot show RealityKit's imported hierarchy.
    @MainActor
    private func reportEntityTree(_ entity: Entity, depth: Int = 0) {
        guard depth < 32 else { return }
        let bounds = entity.visualBounds(relativeTo: nil).extents
        let components = String(describing: entity.components).prefix(400)
        let animationNames = entity.availableAnimations.map { $0.name ?? "<unnamed>" }
        print("ASSET_TREE \(String(repeating: "  ", count: depth))\(entity.name) model=\(entity.components[ModelComponent.self] != nil) animations=\(entity.availableAnimations.count) names=\(animationNames) bounds=\(bounds) components=\(components)")
        for child in entity.children { reportEntityTree(child, depth: depth + 1) }
    }

}
