#if DEBUG
import Foundation

/// Opt-in CI evidence for the real app scene. Never included in Release.
@MainActor
enum PilotPreviewProbe {
    static let requested = ProcessInfo.processInfo.arguments.contains("--pilot-demo") ||
        ProcessInfo.processInfo.arguments.contains("--pilot-race")
    private(set) static var isReady = false
    private(set) static var failed = false
    private static var lastState: Data?
    private static var captures: [String: [String: Any]] = [:]
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoomwavePilotCaptures", isDirectory: true)

    static func beginLaunch() {
        guard requested else { return }
        isReady = false
        failed = false
        lastState = nil
        captures = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The caller has checked that the snapshot's scene generation/mode is still current.
    /// Write pixels first; the matching immutable capture receipt is published by record.
    static func saveSnapshot(_ png: Data, mode: String, generation: UUID,
                             requestTick: Int, captureTick: Int) -> Bool {
        guard requested else { return false }
        let name = "\(mode)-\(generation.uuidString).png"
        do {
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
            captures[mode] = [
                "image_filename": name, "capture_mode": mode,
                "generation": generation.uuidString,
                "request_tick": requestTick, "capture_tick": captureTick,
                "race_running_at_capture": mode == "race"
            ]
            return true
        } catch {
            print("ROOMWAVE_PREVIEW_IMAGE_WRITE_FAILED: \(error)")
            return false
        }
    }

    static func record(loadCompleted: Bool, renderableLayers: [String], fallbackPresent: Bool,
                       glideLayers: [String], updatesAfterLoad: Int, snapshotRendered: Bool,
                       snapshotFailed: Bool, mode: String, loadStatus: String) {
        guard requested else { return }
        let loaded = loadCompleted && renderableLayers.count == 4 && !fallbackPresent
        failed = (loadCompleted && !loaded) || snapshotFailed
        isReady = loaded && glideLayers.count == 4 && updatesAfterLoad >= 2 &&
            snapshotRendered && captures[mode] != nil
        let state = failed ? "failed" : isReady ? "ready" : "loading"
        var payload: [String: Any] = [
            "state": state, "mode": mode, "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "load_completed": loadCompleted, "renderable_layers": renderableLayers.sorted(),
            "fallback_present": fallbackPresent, "glide_layers": glideLayers.sorted(),
            "scene_updates_after_load": min(updatesAfterLoad, 2),
            "snapshot_rendered": snapshotRendered, "load_status": loadStatus
        ]
        if let capture = captures[mode] {
            payload.merge(capture) { _, captured in captured }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            guard data != lastState else { return }
            try data.write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
            if isReady && (mode == "preview" || mode == "race") {
                let receipt = directory.appendingPathComponent("\(mode).json")
                if !FileManager.default.fileExists(atPath: receipt.path) {
                    try data.write(to: receipt, options: .atomic)
                }
            }
            lastState = data
        } catch {
            failed = true
            isReady = false
            print("ROOMWAVE_PREVIEW_PROBE_WRITE_FAILED: \(error)")
        }
    }
}
#endif
