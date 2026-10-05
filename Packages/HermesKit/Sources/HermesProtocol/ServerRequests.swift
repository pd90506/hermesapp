import Foundation

/// A server→client JSON-RPC request (`tui_gateway/server_requests.py`).
///
/// Frame: `{"jsonrpc":"2.0","id":"srq-<12hex>","method":"approval","params":{"session_id":…,…}}`.
/// The client answers with a normal JSON-RPC response carrying the same id;
/// the server does not reply to that response. Unanswered requests come back
/// as `open_requests` on resume/replay (then `replayed == true`).
public struct ServerRequest: Sendable, Hashable, Identifiable {
    public var id: String
    public var method: String
    public var params: JSONValue
    /// Re-delivered from `open_requests` rather than received live.
    public var replayed: Bool

    public init(id: String, method: String, params: JSONValue, replayed: Bool = false) {
        self.id = id
        self.method = method
        self.params = params
        self.replayed = replayed
    }

    public init(_ entry: OpenRequestEntry) {
        self.init(id: entry.id, method: entry.method, params: entry.params, replayed: true)
    }

    public var sessionID: String? { params["session_id"]?.stringValue }

    /// Typed view of the request. Unknown methods and malformed params map to `.unsupported`.
    public var kind: ServerRequestKind {
        func decode<T: Decodable>(_: T.Type) -> T? { try? params.decode(T.self) }
        switch method {
        case ServerRequestMethod.approval: return decode(ApprovalRequest.self).map(ServerRequestKind.approval) ?? .unsupported
        case ServerRequestMethod.clarify: return decode(ClarifyRequest.self).map(ServerRequestKind.clarify) ?? .unsupported
        case ServerRequestMethod.sudo: return decode(SudoRequest.self).map(ServerRequestKind.sudo) ?? .unsupported
        case ServerRequestMethod.secret: return decode(SecretRequest.self).map(ServerRequestKind.secret) ?? .unsupported
        default: return .unsupported
        }
    }
}

/// Server→client request methods (`tui_gateway/contracts/server_requests.py`).
public enum ServerRequestMethod {
    public static let approval = "approval"
    public static let clarify = "clarify"
    public static let sudo = "sudo"
    public static let secret = "secret"

    /// What the MVP client answers. Anything else is declined (see below) so
    /// the agent fails fast instead of waiting out the deadline.
    public static let mvpSupported: Set<String> = [approval, clarify, sudo, secret]

    /// Window-owned bridges answered only by a Desktop window showing the
    /// session. Other clients must decline with `notShownCode`: any other
    /// error is a final answer that would beat the real window's reply
    /// (`tui_gateway/server_requests.py:22-28,221-275`). Every other
    /// unsupported method gets -32601.
    public static let windowOwned: Set<String> = ["preview.read", "preview.act", "terminal.read", "window.read", "tour"]

    /// `NOT_SHOWN_CODE` (`tui_gateway/server_requests.py:100`).
    public static let notShownCode = 4404
}

public enum ServerRequestKind: Sendable, Hashable {
    case approval(ApprovalRequest)
    case clarify(ClarifyRequest)
    case sudo(SudoRequest)
    case secret(SecretRequest)
    case unsupported
}

// MARK: - approval

public enum ApprovalChoice: String, Sendable, Hashable, Codable, CaseIterable {
    case once, session, always, deny
}

/// Params of the `approval` server request (`ApprovalRequestParams`).
public struct ApprovalRequest: Sendable, Hashable, Codable {
    public var sessionID: String
    public var requestID: String
    public var command: String?
    public var description: String?
    public var choices: [ApprovalChoice]?
    public var allowPermanent: Bool?
    public var allowSession: Bool?
    public var toolName: String?

    enum CodingKeys: String, CodingKey {
        case command, description, choices
        case sessionID = "session_id"
        case requestID = "request_id"
        case allowPermanent = "allow_permanent"
        case allowSession = "allow_session"
        case toolName = "tool_name"
    }

    /// Choices to offer, honouring the allow flags when `choices` is absent.
    public var offeredChoices: [ApprovalChoice] {
        if let choices, !choices.isEmpty { return choices }
        var result: [ApprovalChoice] = [.once]
        if allowSession ?? true { result.append(.session) }
        if allowPermanent ?? true { result.append(.always) }
        result.append(.deny)
        return result
    }
}

/// Answer to `approval` (`ApprovalResult`).
public struct ApprovalAnswer: Sendable, Hashable, Codable {
    public var choice: ApprovalChoice
    /// Apply to every pending approval of the session.
    public var all: Bool?

    public init(choice: ApprovalChoice, all: Bool? = nil) {
        self.choice = choice
        self.all = all
    }
}

// MARK: - clarify

public struct ClarifyQuestion: Sendable, Hashable, Codable, Identifiable {
    public var qid: String
    public var question: String
    public var choices: [String]?
    public var multiSelect: Bool?

    public var id: String { qid }

    enum CodingKeys: String, CodingKey {
        case qid, question, choices
        case multiSelect = "multi_select"
    }
}

/// Params of the `clarify` server request (`ClarifyRequestParams`).
public struct ClarifyRequest: Sendable, Hashable, Codable {
    public var sessionID: String
    public var questions: [ClarifyQuestion]
    /// Answers already locked via `clarify.lock` (present on replay).
    public var answers: [String: String?]?

    enum CodingKeys: String, CodingKey {
        case questions, answers
        case sessionID = "session_id"
    }
}

/// Answer to `clarify` (`ClarifyResult`). `answers == nil` cancels every question.
public struct ClarifyAnswer: Sendable, Hashable, Codable {
    public var answers: [String: String?]?

    public init(answers: [String: String?]?) { self.answers = answers }

    // Encode `nil` values in the map as JSON null rather than dropping them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let answers {
            let object = answers.mapValues { $0.map(JSONValue.string) ?? .null }
            try container.encode(JSONValue.object(object), forKey: .answers)
        }
    }

    enum CodingKeys: String, CodingKey { case answers }
}

// MARK: - sudo / secret

public struct SudoRequest: Sendable, Hashable, Codable {
    public var sessionID: String
    public var command: String?

    enum CodingKeys: String, CodingKey {
        case command
        case sessionID = "session_id"
    }
}

public struct SecretRequest: Sendable, Hashable, Codable {
    public var sessionID: String
    public var envVar: String
    public var prompt: String

    enum CodingKeys: String, CodingKey {
        case prompt
        case sessionID = "session_id"
        case envVar = "env_var"
    }
}

/// Answer to sudo/secret/vault prompts (`ValueResult`). Empty string = skipped.
public struct ValueAnswer: Sendable, Hashable, Codable {
    public var value: String

    public init(value: String) { self.value = value }
}
