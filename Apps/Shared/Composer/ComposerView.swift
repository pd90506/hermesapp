import HermesKit
import HermesProtocol
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The chat composer, after Hermes Desktop's: attachment cards, an auto-growing
/// text area, and a toolbar with `+`, the model and effort pickers, the mic and
/// Send/Stop. All state lives in `ChatComposer` (HermesKit); this view only
/// reads images and files and lays things out. Images go to the gateway with the
/// prompt (`image.attach_bytes`); any other file is uploaded as soon as it is
/// attached (`file.attach`), as in Desktop (docs/protocol.md §10.3, §10.5).
struct ComposerView: View {
    let composer: ChatComposer
    var isConnected: Bool

    @State private var inputHandle = ComposerInputHandle()
    @State private var textHeight: CGFloat = 0
    /// An input method's marked text shows in the field (`ComposerTextView.onComposingChange`).
    @State private var isComposing = false
    @State private var thumbnails: [UUID: CGImage] = [:]
    @Environment(ServerConnection.self) private var server
    @State private var focusRequest = 0
    @State private var isImportingFile = false
    @State private var isDropTargeted = false
    @State private var stopError: String?
    #if os(iOS)
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    /// The text view has the keyboard.
    @State private var isFocused = false
    #endif

    /// About eight lines of body text, then the text area scrolls.
    private let maxTextHeight: CGFloat = 170

    private var session: ChatSession { composer.session }

    var body: some View {
        @Bindable var composer = composer

        VStack(alignment: .leading, spacing: 0) {
            if let message = composer.error ?? stopError {
                errorRow(message)
            }
            if !composer.attachments.isEmpty || !composer.files.isEmpty || composer.uploadingFiles > 0 {
                cards
            }
            SlashSuggestionList(composer: composer) { focusRequest += 1 }
            if composer.isCompressing { compressingRow }
            // The text area keeps its place in both layouts, so the text view, and the
            // keyboard it has, stay when the card grows or shrinks.
            HStack(spacing: 8) {
                if isCollapsed { addMenu }
                textArea
                if isCollapsed { sendButton }
            }
            .padding(.horizontal, isCollapsed ? Self.inset.toolbar : Self.inset.text)
            .padding(.vertical, isCollapsed ? Self.inset.toolbar : 0)
            .padding(.top, isCollapsed ? 0 : Self.inset.top)
            if !isCollapsed { toolbar }
        }
        .animation(.snappy(duration: 0.25), value: isCollapsed)
        // A card floating over the chat, as the Claude app's, on the Mac and iOS alike:
        // the system's Liquid Glass (`floatingGlass`), the messages blurred
        // under it. A hairline in the text colour around it, as Desktop's composer border:
        // in light the glass's own rim all but vanishes on a white chat (the user,
        // 2026-10-26). The tint's edge while a drop is over it.
        .floatingGlass(in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .chatGlassID("composer")
        .overlay {
            // Just outside the glass's edge: on it, the glass's own bright rim all but
            // covered the line (VM, 2026-10-27: 20% of black came out as 3%).
            RoundedRectangle(cornerRadius: Self.cornerRadius + 1, style: .continuous)
                .strokeBorder(Color.primary.opacity(Self.borderOpacity), lineWidth: 1)
                .padding(-1)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .onDrop(of: [.fileURL, .image, .data], isTargeted: $isDropTargeted) { providers in
            #if os(macOS)
            // SwiftUI hands over a dragged file by its contents' type alone: a Markdown file
            // from Finder is one `net.daringfireball.markdown` provider, without its file URL
            // or name (VM, 2026-10-22), so text files were turned away with no sign. The
            // drag pasteboard has the file URLs: read it as the text view reads a paste.
            // Only when it holds this drag's files, though: a file from a Dock stack comes on
            // a pasteboard of the Dock's own (VM, 2026-10-29), and the drag pasteboard then
            // has nothing, or the files of an earlier drag from Finder. Then the providers'
            // contents are attached as files, text too: the file representation has the name.
            let dragged = ImageLoader.sources(from: NSPasteboard(name: .drag))
            if ImageLoader.sources(dragged, match: providers) {
                Task { await attach(dragged) }
                return true
            }
            let attachable = providers.filter { ImageLoader.isAttachable($0, fileDrop: true) }
            guard !attachable.isEmpty else { return false }
            Task { await attach(await ImageLoader.sources(from: attachable, fileDrop: true)) }
            #else
            let attachable = providers.filter { ImageLoader.isAttachable($0) }
            guard !attachable.isEmpty else { return false }
            Task { await attach(await ImageLoader.sources(from: attachable)) }
            #endif
            return true
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await attach(urls.map(AttachmentSource.file)) }
            case .failure(let error): composer.error = error.localizedDescription
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoSelection, matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { await attachPhotos(items) }
        }
        #endif
        .confirmationDialog(
            "Switch model?",
            isPresented: Binding(get: { composer.pendingModelSwitch != nil },
                                 set: { if !$0 { composer.cancelPendingModelSwitch() } }),
            presenting: composer.pendingModelSwitch
        ) { pending in
            Button("Switch to \(ModelLabel.displayName(pending.choice.model))") {
                Task { await composer.confirmPendingModelSwitch() }
            }
            Button("Keep Current Model", role: .cancel) { composer.cancelPendingModelSwitch() }
        } message: { pending in
            Text(pending.message)
        }
        .onChange(of: composer.attachments.map(\.id)) { _, ids in
            // Drop thumbnails of cards that were sent or removed.
            let live = Set(ids)
            thumbnails = thumbnails.filter { live.contains($0.key) }
        }
        .task(id: TaskKey(sessionID: session.sessionID, isConnected: isConnected)) {
            // Again after a reconnect: the runtime id (and maybe the backend) changed.
            // A Stop that failed offline is stale then: the turn's state comes from
            // the resumed session.
            guard isConnected else { return }
            stopError = nil
            await composer.loadCommandsAndOptions()
        }
        .task(id: composer.draft) {
            // Like Desktop, wait 60 ms before asking the gateway (`use-live-completion-adapter.ts:43`);
            // the next keystroke cancels this. A cached or catalog answer shows at once.
            if composer.slashUpdateNeedsRequest {
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { return }
            }
            await composer.updateSlashSuggestions()
        }
    }

    private struct TaskKey: Hashable {
        var sessionID: String
        var isConnected: Bool
    }

    /// On the Mac rounder than the system's fields, as Desktop's composer; on iOS a
    /// large card, as the Claude app's.
    private static var cornerRadius: CGFloat {
        #if os(macOS)
        12
        #else
        30
        #endif
    }

    /// The toolbar's round controls (`+`, Send, Stop) and the pills' height: on iOS
    /// full-size touch targets.
    static var controlSize: CGFloat {
        #if os(macOS)
        26
        #else
        36
        #endif
    }

    /// The space between the card's edge and its text, cards and controls.
    private static var inset: (text: CGFloat, top: CGFloat, cards: CGFloat, toolbar: CGFloat) {
        #if os(macOS)
        (text: 10, top: 8, cards: 8, toolbar: 6)
        #else
        (text: 16, top: 14, cards: 12, toolbar: 10)
        #endif
    }

    // MARK: Rows

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .uiFont(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button("Dismiss", systemImage: "xmark") {
                composer.error = nil
                stopError = nil
            }
            .labelStyle(.iconOnly)
            .hoverButtonStyle(.circle, padding: 3)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.inset.text)
        .padding(.top, Self.inset.top)
    }

    /// A `/compress` still running (it can take minutes). The composer stays usable
    /// meanwhile; Desktop shows the same notice, for a compaction only (`slash.ts:703-709`).
    private var compressingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Compressing context…")
                .uiFont(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.inset.text)
        .padding(.top, Self.inset.top)
        .accessibilityElement(children: .combine)
    }

    private var cards: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AttachmentCardView.spacing) {
                ForEach(composer.attachments) { attachment in
                    // The draft outlives this view (`GatewayConnection.composer(for:)`); its thumbnails
                    // are also in the shared store, for when the chat is shown again.
                    AttachmentCardView(attachment: attachment,
                                       thumbnail: thumbnails[attachment.id] ?? server.thumbnails.local(attachment.id),
                                       isSending: composer.isSubmitting,
                                       isUploading: composer.uploadingImageIDs.contains(attachment.id),
                                       uploadFailure: composer.failedImageUploads[attachment.id]) {
                        composer.removeAttachment(id: attachment.id)
                    }
                }
                ForEach(composer.files) { file in
                    AttachmentCardView(file: file, isSending: composer.isSubmitting) {
                        composer.removeAttachment(id: file.id)
                    }
                }
                ForEach(Array(composer.uploadingFileNames.enumerated()), id: \.offset) { _, name in
                    UploadingCardView(name: name)
                }
            }
            .padding(.horizontal, Self.inset.cards)
            .padding(.top, Self.inset.cards)
        }
        .scrollIndicators(.never)
    }

    private var textArea: some View {
        @Bindable var composer = composer
        return ComposerTextView(
            text: $composer.draft, contentHeight: $textHeight, maxHeight: maxTextHeight, focusRequest: focusRequest,
            onSubmit: submit,
            onAttach: { sources in Task { await attach(sources) } },
            onProviders: { providers in Task { await attach(await ImageLoader.sources(from: providers)) } },
            onComposingChange: { isComposing = $0 },
            onSlashKey: handleSlashKey,
            onFocusChange: { focused in
                #if os(iOS)
                isFocused = focused
                #endif
            },
            inputHandle: inputHandle
        )
        .frame(height: min(max(textHeight, 28), maxTextHeight))
        .overlay(alignment: .topLeading) {
            if ComposerTextView.showsPlaceholder(draft: composer.draft, composing: isComposing) {
                Text("Message Hermes")
                    .contentFont()
                    .foregroundStyle(.tertiary)
                    .padding(.top, ComposerTextView.verticalInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// On iOS, with the keyboard away and nothing in the draft, the card is one row, as
    /// the Claude app's: `+`, the field and Send. The model and effort pills come back
    /// with the keyboard (asked for by the user, 2026-10-19).
    private var isCollapsed: Bool {
        #if os(iOS)
        !isFocused && composer.draft.isEmpty && !isComposing && composer.attachments.isEmpty
            && composer.files.isEmpty && composer.uploadingFiles == 0 && composer.error == nil && stopError == nil
            && !composer.isCompressing && !composer.slashIsOpen && !composer.isModelPickerRequested
        #else
        false
        #endif
    }

    private func handleSlashKey(_ key: ComposerTextView.SlashKey) -> Bool {
        let hadRows = composer.slashIsOpen
        // False: not the list's key, so Return sends the draft as typed.
        guard composer.handleSlashKey(key) else { return false }
        if hadRows, key == .tab || key == .accept { focusRequest += 1 }
        return true
    }

    /// On the Mac `+` alone on the left, as Desktop's; on iOS `+` and the pills on the
    /// left, Send on the right, as the Claude app's.
    private var toolbar: some View {
        #if os(macOS)
        HStack(spacing: 2) {
            addMenu
            Spacer(minLength: 8)
            modelMenu
            effortMenu
            micButton
            sendButton
                .padding(.leading, 4)
                // Stop grows in where Send was as a reply starts, and back.
                .animation(Motion.swap, value: [session.transcript.isRunning, composer.isSubmitting,
                                                composer.canSubmit || composer.isSubmitting])
        }
        .padding(.horizontal, Self.inset.toolbar)
        .padding(.bottom, 6)
        .padding(.top, 2)
        #else
        HStack(spacing: 8) {
            addMenu
            modelMenu
            effortMenu
            Spacer(minLength: 0)
            sendButton
        }
        .padding(.horizontal, Self.inset.toolbar)
        .padding(.bottom, Self.inset.toolbar)
        .padding(.top, 6)
        #endif
    }

    // MARK: Toolbar controls

    private var addMenu: some View {
        Menu {
            #if os(iOS)
            // A button, the picker presented from the composer: a PhotosPicker in the
            // menu closed the menu and showed no picker (VM, iOS 27).
            Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
            #endif
            Button("Choose Files…", systemImage: "doc") { isImportingFile = true }
        } label: {
            #if os(macOS)
            Image(systemName: "plus")
                .uiFont(.body, weight: .medium)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(.rect)
            #else
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: Self.controlSize, height: Self.controlSize)
                .background(Self.controlFill, in: .circle)
                .contentShape(.circle)
            #endif
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(in: Circle())
        #if os(macOS)
        .foregroundStyle(.secondary)
        #else
        .foregroundStyle(.primary)
        #endif
        .help("Attach images or files")
        .accessibilityLabel("Attach")
    }

    private var modelMenu: some View {
        @Bindable var composer = composer
        return Menu {
            if let catalog = composer.catalog, !catalog.isEmpty {
                ForEach(catalog.providers, id: \.slug) { provider in
                    Section(provider.name) {
                        ForEach(provider.models, id: \.self) { model in
                            let choice = ModelChoice(provider: provider.slug, model: model)
                            Toggle(ModelLabel.displayName(model), isOn: Binding(
                                get: { composer.isCurrent(choice) },
                                set: { _ in Task { await composer.selectModel(choice) } }))
                        }
                    }
                }
            } else {
                Text(composer.catalog == nil ? "Loading models…" : "No models available")
            }
            Divider()
            Button("Reload Models", systemImage: "arrow.clockwise") {
                Task { await composer.loadOptions() }
            }
        } label: {
            pillLabel(composer.currentModelLabel ?? "Model")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #if os(macOS)
        .fixedSize()
        #endif
        .hoverHighlight()
        .disabled(!isConnected)
        .help(composer.currentModel.map { "Model for this chat: \($0)" } ?? "Model for this chat")
        .accessibilityLabel("Model")
        .accessibilityValue(composer.currentModelLabel ?? "")
        // `/model` with no model opens the same choices from this pill. SwiftUI
        // cannot open a `Menu` from code, so they come as a list in a popover.
        .popover(isPresented: $composer.isModelPickerRequested, arrowEdge: .top) {
            ModelPickerList(composer: composer)
        }
    }

    @ViewBuilder private var effortMenu: some View {
        let choices = composer.effortChoices
        if !choices.isEmpty {
            Menu {
                Section("Reasoning Effort") {
                    ForEach(choices, id: \.self) { level in
                        Toggle(ReasoningEffort.label(level), isOn: Binding(
                            get: { composer.currentEffort == level },
                            set: { _ in Task { await composer.selectEffort(level) } }))
                    }
                }
            } label: {
                pillLabel(ReasoningEffort.label(composer.currentEffort))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight()
            .disabled(!isConnected)
            .help("Reasoning effort for this chat")
            .accessibilityLabel("Reasoning effort")
            .accessibilityValue(ReasoningEffort.label(composer.currentEffort))
        }
    }

    @ViewBuilder private func pillLabel(_ title: String) -> some View {
        #if os(macOS)
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.7)
        }
        .uiFont(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: Self.controlSize)
        .contentShape(.rect)
        #else
        // A filled capsule like `+`'s circle. A long model name shortens in the middle, so the
        // effort pill and Send keep their room on a phone (`modelMenu` isn't fixed in size).
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .uiFont(.subheadline, weight: .medium)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: Self.controlSize)
        .background(Self.controlFill, in: .capsule)
        .contentShape(.capsule)
        #endif
    }

    /// The card's hairline: Desktop mixes 18% of the text colour into its input stroke
    /// (`apps/desktop/src/app/chat/composer/index.tsx`, the composer surface's `border`).
    static let borderOpacity = 0.15

    #if os(iOS)
    /// The fill of `+` and the pills on the card, as the Claude app's.
    static let controlFill = Color.primary.opacity(0.08)
    #endif

    /// Voice input needs the dashboard's HTTP transcription route; the gateway's
    /// `voice.record` records on the gateway host's microphone, not this device's
    /// (docs/protocol.md §10.4). Shown, disabled, so the gap is visible on macOS;
    /// iOS has no hover to explain it, so it is left out there.
    @ViewBuilder private var micButton: some View {
        #if os(macOS)
        Button {} label: {
            Label("Voice Input", systemImage: "mic")
                .labelStyle(.iconOnly)
                .frame(width: 18, height: 18)
        }
        // Disabled, so it shows no hover; the style keeps it the size of its neighbours.
        .hoverButtonStyle(.circle, padding: 4)
        .disabled(true)
            .help("Voice input isn't available yet: Hermes's gateway voice methods record on the server's own microphone, not this Mac's.")
            .accessibilityHint("Not available yet.")
        #endif
    }

    /// Idle: Send. While a reply runs: Stop, plus Send beside it as soon as
    /// there is something to send. What Hermes does with it depends on the
    /// content (docs/protocol.md §10.3):
    /// - a message with images is always queued as its own next turn;
    /// - text alone follows the profile's `display.busy_input_mode`, which
    ///   defaults to `interrupt` (`tui_gateway/server.py:375-377`): it redirects
    ///   or cuts off the running reply. It may also be `queue` or `steer`.
    /// The app reads no setting for this, so the copy states both cases. On iOS
    /// Return inserts a newline, so this button is the way to send during a reply.
    @ViewBuilder private var sendButton: some View {
        if session.transcript.isRunning {
            HStack(spacing: 6) {
                if composer.canSubmit || composer.isSubmitting {
                    if composer.isSubmitting {
                        cancelSendButton(isProminent: false)
                    } else {
                        Button("Send", systemImage: "arrow.up", action: submit)
                            .buttonStyle(CircleButtonStyle(isProminent: false))
                            .disabled(!composer.canSubmit)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help(composer.attachments.isEmpty
                                  ? "Send now. By default Hermes redirects or stops the current reply for it (its busy-input setting)."
                                  : "Send now. Hermes queues a message with images to run after the current reply.")
                            .accessibilityHint(composer.attachments.isEmpty
                                               ? "May redirect or stop the current reply."
                                               : "Queued to run after the current reply.")
                            .transition(.swapped)
                    }
                }
                Button("Stop", systemImage: "stop.fill") {
                    Task {
                        stopError = nil
                        do { try await session.interrupt() } catch { stopError = GatewayConnection.describe(error) }
                    }
                }
                .buttonStyle(CircleButtonStyle())
                .disabled(!isConnected)
                .help("Stop the reply")
                .transition(.swapped)
            }
        } else {
            if composer.isSubmitting {
                cancelSendButton(isProminent: true)
            } else {
                Button("Send", systemImage: "arrow.up", action: submit)
                    .buttonStyle(CircleButtonStyle())
                    .disabled(!composer.canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(composer.uploadingImageIDs.isEmpty ? "Send (Return)" : "Waiting for the images to upload")
                    .transition(.swapped)
            }
        }
    }

    /// While a send is in flight (cleaning up stranded images, uploading):
    /// a spinner the user can tap to cancel it. Draft and cards come back; a
    /// prompt already submitted is not recalled (`ChatComposer.cancelSubmit`).
    private func cancelSendButton(isProminent: Bool) -> some View {
        Button("Cancel Send", systemImage: "xmark") { composer.cancelSubmit() }
            .buttonStyle(CircleButtonStyle(isBusy: true, isProminent: isProminent))
            .help("Sending… click to cancel")
            .accessibilityHint("Stops sending; the message and images stay in the composer.")
            .transition(.swapped)
    }

    // MARK: Actions

    private func submit() {
        #if os(iOS)
        // Capture marked/native text before checking or starting the async send.
        // Keep the keyboard; ordinary candidate selection and Return do not use this path.
        guard !composer.isSubmitting, isConnected else { return }
        inputHandle.prepareSubmission?()
        #endif
        guard composer.canSubmit else { return }
        if SlashCommand.isCommand(composer.draft) {
            Task { await composer.submitSlash() }
        } else {
            Task { await composer.submit() }
        }
        focusRequest += 1
    }

    /// Images become image cards (re-encoded if needed); anything else, or an image
    /// that cannot be decoded, is uploaded as a file.
    private func attach(_ sources: [AttachmentSource]) async {
        for source in sources {
            if source.isImage {
                do {
                    let loaded = try await ImageLoader.load(source)
                    if composer.attach(loaded.attachment) {
                        thumbnails[loaded.attachment.id] = loaded.thumbnail
                        // The sent bubble shows the same thumbnail (`TranscriptImageCard`).
                        if let thumbnail = loaded.thumbnail { server.thumbnails.storeLocal(thumbnail, for: loaded.attachment.id) }
                    }
                    continue
                } catch ImageLoader.Failure.notAnImage {
                    // Named like an image but not one: send the file as it is.
                } catch {
                    composer.error = error.localizedDescription
                    continue
                }
            }
            do {
                let file = try await FileLoader.load(source)
                await composer.attachFile(file.data, filename: file.filename, mimeType: file.mimeType)
            } catch {
                composer.error = error.localizedDescription
            }
        }
    }

    #if os(iOS)
    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                await attach([.data(data, filename: "Photo.\(ext)")])
            } catch {
                composer.error = "Couldn't load the photo: \(error.localizedDescription)"
            }
        }
    }
    #endif
}

/// The model menu's choices as a list, for `/model` (Desktop opens its model
/// picker there, `use-prompt-actions/slash.ts:1284-1295`): grouped by provider,
/// the current one checked, with the menu's Reload when the catalog is missing.
private struct ModelPickerList: View {
    let composer: ChatComposer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let catalog = composer.catalog, !catalog.isEmpty {
                ForEach(catalog.providers, id: \.slug) { provider in
                    Section(provider.name) {
                        ForEach(provider.models, id: \.self) { model in
                            row(ModelChoice(provider: provider.slug, model: model))
                        }
                    }
                }
            } else {
                Text(composer.catalog == nil ? "Loading models…" : "No models available")
                    .foregroundStyle(.secondary)
            }
            Button("Reload Models", systemImage: "arrow.clockwise") {
                Task { await composer.loadOptions() }
            }
        }
        .frame(minWidth: 260, idealWidth: 300, minHeight: 200, idealHeight: 360)
        // The sheet's or popover's own Liquid Glass shows through, not the list's page.
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("modelPickerList")
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func row(_ choice: ModelChoice) -> some View {
        let isCurrent = composer.isCurrent(choice)
        return Button {
            dismiss()
            Task { await composer.selectModel(choice) }
        } label: {
            HStack {
                Text(ModelLabel.displayName(choice.model))
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

private extension AnyTransition {
    /// A round button taking another's place: it shrinks away as the next one grows in.
    static var swapped: AnyTransition { .scale(scale: 0.6).combined(with: .opacity) }
}

/// The filled circular Send/Stop button: the composer's one high-contrast
/// control. `isProminent: false` is the quieter Send shown beside Stop.
private struct CircleButtonStyle: ButtonStyle {
    var isBusy = false
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        CircleButton(configuration: configuration, isBusy: isBusy, isProminent: isProminent)
    }
}

/// The style's body: a view, so it can hold the hover state (macOS; `Hover.swift`).
/// Hovered, the filled circle lightens a little, and the quiet one gets the hover fill.
private struct CircleButton: View {
    let configuration: ButtonStyleConfiguration
    let isBusy: Bool
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .opacity(isEnabled && isProminent && hovered ? 0.8 : 1)
            Circle()
                .fill(Hover.fill(pressed: false))
                .opacity(isEnabled && !isProminent && hovered ? 1 : 0)
            if isBusy {
                // Sending: a spinner around the label (the cancel ✕).
                ProgressView()
                    .controlSize(.small)
                    .tint(Self.isAccentFilled && isProminent ? Color.white : Color(white: 0.5))
                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.system(size: Self.isAccentFilled ? 10 : 8, weight: .bold))
                    .foregroundStyle(Self.isAccentFilled && isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            } else {
                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.system(size: Self.isAccentFilled ? 16 : 12, weight: .bold))
                    .foregroundStyle(labelStyle)
            }
        }
        .frame(width: ComposerView.controlSize, height: ComposerView.controlSize)
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(.circle)
        .onHover { isHovered = $0 }
    }

    private var hovered: Bool {
        #if os(macOS)
        isHovered
        #else
        false
        #endif
    }

    /// On iOS the filled circle is the theme's accent with a white arrow, as the Claude
    /// app's Send; on the Mac the text colour, as Desktop's.
    private static var isAccentFilled: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    private var fill: AnyShapeStyle {
        guard isProminent else { return AnyShapeStyle(.quaternary) }
        if Self.isAccentFilled { return isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.35)) }
        // Disabled: the text colour at 30%, as Desktop's `disabled:bg-foreground/30`
        // (`control-classes.ts`), so the empty composer's Send still reads as a button.
        // `Color.primary`, not the `.primary` style: on the composer's glass that style
        // turns vibrant, and a disabled button resolves it to the disabled text colour,
        // so Send came out the same pale grey with text or without (VM, 2026-10-27).
        return AnyShapeStyle(Color.primary.opacity(isEnabled ? 1 : 0.3))
    }

    private var labelStyle: AnyShapeStyle {
        if Self.isAccentFilled && isProminent { return AnyShapeStyle(.white.opacity(isEnabled ? 1 : 0.85)) }
        guard isProminent else { return isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary) }
        // The circle's opposite, black or white, for the reason `fill` gives.
        return AnyShapeStyle(colorScheme == .dark ? Color.black : Color.white)
    }
}
