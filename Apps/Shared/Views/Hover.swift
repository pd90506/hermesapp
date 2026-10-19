import SwiftUI

/// Pointer feedback in one look for the whole Mac app, as in ChatGPT and Codex: a
/// soft rounded fill under the pointer, a little stronger while pressed, none when
/// disabled.
///
/// How it tracks the pointer: `onHover`. On macOS SwiftUI backs it with the
/// `NSTrackingArea` that every `NSHostingView` (and every List cell's hosting view)
/// installs with `.mouseEnteredAndExited`, `.mouseMoved`, `.activeAlways` and
/// `.inVisibleRect`, so it follows a real pointer in a key or background window.
/// `HoverTests` drives that tracking area. The fill is a background only: it takes
/// no clicks, so selection, context menus and drags are untouched.
///
/// It applies to macOS only. iOS keeps its native look: `hoverHighlight` does
/// nothing there, and `hoverButtonStyle` is plain `.borderless`.
enum Hover {
    static let cornerRadius: CGFloat = 8
    /// The macOS sidebar's selection is inset this far from the List's edges;
    /// the row hover fill matches it.
    static let rowInset: CGFloat = 10
    /// Where a sidebar row's content starts, from the List's edge.
    static let rowContentInset: CGFloat = 16
    /// The row hover fill stops this far short of the row's top and bottom, so it never
    /// touches the selection on the row next to it (which fills its row's full height):
    /// the two fills stay apart by this gap.
    static let rowGap: CGFloat = 1

    /// Meant to stay lighter than a selected row's fill (`SurfaceColors.selection`), so
    /// a selected row reads as stronger than a hovered one.
    static func fill(pressed: Bool) -> Color {
        .primary.opacity(pressed ? 0.11 : 0.06)
    }

}

extension View {
    /// A hover fill behind this view, in `shape`. For controls a `ButtonStyle` doesn't
    /// reach, such as a `Menu`. Apply `.disabled` outside this modifier, so the fill sees it.
    func hoverHighlight(in shape: some Shape = RoundedRectangle(cornerRadius: Hover.cornerRadius),
                        isEnabled: Bool = true) -> some View {
        #if os(macOS)
        modifier(HoverHighlight(shape: AnyShape(shape), isActive: isEnabled))
        #else
        self
        #endif
    }

    /// A sidebar List row's selection and hover fills, inset `Hover.rowInset` from the
    /// List's edges. The selection (the theme's, `SurfaceColors.selection`) fills the row's height; the hover
    /// stops `Hover.rowGap` short of its top and bottom, so a selected row beside it stays
    /// apart from it, and the selected row has none. The whole row reacts, not just its
    /// text. The List's own selection highlight is off (`NoTableSelectionHighlight`).
    func sidebarRowHighlight(isSelected: Bool) -> some View {
        #if os(macOS)
        modifier(SidebarRowHighlight(isSelected: isSelected))
        #else
        self
        #endif
    }

    /// `HoverButtonStyle` on macOS; `.borderless` on iOS.
    func hoverButtonStyle(_ shape: HoverButtonStyle.Shape = .rounded, padding: CGFloat = 4) -> some View {
        #if os(macOS)
        buttonStyle(HoverButtonStyle(shape: shape, padding: padding))
        #else
        buttonStyle(.borderless)
        #endif
    }
}

/// The fill itself. Stays in the hierarchy at zero opacity, so hovering never
/// changes the view's identity or layout.
struct HoverHighlight: ViewModifier {
    var shape: AnyShape
    /// `false` while something else already marks the view, such as a selected row.
    var isActive = true
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(Hover.fill(pressed: isPressed))
                    .opacity(isEnabled && isActive && (isHovered || isPressed) ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .onHover { isHovered = $0 }
    }
}

#if os(macOS)
struct SidebarRowHighlight: ViewModifier {
    var isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.surfaces) private var surfaces
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Hover.cornerRadius)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            // Past the content to the cell's edges: the pointer hovers the row even
            // between its lines. Each cell is its own hosting view, so this can't
            // reach into the neighbouring rows.
            .contentShape(Rectangle().inset(by: -16))
            .onHover { isHovered = $0 }
            .background { NoTableSelectionHighlight().accessibilityHidden(true) }
            .listRowBackground(
                ZStack {
                    shape
                        .fill(Hover.fill(pressed: false))
                        .opacity(isHovered && isEnabled && !isSelected ? 1 : 0)
                        .padding(.vertical, Hover.rowGap)
                    shape
                        .fill(surfaces.selection)
                        .opacity(isSelected ? 1 : 0)
                }
                .padding(.horizontal, Hover.rowInset)
                .accessibilityHidden(true))
    }
}

/// Turns off the List's own selection highlight, which AppKit draws in the system's
/// accent while the list has focus and in gray once focus moves on (to the composer,
/// after a session is picked): the selected row changed colour with focus, and never
/// took the theme's. The rows draw their selection instead (`SidebarRowHighlight`).
/// Selection itself, keyboard included, is still the List's.
private struct NoTableSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// On the table the row is in. Cells are reused and moved between tables, so
        /// every row sets it whenever it lands in one.
        func apply() {
            var view = superview
            while let candidate = view, !(candidate is NSTableView) { view = candidate.superview }
            guard let table = view as? NSTableView, table.selectionHighlightStyle != .none else { return }
            table.selectionHighlightStyle = .none
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

/// A borderless button with the hover fill: icon buttons (`.circle`) and small
/// text buttons (`.rounded`). Focus rings are SwiftUI's, as for any styled button.
struct HoverButtonStyle: ButtonStyle {
    enum Shape { case rounded, circle }

    var shape: Shape = .rounded
    var padding: CGFloat = 4
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let outline = shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Hover.cornerRadius))
        configuration.label
            .padding(padding)
            .contentShape(outline)
            .opacity(isEnabled ? 1 : 0.4)
            .modifier(HoverHighlight(shape: outline, isPressed: configuration.isPressed))
    }
}
