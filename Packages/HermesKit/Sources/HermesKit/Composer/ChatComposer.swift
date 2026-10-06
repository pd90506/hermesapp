import Foundation
import HermesProtocol
import Observation

/// State behind one chat's composer: the draft, the attached images, and the
/// session's model and reasoning-effort pickers. The view owns one per chat.
@MainActor
@Observable
public final class ChatComposer {
    public let session: ChatSession
    public var draft = ""
    public private(set) var attachments: [ComposerAttachment] = []
    /// Images are uploading or the prompt is being submitted.
    public private(set) var isSubmitting = false
    /// A composer failure (attachment, model or effort change), shown in the
    /// composer. A failed `prompt.submit` shows in the transcript instead.
    public var error: String?
    public private(set) var catalog: ModelCatalog?
    /// A model switch the gateway refused until the user confirms it
    /// (`confirm_required`, e.g. an expensive model).
    public private(set) var pendingModelSwitch: PendingModelSwitch?
    /// The effort `config.get` reported, for a session whose `session.info`
    /// does not carry one yet.
    private var fetchedEffort: String?

    public struct PendingModelSwitch: Sendable, Hashable {
        public var choice: ModelChoice
        public var message: String
    }

    public init(session: ChatSession) {
        self.session = session
    }

    // MARK: Sending

    /// Whether Return / Send would submit something now. Also while a turn
    /// runs. Hermes then queues a submit with images as its own turn
    /// (`tui_gateway/session_auto_continue.py:414-448`). Text alone follows the
    /// profile's `display.busy_input_mode`: by default (`interrupt`) it redirects
    /// or stops the running reply, otherwise it is queued or steered
    /// (`tui_gateway/server.py:375-377`; docs/protocol.md §10.3).
    public var canSubmit: Bool {
        guard !isSubmitting else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Sends the draft with the attached images. The draft clears at once.
    /// When the send fails with images, the cards stay and the draft comes back
    /// with them, so a retry sends the same message.
    public func submit() async {
        guard canSubmit else { return }
        let text = draft
        let images = attachments
        draft = ""
        error = nil
        isSubmitting = true
        defer {
            isSubmitting = false
            submitTask = nil
        }
        let session = session
        let sending = Task { try await session.send(text, images: images) }
        submitTask = sending
        do {
            try await sending.value
            let sent = Set(images.map(\.id))
            attachments.removeAll { sent.contains($0.id) }
        } catch is CancellationError {
            // Cancelled before the prompt went out: nothing to report, all kept.
            restoreDraft(text)
        } catch {
            let failure = error as? ComposerError
            // A `ComposerError` means nothing reached the transcript; with images
            // the cards stay, so the text belongs with them. (A failed text-only
            // `prompt.submit` is already on the transcript, via `submitFailed`.)
            if failure != nil || !images.isEmpty { restoreDraft(text) }
            if let failure { self.error = failure.message }
        }
    }

    /// The send in flight, for `cancelSubmit()`.
    @ObservationIgnored private var submitTask: Task<Void, any Error>?

    /// Stops a send that is still waiting (on stranded-image cleanup or on
    /// uploads); the draft and cards come back. A prompt already submitted is
    /// not affected.
    public func cancelSubmit() {
        submitTask?.cancel()
    }

    /// Puts a failed send's text back, keeping whatever the user typed meanwhile.
    private func restoreDraft(_ text: String) {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            draft = text
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text + "\n" + draft
        }
    }

    // MARK: Attachments

    /// Adds an image the app has already converted to a format Hermes takes.
    /// Returns false, with `error` set, when it cannot be attached.
    @discardableResult
    public func attach(_ attachment: ComposerAttachment) -> Bool {
        if let rejection = ImageAttachmentPolicy.rejection(for: attachment) {
            error = rejection
            return false
        }
        guard attachments.count < ImageAttachmentPolicy.maxAttachments else {
            error = "At most \(ImageAttachmentPolicy.maxAttachments) images per message."
            return false
        }
        attachments.append(attachment)
        error = nil
        return true
    }

    /// Removes a card. Nothing is on the gateway yet, so there is nothing to
    /// detach: uploads only happen in `submit()`. Ignored while a send is in
    /// flight: that send already carries the card.
    public func removeAttachment(id: UUID) {
        guard !isSubmitting else { return }
        attachments.removeAll { $0.id == id }
    }

    // MARK: Model and reasoning effort

    /// The session's model: `session.info` first, then the catalog's answer.
    public var currentModel: String? {
        nonEmpty(session.info?.model) ?? catalog?.model
    }

    public var currentProvider: String? {
        nonEmpty(session.info?.provider) ?? catalog?.provider
    }

    public var currentModelLabel: String? {
        currentModel.map(ModelLabel.displayName)
    }

    public func isCurrent(_ choice: ModelChoice) -> Bool {
        guard choice.model == currentModel else { return false }
        guard let provider = currentProvider else { return true }
        return choice.provider.caseInsensitiveCompare(provider) == .orderedSame
    }

    /// Effort levels for the current model; empty (picker hidden) until the
    /// catalog loads, or when the model has no reasoning control.
    public var effortChoices: [String] {
        guard let catalog, let model = currentModel else { return [] }
        return ReasoningEffort.choices(for: catalog.capabilities(model: model, provider: currentProvider))
    }

    /// The session's effort; Hermes' default when nothing is reported.
    public var currentEffort: String {
        ReasoningEffort.normalized(session.info?.reasoningEffort) ?? fetchedEffort ?? ReasoningEffort.defaultLevel
    }

    /// Loads the model catalog and, when `session.info` lacks it, the effort.
    public func loadOptions() async {
        do {
            catalog = ModelCatalog(try await session.modelOptions())
            if ReasoningEffort.normalized(session.info?.reasoningEffort) == nil {
                fetchedEffort = ReasoningEffort.normalized(try await session.fetchReasoningEffort())
            }
        } catch is CancellationError {
        } catch {
            self.error = "Couldn't load models: \(GatewayConnection.describe(error))"
        }
    }

    /// Switches this session's model. A `confirm_required` answer becomes
    /// `pendingModelSwitch` for the view to ask about.
    public func selectModel(_ choice: ModelChoice) async {
        guard !isCurrent(choice) else { return }
        await switchModel(choice, confirmed: false)
    }

    public func confirmPendingModelSwitch() async {
        guard let pending = pendingModelSwitch else { return }
        pendingModelSwitch = nil
        await switchModel(pending.choice, confirmed: true)
    }

    public func cancelPendingModelSwitch() {
        pendingModelSwitch = nil
    }

    /// Bumped per pick; an answer for an older pick changes nothing on screen.
    private var modelPick = 0

    private func switchModel(_ choice: ModelChoice, confirmed: Bool) async {
        error = nil
        modelPick += 1
        let pick = modelPick
        do {
            let result = try await session.setModel(choice, confirmExpensiveModel: confirmed)
            guard pick == modelPick else { return }
            if result.confirmRequired == true {
                if confirmed {
                    // Asked twice; Desktop treats that as a failure rather than loop
                    // (`apps/desktop/src/lib/guarded-model-switch.ts:44-50`).
                    error = "Hermes did not switch to \(ModelLabel.displayName(choice.model))."
                } else {
                    let message = nonEmpty(result.confirmMessage) ?? nonEmpty(result.warning)
                        ?? "Switch this chat to \(ModelLabel.displayName(choice.model))?"
                    pendingModelSwitch = PendingModelSwitch(choice: choice, message: message)
                }
                return
            }
            // The effort a new model starts with may differ; re-read it.
            // A deferred switch (mid-turn) runs from the next turn start; until then
            // the gateway reports the old model's effort, which is still the live one.
            fetchedEffort = ReasoningEffort.normalized(try? await session.fetchReasoningEffort())
        } catch {
            guard pick == modelPick else { return }
            self.error = "Couldn't switch the model: \(GatewayConnection.describe(error))"
        }
    }

    public func selectEffort(_ effort: String) async {
        guard effort != currentEffort else { return }
        error = nil
        do {
            try await session.setReasoningEffort(effort)
        } catch let failure as ComposerError {
            self.error = failure.message
        } catch {
            self.error = "Couldn't change the reasoning effort: \(GatewayConnection.describe(error))"
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
