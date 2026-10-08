import HermesKit
import SwiftUI

/// An assistant reply: reasoning disclosure, the rendered Markdown, and the
/// action bar. Menus belong to the row that hosts it.
struct AssistantMessageContent: View {
    let item: TranscriptItem
    var isHovering = false
    var isNewest = false
    var conversationSource: (() -> String)?
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            }
            // Directly under the message, so moving down onto it never leaves the row.
            MessageActionBar(isHovering: isHovering, isNewest: isNewest, copy: copy)
        }
    }
}

/// A tool call card: name and up to three lines of detail. No action bar
/// (Copy Message is in its context menu), so a run of tool calls stays compact.
struct ToolMessageContent: View {
    let item: TranscriptItem

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
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
