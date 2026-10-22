#if os(iOS)
import SwiftUI
import UIKit

/// On iPhone, the profiles in a drawer over the session list, as Slack's workspaces:
/// the profile's avatar at the list's top left (`CurrentProfileAvatar`) or a swipe right
/// on the list slides a wide panel in from the leading edge, over the list, which stays
/// where it is under a shade. Picking a profile, a tap on the shade, the avatar again or
/// a swipe left slides it back out (asked for by the user, 2026-10-18; it was a narrow
/// rail under the list, uncovered by sliding the list aside).
///
/// The profiles are never a screen of their own. As the split view's first column they
/// were one Back away from the list, and showed alone, stretched over the screen.
struct ProfileDrawer<Rail: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var rail: Rail
    @ViewBuilder var content: Content
    /// How far a drag in progress has moved the panel from where it rests.
    @State private var drag: CGFloat = 0
    @Environment(\.surfaces) private var surfaces
    /// The panel is in the hierarchy though closed: about to slide in, or sliding out.
    @State private var isMounted = false

    /// The panel's width on a screen this wide: most of it, the list's edge showing
    /// beside it, as Slack's.
    static func width(in screen: CGFloat) -> CGFloat { min((screen * 0.85).rounded(), 360) }

    /// How far the panel floats in from the screen's leading, top and bottom edges.
    private static var inset: CGFloat { 8 }

    var body: some View {
        GeometryReader { proxy in
            let width = Self.width(in: proxy.size.width)
            let shown = min(max((isOpen ? width : 0) + drag, 0), width)
            ZStack(alignment: .leading) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Nothing under the panel and its shade answers (VoiceOver too).
                    .accessibilityHidden(shown > 0)

                // From just before it opens until it has slid away, so it slides both
                // ways: inserted at its open place, it only faded in and out there.
                // Nothing reaches it when it is away.
                if isMounted || shown > 0 {
                    Color.black
                        .opacity(0.35 * shown / width)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { slide(open: false) }
                        .allowsHitTesting(shown > 0)
                        .accessibilityLabel("Close profiles")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { slide(open: false) }

                    rail
                        .frame(width: width - Self.inset)
                        .frame(maxHeight: .infinity)
                        .background {
                            // A panel of Liquid Glass floating in from the screen's edges, as
                            // iOS 26's sidebars, its corners concentric with the screen's:
                            // tinted deep with the theme's frame, as the Mac's profile rail.
                            Color.clear
                                .glassEffect(.regular.tint(surfaces.frame.opacity(0.85)),
                                             in: ConcentricRectangle(corners: .concentric(minimum: 28),
                                                                     isUniform: true))
                                .padding(.vertical, Self.inset)
                                .ignoresSafeArea()
                        }
                        .padding(.leading, Self.inset)
                        .offset(x: shown - width)
                        .allowsHitTesting(isOpen)
                }
            }
            // A swipe right anywhere on the list opens it, as iOS 26's Back swipe works
            // anywhere on a page; a swipe left anywhere on the panel or the shade closes
            // it. The panel follows the finger, and a flick is enough either way.
            .gesture(DrawerPan(isOpen: isOpen,
                               changed: { drag = isOpen ? min($0, 0) : max($0, 0) },
                               ended: { translation, velocity in
                                   let open = Self.settles(open: isOpen, translation: translation,
                                                           velocity: velocity, width: width)
                                   // What is left of the way, for the finger's speed to carry on.
                                   let rest = open ? width - shown : shown
                                   let toward = open ? velocity : -velocity
                                   slide(open: open, velocity: rest > 1 ? min(max(toward / rest, 0), 20) : 0)
                               }))
        }
        .environment(\.toggleProfiles, ToggleProfiles { slide(open: !isOpen) })
        // Closed (here or by picking a profile): gone once it has slid away.
        .task(id: isOpen) {
            guard !isOpen, isMounted else { return }
            try? await Task.sleep(for: Motion.drawerSettles)
            if !Task.isCancelled, !isOpen { isMounted = false }
        }
    }

    /// How fast a swipe, in points a second, goes its way however short it was, as the
    /// system's: a flick opens or closes the drawer; a slower one goes past halfway.
    static var flickSpeed: CGFloat { 300 }

    /// Whether a swipe let go of with this `translation` and `velocity` (points, points
    /// a second; rightwards positive) leaves the drawer open.
    static func settles(open isOpen: Bool, translation: CGFloat, velocity: CGFloat,
                        width: CGFloat) -> Bool {
        if abs(velocity) >= flickSpeed { return velocity > 0 }
        let shown = (isOpen ? width : 0) + translation
        return shown > width / 2
    }

    private func slide(open: Bool, velocity: CGFloat = 0) {
        let move = {
            withAnimation(velocity == 0 ? Motion.drawer : Motion.drawer(velocity: velocity)) {
                isOpen = open
                drag = 0
            }
        }
        guard open, !isMounted, !isOpen, drag == 0 else {
            isMounted = isMounted || open
            return move()
        }
        // Not there yet: in place off screen first, then slid in once laid out there.
        isMounted = true
        Task { @MainActor in move() }
    }
}

/// Opens the profiles' drawer over the session list, or closes it (`ProfileDrawer`).
/// Set only on iPhone.
struct ToggleProfiles {
    let action: @MainActor () -> Void

    @MainActor func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var toggleProfiles: ToggleProfiles?
}

/// The picked profile's avatar at the session list's top left, as Slack's workspace
/// icon: a tap opens the profiles' drawer over the list (`ProfileDrawer`), as a swipe
/// right does. Nothing where there is no drawer (iPad).
struct CurrentProfileAvatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.toggleProfiles) private var toggleProfiles

    static let size: CGFloat = 34

    var body: some View {
        if let toggleProfiles {
            Button { toggleProfiles() } label: {
                avatar
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profiles")
            .accessibilityHint("Shows the profiles")
            .accessibilityIdentifier("profilesButton")
        }
    }

    @ViewBuilder private var avatar: some View {
        if let server = model.sessionsServer, let bot = server.connection.listProfileBot {
            let connection = server.connection
            BotAvatar(name: bot.displayName, activity: connection.activity(for: bot), size: Self.size,
                      image: AvatarImages.image(connection.avatars[bot.name]),
                      color: bot.avatarColor.map(Color.init(rgb:)))
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: Self.size))
                .foregroundStyle(.secondary)
        }
    }
}

/// The drawer's swipe: right on the list while it is closed, left on the panel or the
/// shade while it is open. Only a sideways one starts it, so the list and the profiles
/// still scroll on a vertical one. A UIKit recognizer, as a SwiftUI drag on the list took
/// its scrolling, and on the panel, which moves with the finger, read the finger against
/// the moving panel: it shook, and went half as far. Once it has started, the scrolling
/// under it stops: until then the list followed the finger up and down under the opening
/// drawer (user, 2026-10-19).
private struct DrawerPan: UIGestureRecognizerRepresentable {
    var isOpen: Bool
    /// How far the finger has gone sideways, rightwards positive.
    var changed: (CGFloat) -> Void
    var ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.opens = !isOpen
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        // In the view under the whole drawer, which stays put while the panel moves.
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .began: context.coordinator.stopScrolling()
        case .changed: changed(translation)
        case .ended: ended(translation, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Which way it starts: right to open, left to close.
        var opens = true
        /// The pans of the scroll views under the touch (the session list's, or the
        /// profiles'), which recognize beside this one.
        private let scrollPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()

        /// The drawer took the touch: the list stops where it is. Turning a recognizer
        /// off and on cancels its touch; the next one scrolls again.
        func stopScrolling() {
            for pan in scrollPans.allObjects where pan.isEnabled {
                pan.isEnabled = false
                pan.isEnabled = true
            }
            scrollPans.removeAllObjects()
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let sideways = opens ? velocity.x : -velocity.x
            return sideways > 0 && sideways > abs(velocity.y) * 1.5
        }

        // Beside the scrolling under it, which otherwise could take the touch first.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer {
                // One that would start once the drawer has the touch doesn't.
                if recognizer.state == .began || recognizer.state == .changed { return false }
                scrollPans.add(scroll.panGestureRecognizer)
            }
            return true
        }
    }
}
#endif
