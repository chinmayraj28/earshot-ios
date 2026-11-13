import XCTest

/// End-to-end flows against demo mode (`-demo ...`). Every "other phone" is a real
/// Earshot engine on an in-memory radio, so these exercise the real request,
/// handshake and delivery logic.
final class EarshotUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: Flows

    @MainActor
    func testFirstRunOnboardingReachesHome() {
        let app = launch("-demo", "firstRun")

        tap(app.buttons["onboarding.continue"])
        let field = app.textFields["onboarding.nameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Name field should appear on step 2")
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "",
                       "Name must not be prefilled")
        field.tap()
        field.typeText("Sam")
        tap(app.buttons["onboarding.continue"])

        let turnOn = app.buttons["onboarding.turnOn"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10))
        let note = element(app, "onboarding.permissionNote")
        XCTAssertTrue(note.exists && note.label.contains("Bluetooth"),
                      "The Bluetooth permission prompt must be explained right above the button")
        turnOn.tap()

        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10), "Home should appear")
        XCTAssertTrue(element(app, "nearby.peer.Aubrey Graham").waitForExistence(timeout: 20),
                      "People nearby should be listed once Earshot is on")
    }

    @MainActor
    func testConnectToNewPersonThenChatAndGetReply() {
        let app = launch("-demo", "populated")

        tap(app.buttons["nearby.connect.Aubrey Graham"], timeout: 20)

        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 25), "Accepted request should open the chat")
        XCTAssertTrue(element(app, "chat.title").label.contains("Aubrey Graham"))
        XCTAssertFalse(element(app, "notifications.offer").exists,
                       "Demo mode must not show the notification explainer without -demoNotificationPrompt")

        composer.tap()
        composer.typeText("Hi Aubrey, I'm by the stairs")
        tap(app.buttons["chat.send"])

        XCTAssertTrue(element(app, "Hi Aubrey, I'm by the stairs", labelContains: true).waitForExistence(timeout: 5),
                      "Sent bubble should appear")
        waitForLabel(element(app, "chat.lastStatus"), toContain: "Delivered", timeout: 20)
        let reply = element(app, "Got it", labelContains: true)
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "Aubrey's reply should arrive")
        let visible = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: reply)],
                                       timeout: 5)
        XCTAssertEqual(visible, .completed, "The transcript should follow the new reply into view")
    }

    @MainActor
    func testUnansweredRequestShowsFailureWithTryAgain() {
        let app = launch("-demo", "populated")

        tap(app.buttons["nearby.connect.Tomás"], timeout: 20)
        XCTAssertTrue(element(app, "nearby.cancel.Tomás").waitForExistence(timeout: 10),
                      "A waiting state with Cancel should show while Tomás decides")

        let retry = app.buttons["nearby.retry.Tomás"]
        XCTAssertTrue(retry.waitForExistence(timeout: 25), "Failure state should offer Try again")
        let failure = element(app, "nearby.failure.Tomás")
        XCTAssertTrue(failure.exists)
        XCTAssertTrue(failure.label.contains("No answer"), "Got: \(failure.label)")
        XCTAssertTrue(app.buttons["nearby.dismiss.Tomás"].exists)
        XCTAssertFalse(element(app, "chat.composer").exists, "No chat should open")

        tap(app.buttons["nearby.dismiss.Tomás"])
        XCTAssertTrue(app.buttons["nearby.connect.Tomás"].waitForExistence(timeout: 10),
                      "Dismissing returns the row to Connect")
    }

    @MainActor
    func testIncomingRequestAccepted() {
        let app = launch("-demo", "populated", "-demoRequest")

        let accept = app.buttons["request.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 25), "Incoming request sheet should appear")
        XCTAssertTrue(app.buttons["request.decline"].exists)
        XCTAssertTrue(element(app, "request.title").label.contains("Noor Haddad"))
        accept.tap()

        XCTAssertTrue(element(app, "chat.composer").waitForExistence(timeout: 25), "Chat should open after accepting")
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.contains("Noor Haddad"), "Got: \(title.label)")
        XCTAssertFalse(app.buttons["request.accept"].exists, "The sheet should be gone")
    }

    @MainActor
    func testMessageToOutOfRangeContactWaits() {
        let app = launch("-demo", "populated")

        tap(app.buttons["conversation.Alice Huang"], timeout: 20)
        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "chat.banner").waitForExistence(timeout: 10),
                      "An out-of-range banner should explain that messages will wait")

        composer.tap()
        composer.typeText("Meet at the gate?")
        tap(app.buttons["chat.send"])

        XCTAssertTrue(element(app, "Meet at the gate?", labelContains: true).waitForExistence(timeout: 5))
        let status = element(app, "chat.lastStatus")
        waitForLabel(status, toContain: "Waiting", timeout: 10)
        XCTAssertTrue(status.label.contains("Alice"), "Got: \(status.label)")
    }

    @MainActor
    func testContactWalkingAwayExplainsThatMessagesWillWait() {
        // Debug-only argument: Jensen walks out of range about 6 s after launch.
        let app = launch("-demo", "populated", "-demoLeave", "Jensen Huang")

        tap(app.buttons["conversation.Jensen Huang"], timeout: 20)
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let banner = element(app, "chat.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "A banner should appear when Jensen leaves")
        XCTAssertTrue(banner.label.contains("moved out of range"), "Got: \(banner.label)")

        let composer = element(app, "chat.composer")
        composer.tap()
        composer.typeText("Back at the stairs")
        tap(app.buttons["chat.send"])
        // Jensen's demo phone shares relay keys with ours, so the message may be sealed for friends
        // to carry; either way it is Waiting for Jensen and not delivered.
        let status = element(app, "chat.lastStatus")
        waitForLabel(status, toContain: "Waiting", timeout: 10)
        XCTAssertTrue(status.label.contains("Jensen"), "Got: \(status.label)")
    }

    @MainActor
    func testNotificationExplainerAppearsAfterFirstContactAndCanBeDismissed() {
        let app = launch("-demo", "populated", "-demoNotificationPrompt")

        tap(app.buttons["nearby.connect.Aubrey Graham"], timeout: 20)
        XCTAssertTrue(element(app, "chat.composer").waitForExistence(timeout: 25))

        let card = element(app, "notifications.offer")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The explainer should follow the first new contact")
        XCTAssertTrue(element(app, "Get notified when a message arrives", labelContains: true).exists)
        XCTAssertTrue(app.buttons["notifications.offer.allow"].exists)
        // "Allow" would raise the real system alert, so the test only uses "Not now".
        tap(app.buttons["notifications.offer.notNow"])

        let gone = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)],
                                    timeout: 5)
        XCTAssertEqual(gone, .completed, "Not now should hide the explainer")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "No system permission alert should appear")
        XCTAssertTrue(element(app, "chat.composer").isHittable, "The chat stays usable")
    }

    /// Runs only where notifications are already allowed for Earshot (it never asks for them,
    /// so it never raises the system alert). Skipped otherwise.
    @MainActor
    func testReplyWhileElsewhereNotifiesAndTapOpensChat() throws {
        let app = launch("-demo", "populated")

        tap(app.buttons["home.settings"], timeout: 20)
        XCTAssertTrue(element(app, "settings.notifications").waitForExistence(timeout: 10))
        let allowed = !app.buttons["settings.notifications.turnOn"].exists
            && !app.buttons["settings.notifications.openSettings"].exists
        try XCTSkipUnless(allowed, "Notifications aren't allowed for Earshot in this Simulator")
        app.navigationBars.buttons.firstMatch.tap()

        tap(app.buttons["conversation.Jensen Huang"], timeout: 10)
        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Where are you?")
        tap(app.buttons["chat.send"])
        // Leave the conversation before Jensen's reply arrives (~2 s).
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Jensen Huang")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "A banner should announce the reply")
        XCTAssertTrue(banner.label.contains("New message"), "Message text is hidden by default. Got: \(banner.label)")
        banner.tap()

        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(title.label.contains("Jensen Huang"), "Tapping should open the conversation. Got: \(title.label)")
    }

    @MainActor
    func testSettingsReachableAndExplainsHowItWorks() {
        let app = launch("-demo", "populated")

        tap(app.buttons["home.settings"], timeout: 20)
        XCTAssertTrue(app.switches["settings.visible"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "settings.notifications").exists, "Settings should show the notification state")
        let showText = app.switches["settings.notifications.showText"]
        XCTAssertTrue(showText.exists)
        XCTAssertEqual(showText.value as? String, "0", "Message text in notifications is off by default")
        let howItWorks = app.buttons["How Earshot works"]
        for _ in 0..<6 where !(howItWorks.exists && howItWorks.isHittable) { app.swipeUp() }
        tap(howItWorks)
        XCTAssertTrue(app.staticTexts["Short range"].waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Finds an element of any type by identifier, or by label when `labelContains` is set.
    @MainActor
    private func element(_ app: XCUIApplication, _ key: String, labelContains: Bool = false) -> XCUIElement {
        if labelContains {
            return app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", key)).firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: key).firstMatch
    }

    @MainActor
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        wait(for: [hittable], timeout: timeout)
        element.tap()
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, toContain text: String, timeout: TimeInterval,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "Expected label containing \"\(text)\", got \"\(element.exists ? element.label : "<missing>")\"",
                       file: file, line: line)
    }
}

private extension XCUIElementQuery {
    func containing(label: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "label CONTAINS %@", label))
    }
}
