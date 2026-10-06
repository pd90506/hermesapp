import Foundation
import HermesProtocol

/// Typed wrappers for the composer's calls (`docs/protocol.md` §10).
extension GatewayClient {
    /// The models Hermes offers, layered over the session's live provider.
    public func modelOptions(sessionID: String?, profile: String?) async throws -> ModelOptionsResult {
        try await call(GatewayMethod.modelOptions, params: ModelOptionsParams(sessionID: sessionID, profile: profile))
    }

    /// The session's reasoning effort (`none` = thinking off), or the profile
    /// default while the session has no pin of its own.
    public func reasoningEffort(sessionID: String, profile: String?) async throws -> String? {
        try await call(GatewayMethod.configGet,
                       params: ConfigGetParams(key: "reasoning", sessionID: sessionID, profile: profile),
                       as: ConfigGetResult.self).value
    }

    /// Switches this session's model only. `--session` opts out of every
    /// persistence rule (`hermes_cli/model_switch.py:510-540`), the way Desktop
    /// switches a secondary tile (`use-model-controls.ts:335-344`).
    public func setSessionModel(sessionID: String, profile: String?, model: String, provider: String,
                                confirmExpensiveModel: Bool = false) async throws -> ConfigSetResult {
        try await call(GatewayMethod.configSet,
                       params: ConfigSetParams(key: "model",
                                               value: ModelSwitch.sessionValue(model: model, provider: provider),
                                               sessionID: sessionID, profile: profile,
                                               confirmExpensiveModel: confirmExpensiveModel ? true : nil))
    }

    /// Sets this session's reasoning effort. With a live `session_id` and no
    /// `scope`, the gateway pins it on the session only (`methods_config_set.py:321-331`).
    public func setSessionReasoningEffort(sessionID: String, profile: String?, effort: String) async throws
        -> ConfigSetResult
    {
        try await call(GatewayMethod.configSet,
                       params: ConfigSetParams(key: "reasoning", value: effort, sessionID: sessionID, profile: profile))
    }

    /// Uploads an image and queues it for the session's next turn.
    public func attachImage(sessionID: String, profile: String?, data: Data, filename: String) async throws
        -> AttachedImageResult
    {
        try await call(GatewayMethod.imageAttachBytes,
                       params: ImageAttachBytesParams(sessionID: sessionID, profile: profile,
                                                      contentBase64: data.base64EncodedString(), filename: filename),
                       timeout: Self.imageUploadTimeout)
    }

    /// Drops a queued image (by the path `attachImage` returned).
    @discardableResult
    public func detachImage(sessionID: String, profile: String?, path: String) async throws -> ImageDetachResult {
        try await call(GatewayMethod.imageDetach, params: ImageDetachParams(sessionID: sessionID, profile: profile, path: path))
    }

    /// Uploads a non-image file (a PDF, a text file, anything) into the session's
    /// attachments folder; the result's `refText` goes into the prompt.
    public func attachFile(sessionID: String, data: Data, name: String, mimeType: String?) async throws
        -> FileAttachResult
    {
        let dataURL = "data:\(mimeType ?? "application/octet-stream");base64,\(data.base64EncodedString())"
        return try await call(GatewayMethod.fileAttach,
                              params: FileAttachParams(sessionID: sessionID, name: name, dataURL: dataURL),
                              timeout: Self.imageUploadTimeout)
    }

    /// Up to 25 MB of base64 over the socket (`prompt_attachments.py:16`); files
    /// (`file.attach`) get the same time.
    public static let imageUploadTimeout: Duration = .seconds(300)
}

/// The `config.set model` value grammar (`hermes_cli/model_switch.py:477-500,592-620`).
public enum ModelSwitch {
    /// `<model> --provider <slug> --session`: this session only, whatever
    /// `model.persist_switch_by_default` says.
    public static func sessionValue(model: String, provider: String) -> String {
        let provider = provider.trimmingCharacters(in: .whitespaces)
        var value = model.trimmingCharacters(in: .whitespaces)
        if !provider.isEmpty { value += " --provider \(provider)" }
        return value + " --session"
    }
}
