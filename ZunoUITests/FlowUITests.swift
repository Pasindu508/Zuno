import XCTest

final class OnboardingAndAuthUITests: ZunoUITestCase {
    func test01_Onboarding() {
        launch(signedIn: false, onboarding: true)
        waitFor(element("onboarding.view"))
        snapshot("onboarding-1")
        tap("onboarding.continue")
        tap("onboarding.continue")
        snapshot("onboarding-3")
        waitFor(element("onboarding.explore"))
        tap("onboarding.continue")
        waitFor(element("auth.view"))
        snapshot("auth")
    }

    func test02_AppleSignInTestState() {
        launch(signedIn: false)
        waitFor(element("auth.view"))
        waitFor(element("auth.apple")).tap()
        waitFor(element("profile.setup"), timeout: 10)
        let name = waitFor(element("profile.name"))
        XCTAssertEqual(name.value as? String, "Nethmi Perera", "Apple's first-authorization name is saved")
        snapshot("profile-setup")
        tap("profile.continue")
        waitFor(element("identity.view"))
        snapshot("identity")
        let nic = waitFor(element("identity.nic"))
        nic.tap()
        nic.typeText("200045678912")
        tap("identity.submit")
        waitFor(element("identity.verified"))
        tap("identity.continue")
        waitFor(app.buttons.matching(identifier: "event.card").firstMatch, timeout: 15)
    }

    func test03_GoogleSignInTestState() {
        launch(signedIn: false)
        tap("auth.google")
        waitFor(element("profile.setup"), timeout: 10)
        tap("profile.continue")
        waitFor(element("identity.view"))
        tap("identity.later")
        waitFor(app.buttons.matching(identifier: "event.card").firstMatch, timeout: 15)
    }

    func test04_EmailSignIn() {
        launch(signedIn: false)
        // Wrong password first: an error is shown and nothing is signed in.
        tap("auth.email")
        let email = waitFor(element("email.address"))
        email.tap()
        email.typeText("dev.attendee@zuno.example")
        let password = waitFor(element("email.password"))
        password.tap()
        password.typeText("wrong-password")
        tap("email.submit")
        waitFor(element("email.error"))
        snapshot("email-error")
        app.buttons["Close"].firstMatch.tap()

        // Fresh sheet, correct credentials (wait for the previous sheet to finish dismissing).
        XCTAssertTrue(waitUntil { !self.element("email.address").exists })
        sleep(1) // SwiftUI ignores a new sheet while the previous one is still dismissing
        snapshot("email-closed")
        tap("auth.email")
        sleep(2)
        snapshot("email-reopened")
        let email2 = waitFor(element("email.address"))
        XCTAssertTrue(waitUntil {
            email2.tap()
            return (email2.value(forKey: "hasKeyboardFocus") as? Bool) == true
        })
        email2.typeText("dev.attendee@zuno.example")
        let password2 = waitFor(element("email.password"))
        password2.tap()
        password2.typeText("correct-horse-42")
        tap("email.submit")
        waitFor(app.buttons.matching(identifier: "event.card").firstMatch, timeout: 15)
    }
}

final class DiscoveryUITests: ZunoUITestCase {
    func test05_HomeLoading() {
        launch()
        waitFor(element("home.location"))
        waitFor(app.buttons.matching(identifier: "event.card").firstMatch, timeout: 15)
        XCTAssertTrue(element("home.section.recommended").exists)
        snapshot("home")
    }

    func test06_CategorySelection() {
        launch()
        waitFor(app.buttons.matching(identifier: "event.card").firstMatch, timeout: 15)
        let art = waitFor(element("category.art"))
        // Drag the capsule row until Art is fully on screen (it starts beyond the trailing edge).
        let window = app.windows.firstMatch.frame
        var drags = 0
        while art.frame.maxX > window.maxX - 12 && drags < 6 {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: window.width * 0.85, dy: art.frame.midY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: window.width * 0.35, dy: art.frame.midY)))
            drags += 1
        }
        art.tap()
        XCTAssertTrue(art.isSelected)
        let card = app.buttons.matching(identifier: "event.card").firstMatch
        waitFor(card)
        XCTAssertTrue(card.label.contains("Island Light") || card.label.contains("Golden Hour"), card.label)
        snapshot("category-art")
    }

    func test07_Search() {
        launch()
        let field = waitFor(element("search.field"))
        field.tap()
        waitFor(element("search.close"))
        snapshot("search-idle")
        field.typeText("Negombo")
        let count = waitFor(element("search.count"))
        XCTAssertTrue(count.label.contains("1"), count.label)
        snapshot("search-results")
        tap("search.close")
        waitFor(element("category.for-you"))
    }

    func test08_Filters() {
        launch()
        tap("home.filters")
        waitFor(app.buttons["Free"].firstMatch).tap()
        snapshot("filters")
        tap("filters.apply")
        let badge = waitFor(element("home.filters"))
        XCTAssertTrue(badge.label.contains("1 active"), badge.label)
    }

    func test09_EventCardTransition() {
        launch()
        openFirstEvent()
        tap("detail.back")
        waitFor(app.buttons.matching(identifier: "event.card").firstMatch)
    }

    func test10_EventDetails() {
        launch()
        openEvent(titled: "Jazz")
        XCTAssertTrue(element("detail.datePill").exists)
        XCTAssertTrue(element("detail.share").exists)
        XCTAssertTrue(element("event.favorite").exists)
        let action = element("detail.primaryAction")
        XCTAssertEqual(action.label, "View ticket", "the development user already holds Jazz tickets")
        snapshot("detail-jazz")
        element("event.favorite").tap()
    }
}

final class RegistrationAndPaymentUITests: ZunoUITestCase {
    func test11_FreeRegistration() {
        launch()
        openEvent(titled: "Northern")
        tap("detail.primaryAction")
        waitFor(element("registration.allowance"))
        snapshot("registration-quote")
        tap("registration.confirm")
        waitFor(element("registration.confirmed"), timeout: 10)
        XCTAssertTrue(element("ticket.qr").exists)
        snapshot("registration-confirmed")
        tap("registration.done")
        let action = waitFor(element("detail.primaryAction"))
        XCTAssertTrue(waitUntil { action.label == "View ticket" }, action.label)
    }

    func test12_PaidCheckoutTestState() {
        launch()
        openEvent(titled: "Kandyan")
        tap("detail.primaryAction")
        waitFor(element("checkout.summary"))
        let phone = waitFor(element("checkout.phone"))
        XCTAssertEqual(phone.value as? String, "+94771234567")
        snapshot("checkout")
        tap("checkout.pay")
        tap("simulator.approve")
        waitFor(element("payment.receipt"), timeout: 15)
        snapshot("checkout-paid")
        tap("checkout.viewTickets")
    }

    func test13_TicketDisplay() {
        launch()
        openTab("Tickets")
        let row = waitFor(app.buttons.matching(identifier: "tickets.row").firstMatch, timeout: 10)
        snapshot("tickets")
        row.tap()
        waitFor(element("ticket.qr"))
        snapshot("ticket-detail")
    }

    func test14_Wallet() {
        launch(extra: ["-zuno-biometric", "success"])
        openTab("Profile")
        waitFor(element("profile.view"))
        tap("profile.wallet")
        let balance = waitFor(element("wallet.balance"), timeout: 10)
        XCTAssertEqual(balance.label, "LKR 140.00")
        snapshot("wallet")
        tap("wallet.topUp")
        tapButton("LKR 1,000")
        tap("wallet.pay")
        tap("simulator.approve")
        waitFor(element("payment.receipt"), timeout: 15)
    }

    func test15_BiometricGateTestState() {
        launch(extra: ["-zuno-biometric", "failure"])
        openTab("Profile")
        waitFor(element("profile.view"))
        let lock = waitFor(element("profile.appLock"))
        // Turning App Lock on itself requires authentication; with a failing authenticator it stays off.
        lock.switches.firstMatch.tap()
        XCTAssertEqual(lock.switches.firstMatch.value as? String, "0")
        app.terminate()

        launch(extra: ["-zuno-biometric", "success"])
        openTab("Profile")
        let enabled = waitFor(element("profile.appLock"))
        enabled.switches.firstMatch.tap()
        XCTAssertTrue(waitUntil { (enabled.switches.firstMatch.value as? String) == "1" })
        for _ in 0..<3 { app.swipeDown(velocity: .fast) } // back to the top, clear of the nav bar
        tap("profile.wallet")
        let unlocked = element("wallet.balance").waitForExistence(timeout: 10)
        snapshot("app-lock-wallet")
        XCTAssertTrue(unlocked, "App Lock on + successful authentication shows the wallet")
    }
}

final class OrganizerUITests: ZunoUITestCase {
    func test16_QRScanningTestState() {
        launch(organizer: true, extra: ["-zuno-biometric", "success", "-zuno-scanner-code", "ZN-TEST-0001"])
        openTab("Profile")
        tap("profile.organizer")
        waitFor(element("organizer.home"))
        snapshot("organizer-dashboard")
        let climate = app.buttons.matching(identifier: "organizer.event").matching(NSPredicate(format: "label CONTAINS %@", "Climate")).firstMatch
        waitFor(climate).tap()
        waitFor(element("organizer.eventView"))
        snapshot("organizer-event")
        tap("organizer.scan")
        waitFor(element("checkin.result.valid"), timeout: 15)
        snapshot("checkin-valid")
        let manual = waitFor(element("checkin.manualCode"))
        manual.tap()
        manual.typeText("ZN-TEST-0001")
        tap("checkin.manualSubmit")
        waitFor(element("checkin.result.already_used"), timeout: 10)
        snapshot("checkin-already-used")
    }

    func test17_OrganizerEventCreation() {
        launch(organizer: true, extra: ["-zuno-biometric", "success"])
        openTab("Profile")
        tap("profile.organizer")
        tap("organizer.newEvent")
        waitFor(element("editor.view"))
        let title = waitFor(element("editor.title"))
        title.tap()
        title.typeText("Swift Concurrency Clinic")
        let summary = element("editor.summary")
        summary.tap()
        summary.typeText("A practical evening on actors and tasks")
        snapshot("editor")
        let save = element("editor.save")
        scrollTo(save)
        save.tap()
        waitFor(app.staticTexts["Draft saved."], timeout: 10)
        let aiAgenda = element("editor.aiAgenda")
        scrollTo(aiAgenda, direction: .up)
        aiAgenda.tap()
        tap("ai.generate")
        waitFor(element("ai.approve"), timeout: 15)
        snapshot("ai-agenda")
        tap("ai.approve")
        let added = app.staticTexts["AI suggestions added. Review them before publishing."]
        scrollTo(added, direction: .down)
        XCTAssertTrue(added.exists)
    }
}
