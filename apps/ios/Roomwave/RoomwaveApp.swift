import SwiftUI

@main
struct RoomwaveApp: App {
    @StateObject private var model = RoomwaveModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
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
