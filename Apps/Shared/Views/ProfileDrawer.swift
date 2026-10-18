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

    /// The panel's width on a screen this wide: most of it, the list's edge showing
    /// beside it, as Slack's.
    static func width(in screen: CGFloat) -> CGFloat { min((screen * 0.85).rounded(), 360) }

    /// The panel's trailing corners, about the screen's.
    private static var cornerRadius: CGFloat { 36 }

    var body: some View {
        GeometryReader { proxy in
            let width = Self.width(in: proxy.size.width)
            let shown = min(max((isOpen ? width : 0) + drag, 0), width)
            ZStack(alignment: .leading) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Nothing under the panel and its shade answers (VoiceOver too).
                    .accessibilityHidden(shown > 0)

                // Only while it shows, so nothing reaches it when it is away.
                if shown > 0 {
                    Color.black
                        .opacity(0.35 * shown / width)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { slide(open: false) }
                        .gesture(closingDrag(width: width))
                        .accessibilityLabel("Close profiles")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { slide(open: false) }

                    rail
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background {
                            UnevenRoundedRectangle(bottomTrailingRadius: Self.cornerRadius,
                                                   topTrailingRadius: Self.cornerRadius, style: .continuous)
                                .fill(.background)
                                .shadow(color: .black.opacity(0.15), radius: 12)
                                .ignoresSafeArea()
                        }
                        // A swipe left closes it; the profiles still scroll up and down.
                        .simultaneousGesture(closingDrag(width: width))
                        .offset(x: shown - width)
                        .allowsHitTesting(isOpen)
                }
            }
            // Anywhere on the list, as iOS 26's Back swipe works anywhere on a page.
            .gesture(OpeningPan(isEnabled: !isOpen,
                                changed: { drag = $0 },
                                ended: { translation, velocity in
                                    slide(open: translation + velocity * 0.15 > width / 2)
                                }))
        }
        .environment(\.toggleProfiles, ToggleProfiles { slide(open: !isOpen) })
    }

    /// A swipe left on the panel or the shade while it shows. Only a sideways one, so a
    /// scroll through the profiles never moves the panel.
    private func closingDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = min(value.translation.width, 0)
            }
            .onEnded { value in
                guard drag != 0 else { return }
                let moved = value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.15
                slide(open: moved > -width / 2)
            }
    }

    private func slide(open: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            isOpen = open
            drag = 0
        }
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

/// A pan right that starts the drawer opening: horizontal, so the list still scrolls
/// on a vertical one. A UIKit recognizer, as a SwiftUI drag on the list took its
/// scrolling.
private struct OpeningPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var changed: (CGFloat) -> Void
    var ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: changed(max(translation, 0))
        case .ended: ended(translation, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.5
        }

        // Beside the list's own scrolling, which otherwise could take the touch first.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
