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
    private static let captureDiagnostic = requested && ProcessInfo.processInfo.arguments.contains("--arcade-no-app-snapshot-diagnostic")
    private static var initialized = false
    private static var diagnostics: [String: Any] = [:]
    private static var lastHeartbeatTime: TimeInterval = -.infinity
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private static var pending = Set<String>()
    private static var captured = Set<String>()
    private static var nextCaptureAttempt: [String: TimeInterval] = [:]
    private static var latestTick = 0
    private static var latestCourse = ""
    private static var latestScreen: ArcadeScreen?
    private static var generation: UInt64 = 0
    private static var lastGrounded = true
    private static var observations: [[String: Any]] = []
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoomwaveArcadeCaptures", isDirectory: true)

    static func observe(state: SurfState?, course: CompiledSurfCourse?, screen: ArcadeScreen,
                        events: [SurfEvent], view: UIView, isLoading: Bool, isActive: Bool) {
        guard requested else { return }
        initializeIfNeeded()
        updateContext(screen: screen, tick: state?.tick ?? 0, isLoading: isLoading, isActive: isActive)
        guard let course, let state else { return }
        if course.definition.id != latestCourse || state.tick < latestTick ||
            (screen == .playing && latestScreen == .home) { generation &+= 1 }
        latestScreen = screen
        latestTick = state.tick
        latestCourse = course.definition.id
        if !events.isEmpty && observations.count < 600 {
            observations.append([
                "tick": state.tick, "course": course.definition.id,
                "run_generation": generation,
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
        // Explicit diagnostic only: retain the ordinary scene, input and metadata
        // while isolating ARView.snapshot. This emits no render-proof receipt.
        guard !captureDiagnostic else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let mode, !captured.contains(mode), !pending.contains(mode),
              now >= nextCaptureAttempt[mode, default: 0],
              let arView = findARView(view), arView.window != nil else { return }
        let entities = arView.scene.anchors.flatMap { hierarchy($0) }
        let layers = ["Skin", "Coat", "SkeletonOverlay", "MuscleOverlay"].filter { name in
            entities.contains { $0.name == name && hierarchy($0).contains { $0.components[ModelComponent.self] != nil } }
        }
        let fallback = entities.contains { $0.name == "ProceduralFallback_NotBundledAvatar" }
        guard layers.count == 4, !fallback else { return }
        pending.insert(mode)
        nextCaptureAttempt[mode] = now + 0.5
        let requestTick = state.tick
        let courseID = course.definition.id
        let footY = state.height
        let roadY = course.pose(at: state.distance).center.y
        let requestGeneration = generation
        // End the CADisplayLink callback before asking RealityKit to capture.
        // Recheck ownership because course/screen changes may precede this turn.
        DispatchQueue.main.async { [weak arView] in
            guard generation == requestGeneration, latestScreen == screen,
                  latestCourse == courseID, latestTick >= requestTick,
                  pending.contains(mode), let arView, arView.window != nil else {
                pending.remove(mode)
                return
            }
            recordStage("snapshot_request")
            arView.snapshot(saveToHDR: false) { image in
                let width = image?.cgImage?.width ?? 0
                let height = image?.cgImage?.height ?? 0
                let pixelRange = image?.cgImage.map { sampledPixelRange($0) } ?? 0
                // Reject blank/invalid pixels before expensive PNG encoding.
                // Only Data and integer image observations cross into MainActor.
                let png = width >= 100 && height >= 100 && pixelRange >= 24 ? image?.pngData() : nil
                Task { @MainActor in
                    recordStage("snapshot_callback")
                    pending.remove(mode)
                    guard generation == requestGeneration, latestScreen == screen,
                          latestCourse == courseID, latestTick >= requestTick,
                          let png, width >= 100, height >= 100, pixelRange >= 24 else { return }
                    let filename = mode + ".png"
                    do {
                        try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
                        let receipt: [String: Any] = [
                            "schema_version": 4, "mode": mode,
                            "sampled_rgb_range": pixelRange,
                            "pid": ProcessInfo.processInfo.processIdentifier,
                            "bundle": Bundle.main.bundleIdentifier ?? "",
                            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                            "course_id": courseID, "run_generation": requestGeneration,
                            "request_tick": requestTick, "capture_tick": latestTick,
                            "grounded_at_request": state.grounded, "foot_y_at_request": footY,
                            "road_y_at_request": roadY, "score_at_request": state.score,
                            "image_filename": filename, "renderable_layers": layers,
                            "fallback_present": false, "actual_arview_snapshot": true,
                            "width": width, "height": height,
                            "human_playtest": false
                        ]
                        writeJSON(receipt, named: mode + ".json")
                        captured.insert(mode)
                        recordStage("snapshot_accepted")
                    } catch { print("ARCADE_EVIDENCE_WRITE_ERROR: \(error)") }
                }
            }
        }
    }

    static func trace(_ stage: String, screen: ArcadeScreen, tick: Int,
                      isLoading: Bool, isActive: Bool) {
        guard requested else { return }
        initializeIfNeeded()
        updateContext(screen: screen, tick: tick, isLoading: isLoading, isActive: isActive)
        recordStage(stage)
    }

    static func heartbeat(screen: ArcadeScreen, tick: Int, isLoading: Bool, isActive: Bool) {
        guard requested else { return }
        initializeIfNeeded()
        updateContext(screen: screen, tick: tick, isLoading: isLoading, isActive: isActive)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHeartbeatTime >= 1 else { return }
        lastHeartbeatTime = now
        let timestamp = timestampFormatter.string(from: Date())
        diagnostics["heartbeat_at"] = timestamp
        diagnostics["updated_at"] = timestamp
        // Heartbeats preserve the latest meaningful stage.
        writeJSON(diagnostics, named: "diagnostics.json")
    }

    private static func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = timestampFormatter.string(from: Date())
        diagnostics = [
            "schema_version": 1,
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "launch_id": UUID().uuidString,
            "started_at": timestamp, "updated_at": timestamp,
            "stage": "initializing", "heartbeat_at": NSNull(),
            "screen": "home", "tick": 0, "is_loading": false, "is_active": false,
            "capture_diagnostic": captureDiagnostic,
            "app_snapshots_enabled": !captureDiagnostic,
            "stages": [[String: String]]()
        ]
    }

    private static func updateContext(screen: ArcadeScreen, tick: Int, isLoading: Bool, isActive: Bool) {
        diagnostics["screen"] = String(describing: screen)
        diagnostics["tick"] = tick
        diagnostics["is_loading"] = isLoading
        diagnostics["is_active"] = isActive
    }

    private static func recordStage(_ name: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let previous = diagnostics["stages"] as? [[String: String]] ?? []
        diagnostics["stages"] = Array(previous.suffix(31)) + [["name": name, "at": timestamp]]
        diagnostics["stage"] = name
        diagnostics["updated_at"] = timestamp
        writeJSON(diagnostics, named: "diagnostics.json")
    }

    // RealityKit may return its uniform clear colour before the first drawable.
    // Sample actual pixels; entity presence alone does not prove a rendered scene.
    nonisolated private static func sampledPixelRange(_ image: CGImage) -> Int {
        let width = 16, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                            CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return 0 }
        var minima = [255, 255, 255], maxima = [0, 0, 0]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                let value = Int(pixels[offset + channel])
                minima[channel] = min(minima[channel], value)
                maxima[channel] = max(maxima[channel], value)
            }
        }
        return (0..<3).map { maxima[$0] - minima[$0] }.max() ?? 0
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
