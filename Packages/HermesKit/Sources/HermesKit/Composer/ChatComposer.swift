import Foundation
import HermesProtocol
import Observation

/// The keys the composer's slash list takes: arrows, Tab, plain Return, Esc.
public enum SlashListKey: Sendable, Hashable {
    case up, down, tab, accept, escape
}

/// State behind one chat's composer: the draft, the attached images and files,
/// and the session's model and reasoning-effort pickers. The view owns one per chat.
@MainActor
@Observable
public final class ChatComposer {
    public let session: ChatSession
    public var draft = ""
    public private(set) var attachments: [ComposerAttachment] = []
    /// Files already staged on the gateway (`attachFile`); sent as `@file:`
    /// references in front of the text.
    public private(set) var files: [ComposerFile] = []
    /// Names of the files `attachFile` is uploading, in the order they started;
    /// the composer shows a pending card for each.
    public private(set) var uploadingFileNames: [String] = []
    /// How many files `attachFile` is uploading.
    public var uploadingFiles: Int { uploadingFileNames.count }
    /// Images are uploading or the prompt is being submitted.
    public private(set) var isSubmitting = false
    /// A composer failure (attachment, model or effort change), shown in the
    /// composer. A failed `prompt.submit` shows in the transcript instead.
    public var error: String?
    /// `error`, when a lost connection caused it (a model or effort request, or a
    /// send made offline): a reconnect clears it, since the reason is gone.
    private var linkError: String?
    /// `error`, when it is `loadOptions()`'s failure: a later load that works clears it.
    private var optionsError: String?
    public private(set) var slashSuggestions: [SlashSuggestion] = []
    public private(set) var slashSelection = 0
    public private(set) var slashIsOpen = false
    /// `/model` without a model: the view opens its model picker (Desktop's
    /// picker overlay, `use-prompt-actions/slash.ts:1284-1295`).
    public var isModelPickerRequested = false
    private var slashCatalog: SlashCatalog?
    private var slashRequest = 0
    private var slashLoadRequest = 0
    /// The draft the user arrowed through the list at: only for that text is the
    /// highlight their pick (Desktop's `triggerActiveExplicit`, reset per query).
    private var slashExplicitText: String?
    private var suppressedSlashText: String?
    /// `complete.slash` answers by lower-cased text, for this catalog (Desktop
    /// caches per query, `use-slash-completions.ts:218`).
    private var slashCompletionCache: [String: SlashCompletions] = [:]
    /// The text whose `complete.slash` failed: no answer is coming for it.
    private var slashFailedText: String?
    /// Shown where the list would be when a command name matches nothing (Desktop's
    /// "No matches." with "Try /help", `trigger-popover.tsx:164-185`), or when the
    /// lookup or the catalog failed. Never with rows; cleared whenever the list closes.
    public private(set) var slashNotice: String?
    /// Why the last `commands.catalog` failed, for `slashNotice`.
    private var slashCatalogFailure: String?
    /// A `/compress` (or a Bot Chat `/new`) is running, for the composer's status
    /// row: Desktop shows a notice only for a compaction (`slash.ts:703-709`). Slash
    /// commands never block the composer; Desktop sends one without waiting for it
    /// (`use-composer-submit.ts:133-144`), busy or not (:291-315).
    public private(set) var isCompressing = false
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

    // MARK: Slash commands

    /// Loads the slash catalog and the model options side by side, on opening a
    /// chat and after a reconnect: a slow catalog (a skills scan) must not hold up
    /// the model and effort pickers.
    public func loadCommandsAndOptions() async {
        if let linkError, error == linkError { error = nil }
        linkError = nil
        async let commands: Void = loadSlashCommands()
        async let options: Void = loadOptions()
        _ = await (commands, options)
    }

    /// Reload on chat/profile changes and after a reconnect. A failed catalog
    /// disables discovery; submission still reports the failure in the transcript.
    public func loadSlashCommands() async {
        slashRequest += 1
        slashLoadRequest += 1
        let request = slashLoadRequest
        slashCatalog = nil
        slashCompletionCache = [:]
        slashFailedText = nil
        slashCatalogFailure = nil
        closeSlashList()
        do {
            let catalog = try await session.loadSlashCommands()
            guard request == slashLoadRequest else { return }
            slashCatalog = catalog
            await updateSlashSuggestions()
        } catch is CancellationError {
        } catch {
            // Keep the draft intact. Typing `/` shows why; a send gives a local note.
            guard request == slashLoadRequest else { return }
            slashCatalogFailure = GatewayConnection.describe(error)
            await updateSlashSuggestions()
        }
    }

    /// Recomputes the list for the draft. Until a `complete.slash` answer lands,
    /// the list shown is for the older text (as on Desktop); the keys allow for that.
    public func updateSlashSuggestions() async {
        slashRequest += 1
        let request = slashRequest
        let text = draft
        guard let slashCatalog, SlashCommand.isCompletionCandidate(text), text != suppressedSlashText,
            slashCatalog.listsArguments(text)
        else {
            closeSlashList()
            // Only where Desktop shows its empty state: on a command name, not in argument text.
            if self.slashCatalog == nil, let slashCatalogFailure, SlashCommand.isCompletionCandidate(text),
                text != suppressedSlashText, !text.contains(where: \.isWhitespace)
            {
                slashNotice = "Couldn't load commands: \(slashCatalogFailure)"
            }
            return
        }
        var completions: SlashCompletions?
        let load = slashLoadRequest
        if text != "/" {
            if let cached = slashCompletionCache[text.lowercased()] {
                completions = cached
                completions?.text = text
            } else {
                do {
                    let result = try await session.completeSlash(text)
                    // An answer to a request made before a catalog reload stays out of the new cache.
                    if load == slashLoadRequest { slashCompletionCache[text.lowercased()] = result }
                    completions = result
                } catch is CancellationError {
                    // The view cancels this on the next keystroke, and the next update
                    // follows; the rows shown stay up meanwhile, as on Desktop.
                    return
                } catch {
                    if load == slashLoadRequest { slashFailedText = text }
                    guard request == slashRequest else { return }
                    closeSlashList()
                    // Desktop shows an empty list for a failed lookup; the reason shows here.
                    if draft == text { slashNotice = "Couldn't look up commands: \(GatewayConnection.describe(error))" }
                    return
                }
            }
        }
        guard request == slashRequest, draft == text else { return }
        // A row the user arrowed to for this text keeps the highlight when the answer
        // lands (Desktop keeps the pick, `use-composer-trigger.ts:254-256`). If the row
        // is gone, nothing counts as picked.
        let picked = slashExplicitText == text && slashSuggestions.indices.contains(slashSelection)
            ? slashSuggestions[slashSelection].text : nil
        slashSuggestions = slashCatalog.suggestions(for: text, completions: completions)
        if let picked, let index = slashSuggestions.firstIndex(where: { $0.text == picked }) {
            slashSelection = index
        } else {
            slashSelection = 0
            slashExplicitText = nil
        }
        slashIsOpen = !slashSuggestions.isEmpty
        // Nothing matches a command name: Desktop's empty state. Past the name (an
        // argument), an empty list just stays closed (`use-composer-trigger.ts:231-234`).
        slashNotice = slashSuggestions.isEmpty && !text.contains(where: \.isWhitespace) ? "No matches. Try /help." : nil
    }

    /// Whether `updateSlashSuggestions()` would ask the gateway for this draft,
    /// rather than answer from the catalog or the cache. The view debounces only these.
    public var slashUpdateNeedsRequest: Bool {
        guard let slashCatalog, SlashCommand.isCompletionCandidate(draft), draft != "/",
            draft != suppressedSlashText, slashCatalog.listsArguments(draft)
        else { return false }
        return slashCompletionCache[draft.lowercased()] == nil
    }

    /// Tab with no rows while the answer for this draft is still coming. The view
    /// swallows it, as Desktop does (`index.tsx:800-809`), so it neither types a tab
    /// nor moves focus.
    public var swallowsSlashTab: Bool {
        !slashIsOpen && slashUpdateNeedsRequest && draft != slashFailedText
    }

    public func dismissSlashSuggestions() {
        suppressedSlashText = draft
        closeSlashList()
    }

    public func moveSlashSelection(_ offset: Int) {
        guard slashIsOpen, !slashSuggestions.isEmpty else { return }
        slashSelection = (slashSelection + offset + slashSuggestions.count) % slashSuggestions.count
        slashExplicitText = draft
    }

    /// A key the text view offers the slash list (`ComposerTextView.SlashKey`): only
    /// when no input method has marked text, which keeps every key.
    /// Returns whether the key was used; false leaves it to the text view, so
    /// Return sends and Esc and Tab do what they would.
    /// - With rows: arrows move, Tab and Return accept (`acceptSlashSuggestionFromKey`),
    ///   Esc closes (Desktop, `index.tsx:800-890`).
    /// - With no rows: Tab is swallowed while a lookup is due (`swallowsSlashTab`), and
    ///   Esc dismisses a showing notice. Desktop leaves its empty popover up on Esc; on
    ///   macOS, Esc dismisses transient UI. Any other key, or Esc with nothing shown,
    ///   is not used.
    public func handleSlashKey(_ key: SlashListKey) -> Bool {
        if key == .tab, swallowsSlashTab { return true }
        guard slashIsOpen else {
            guard key == .escape, slashNotice != nil else { return false }
            dismissSlashSuggestions()
            return true
        }
        switch key {
        case .up: moveSlashSelection(-1)
        case .down: moveSlashSelection(1)
        case .tab, .accept: return acceptSlashSuggestionFromKey(isTab: key == .tab)
        case .escape: dismissSlashSuggestions()
        }
        return true
    }

    /// Return or Tab while the list shows, after Desktop (`index.tsx:829-869`,
    /// `composer-utils.ts:128-205`). Tab takes the highlight. Return takes the row
    /// `SlashSuggestion.implicitAcceptIndex` picks, and in a free-text argument
    /// (`/goal s`) only a row the user arrowed to. Returns false when Return should
    /// send the draft as typed instead.
    public func acceptSlashSuggestionFromKey(isTab: Bool) -> Bool {
        // A draft that is no longer a slash candidate (the slash was deleted, a
        // newline typed) sends as typed, even before the view closes the list.
        guard slashIsOpen, !slashSuggestions.isEmpty, SlashCommand.isCompletionCandidate(draft) else { return false }
        let explicit = slashExplicitText == draft
        if isTab {
            acceptSlashSuggestion(at: slashSelection)
            return true
        }
        if slashCatalog?.isFreeTextArgument(draft) == true, !explicit { return false }
        guard let index = SlashSuggestion.implicitAcceptIndex(typed: draft, texts: slashSuggestions.map(\.text),
                                                              active: slashSelection, explicit: explicit)
        else { return false }
        acceptSlashSuggestion(at: index)
        return true
    }

    /// The list as the view draws it: one snapshot of the rows, their headers and
    /// the highlight, read together (`SlashRow`).
    public var slashRows: [SlashRow] {
        SlashRow.rows(slashSuggestions, selection: slashSelection)
    }

    /// A click on a drawn row: accepts that row where it is in the list now. A row
    /// that is gone (the list changed under the pointer) is ignored.
    public func acceptSlashRow(id: SlashRow.ID) {
        guard let index = slashRows.firstIndex(where: { $0.id == id }) else { return }
        acceptSlashSuggestion(at: index)
    }

    /// Puts the row into the draft. A command gets Desktop's trailing space
    /// (`use-composer-trigger.ts:375`): an `options` or `mixed` command then lists
    /// its arguments, any other leaves the list closed. An argument row is the whole
    /// `/command argument`; the list stays closed until the next edit.
    public func acceptSlashSuggestion(at index: Int? = nil) {
        let index = index ?? slashSelection
        guard slashIsOpen, slashSuggestions.indices.contains(index) else { return }
        let text = slashSuggestions[index].text
        if text.contains(where: \.isWhitespace) {
            draft = text
            suppressedSlashText = text
        } else {
            draft = text + " "
        }
        closeSlashList()
    }

    private func closeSlashList() {
        slashSuggestions = []
        slashSelection = 0
        slashIsOpen = false
        slashNotice = nil
    }

    /// Runs the draft as a slash command; the outcome shows in the transcript.
    /// Client actions (`/new`, `/model`, …) run here too (`runClientAction`). The
    /// draft clears at once, like `submit()`, and what is typed meanwhile stays.
    /// A slow command (`/compress`, a skill) does not hold up the composer: as on
    /// Desktop, the next message or command (`/stop`) goes out while it runs.
    /// A compaction shows in `isCompressing`, and a second one while it runs is
    /// dropped (Desktop: `use-prompt-actions/slash.ts:696-709`).
    /// No catalog is needed up front: `runSlash` runs its own commands without one
    /// and loads one for the rest (a failed load throws, and nothing is sent).
    public func submitSlash() async -> SlashOutcome? {
        guard canSubmit, SlashCommand.isCommand(draft) else { return nil }
        let text = draft
        closeSlashList()
        suppressedSlashText = nil
        if !attachments.isEmpty || !files.isEmpty {
            session.appendLocalNote("Send attachments separately from slash commands.")
            return .unavailable("Send attachments separately from slash commands.")
        }
        draft = ""
        let compresses = compacts(SlashCommand.parse(text).name)
        if compresses {
            if isCompressing { return .handled }
            isCompressing = true
        }
        defer { if compresses { isCompressing = false } }
        do {
            let outcome = try await session.runSlash(text)
            switch outcome {
            case .unavailable(let reason): session.appendLocalNote(reason)
            case .prefill(let value): restoreText(value)
            case .clientAction(let name, let argument): await runClientAction(name, argument: argument)
            case .output, .submitted, .handled: break
            }
            return outcome
        } catch {
            // The command comes back only into an empty draft. In front of what was
            // typed since, the next Return would run it with that prose as its
            // argument; the note names the command and the error.
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
            session.appendLocalNote("/\(SlashCommand.parse(text).name): \(GatewayConnection.describe(error))")
            return .unavailable(GatewayConnection.describe(error))
        }
    }

    /// Whether `/name` runs a compaction: `/compress` or an alias, and in a Bot
    /// Chat `/new`, `/reset` and `/clear`, which `runSlash` compacts instead
    /// (Desktop rewrites them to `/compact`, `plugins/hermes-bots/plugin.tsx:771-797`).
    private func compacts(_ name: String) -> Bool {
        let canonical = session.slashCatalog.map { String($0.canonicalName(name).dropFirst()) } ?? name
        let names: Set<String> = session.kind == .botChat
            ? ["compress", "compact", "new", "reset", "clear"] : ["compress", "compact"]
        return names.contains(name) || names.contains(canonical)
    }

    /// Desktop's client-side actions (`use-prompt-actions/slash.ts:518-1135`) that
    /// this app has a feature for; the rest get a local note. Nothing is sent as a prompt.
    func runClientAction(_ name: String, argument: String) async {
        do {
            switch name {
            case "new", "reset", "clear":
                // A Bot Chat never gets here: `runSlash` compacts it instead.
                guard let connection = session.connection else { throw GatewayClientError.notConnected }
                if session.kind == .sideChat, let profile = session.profile {
                    try await connection.newSideChat(profile: profile)
                } else {
                    try await connection.newSession()
                }
            case "help", "commands":
                // The catalog may still be loading (or have failed): load it here.
                let commands: SlashCatalog
                if let loaded = session.slashCatalog { commands = loaded } else {
                    commands = try await session.loadSlashCommands()
                }
                session.appendLocalNote(commands.helpText)
            case "model":
                if argument.isEmpty {
                    isModelPickerRequested = true
                } else if let provider = catalog?.providers.first(where: { $0.models.contains(argument) }) {
                    await selectModel(ModelChoice(provider: provider.slug, model: argument))
                } else {
                    session.appendLocalNote("Model \(argument) is not available in this chat.")
                }
            case "profile":
                session.appendLocalNote("/profile is not available in this app yet. Choose a bot in the sidebar; "
                    + "new chats cannot change profile here.")
            case "reasoning":
                if argument.isEmpty {
                    session.appendLocalNote("Reasoning effort: \(ReasoningEffort.label(currentEffort))")
                } else if effortChoices.contains(argument) {
                    await selectEffort(argument)
                } else {
                    session.appendLocalNote("Reasoning option \(argument) is not available in this chat.")
                }
            case "resume", "sessions", "switch":
                if let connection = session.connection,
                    let entry = connection.history.first(where: { $0.summary.id == argument })
                {
                    try await connection.open(entry)
                } else {
                    session.appendLocalNote("Choose a chat from History. "
                        + "This app cannot search sessions by slash command yet.")
                }
            default:
                session.appendLocalNote("/\(name) is not available in this app yet.")
            }
        } catch {
            session.appendLocalNote("/\(name): \(GatewayConnection.describe(error))")
        }
    }

    // MARK: Sending

    /// Whether Return / Send would submit something now. Also while a turn
    /// runs. Hermes then queues a submit with images as its own turn
    /// (`tui_gateway/session_auto_continue.py:414-448`). Text alone follows the
    /// profile's `display.busy_input_mode`: by default (`interrupt`) it redirects
    /// or stops the running reply, otherwise it is queued or steered
    /// (`tui_gateway/server.py:375-377`; docs/protocol.md §10.3).
    public var canSubmit: Bool {
        guard !isSubmitting, uploadingFiles == 0 else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !files.isEmpty
    }

    /// Sends the draft with the attached images and files. The draft clears at once.
    /// When the send fails with images or files, the cards stay and the draft comes
    /// back with them, so a retry sends the same message.
    public func submit() async {
        guard canSubmit else { return }
        let text = draft
        let images = attachments
        let files = files
        draft = ""
        suppressedSlashText = nil
        error = nil
        isSubmitting = true
        defer {
            isSubmitting = false
            submitTask = nil
        }
        let session = session
        let sending = Task { try await session.send(text, images: images, files: files) }
        submitTask = sending
        do {
            try await sending.value
            let sent = Set(images.map(\.id))
            attachments.removeAll { sent.contains($0.id) }
            let sentFiles = Set(files.map(\.id))
            self.files.removeAll { sentFiles.contains($0.id) }
        } catch is CancellationError {
            // Cancelled before the prompt went out: nothing to report, all kept.
            restoreText(text)
        } catch {
            let failure = error as? ComposerError
            // A `ComposerError` means nothing reached the transcript; with images
            // or files the cards stay, so the text belongs with them. (A failed
            // text-only `prompt.submit` is already on the transcript, via `submitFailed`.)
            if failure != nil || !images.isEmpty || !files.isEmpty { restoreText(text) }
            if let failure { show(failure.message, cause: failure) }
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
    /// Also takes back a failed prompt's text when its bubble is gone (`ChatSession`):
    /// the earlier text first, then what is typed now; nothing is overwritten.
    func restoreText(_ text: String) {
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
        files.removeAll { $0.id == id }
    }

    /// Attaches a file picked or dropped by the user. An image Hermes takes as it
    /// is (`ImageAttachmentPolicy.canSendUnchanged`) becomes an image card, like
    /// `attach(_:)`; anything else (PDFs included, as in Desktop) is uploaded now
    /// with `file.attach` and becomes a file card. Returns false, with `error` set,
    /// when it cannot be attached. Images in other formats should be converted by
    /// the app first (`attach(_:)`); sent here they go as files.
    @discardableResult
    public func attachFile(_ data: Data, filename: String, mimeType: String? = nil) async -> Bool {
        if ImageAttachmentPolicy.canSendUnchanged(filename: filename) {
            return attach(ComposerAttachment(filename: filename, data: data))
        }
        error = nil
        uploadingFileNames.append(filename)
        defer {
            if let index = uploadingFileNames.firstIndex(of: filename) { uploadingFileNames.remove(at: index) }
        }
        do {
            files.append(try await session.attachFile(data, filename: filename, mimeType: mimeType))
            return true
        } catch is CancellationError {
            return false
        } catch let failure as ComposerError {
            error = failure.message
        } catch {
            self.error = "Couldn't attach \(filename): \(GatewayConnection.describe(error))"
        }
        return false
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
            if let optionsError, error == optionsError { error = nil }
            optionsError = nil
        } catch is CancellationError {
        } catch {
            let message = "Couldn't load models: \(GatewayConnection.describe(error))"
            show(message, cause: error)
            optionsError = message
        }
    }

    /// Shows `message` as the composer's error, remembering whether a reconnect
    /// should clear it.
    private func show(_ message: String, cause: any Error) {
        error = message
        linkError = GatewayConnection.isLinkFailure(cause) ? message : nil
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
            show("Couldn't switch the model: \(GatewayConnection.describe(error))", cause: error)
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
            show("Couldn't change the reasoning effort: \(GatewayConnection.describe(error))", cause: error)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
