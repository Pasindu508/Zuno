import XCTest

/// Visits every main screen and attaches screenshots for visual review against the
/// references. Run per device with scripts/screenshots.sh.
final class ScreenshotTour: ZunoUITestCase {
    func testTour() {
        launch()
        waitFor(app.buttons.matching(identifier: "event.card").firstMatch, timeout: 15)
        sleep(1)
        snapshot("01-home")

        app.swipeUp(velocity: .slow)
        snapshot("02-home-scrolled")
        app.swipeDown(velocity: .fast)

        tap("home.filters")
        sleep(1)
        snapshot("03-filters")
        app.buttons["Close filters"].firstMatch.tap()

        let field = waitFor(element("search.field"))
        field.tap()
        field.typeText("Colombo")
        sleep(1)
        snapshot("04-search")
        tap("search.close")

        openEvent(titled: "Kandyan")
        sleep(1)
        snapshot("05-detail")
        app.swipeUp(velocity: .slow)
        snapshot("06-detail-scrolled")
        app.swipeUp(velocity: .slow)
        snapshot("07-detail-more")
        tap("detail.back")

        openTab("Calendar")
        sleep(1)
        snapshot("08-calendar")

        openTab("Tickets")
        sleep(1)
        snapshot("09-tickets")
        app.buttons.matching(identifier: "tickets.row").firstMatch.tap()
        waitFor(element("ticket.qr"))
        snapshot("10-ticket")
        app.navigationBars.buttons.firstMatch.tap()

        openTab("Profile")
        sleep(1)
        snapshot("11-profile")
        tap("profile.wallet")
        waitFor(element("wallet.balance"), timeout: 10)
        snapshot("12-wallet")
        app.navigationBars.buttons.firstMatch.tap()

        openTab("Home")
        tap("home.notifications")
        waitFor(element("notifications.view"))
        snapshot("13-notifications")
    }

    func testOrganizerTour() {
        launch(organizer: true, extra: ["-zuno-biometric", "success", "-zuno-scanner-code", "ZN-TEST-0001"])
        openTab("Profile")
        tap("profile.organizer")
        waitFor(element("organizer.home"))
        sleep(1)
        snapshot("20-organizer")
        app.buttons.matching(identifier: "organizer.event").firstMatch.tap()
        waitFor(element("organizer.eventView"))
        snapshot("21-organizer-event")
        tap("organizer.scan")
        waitFor(element("checkin.result.valid"), timeout: 15)
        snapshot("22-checkin")
    }

    func testOnboardingTour() {
        launch(signedIn: false, onboarding: true)
        waitFor(element("onboarding.view"))
        sleep(1)
        snapshot("30-onboarding")
        tap("onboarding.continue")
        tap("onboarding.continue")
        tap("onboarding.continue")
        waitFor(element("auth.view"))
        snapshot("31-auth")
    }
}
