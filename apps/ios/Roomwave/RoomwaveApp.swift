import SwiftUI

@main
struct RoomwaveApp: App {
    @StateObject private var session = ArcadeSession()

    var body: some Scene {
        WindowGroup {
            ArcadeRootView(session: session)
        }
    }
}
