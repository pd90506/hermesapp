import Sparkle
import SwiftUI

/// In-app updates through Sparkle, from the appcast `SUFeedURL` names (set by
/// `HERMES_UPDATE_FEED_URL` in Config/Local.xcconfig; see scripts/release-mac.sh).
///
/// Off in Debug builds and when no feed is set, so a development build never
/// offers to replace itself with a release.
@MainActor
final class Updater {
    static let isConfigured: Bool = {
        #if DEBUG
        return false
        #else
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return URL(string: feed)?.scheme != nil && !key.isEmpty
        #endif
    }()

    private let controller: SPUStandardUpdaterController?

    init() {
        controller = Self.isConfigured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var updater: SPUUpdater? { controller?.updater }
}

/// "Check for Updates…" in the app menu, disabled while Sparkle can't check
/// (a check is already running).
struct CheckForUpdatesButton: View {
    @State private var model: CheckForUpdatesModel

    init(updater: SPUUpdater) {
        _model = State(initialValue: CheckForUpdatesModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { model.updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

@MainActor
@Observable
private final class CheckForUpdatesModel {
    let updater: SPUUpdater
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        // KVO delivers on the thread that changed the value; Sparkle changes it on the main thread.
        observation = updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }
}
