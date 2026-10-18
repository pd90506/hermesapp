import SwiftUI

@main
struct HermesiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .appearance(model.appearance)
                .markdownColors(model.markdownColors)
                .onChange(of: scenePhase) { _, phase in
                    // iOS suspends sockets in the background; reconnect on return.
                    // The connection's replay logic restores the active session.
                    guard phase == .active else { return }
                    Task { await model.connectAll() }
                }
        }
    }
}
