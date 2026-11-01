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
        #if os(iOS)
        // iPhone may start on the chat; the sidebar is one Back away.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 30), "the imported chat listed")
        let searchTab = app.sessionListTab("search")
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10), "the Search tab")
        searchTab.tap()
        #else
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 30), "the imported chat listed")
        #endif
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field")
        #if os(macOS)
        field.click()
        #else
        field.tap()
        #endif
        field.typeText(word)

        let row = app.descendants(matching: .any)["sessionSearchRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "a result")
        XCTAssertTrue(app.staticTexts[title].exists || row.label.contains(title), "the chat's title on the result")
        XCTAssertTrue(row.label.contains(word), "the matched text, without the FTS markers: \(row.label)")
        XCTAssertFalse(row.label.contains(">>>"), "no FTS markers")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "session search results"
        shot.lifetime = .keepAlways
        add(shot)

        #if os(macOS)
        row.click()
        #else
        row.tap()
        #endif
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", word)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "the hit opens its chat")
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
