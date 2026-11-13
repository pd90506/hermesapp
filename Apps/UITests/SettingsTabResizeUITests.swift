#if os(macOS)
import XCTest

/// The Settings window resizes smoothly as its tabs change, as AppKit's preference
/// windows do, rather than jumping to the new tab's height. The VM's mouse helper
/// (scripts/vm-mouse.swift) clicks the toolbar's tabs while it samples the window's
/// frame every few milliseconds, into /tmp/hermesapp-settings-trace.tsv in the VM.
final class SettingsTabResizeUITests: XCTestCase {
    @MainActor
    func testTabChangesResizeTheWindow() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 60), "connected")

        app.typeKey(",", modifierFlags: .command)
        let tabs = ["Servers", "Appearance", "Servers", "Appearance", "Session Sources", "Providers", "Notifications",
                    "Capabilities", "Servers", "Session Sources", "Providers"]
        let first = app.toolbars.buttons["Servers"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the Settings window")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // The toolbar's tabs stay put (every tab has the same width), so their places now
        // are their places through the trace.
        var points: [String] = []
        for tab in tabs {
            let button = app.toolbars.buttons[tab].firstMatch
            XCTAssertTrue(button.exists, "the \(tab) tab")
            points.append("\(button.frame.midX) \(button.frame.midY)")
        }
        let request = "/tmp/hermesapp-uitest-mouse"
        try? "trace /tmp/hermesapp-settings-trace \(points.joined(separator: " "))\n"
            .write(toFile: request, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(40)
        while FileManager.default.fileExists(atPath: request), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request), "the VM's mouse helper traced")

        // The window's heights after each click: a jump goes straight from the old height
        // to the new; a resize passes heights between. A tab built the first time can keep
        // the app (and so the sampling) busy through its resize, so not every change shows
        // its steps; the jumps before (main, 2026-11-13) showed none in 11.
        let trace = try String(contentsOfFile: "/tmp/hermesapp-settings-trace.tsv", encoding: .utf8)
        var changes: [[Double]] = []
        for line in trace.split(separator: "\n") {
            let field = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if field.count == 3, field[1] == "click" {
                changes.append([])
            } else if field.count == 7, Set(tabs).contains(field[2]), let height = Double(field[6]),
                      !changes.isEmpty, changes[changes.count - 1].last != height {
                changes[changes.count - 1].append(height)
            }
        }
        let resizes = changes.filter { $0.count >= 2 && abs($0[$0.count - 1] - $0[0]) > 40 }
        let smooth = resizes.filter { $0.count >= 4 }
        XCTAssertGreaterThanOrEqual(resizes.count, 8, "the tabs changed the window's height: \(changes)")
        XCTAssertGreaterThanOrEqual(smooth.count * 2, resizes.count,
                                    "most resizes pass the heights between: \(changes)")
    }
}
#endif
