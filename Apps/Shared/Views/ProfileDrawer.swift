#if os(iOS)
import SwiftUI
import UIKit

/// On iPhone, the profile rail under the session list, as Discord's server rail: the
/// list covers the screen, and the Profiles button (where Back was) or a swipe right
/// slides it right, uncovering the rail beside it, where it rests. Picking a profile,
/// a tap on the list, the button again or a swipe left slides it back.
///
/// The rail is never a screen of its own. As the split view's first column it was one
/// Back away from the list, and showed alone, stretched over the screen (2026-10-18).
struct ProfileDrawer<Rail: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var rail: Rail
    @ViewBuilder var content: Content
    /// How far a drag in progress has moved the list from where it rests.
    @State private var drag: CGFloat = 0

    /// How far the list slides: the rail and the line after it.
    static var railWidth: CGFloat { ProfileRailItem.width + 1 }

    var body: some View {
        let shift = min(max((isOpen ? Self.railWidth : 0) + drag, 0), Self.railWidth)
        ZStack(alignment: .leading) {
            // Only while uncovered, so nothing reaches it under the list (VoiceOver too).
            if shift > 0 {
                HStack(spacing: 0) {
                    rail
                        .frame(width: ProfileRailItem.width)
                    Divider()
                }
                .allowsHitTesting(isOpen)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Over the rail: the list's header and Bot Chat draw no background.
                .background(.background)
                .overlay {
                    // While the rail shows, the list only slides back.
                    if isOpen {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { slide(open: false) }
                            .gesture(closingDrag)
                            .accessibilityHidden(true)
                    }
                }
                .offset(x: shift)
        }
        // Anywhere on the list, as iOS 26's Back swipe works anywhere on a page.
        .gesture(OpeningPan(isEnabled: !isOpen,
                            changed: { drag = $0 },
                            ended: { translation, velocity in
                                slide(open: translation + velocity * 0.15 > Self.railWidth / 2)
                            }))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Profiles", systemImage: "sidebar.leading") { slide(open: !isOpen) }
                    .accessibilityIdentifier("profilesButton")
            }
        }
    }

    /// A swipe left on the list while the rail shows.
    private var closingDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag = min($0.translation.width, 0) }
            .onEnded { value in
                let moved = value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.15
                slide(open: moved > -Self.railWidth / 2)
            }
    }

    private func slide(open: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            isOpen = open
            drag = 0
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
