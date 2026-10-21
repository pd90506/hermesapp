import XCTest

extension XCTestCase {
    /// What the screen and the app showed when a wait for the app to connect ran out: the
    /// whole screen (other windows and sheets too), the app's windows and its elements.
    /// Only attaches; the caller's assertion fails the test.
    @MainActor
    func attachLaunchState(of app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(name): screen"
        shot.lifetime = .keepAlways
        add(shot)
        // Element queries of an app that is not running fail the test themselves.
        guard app.state == .runningForeground || app.state == .runningBackground else {
            let state = XCTAttachment(string: "app state \(app.state.rawValue), not running")
            state.name = "\(name): app state"
            state.lifetime = .keepAlways
            add(state)
            return
        }
        let windows = app.windows.allElementsBoundByIndex.map { "'\($0.identifier)' '\($0.title)' \($0.frame)" }
        let tree = XCTAttachment(string: "app state \(app.state.rawValue), \(windows.count) windows:\n"
            + windows.joined(separator: "\n") + "\n\n" + app.debugDescription)
        tree.name = "\(name): app elements"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
