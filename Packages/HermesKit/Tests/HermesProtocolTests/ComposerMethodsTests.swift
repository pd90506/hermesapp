import Foundation
import HermesProtocol
import Testing

@Suite struct ComposerMethodsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func modelOptionsToleratesSparseAndOddRows() throws {
        // Decoding must tolerate change (AGENTS.md): a row without `models` and one
        // whose capabilities map is not the documented shape must not sink the catalog.
        let result = try decode(ModelOptionsResult.self, """
            {"providers":[{"slug":"nous","name":"Nous Portal"},
                          {"slug":"x","name":"X","models":["m"],"capabilities":{"m":"oops"},"pricing":{}}],
             "model":"m","provider":"x"}
            """)
        #expect(result.providers.map(\.models) == [[], ["m"]])
        #expect(result.providers[1].capabilities == nil)
        #expect(result.model == "m")
    }

    /// `error` is outside `ToolCompletePayload` (`contracts/events.py:278-291`): an odd
    /// value must not demote the event to `.unknown`, which would leave the row running.
    @Test func toolCompleteToleratesAnOddError() throws {
        let event = GatewayEvent(type: "tool.complete", sessionID: "s",
                                 payload: ["tool_id": "t1", "name": "terminal", "result_text": "ok",
                                           "error": ["code": 1]])
        guard case .toolComplete(let complete) = event.kind else {
            Issue.record("decoded as \(event.kind)")
            return
        }
        #expect(complete.toolID == "t1")
        #expect(complete.resultText == "ok")
        #expect(complete.error == nil)
        let failed = try decode(ToolComplete.self, #"{"tool_id":"t2","name":"x","error":"boom"}"#)
        #expect(failed.error == "boom")
    }

    @Test func processStopAnswerDecodes() throws {
        #expect(try decode(ProcessStopResult.self, #"{"killed":3}"#).killed == 3)
    }

    @Test func modelSwitchAnswersDecode() throws {
        let confirm = try decode(ConfigSetResult.self, """
            {"key":"model","value":"claude-opus-5-5","warning":"pricey","confirm_required":true,
             "confirm_message":"pricey","scope":"session"}
            """)
        #expect(confirm.confirmRequired == true)
        #expect(confirm.value?.stringValue == "claude-opus-5-5")
        let deferred = try decode(ConfigSetResult.self, """
            {"key":"model","value":"m","warning":"","confirm_required":false,"confirm_message":"","scope":"session","deferred":true}
            """)
        #expect(deferred.deferred == true)
        // Display toggles answer a bool value.
        #expect(try decode(ConfigSetResult.self, #"{"key":"density","value":true}"#).value == .bool(true))
    }

    @Test func attachParamsEncodeTheWireNames() throws {
        let params = ImageAttachBytesParams(sessionID: "sid", contentBase64: "AAAA", filename: "a.png")
        #expect(try JSONValue(encoding: params) == ["session_id": "sid", "content_base64": "AAAA", "filename": "a.png"])
        let set = ConfigSetParams(key: "reasoning", value: "high", sessionID: "sid")
        #expect(try JSONValue(encoding: set) == ["key": "reasoning", "value": "high", "session_id": "sid"])
    }
}
