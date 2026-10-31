import BackgroundTasks
import SwiftUI
import UIKit

@main
struct HermesiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    /// The extra time asked for on leaving the app (`keepAliveAfterLeaving`).
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    /// iOS's background app refresh for this app (`BGTaskSchedulerPermittedIdentifiers`).
    static let refreshTaskID = "\(Bundle.main.bundleIdentifier ?? "talaria").refresh"
    /// The least time between two refreshes asked of iOS; it picks the actual times.
    static let refreshInterval: TimeInterval = 15 * 60

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .appearance(model.appearance)
                .markdownColors(model.markdownColors)
                .colorTheme(model.markdownColors.preset)
                .onAppear { model.notifier.install() }
                .onChange(of: scenePhase) { _, phase in
                    model.notifier.appIsActive = phase == .active
                    switch phase {
                    case .background:
                        keepAliveAfterLeaving()
                        Self.scheduleRefresh()
                    case .active:
                        endBackgroundTask()
                        // iOS suspends sockets in the background; reconnect on return.
                        // The connection's replay logic restores the active session.
                        Task {
                            #if DEBUG
                            // Found gone on return, as a real iPhone's (the simulator keeps them).
                            if UITestLaunch.current?.dropsSocketsInBackground == true {
                                for server in model.servers { await server.connection.dropSocket(forgettingReplay: true) }
                            }
                            #endif
                            await model.connectAll()
                        }
                    default:
                        break
                    }
                }
        }
        // Every so often, as iOS sees fit, while the app is suspended: reconnect, read the
        // session lists and notify the replies that came meanwhile.
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            Self.scheduleRefresh()
            await model.checkForReplies()
        }
    }

    /// On leaving the app, iOS lets it run for about 30 seconds more if asked: the sockets
    /// stay up, so a turn that ends then, or a question Hermes asks, still notifies.
    private func keepAliveAfterLeaving() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Notify replies") {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Asks iOS for the next background refresh (one is pending at a time).
    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }
}
