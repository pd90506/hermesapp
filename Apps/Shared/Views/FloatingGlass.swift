import SwiftUI

/// Liquid Glass for the app's floating controls (the composer, the scroll-to-bottom pill,
/// the session list's tabs), as Apple's own apps use it: on the controls that float over
/// the content, never on the content or the theme's surfaces under it. The system's
/// regular glass, untinted, as Messages' field: a tint in the theme's composer colour
/// turned a flat dark grey in a window that isn't key (230 of 255 on a white chat, where
/// the untinted glass is 240 and Messages' 243; the user, 2026-10-29).
extension View {
    func floatingGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        glassEffect(.regular.interactive(interactive), in: shape)
    }

    /// This glass's place among the chat's (`ChatGlass`): the scroll-to-bottom pill grows
    /// out of the composer's card and melts back into it. Nothing outside a chat.
    func chatGlassID(_ id: String) -> some View {
        modifier(ChatGlassID(id: id))
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
