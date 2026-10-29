import SwiftUI

/// Liquid Glass for the app's floating controls (the composer, the scroll-to-bottom pill,
/// the session list's tabs), as Apple's own apps use it: on the controls that float over
/// the content, never on the content or the theme's surfaces under it. Tinted with the
/// theme's composer colour, so each theme keeps its own look through the glass (the
/// user, 2026-10-20: the themes stay apart).
extension View {
    func themedGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(ThemedGlass(shape: AnyShape(shape), isInteractive: interactive))
    }

    /// This glass's place among the chat's (`ChatGlass`): the scroll-to-bottom pill grows
    /// out of the composer's card and melts back into it. Nothing outside a chat.
    func chatGlassID(_ id: String) -> some View {
        modifier(ChatGlassID(id: id))
    }
}

private struct ThemedGlass: ViewModifier {
    let shape: AnyShape
    let isInteractive: Bool
    @Environment(\.surfaces) private var surfaces
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            // In a window that isn't key, the Mac draws glass as a flat mid grey (the
            // composer on a white chat, the user 2026-10-29). There the theme's composer
            // colour, opaque, covers it, as AppKit's own inactive controls go flat.
            .background {
                if !appearsActive { shape.fill(surfaces.composer) }
            }
            #endif
            .glassEffect(.regular.tint(ThemedGlass.tint(surfaces, colorScheme)).interactive(isInteractive),
                         in: shape)
    }

    /// The theme's composer colour, a little stronger in dark, where the glass alone is light.
    static func tint(_ surfaces: SurfaceColors, _ colorScheme: ColorScheme) -> Color {
        surfaces.composer.opacity(colorScheme == .dark ? 0.55 : 0.4)
    }
}

/// The chat's glass namespace, set by `ChatView` around its transcript and composer.
struct ChatGlass {
    let namespace: Namespace.ID
}

extension EnvironmentValues {
    @Entry var chatGlass: ChatGlass?
}

private struct ChatGlassID: ViewModifier {
    let id: String
    @Environment(\.chatGlass) private var chatGlass

    func body(content: Content) -> some View {
        if let chatGlass {
            content.glassEffectID(id, in: chatGlass.namespace)
        } else {
            content
        }
    }
}
