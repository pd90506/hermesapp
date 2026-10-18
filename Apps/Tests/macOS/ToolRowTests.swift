import AppKit
import HermesKit
import SwiftUI
import Testing

/// An opened tool call stays a bounded size: a long diff scrolls inside a box of
/// `ToolTextBox.diffMaxLines` lines, as Desktop's 12rem diff box does, and output
/// inside one of `ToolTextBox.outputMaxLines`, as its 5rem payload box does.
@MainActor
@Suite struct ToolRowTests {
    private func height(_ view: some View, width: CGFloat = 400) -> CGFloat {
        NSHostingView(rootView: view.frame(width: width)).fittingSize.height
    }

    static func edit(lines: Int) -> TranscriptItem {
        var item = TranscriptItem(id: "edit", role: .tool, text: "")
        item.toolName = "patch"
        var tool = ToolActivity(toolID: "edit", name: "patch", phase: .complete)
        tool.args = ["path": "Sources/File.swift"]
        tool.inlineDiff = "--- a/File.swift\n+++ b/File.swift\n@@ -1 +1 @@\n"
            + (1...lines).map { "+line \($0)" }.joined(separator: "\n")
        item.tool = tool
        return item
    }

    @Test func aLongDiffScrollsInsideItsBox() {
        let short = height(ToolMessageContent(item: Self.edit(lines: 3)))
        let long = height(ToolMessageContent(item: Self.edit(lines: 200)))
        let limit = height(ToolMessageContent(item: Self.edit(lines: ToolTextBox.diffMaxLines + 1)))
        #expect(short > 40, "an edit with a diff opens by default (\(short) pt)")
        #expect(long < 260, "a 200-line diff is \(long) pt tall")
        #expect(abs(long - limit) <= 1, "the box is one height once it scrolls: \(long) vs \(limit)")
    }

    static func read(lines: Int) -> TranscriptItem {
        var item = TranscriptItem(id: "read", role: .tool, text: "")
        item.toolName = "read_file"
        var tool = ToolActivity(toolID: "read", name: "read_file", phase: .complete)
        tool.args = ["path": "notes.md", "offset": 10, "limit": .number(Double(lines))]
        tool.result = ["content": .string((10..<(10 + lines)).map { "\($0)|line" }.joined(separator: "\n"))]
        item.tool = tool
        return item
    }

    /// A read is one closed line; opened in place, its lines scroll inside a short box.
    @Test func aReadOpensInPlaceToItsLines() {
        let closed = height(ToolMessageContent(item: Self.read(lines: 40)))
        #expect(closed < 24, "a read is one line until opened (\(closed) pt)")
        let opened = height(ToolMessageContent(item: Self.read(lines: 40), isExpanded: true))
        #expect(opened > closed + 40 && opened < closed + 160, "opened in place, its box bounded: \(opened) pt")
        let short = height(ToolTextBox(text: "1|a\n2|b", kind: .code))
        let long = height(ToolTextBox(text: (1...40).map { "\($0)|x" }.joined(separator: "\n"), kind: .code))
        let limit = height(ToolTextBox(text: (1...(ToolTextBox.outputMaxLines + 1)).map { "\($0)" }
            .joined(separator: "\n"), kind: .code))
        #expect(short < long, "\(short) vs \(long)")
        #expect(abs(long - limit) <= 1, "the output box is one height once it scrolls: \(long) vs \(limit)")
    }

    /// A background-process notice is one line until opened, however long its output.
    @Test func aBackgroundNoticeIsOneLine() throws {
        let text = "[IMPORTANT: Background process proc_1 completed normally (exit code 0).\nCommand: make\nOutput:\n"
            + (1...80).map { "build step \($0)" }.joined(separator: "\n") + "]"
        let notice = try #require(BackgroundNotice(text))
        let line = height(BackgroundNoticeRow(notice: notice))
        #expect(line < 24, "the notice is \(line) pt tall")
    }

    @Test func aShortDiffHasNoScrollBox() {
        let host = NSHostingView(rootView: ToolMessageContent(item: Self.edit(lines: 3)).frame(width: 400))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(descendants(NSScrollView.self, in: host).isEmpty)
    }
}

@MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var result: [T] = []
    if let match = view as? T { result.append(match) }
    for child in view.subviews { result += descendants(type, in: child) }
    return result
}
