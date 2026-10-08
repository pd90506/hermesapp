import HermesKit
import HermesProtocol
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The chat composer, after Hermes Desktop's: attachment cards, an auto-growing
/// text area, and a toolbar with `+`, the model and effort pickers, the mic and
/// Send/Stop. All state lives in `ChatComposer` (HermesKit); this view only
/// reads images and lays things out.
struct ComposerView: View {
    let composer: ChatComposer
    var isConnected: Bool

    @State private var textHeight: CGFloat = 0
    @State private var thumbnails: [UUID: CGImage] = [:]
    @Environment(AppModel.self) private var model
    @State private var focusRequest = 0
    @State private var isImportingFile = false
    @State private var isDropTargeted = false
    @State private var stopError: String?
    #if os(iOS)
    @State private var photoSelection: [PhotosPickerItem] = []
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
            if !composer.attachments.isEmpty {
                cards
            }
            textArea
            toolbar
        }
        .background(fill, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: 1)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            Task { await attach(await ImageLoader.sources(from: providers)) }
            return true
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await attach(urls.map(ImageSource.file)) }
            case .failure(let error): composer.error = error.localizedDescription
            }
        }
        #if os(iOS)
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
            if isConnected { await composer.loadOptions() }
        }
    }

    private struct TaskKey: Hashable {
        var sessionID: String
        var isConnected: Bool
    }

    private var fill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    // MARK: Rows

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
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
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var cards: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(composer.attachments) { attachment in
                    // The draft outlives this view (`GatewayConnection.composer(for:)`); its thumbnails
                    // are also in the shared store, for when the chat is shown again.
                    AttachmentCardView(attachment: attachment,
                                       thumbnail: thumbnails[attachment.id] ?? model.thumbnails.local(attachment.id),
                                       isSending: composer.isSubmitting) {
                        composer.removeAttachment(id: attachment.id)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .scrollIndicators(.never)
    }

    private var textArea: some View {
        @Bindable var composer = composer
        return ComposerTextView(
            text: $composer.draft, contentHeight: $textHeight, maxHeight: maxTextHeight, focusRequest: focusRequest,
            onSubmit: submit,
            onImages: { sources in Task { await attach(sources) } },
            onImageProviders: { providers in Task { await attach(await ImageLoader.sources(from: providers)) } }
        )
        .frame(height: min(max(textHeight, 28), maxTextHeight))
        .overlay(alignment: .topLeading) {
            if composer.draft.isEmpty {
                Text("Message Hermes")
                    .foregroundStyle(.tertiary)
                    .padding(.top, ComposerTextView.verticalInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            addMenu
            Spacer(minLength: 8)
            modelMenu
            effortMenu
            micButton
            sendButton
                .padding(.leading, 4)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .padding(.top, 2)
    }

    // MARK: Toolbar controls

    private var addMenu: some View {
        Menu {
            #if os(iOS)
            PhotosPicker(selection: $photoSelection, matching: .images) {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            #endif
            Button(fileMenuTitle, systemImage: "doc") { isImportingFile = true }
            Button("Paste Image", systemImage: "doc.on.clipboard", action: pasteImage)
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(in: Circle())
        .foregroundStyle(.secondary)
        .help("Attach an image")
        .accessibilityLabel("Attach")
    }

    private var fileMenuTitle: String {
        #if os(macOS)
        "Choose Image…"
        #else
        "Choose File…"
        #endif
    }

    private var modelMenu: some View {
        Menu {
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
        .fixedSize()
        .hoverHighlight()
        .disabled(!isConnected)
        .help(composer.currentModel.map { "Model for this chat: \($0)" } ?? "Model for this chat")
        .accessibilityLabel("Model")
        .accessibilityValue(composer.currentModelLabel ?? "")
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

    private func pillLabel(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.7)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .contentShape(.rect)
    }

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
            }
        } else {
            if composer.isSubmitting {
                cancelSendButton(isProminent: true)
            } else {
                Button("Send", systemImage: "arrow.up", action: submit)
                    .buttonStyle(CircleButtonStyle())
                    .disabled(!composer.canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return)")
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
    }

    // MARK: Actions

    private func submit() {
        guard composer.canSubmit else { return }
        Task { await composer.submit() }
        focusRequest += 1
    }

    private func attach(_ sources: [ImageSource]) async {
        for source in sources {
            do {
                let loaded = try await ImageLoader.load(source)
                if composer.attach(loaded.attachment) {
                    thumbnails[loaded.attachment.id] = loaded.thumbnail
                    // The sent bubble shows the same thumbnail (`TranscriptImageCard`).
                    if let thumbnail = loaded.thumbnail { model.thumbnails.storeLocal(thumbnail, for: loaded.attachment.id) }
                }
            } catch {
                composer.error = error.localizedDescription
            }
        }
    }

    private func pasteImage() {
        #if os(macOS)
        let sources = ImageLoader.sources(from: NSPasteboard.general)
        if sources.isEmpty { composer.error = "The clipboard has no image." }
        Task { await attach(sources) }
        #else
        let providers = ImageLoader.pastedImageProviders()
        if providers.isEmpty { composer.error = "The clipboard has no image." }
        Task { await attach(await ImageLoader.sources(from: providers)) }
        #endif
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
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isEnabled && isProminent ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                .opacity(isEnabled && isProminent && hovered ? 0.8 : 1)
            Circle()
                .fill(Hover.fill(pressed: false))
                .opacity(isEnabled && !isProminent && hovered ? 1 : 0)
            if isBusy {
                // Sending: a spinner around the label (the cancel ✕).
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(white: 0.5))
                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(!isEnabled ? AnyShapeStyle(.secondary)
                        : isProminent ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            }
        }
        .frame(width: 26, height: 26)
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
}
