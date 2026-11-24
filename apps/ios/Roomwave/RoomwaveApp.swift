import SwiftUI

@main
struct RoomwaveApp: App {
    @StateObject private var model = RoomwaveModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                #if DEBUG
                // CI preview controls use the real demo/race paths and are absent from Release.
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    guard arguments.contains("--pilot-demo") || arguments.contains("--pilot-race") else { return }
                    model.makeDemo()
                    if arguments.contains("--pilot-race") {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        model.startRace()
                    }
                }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    // Permission alerts can make the app inactive. Do not cancel
                    // the user's pending permission request for that transition.
                    if phase == .background ||
                        (phase == .inactive && model.phase != .requestingCamera) {
                        model.stopForInactivity()
                    }
                }
        }
    }
}
