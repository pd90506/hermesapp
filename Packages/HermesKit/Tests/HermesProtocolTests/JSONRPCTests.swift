import Foundation
import Testing

@testable import HermesProtocol

@Suite struct JSONRPCTests {
    @Test func decodesResponseWithNumericOrStringID() throws {
        let numeric = try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#.utf8))
        guard case .response(let r1) = numeric else { Issue.record("expected response"); return }
        #expect(r1.id == .number(7))
        #expect(r1.result?["ok"]?.boolValue == true)

        let string = try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":"c-1","result":null}"#.utf8))
        guard case .response(let r2) = string else { Issue.record("expected response"); return }
        #expect(r2.id == .string("c-1"))
        #expect(r2.result == .null)
        #expect(r2.error == nil)
    }

    @Test func decodesErrorResponse() throws {
        let message = try RPCMessage.decode(Data(
            #"{"jsonrpc":"2.0","id":"c-2","error":{"code":4001,"message":"session not found"}}"#.utf8))
        guard case .response(let response) = message else { Issue.record("expected response"); return }
        #expect(response.error == RPCError(code: 4001, message: "session not found"))
    }

    @Test func distinguishesNotificationFromServerRequest() throws {
        let notification = try RPCMessage.decode(Data(
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta"}}"#.utf8))
        guard case .request(let n) = notification else { Issue.record("expected request"); return }
        #expect(n.isNotification)

        let request = try RPCMessage.decode(Data(
            #"{"jsonrpc":"2.0","id":"s-9","method":"approval.request","params":{}}"#.utf8))
        guard case .request(let r) = request else { Issue.record("expected request"); return }
        #expect(!r.isNotification)
        #expect(r.id == .string("s-9"))
    }

    @Test func rejectsNonObjectFrames() {
        #expect(throws: RPCError.self) { try RPCMessage.decode(Data("[1,2]".utf8)) }
        #expect(throws: RPCError.self) { try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)) }
    }

    @Test func encodesNullResultExplicitly() throws {
        let data = try RPCMessage.response(RPCResponse(id: .string("x"), result: .null)).encoded()
        #expect(String(decoding: data, as: UTF8.self) == #"{"id":"x","jsonrpc":"2.0","result":null}"#)
    }

    @Test func notificationOmitsID() throws {
        let data = try RPCMessage.request(RPCRequest(id: nil, method: "ping")).encoded()
        #expect(String(decoding: data, as: UTF8.self) == #"{"jsonrpc":"2.0","method":"ping"}"#)
    }

    @Test func jsonValueRoundTripsAndKeepsIntegersIntegral() throws {
        let value: JSONValue = ["a": 1, "b": 1.5, "c": [true, nil, "s"], "d": ["e": -3]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(String(decoding: try JSONEncoder().encode(JSONValue.number(42)), as: UTF8.self) == "42")
    }
}
