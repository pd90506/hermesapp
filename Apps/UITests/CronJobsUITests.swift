import XCTest

/// The session list's Cron Jobs tab against a live dashboard, in the `hermesapp-test`
/// profile. Compiled into both HermesMacUITests and HermesiOSUITests.
///
/// The test makes its own jobs through the dashboard's REST routes (`POST
/// /api/cron/jobs?profile=`) and deletes them when it ends, also when it fails.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class CronJobsUITests: XCTestCase {
    private static let namePrefix = "UI test cron"

    /// The tabs at the bottom of the list (on iOS the system's tab bar) switch it between
    /// the sessions and the jobs.
    /// A job's row shows its schedule and where it delivers; a tap shows its runs; its
    /// "…" menu has Run Now, Pause, Deliver To and Delete. On the Mac, Run Now runs it, and
    /// the run opens as a chat (when the VM's Hermes has a model key: without one, the run
    /// only records its error). A run is a whole agent turn, about four minutes in the VM,
    /// and the server path is the same on both platforms, so iOS checks the menu only.
    @MainActor
    func testCronTabListsTheJobsAndOpensARun() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        let profile = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        let api = Dashboard(url: url, token: token, profile: profile)
        try api.removeJobs(named: Self.namePrefix)
        let brief = try api.createJob(["name": "\(Self.namePrefix): morning brief",
                                       "prompt": "Reply with exactly: cron ok", "schedule": "0 9 * * *",
                                       "deliver": "bot-chat"])
        let paused = try api.createJob(["name": "\(Self.namePrefix): weekly report",
                                        "prompt": "Reply with exactly: weekly ok", "schedule": "every monday 8am",
                                        "deliver": "local", "paused": true])
        defer { try? api.removeJobs(named: Self.namePrefix) }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = profile
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
        defer { app.terminate() }
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        let connected = app.buttons["New chat"].waitForExistence(timeout: 30)
        if !connected { attachLaunchState(of: app, "not connected") }
        XCTAssertTrue(connected, "connected, the session list shown")

        let sessionsTab = app.sessionListTab("sessions")
        let cronTab = app.sessionListTab("cron")
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 10), "the Sessions tab")
        XCTAssertTrue(cronTab.exists, "the Cron Jobs tab")
        XCTAssertEqual(sessionsTab.frame.midY, cronTab.frame.midY, accuracy: 2, "the tabs side by side")
        XCTAssertGreaterThan(cronTab.frame.minY, app.windows.firstMatch.frame.midY, "the tabs at the bottom")
        attach(app, "1 sessions tab")
        let tabsBefore = sessionsTab.frame.union(cronTab.frame)

        press(cronTab)
        let briefRow = element(app, "cronJob.\(brief)")
        let pausedRow = element(app, "cronJob.\(paused)")
        XCTAssertTrue(briefRow.waitForExistence(timeout: 30), "the job is listed")
        XCTAssertTrue(pausedRow.waitForExistence(timeout: 5), "the paused job is listed")
        // Picking a tab doesn't resize the bar (it grew by a hair, the picked tab's
        // symbol filled and its title semibold).
        let tabsAfter = sessionsTab.frame.union(cronTab.frame)
        XCTAssertEqual(tabsAfter.height, tabsBefore.height, accuracy: 0.01, "the tabs keep their height: \(tabsBefore) → \(tabsAfter)")
        XCTAssertEqual(tabsAfter.width, tabsBefore.width, accuracy: 0.01, "the tabs keep their width: \(tabsBefore) → \(tabsAfter)")
        XCTAssertTrue(briefRow.label.contains("Bot Chat"), "the row says where it delivers: \(briefRow.label)")
        XCTAssertTrue(pausedRow.label.contains("Paused"), "the paused job says so: \(pausedRow.label)")
        XCTAssertLessThan(briefRow.frame.minY, pausedRow.frame.minY, "the job that runs next first")
        XCTAssertFalse(element(app, "botChatRow").exists || element(app, "pinnedBotChat").exists,
                       "the Bot Chat and sessions make way for the jobs")
        attach(app, "2 cron jobs tab")

        press(briefRow)
        XCTAssertTrue(app.staticTexts["No runs yet"].waitForExistence(timeout: 15), "its runs under it")
        attach(app, "3 job expanded")

        let menu = element(app, "cronJobMenu.\(brief)")
        press(menu)
        XCTAssertTrue(menuItem(app, "Deliver To").waitForExistence(timeout: 5), "the job's menu")
        XCTAssertTrue(menuItem(app, "Run Now").exists)
        XCTAssertTrue(menuItem(app, "Pause").exists)
        attach(app, "4 job menu")
        #if os(macOS)
        press(menuItem(app, "Run Now"))

        // The trigger answers when the run ends; then the run is listed under the job.
        let run = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cronRun.cron_\(brief)_")).firstMatch
        if run.waitForExistence(timeout: 240) {
            attach(app, "5 run listed")
            press(run)
            XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 30), "the run opened as a chat")
            // On the Mac a reply is selectable text, whose words are its value.
            let reply = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label ==[c] %@ OR value ==[c] %@", "cron ok", "cron ok")).firstMatch
            let replied = reply.waitForExistence(timeout: 30)
            attach(app, "6 run opened")
            XCTAssertTrue(replied, "the run's reply")
        } else {
            attach(app, "5 run not listed")
        }
        if element(app, "cronJobMenu.\(brief)").waitForExistence(timeout: 10) {
            press(element(app, "cronJobMenu.\(brief)"))
        }
        #endif

        // Pause from the menu (on iOS still open), then back to the sessions.
        if menuItem(app, "Pause").waitForExistence(timeout: 5) {
            press(menuItem(app, "Pause"))
            XCTAssertTrue(eventually(timeout: 15) { briefRow.label.contains("Paused") }, "paused: \(briefRow.label)")
            attach(app, "7 paused")
        }
        press(sessionsTab)
        XCTAssertTrue(eventually { !briefRow.exists }, "the sessions again")
    }

    /// A click on the Mac, a tap on iOS.
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// An item of an open menu: a menu item on the Mac, a button on iOS.
    private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        #if os(macOS)
        app.menuItems[title].firstMatch
        #else
        app.buttons[title].firstMatch
        #endif
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }
}

/// The dashboard's cron routes, called the way the app calls them (token as bearer).
private struct Dashboard {
    let url: String
    let token: String
    let profile: String

    func createJob(_ body: [String: Any]) throws -> String {
        let job = try call("POST", "/api/cron/jobs", body: body) as? [String: Any]
        guard let id = job?["id"] as? String else { throw Failure(detail: "no job id in \(String(describing: job))") }
        return id
    }

    func removeJobs(named prefix: String) throws {
        let jobs = try call("GET", "/api/cron/jobs", body: nil) as? [[String: Any]] ?? []
        for job in jobs where (job["name"] as? String)?.hasPrefix(prefix) == true {
            if let id = job["id"] as? String { _ = try? call("DELETE", "/api/cron/jobs/\(id)", body: nil) }
        }
    }

    private struct Failure: Error { var detail: String }

    private func call(_ method: String, _ path: String, body: [String: Any]?) throws -> Any {
        var components = URLComponents(string: url.hasSuffix("/") ? String(url.dropLast()) + path : url + path)!
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Data, Int), any Error> = .failure(Failure(detail: "no answer"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        let (data, status) = try result.get()
        guard (200..<300).contains(status) else {
            throw Failure(detail: "\(method) \(path): HTTP \(status) \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
