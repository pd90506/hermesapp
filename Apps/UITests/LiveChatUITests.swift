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
    private func launchApp(servers: Int = 1) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/live-test.sh --ui)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = String(servers)
        app.launch()
        return app
    }

    #if os(iOS)
    /// A new chat gets its reply. On macOS `testEachProfileReturnsToItsLastChat` sends
    /// and waits for a reply the same way.
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

        let composer = app.textViews.firstMatch
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
    }
    #endif

    /// A turn that runs tools and answers with a table: once the reply is in, its tool
    /// calls are one closed summary line ("Ran 2 commands"), which opens to the calls.
    @MainActor
    func testToolCallsFoldIntoOneSummary() throws {
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

        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        composer.typeText("Use the terminal tool twice: first run `echo alpha`, then run `echo beta`. "
            + "Then reply with only a Markdown table with the columns Command and Output, one row per command.")
        press(app.buttons["Send"].firstMatch)

        let summary = app.buttons.matching(identifier: "toolRunSummary").firstMatch
        let settled = NSPredicate(format: "label MATCHES 'Ran [2-9] commands.*'")
        let deadline = Date().addingTimeInterval(180)
        while !(summary.exists && settled.evaluate(with: summary)), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        attach(app, "settled")
        XCTAssertTrue(summary.exists && settled.evaluate(with: summary),
                      "one summary line for the turn's tool calls, got \(summary.exists ? summary.label : "none")")
        XCTAssertEqual(app.buttons.matching(identifier: "toolCallRow").count, 0, "the calls are folded")

        // The live run's line becomes the turn's line as the reply lands: let it
        // settle before clicking it.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        press(summary)
        let rows = app.buttons.matching(identifier: "toolCallRow")
        let opened = Date().addingTimeInterval(10)
        while rows.count < 2, Date() < opened { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        attach(app, "opened")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "opening the summary shows each call")

        #if os(macOS)
        // The run is the one fold: a call in it opens its input and output in a
        // popover, not below its line.
        press(rows.firstMatch)
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "a call in the run opens a popover")
        attach(app, "call popover")
        app.typeKey(.escape, modifierFlags: [])

        // A reply long enough to scroll under the title bar, which is glass: the
        // rows show through it.
        press(composer)
        composer.typeText("Reply with the numbers 1 to 80, one per line, nothing else. Do not use tools.")
        press(app.buttons["Send"].firstMatch)
        let last = app.textViews.matching(NSPredicate(format: "value CONTAINS '\n80'"))
        let replied = Date().addingTimeInterval(150)
        while last.count < 1, Date() < replied { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        (last.count > 0 ? last.firstMatch : composer).scroll(byDeltaX: 0, deltaY: 300)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attach(app, "rows under the title bar")
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
        checkSidebarIsOnePanelUnderTheWindowButtons(app, newChat: newChat, list: list, rail: rail, "no chat")

        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        try require(XCTWaiter().wait(for: [enabled], timeout: 30) == .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews.firstMatch
        try require(composer.waitForExistence(timeout: 30), "composer shown")

        checkNewChatHoldsStill(app, newChat: newChat, "a chat open")
        checkSidebarIsOnePanelUnderTheWindowButtons(app, newChat: newChat, list: list, rail: rail, "a chat open")
        checkHoveringTheTitleBarDoesNotShadeTheChat(app, composer: composer)

        try checkBotChatStaysPinnedAboveTheSessions(app, newChat: newChat, list: list)
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

    /// New chat is in the session column's title bar at its trailing edge (where the
    /// rows' "…" are), level with the window buttons and the profile's name. As a
    /// toolbar item of its own it landed right after the name instead.
    @MainActor
    private func checkNewChatSitsAtTheSessionColumnsTrailingEdge(_ app: XCUIApplication, newChat: XCUIElement,
                                                                 list: XCUIElement) {
        let close = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists, "the window's close button")
        let button = newChat.frame, column = list.frame
        XCTAssertLessThanOrEqual(abs(button.maxX - (column.maxX - 7.5)), 4,
                                 "New chat ends at the column's trailing edge: \(button) in \(column)")
        XCTAssertLessThanOrEqual(abs(button.midY - close.frame.midY), 2,
                                 "New chat is level with the title bar: \(button) vs \(close.frame)")
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
        XCTAssertEqual(rail.frame.width, 64, accuracy: 1, "the rail's width")
        for title in ["Hide Sidebar", "Show Sidebar", "Toggle Sidebar"] {
            XCTAssertFalse(app.menuBars.menuItems[title].exists, "the menus offer \(title)")
        }
        attach(app, "profile rail")
    }

    /// As in Mail, the profile rail and the session list are one sidebar: the window
    /// buttons sit on it, and its glass has one tone across the rail and the list in the
    /// title bar row (the rail and the list each drew their own, with a seam under the
    /// window buttons). The chat column has its own band, set off from the chat below.
    @MainActor
    private func checkSidebarIsOnePanelUnderTheWindowButtons(_ app: XCUIApplication, newChat: XCUIElement,
                                                             list: XCUIElement, rail: XCUIElement,
                                                             _ state: String) {
        let window = app.windows.firstMatch
        let frame = window.frame
        let close = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists, "the window's close button")
        XCTAssertLessThan(rail.frame.maxX, list.frame.minX + 2, "the rail is beside the list: \(rail.frame) \(list.frame)")
        XCTAssertLessThan(close.frame.maxX, list.frame.maxX, "the window buttons are on the sidebar")
        // Points in the title bar row away from any text or button, and one in the chat
        // well below it.
        let railX = rail.frame.midX - frame.minX
        let sessionX = newChat.frame.minX - 40 - frame.minX
        let chatX = list.frame.maxX + (frame.maxX - list.frame.maxX) * 0.75 - frame.minX
        func color(at x: CGFloat, _ y: CGFloat, in shot: XCUIScreenshot) -> [UInt8] {
            Self.pixels(of: shot.image, column: (x: x, from: y, to: y + 1), in: frame.size).first ?? []
        }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "sidebar, \(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let over = color(at: railX, 8, in: shot), session = color(at: sessionX, 8, in: shot)
        let chat = color(at: chatX, 8, in: shot), below = color(at: chatX, 120, in: shot)
        XCTAssertFalse(session.isEmpty || chat.isEmpty || over.isEmpty || below.isEmpty, "read the window")
        XCTAssertTrue(zip(session, over).allSatisfy { abs(Int($0) - Int($1)) <= 8 },
                      "\(state): the sidebar over the rail \(over) and over the list \(session) differ")
        XCTAssertTrue(zip(chat, below).contains { abs(Int($0) - Int($1)) > 8 },
                      "\(state): no band over the chat: \(chat), the same as under it \(below)")
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
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 30), "the Bot Chat opened")
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
        if !waitForText(in: app, "All 2 servers connected", timeout: 60) {
            attach(app, "not both connected")
            XCTFail("both servers connected")
        }
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
        let composer = app.textViews.firstMatch
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

    /// The prompt rail: a chat with three long replies gets a tick per prompt beside the
    /// centered messages; hovering a tick opens the panel of prompts, and a prompt there
    /// scrolls the chat back to it. Screenshots of each step are attached.
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
        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")

        // Each reply ends with its marker. The reply's text view holds it with the list;
        // the prompt holds it too, so its wording ("bulleted list") tells them apart.
        for round in 1...3 {
            let marker = "RAIL\(round)-\(Int.random(in: 1000...9999))"
            press(composer)
            composer.typeText("Round \(round): write the numbers 1 to 25 as a bulleted list, then a blank line, then a last paragraph with exactly \(marker). Do not repeat these instructions. Do not use tools.")
            press(app.buttons["Send"].firstMatch)
            let reply = app.textViews.matching(NSPredicate(
                format: "value CONTAINS %@ AND NOT (value CONTAINS %@)", marker, "bulleted list"))
            let deadline = Date().addingTimeInterval(150)
            while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            XCTAssertGreaterThanOrEqual(reply.count, 1, "round \(round) answered")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "Prompt rail: chat after three rounds")

        let ticks = app.buttons.matching(identifier: "prompt-rail-tick")
        XCTAssertEqual(ticks.count, 3, "a tick per prompt")
        ticks.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let rows = app.buttons.matching(identifier: "prompt-rail-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "hovering the rail opens the panel")
        XCTAssertEqual(rows.count, 3, "the panel lists every prompt")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attach(app, "Prompt rail: panel open")

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
