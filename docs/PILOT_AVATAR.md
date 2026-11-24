# Avatar lane handoff

Implemented code in `apps/ios/Roomwave/LayeredAvatarController.swift`; UI, TrackScene,
artwork, packaging and licenses remain with their coordinators. Native compilation
and device operation are **NOT VERIFIED** on this Windows host.

- `@MainActor final class LayeredAvatarController` provides the frozen `root`,
  initializer, async nonthrowing loader, update and four-layer visibility methods.
  `assetStatus` is readable with a private setter; it is not an observable publisher.
- TrackScene attaches and places `root`. The controller never writes its transform
  after initialization. Lean, bob and squash use `AvatarProceduralMotion`, its child.
  Positive steering leans toward +X when facing -Z. Speed 0...12 controls visual
  amplitude; other finite speeds/steering are clamped and nonfinite inputs use zero.
  Pass elapsed seconds to `time`; repeated identical inputs produce the same pose.
- Loads only `Bundle.main` `Assets/RoomwavePilot.usdz`, then bundle-root lookup if
  absent from Assets. No downloads. Successful calls are idempotent; overlapping
  calls are ignored, and failed/cancelled calls may be retried. The existing fallback
  remains attached throughout loading; it is removed only after asset validation.
- Requires renderable subtrees named exactly `Skin`, `Coat`, `SkeletonOverlay`,
  `MuscleOverlay`. Layer subtrees must be independent and must not contain
  `SkeletonRig`; visibility changes never target the articulation rig. Missing,
  unreadable or incompatible assets retain the explicitly labeled procedural
  fallback and a failure reason, without a bundled-loaded claim.
- Defaults: skin/coat visible, skeleton/muscle hidden. Toggles persist through async
  load, including choices made while suspended, and apply to every exact-name match.
  Turning all layers off intentionally hides the avatar.
- Plays the first available embedded clip on its owning entity in a loop. Body
  procedural motion is outside the imported hierarchy, which is not reparented
  internally. Coat adds a small rigid local rotation from its authored rest transform;
  this is not cloth physics. Embedded clips should animate the rig, not the `Coat`
  entity transform, to avoid competition with this accent. No baked animation is
  invented or claimed if `availableAnimations` is empty.
- Expects the asset handoff's Y-up, forward -Z, approximately 1 m character, with
  origin at its feet. No automatic rescaling, recentering or rig retargeting is done.
  Skeleton/muscle overlays (including fallback helper bars) are stylized derived
  animation helpers, not medically accurate anatomy. The imported rig is separate.
  CC0 source/license and actual asset axis/scale/clip inspection belong to the asset
  handoff; they have not been verified here. No USDZ was present during this task.

## Behavior checks for native integration (not executed here)

1. Set root position, orientation and scale to nonidentity values. Call `update`
   for speed 0/4/12, steering -1/0/1 and varied time; assert the entire root transform
   remains exactly unchanged while its motion child changes. Repeating the same
   inputs must produce equal child transforms, with no coat drift.
2. Test NaN, infinities and greatest finite Double in each input. Assert every
   resulting child transform component is finite; steering/speed saturation should
   match the corresponding endpoint pose. Check continuity across whole seconds.
3. Toggle each of the four layers independently, including all-off and overlays-only,
   before loading, while awaiting loading, and after success. Assert only the named
   visual subtrees change `isEnabled`; `SkeletonRig` remains enabled.
4. Bundle the valid USDZ once under Assets and once at bundle root. Each load must
   replace the fallback with one imported entity. Repeated calls must not duplicate
   entities or animation playback. Inspect front direction, foot origin and height.
5. Remove, corrupt, or supply an asset missing a named/renderable layer; also test
   nested visual layers or a rig under a visual layer. Expect the fallback to remain,
   failure status, preserved toggles, no partial imported subtree and no loaded claim.
   Cancel a load and retry from a new task; check the same invariants.
6. With a rig clip, observe looping articulation plus lean/bob/coat motion. With a
   clip-free USDZ, expect only procedural motion and an explicit no-clip status.
   Confirm the shipped clip does not animate the `Coat` entity's local transform.

These regression tests are ready for the coordinator's native XCTest target; they
are supplied here to keep edits within the two owned files. They were **not run**:

```swift
import RealityKit
import XCTest
import simd
@testable import Roomwave

final class PilotAvatarTests: XCTestCase {
    @MainActor
    func testUpdatePreservesScenePlacementAndDoesNotAccumulate() throws {
        let avatar = LayeredAvatarController()
        avatar.root.position = SIMD3(4, 2, -3)
        avatar.root.scale = SIMD3(repeating: 0.35)
        avatar.root.orientation = simd_quatf(angle: 0.8, axis: SIMD3(0, 1, 0))
        let placement = avatar.root.transform
        let motion = try XCTUnwrap(avatar.root.findEntity(named: "AvatarProceduralMotion"))
        let coat = try XCTUnwrap(avatar.root.findEntity(named: "Fallback_Coat"))
        avatar.update(speed: 12, steering: 1, time: 0.125)
        let coatRotation = coat.orientation.vector
        let motionPosition = motion.position
        avatar.update(speed: 12, steering: 1, time: 0.125)
        XCTAssertEqual(avatar.root.position, placement.translation)
        XCTAssertEqual(avatar.root.scale, placement.scale)
        XCTAssertEqual(avatar.root.orientation.vector, placement.rotation.vector)
        XCTAssertGreaterThan(motion.position.y, 0)
        XCTAssertLessThan(motion.orientation.vector.z, 0)
        XCTAssertEqual(motion.position, motionPosition)
        XCTAssertEqual(coat.orientation.vector, coatRotation)
    }

    @MainActor
    func testFallbackOverlaysAreIndependentOfSkin() throws {
        let avatar = LayeredAvatarController()
        avatar.setLayerVisibility(skeleton: true, muscle: false, skin: false, coat: true)
        for (name, expected) in [("SkeletonOverlay", true), ("MuscleOverlay", false),
                                 ("Skin", false), ("Coat", true)] {
            let layer = try XCTUnwrap(avatar.root.findEntity(named: "Fallback_" + name))
            XCTAssertEqual(layer.isEnabled, expected)
        }
        XCTAssertTrue(avatar.assetStatus.contains("Procedural fallback"))
    }
}
```

## Executed verification

Nine PowerShell source-contract assertions passed: MainActor class, read-only root,
three method signatures, read-only status, no root-pose assignments, both bundle
locations, no network calls, and cancellation/validation before fallback removal.
Owned-file scope, whitespace/final-newline checks and `git diff --check` passed.
These are static checks, not Swift parsing or runtime tests. `swift` and `xcodebuild`
were both absent from PATH; no USDZ was found under apps/ios. The native XCTest
examples and behavior checks above were not compiled or executed.
