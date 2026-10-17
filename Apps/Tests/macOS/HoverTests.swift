import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

// Pointer feedback of the real sidebar controls (`SidebarControls.swift`, `Hover.swift`),
// hosted in an `NSHostingView` in a window and checked in its rendered pixels.
//
// The pointer is driven the way AppKit drives it: every tracking area under the point
// gets an enter event carrying that area (its `trackingNumber` is the area, so
// `event.trackingArea` is that area), sent to the area's owner, then a mouse-moved
// event, and an exit when the pointer leaves it. SwiftUI's `onHover` listens to
// exactly these. A hosting view can have several areas under one point (a `.help`
// tooltip adds its own), in no fixed order, so all of them get the events, not just
// one. Plain `mouseMoved` events without the enter change nothing, and `@State` is
// never touched from here.

/// The test process is never the active app, so its windows are never key, and AppKit
/// hands a first click in a non-key window only to views that accept first mouse (a
/// table doesn't). This window counts as key, so clicks reach the List as in the app.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    /// Stays where it is put, off every screen (AppKit pulls a titled window's top back on).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class HostWindow {
    let window: NSWindow
    let host: NSView
    /// The tracking areas the pointer is in, with the view each belongs to.
    private var hovered: [(view: NSView, area: NSTrackingArea)] = []

    /// The host's own coordinates, for frames measured in SwiftUI (`.global` is the
    /// window's, titlebar included).
    nonisolated static let space = "host"

    init(size: CGSize, dark: Bool = false, @ViewBuilder content: () -> some View) {
        // On the built-in display, away from the screens in use. SwiftUI's `onHover` areas
        // take the cursor's real position when they are installed, whatever the events,
        // so keep the real pointer off that display while these run.
        window = KeyWindow(contentRect: .testArea(size),
                           styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Opaque, so an empty pixel reads as white (black in dark mode) rather than
        // transparent black.
        host = NSHostingView(rootView: content()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(dark ? Color.black : Color.white)
            .coordinateSpace(.named(Self.space)))
        window.contentView = host
        // No real mouse event reaches the test either. The synthetic events below are
        // delivered to the areas' owners and views directly, so they still arrive.
        window.ignoresMouseEvents = true
        window.showInTestArea()
        settle()
    }

    deinit {
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    func settle() {
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// `point` in the host's (top-left) coordinates.
    func windowPoint(_ point: CGPoint) -> NSPoint { host.convert(point, to: nil) }

    // MARK: Pointer

    func movePointer(to point: CGPoint) {
        let location = windowPoint(point)
        // Every enter/exit area under the point, on the hit view and its ancestors.
        var under: [(view: NSView, area: NSTrackingArea)] = []
        var view = window.contentView?.superview?.hitTest(location)
        while let candidate = view {
            under += areas(of: candidate, at: location).map { (candidate, $0) }
            view = candidate.superview
        }
        guard !under.isEmpty else {
            Issue.record("No tracking area under \(point)")
            return
        }
        for old in hovered where !under.contains(where: { $0.area === old.area }) {
            send(.mouseExited, old.area, from: old.view, at: location)
        }
        for new in under where !hovered.contains(where: { $0.area === new.area }) {
            send(.mouseEntered, new.area, from: new.view, at: location)
        }
        hovered = under
        let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        // Each owner of an area under the point that asked for moves gets one.
        var owners: [NSObject] = []
        for entry in under where entry.area.options.contains(.mouseMoved) {
            guard let owner = entry.area.owner as? NSObject, !owners.contains(where: { $0 === owner }) else { continue }
            owners.append(owner)
        }
        for owner in owners { deliver(#selector(NSResponder.mouseMoved(with:)), moved, to: owner) }
        settle()
    }

    /// The pointer leaves the window.
    func pointerLeaves() {
        for old in hovered { send(.mouseExited, old.area, from: old.view, at: NSPoint(x: -50, y: -50)) }
        hovered = []
        settle()
    }

    private func areas(of view: NSView, at location: NSPoint) -> [NSTrackingArea] {
        let local = view.convert(location, from: nil)
        return view.trackingAreas.filter { $0.options.contains(.mouseEnteredAndExited) && $0.rect.contains(local) }
    }

    /// AppKit sends an area's events to the area's owner, which need not be the view
    /// (a `.help` tooltip's area belongs to a SwiftUI bridge object).
    private func deliver(_ selector: Selector, _ event: NSEvent, to owner: NSObject) {
        if owner.responds(to: selector) { owner.perform(selector, with: event) }
    }

    private func send(_ type: NSEvent.EventType, _ area: NSTrackingArea, from view: NSView, at location: NSPoint) {
        let event = NSEvent.enterExitEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil)!
        #expect(event.trackingArea === area)
        guard let owner = area.owner as? NSObject ?? Optional(view) else { return }
        deliver(type == .mouseEntered ? #selector(NSResponder.mouseEntered(with:)) : #selector(NSResponder.mouseExited(with:)),
                event, to: owner)
    }

    /// A click on the view under `point`, as `NSWindow.sendEvent` delivers it in an active
    /// app (the test app never is, and the window would swallow a first click). A table
    /// tracks the press in its own loop (`nextEvent(matching:)`), so the release is queued
    /// first; if nothing took it from the queue, it goes to the view, as for SwiftUI buttons.
    func click(at point: CGPoint) {
        let location = windowPoint(point)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        guard let target = window.contentView?.superview?.hitTest(location) else {
            Issue.record("Nothing to click at \(point)")
            return
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        target.mouseDown(with: event(.leftMouseDown))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true) {
            target.mouseUp(with: release)
        }
        settle()
    }

    // MARK: Pixels

    func snapshot() -> NSBitmapImageRep {
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Mean brightness of `rect` (host coordinates): 1 is white.
    func brightness(of rect: CGRect, in rep: NSBitmapImageRep) -> Double {
        let scale = Double(rep.pixelsWide) / host.bounds.width
        var sum = 0.0
        var count = 0.0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                sum += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        return sum / max(count, 1)
    }

    func brightness(of rect: CGRect) -> Double { brightness(of: rect, in: snapshot()) }

    /// The darkest pixel in `rect`: thin strokes (a chevron) barely move the mean.
    func darkest(in rect: CGRect, of rep: NSBitmapImageRep) -> Double {
        let scale = Double(rep.pixelsWide) / host.bounds.width
        var darkest = 1.0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                darkest = min(darkest, (color.redComponent + color.greenComponent + color.blueComponent) / 3)
            }
        }
        return darkest
    }

    /// The brightest pixel in `rect`: a light glyph on a dark background.
    func brightest(in rect: CGRect, of rep: NSBitmapImageRep) -> Double {
        let scale = Double(rep.pixelsWide) / host.bounds.width
        var brightest = 0.0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                brightest = max(brightest, (color.redComponent + color.greenComponent + color.blueComponent) / 3)
            }
        }
        return brightest
    }

    // MARK: Views

    func subviews<T: NSView>(of type: T.Type, in view: NSView? = nil) -> [T] {
        let root = view ?? host
        return root.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + root.subviews.flatMap { subviews(of: type, in: $0) }
    }

    /// Row `index` of the window's List, in host coordinates.
    func rowRect(_ index: Int) throws -> CGRect {
        let table = try #require(subviews(of: NSTableView.self).first)
        return table.convert(table.rect(ofRow: index), to: host)
    }

    func selectedRows() -> IndexSet { subviews(of: NSTableView.self).first?.selectedRowIndexes ?? [] }
}

/// A fill this strong or stronger counts as "drawn" (`Hover.fill` is 6 % of black on white).
private let visible = 0.02

private let bots = [
    Bot(profile: ProfileRow(name: "default", isDefault: true)),
    Bot(profile: ProfileRow(name: "coder")),
]

private func entries(_ count: Int) -> [HistoryEntry] {
    (0..<count).map { HistoryEntry(profile: "default", summary: SessionSummary(id: "s\($0)", title: "Chat \($0)")) }
}

@MainActor
@Suite(.serialized) struct HoverTests {
    // MARK: Rows

    /// Table rows of `Sidebar`: the "Sessions" header, then the sessions.
    private let firstSessionRow = 1

    /// The real session list's arrangement on macOS: the List (New chat is in the title bar).
    private struct Sidebar: View {
        @State var selection: String?
        var sessions = 3
        /// Forced, so the tests don't depend on the Mac's "Sidebar icon size" setting.
        var rowSize = SidebarRowSize.medium
        var onSelection: (String?) -> Void = { _ in }

        var body: some View {
            List(selection: $selection) {
                Section("Sessions") {
                    ForEach(entries(sessions)) { entry in
                        HistoryRow(entry: entry) {
                            Button("Pin") {}
                        }
                            .sidebarRowHover(isSelected: selection == entry.id)
                            .tag(entry.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, new in onSelection(new) }
            .environment(\.sidebarRowSize, rowSize)
        }
    }

    /// A session row's "…" button sits at the row's trailing edge, past its text.
    @Test func sessionRowHasItsMoreButtonAtTheTrailingEdge() throws {
        let ui = HostWindow(size: CGSize(width: 280, height: 300)) { Sidebar() }
        let row = try ui.rowRect(firstSessionRow)
        let shot = ui.snapshot()
        let trailing = CGRect(x: row.maxX - 44, y: row.minY + 4, width: 34, height: row.height - 8)
        let gap = CGRect(x: row.maxX - 110, y: row.minY + 4, width: 50, height: row.height - 8)  // "Chat 0" is short
        #expect(ui.darkest(in: trailing, of: shot) < 0.75)
        #expect(ui.darkest(in: gap, of: shot) > 0.9)
    }

    /// In dark mode the "…" is light, like the row's secondary text, not black.
    @Test func sessionRowMoreButtonIsLightInDarkMode() throws {
        let ui = HostWindow(size: CGSize(width: 280, height: 300), dark: true) { Sidebar() }
        let row = try ui.rowRect(firstSessionRow)
        let shot = ui.snapshot()
        let trailing = CGRect(x: row.maxX - 44, y: row.minY + 4, width: 34, height: row.height - 8)
        #expect(ui.brightest(in: trailing, of: shot) > 0.4, "the \"…\" is dark on a dark background")
    }

    /// Hover fills the whole row, inset from the List's edges like the selection, also
    /// where the pointer is between the row's lines; it goes when the pointer leaves.
    @Test func rowHoverFillsTheRowInsetFromTheEdges() throws {
        let ui = HostWindow(size: CGSize(width: 280, height: 300)) { Sidebar() }
        let row = try ui.rowRect(firstSessionRow)
        let inside = CGRect(x: Hover.rowInset + 2, y: row.minY + 1, width: 3, height: 3)  // a corner, past the text
        let outside = CGRect(x: 2, y: row.midY - 2, width: 4, height: 4)  // the inset margin
        let before = ui.snapshot()

        ui.movePointer(to: CGPoint(x: row.maxX - 30, y: row.minY + 3))  // right of the text, at the row's top
        let hovered = ui.snapshot()
        #expect(ui.brightness(of: inside, in: before) - ui.brightness(of: inside, in: hovered) > visible)
        #expect(abs(ui.brightness(of: outside, in: before) - ui.brightness(of: outside, in: hovered)) < 0.005)

        // To the next row: this one clears, that one fills.
        let next = try ui.rowRect(firstSessionRow + 1)
        ui.movePointer(to: CGPoint(x: next.midX, y: next.midY))
        let moved = ui.snapshot()
        #expect(abs(ui.brightness(of: inside, in: before) - ui.brightness(of: inside, in: moved)) < 0.005)
        let nextInside = inside.offsetBy(dx: 0, dy: next.minY - row.minY)
        #expect(ui.brightness(of: nextInside, in: before) - ui.brightness(of: nextInside, in: moved) > visible)

        ui.pointerLeaves()
        #expect(abs(ui.brightness(of: nextInside, in: before) - ui.brightness(of: nextInside)) < 0.005)
    }

    /// Hover is visual only: a click on a hovered row still selects it.
    @Test func hoverLeavesClicksAndSelectionAlone() throws {
        var selections: [String?] = []
        let ui = HostWindow(size: CGSize(width: 280, height: 300)) {
            Sidebar(onSelection: { selections.append($0) })
        }
        let session = try ui.rowRect(firstSessionRow)
        ui.movePointer(to: CGPoint(x: session.midX, y: session.midY))
        ui.click(at: CGPoint(x: session.midX, y: session.midY))
        #expect(selections == ["default/s0"])
        #expect(ui.selectedRows() == [firstSessionRow])
    }

    // MARK: Buttons

    @Test func hoverButtonStyleFillsOnlyWhileEnabled() {
        for enabled in [true, false] {
            let ui = HostWindow(size: CGSize(width: 120, height: 60)) {
                Button("Dismiss", systemImage: "xmark") {}
                    .labelStyle(.iconOnly)
                    .hoverButtonStyle(.rounded, padding: 8)
                    .disabled(!enabled)
            }
            let edge = CGRect(x: 1, y: 6, width: 4, height: 4)  // inside the padding, off the icon
            let before = ui.brightness(of: edge)
            ui.movePointer(to: CGPoint(x: 12, y: 12))
            let drop = before - ui.brightness(of: edge)
            if enabled {
                #expect(drop > visible)
            } else {
                #expect(abs(drop) < 0.005)
            }
        }
    }

    // MARK: Profile rail

    /// A rail item is its avatar alone (the name is the tooltip), and the selected one has
    /// the pill on its leading edge, level with the avatar.
    @Test func railItemFitsTheRailAndShowsTheSelection() {
        let bot = bots[1]
        let height = ProfileRailItem.avatarSize + 2 * ProfileRailItem.verticalPadding
        for selected in [false, true] {
            let item = ProfileRailItem(bot: bot, activity: .idle, isSelected: selected) {}
            let size = NSHostingView(rootView: item.frame(width: ProfileRailItem.width)).fittingSize
            #expect(abs(size.height - height) < 1, "the item is taller than its avatar")
            // Pinned top-left; below it, the window's white.
            let ui = HostWindow(size: CGSize(width: ProfileRailItem.width, height: height + 20)) {
                item.frame(width: ProfileRailItem.width)
            }
            ui.settle()  // the selection animates in
            let middle = ProfileRailItem.verticalPadding + ProfileRailItem.avatarSize / 2
            let pill = CGRect(x: 0.5, y: middle - 6, width: 3, height: 12)
            let drop = ui.brightness(of: CGRect(x: 0, y: height + 14, width: 4, height: 2)) - ui.brightness(of: pill)
            if selected {
                #expect(drop > visible, "no selection pill")
            } else {
                #expect(abs(drop) < 0.005, "an unselected item shows the pill")
            }
        }
    }
}

// MARK: - Message action bar

@MainActor
@Suite(.serialized) struct MessageActionBarHoverTests {
    @MainActor private final class Frames { var rows: [String: CGRect] = [:] }

    /// The rows in transcript order, with the newest message chosen as `ChatView` does.
    private func transcript(_ items: [TranscriptItem], frames: Frames) -> some View {
        let newestID = ConversationMarkdown.newestMessageID(in: items)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                Group {
                    switch item.role {
                    case .assistant:
                        MessageHoverArea { hovering in
                            AssistantMessageContent(item: item, isHovering: hovering, isNewest: item.id == newestID) {}
                        }
                    case .tool:
                        ToolMessageContent(item: item)
                    default:
                        Text(item.text)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HostWindow.space)) } action: {
                    frames.rows[item.id] = $0
                }
            }
        }
        .padding(16)
    }

    /// The Copy button's square at the leading end of a row's action bar.
    private func copyButton(of row: CGRect) -> CGRect {
        CGRect(x: row.minX, y: row.maxY - 26, width: 26, height: 26)
    }

    private func barShown(_ ui: HostWindow, _ row: CGRect) -> Bool {
        ui.darkest(in: copyButton(of: row).insetBy(dx: 4, dy: 4), of: ui.snapshot()) < 0.6
    }

    /// From the text, down across the bar's empty stretch and the strip just
    /// above Copy, the bar of an older reply stays shown the whole way.
    @Test func olderReplysBarStaysWhileThePointerMovesOntoIt() throws {
        let frames = Frames()
        let older = TranscriptItem(id: "older", role: .assistant,
                                   text: "An older reply, long enough to run across most of the column width.")
        let newer = TranscriptItem(id: "newer", role: .assistant, text: "The newest reply.")
        let ui = HostWindow(size: CGSize(width: 520, height: 320)) { transcript([older, newer], frames: frames) }
        let row = try #require(frames.rows["older"])
        let button = copyButton(of: row)
        #expect(!barShown(ui, row), "an older reply's bar shows without hover")

        ui.movePointer(to: CGPoint(x: row.minX + 120, y: row.minY + 8))
        #expect(barShown(ui, row), "hovering the text does not show the bar")
        ui.movePointer(to: CGPoint(x: button.maxX + 100, y: button.midY))
        #expect(barShown(ui, row), "the bar hid in its empty stretch, 100 pt from Copy")
        ui.movePointer(to: CGPoint(x: button.midX, y: button.minY + 0.5))
        #expect(barShown(ui, row), "the bar hid 1 pt above Copy")
        ui.movePointer(to: CGPoint(x: button.midX, y: button.midY))
        #expect(barShown(ui, row), "the bar hid on Copy")
        // On to the next reply: the older one's bar hides again.
        let next = try #require(frames.rows["newer"])
        ui.movePointer(to: CGPoint(x: next.minX + 40, y: next.minY + 8))
        #expect(!barShown(ui, row), "the bar stays after the pointer moves to the next reply")
    }

    /// The newest message's bar shows without hover; a tool call after it has no
    /// bar and does not take the "newest" place.
    @Test func newestReplyKeepsItsBarWhileAToolRuns() throws {
        let frames = Frames()
        let older = TranscriptItem(id: "older", role: .assistant, text: "Earlier reply.")
        let reply = TranscriptItem(id: "reply", role: .assistant, text: "Latest reply.")
        var tool = TranscriptItem(id: "tool", role: .tool, text: "")
        tool.toolName = "search"
        tool.detail = "running"
        tool.isActive = true
        let ui = HostWindow(size: CGSize(width: 520, height: 320)) { transcript([older, reply, tool], frames: frames) }
        #expect(barShown(ui, try #require(frames.rows["reply"])))
        #expect(!barShown(ui, try #require(frames.rows["older"])))
        // The tool row is its one line: nothing is reserved under it (a hidden
        // bar would add 26 pt).
        let toolRow = try #require(frames.rows["tool"])
        #expect(toolRow.height < 24, "the tool row is \(toolRow.height) pt tall")
    }
}
