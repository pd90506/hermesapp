import SwiftUI

/// Fixed-height action row. Keeping it in layout while hidden prevents row
/// movement on hover and while the newest reply streams.
struct MessageActionBar: View {
    let isHovering: Bool
    let isNewest: Bool
    var alignment: HorizontalAlignment = .leading
    var timestamp: Date? = nil
    let copy: () -> Void

    var isVisible: Bool {
        #if os(macOS)
        isHovering || isNewest
        #else
        true
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            if alignment == .trailing { Spacer(minLength: 0) }
            Button("Copy Message", systemImage: "doc.on.doc", action: copy)
                .labelStyle(.iconOnly)
                .hoverButtonStyle(.rounded, padding: 4)
                .help("Copy Message")
            if let timestamp {
                Text(timestamp, format: .relative(presentation: .named))
                    .uiFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if alignment == .leading { Spacer(minLength: 0) }
        }
        .frame(minHeight: 26)
        .opacity(isVisible ? 1 : 0)
        // Fades in and out with the pointer, as ChatGPT's and Desktop's bars do.
        .animation(Motion.reveal, value: isVisible)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .accessibilityIdentifier("messageActionBar")
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
