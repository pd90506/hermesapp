import Foundation

/// JSON-RPC 2.0 framing as used by the Hermes TUI gateway.
///
/// One WebSocket text frame carries exactly one JSON-RPC message. The
/// gateway sends three kinds of frames to the client: responses to client
/// requests, notifications (the `event` stream), and — for blocking prompts
/// such as approvals — requests of its own. See `docs/protocol.md`.
public enum JSONRPC {
    public static let version = "2.0"
}

/// A JSON-RPC id. The spec allows numbers or strings; the client always
/// sends strings but accepts either from the server.
public enum RPCID: Sendable, Hashable, Codable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .number(let value): String(value)
        case .string(let value): value
        }
    }
}

/// The `error` member of a JSON-RPC response.
public struct RPCError: Error, Sendable, Hashable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC 2.0 codes.
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}

/// A request (has `id`) or notification (no `id`), in either direction.
public struct RPCRequest: Sendable, Hashable, Codable {
    public var jsonrpc: String = JSONRPC.version
    public var id: RPCID?
    public var method: String
    public var params: JSONValue?

    public init(id: RPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }
}

/// A response to a request, in either direction.
public struct RPCResponse: Sendable, Hashable, Codable {
    public var jsonrpc: String = JSONRPC.version
    public var id: RPCID?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: RPCID?, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: RPCID?, error: RPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }

    // `result: null` is a valid success, so encode `result` explicitly when
    // there is no error instead of letting synthesized Codable drop it.
    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? JSONRPC.version
        id = try container.decodeIfPresent(RPCID.self, forKey: .id)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        if error == nil, result == nil { result = .null }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id { try container.encode(id, forKey: .id) } else { try container.encodeNil(forKey: .id) }
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(result ?? .null, forKey: .result)
        }
    }
}

/// Any inbound or outbound JSON-RPC frame.
public enum RPCMessage: Sendable, Hashable {
    case request(RPCRequest)
    case response(RPCResponse)

    public static func decode(_ data: Data) throws -> RPCMessage {
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = raw else {
            throw RPCError(code: RPCError.invalidRequest, message: "Frame is not a JSON object")
        }
        if object["method"] != nil {
            return .request(try raw.decode(RPCRequest.self))
        }
        if object["result"] != nil || object["error"] != nil {
            return .response(try raw.decode(RPCResponse.self))
        }
        throw RPCError(code: RPCError.invalidRequest, message: "Frame has neither method nor result/error")
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch self {
        case .request(let request): return try encoder.encode(request)
        case .response(let response): return try encoder.encode(response)
        }
    }
}
