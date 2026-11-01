import XCTest

/// The session list's search (`SessionSearchResultsList`): a word said only in an older
/// chat finds it, with the matched text under its title, and the hit opens the chat. The
/// chat comes from the dashboard's session import (`POST /api/sessions/import`,
/// `hermes_cli/web_routers/sessions.py:492-508`), which the search's FTS index covers;
/// it stays in the VM's test profile, as `SessionDateGroupsUITests`' do. The Mac searches from the sidebar's field,
/// iOS from its Search tab. Screenshots of the results and the opened chat. Compiled
/// into both HermesMacUITests and HermesiOSUITests.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class SessionSearchUITests: XCTestCase {
    @MainActor
    func testAWordFromAnOlderChatFindsAndOpensIt() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        let profile = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        // A word no other chat has: ids and words are new each run.
        let run = UUID().uuidString.prefix(8).lowercased()
        let word = "zephyrine\(run)"
        let title = "Searched chat \(run)"
        try await Self.importSession(id: "uitest-search-\(run)", title: title,
                                     prompt: "Which name did we pick for the release?",
                                     reply: "We picked \(word) for the release name.",
                                     date: Date().addingTimeInterval(-3 * 86_400),
                                     profile: profile, url: url, token: token)

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = profile
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
        defer { app.terminate() }
        // Not "the chat is listed": three days old, it is far down a long list, past what a
        // lazy list draws. Search finds what the list doesn't show.
        #if os(iOS)
        // iPhone may start on the chat; the sidebar is one Back away.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "connected, Sessions page shown")
        let searchTab = app.sessionListTab("search")
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10), "the Search tab")
        searchTab.tap()
        let tab = XCTAttachment(screenshot: app.screenshot())
        tab.name = "search tab"
        tab.lifetime = .keepAlways
        add(tab)
        #else
        XCTAssertTrue(app.sessionListTab("sessions").waitForExistence(timeout: 30), "the session list")
        #endif
        #if os(iOS)
        let field = app.textFields["sessionSearchField"]
        #else
        let field = app.searchFields.firstMatch
        #endif
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field")
        #if os(macOS)
        field.click()
        #else
        field.tap()
        #endif
        field.typeText(word)
        let typed = XCTAttachment(screenshot: app.screenshot())
        typed.name = "search typed"
        typed.lifetime = .keepAlways
        add(typed)

        // On iOS the row is one element whose label joins its lines; on the Mac its lines are
        // texts of their own, whose text is their value.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a result with the chat's title")
        let snippet = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", word, word)).firstMatch
        XCTAssertTrue(snippet.exists, "the matched text on the result")
        let shown = "\(snippet.label) \(snippet.value as? String ?? "")"
        XCTAssertFalse(shown.contains(">>>"), "no FTS markers: \(shown)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "session search results"
        shot.lifetime = .keepAlways
        add(shot)

        #if os(macOS)
        row.click()
        #else
        row.tap()
        #endif
        // The prompt, which only the chat shows (the result shows the reply).
        let prompt = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Which name did we pick", "Which name did we pick"))
            .firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "the hit opens its chat")
        let opened = XCTAttachment(screenshot: app.screenshot())
        opened.name = "session search opened"
        opened.lifetime = .keepAlways
        add(opened)
    }

    /// Imports a session with one prompt and one reply, at `date` (as
    /// `SessionDateGroupsUITests.importSessions`).
    private static func importSession(id: String, title: String, prompt: String, reply: String, date: Date,
                                      profile: String, url: String, token: String) async throws {
        let base = try XCTUnwrap(URL(string: url))
        var request = URLRequest(url: base.appending(path: "api/sessions/import"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let seconds = date.timeIntervalSince1970
        let payload: [String: Any] = [
            "request_id": UUID().uuidString,
            "expected_revision": 0,
            "profile": profile,
            "sessions": [[
                "id": id, "title": title, "source": "desktop",
                "started_at": seconds - 60, "ended_at": seconds, "message_count": 2,
                "messages": [
                    ["role": "user", "content": prompt, "timestamp": seconds - 60],
                    ["role": "assistant", "content": reply, "timestamp": seconds],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 200, "import: \(String(decoding: data, as: UTF8.self))")
    }
}
