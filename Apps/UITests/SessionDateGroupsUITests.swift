import XCTest

/// The session list's date groups (`SessionDateGrouping`): sessions from earlier months sit
/// under their month's header, below the newest run under "Sessions". Older sessions come
/// from the dashboard's session import (`POST /api/sessions/import`,
/// `hermes_cli/web_routers/sessions.py:492-508`), with their messages' times; the script's
/// sweep deletes them afterwards. Screenshots of the list. Compiled into both
/// HermesMacUITests and HermesiOSUITests.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class SessionDateGroupsUITests: XCTestCase {
    @MainActor
    func testOlderSessionsSitUnderTheirMonth() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        let profile = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        let now = Date()
        // Ids are new each run: Hermes never restores an id it deleted.
        let run = UUID().uuidString.prefix(8).lowercased()
        let recent = (title: "Dated recent \(run)", date: now.addingTimeInterval(-120))
        let month = (title: "Dated month \(run)", date: now.addingTimeInterval(-45 * 86_400))
        let year = (title: "Dated year \(run)", date: now.addingTimeInterval(-400 * 86_400))
        try await Self.importSessions([recent, month, year].enumerated().map { index, session in
            (id: "uitest-dated-\(run)-\(index)", title: session.title, date: session.date)
        }, profile: profile, url: url, token: token)

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = profile
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
        defer { app.terminate() }
        #if os(iOS)
        // iPhone may start on the chat; the sidebar is one Back away.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        XCTAssertTrue(app.staticTexts[recent.title].waitForExistence(timeout: 30), "the imported sessions listed")

        let monthHeader = Self.monthTitle(month.date, now: now)
        let yearHeader = Self.monthTitle(year.date, now: now)
        // Newest first: the recent session, then the month, then the month of last year.
        // Earlier tests' chats (a full run deletes them only at its end) can push the older
        // ones below the screen, where a lazy list hasn't built them: scroll down to each in
        // turn, and compare it with the one before while that is still on screen.
        let order = [(recent.title, "the newest"), (monthHeader, "the header \(monthHeader)"),
                     (month.title, "the month's session"), (yearHeader, "the header \(yearHeader)"),
                     (year.title, "last year's session")]
        var previous: (element: XCUIElement, what: String)?
        for (text, what) in order {
            let element = app.staticTexts[text]
            XCTAssertTrue(Self.scrollDown(to: element, in: app), "\(what) in the list")
            if let previous, Self.onScreen(previous.element) {
                XCTAssertLessThan(previous.element.frame.minY, element.frame.minY, "\(what) after \(previous.what)")
            }
            previous = (element, what)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "session list date groups"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scrolls the list down until `element` is on screen: a lazy iPhone list builds a row
    /// only once it is near. The list only moves down, so what was passed stays above. The
    /// Mac's sidebar holds them all (its headers are never hittable): there it only waits.
    @MainActor
    private static func scrollDown(to element: XCUIElement, in app: XCUIApplication) -> Bool {
        #if os(iOS)
        for _ in 0..<15 {
            if onScreen(element) { return true }
            app.swipeUp(velocity: .slow)
        }
        return onScreen(element)
        #else
        return element.waitForExistence(timeout: 20)
        #endif
    }

    @MainActor
    private static func onScreen(_ element: XCUIElement) -> Bool {
        #if os(iOS)
        element.waitForExistence(timeout: 1) && element.isHittable
        #else
        element.exists
        #endif
    }

    /// The header for `date` (`SessionDateBucket.title`): the month, with its year when it
    /// isn't this one. The day ends at 4 AM.
    private static func monthTitle(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let day = date.addingTimeInterval(-4 * 3600)
        let month = calendar.standaloneMonthSymbols[calendar.component(.month, from: day) - 1]
        let year = calendar.component(.year, from: day)
        return year == calendar.component(.year, from: now.addingTimeInterval(-4 * 3600)) ? month : "\(month) \(year)"
    }

    /// Imports sessions with a prompt and a reply each, at `date`. The import is a fenced
    /// session mutation: a new anchor's revision is 0
    /// (`get_session_mutation_snapshot`, `hermes_cli/web_routers/sessions.py:586-598`).
    private static func importSessions(_ sessions: [(id: String, title: String, date: Date)], profile: String,
                                url: String, token: String) async throws {
        let base = try XCTUnwrap(URL(string: url))
        let endpoint = base.appending(path: "api/sessions/import")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "request_id": UUID().uuidString,
            "expected_revision": 0,
            "profile": profile,
            "sessions": sessions.map { session -> [String: Any] in
                let seconds = session.date.timeIntervalSince1970
                return [
                    "id": session.id, "title": session.title, "source": "desktop",
                    "started_at": seconds - 60, "ended_at": seconds, "message_count": 2,
                    "messages": [
                        ["role": "user", "content": "Hello", "timestamp": seconds - 60],
                        ["role": "assistant", "content": "Hi", "timestamp": seconds],
                    ],
                ]
            },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(status, 200, "import: \(body)")
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let imported = json["imported"] as? Int {
            XCTAssertEqual(imported, sessions.count, "import: \(body)")
        }
    }
}
