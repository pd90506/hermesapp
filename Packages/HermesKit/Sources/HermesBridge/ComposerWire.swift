import Foundation
import HermesKit
import HermesProtocol

/// The open chat's composer (`ChatComposer`): its model and reasoning-effort pickers and
/// its attachment cards, as the `composer` event (docs/desktop-bridge.md, "Composer").
struct ComposerSnapshot: Encodable, Sendable, Equatable {
    struct Provider: Encodable, Sendable, Equatable {
        struct Model: Encodable, Sendable, Equatable {
            var model: String
            var label: String
            var isCurrent: Bool
        }

        var slug: String
        var name: String
        var models: [Model]
    }

    struct Choice: Encodable, Sendable, Equatable {
        var value: String
        var label: String
    }

    struct PendingSwitch: Encodable, Sendable, Equatable {
        var provider: String
        var model: String
        var label: String
        var message: String
    }

    struct Attachment: Encodable, Sendable, Equatable {
        var id: String
        /// `image` (sent with `image.attach_bytes`) or `file` (staged with `file.attach`).
        var kind: String
        var name: String
        var detail: String
        var isUploading: Bool
        /// Why the image's upload failed; the send uploads it again.
        var failure: String?
    }

    var sessionID: String
    var model: String?
    var provider: String?
    var modelLabel: String?
    /// Nil until `model.options` answers; empty when the gateway offers no models.
    var providers: [Provider]?
    /// The effort levels for the current model, in menu order; empty hides the picker.
    var efforts: [Choice]
    var effort: String
    var effortLabel: String
    var pendingModelSwitch: PendingSwitch?
    var error: String?
    var attachments: [Attachment]
    /// Files `attachFile` is still uploading, by name.
    var uploadingFiles: [String]
    var isSubmitting: Bool
    var canSubmit: Bool

    @MainActor init(_ composer: ChatComposer) {
        sessionID = composer.session.sessionID
        model = composer.currentModel
        provider = composer.currentProvider
        modelLabel = composer.currentModelLabel
        providers = composer.catalog.map { catalog in
            catalog.providers.map { provider in
                Provider(slug: provider.slug, name: provider.name, models: provider.models.map { model in
                    Provider.Model(model: model, label: ModelLabel.displayName(model),
                          isCurrent: composer.isCurrent(ModelChoice(provider: provider.slug, model: model)))
                })
            }
        }
        efforts = composer.effortChoices.map { Choice(value: $0, label: ReasoningEffort.label($0)) }
        effort = composer.currentEffort
        effortLabel = ReasoningEffort.label(composer.currentEffort)
        pendingModelSwitch = composer.pendingModelSwitch.map {
            PendingSwitch(provider: $0.choice.provider, model: $0.choice.model,
                          label: ModelLabel.displayName($0.choice.model), message: $0.message)
        }
        error = composer.error
        attachments = composer.attachments.map { image in
            Attachment(id: image.id.uuidString, kind: "image", name: image.filename, detail: image.detail,
                       isUploading: composer.uploadingImageIDs.contains(image.id),
                       failure: composer.failedImageUploads[image.id])
        } + composer.files.map { file in
            Attachment(id: file.id.uuidString, kind: "file", name: file.name, detail: file.detail,
                       isUploading: false, failure: nil)
        }
        uploadingFiles = composer.uploadingFileNames
        isSubmitting = composer.isSubmitting
        canSubmit = composer.canSubmit
    }
}

/// Reading a picked, dropped or pasted file for `attachFile`, as the Mac's `FileLoader`:
/// a folder or a file over `FileAttachmentPolicy`'s limit is refused before it is read.
enum AttachmentFile {
    static func load(path: String) throws -> (data: Data, filename: String) {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            throw BridgeError("\(filename) is a folder. Attach the files in it instead.")
        }
        if let size = values?.fileSize, let reason = FileAttachmentPolicy.rejection(byteCount: size) {
            throw BridgeError("Couldn't attach \(filename): \(reason).")
        }
        do {
            return (try Data(contentsOf: url, options: .mappedIfSafe), filename)
        } catch {
            throw BridgeError("Couldn't read \(filename): \(error.localizedDescription)")
        }
    }
}

extension ClipboardPolicy.Decision {
    /// `{"decision": "text"}`, `{"decision": "files", "files": [paths]}`,
    /// `{"decision": "imageData", "type": uti}`, or `{"decision": "fileItems"}`.
    var json: JSONValue {
        switch self {
        case .text: .object(["decision": .string("text")])
        case .files(let urls): .object(["decision": .string("files"), "files": .array(urls.map { .string($0.path) })])
        case .imageData(let type): .object(["decision": .string("imageData"), "type": .string(type)])
        case .fileItems: .object(["decision": .string("fileItems")])
        }
    }
}
