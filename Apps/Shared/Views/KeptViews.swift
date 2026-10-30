#if os(macOS)
import AppKit
import SwiftUI

/// Views kept built while off screen, each in its own hosting controller, with only the
/// one shown visible: the others are hidden AppKit views (`isHidden`). A hidden view
/// keeps its state and its scroll position, but takes no drops, clicks or keyboard, and
/// keeps its size while the window is resized (`KeptChats`). Its content still answers
/// accessibility, so it hides itself there (`accessibilityHidden`).
///
/// Stacked in one SwiftUI view instead, hidden by opacity, a hidden chat's composer still
/// took files dropped on the one shown: AppKit picks a drop's view by frame and drag
/// types, not by SwiftUI's opacity or hit testing.
///
/// Not out of the window, as `NSTabView` keeps its tabs: each view put back in it
/// appeared afresh to SwiftUI, and going back to a chat took about a third longer than
/// with the chats stacked; hidden, it takes as long (`ChatSwitchTests`, VM, 2026-10-30).
struct KeptViews<ID: Hashable, Content: View>: NSViewControllerRepresentable {
    /// The views kept, the one shown among them.
    let ids: [ID]
    let shown: ID?
    @ViewBuilder let content: (ID) -> Content

    func makeNSViewController(context: Context) -> Controller { Controller() }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(ids: ids, shown: shown, environment: context.environment, content: content)
    }

    /// The views take the whole of the space given, and set no size of their own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// What each hosting controller shows: the view, in the environment around this one
    /// (a hosting controller starts from the app's defaults, not its container's).
    struct Root: View {
        let content: Content
        let environment: EnvironmentValues

        var body: some View {
            content.environment(\.self, environment)
        }
    }

    final class Controller: NSViewController {
        private var hosts: [ID: NSHostingController<Root>] = [:]
        private var shownID: ID?

        override func loadView() { view = NSView() }

        func update(ids: [ID], shown: ID?, environment: EnvironmentValues, content: (ID) -> Content) {
            let kept = Set(ids).union(shown.map { [$0] } ?? [])
            for (id, host) in hosts where !kept.contains(id) {
                host.view.removeFromSuperview()
                host.removeFromParent()
                hosts[id] = nil
            }
            if let shown, hosts[shown] == nil {
                let host = NSHostingController(rootView: Root(content: content(shown), environment: environment))
                // The container sets its size; the view reports none of its own.
                host.sizingOptions = []
                addChild(host)
                view.addSubview(host.view)
                hosts[shown] = host
            }
            // Only the views shown and just hidden are updated: a hidden one still
            // follows its own models, and takes the environment of the day when it is
            // shown again.
            var updated = shown.map { [$0] } ?? []
            if shownID != shown {
                if let hidden = shownID, let host = hosts[hidden] {
                    host.view.isHidden = true
                    // Hidden, it keeps its size: resizing the window lays out only the
                    // view shown.
                    host.view.autoresizingMask = []
                    updated.append(hidden)
                }
                shownID = shown
                if let shown, let host = hosts[shown] {
                    host.view.frame = view.bounds
                    host.view.autoresizingMask = [.width, .height]
                    host.view.isHidden = false
                }
            }
            for id in updated {
                hosts[id]?.rootView = Root(content: content(id), environment: environment)
            }
        }
    }
}
#endif
