import XCTest
#if os(macOS)
import AppKit
#endif

/// Drives the real app against a live Hermes dashboard, in the `hermesapp-test`
/// profile. Compiled into both HermesMacUITests and HermesiOSUITests.
///
/// Skipped unless the runner gets `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`
/// (xcodebuild forwards `TEST_RUNNER_`-prefixed variables; `scripts/live-test.sh --ui`
/// sets them). The chats it creates are deleted by the script's sweep afterwards.
final class LiveChatUITests: XCTestCase {
    @MainActor
    private func launchApp(servers: Int = 1, motionScale: Double? = nil,
                           dropsSocketsInBackground: Bool = false,
                           reconnectNoticeDelay: Double? = nil) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/live-test.sh --ui)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = String(servers)
        // The app's animations this many times slower (`Motion`), to see them part way.
        if let motionScale { app.launchEnvironment["HERMES_UITEST_MOTION_SCALE"] = String(motionScale) }
        if dropsSocketsInBackground { app.launchEnvironment["HERMES_UITEST_DROP_IN_BACKGROUND"] = "1" }
        if let reconnectNoticeDelay {
            app.launchEnvironment["HERMES_UITEST_RECONNECT_NOTICE_DELAY"] = String(reconnectNoticeDelay)
        }
        app.launch()
        return app
    }

    #if os(iOS)
    /// A new chat gets its reply. On macOS `testEachProfileReturnsToItsLastChat` sends
    /// and waits for a reply the same way. The reply's Branch in New Chat opens a branch,
    /// which the list shows.
    @MainActor
    func testNewChatSendsAndShowsTheReply() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        #if os(iOS)
        // iPhone may start on the chat; the sidebar is one Back away.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)

        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        let marker = "PONG-\(Int.random(in: 1000...9999))"
        composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
        press(app.buttons["Send"].firstMatch)

        // The reply is exactly the marker, in a selectable text view (its value); the
        // prompt bubble holds more than the marker.
        let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
        let deadline = Date().addingTimeInterval(150)
        while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        if reply.count < 1 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "no reply"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")
        // The row under the reply: Copy, "…" (Branch in New Chat) and the time.
        let more = app.descendants(matching: .any).matching(identifier: "messageMoreMenu").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the reply's … menu")
        attach(app, "reply and its row")
        more.tap()
        let branch = app.buttons["Branch in New Chat"].firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 5), "Branch in the menu")
        attach(app, "the reply's menu")

        // The branch opens, and the list shows it.
        branch.tap()
        // Its title is the parent's next in lineage ("Title #2") once the parent has one,
        // else the gateway's own, so the screenshots show it rather than a title check.
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", marker)).firstMatch
            .waitForExistence(timeout: 30), "the branch holds the reply")
        attach(app, "the branch")
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 10), "back on the list")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach(app, "the branch in the list")
    }
    #endif

    /// A turn that runs tools and answers with a table, drawn in the three layers the user
    /// asked for: once the turn is done its work is one closed "Completed in …" line above
    /// the answer; opened, a group line ("Ran commands"); a group opened, a line per step
    /// ("Bash · echo alpha"); a step opened, its card in place, with its command and Copy.
    @MainActor
    func testTurnWorkOpensLayerByLayer() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)

        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        composer.typeText("Use the terminal tool twice, with no text between the calls: first run `echo alpha`, "
            + "then run `echo beta`. Then reply with only a Markdown table with the columns Command and Output, "
            + "one row per command.")
        press(app.buttons["Send"].firstMatch)

        let summary = app.buttons.matching(identifier: "turnWorkSummary").firstMatch
        let groups = app.buttons.matching(identifier: "workGroupRow")
        let steps = app.buttons.matching(identifier: "workStepRow")
        let settled = NSPredicate(format: "label BEGINSWITH 'Completed'")
        let deadline = Date().addingTimeInterval(180)
        var sawWorking = false
        while !(summary.exists && settled.evaluate(with: summary)), Date() < deadline {
            // While it works, the work is open one layer: its group lines, each the newest step's.
            if !sawWorking, summary.exists, summary.label.hasPrefix("Working"), groups.count > 0 {
                sawWorking = true
                attach(app, "working")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(sawWorking ? 1 : 0.2))
        }
        // The newest rows are read again once the turn ends; their times give the duration.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attach(app, "settled")
        XCTAssertTrue(settled.evaluate(with: summary), "the work's line says the turn completed, got \(summary.label)")
        XCTAssertEqual(groups.count, 0, "a settled turn's work is closed")

        press(summary)
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 10), "opened, the work shows its groups")
        let ran = groups.matching(NSPredicate(format: "label CONTAINS 'Ran commands'")).firstMatch
        XCTAssertTrue(ran.exists, "a group of commands reads \"Ran commands\", got \(groups.allElementsBoundByIndex.map(\.label))")
        attach(app, "work opened")

        press(ran)
        let opened = Date().addingTimeInterval(10)
        while steps.count < 2, Date() < opened { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertGreaterThanOrEqual(steps.count, 2, "each command has its step")
        let bash = steps.matching(NSPredicate(format: "label CONTAINS 'Bash'")).firstMatch
        XCTAssertTrue(bash.exists, "a command's step starts with Bash")
        attach(app, "group opened")

        // A step opens in place into its card: the command and a Copy button, no popover.
        press(bash)
        XCTAssertTrue(app.buttons.matching(identifier: "workStepCopy").firstMatch.waitForExistence(timeout: 5),
                      "the opened step shows its card")
        let command = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'echo' OR value BEGINSWITH 'echo'")).firstMatch
        XCTAssertTrue(command.exists, "the card shows the command")
        attach(app, "step opened")
        #if os(macOS)
        XCTAssertEqual(app.popovers.count, 0, "a step opens in place, not in a popover")
        #endif
    }

    #if os(macOS)
    /// The window's layout, all in one launch (each launch waits for the app to connect):
    /// with no chat open, then with a new chat, then the pinned Bot Chat opened. Each
    /// check is its own function below; a failed check doesn't stop the later ones.
    @MainActor
    func testSidebarAndTitleBarLayout() throws {
        continueAfterFailure = true
        XCUIDevice.shared.appearance = .light
        let app = try launchApp()
        defer { app.terminate() }
        let newChat = app.buttons["New chat"]
        try require(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let list = app.outlines.firstMatch
        try require(list.waitForExistence(timeout: 10), "the session list")
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        try require(rail.waitForExistence(timeout: 10), "the profile rail")

        checkProfileRailIsFixed(app, rail: rail)
        checkNewChatSitsAtTheSessionColumnsTrailingEdge(app, newChat: newChat, list: list)
        checkNewChatHoldsStill(app, newChat: newChat, "no chat")
        checkSessionListHeaderLooksTheSameUnderThePointer(app, newChat: newChat)
        checkFrameIsOneColourAroundThePanel(app, newChat: newChat, list: list, rail: rail, "no chat")
        checkCollapseButtonHidesTheProfiles(app, list: list, rail: rail)

        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        try require(XCTWaiter().wait(for: [enabled], timeout: 30) == .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews["composer"]
        try require(composer.waitForExistence(timeout: 30), "composer shown")

        checkNewChatHoldsStill(app, newChat: newChat, "a chat open")
        checkFrameIsOneColourAroundThePanel(app, newChat: newChat, list: list, rail: rail, "a chat open")
        checkHoveringTheTitleBarDoesNotShadeTheChat(app, composer: composer)
        checkAttachMenuHasNoPaste(app)

        try checkBotChatStaysPinnedAboveTheSessions(app, newChat: newChat, list: list)
    }

    /// The composer's `+` holds Choose Files… and no Paste: Command-V pastes images and
    /// files into the composer (user, 2026-10-19).
    @MainActor
    private func checkAttachMenuHasNoPaste(_ app: XCUIApplication) {
        // A menu button on the Mac.
        let plus = app.menuButtons["Attach"].firstMatch
        guard plus.waitForExistence(timeout: 5) else { return XCTFail("the composer's +") }
        press(plus)
        let files = app.menuItems["Choose Files…"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), "the + menu")
        let menu = app.menus.containing(NSPredicate(format: "title == %@", "Choose Files…")).firstMatch
        XCTAssertFalse(menu.menuItems["Paste"].exists, "no Paste in the + menu")
        attach(app, "the + menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Hiding the profile rail slides it out and the panel (session list and chat) with
    /// it, to the window's edge, and showing it slides both back: no jump straight to the
    /// end, and no frame where the panel's edge goes back the way it came (a flicker). The
    /// app's animations run 10 times slower here, so screenshots catch them part way; the
    /// frames are attached in order, with how far into the slide each was taken.
    @MainActor
    func testProfileRailSlidesWithThePanel() throws {
        continueAfterFailure = true
        XCUIDevice.shared.appearance = .light
        let app = try launchApp(motionScale: 10)
        defer { app.terminate() }
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        try require(rail.waitForExistence(timeout: 30), "the profile rail")
        let collapse = app.windows.firstMatch.buttons["collapseProfiles"]
        try require(collapse.waitForExistence(timeout: 10), "the collapse button")
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let shown = panelEdges(app, press: collapse, "hiding the profiles")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let hidden = panelEdges(app, press: collapse, "showing the profiles")
        for (name, edges, from, to) in [("hiding", shown, CGFloat(54), CGFloat(0)), ("showing", hidden, 0, 54)] {
            XCTAssertEqual(edges.first ?? -1, from, accuracy: 2, "\(name): the panel's edge before: \(edges)")
            XCTAssertEqual(edges.last ?? -1, to, accuracy: 2, "\(name): the panel's edge after: \(edges)")
            XCTAssertTrue(edges.contains { $0 > 6 && $0 < 48 }, "\(name): no frame part way, a jump: \(edges)")
            let steps = zip(edges, edges.dropFirst()).map { $1 - $0 }
            XCTAssertFalse(steps.contains { to < from ? $0 > 1 : $0 < -1 }, "\(name): the edge went back: \(edges)")
        }
    }

    /// Clicks `button`, then screenshots the window as fast as it can for the slowed
    /// slide and a little after: the panel's leading edge in each, in window points, the
    /// first from just before the click. Each screenshot is attached.
    @MainActor
    private func panelEdges(_ app: XCUIApplication, press button: XCUIElement, _ name: String) -> [CGFloat] {
        let window = app.windows.firstMatch
        let size = window.frame.size
        func edge(_ shot: XCUIScreenshot, _ label: String) -> CGFloat {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(name) \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
            return Self.panelEdge(in: shot.image, size: size)
        }
        var edges = [edge(window.screenshot(), "00 before")]
        let start = Date()
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        while Date().timeIntervalSince(start) < 4 {
            let shot = window.screenshot()
            let t = Date().timeIntervalSince(start)
            edges.append(edge(shot, String(format: "%02d at %d ms", edges.count, Int(t * 1000))))
        }
        return edges
    }

    /// The panel's leading edge in window points: along a line at mid-height (under the
    /// profiles, over the empty rail), the first pixel off the frame's colour, which the
    /// strip over the window shows at its middle.
    private static func panelEdge(in image: NSImage, size: CGSize) -> CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return -1 }
        let scale = CGFloat(width) / size.width
        // The bitmap's first row is the image's top row.
        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<3).map { Int(bytes[(y * width + x) * 4 + $0]) } }
        let frameColour = pixel(width / 2, Int(6 * scale))
        let row = min(height - 1, Int(size.height * 0.6 * scale))
        for x in 0..<min(width, Int(200 * scale)) where zip(pixel(x, row), frameColour).contains(where: { abs($0 - $1) > 6 }) {
            return CGFloat(x) / scale
        }
        return -1
    }

    /// Stops the test when a step the later checks need didn't happen.
    private func require(_ ok: Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        _ = try XCTUnwrap(ok ? true : nil, message, file: file, line: line)
    }

    /// The pointer over the title bar, or over the top of the chat, leaves the chat
    /// column alone. macOS 26 showed the window toolbar's background there: a band
    /// from the top of the window down to the first message, with a line under it
    /// (gray in dark mode; in the VM's light mode only the line shows). Needs a new
    /// chat open: one short line at the bottom, so the top of the chat column is empty.
    @MainActor
    private func checkHoveringTheTitleBarDoesNotShadeTheChat(_ app: XCUIApplication, composer: XCUIElement) {
        // Compared: a column of pixels from just under the title bar to the composer,
        // away from where the pointer goes.
        let window = app.windows.firstMatch
        let frame = window.frame
        let x = composer.frame.midX - frame.minX
        let column = (x: x + 120, from: CGFloat(56), to: composer.frame.minY - frame.minY - 16)
        func hover(_ y: CGFloat) {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - 120, dy: y)).hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        func pixels(_ name: String) -> [[UInt8]] {
            let shot = window.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return Self.pixels(of: shot.image, column: column, in: frame.size)
        }

        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let away = pixels("pointer on the composer")
        XCTAssertFalse(away.isEmpty, "read the chat column")
        hover(16)
        let titleBar = pixels("pointer on the title bar")
        hover(220)
        let top = pixels("pointer on the top of the chat")
        XCTAssertNil(Self.firstDifference(away, titleBar), "the title bar under the pointer shades the chat")
        XCTAssertNil(Self.firstDifference(away, top), "the top of the chat under the pointer shades it")
    }

    /// The session list's header (title bar, New chat) keeps one look: the same glass
    /// whether or not the pointer is over the title bar. macOS 26 showed the toolbar's
    /// glass only on hover (or with rows scrolled under it), so the header changed as
    /// the pointer crossed it.
    @MainActor
    private func checkSessionListHeaderLooksTheSameUnderThePointer(_ app: XCUIApplication, newChat: XCUIElement) {
        // From the top of the window to a little under the title bar, just left of New
        // chat (at the column's trailing edge), away from where the pointer goes.
        let window = app.windows.firstMatch
        let frame = window.frame
        let row = newChat.frame
        let column = (x: row.minX - 12 - frame.minX, from: CGFloat(4), to: row.maxY + 24 - frame.minY)
        func shot(_ name: String) -> [[UInt8]] {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let shot = window.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return Self.pixels(of: shot.image, column: column, in: frame.size)
        }

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).hover()
        let away = shot("pointer on the chat column")
        XCTAssertFalse(away.isEmpty, "read the session list's header")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.minX - 60 - frame.minX, dy: 16)).hover()
        let titleBar = shot("pointer on the session list's title bar")
        XCTAssertNil(Self.firstDifference(away, titleBar), "the header changes under the pointer")
    }

    /// New chat is in the session list's header at its trailing edge (where the rows'
    /// "…" are), under the window's strip, as Slack's compose button.
    @MainActor
    private func checkNewChatSitsAtTheSessionColumnsTrailingEdge(_ app: XCUIApplication, newChat: XCUIElement,
                                                                 list: XCUIElement) {
        let close = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists, "the window's close button")
        let button = newChat.frame, column = list.frame
        XCTAssertLessThanOrEqual(abs(button.maxX - (column.maxX - 10)), 6,
                                 "New chat ends at the column's trailing edge: \(button) in \(column)")
        XCTAssertGreaterThan(button.minY, close.frame.maxY, "New chat is under the window's strip: \(button)")
    }

    /// The collapse button sits after the window buttons, level with them, and hides the
    /// profile rail (as Slack's hides its workspaces), the session list moving to the
    /// window's edge; again, it shows the rail.
    @MainActor
    private func checkCollapseButtonHidesTheProfiles(_ app: XCUIApplication, list: XCUIElement, rail: XCUIElement) {
        let window = app.windows.firstMatch
        // The green button: full screen on macOS 26, zoom before.
        let fullScreen = window.buttons[XCUIIdentifierFullScreenWindow]
        let zoom = fullScreen.exists ? fullScreen : window.buttons[XCUIIdentifierZoomWindow]
        let collapse = window.buttons["collapseProfiles"]
        guard collapse.exists else { return XCTFail("the collapse button") }
        XCTAssertGreaterThan(collapse.frame.minX, zoom.frame.maxX, "after the window buttons: \(collapse.frame)")
        XCTAssertLessThan(collapse.frame.minX, zoom.frame.maxX + 30, "right after them: \(collapse.frame)")
        XCTAssertLessThanOrEqual(abs(collapse.frame.midY - zoom.frame.midY), 2, "level with them: \(collapse.frame)")
        let listX = list.frame.minX, width = list.frame.width
        press(collapse)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: rail)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the profile rail hides")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(list.exists, "the session list stays")
        XCTAssertLessThan(list.frame.minX, listX - 40, "the session list moves to the window's edge: \(list.frame)")
        XCTAssertEqual(list.frame.width, width, accuracy: 1, "at its width")
        attach(app, "profiles collapsed")
        press(collapse)
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "the profile rail shows again")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(list.frame.minX, listX, accuracy: 1, "the session list back beside it")
    }

    /// New chat holds still in the title bar, with a chat open and with none. It
    /// jittered back and forth when its title's measured start fed back into the title's
    /// width.
    @MainActor
    private func checkNewChatHoldsStill(_ app: XCUIApplication, newChat: XCUIElement, _ state: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        var frames: [CGRect] = []
        for _ in 0..<20 {
            frames.append(newChat.frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let xs = frames.map(\.minX)
        XCTAssertLessThanOrEqual((xs.max() ?? 0) - (xs.min() ?? 0), 0.5,
                                 "\(state): New chat moved while idle: \(xs)")
        attach(app, "New chat, \(state)")
    }

    /// The profile rail is one fixed width, and nothing in the menus hides it (a hidden
    /// rail had no way back). Dragging the split view's dividers isn't tested here:
    /// XCUI's synthesized drags don't move NSSplitView dividers in the VM, even on a
    /// build whose rail a person can drag.
    @MainActor
    private func checkProfileRailIsFixed(_ app: XCUIApplication, rail: XCUIElement) {
        XCTAssertEqual(rail.frame.width, 54, accuracy: 1, "the rail's width")
        for title in ["Hide Sidebar", "Show Sidebar", "Toggle Sidebar"] {
            XCTAssertFalse(app.menuBars.menuItems[title].exists, "the menus offer \(title)")
        }
        attach(app, "profile rail")
    }

    /// The frame, one deeper tint of the theme, runs along the top (the window buttons on
    /// it) and down the profile rail, around the panel with the session list and the
    /// chat's card, which stands apart from it.
    /// Nor does the pointer over the strip shade the chat (macOS 26 shaded the title bar
    /// under the pointer).
    @MainActor
    private func checkFrameIsOneColourAroundThePanel(_ app: XCUIApplication, newChat: XCUIElement,
                                                     list: XCUIElement, rail: XCUIElement, _ state: String) {
        let window = app.windows.firstMatch
        let frame = window.frame
        let close = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists, "the window's close button")
        XCTAssertLessThan(rail.frame.maxX, list.frame.minX + 2, "the rail is beside the list: \(rail.frame) \(list.frame)")
        XCTAssertLessThan(close.frame.maxY, newChat.frame.minY, "the window buttons are on the strip, over the panel")
        // Points away from any text or button: the strip over the rail and over the chat,
        // the rail low down, and the chat well under the strip.
        let railX = rail.frame.midX - frame.minX
        let chatX = list.frame.maxX + (frame.maxX - list.frame.maxX) * 0.75 - frame.minX
        func color(at x: CGFloat, _ y: CGFloat, in shot: XCUIScreenshot) -> [UInt8] {
            Self.pixels(of: shot.image, column: (x: x, from: y, to: y + 1), in: frame.size).first ?? []
        }
        func same(_ a: [UInt8], _ b: [UInt8], within: Int = 3) -> Bool {
            !a.isEmpty && a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= within }
        }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "window frame, \(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let stripOverRail = color(at: railX, 6, in: shot), stripOverChat = color(at: chatX, 6, in: shot)
        let railLow = color(at: railX, frame.height * 0.75, in: shot)
        let chat = color(at: chatX, 160, in: shot)
        XCTAssertTrue(same(stripOverRail, stripOverChat), "\(state): the strip is one colour: \(stripOverRail) \(stripOverChat)")
        XCTAssertTrue(same(stripOverRail, railLow), "\(state): the rail is the strip's colour: \(railLow) vs \(stripOverRail)")
        XCTAssertFalse(same(stripOverRail, chat), "\(state): the chat's card is set off from the chrome: \(chat)")
        // The pointer over the strip leaves it and the chat alone.
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: chatX, dy: 8)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let hovered = window.screenshot()
        XCTAssertTrue(same(color(at: chatX, 6, in: hovered), stripOverChat), "\(state): the strip changed under the pointer")
        XCTAssertTrue(same(color(at: chatX, 160, in: hovered), chat), "\(state): the chat changed under the pointer")
    }

    /// The Bot Chat is pinned above the session list: scrolling the list leaves it where
    /// it is, and a click opens it (it scrolled away with the sessions before).
    @MainActor
    private func checkBotChatStaysPinnedAboveTheSessions(_ app: XCUIApplication, newChat: XCUIElement,
                                                         list: XCUIElement) throws {
        let bot = app.descendants(matching: .any)["pinnedBotChat"].firstMatch
        try require(bot.waitForExistence(timeout: 30), "the pinned Bot Chat")
        XCTAssertLessThan(bot.frame.maxY, newChat.frame.maxY + 120, "the Bot Chat is at the top: \(bot.frame)")
        let before = bot.frame
        list.scroll(byDeltaX: 0, deltaY: -600)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "list scrolled")
        XCTAssertEqual(bot.frame, before, "the Bot Chat moved with the list")
        XCTAssertTrue(bot.isHittable, "the Bot Chat is still in reach")
        press(bot)
        // The new chat's composer was already there: wait for the window to show the
        // Bot Chat (titled by the bot) as selected instead.
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: bot)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 10), .completed, "the Bot Chat shows as selected")
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 30), "the Bot Chat opened")
        attach(app, "Bot Chat open")
    }

    /// The RGB of each pixel down a column of the screenshot, in window points
    /// (top-left origin).
    private static func pixels(of image: NSImage, column: (x: CGFloat, from: CGFloat, to: CGFloat),
                               in size: CGSize) -> [[UInt8]] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        // The bitmap's first row is the image's top row.
        let scale = CGFloat(width) / size.width
        let px = min(width - 1, Int(column.x * scale))
        return (Int(column.from * scale)..<min(height, Int(column.to * scale))).map { row in
            let i = (row * width + px) * 4
            return [bytes[i], bytes[i + 1], bytes[i + 2]]
        }
    }

    /// Where two columns first differ by more than rounding, as "row: before -> after".
    private static func firstDifference(_ a: [[UInt8]], _ b: [[UInt8]]) -> String? {
        guard a.count == b.count else { return "\(a.count) rows vs \(b.count)" }
        for (row, (p, q)) in zip(a, b).enumerated() where zip(p, q).contains(where: { abs(Int($0) - Int($1)) > 2 }) {
            return "row \(row): \(p) -> \(q)"
        }
        return nil
    }
    #endif

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    #if os(iOS)
    /// On iPhone the Bot Chat is the session list's first group, a row in the list that
    /// scrolls with the sessions (no longer pinned above it), and the list's header leads
    /// with the profile's avatar, as Slack's workspace icon. The avatar, or a swipe right
    /// on the list, opens the profiles in a drawer, as Slack's workspaces: a wide panel
    /// over the list, which stays where it is under a shade. Picking a profile or a tap on
    /// the shade closes it.
    /// The profiles' drawer slides in from the leading edge when the avatar is tapped and
    /// slides back out when the shade is tapped: no frame where it sits in place half
    /// faded, and no frame where its edge goes back the way it came. The app's animations
    /// run 10 times slower here, so screenshots catch them part way; the frames are
    /// attached in order, with how far into the slide each was taken.
    @MainActor
    func testProfileDrawerSlidesInAndOut() throws {
        continueAfterFailure = true
        XCUIDevice.shared.appearance = .light
        let app = try launchApp(motionScale: 10)
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        let avatar = app.buttons["profilesButton"].firstMatch
        guard avatar.waitForExistence(timeout: 30) else { return XCTFail("the profile's avatar") }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let screen = app.windows.firstMatch.frame.size
        let width = min((screen.width * 0.85).rounded(), 360)

        let opening = drawerShots(app, "opening the profiles") { avatar.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let closing = drawerShots(app, "closing the profiles") {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        }
        // The drawer's colour and the list's along a line under the status bar and over
        // the list's header, clear of the drawer's rounded corners and of the list's
        // cards (white, as the drawer): fully open and closed.
        let y: CGFloat = 44
        guard let closedShot = opening.first, let openShot = opening.last,
              let list = Self.rgb(closedShot, x: 20, y: y, in: screen),
              let drawer = Self.rgb(openShot, x: 20, y: y, in: screen) else { return XCTFail("read the screenshots") }
        XCTAssertTrue(Self.differ(list, drawer), "the drawer stands apart from the list: \(drawer) vs \(list)")
        for (name, shots, from, to) in [("opening", opening, CGFloat(0), width), ("closing", closing, width, 0)] {
            let edges = shots.map { Self.drawerEdge(in: $0, y: y, colour: drawer, size: screen) }
            XCTAssertEqual(edges.first ?? -1, from, accuracy: 8, "\(name): the drawer's edge before: \(edges)")
            // Within the glass's rim, which shades its last few points.
            XCTAssertEqual(edges.last ?? -1, to, accuracy: 8, "\(name): the drawer's edge after: \(edges)")
            XCTAssertTrue(edges.contains { $0 > 20 && $0 < width - 20 }, "\(name): no frame part way: \(edges)")
            let steps = zip(edges, edges.dropFirst()).map { $1 - $0 }
            XCTAssertFalse(steps.contains { to < from ? $0 > 2 : $0 < -2 }, "\(name): the edge went back: \(edges)")
        }
    }

    /// Screenshots the screen from just before `action` and as fast as it can for the
    /// slowed slide and a little after; each is attached.
    @MainActor
    private func drawerShots(_ app: XCUIApplication, _ name: String, action: () -> Void) -> [XCUIScreenshot] {
        func shot(_ label: String) -> XCUIScreenshot {
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(name) \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
            return shot
        }
        var shots = [shot("00 before")]
        let start = Date()
        action()
        while Date().timeIntervalSince(start) < 4.5 {
            let t = Date().timeIntervalSince(start)
            shots.append(shot(String(format: "%02d at %d ms", shots.count, Int(t * 1000))))
        }
        return shots
    }

    /// How far the drawer reaches across the screen, in points, along the line `y`: the
    /// first pixel from the leading edge off the drawer's `colour`.
    @MainActor
    private static func drawerEdge(in shot: XCUIScreenshot, y: CGFloat, colour: [Int], size: CGSize) -> CGFloat {
        guard let image = shot.image.cgImage else { return -1 }
        let scale = CGFloat(image.width) / size.width
        // The panel floats 8 pt in from the screen's edge (its glass, rim and all): from
        // where the colour was read, inside it, or nothing of it there yet.
        let start = Int(20 * scale)
        // The glass shows a little of the list and its shade through it, which change as
        // it slides: near its colour, not exactly it.
        func off(_ pixel: [Int]) -> Bool { zip(pixel, colour).contains { abs($0 - $1) > 20 } }
        guard let first = rgb(shot, x: 20, y: y, in: size) else { return -1 }
        if off(first) { return 0 }
        for px in start..<image.width {
            guard let pixel = rgb(shot, x: CGFloat(px) / scale, y: y, in: size) else { return -1 }
            if off(pixel) { return CGFloat(px) / scale }
        }
        return size.width
    }

    private static func differ(_ a: [Int], _ b: [Int]) -> Bool {
        zip(a, b).contains { abs($0 - $1) > 4 }
    }

    /// The RGB of the screenshot's pixel at a point (top-left origin).
    @MainActor
    private static func rgb(_ shot: XCUIScreenshot, x: CGFloat, y: CGFloat, in size: CGSize) -> [Int]? {
        guard let image = shot.image.cgImage else { return nil }
        let scale = CGFloat(image.width) / size.width
        let px = min(image.width - 1, Int(x * scale)), py = min(image.height - 1, Int(y * scale))
        guard let crop = image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? bytes.prefix(3).map(Int.init) : nil
    }

    @MainActor
    func testBotChatScrollsWithTheSessionsAndTheAvatarShowsProfiles() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no tabs")
        XCTAssertFalse(app.descendants(matching: .any)["pinnedBotChat"].exists, "no Bot Chat pinned above the list")
        let list = app.collectionViews.firstMatch
        let botChat = list.descendants(matching: .any)["botChatRow"].firstMatch
        XCTAssertTrue(botChat.waitForExistence(timeout: 30), "the Bot Chat is a row of the list")
        let sessionsTitle = list.staticTexts["Sessions"].firstMatch
        if sessionsTitle.exists {
            XCTAssertLessThan(botChat.frame.maxY, sessionsTitle.frame.minY + 1, "the Bot Chat above the sessions")
        }
        let avatar = app.buttons["profilesButton"].firstMatch
        XCTAssertTrue(avatar.exists, "the profile's avatar")
        XCTAssertLessThan(avatar.frame.minX, 40, "the avatar at the leading edge: \(avatar.frame)")
        XCTAssertEqual(avatar.frame.midY, newChat.frame.midY, accuracy: 4, "the avatar level with New chat")
        XCTAssertLessThan(avatar.frame.maxY, botChat.frame.minY, "the avatar above the list")
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        XCTAssertFalse(rail.exists, "the drawer is closed")
        let restingX = newChat.frame.minX
        let screen = app.windows.firstMatch.frame
        attach(app, "session list")

        // Scrolled, the Bot Chat goes up with the sessions (when there are enough of them
        // to scroll).
        let botY = botChat.frame.minY
        list.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if !botChat.exists || botChat.frame.minY < botY - 1 {
            attach(app, "scrolled")
        }
        list.swipeDown()
        XCTAssertTrue(eventually { botChat.exists && abs(botChat.frame.minY - botY) < 1 }, "back at the top")

        avatar.tap()
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "the avatar opens the drawer")
        XCTAssertTrue(eventually { abs(rail.frame.minX - 8) < 1 }, "the drawer floating 8 pt in from the screen's leading edge: \(rail.frame)")
        XCTAssertGreaterThan(rail.frame.width, screen.width * 0.7, "a wide drawer: \(rail.frame)")
        XCTAssertLessThan(rail.frame.width, screen.width - 30, "the list's edge shows beside it: \(rail.frame)")
        XCTAssertTrue(rail.staticTexts["Profiles"].exists, "titled Profiles")
        XCTAssertTrue(app.buttons["Settings"].exists, "Settings at the drawer's bottom")
        let picked = rail.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 10), "a profile is selected")
        XCTAssertGreaterThan(picked.frame.width, screen.width * 0.5, "a profile is a wide row: \(picked.frame)")
        attach(app, "profiles drawer")

        picked.tap()
        XCTAssertTrue(eventually { !rail.exists }, "picking a profile closes the drawer")
        XCTAssertEqual(newChat.frame.minX, restingX, accuracy: 1, "the list never moved")

        list.swipeRight()
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "a swipe right opens the drawer")
        XCTAssertTrue(eventually { abs(rail.frame.minX - 8) < 1 }, "fully open after the swipe: \(rail.frame)")
        // A tap on the shade, beside the drawer, closes it.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(eventually { !rail.exists }, "a tap beside the drawer closes it")

        // The Bot Chat opens like any session: pushed, and Back returns to the list.
        botChat.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 30), "the Bot Chat opened")
        attach(app, "Bot Chat open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(botChat.waitForExistence(timeout: 10), "Back returns to the list")
    }

    /// A swipe right that drifts up or down opens the profiles' drawer and leaves the
    /// session list where it was: the list no longer scrolls with the finger under the
    /// opening drawer (user, 2026-10-19).
    @MainActor
    func testSwipingTheDrawerOpenLeavesTheListStill() throws {
        continueAfterFailure = true
        let app = try launchApp()
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        let list = app.collectionViews.firstMatch
        let botChat = list.descendants(matching: .any)["botChatRow"].firstMatch
        XCTAssertTrue(botChat.waitForExistence(timeout: 30), "the session list")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let resting = botChat.frame
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        let window = app.windows.firstMatch
        // Right and a little up, slowly, so the list's own pan has the touch too.
        for (start, end) in [(CGVector(dx: 0.08, dy: 0.7), CGVector(dx: 0.9, dy: 0.58)),
                             (CGVector(dx: 0.08, dy: 0.4), CGVector(dx: 0.9, dy: 0.52))] {
            window.coordinate(withNormalizedOffset: start)
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: end),
                       withVelocity: 600, thenHoldForDuration: 0.1)
            XCTAssertTrue(rail.waitForExistence(timeout: 5), "the swipe opened the drawer")
            XCTAssertTrue(eventually { abs(rail.frame.minX - 8) < 1 }, "fully open: \(rail.frame)")
            attach(app, "drawer swiped open \(start.dy) to \(end.dy)")
            XCTAssertEqual(botChat.frame.minY, resting.minY, accuracy: 1, "the list stayed where it was")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
            XCTAssertTrue(eventually { !rail.exists }, "a tap beside the drawer closes it")
        }
    }

    /// Back from the background the chat stays on screen while the app reconnects, with
    /// no spinner over it: a reconnect within 5 s shows nothing, a longer one a spinner in
    /// the title bar (user, 2026-10-19). The app's socket is gone on its return, as a real
    /// iPhone's (`HERMES_UITEST_DROP_IN_BACKGROUND`), and the chat was opened from the list,
    /// so it is restored from Hermes's store, not replayed.
    @MainActor
    func testReturningFromTheBackgroundKeepsTheChatOnScreen() throws {
        try returnFromTheBackground(noticeDelay: nil)
    }

    /// The same with no quiet time: the reconnect shows in the title bar, under the
    /// chat's title, and the chat stays on screen.
    @MainActor
    func testAReconnectPastTheQuietTimeShowsInTheTitleBar() throws {
        try returnFromTheBackground(noticeDelay: 0)
    }

    @MainActor
    private func returnFromTheBackground(noticeDelay: Double?) throws {
        continueAfterFailure = true
        let app = try launchApp(dropsSocketsInBackground: true, reconnectNoticeDelay: noticeDelay)
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        newChat.tap()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        composer.tap()
        let marker = "PONG-\(Int.random(in: 1000...9999))"
        composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
        app.buttons["Send"].firstMatch.tap()
        let prompt = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                                          marker, marker)).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "the prompt in the chat")
        let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
        let deadline = Date().addingTimeInterval(150)
        while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        // Without a model key there is no reply; the prompt is the chat's content then.
        // Opened again from the list: a chat read, not one just written in.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.collectionViews.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the chat's row in the list")
        row.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "the chat opened again")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach(app, "00 before the background")

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        app.activate()
        let start = Date()
        var samples: [(ms: Int, prompt: Bool, spinner: Bool, reconnecting: Bool)] = []
        let reconnecting = app.descendants(matching: .any)["reconnectingIndicator"]
        while Date().timeIntervalSince(start) < (noticeDelay == nil ? 9 : 4) {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let inBar = reconnecting.exists && app.navigationBars.firstMatch.frame.contains(reconnecting.frame)
            let sample = (ms: ms, prompt: prompt.exists, spinner: app.activityIndicators.firstMatch.exists,
                          reconnecting: inBar)
            samples.append(sample)
            attach(app, String(format: "%02d back at %d ms%@%@", samples.count, ms,
                               sample.spinner ? ", spinner" : "", sample.reconnecting ? ", reconnecting" : ""))
        }
        let log = XCTAttachment(string: samples.map { "\($0.ms) ms: prompt \($0.prompt), spinner \($0.spinner), "
            + "reconnecting \($0.reconnecting)" }.joined(separator: "\n"))
        log.name = "back from the background, sampled"
        log.lifetime = .keepAlways
        add(log)
        XCTAssertTrue(samples.allSatisfy(\.prompt), "the chat stayed on screen: \(samples)")
        if noticeDelay == nil {
            XCTAssertFalse(samples.contains { $0.ms < 4500 && $0.reconnecting }, "nothing within 5 s: \(samples)")
        } else {
            XCTAssertTrue(samples.contains(where: \.reconnecting), "the title bar said so: \(samples)")
        }
        XCTAssertFalse(samples.contains { $0.spinner && !$0.reconnecting }, "no spinner but the title's: \(samples)")
        XCTAssertTrue(composer.exists, "still in the chat")
    }

    /// The session list has no Settings button of its own: the gear is the rail's, a
    /// Liquid Glass circle. Settings opens on Connections, Session Sources and
    /// Appearance, each a page of its own; Connections lists the servers, each with its
    /// own page.
    @MainActor
    func testSettingsOpensItsThreePages() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "connected, Sessions page shown")
        XCTAssertFalse(app.buttons["Settings"].exists, "no Settings button over the session list")

        app.buttons["profilesButton"].tap()
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "the gear under the profiles")
        XCTAssertTrue(eventually { gear.isHittable }, "the gear on screen")
        attach(app, "profiles with the glass gear")
        gear.tap()

        let connections = app.buttons["settings.connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 5), "Settings lists Connections")
        XCTAssertTrue(app.buttons["settings.sessionSources"].exists, "Settings lists Session Sources")
        XCTAssertTrue(app.buttons["settings.appearance"].exists, "Settings lists Appearance")
        XCTAssertTrue(app.navigationBars["Settings"].exists, "titled Settings")
        attach(app, "settings")

        connections.tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5), "Connections opens")
        XCTAssertTrue(app.buttons["Add Server"].exists, "Connections has Add Server")
        attach(app, "settings: connections")
        app.buttons["serverRow"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Check Server"].waitForExistence(timeout: 5), "a server opens its own page")
        attach(app, "settings: a server")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let sources = app.buttons["settings.sessionSources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.tap()
        XCTAssertTrue(app.navigationBars["Session Sources"].waitForExistence(timeout: 5), "Session Sources opens")
        attach(app, "settings: session sources")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5), "Appearance opens")
        attach(app, "settings: appearance")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(connections.waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(eventually { !connections.exists }, "Close closes the settings")
    }

    /// On iPhone, picking a profile shows its sessions, never its last chat: the chat
    /// stays a tap away (on the Mac and iPad, where the chat is always beside the list,
    /// the profile's last chat comes back).
    @MainActor
    func testPickingAProfileStaysOnItsSessions() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        let newChat = app.buttons["New chat"]
        if !newChat.waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")

        // The profile's Bot Chat, so it is the chat the profile showed last.
        let botChat = app.descendants(matching: .any)["botChatRow"].firstMatch
        XCTAssertTrue(botChat.waitForExistence(timeout: 30), "the session list")
        botChat.tap()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the Bot Chat opens")
        back.tap()
        XCTAssertTrue(newChat.waitForExistence(timeout: 10), "back on the sessions")

        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        app.buttons["profilesButton"].tap()
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "the avatar opens the profiles' drawer")
        let picked = rail.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 10), "a profile is selected")
        let others = rail.buttons.matching(NSPredicate(
            format: "isSelected == false AND identifier != 'settingsButton' AND NOT (label BEGINSWITH 'Avatar options')"))
        guard others.count > 0 else { throw XCTSkip("Only one profile in the VM's Hermes") }
        let pickedLabel = picked.label
        others.firstMatch.tap()
        XCTAssertTrue(eventually { !rail.exists }, "picking a profile closes the drawer")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(composer.exists, "another profile shows its sessions, not a chat")
        XCTAssertTrue(newChat.exists, "the session list stays")

        app.buttons["profilesButton"].tap()
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        rail.buttons[pickedLabel].firstMatch.tap()
        XCTAssertTrue(eventually { !rail.exists }, "picking a profile closes the drawer")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(composer.exists, "back on the first profile: its sessions, not its Bot Chat")
        XCTAssertTrue(newChat.exists, "the session list stays")
        attach(app, "profile picked: its sessions")
    }

    /// Polls a condition that settles after an animation.
    @MainActor
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }

    /// Two servers (the same dashboard twice): both connect, each on its own socket,
    /// and the sidebar names the server it lists. On macOS
    /// `testEachProfileReturnsToItsLastChat` starts with both servers connected.
    @MainActor
    func testTwoServersConnectAndAreNamed() throws {
        continueAfterFailure = false
        let app = try launchApp(servers: 2)
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        // The list has no connection footer (user, 2026-10-19): the profiles' drawer says
        // each server's status in its section's title.
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "the session list")
        app.buttons["profilesButton"].firstMatch.tap()
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "the drawer opened")
        let connected = ["Test 1", "Test 2"].map { name in
            XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true"),
                object: app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", "\(name): Connected")).firstMatch)
        }
        if XCTWaiter().wait(for: connected, timeout: 60) != .completed {
            attach(app, "not both connected")
            XCTFail("both servers connected")
        }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(eventually { !rail.exists }, "the drawer closed")
        XCTAssertTrue(waitForText(in: app, "Test 1", timeout: 10), "the Sessions list is headed by its server")
        let newChat = app.buttons["New chat"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
    }
    #endif

    #if os(macOS)
    /// Each profile shows the chat it showed last: a session it was left on, else its
    /// Bot Chat. Two servers list the same profile, so the test never leaves
    /// `hermesapp-test`; each server's copy keeps its own record.
    @MainActor
    func testEachProfileReturnsToItsLastChat() throws {
        continueAfterFailure = false
        let app = try launchApp(servers: 2)
        defer { app.terminate() }
        let connected = ["Test 1", "Test 2"].map { name in
            XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true"),
                object: app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ AND value == %@", name, "Connected")).firstMatch)
        }
        XCTAssertEqual(XCTWaiter().wait(for: connected, timeout: 60), .completed, "both servers connected")
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "the profile rail")
        // The test profile, selected on Test 1; the same profile on Test 2 is listed after it.
        let picked = rail.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 30), "a profile is selected")
        let name = picked.label
        let profiles = rail.buttons.matching(NSPredicate(format: "label == %@", name))
        XCTAssertEqual(profiles.count, 2, "the test profile on both servers")

        // Test 1: a new side chat, with a message in it: a chat nobody wrote in isn't
        // in the session list, so there is nothing to go back to.
        let newChat = app.buttons["New chat"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        let marker = "PONG-\(Int.random(in: 1000...9999))"
        composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
        press(app.buttons["Send"].firstMatch)
        let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
        let deadline = Date().addingTimeInterval(150)
        while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")
        // A side chat is titled "<title> · <bot>"; its title can change after the reply.
        let window = app.windows.firstMatch
        let isSideChat: (String) -> Bool = { $0.hasSuffix(" · \(name)") }
        XCTAssertNotNil(waitForTitle(of: window, timeout: 30, isSideChat), "the side chat is on screen: \(window.title)")
        attach(app, "Test 1: side chat")

        // Test 2 has no record: its Bot Chat, titled by the bot.
        press(profiles.element(boundBy: 1))
        XCTAssertNotNil(waitForTitle(of: window, timeout: 30) { $0 == name }, "Test 2 shows its Bot Chat: \(window.title)")
        attach(app, "Test 2: Bot Chat")

        // Back on Test 1: the side chat again, not the Bot Chat just shown.
        press(profiles.element(boundBy: 0))
        XCTAssertNotNil(waitForTitle(of: window, timeout: 30, isSideChat), "Test 1 shows its side chat again: \(window.title)")
        attach(app, "Test 1: side chat again")

        // And Test 2 its Bot Chat.
        press(profiles.element(boundBy: 1))
        XCTAssertNotNil(waitForTitle(of: window, timeout: 30) { $0 == name }, "Test 2 shows its Bot Chat again: \(window.title)")
    }

    /// What was typed in a New chat, not sent, is still there after another chat was
    /// shown: New chat goes back to the same chat. The pinned Bot Chat has no avatar (the
    /// rail shows it) and no New Side Chat in its context menu.
    @MainActor
    func testNewChatKeepsItsDraftAndBotChatIsPlain() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
        let app = try launchApp()
        defer { app.terminate() }
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        let bot = app.descendants(matching: .any)["pinnedBotChat"].firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 30), "the pinned Bot Chat")

        press(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        let draft = "draft \(Int.random(in: 1000...9999)) kept"
        composer.typeText(draft)
        attach(app, "New chat with a draft")

        press(bot)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: bot)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 10), .completed, "the Bot Chat shows as selected")
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", draft),
                                                 object: app.textViews["composer"].firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [switched], timeout: 30), .completed, "the Bot Chat's own composer")

        press(newChat)
        let kept = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", draft),
                                             object: app.textViews["composer"].firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [kept], timeout: 30), .completed,
                       "the draft came back: \(String(describing: app.textViews["composer"].firstMatch.value))")
        attach(app, "New chat again, draft kept")

        bot.rightClick()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.menuItems["New Side Chat"].exists, "the Bot Chat's context menu offers New Side Chat")
        app.typeKey(.escape, modifierFlags: [])

        // The divider under the Bot Chat is the same with the pointer away and over it:
        // the system drew a second line across the column only under the pointer. Read
        // down a column of pixels near the list's leading edge, outside the Bot Chat's
        // own (inset) divider and its hover fill, from the row's bottom into the Sessions
        // header.
        let window = app.windows.firstMatch
        let frame = window.frame
        let list = app.outlines.firstMatch
        let column = (x: list.frame.minX + 5 - frame.minX, from: bot.frame.maxY - frame.minY,
                      to: bot.frame.maxY + 24 - frame.minY)
        func edge(_ name: String) -> [[UInt8]] {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let shot = window.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return Self.pixels(of: shot.image, column: column, in: frame.size)
        }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).hover()
        let away = edge("sidebar, pointer away")
        XCTAssertFalse(away.isEmpty, "read the sidebar")
        bot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let over = edge("sidebar, pointer on the Bot Chat")
        XCTAssertNil(Self.firstDifference(away, over), "a line shows under the Bot Chat only under the pointer")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).hover()
        XCUIDevice.shared.appearance = .dark
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attach(app, "sidebar, dark")
        XCUIDevice.shared.appearance = .light
    }

    /// A selected session row and the hovered row under it keep a gap between their two
    /// shades: the hover stopped at the row's edge, right against the selection. Checked
    /// in the real window, where the selection is drawn, down a column of pixels through
    /// both fills (past their rounded corners, which would read as a gap), against the
    /// bare sidebar just outside them. Writes in chats until the list has two sessions.
    @MainActor
    func testSelectedAndHoveredSessionRowsStayApart() throws {
        continueAfterFailure = false
        // Dark, as the user saw it: a gray selection over a lighter hover, touching.
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        let app = try launchApp()
        defer { app.terminate() }
        let (list, rows) = try twoSessionRows(app)
        let selected = rows[0], hovered = rows[1]
        press(selected)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        hovered.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let window = app.windows.firstMatch
        let frame = window.frame
        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "selected row above a hovered row"
        attachment.lifetime = .keepAlways
        add(attachment)

        // The fills start 10 pt in from the list's edge (`Hover.rowInset`), with 8 pt corners.
        // Text there only adds shade, so it can't fake a gap.
        let from = selected.frame.minY - frame.minY, to = hovered.frame.maxY - frame.minY
        let fills = Self.pixels(of: shot.image, column: (x: list.frame.minX + 24 - frame.minX, from: from, to: to),
                                in: frame.size)
        let bare = Self.pixels(of: shot.image, column: (x: list.frame.minX + 4 - frame.minX, from: from, to: to),
                               in: frame.size)
        XCTAssertFalse(fills.isEmpty, "read the rows")
        let shaded = zip(fills, bare).map { p, q in zip(p, q).contains { abs(Int($0) - Int($1)) > 3 } }
        // Pixels down from the selection's top: the selection, the gap, the hover.
        let scale = CGFloat(fills.count) / (to - from)
        let boundary = Int((hovered.frame.minY - selected.frame.minY) * scale)
        let span = max(0, boundary - Int(6 * scale))..<min(shaded.count, boundary + Int(6 * scale))
        let around = shaded[span].map { $0 ? "#" : "." }.joined()
        XCTAssertTrue(shaded[..<boundary].contains(true), "the selected row is shaded")
        XCTAssertTrue(shaded[boundary...].contains(true), "the hovered row is shaded")
        let gap = shaded[span].split(separator: true, omittingEmptySubsequences: true).map(\.count).max() ?? 0
        XCTAssertGreaterThanOrEqual(gap, 1, "no gap between the selection and the hover, around their edge: \(around)")
        print("selection/hover edge, \(scale) px per pt: \(around)")
    }

    /// The selected session row is the theme's accent (Nous, the default: blue) whether
    /// the list has focus or not: picked with a click, then after a switch to another
    /// session, then with the composer focused. AppKit drew it in the system's accent
    /// only while the list had focus, gray otherwise. Writes in chats until the list
    /// has two sessions.
    @MainActor
    func testSelectedSessionRowKeepsTheAccentWhateverHasFocus() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let (list, rows) = try twoSessionRows(app)
        let window = app.windows.firstMatch
        // Inside the fill (10 pt in, `Hover.rowInset`), before the row's text (16 pt in).
        func fill(of row: XCUIElement, _ name: String) -> [Int] {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let shot = window.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let frame = window.frame
            let pixel = Self.pixels(of: shot.image, column: (x: list.frame.minX + 13 - frame.minX,
                                                            from: row.frame.midY - frame.minY,
                                                            to: row.frame.midY + 1 - frame.minY),
                                    in: frame.size).first ?? []
            XCTAssertGreaterThanOrEqual(pixel.count, 3, "read the row")
            return pixel.prefix(3).map(Int.init)
        }
        press(rows[0])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let picked = fill(of: rows[0], "selected session, clicked")
        press(rows[1])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let switched = fill(of: rows[1], "selected session, after switching")
        press(app.textViews["composer"])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let composing = fill(of: rows[1], "selected session, composer focused")
        print("selected row fill: clicked \(picked), switched \(switched), composing \(composing)")
        // Blue, not gray: its channels spread apart.
        for (name, pixel) in [("clicked", picked), ("switched", switched), ("composing", composing)] {
            let spread = (pixel.max() ?? 0) - (pixel.min() ?? 0)
            XCTAssertGreaterThan(spread, 20, "\(name): the selection is gray: \(pixel)")
        }
        for other in [switched, composing] {
            XCTAssertTrue(zip(picked, other).allSatisfy { abs($0 - $1) <= 6 },
                          "the selection changed colour: \(picked) vs \(other)")
        }
    }

    /// The session list, once it has at least two sessions (written in until it does),
    /// and its session rows, less its section headers and notes.
    @MainActor
    private func twoSessionRows(_ app: XCUIApplication) throws -> (list: XCUIElement, rows: [XCUIElement]) {
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected")
        let list = app.outlines.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the session list")
        let notes = ["Sessions", "Pinned", "No sessions yet", "Loading sessions…"]
        func sessionRows() -> [XCUIElement] {
            list.outlineRows.allElementsBoundByIndex.filter { row in
                !notes.contains { row.staticTexts[$0].exists }
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        while sessionRows().count < 2 {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
            let before = sessionRows().count
            press(newChat)
            let composer = app.textViews["composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
            press(composer)
            composer.typeText("Reply with exactly OK and nothing else. Do not use tools.")
            press(app.buttons["Send"].firstMatch)
            let deadline = Date().addingTimeInterval(90)
            while sessionRows().count <= before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            XCTAssertGreaterThan(sessionRows().count, before,
                                 "the chat written in is listed: \(list.outlineRows.count) rows")
        }
        return (list, sessionRows())
    }

    /// The window's title (the chat's) once it passes `test`, or nil.
    @MainActor
    private func waitForTitle(of window: XCUIElement, timeout: TimeInterval, _ test: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if test(window.title) { return window.title }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return nil
    }

    /// The prompt rail: a chat with a long reply and two short ones gets a tick per prompt
    /// beside the centered messages; hovering a tick opens the panel of prompts, and a
    /// prompt there scrolls the chat back to it and is marked, the one before last too.
    /// Screenshots of each step are attached.
    @MainActor
    func testPromptRailListsThePromptsAndJumpsBack() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")

        // Each reply ends with its marker; the prompt holds it too, so its wording ("Do not
        // repeat") tells them apart. The first reply is long, so the chat scrolls; the
        // last two are short, so the prompt before last and everything after it fit on
        // screen, as in the user's report (2026-10-18).
        for round in 1...3 {
            let marker = "RAIL\(round)-\(Int.random(in: 1000...9999))"
            let ask = round == 1
                ? "write the numbers 1 to 25 as a bulleted list, then a blank line, then a last paragraph with exactly \(marker)."
                : "answer with one short sentence, then a last paragraph with exactly \(marker)."
            press(composer)
            composer.typeText("Round \(round): \(ask) Do not repeat these instructions. Do not use tools.")
            press(app.buttons["Send"].firstMatch)
            let reply = app.textViews.matching(NSPredicate(
                format: "value CONTAINS %@ AND NOT (value CONTAINS %@)", marker, "Do not repeat"))
            let deadline = Date().addingTimeInterval(150)
            while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            XCTAssertGreaterThanOrEqual(reply.count, 1, "round \(round) answered")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // The first replies are under the title bar now, blurred by its glass.
        attach(app, "Prompt rail: chat after three rounds")

        let ticks = app.buttons.matching(identifier: "prompt-rail-tick")
        XCTAssertEqual(ticks.count, 3, "a tick per prompt")
        ticks.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let rows = app.buttons.matching(identifier: "prompt-rail-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "hovering the rail opens the panel")
        XCTAssertEqual(rows.count, 3, "the panel lists every prompt")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attach(app, "Prompt rail: panel open")

        // The prompt before last (the user's report, 2026-10-18): its jump left the last
        // prompt on screen under it, and the rail marked the last prompt instead.
        press(rows.element(boundBy: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "Prompt rail: after jumping to the prompt before last")
        XCTAssertEqual(ticks.element(boundBy: 1).value as? String, "current",
                       "the rail marks the prompt before last after a jump to it")
        XCTAssertNotEqual(ticks.element(boundBy: 2).value as? String, "current", "the last prompt is not marked")
        let isSecond = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Round 2:", "Round 2:")
        let second = app.staticTexts.matching(isSecond).firstMatch.exists
            ? app.staticTexts.matching(isSecond).firstMatch : app.textViews.matching(isSecond).firstMatch
        XCTAssertTrue(second.exists && second.isHittable, "the prompt before last is on screen after the jump")

        ticks.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "hovering the rail opens the panel again")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        press(rows.element(boundBy: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // Away from the rail, so the panel closes and only the chat's texts remain.
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "Prompt rail: after jumping to the first prompt")
        XCTAssertEqual(rows.count, 0, "the panel closes when the pointer leaves it")
        let isFirst = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Round 1:", "Round 1:")
        let first = app.staticTexts.matching(isFirst).firstMatch.exists
            ? app.staticTexts.matching(isFirst).firstMatch : app.textViews.matching(isFirst).firstMatch
        XCTAssertTrue(first.exists && first.isHittable, "the first prompt is on screen after the jump")

        // The same in dark mode, with the first reply scrolled under the title bar.
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -300)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach(app, "Prompt rail: dark mode")
    }
    #endif

    /// Whether some text containing `text` shows up: a static text (macOS keeps its
    /// string in the value, iOS in the label) or a combined element's label.
    @MainActor
    private func waitForText(in app: XCUIApplication, _ text: String, timeout: TimeInterval) -> Bool {
        let texts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
        let others = app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", text))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if texts.count > 0 || others.count > 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while Date() < deadline
        return false
    }

    /// A click in the element's middle. On macOS, XCUITest's `tap()` (on the element or a
    /// coordinate) did not trigger SwiftUI buttons such as New chat, nor find a hit point
    /// in the composer; a coordinate `click()` did (checked in a VM, 2026-10).
    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }
}
