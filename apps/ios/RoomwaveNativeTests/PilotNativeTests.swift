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
