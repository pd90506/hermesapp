import Foundation
import HermesKit
import HermesProtocol

/// System notifications (`SystemNotifier`): their buttons, and the check for replies
/// that iOS's background app refresh runs.
extension AppModel {
    /// A notification's Approve / Reject. On iOS the app may have been suspended, its
    /// socket gone: it connects first, and the request comes back with the session's
    /// open requests. If it can't be answered, the chat opens instead.
    func answerApproval(_ requestID: String, choice: ApprovalChoice, on serverID: UUID) async {
        guard let server = server(serverID) else { return }
        if !server.isConnected { await connect(server) }
        do {
            try await server.connection.answerApproval(requestID: requestID, choice: choice)
        } catch {
            actionError = describe(error, on: server)
        }
    }

    /// Reads every connected server's session list and Bot Chats and alerts the replies
    /// not seen yet (`GatewayConnection.checkForReplies`). Connects first: iOS
    /// suspended the sockets with the app.
    func checkForReplies() async {
        await connectAll()
        for server in servers where server.isConnected {
            await server.connection.checkForReplies()
        }
    }
}
