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
        checkSidebarIsOnePanelUnderTheWindowButtons(app, newChat: newChat, list: list, rail: rail, "no chat")

        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        try require(XCTWaiter().wait(for: [enabled], timeout: 30) == .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews["composer"]
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
        // The band is in the chat's own color (the App Store's look): with nothing under
        // the title bar, it is the chat's color.
        XCTAssertTrue(zip(chat, below).allSatisfy { abs(Int($0) - Int($1)) <= 3 },
                      "\(state): a band over the chat: \(chat), unlike under it \(below)")
        // Nor with the pointer over the title bar (macOS 26 shaded it then).
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: chatX, dy: 8)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let hovered = window.screenshot()
        let hoveredAttachment = XCTAttachment(screenshot: hovered)
        hoveredAttachment.name = "title bar under the pointer, \(state)"
        hoveredAttachment.lifetime = .keepAlways
        add(hoveredAttachment)
        let chatHovered = color(at: chatX, 8, in: hovered)
        XCTAssertTrue(zip(chatHovered, below).allSatisfy { abs(Int($0) - Int($1)) <= 3 },
                      "\(state): a band over the chat under the pointer: \(chatHovered), unlike under it \(below)")
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
    /// On iPhone the profile rail is never a page of its own: Profiles (where Back was)
    /// slides the session list right, uncovering the rail beside it, and it rests there.
    /// Picking a profile slides the list back; a swipe right on the list uncovers the
    /// rail again.
    @MainActor
    func testProfilesSlideOutBesideTheSessions() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "connected, Sessions page shown")
        // The list's top row, which slides with it.
        let botChat = app.descendants(matching: .any)["pinnedBotChat"].firstMatch
        XCTAssertTrue(botChat.waitForExistence(timeout: 30), "the session list")
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        XCTAssertFalse(rail.exists, "the list covers the rail")
        let restingX = botChat.frame.minX
        attach(app, "sessions")

        app.buttons["profilesButton"].tap()
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "Profiles uncovers the rail")
        XCTAssertTrue(eventually { botChat.frame.minX > restingX + 60 }, "the list slid right, beside the rail")
        XCTAssertTrue(botChat.exists, "the session list still shows")
        XCTAssertEqual(rail.frame.minX, 0, accuracy: 1, "the rail at the screen's leading edge")
        attach(app, "profiles beside the sessions")

        let picked = rail.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 10), "a profile is selected")
        picked.tap()
        XCTAssertTrue(eventually { !rail.exists }, "picking a profile covers the rail")
        XCTAssertEqual(botChat.frame.minX, restingX, accuracy: 1, "the list back where it rests")

        botChat.swipeRight()
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "a swipe right uncovers the rail")
        XCTAssertTrue(eventually { botChat.frame.minX > restingX + 60 }, "the list slid right after the swipe")
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
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected")
        let list = app.outlines.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the session list")
        // The list's rows, less its section headers and notes.
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

        let rows = sessionRows()
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
