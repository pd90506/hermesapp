import AppKit
import HermesKit
import SwiftUI
import Testing

// The sidebar's Settings button and the settings sheet, in real windows: the hosting
// view bridges SwiftUI's `.toolbar` into the window's NSToolbar, and `.sheet` attaches a
// real sheet window.

@MainActor
@Suite(.serialized) struct SettingsToolbarTests {
    /// The settings state, as `AppModel` holds it.
    @Observable final class Model {
        var presentation: SettingsPresentation
        init(_ presentation: SettingsPresentation) { self.presentation = presentation }
    }

    /// `RootView`'s arrangement: the gear in the sidebar's toolbar, the settings sheet.
    private struct Root: View {
        @Bindable var model: Model

        var body: some View {
            NavigationSplitView {
                List { Text("Row") }
                    .toolbar { SettingsToolbarItem(presentation: $model.presentation) }
                    // The app's sidebar width: narrower, the toolbar overflows and hides the toggle.
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            } detail: {
                Text("Detail")
            }
            .sheet(isPresented: Binding(get: { model.presentation.isShown },
                                        set: { if !$0 { model.presentation.close() } })) {
                TextField("Server URL", text: .constant(""))
                    .padding()
                    .onParentWindowClick(isEnabled: model.presentation.isTransient) {
                        model.presentation.clickedOutside()
                    }
                    .frame(minWidth: 460, minHeight: 420)
            }
        }
    }

    /// Records the mouse-downs AppKit hands it, to tell a consumed click from a delivered one.
    final class RecordingWindow: NSWindow {
        var mouseDowns = 0
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown { mouseDowns += 1 }
            super.sendEvent(event)
        }
    }

    private func window(_ model: Model) -> RecordingWindow {
        let window = RecordingWindow(contentRect: .testArea(CGSize(width: 800, height: 500)),
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: Root(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.showInTestArea()
        settle()
        return window
    }

    private func settle() {
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    private func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

    // MARK: Gear

    /// The gear is the system toolbar button: its glass is a circle the size of the
    /// sidebar toggle's, not the 26 × 36 capsule round 2's custom button style made of it.
    /// Public API only: the toolbar items and `NSGlassEffectView`.
    @Test func gearIsTheSameGlassCircleAsTheSidebarToggle() throws {
        let window = window(Model(SettingsPresentation(hasServer: true)))
        defer { window.orderOut(nil) }
        let toggle = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar")
        }?.view?.frame.size, "no sidebar toggle in the toolbar")
        #expect(toggle.width == toggle.height)
        let frameView = try #require(window.contentView?.superview)
        // The toolbar items' own glass: small pieces, not the sidebar's or the bar's.
        let glass = views(in: frameView)
            .filter { $0 is NSGlassEffectView }
            .map { $0.convert($0.bounds, to: nil).size }
            .filter { $0.width < 80 && $0.height < 80 }
        #expect(glass.count == 2, "the gear and the sidebar toggle, side by side: \(glass)")
        #expect(glass.allSatisfy { $0 == toggle }, "\(glass) vs the toggle's \(toggle)")
    }

    // MARK: Sheet

    /// Tags each posted click, so the loop below knows when it came back out of the queue.
    private static var nextClickNumber = 7_000

    /// A mouse-down, put in the app's queue and run the way `NSApplication.run` does:
    /// taken with `nextEvent`, then given to `NSApp.sendEvent`, which runs the local
    /// monitors before the event goes to its window.
    ///
    /// The loop runs until this very click has been taken and sent (a generous
    /// deadline only guards against a hang), not for a fixed 0.1 s: under load the
    /// queue can hand it back later than that, and the click was then never sent.
    private func clickThroughTheEventLoop(in window: NSWindow, at point: NSPoint,
                                          sourceLocation: SourceLocation = #_sourceLocation) {
        Self.nextClickNumber += 1
        let number = Self.nextClickNumber
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                      clickCount: 1, pressure: 1)!
        NSApp.postEvent(down, atStart: false)
        var sent = false
        let deadline = Date().addingTimeInterval(10)
        while !sent, Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05),
                                              inMode: .default, dequeue: true) else { continue }
            NSApp.sendEvent(event)
            if event.type == .leftMouseDown, event.eventNumber == number { sent = true }
        }
        #expect(sent, "the posted click never came out of the event queue", sourceLocation: sourceLocation)
        // Whatever the click itself queued (a sheet's dismissal) runs too.
        while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05),
                                          inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        settle()
    }

    /// Opened from the gear, a click elsewhere in the window closes the sheet, and
    /// nothing under it gets that click.
    @Test func aClickInTheWindowClosesTheGearSettings() throws {
        let model = Model(SettingsPresentation(hasServer: true))
        let window = window(model)
        defer { window.orderOut(nil) }
        model.presentation.toggle()  // what the gear does
        settle()
        let sheet = try #require(window.attachedSheet, "no sheet")

        // A click inside the sheet (on its field) keeps it.
        clickThroughTheEventLoop(in: sheet, at: NSPoint(x: sheet.frame.width / 2, y: sheet.frame.height / 2))
        #expect(model.presentation.isTransient)
        #expect(window.attachedSheet != nil)

        // A click on the sidebar closes it, and is consumed: the window never gets it.
        clickThroughTheEventLoop(in: window, at: NSPoint(x: 60, y: 200))
        #expect(window.mouseDowns == 0, "the click reached the window under the sheet")
        #expect(model.presentation.mode == .hidden)
        #expect(window.attachedSheet == nil)

        // With the sheet gone, clicks reach the window again.
        clickThroughTheEventLoop(in: window, at: NSPoint(x: 60, y: 200))
        #expect(window.mouseDowns == 1)
    }

    /// The must-connect sheet stays: clicks in the window pass by it, as before.
    @Test func aClickInTheWindowLeavesTheRequiredSettings() throws {
        let model = Model(SettingsPresentation(hasServer: false))
        let window = window(model)
        defer { window.orderOut(nil) }
        #expect(window.attachedSheet != nil)

        clickThroughTheEventLoop(in: window, at: NSPoint(x: 60, y: 200))
        #expect(window.mouseDowns == 1)  // passed on to AppKit, which ignores it under a sheet
        #expect(model.presentation.isRequired)
        #expect(window.attachedSheet != nil)
        model.presentation.close()  // Done
        settle()
        #expect(window.attachedSheet == nil)
    }
}
