import XCTest

/// What a send shows before the network answers, and what the sidebar's row dates. The
/// network is bad for one message at a time (`UITestSubmitNetwork` in the app): a
/// message holding `SLOW-` leaves after `HERMES_UITEST_SUBMIT_DELAY` seconds, one holding
/// `LOST-` never leaves and the socket drops. Compiled into HermesMacUITests and
/// HermesiOSUITests. Makes one chat; the script's sweep deletes it.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class SendStateUITests: XCTestCase {
    private static let submitDelay: TimeInterval = 8

    @MainActor
    private func launchApp(arguments: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchEnvironment["HERMES_UITEST_SUBMIT_DELAY"] = String(Self.submitDelay)
        app.launchWithMainWindow()
        return app
    }

    /// A first message, a minute's wait, then a message on a stalled uplink: its bubble
    /// shows at once as Sending…, the composer empties, and once it went out the status
    /// goes. The chat's row then dates the latest message, not the chat's start a minute
    /// before. Then a message the network loses: it stays on screen (as Not confirmed, or
    /// back in the composer after a rebuild), never just gone.
    @MainActor
    func testPendingSendShowsAtOnceAndTheRowDatesTheLatestMessage() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let composer = try openNewChat(app)

        let first = "PONG\(Int.random(in: 1000...9999))"
        send("Reply with exactly \(first) and nothing else. Do not use tools.", composer: composer, in: app)
        let firstSent = Date()
        XCTAssertTrue(waitForMessage(first, exactly: true, in: app, timeout: 150), "reply \(first) shown")
        attach(app, "1 first reply")
        showSessionList(app)
        attach(app, "2 list after the first reply")
        record(rowTexts(app), "row dates after the first reply")
        #if os(macOS)
        let rowDate = app.staticTexts["sessionMessageDate"].firstMatch
        XCTAssertTrue(rowDate.waitForExistence(timeout: 10), "latest stored message date loaded")
        let initialRelativeDate = statusText(rowDate)
        let dateObserved = Date()
        #endif

        // More than a minute after the chat began, so "started" and "latest" differ.
        #if os(macOS)
        let wait = 70 - Date().timeIntervalSince(dateObserved)
        #else
        let wait = 70 - Date().timeIntervalSince(firstSent)
        #endif
        if wait > 0 { RunLoop.current.run(until: Date().addingTimeInterval(wait)) }
        #if os(iOS)
        // Back on the list, the rows are drawn again, with the time since then.
        openFirstSession(app)
        showSessionList(app)
        attach(app, "3 list a minute later")
        record(rowTexts(app), "row dates a minute later")
        openFirstSession(app)
        #else
        attach(app, "3 a minute later")
        XCTAssertTrue(eventually(timeout: 65) { self.statusText(rowDate) != initialRelativeDate },
                      "the macOS relative date must age without interaction or a new message")
        #endif

        let slow = "SLOW-\(Int.random(in: 1000...9999))"
        let second = "PONG\(Int.random(in: 1000...9999))"
        send("\(slow) Reply with exactly \(second) and nothing else. Do not use tools.", composer: composer, in: app)
        let pressed = Date()
        let status = app.staticTexts["outgoingStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 2), "the pending bubble's status at once")
        let shownAfter = Date().timeIntervalSince(pressed)
        XCTAssertTrue(waitForMessage(slow, exactly: false, in: app, timeout: 1), "the pending bubble's text at once")
        attach(app, "4 pending, '\(statusText(status))' after \(Int(shownAfter * 1000)) ms")
        record(["status: \(statusText(status))", "shown after \(String(format: "%.2f", shownAfter)) s",
                "composer: \(composerText(composer))"], "pending")
        XCTAssertEqual(statusText(status), "Sending…")
        XCTAssertLessThan(shownAfter, Self.submitDelay - 2, "shown before the submit left")
        XCTAssertFalse(composerText(composer).contains(slow), "the composer emptied")
        let pendingFooter = try XCTUnwrap(footer(under: slow, in: app), "the pending bubble's footer")
        XCTAssertTrue(pendingFooter.staticTexts["outgoingStatus"].exists, "Sending belongs to the existing footer")
        XCTAssertFalse(pendingFooter.descendants(matching: .any)["messageTime"].exists,
                       "status replaces time instead of exposing both")
        let pendingCopy = pendingFooter.buttons["Copy Message"].frame
        let copyOffset = CGVector(dx: pendingFooter.frame.maxX - pendingCopy.midX,
                                  dy: pendingCopy.midY - pendingFooter.frame.minY)

        XCTAssertTrue(waitForMessage(second, exactly: true, in: app, timeout: 150), "reply \(second) shown")
        XCTAssertTrue(eventually(timeout: 10) { !app.staticTexts["outgoingStatus"].exists }, "status gone once settled")
        // On macOS an older message's footer shows under the pointer only.
        let confirmedFooter = try XCTUnwrap(footer(under: slow, in: app), "the sent bubble's footer")
        XCTAssertTrue(confirmedFooter.descendants(matching: .any)["messageTime"].exists,
                      "confirmation restores the timestamp in the footer")
        let confirmedCopy = confirmedFooter.buttons["Copy Message"].frame
        XCTAssertEqual(confirmedFooter.frame.maxX - confirmedCopy.midX, copyOffset.dx, accuracy: 1,
                       "Copy keeps its horizontal anchor")
        XCTAssertEqual(confirmedCopy.midY - confirmedFooter.frame.minY, copyOffset.dy, accuracy: 1,
                       "Copy keeps its vertical anchor")
        attach(app, "5 second reply, settled")
        showSessionList(app)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attach(app, "6 list after the second reply")
        record(rowTexts(app), "row dates after the second reply")
        #if os(iOS)
        openFirstSession(app)
        #endif

        let lost = "LOST-\(Int.random(in: 1000...9999))"
        send("\(lost) Reply with exactly OK.", composer: composer, in: app)
        XCTAssertTrue(waitForMessage(lost, exactly: false, in: app, timeout: 2), "the lost message's bubble at once")
        attach(app, "7 lost, at once")
        // The socket drops; the app reconnects. The message must stay visible somewhere.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        let lostStatus = app.staticTexts["outgoingStatus"].firstMatch
        let lostText = lostStatus.exists ? statusText(lostStatus) : "(no status)"
        let inComposer = composerText(composer).contains(lost)
        let bubble = waitForMessage(lost, exactly: false, in: app, timeout: 1, excludingComposer: true)
        attach(app, "8 lost after reconnect, '\(lostText)', bubble \(bubble), composer \(inComposer)")
        record(["status: \(lostText)", "bubble shown: \(bubble)", "in composer: \(inComposer)"], "lost")
        XCTAssertTrue(bubble || inComposer, "the lost message is still on screen")
        XCTAssertFalse(lostText.hasPrefix("Queued"), "a lost message never reads as taken")
        // Leave no draft behind.
        if inComposer { clear(composer, in: app) }
    }

    /// A correction sent while a reply streams shows below the reply so far, and what that
    /// reply streams until Hermes takes the correction stays above it, as Hermes stores it.
    /// The uplink holds the correction (`SLOW-`) for `submitDelay` seconds, as a slow
    /// network does, while the reply streams on. Hermes's default busy mode then redirects
    /// the reply with it, and the answer comes below the correction.
    @MainActor
    func testACorrectionMidReplyKeepsTheReplySoFarAboveIt() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let composer = try openNewChat(app)

        send("Write the whole numbers from 1 to 1000 as English words, each on its own line, and nothing else. "
             + "Do not use tools.", composer: composer, in: app)
        XCTAssertTrue(waitForMessage("twenty", exactly: false, in: app, timeout: 150), "the reply streams")
        let slow = "SLOW-\(Int.random(in: 1000...9999))"
        let answer = "PONG\(Int.random(in: 1000...9999))"
        send("\(slow) Stop counting. Reply with exactly \(answer) and nothing else.", composer: composer, in: app)
        XCTAssertTrue(waitForMessage(slow, exactly: false, in: app, timeout: 2), "the correction shows at once")
        attach(app, "1 correction sent")
        RunLoop.current.run(until: Date().addingTimeInterval(Self.submitDelay - 2))
        attach(app, "2 the reply streamed on while the correction waited")
        checkOrder(correction: slow, answer: nil, in: app, "while it waited")

        XCTAssertTrue(waitForMessage(answer, exactly: true, in: app, timeout: 150), "answer \(answer) shown")
        attach(app, "3 the answer")
        checkOrder(correction: slow, answer: answer, in: app, "answered")
        // The stored rows take over once the session is quiet; the order holds.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        attach(app, "4 settled")
        checkOrder(correction: slow, answer: answer, in: app, "settled")
    }

    /// The counting reply's text is above the correction (holding `correction`), and the
    /// answer, when given, below it.
    @MainActor
    private func checkOrder(correction: String, answer: String?, in app: XCUIApplication, _ moment: String) {
        let texts = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier != 'composer' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.staticText.rawValue, XCUIElement.ElementType.textView.rawValue))
            .allElementsBoundByIndex.filter { $0.frame.height > 0 }
        func text(_ element: XCUIElement) -> String {
            let value = element.value as? String ?? ""
            return value.isEmpty ? element.label : value
        }
        guard let bubble = texts.filter({ text($0).contains(correction) }).min(by: { $0.frame.height < $1.frame.height })
        else { return XCTFail("\(moment): no correction bubble") }
        let counting = texts.filter { element in
            let words = text(element).lowercased()
            return !words.contains(correction.lowercased()) && !words.contains("english words")
                && ["twenty", "thirty", "forty", "hundred", "seven", "nine"].contains { words.contains($0) }
        }
        record(["correction \(bubble.frame)"] + counting.map { "counting \($0.frame): \(text($0).suffix(40))" },
               "order \(moment)")
        XCTAssertFalse(counting.isEmpty, "\(moment): the reply so far is shown")
        for element in counting {
            XCTAssertLessThan(element.frame.minY, bubble.frame.minY,
                              "\(moment): reply text below the correction: \(text(element).suffix(40))")
        }
        if let answer {
            let reply = texts.filter { text($0) == answer }
            XCTAssertFalse(reply.isEmpty, "\(moment): the answer is shown")
            for element in reply {
                XCTAssertGreaterThan(element.frame.minY, bubble.frame.maxY, "\(moment): the answer is below the correction")
            }
        }
    }

    #if os(iOS)
    /// Pinyin on the simulator's own keyboard: letters typed stay marked (the candidate
    /// bar is up) when Send is tapped. The bubble shows what was visible, the composer is
    /// empty, and the next letter starts a new composition, not the old text again. A
    /// candidate tap still only commits it. Fails if the software keyboard is off screen (a
    /// hardware keyboard hides it) or the globe does not reach Pinyin: scripts/vm-test.sh
    /// makes Pinyin the simulator's other keyboard for the run.
    @MainActor
    func testSendDuringPinyinCompositionClearsTheComposer() throws {
        continueAfterFailure = false
        // The simulator's own keyboards must hold Pinyin (a launch argument does not reach
        // the keyboard process).
        let app = try launchApp()
        // Teardown blocks, not defers: with continueAfterFailure off a failed assertion
        // stops the test before its defers run. They run last first: the keyboard goes
        // back to English, then the app quits. Each makes its own XCUIApplication (the
        // same app), so the blocks capture nothing.
        addTeardownBlock { XCUIApplication().terminate() }
        let composer = try openNewChat(app)
        press(composer)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the keyboard is up")
        attach(app, "1 keyboard")
        attachTree(of: keyboard, "keyboard elements")
        // With a hardware keyboard the software one stays in the tree, below the screen.
        let screen = app.windows.firstMatch.frame
        record(["keyboard \(keyboard.frame)", "window \(screen)"], "keyboard frame")
        XCTAssertLessThan(keyboard.frame.minY, screen.maxY - 100,
                          "the software keyboard is on screen, not hidden by a hardware one: \(keyboard.frame)")

        // The simulator keeps the last keyboard chosen: back to English at the end, or the
        // next tests' typing goes through Pinyin.
        let isPinyin = { (name: String) in name.localizedCaseInsensitiveContains("pinyin") || name.contains("拼音") }
        addTeardownBlock {
            let app = XCUIApplication()
            let composer = app.textViews["composer"]
            if !app.keyboards.firstMatch.waitForExistence(timeout: 2), composer.exists { composer.tap() }
            let back = SendStateUITests.switchKeyboard(in: app) { $0.hasPrefix("English") }
            SendStateUITests.note(back, "keyboards switched back to")
            XCTAssertTrue(back.last?.hasPrefix("English") ?? false, "the keyboard went back to English: \(back)")
        }
        let switches = Self.switchKeyboard(in: app, to: isPinyin)
        record(switches, "keyboards switched to")
        attach(app, "1b keyboard after the globe: \(switches.last ?? "none")")
        XCTAssertTrue(switches.last.map(isPinyin) ?? false,
                      "the globe went to Pinyin (vm-test.sh sets it as the other keyboard): \(switches)")
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "label == '你'")).firstMatch
        type("ni", in: app, composer: composer)
        guard candidate.waitForExistence(timeout: 5) else {
            attach(app, "no pinyin candidates")
            attachTree(of: keyboard, "keyboard elements, no candidates")
            return XCTFail("Pinyin offers no 你 for \"ni\" (switched to \(switches)): \(composerText(composer))")
        }
        // Latin first (as a sentence typed before the pinyin): a candidate tap commits it.
        candidate.tap()
        XCTAssertTrue(eventually { self.composerText(composer).hasPrefix("你") }, "the candidate committed: \(composerText(composer))")
        XCTAssertFalse(waitForMessage("你", exactly: false, in: app, timeout: 1, excludingComposer: true),
                       "a candidate tap does not send")
        attach(app, "2 candidate committed")
        // Then letters left marked, and Send.
        type("hao", in: app, composer: composer)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == '好'")).firstMatch
            .waitForExistence(timeout: 5), "hao is marked, candidates up")
        let visible = composerText(composer)
        attach(app, "3 marked, before Send, visible '\(visible)'")
        record(["visible: \(visible)"], "before Send")
        press(app.buttons["Send"].firstMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let after = composerText(composer)
        attach(app, "4 after Send, composer '\(after)'")
        XCTAssertTrue(waitForMessage(visible, exactly: true, in: app, timeout: 5, excludingComposer: true),
                      "the bubble shows what was visible: \(visible)")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        // Once: the transcript's texts, not the navigation title.
        let below = app.navigationBars.firstMatch.frame.maxY
        let bubbles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier != 'composer' AND (label == %@ OR value == %@)", visible, visible))
            .allElementsBoundByIndex
            .filter { [.staticText, .textView].contains($0.elementType) && $0.frame.minY > below }
        record(["composer: \(after)", "bubbles '\(visible)': \(bubbles.count)"], "after Send")
        XCTAssertEqual(bubbles.count, 1, "the message shows exactly once")
        XCTAssertTrue(after.isEmpty, "the composer emptied: \(after)")
        // Late input-method callbacks must not bring it back.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(composerText(composer).contains("你"), "still empty: \(composerText(composer))")
        // The next letters start over.
        type("ni", in: app, composer: composer)
        let next = composerText(composer)
        attach(app, "5 next letters, composer '\(next)'")
        record(["composer: \(next)"], "next letters")
        XCTAssertFalse(next.contains("你hao") || next.contains("你好"), "the old text did not come back: \(next)")
        clear(composer, in: app)
        attach(app, "6 cleared")
    }

    /// Taps the keyboard's globe until the keyboard it went to is one `target` accepts. The
    /// globe (in the row under the keys, outside the keyboard element on iOS 26) names that
    /// keyboard in its value. A tap goes back and forth between the current keyboard and the
    /// one before it, so a few taps are enough or none will be. The first tap ever shows a
    /// one-time tip instead (Continue). Returns the keyboards gone to. Static, for the
    /// teardown block and ComposerUITests.
    @MainActor
    static func switchKeyboard(in app: XCUIApplication, to target: (String) -> Bool) -> [String] {
        let globe = app.buttons.matching(NSPredicate(format: "label IN {'Next keyboard', '下一个键盘'}")).firstMatch
        let tip = app.buttons["Continue"]
        var switches: [String] = []
        for _ in 0..<4 {
            guard globe.waitForExistence(timeout: 5) else {
                note([app.debugDescription], "app elements, no globe")
                break
            }
            let next = globe.value as? String ?? ""
            globe.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            if tip.exists {
                XCTContext.runActivity(named: "keyboard tip") { activity in
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "keyboard tip"
                    shot.lifetime = .keepAlways
                    activity.add(shot)
                }
                tip.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                continue
            }
            switches.append(next)
            if target(next) { break }
        }
        return switches
    }

    /// Letters through the keyboard's own keys, which an input method composes. Never
    /// typeText: that inserts plain Latin text, past the input method.
    @MainActor
    private func type(_ letters: String, in app: XCUIApplication, composer: XCUIElement) {
        for letter in letters {
            // Keys read "Q" or "q" with the shift state.
            let key = app.keyboards.keys.matching(NSPredicate(format: "label ==[c] %@", String(letter))).firstMatch
            // Right after a keyboard switch its keys take a moment to be hittable.
            guard key.waitForExistence(timeout: 3), eventually(timeout: 3, { key.isHittable }) else {
                return XCTFail("no on-screen key \(letter) to tap: \(key.exists ? "\(key.frame)" : "none")")
            }
            key.tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    #endif

    // MARK: Helpers

    @MainActor
    private func openNewChat(_ app: XCUIApplication) throws -> XCUIElement {
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        let newChat = app.buttons["New chat"]
        let connected = newChat.waitForExistence(timeout: 30)
        if !connected { attachLaunchState(of: app, "not connected") }
        XCTAssertTrue(connected, "connected, Sessions shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        let wait = XCTWaiter().wait(for: [enabled], timeout: 30)
        if wait != .completed { attachLaunchState(of: app, "New chat not enabled") }
        XCTAssertEqual(wait, .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        return composer
    }

    @MainActor
    private func send(_ text: String, composer: XCUIElement, in app: XCUIApplication) {
        press(composer)
        composer.typeText(text)
        press(app.buttons["Send"].firstMatch)
    }

    @MainActor
    private func showSessionList(_ app: XCUIApplication) {
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 10), "the list")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        #endif
    }

    #if os(iOS)
    /// The newest session, the one this test writes in.
    @MainActor
    private func openFirstSession(_ app: XCUIApplication) {
        let cells = app.collectionViews.firstMatch.cells.allElementsBoundByIndex
            .filter { $0.identifier != "botChatRow" && !$0.descendants(matching: .any)["botChatRow"].exists
                && $0.staticTexts.count >= 2 }
        guard let row = cells.first else { return XCTFail("no session row") }
        row.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10), "the chat opened")
    }
    #endif

    /// The session list's texts, row titles with their dates.
    @MainActor
    private func rowTexts(_ app: XCUIApplication) -> [String] {
        #if os(macOS)
        let rows = app.outlines.firstMatch.outlineRows.allElementsBoundByIndex
        #else
        let rows = app.collectionViews.firstMatch.cells.allElementsBoundByIndex
        #endif
        return rows.prefix(6).map { row in
            row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        }
    }

    @MainActor
    private func waitForMessage(_ text: String, exactly: Bool, in app: XCUIApplication, timeout: TimeInterval,
                                excludingComposer: Bool = true) -> Bool {
        let match = exactly
            ? NSPredicate(format: "identifier != 'composer' AND (value == %@ OR label == %@)", text, text)
            : NSPredicate(format: "identifier != 'composer' AND (value CONTAINS %@ OR label CONTAINS %@)", text, text)
        let found = app.descendants(matching: .any).matching(match)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if found.count > 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    /// The status line's text: iOS reports a Text as its label, macOS as its value.
    @MainActor
    private func statusText(_ element: XCUIElement) -> String {
        let value = element.value as? String ?? ""
        return value.isEmpty ? element.label : value
    }

    /// The action bar right under the message holding `text`; on macOS the pointer goes
    /// over the message first, as an older message's bar shows only then.
    @MainActor
    private func footer(under text: String, in app: XCUIApplication) -> XCUIElement? {
        let matches = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier != 'composer' AND identifier != 'outgoingStatus' AND (value CONTAINS %@ OR label CONTAINS %@)",
            text, text))
        guard matches.firstMatch.waitForExistence(timeout: 5) else { return nil }
        // The text itself, not a container around the message and its bar.
        guard let message = matches.allElementsBoundByIndex
            .filter({ [.staticText, .textView].contains($0.elementType) && $0.frame.height > 0 })
            .min(by: { $0.frame.height < $1.frame.height }) else { return nil }
        #if os(macOS)
        message.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        #endif
        let bottom = message.frame.maxY
        let bars = app.descendants(matching: .any).matching(identifier: "messageActionBar").allElementsBoundByIndex
        record(["message \(message.elementType.rawValue) \(message.frame)"] + bars.map {
            "bar \($0.frame) status \($0.staticTexts["outgoingStatus"].exists)"
        }, "footer under \(text)")
        return bars
            .filter { $0.frame.minY > message.frame.midY }
            .min { abs($0.frame.minY - bottom) < abs($1.frame.minY - bottom) }
    }

    @MainActor
    private func composerText(_ composer: XCUIElement) -> String { composer.value as? String ?? "" }

    @MainActor
    private func clear(_ composer: XCUIElement, in app: XCUIApplication) {
        press(composer)
        let count = composerText(composer).count
        guard count > 0 else { return }
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2))
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func attachTree(of element: XCUIElement, _ name: String) {
        let tree = XCTAttachment(string: element.exists ? element.debugDescription : "(none)")
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// As record, without the test case (for the static helpers and teardown blocks).
    @MainActor
    static func note(_ lines: [String], _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let note = XCTAttachment(string: lines.joined(separator: "\n"))
            note.name = name
            note.lifetime = .keepAlways
            activity.add(note)
        }
        print("[SendStateUITests] \(name): \(lines.joined(separator: " / "))")
    }

    private func record(_ lines: [String], _ name: String) {
        let note = XCTAttachment(string: lines.joined(separator: "\n"))
        note.name = name
        note.lifetime = .keepAlways
        add(note)
        print("[SendStateUITests] \(name): \(lines.joined(separator: " / "))")
    }

    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }
}
