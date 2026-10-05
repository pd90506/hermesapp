import SwiftUI

@main
struct HermesMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            SidebarCommands()
        }

        Settings {
            NavigationStack {
                ConnectionSettingsView()
            }
            .environment(model)
            .frame(width: 480, height: 460)
        }
    }
}
