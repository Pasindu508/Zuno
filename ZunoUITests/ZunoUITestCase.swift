import XCTest

/// Base class: launches Zuno against the deterministic development backend with stubbed
/// providers (Apple, Google, biometrics, camera). No network or credentials are needed.
class ZunoUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @discardableResult
    func launch(signedIn: Bool = true, onboarding: Bool = false, organizer: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-zuno-dev-backend", "-zuno-reset", "-zuno-stub-providers"]
        if signedIn { arguments.append("-zuno-signed-in") }
        if !onboarding && !signedIn { arguments.append("-zuno-skip-onboarding") }
        if organizer { arguments.append("-zuno-organizer") }
        // Extra arguments from the environment (scripts/screenshots.sh passes -zuno-light).
        let environmentExtra = ProcessInfo.processInfo.environment["ZUNO_EXTRA_LAUNCH_ARGS"]?
            .split(separator: " ").map(String.init) ?? []
        app.launchArguments = arguments + extra + environmentExtra
        app.launch()
        self.app = app
        return app
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Timed out waiting for \(element)", file: file, line: line)
        return element
    }

    func tap(_ identifier: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let target = waitFor(element(identifier), timeout: timeout, file: file, line: line)
        target.tap()
    }

    func tapButton(_ label: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(app.buttons[label].firstMatch, timeout: timeout, file: file, line: line).tap()
    }

    /// Taps a tab through the native tab bar (labels: Home, Calendar, Tickets, Profile).
    func openTab(_ label: String) {
        let button = app.tabBars.buttons[label].firstMatch
        if button.waitForExistence(timeout: 10) {
            button.tap()
        } else {
            tap("tab.\(label.lowercased())")
        }
    }

    func openFirstEvent() {
        let card = waitFor(app.buttons.matching(identifier: "event.card").firstMatch, timeout: 15)
        card.tap()
        waitFor(element("detail.title"), timeout: 10)
    }

    func openEvent(titled title: String) {
        let field = waitFor(element("search.field"))
        field.tap()
        field.typeText(title)
        let card = app.buttons.matching(identifier: "event.card").matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        waitFor(card, timeout: 10).tap()
        waitFor(element("detail.title"), timeout: 10)
    }

    enum ScrollDirection { case down, up }

    /// Scrolls until the element exists and is hittable (`.down` reveals content below).
    func scrollTo(_ element: XCUIElement, direction: ScrollDirection = .down, maxSwipes: Int = 12) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            switch direction {
            case .down: app.swipeUp(velocity: .slow)
            case .up: app.swipeDown(velocity: .slow)
            }
            swipes += 1
        }
    }

    /// Polls a condition on the main run loop (avoids sending the test case across isolation).
    @discardableResult
    func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Attaches a named screenshot to the result bundle (exported for visual review).
    func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
