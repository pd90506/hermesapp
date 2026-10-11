import SwiftUI

@main
struct HermesMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                #if DEBUG
                .onAppear { UITestLaunch.placeWindowsOnBuiltInDisplay() }
                #endif
        }
        .commands {
            SidebarCommands()
        }

        Settings {
            NavigationStack {
                ConnectionSettingsView()
            }
            .environment(model)
            .frame(width: 480, height: 560)
        }
    }
}

#if DEBUG
extension UITestLaunch {
    /// Under UI tests, keep the app's windows on the Mac's built-in display, away
    /// from the external displays the user works on.
    @MainActor
    static func placeWindowsOnBuiltInDisplay() {
        guard current != nil else { return }
        DispatchQueue.main.async {
            let builtIn = NSScreen.screens.first { screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
            }
            guard let area = builtIn?.visibleFrame else { return }
            for window in NSApp.windows where window.isVisible {
                window.setFrame(window.frame.size.fitted(in: area), display: true)
            }
        }
    }
}

private extension CGSize {
    func fitted(in area: CGRect) -> CGRect {
        CGRect(origin: area.origin, size: CGSize(width: min(width, area.width), height: min(height, area.height)))
    }
}
#endif
