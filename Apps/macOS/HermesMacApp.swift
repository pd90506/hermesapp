import SwiftUI

@main
struct HermesMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                // The size and place the window last had, across launches and updates.
                .windowFrameAutosave("HermesMainWindow")
                #if DEBUG
                .onAppear { UITestLaunch.placeWindowsOnBuiltInDisplay() }
                #endif
        }
        // The first window, before there is a saved frame.
        .defaultWindowPlacement { _, context in
            WindowPlacement(size: Self.defaultWindowSize(in: context.defaultDisplay.visibleRect.size))
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

/// Owns the model, so quitting can stop the Hermes backend the app started.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.watchLocalBackend() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.terminateLocalBackend()
    }
}

extension HermesMacApp {
    /// 1160 × 760 pt (picked by the user, 2026-10), shrunk to fit a smaller screen.
    /// (`defaultSize` doesn't shrink: on a 1024-pt screen the window ran off the edge.)
    static func defaultWindowSize(in screen: CGSize) -> CGSize {
        CGSize(width: min(1160, screen.width), height: min(760, screen.height))
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
