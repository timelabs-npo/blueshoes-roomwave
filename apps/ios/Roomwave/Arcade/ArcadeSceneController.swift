import Foundation
import RealityKit
import RoomwaveArcade
import UIKit
import simd

enum ArcadeSceneError: LocalizedError {
    case invalidMesh(String)
    case avatarUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidMesh(let reason): return "Could not build surf geometry: \(reason)."
        case .avatarUnavailable(let reason): return "Could not load the bundled rider: \(reason)"
        }
    }
}

/// Native non-AR renderer. The session delivers every frame and owns time/input.
/// No SwiftUI publication, game clock, collision inference or correcting gameplay bot.
@MainActor
final class ArcadeSceneController: ArcadeSceneDriving {
    var view: UIView { arView }

    private let arView: ARView
    private let camera = PerspectiveCamera()
    private var anchor: AnchorEntity?
    private var course: CompiledSurfCourse?
    private var art: ArcadeGeometry.CourseArt?
    private var avatar: LayeredAvatarController?
    // Translation/heading live on avatar.root. This wrapper changes only local pose
    // above the imported rig; it doesn't reparent any USDZ layer or skeleton binding.
    private var riderPose: Entity?
    private var board: ModelEntity?
    private var boardGlow: ModelEntity?
    private var shadow: ModelEntity?
    private var ghostBoard: ModelEntity?
    private var effects: ArcadeEffects?
    private var generation: UInt64 = 0
    private var visibleEncounters = 0..<0
    private var consumedCursor = 0
    private var previousTick = -1
    private var lastEventTick = -1
    private var lastRenderedDistance: Double = 0
    private var cameraPosition: SIMD3<Float>?
    private var cameraTarget: SIMD3<Float>?
    private var cameraHeading = SIMD3<Float>(0, 0, -1)
    private var riderHeading = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var fieldOfView: Float = 61
    private var landingCompression: Float = 0
    private var hitImpulse: Float = 0
    private var eventAge: Float = 0
    private var wasPreview = true

    init() {
        arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(ArcadeGeometry.rgb(0.018, 0.025, 0.06))
        arView.environment.lighting.intensityExponent = 0.7
        // The portrait FOV is explicit, avoiding aspect-dependent horizontal framing.
        camera.camera = PerspectiveCameraComponent(near: 0.08, far: 1600,
                                                   fieldOfViewInDegrees: 61,
                                                   fieldOfViewOrientation: .vertical)
        camera.name = "SurfFollowCamera"
        arView.accessibilityLabel = "Roomwave surfing course"
    }

    func load(course: CompiledSurfCourse) async throws {
        teardown()
        let revision = generation
        let candidateAvatar = LayeredAvatarController()
        do {
            try Task.checkCancellation()
            let candidateArt = try ArcadeGeometry.build(course: course)
            let candidateEffects = try ArcadeEffects()
            candidateAvatar.setLayerVisibility(skeleton: false, muscle: false, skin: true, coat: true)
            await candidateAvatar.loadBundledAsset()
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            // The existing helper reports failures rather than throwing. Inspect its
            // real hierarchy so a fallback never silently becomes a successful load.
            guard candidateAvatar.root.findEntity(named: "ProceduralFallback_NotBundledAvatar") == nil,
                  let skin = candidateAvatar.root.findEntity(named: "Skin"), containsModel(skin),
                  let coat = candidateAvatar.root.findEntity(named: "Coat"), containsModel(coat) else {
                throw ArcadeSceneError.avatarUnavailable(candidateAvatar.assetStatus)
            }
            let candidateAnchor = AnchorEntity(world: .zero)
            candidateAnchor.name = "RoomwaveSurfWorld"
            candidateAnchor.addChild(candidateArt.root)
            candidateAnchor.addChild(candidateEffects.root)
            candidateAnchor.addChild(camera)

            let poseContainer = Entity()
            poseContainer.name = "RiderCompressionAboveImportedRig"
            // Move the helper's whole root; all imported rig relationships stay intact.
            poseContainer.addChild(candidateAvatar.root)
            candidateAnchor.addChild(poseContainer)
            // The bundled rider is authored at about 1 m, matching the simulation's
            // foot + 0.1...0.9 body band and foot + 0.5 ring target.
            candidateAvatar.root.scale = SIMD3(repeating: 1)

            let boardMesh = MeshResource.generateBox(size: SIMD3<Float>(0.55, 0.065, 1.35), cornerRadius: 0.025)
            let candidateBoard = ModelEntity(mesh: boardMesh,
                                            materials: [SimpleMaterial(color: UIColor(white: 0.88, alpha: 1),
                                                                       roughness: 0.28, isMetallic: true)])
            candidateBoard.position.y = 0.025
            candidateAvatar.root.addChild(candidateBoard)
            let glow = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.61, 0.018, 1.28), cornerRadius: 0.008),
                                   materials: [UnlitMaterial(color: ArcadeGeometry.cyan)])
            glow.position.y = 0.003
            candidateAvatar.root.addChild(glow)
            // A low transparent contact patch; its position stays on the road in flight.
            var shadowMaterial = UnlitMaterial(color: .black)
            shadowMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.36))
            let candidateShadow = ModelEntity(mesh: try ArcadeGeometry.contactPatch(),
                                              materials: [shadowMaterial])
            candidateAnchor.addChild(candidateShadow)
            var ghostMaterial = UnlitMaterial(color: ArcadeGeometry.cyan)
            ghostMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            let ghost = ModelEntity(mesh: boardMesh, materials: [ghostMaterial])
            ghost.isEnabled = false
            candidateAnchor.addChild(ghost)
            addLighting(to: candidateAnchor, biome: course.definition.biome)

            self.course = course
            self.art = candidateArt
            self.avatar = candidateAvatar
            self.anchor = candidateAnchor
            self.riderPose = poseContainer
            self.board = candidateBoard
            self.boardGlow = glow
            self.shadow = candidateShadow
            self.ghostBoard = ghost
            self.effects = candidateEffects
            arView.environment.background = .color(candidateArt.palette.sky)
            arView.scene.addAnchor(candidateAnchor)
            preview(time: 0, reducedMotion: true)
            NSLog("Roomwave arcade scene loaded %@: %ld ribbon stations, %ld cached encounters; %@",
                  course.definition.id, candidateArt.stationCount, candidateArt.encounters.count, candidateAvatar.assetStatus)
        } catch {
            candidateAvatar.root.stopAllAnimations(recursive: true)
            // A stale load must not tear down the newer generation's scene.
            if revision == generation { teardown() }
            NSLog("Roomwave arcade scene load failed: %@", error.localizedDescription)
            throw error
        }
    }

    func render(state: SurfState, events: [SurfEvent], deltaTime: TimeInterval,
                reducedMotion: Bool, ghost: SurfState?) {
        guard let course, let avatar, let riderPose, let effects,
              state.distance.isFinite, state.height.isFinite, state.speed.isFinite else { return }
        let dt = Float(deltaTime.isFinite ? min(0.1, max(0, deltaTime)) : 0)
        let reset = state.tick < previousTick || state.distance + 0.1 < lastRenderedDistance
        if reset { resetRunPresentation() }
        let pose = course.pose(at: state.distance)
        let forward = ArcadeGeometry.normalized(ArcadeGeometry.vector(pose.forward), fallback: SIMD3(0, 0, -1))
        let flatForward = ArcadeGeometry.normalized(SIMD3(forward.x, 0, forward.z), fallback: cameraHeading)
        let road = ArcadeGeometry.vector(pose.center)
        // height is ABSOLUTE rider-foot Y. Never add road.y here.
        let foot = SIMD3<Float>(road.x, Float(state.height), road.z)
        let separation = max(0, foot.y - road.y)
        let speedFraction = Float(max(0, min(1, state.speed / 30)))
        let turn = signedTurn(from: cameraHeading, to: flatForward)
        let snap = wasPreview || reset || cameraPosition == nil

        // Scale/lean around the rider foot with a conjugated parent transform,
        // keeping avatar.root.position and the resulting world foot equal to foot.
        avatar.root.position = foot
        let heading = ArcadeGeometry.yaw(for: flatForward)
        riderHeading = snap ? heading : simd_slerp(riderHeading, heading, smoothing(18, dt))
        avatar.root.orientation = riderHeading
        avatar.update(speed: 12 * max(0, min(30, state.speed)) / 30,
                      steering: reducedMotion ? 0 : Double(max(-1, min(1, turn * 3))),
                      time: reducedMotion ? 0 : Double(state.tick) / 60)

        eventAge += dt
        // Process all events sharing a tick before advancing the watermark.
        var newestEventTick = lastEventTick
        for event in events where event.tick > lastEventTick {
            effects.event(event, rider: foot, road: road, forward: forward, reducedMotion: reducedMotion)
            newestEventTick = max(newestEventTick, event.tick)
            switch event.kind {
            case .landing, .perfectLanding:
                landingCompression = max(landingCompression, event.kind == .perfectLanding ? 0.17 : 0.24)
            case .hit:
                hitImpulse = min(1, Float(max(0, event.intensity)))
                eventAge = 0
            default: break
            }
        }
        lastEventTick = newestEventTick
        landingCompression *= exp(-13 * dt)
        hitImpulse *= exp(-8 * dt)
        let charge = state.grounded ? Float(max(0, min(1, state.charge))) : 0
        let compression = min(0.34, charge * 0.22 + landingCompression)
        let roadPitch = simd_quatf(angle: Float(atan(pose.slope)), axis: SIMD3<Float>(1, 0, 0))
        let pitch = state.grounded ? Float(atan(pose.slope)) : Float(max(-0.18, min(0.18, -state.verticalSpeed * 0.013)))
        let bank = reducedMotion ? Float(0) : max(-0.14, min(0.14, -turn * 0.8))
        let localPose = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) *
            simd_quatf(angle: bank, axis: SIMD3(0, 0, 1))
        let worldPose = riderHeading * localPose * riderHeading.inverse
        riderPose.orientation = worldPose
        riderPose.scale = SIMD3(1 + compression * 0.16, 1 - compression, 1 + compression * 0.16)
        // Matrix order is T * R * S. Conjugation cancels translation at the foot.
        riderPose.position = foot - worldPose.act(riderPose.scale * foot)

        shadow?.position = road + SIMD3(0, 0.018, 0)
        shadow?.orientation = heading * roadPitch
        let shadowScale = max(0.35, 1 - separation * 0.055)
        shadow?.scale = SIMD3(shadowScale, 1, shadowScale)
        shadow?.isEnabled = separation < 16
        boardGlow?.isEnabled = reducedMotion || state.invulnerabilityTicks == 0 || (state.tick / 5) % 2 == 0
        board?.isEnabled = true
        effects.update(deltaTime: dt, rider: foot, forward: forward, airborne: !state.grounded,
                       speed: Float(state.speed), reducedMotion: reducedMotion)
        updateEncounters(distance: state.distance, cursor: state.encounterCursor)
        updateGhost(ghost, course: course)
        followCamera(foot: foot, road: road, forward: flatForward, distance: state.distance,
                     speed: speedFraction, separation: separation, dt: dt,
                     reducedMotion: reducedMotion, snap: snap, previewOffset: 0)
        previousTick = state.tick
        lastRenderedDistance = state.distance
        wasPreview = false
    }

    func preview(time: TimeInterval, reducedMotion: Bool) {
        guard let course, let avatar, let riderPose else { return }
        if !wasPreview { resetRunPresentation() }
        let pose = course.pose(at: 0)
        let road = ArcadeGeometry.vector(pose.center)
        let forward = ArcadeGeometry.normalized(SIMD3(Float(pose.forward.x), 0, Float(pose.forward.z)), fallback: SIMD3(0, 0, -1))
        riderPose.transform = .identity
        avatar.root.position = road
        let heading = ArcadeGeometry.yaw(for: forward)
        avatar.root.orientation = heading * simd_quatf(angle: Float(atan(pose.slope)), axis: SIMD3<Float>(1, 0, 0))
        avatar.update(speed: 0, steering: 0, time: 0)
        riderHeading = heading
        shadow?.position = road + SIMD3(0, 0.018, 0)
        shadow?.orientation = avatar.root.orientation
        shadow?.scale = SIMD3(repeating: 1)
        shadow?.isEnabled = true
        board?.isEnabled = true
        boardGlow?.isEnabled = true
        ghostBoard?.isEnabled = false
        effects?.clear()
        updateEncounters(distance: 0, cursor: 0)
        // Bounded home drift only. No orbit when reduced motion is requested.
        let elapsed = time.isFinite ? time.truncatingRemainder(dividingBy: 40) : 0
        let drift = reducedMotion ? Float(0) : sin(Float(elapsed) * (.pi / 20)) * 0.7
        followCamera(foot: road, road: road, forward: forward, distance: 0, speed: 0.35,
                     separation: 0, dt: 1 / 60, reducedMotion: reducedMotion,
                     snap: true, previewOffset: drift)
        wasPreview = true
    }

    func teardown() {
        generation &+= 1
        avatar?.root.stopAllAnimations(recursive: true)
        effects?.clear()
        camera.removeFromParent()
        anchor?.removeFromParent()
        anchor = nil
        art = nil
        course = nil
        avatar = nil
        riderPose = nil
        board = nil
        boardGlow = nil
        shadow = nil
        ghostBoard = nil
        effects = nil
        visibleEncounters = 0..<0
        consumedCursor = 0
        previousTick = -1
        lastEventTick = -1
        lastRenderedDistance = 0
        cameraPosition = nil
        cameraTarget = nil
        cameraHeading = SIMD3(0, 0, -1)
        riderHeading = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        fieldOfView = 61
        landingCompression = 0
        hitImpulse = 0
        eventAge = 0
        wasPreview = true
    }

    private func followCamera(foot: SIMD3<Float>, road: SIMD3<Float>, forward: SIMD3<Float>,
                              distance: Double, speed: Float, separation: Float, dt: Float,
                              reducedMotion: Bool, snap: Bool, previewOffset: Float) {
        guard let course else { return }
        // Frame the rider low in portrait and keep 20–34 m of road in view. The
        // target follows flight enough to keep the rider in frame, without looking
        // down from an overview. Lookahead elevation anticipates crests/landings.
        let lookahead = course.pose(at: min(course.length, distance + 20 + Double(speed) * 14))
        let ahead = ArcadeGeometry.vector(lookahead.center)
        cameraHeading = snap ? forward : ArcadeGeometry.normalized(
            cameraHeading + (forward - cameraHeading) * smoothing(7, dt), fallback: forward)
        let right = simd_cross(cameraHeading, SIMD3<Float>(0, 1, 0))
        let lift = separation * 0.92
        let desiredPosition = road - cameraHeading * (8.4 + speed * 1.2) +
            SIMD3<Float>(0, 4.0 + lift + max(0, ahead.y - road.y) * 0.15, 0) + right * previewOffset
        // A shorter aim vector than the visibility distance keeps the rider's body
        // around the lower-middle of the image, with the real landing area ahead.
        let desiredTarget = road * 0.57 + ahead * 0.43 + SIMD3<Float>(0, 1.9 + separation * 0.88, 0)
        let moveAlpha = smoothing(7.5, dt)
        let aimAlpha = smoothing(9, dt)
        let position = snap ? desiredPosition : (cameraPosition ?? desiredPosition) + (desiredPosition - (cameraPosition ?? desiredPosition)) * moveAlpha
        let target = snap ? desiredTarget : (cameraTarget ?? desiredTarget) + (desiredTarget - (cameraTarget ?? desiredTarget)) * aimAlpha
        cameraPosition = position
        cameraTarget = target
        var shake = SIMD3<Float>.zero
        if !reducedMotion, hitImpulse > 0.005 {
            shake = right * sin(eventAge * 61) * hitImpulse * 0.09 + SIMD3(0, cos(eventAge * 47) * hitImpulse * 0.045, 0)
        }
        camera.look(at: target, from: position + shake, relativeTo: nil)
        if !reducedMotion {
            let bank = max(-0.025, min(0.025, signedTurn(from: cameraHeading, to: forward) * 0.12))
            camera.orientation = camera.orientation * simd_quatf(angle: bank, axis: SIMD3(0, 0, 1))
        }
        let desiredFOV: Float = reducedMotion ? 61 : 59 + speed * 4
        fieldOfView = snap || reducedMotion ? desiredFOV : fieldOfView + (desiredFOV - fieldOfView) * smoothing(2.5, dt)
        camera.camera.fieldOfViewInDegrees = fieldOfView
        // Sky follows translation only, preserving a fixed world horizon/orbit axis.
        art?.sky.position = SIMD3(position.x, Float(course.definition.samples.first?.center.y ?? 0), position.z)
    }

    private func updateEncounters(distance: Double, cursor: Int) {
        guard let art else { return }
        let count = art.encounters.count
        let boundedCursor = max(0, min(count, cursor))
        if boundedCursor > consumedCursor {
            for index in consumedCursor..<boundedCursor {
                let kind = art.encounters[index].encounter.kind
                if kind == .ring || kind == .boost {
                    art.encounters[index].consumed = true
                    art.encounters[index].entity.isEnabled = false
                }
            }
        }
        consumedCursor = boundedCursor
        let newRange = lowerBound(distance - 14, in: art.encounters)..<lowerBound(distance + 150, in: art.encounters)
        if newRange != visibleEncounters {
            for index in visibleEncounters where !newRange.contains(index) {
                art.encounters[index].entity.isEnabled = false
            }
            for index in newRange where !visibleEncounters.contains(index) {
                art.encounters[index].entity.isEnabled = !art.encounters[index].consumed
            }
            visibleEncounters = newRange
        }
    }

    private func lowerBound(_ distance: Double, in encounters: [ArcadeGeometry.EncounterArt]) -> Int {
        var low = 0, high = encounters.count
        while low < high {
            let middle = low + (high - low) / 2
            if encounters[middle].encounter.distance < distance { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    private func resetRunPresentation() {
        effects?.clear()
        if let art {
            for index in visibleEncounters { art.encounters[index].entity.isEnabled = false }
            for index in art.encounters.indices { art.encounters[index].consumed = false }
        }
        visibleEncounters = 0..<0
        consumedCursor = 0
        lastEventTick = -1
        landingCompression = 0
        hitImpulse = 0
        cameraPosition = nil
        cameraTarget = nil
    }

    private func updateGhost(_ state: SurfState?, course: CompiledSurfCourse) {
        guard let state, state.distance.isFinite, state.height.isFinite else { ghostBoard?.isEnabled = false; return }
        let pose = course.pose(at: state.distance)
        ghostBoard?.position = SIMD3(Float(pose.center.x), Float(state.height) + 0.025, Float(pose.center.z))
        ghostBoard?.orientation = ArcadeGeometry.yaw(for: ArcadeGeometry.vector(pose.forward))
        ghostBoard?.scale = SIMD3(repeating: 1)
        ghostBoard?.isEnabled = true
    }

    private func addLighting(to anchor: AnchorEntity, biome: SurfBiome) {
        let key = DirectionalLight()
        key.light.color = biome == .dawn ? ArcadeGeometry.rgb(1, 0.85, 0.76) : ArcadeGeometry.rgb(0.64, 0.81, 1)
        key.light.intensity = biome == .midnight ? 1500 : 2800
        key.look(at: .zero, from: SIMD3(-10, 18, 9), relativeTo: nil)
        anchor.addChild(key)
        let fill = DirectionalLight()
        fill.light.color = ArcadeGeometry.rgb(0.32, 0.80, 0.91)
        fill.light.intensity = biome == .midnight ? 500 : 900
        fill.look(at: .zero, from: SIMD3(8, 6, -10), relativeTo: nil)
        anchor.addChild(fill)
    }

    private func containsModel(_ entity: Entity) -> Bool {
        entity.components[ModelComponent.self] != nil || entity.children.contains { containsModel($0) }
    }
    private func smoothing(_ rate: Float, _ dt: Float) -> Float { 1 - exp(-rate * dt) }
    private func signedTurn(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
        atan2(simd_cross(a, b).y, max(-1, min(1, simd_dot(a, b))))
    }
}