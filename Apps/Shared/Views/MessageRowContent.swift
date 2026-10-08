import HermesKit
import SwiftUI

/// An assistant reply: reasoning disclosure, the rendered Markdown, and the
/// copy button. Hover tracking and menus belong to the row that hosts it.
struct AssistantMessageContent: View {
    let item: TranscriptItem
    var isHovering = false
    var conversationSource: (() -> String)?
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.reasoning.isEmpty {
                // Model-written like the reply, so rendered the same way; the
                // content is only built while expanded.
                DisclosureGroup("Reasoning") {
                    MarkdownView(text: item.reasoning, isStreaming: item.isActive, isReasoning: true)
                        .equatable()
                }
                .font(.caption)
            }
            if item.text.isEmpty && item.isActive {
                Text("…")
            } else {
                MarkdownView(text: item.text, isStreaming: item.isActive, conversationSource: conversationSource)
                    .equatable()
            }
            if item.outcome == "interrupted" {
                Text("Interrupted").font(.caption).foregroundStyle(.secondary)
            }
            InlineMessageCopyButton(action: copy)
        }
        .messageCopyAccessory(isHovering: isHovering, placement: .trailingGutter(.bottom), action: copy)
    }
}

/// A tool call card: name, up to three lines of detail, and the copy button.
struct ToolMessageContent: View {
    let item: TranscriptItem
    var isHovering = false
    let copy: () -> Void

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.toolName ?? "tool").font(.callout.monospaced())
                    if let detail = item.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            } icon: {
                if item.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                }
            }
            Spacer(minLength: 4)
            InlineMessageCopyButton(action: copy)
        }
        .messageCopyAccessory(isHovering: isHovering, placement: .trailingGutter(.center), action: copy)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// iOS keeps the copy button in the row, always visible; macOS shows it on
/// hover beside the row's text instead (`messageCopyAccessory`).
struct InlineMessageCopyButton: View {
    let action: () -> Void

    var body: some View {
        #if os(iOS)
        MessageCopyButton(action: action)
        #endif
    }
}
