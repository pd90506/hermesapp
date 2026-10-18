import AppKit
import HermesKit
import ObjectiveC
import SwiftUI
import Testing

/// A table is never cut off: its container is as tall as its rows at every point
/// of a reply's life (streaming, a tool call, finished, resized), with legacy and
/// overlay scroll bars, while it, and the text around it, stays in the column.
///
/// The cut came from SwiftUI's `Grid`: offered a definite height (the horizontal
/// scroll view offers its own) with vertically flexible cells, it spreads the
/// extra line of a wrapped row over every row, so it lays out taller than the
/// ideal height its container took and the last row falls past the bottom.
@MainActor
@Suite(.serialized) struct TableClipTests {
    /// A long CJK paragraph, a long unbroken URL, then a 6-row table whose third
    /// body row wraps, as in the report.
    static let reply = """
    下面是本次申请的时间安排和材料要求，请仔细核对。\(String(repeating: "所有申请人都需要按时完成每一个步骤，否则可能影响最终的录取结果。", count: 5))

    参考链接：https://example.com/\(String(repeating: "very-long-path-segment-", count: 14))end?query=\(String(repeating: "x", count: 40))

    | 项目 | 说明 | 截止 |
    |---|---|---|
    | 报名 | 在线填写报名表 | 9月30日 |
    | 材料准备 | 成绩单、推荐信、个人陈述 | 10月10日 |
    | 提交截止 | 所有材料必须在截止日期之前通过在线系统提交，逾期不予受理，请提前准备好全部文件 | 10月15日 |
    | 面试 | 线上面试，约30分钟 | 11月初 |
    | 结果 | 邮件通知 | 12月 |

    - 第一点
    - 第二点

    **结论：尽早准备。**
    """

    /// Wider than any chat column: it must scroll inside its own container.
    static let wide = "Wide table:\n\n| " + (1...9).map { "Column number \($0)" }.joined(separator: " | ") + " |\n|"
        + String(repeating: "---|", count: 9) + "\n| " + (1...9).map { "value \($0) that is long" }.joined(separator: " | ") + " |"

    nonisolated static let widths: [CGFloat] = [500, 770, 1000]

    // MARK: Hosting, as ChatView lays out the transcript

    struct Column: View {
        let items: [TranscriptItem]

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        if item.role == .tool {
                            ToolMessageContent(item: item)
                        } else {
                            AssistantMessageContent(item: item) {}
                        }
                    }
                }
                .padding()
            }
        }
    }

    /// The transcript's horizontal padding (`.padding()` in `ChatView`).
    static let gutter: CGFloat = 16

    @MainActor final class Chat {
        let host: NSHostingView<Column>
        let window: NSWindow
        let style: NSScroller.Style

        init(width: CGFloat, style: NSScroller.Style, items: [TranscriptItem]) {
            self.style = style
            host = NSHostingView(rootView: Column(items: items))
            window = NSWindow(contentRect: .testArea(CGSize(width: width, height: 1600)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            // Owned by ARC here (see MarkdownSelectionHostTests.fullMessage).
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.showInTestArea()
            settle()
        }

        func show(_ items: [TranscriptItem]) {
            host.rootView = Column(items: items)
            settle()
        }

        func resize(width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: window.frame.height))
            settle()
        }

        /// Lays out, lets SwiftUI apply what it deferred to the main queue, and
        /// keeps every scroll view on the style under test. No waiting: the run
        /// loop only handles what is already queued.
        func settle() {
            for _ in 0..<2 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: Date())
                for scroll in descendants(NSScrollView.self, in: host) where scroll.scrollerStyle != style {
                    scroll.scrollerStyle = style
                }
            }
            host.layoutSubtreeIfNeeded()
        }

        func close() { window.close() }
    }

    /// Makes AppKit's preferred scroller style `style` for the test's duration, as
    /// a connected mouse ("Automatically") or "Always" does for legacy, so SwiftUI
    /// builds its scroll views for it; each scroll view is also set directly.
    enum PreferredScrollerStyle {
        // Written only by these serialized main-actor tests, read by AppKit on the
        // main thread while they lay out.
        nonisolated(unsafe) private static var forced: NSScroller.Style?
        nonisolated(unsafe) private static var installed = false

        @MainActor static func with<T>(_ style: NSScroller.Style, _ body: () throws -> T) rethrows -> T {
            install()
            forced = style
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            defer {
                forced = nil
                NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            }
            return try body()
        }

        nonisolated private static func install() {
            guard !installed else { return }
            installed = true
            let selector = #selector(getter: NSScroller.preferredScrollerStyle)
            guard let method = class_getClassMethod(NSScroller.self, selector) else { return }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let replacement: @convention(block) (AnyObject) -> Int = { object in
                forced?.rawValue ?? original(object, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    // MARK: Checks

    /// The horizontal scroll views that hold a table's cells.
    static func tableScrolls(in root: NSView) -> [NSScrollView] {
        descendants(NSScrollView.self, in: root).filter { scroll in
            guard let document = scroll.documentView else { return false }
            return descendants(NSScrollView.self, in: document).isEmpty
                && !descendants(MarkdownSelectionTextView.self, in: document).isEmpty
        }
    }

    /// Every table's visible area holds all of its rows: the lowest cell, its 5 pt
    /// padding and the 1 pt border, within 1 pt. A legacy scroller takes its height
    /// out of the visible area, so it counts too.
    func expectTablesFit(_ chat: Chat, _ stage: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for scroll in Self.tableScrolls(in: chat.host) {
            guard let document = scroll.documentView else { continue }
            #expect(scroll.scrollerStyle == chat.style, "\(stage): the scroll view is not on the style under test",
                    sourceLocation: sourceLocation)
            let clip = scroll.contentView
            let visible = clip.documentVisibleRect
            let cells = descendants(MarkdownSelectionTextView.self, in: document)
            let lowest = cells.map { clip.convert($0.bounds, from: $0).maxY }.max() ?? 0
            #expect(lowest + 6 <= visible.maxY + 1,
                    "\(stage): rows end at \(lowest + 6), the table shows \(visible.height) (frame \(scroll.frame.height))",
                    sourceLocation: sourceLocation)
            #expect(document.frame.height <= visible.height + 1,
                    "\(stage): content \(document.frame.height) is taller than the visible \(visible.height)",
                    sourceLocation: sourceLocation)
            for cell in cells {
                #expect(abs(cell.fittingHeight(width: cell.frame.width) - cell.frame.height) <= 0.5,
                        "\(stage): cell \(cell.string.prefix(8)) is \(cell.frame.height) tall for its text",
                        sourceLocation: sourceLocation)
            }
        }
    }

    /// Tables, code and prose stay inside the transcript column; prose text
    /// containers are exactly as wide as their views.
    func expectInsideColumn(_ chat: Chat, _ stage: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let host = chat.host
        let left = Self.gutter - 0.5, right = host.bounds.width - Self.gutter + 0.5
        // The components' own scroll views: every one but the transcript's.
        let scrolls = descendants(NSScrollView.self, in: host).filter { scroll in
            scroll.documentView.map { descendants(NSScrollView.self, in: $0).isEmpty } ?? false
        }
        #expect(!scrolls.isEmpty, sourceLocation: sourceLocation)
        for scroll in scrolls {
            let frame = scroll.convert(scroll.bounds, to: host)
            #expect(frame.minX >= left && frame.maxX <= right, "\(stage): a scroll view at \(frame) leaves the column",
                    sourceLocation: sourceLocation)
        }
        let tables = Self.tableScrolls(in: host)
        let prose = descendants(MarkdownSelectionTextView.self, in: host).filter { view in
            !tables.contains { view.isDescendant(of: $0) }
        }
        #expect(!prose.isEmpty, sourceLocation: sourceLocation)
        for view in prose {
            let frame = view.convert(view.bounds, to: host)
            #expect(frame.minX >= left && frame.maxX <= right, "\(stage): text at \(frame) leaves the column",
                    sourceLocation: sourceLocation)
            #expect(abs((view.textContainer?.size.width ?? 0) - view.frame.width) <= 0.5,
                    "\(stage): text container \(view.textContainer?.size.width ?? 0) for a \(view.frame.width) view",
                    sourceLocation: sourceLocation)
            if let layoutManager = view.layoutManager, let container = view.textContainer {
                layoutManager.ensureLayout(for: container)
                #expect(layoutManager.usedRect(for: container).maxX <= view.frame.width + 0.5,
                        "\(stage): text runs past its view", sourceLocation: sourceLocation)
            }
        }
    }

    static func reply(_ text: String, active: Bool) -> TranscriptItem {
        TranscriptItem(id: "reply", role: .assistant, text: text, isActive: active)
    }

    static func tool(active: Bool) -> TranscriptItem {
        var item = TranscriptItem(id: "tool", role: .tool, text: "", isActive: active)
        item.toolName = "terminal"
        item.detail = "ls -la"
        return item
    }

    nonisolated static let styles: [NSScroller.Style] = [.legacy, .overlay]

    // MARK: 1. Streaming, a tool call, the end of the turn

    /// The reply arrives a few characters at a time, so rows and cell text grow
    /// in pieces, the wrapped cell included; then a tool runs; then the turn ends.
    @Test(arguments: styles, widths)
    func tableFitsWhileStreamingDuringToolsAndAfter(style: NSScroller.Style, width: CGFloat) {
        PreferredScrollerStyle.with(style) {
            let chat = Chat(width: width, style: style, items: [])
            defer { chat.close() }
            let characters = Array(Self.reply)
            var end = 0
            var checked = 0
            while end < characters.count {
                end = min(end + 4, characters.count)
                chat.show([Self.reply(String(characters[..<end]), active: true)])
                if !Self.tableScrolls(in: chat.host).isEmpty {
                    checked += 1
                    expectTablesFit(chat, "streamed \(end)/\(characters.count) at \(width)")
                }
            }
            #expect(checked > 20, "the table was only on screen for \(checked) deltas")
            expectInsideColumn(chat, "streamed at \(width)")

            chat.show([Self.reply(Self.reply, active: true), Self.tool(active: true)])
            expectTablesFit(chat, "tool running at \(width)")
            chat.show([Self.reply(Self.reply, active: false), Self.tool(active: false)])
            expectTablesFit(chat, "turn ended at \(width)")
            expectInsideColumn(chat, "turn ended at \(width)")
        }
    }

    // MARK: 2. Resizing

    @Test(arguments: styles)
    func tableFitsAfterShrinkingTheWindow(style: NSScroller.Style) {
        PreferredScrollerStyle.with(style) {
            let chat = Chat(width: 1200, style: style, items: [Self.reply(Self.reply, active: false)])
            defer { chat.close() }
            expectTablesFit(chat, "at 1200")
            chat.resize(width: 760)
            #expect(chat.host.bounds.width == 760)
            expectTablesFit(chat, "shrunk to 760")
            expectInsideColumn(chat, "shrunk to 760")
            // Shrunk mid-stream as well.
            chat.show([Self.reply(String(Self.reply.prefix(Self.reply.count - 30)), active: true)])
            chat.resize(width: 1200)
            chat.resize(width: 760)
            expectTablesFit(chat, "shrunk to 760 mid-stream")
        }
    }

    // MARK: 3. Width

    /// A table wider than the column scrolls inside its own container, which
    /// stays in the column and, with a legacy scroller showing, still shows
    /// every row above it.
    @Test(arguments: styles, widths)
    func wideTableScrollsInsideTheColumn(style: NSScroller.Style, width: CGFloat) throws {
        try PreferredScrollerStyle.with(style) {
            let chat = Chat(width: width, style: style, items: [Self.reply(Self.wide + "\n\nAfter.", active: false)])
            defer { chat.close() }
            let scroll = try #require(Self.tableScrolls(in: chat.host).first)
            let document = try #require(scroll.documentView)
            #expect(NSScroller.preferredScrollerStyle == style)
            #expect(document.frame.width > scroll.contentView.bounds.width + 20, "the wide table does not scroll")
            if style == .legacy {
                // A legacy scroller shows and takes its own room below the rows.
                let scroller = try #require(scroll.horizontalScroller)
                #expect(scroll.hasHorizontalScroller && !scroller.isHidden, "no legacy scroller on the wide table")
                #expect(scroll.contentView.frame.height <= scroll.frame.height - scroller.frame.height + 0.5,
                        "the legacy scroller covers the rows instead of sitting below them")
            }
            #expect(scroll.frame.width <= width - 2 * Self.gutter + 0.5, "the wide table widened the column")
            expectTablesFit(chat, "wide at \(width)")
            expectInsideColumn(chat, "wide at \(width)")
            // And while it streams in.
            chat.show([Self.reply(Self.wide, active: true)])
            expectTablesFit(chat, "wide streaming at \(width)")
        }
    }

    /// The long CJK paragraph and the long URL wrap inside the column.
    @Test(arguments: widths)
    func longCJKAndURLWrap(width: CGFloat) throws {
        let chat = Chat(width: width, style: NSScroller.preferredScrollerStyle, items: [Self.reply(Self.reply, active: false)])
        defer { chat.close() }
        let prose = try #require(descendants(MarkdownSelectionTextView.self, in: chat.host).first { $0.string.contains("example.com") })
        let layoutManager = try #require(prose.layoutManager)
        let storage = prose.string as NSString
        /// The top of the line holding the first (or last) occurrence of `text`.
        func lineTop(_ text: String, last: Bool = false) throws -> CGFloat {
            let range = storage.range(of: text, options: last ? .backwards : [])
            try #require(range.location != NSNotFound, "no \(text)")
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        #expect(try lineTop("end?query=") > lineTop("https://"), "the long URL did not wrap at \(width)")
        #expect(try lineTop("录取结果。", last: true) > lineTop("所有申请人"), "the long CJK paragraph did not wrap at \(width)")
        expectInsideColumn(chat, "CJK and URL at \(width)")
    }

    // MARK: 4. Look: every grid line is whole, the wrapped row included

    @Test func wrappedRowKeepsEveryGridLineAndTheBottomBorder() throws {
        let table = try #require(MarkdownPresentation(parsing: Self.reply).parts.lazy.compactMap { part -> MarkdownTable? in
            if case .table(let table) = part.content { return table } else { return nil }
        }.first)
        let host = NSHostingView(rootView: MarkdownTableGrid(table: table).frame(width: 738)
            .fixedSize(horizontal: false, vertical: true).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 738, height: 10)
        host.frame.size.height = host.fittingSize.height
        let window = NSWindow(contentRect: .testArea(host.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // The grid learns the width it fills in its first layout, then lays out again:
        // size the window to that second layout, as the chat's stack does.
        RunLoop.main.run(mode: .default, before: Date())
        host.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 738, height: host.fittingSize.height))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        func dark(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let color = rep.colorAt(x: Int((x * scale).rounded(.down)), y: Int((y * scale).rounded(.down)))
            // Luma, not HSB brightness, which is 1 for the blue border on white.
            guard let rgb = color?.usingColorSpace(.sRGB) else { return false }
            return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.97
        }
        // The border's top and bottom, met walking down 20 pt in; its sides, met
        // walking across the header's top padding.
        let height = host.bounds.height
        let minY = try #require(stride(from: 0, to: height, by: 1 / scale).first { dark(20, $0) })
        let maxY = try #require(stride(from: height - 1 / scale, through: 0, by: -1 / scale).first { dark(20, $0) })
        let minX = try #require(stride(from: 0, to: 738, by: 1 / scale).first { dark($0, minY + 3) })
        let maxX = try #require(stride(from: 737, through: 0, by: -1 / scale).first { dark($0, minY + 3) })
        #expect(maxY >= height - 1 - 1 / scale, "the table draws nothing in its last point: the bottom is cut (\(maxY) of \(height))")

        /// Positions where a line crosses the walk from `from` to `to` (one per line).
        func crossings(_ points: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = [], inLine = false
            for point in points {
                let hit = dark(point.x, point.y)
                if hit && !inLine { result.append(point) }
                inLine = hit
            }
            return result
        }
        let step = 1 / scale
        let inset = MarkdownTableGrid.cornerRadius + 1
        // Row lines, met walking down the first column's left padding: the top border
        // (run into the tinted header and its rule), 4 rules between body rows, the bottom.
        let rowLines = crossings(stride(from: minY, through: maxY, by: step).map { CGPoint(x: minX + inset + 2, y: $0) })
        #expect(rowLines.count == 6, "top, 4 row lines and the bottom border expected, got \(rowLines.count)")
        // Column lines, met walking across a body row's top padding: only the border.
        let bodyY = (rowLines.dropFirst().first?.y ?? minY) + 3
        let columnLines = crossings(stride(from: minX, through: maxX, by: step).map { CGPoint(x: $0, y: bodyY) })
        #expect(columnLines.count == 2, "only the outer border expected, got \(columnLines.count)")
        // Each line runs the table's full height or width, through the wrapped row.
        for line in columnLines {
            let x = line.x + step / 2
            let gaps = stride(from: minY + inset, through: maxY - inset, by: step).filter { !dark(x, $0) }
            #expect(gaps.isEmpty, "the border at \(x) is broken at \(gaps.prefix(3))")
        }
        for line in rowLines.dropFirst() {
            let y = line.y + step / 2
            let gaps = stride(from: minX + inset, through: maxX - inset, by: step).filter { !dark($0, y) }
            #expect(gaps.isEmpty, "the row line at \(y) is broken at \(gaps.prefix(3))")
        }
    }

    // MARK: 5. Streaming does not rebuild or re-lay out

    /// While a reply streams below it, a finished reply's table keeps its views,
    /// frames and single layout; the streaming table keeps the cells it has.
    @Test func streamingLeavesFinishedTablesAndCompletedCellsAlone() throws {
        let finished = TranscriptItem(id: "old", role: .assistant, text: "| Old | Table |\n|---|---|\n| kept | as is |")
        let chat = Chat(width: 770, style: NSScroller.preferredScrollerStyle, items: [finished])
        defer { chat.close() }
        func oldCells() -> [MarkdownSelectionTextView] {
            descendants(MarkdownSelectionTextView.self, in: chat.host).filter { ["Old", "Table", "kept", "as is"].contains($0.string) }
        }
        let before = oldCells()
        #expect(before.count == 4)
        let frames = before.map { $0.convert($0.bounds, to: chat.host) }
        let characters = Array(Self.reply)
        var end = 0
        var firstCell: MarkdownSelectionTextView?
        while end < characters.count {
            end = min(end + 6, characters.count)
            chat.show([finished, Self.reply(String(characters[..<end]), active: true)])
            let now = oldCells()
            #expect(now.count == 4 && zip(now, before).allSatisfy { $0 === $1 }, "the finished table was rebuilt at \(end)")
            #expect(now.map { $0.convert($0.bounds, to: chat.host) } == frames, "the finished table moved at \(end)")
            #expect(now.allSatisfy { $0.offscreenMeasurements == 0 && $0.layoutManagerCount == 1 })
            let header = descendants(MarkdownSelectionTextView.self, in: chat.host).first { $0.string == "项目" }
            if let firstCell, let header { #expect(header === firstCell, "the streaming table rebuilt a finished cell at \(end)") }
            if firstCell == nil { firstCell = header }
        }
        #expect(firstCell != nil)
    }
}

@MainActor
private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var result: [T] = []
    if let match = view as? T { result.append(match) }
    for child in view.subviews { result += descendants(type, in: child) }
    return result
}
