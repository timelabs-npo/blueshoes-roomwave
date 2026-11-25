#if DEBUG
import Foundation
import RealityKit
import UIKit
import RoomwaveArcade

/// Opt-in observations of the ordinary app, never an alternate scene or input
/// controller. XCUITest supplies real touch events. Release contains no probe.
@MainActor
enum ArcadeEvidenceProbe {
    static let requested = ProcessInfo.processInfo.arguments.contains("--arcade-evidence")
    private static var initialized = false
    private static var pending = Set<String>()
    private static var captured = Set<String>()
    private static var latestTick = 0
    private static var latestCourse = ""
    private static var lastGrounded = true
    private static var observations: [[String: Any]] = []
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoomwaveArcadeCaptures", isDirectory: true)

    static func observe(state: SurfState?, course: CompiledSurfCourse?, screen: ArcadeScreen,
                        events: [SurfEvent], view: UIView) {
        guard requested, let course, let state else { return }
        if !initialized {
            initialized = true
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        latestTick = state.tick
        latestCourse = course.definition.id
        if !events.isEmpty && observations.count < 600 {
            observations.append([
                "tick": state.tick, "course": course.definition.id,
                "distance": state.distance, "foot_y": state.height,
                "grounded": state.grounded, "score": state.score,
                "events": events.map(\.kind.rawValue)
            ])
            writeJSON(observations, named: "events.json")
        }
        var mode: String?
        if screen == .home { mode = "home-" + course.definition.biome.rawValue }
        else if screen == .paused { mode = "paused" }
        else if screen == .results { mode = "results" }
        else if screen == .playing {
            if !state.grounded { mode = "airborne" }
            else if !lastGrounded { mode = "landing" }
            else if state.charge >= 0.4 { mode = "charged" }
            else if state.tick >= 60 { mode = "running" }
        }
        lastGrounded = state.grounded
        guard let mode, !captured.contains(mode), !pending.contains(mode),
              let arView = findARView(view), arView.window != nil else { return }
        let entities = arView.scene.anchors.flatMap { hierarchy($0) }
        let layers = ["Skin", "Coat", "SkeletonOverlay", "MuscleOverlay"].filter { name in
            entities.contains { $0.name == name && hierarchy($0).contains { $0.components[ModelComponent.self] != nil } }
        }
        let fallback = entities.contains { $0.name == "ProceduralFallback_NotBundledAvatar" }
        guard layers.count == 4, !fallback else { return }
        pending.insert(mode)
        let requestTick = state.tick
        let courseID = course.definition.id
        let footY = state.height
        let roadY = course.pose(at: state.distance).center.y
        arView.snapshot(saveToHDR: false) { image in
            let png = image?.pngData()
            let width = image?.size.width ?? 0
            let height = image?.size.height ?? 0
            Task { @MainActor in
                pending.remove(mode)
                guard latestCourse == courseID, let png, width >= 100, height >= 100 else { return }
                let filename = mode + ".png"
                do {
                    try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
                    let receipt: [String: Any] = [
                        "schema_version": 3, "mode": mode,
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "bundle": Bundle.main.bundleIdentifier ?? "",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                        "course_id": courseID, "request_tick": requestTick, "capture_tick": latestTick,
                        "grounded_at_request": state.grounded, "foot_y_at_request": footY,
                        "road_y_at_request": roadY, "score_at_request": state.score,
                        "image_filename": filename, "renderable_layers": layers,
                        "fallback_present": false, "actual_arview_snapshot": true,
                        "width": width, "height": height,
                        "human_playtest": false
                    ]
                    writeJSON(receipt, named: mode + ".json")
                    captured.insert(mode)
                } catch { print("ARCADE_EVIDENCE_WRITE_ERROR: \(error)") }
            }
        }
    }

    private static func writeJSON(_ value: Any, named: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: directory.appendingPathComponent(named), options: .atomic)
        } catch { print("ARCADE_EVIDENCE_JSON_ERROR: \(error)") }
    }

    private static func findARView(_ view: UIView) -> ARView? {
        if let arView = view as? ARView { return arView }
        return view.subviews.lazy.compactMap { findARView($0) }.first
    }

    private static func hierarchy(_ root: Entity) -> [Entity] {
        var result: [Entity] = [], pending = [root]
        while let next = pending.popLast() {
            result.append(next)
            pending.append(contentsOf: next.children)
        }
        return result
    }
}
#endif
