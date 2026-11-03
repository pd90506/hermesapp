import Foundation

/// What one chat is doing, as a sidebar row shows it: Desktop's session dot
/// (`apps/desktop/src/store/session-dot-state.ts`), less its unread and draft states, which
/// the row shows its own way (`GatewayConnection.isUnread`).
///
/// One state per chat, the loudest first: a question for the user outranks a running turn,
/// which outranks work left running in the background.
public enum ChatStatus: Sendable, Hashable {
    case idle
    /// Its turn's children still run after the turn ended (async `delegate_task`), or a
    /// process its agent started in the background still runs (`BackgroundProcessList`):
    /// Desktop's hollow "background" dot.
    case background
    /// A turn is running.
    case working
    /// An approval, question, password or secret is waiting for the user's answer.
    case waitingForYou

    /// Desktop's priority (`session-dot-state.ts:158-181`): the last claim wins.
    static func resolve(waiting: Bool, running: Bool, background: Bool) -> ChatStatus {
        if waiting { return .waitingForYou }
        if running { return .working }
        return background ? .background : .idle
    }
}

/// A chat with a question waiting for the user (`GatewayConnection.waitingChats`).
public struct WaitingChat: Sendable, Hashable {
    /// Its runtime id on the connection.
    public var sessionID: String
    /// Nil when the connection holds no chat for the runtime.
    public var storedSessionID: String?
    public var profile: String?
    public var isBotChat: Bool
}
