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
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoomwavePilotReadiness.json")

    static func beginLaunch() {
        guard requested else { return }
        isReady = false
        failed = false
        lastState = nil
        try? FileManager.default.removeItem(at: url)
    }

    static func record(loadCompleted: Bool, renderableLayers: [String], fallbackPresent: Bool,
                       glideLayers: [String], updatesAfterLoad: Int, snapshotRendered: Bool,
                       snapshotFailed: Bool, mode: String, loadStatus: String) {
        guard requested else { return }
        let loaded = loadCompleted && renderableLayers.count == 4 && !fallbackPresent
        failed = (loadCompleted && !loaded) || snapshotFailed
        isReady = loaded && glideLayers.count == 4 && updatesAfterLoad >= 2 && snapshotRendered
        let state = failed ? "failed" : isReady ? "ready" : "loading"
        let payload: [String: Any] = [
            "state": state, "mode": mode, "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "load_completed": loadCompleted, "renderable_layers": renderableLayers.sorted(),
            "fallback_present": fallbackPresent, "glide_layers": glideLayers.sorted(),
            "scene_updates_after_load": min(updatesAfterLoad, 2),
            "snapshot_rendered": snapshotRendered, "load_status": loadStatus
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            guard data != lastState else { return }
            try data.write(to: url, options: .atomic)
            lastState = data
        } catch {
            failed = true
            isReady = false
            print("ROOMWAVE_PREVIEW_PROBE_WRITE_FAILED: \(error)")
        }
    }
}
#endif
