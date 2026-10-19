import HermesKit
import SwiftUI

/// Fixed-height action row under a message, after ChatGPT's and Desktop's: a small grey
/// Copy, a "…" menu (Branch in New Chat, on replies) and when the message was written.
/// Keeping it in layout while hidden prevents row movement on hover and while the newest
/// reply streams.
struct MessageActionBar: View {
    let isHovering: Bool
    let isNewest: Bool
    var alignment: HorizontalAlignment = .leading
    var timestamp: Date? = nil
    /// Branch in New Chat, in the "…" menu; without it there is no menu.
    var branch: (() -> Void)? = nil
    let copy: () -> Void

    var isVisible: Bool {
        #if os(macOS)
        isHovering || isNewest
        #else
        true
        #endif
    }

    /// The icons' and the time's grey: lighter than secondary text, so the row stays quiet
    /// under the message (asked for by the user, 2026-10-19).
    static let ink = Color.primary.opacity(0.42)

    var body: some View {
        HStack(spacing: 2) {
            if alignment == .trailing { Spacer(minLength: 0) }
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
                    .uiFont(.caption)
                    .frame(width: 16, height: 16)
            }
            .hoverButtonStyle(.rounded, padding: 4)
            .help("Copy Message")
            .accessibilityLabel("Copy Message")
            if let branch {
                Menu {
                    Button("Branch in New Chat", systemImage: "arrow.triangle.branch", action: branch)
                } label: {
                    Image(systemName: "ellipsis")
                        .uiFont(.caption, weight: .semibold)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight()
                .help("More")
                .accessibilityLabel("More actions")
                .accessibilityIdentifier("messageMoreMenu")
            }
            if let timestamp {
                MessageTimeLabel(date: timestamp)
                    .padding(.horizontal, 4)
            }
            if alignment == .leading { Spacer(minLength: 0) }
        }
        .foregroundStyle(Self.ink)
        .frame(minHeight: 26)
        .opacity(isVisible ? 1 : 0)
        // Fades in and out with the pointer, as ChatGPT's and Desktop's bars do.
        .animation(Motion.reveal, value: isVisible)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        // A container: on a plain stack the identifier replaced its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageActionBar")
    }
}

/// "3:27 PM" today, "Yesterday, 3:27 PM", else "Sep 28, 3:27 PM" (`MessageTimestamp`), with
/// the full date and time in its tooltip.
struct MessageTimeLabel: View {
    let date: Date

    static func text(for date: Date, now: Date = Date()) -> String {
        let clock = date.formatted(date: .omitted, time: .shortened)
        switch MessageTimestamp.day(of: date, now: now) {
        case .today: return clock
        case .yesterday: return String(localized: "Yesterday, \(clock)")
        case .earlier: return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    var body: some View {
        Text(Self.text(for: date))
            .uiFont(.caption2)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .help(date.formatted(date: .complete, time: .shortened))
            .accessibilityIdentifier("messageTime")
    }
}

/// A message and its action bar as one pointer area. `onHover` only counts
/// hit-testable parts of a view, so without the content shape the bar's empty
/// stretch (and the strip around Copy) would read as leaving the message: the
/// bar would hide, stop taking hits, and could not be brought back from below.
struct MessageHoverArea<Content: View>: View {
    @ViewBuilder let content: (_ isHovering: Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        content(isHovering)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }
}
