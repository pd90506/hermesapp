import Foundation
import HermesKit
import UniformTypeIdentifiers

/// Reads a file to attach with `file.attach` (`ChatComposer.attachFile`): checks its
/// size before reading it (`FileAttachmentPolicy`), and reads off the main actor.
enum FileLoader {
    struct Loaded: Sendable {
        var data: Data
        var filename: String
        var mimeType: String?
    }

    enum Failure: LocalizedError {
        case unreadable(String, String)
        case folder(String)
        case rejected(String, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name, let reason): "Couldn't read \(name): \(reason)"
            case .folder(let name): "\(name) is a folder. Attach the files in it instead."
            case .rejected(let name, let reason): "Couldn't attach \(name): \(reason)."
            }
        }
    }

    @concurrent
    nonisolated static func load(_ source: AttachmentSource) async throws -> Loaded {
        let filename = source.filename
        let mimeType = UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType
        switch source {
        case .data(let data, _):
            if let reason = FileAttachmentPolicy.rejection(byteCount: data.count) { throw Failure.rejected(filename, reason) }
            return Loaded(data: data, filename: filename, mimeType: mimeType)
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { throw Failure.folder(filename) }
            if let size = values?.fileSize, let reason = FileAttachmentPolicy.rejection(byteCount: size) {
                throw Failure.rejected(filename, reason)
            }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if let reason = FileAttachmentPolicy.rejection(byteCount: data.count) { throw Failure.rejected(filename, reason) }
                return Loaded(data: data, filename: filename, mimeType: mimeType)
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.unreadable(filename, error.localizedDescription)
            }
        }
    }
}
