import XCTest

/// Drives the app into states that can't be reached from launch arguments alone and
/// attaches screenshots. Skipped unless the runner is started with
/// `TEST_RUNNER_EARSHOT_SCREENSHOTS=1`, so the normal suite stays fast.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testCaptureFlowScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EARSHOT_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_EARSHOT_SCREENSHOTS=1 to capture screenshots")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "populated"]
        app.launch()

        let tomas = app.buttons["nearby.connect.Tomás"]
        XCTAssertTrue(tomas.waitForExistence(timeout: 20))
        tomas.tap()
        let priya = app.buttons["nearby.connect.Priya Raman"]
        XCTAssertTrue(priya.waitForExistence(timeout: 5))
        priya.tap()
        XCTAssertTrue(app.buttons["nearby.cancel.Tomás"].waitForExistence(timeout: 5))
        attach(app, "nearby-waiting")

        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("Hi Priya! Which exit are you nearest?")
        app.buttons["chat.send"].tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Got it")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        composer.typeText("Great, I'll head your way.")
        app.buttons["chat.send"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "chat.lastStatus").firstMatch
        let delivered = expectation(for: NSPredicate(format: "label CONTAINS %@", "Delivered"), evaluatedWith: status)
        wait(for: [delivered], timeout: 20)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "north entrance"))
                        .firstMatch.waitForExistence(timeout: 20))
        // Visit contact details and come back: a clean way to put the keyboard away.
        app.buttons["chat.details"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "contact.safetyCode").firstMatch.waitForExistence(timeout: 5))
        attach(app, "contact-new")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        sleep(1) // let the transcript settle on the newest message before capturing
        attach(app, "chat-new-contact")

        app.navigationBars.buttons.firstMatch.tap()
        let retry = app.buttons["nearby.retry.Tomás"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        attach(app, "nearby-failed")
    }

    @MainActor
    func testCaptureOnboardingScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EARSHOT_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_EARSHOT_SCREENSHOTS=1 to capture screenshots")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "firstRun"]
        app.launch()

        let next = app.buttons["onboarding.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        next.tap()
        let field = app.textFields["onboarding.nameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Sam")
        attach(app, "onboarding-name")
        next.tap()
        XCTAssertTrue(app.buttons["onboarding.turnOn"].waitForExistence(timeout: 10))
        sleep(1)
        attach(app, "onboarding-how-it-works")
    }

    @MainActor
    func testCaptureNotificationExplainer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EARSHOT_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_EARSHOT_SCREENSHOTS=1 to capture screenshots")
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "populated", "-demoNotificationPrompt"]
        app.launch()
        let priya = app.buttons["nearby.connect.Priya Raman"]
        XCTAssertTrue(priya.waitForExistence(timeout: 20))
        priya.tap()
        XCTAssertTrue(app.buttons["notifications.offer.notNow"].waitForExistence(timeout: 25))
        sleep(1)
        attach(app, "notifications-offer")
    }

    /// Needs notifications already allowed for Earshot in this Simulator; it never asks for them.
    @MainActor
    func testCaptureNotificationBanner() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EARSHOT_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_EARSHOT_SCREENSHOTS=1 to capture screenshots")
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "populated"]
        app.launch()
        let maya = app.buttons["conversation.Maya Okafor"]
        XCTAssertTrue(maya.waitForExistence(timeout: 20))
        maya.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("On the platform now")
        app.buttons["chat.send"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Maya Okafor")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "notification-banner"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
