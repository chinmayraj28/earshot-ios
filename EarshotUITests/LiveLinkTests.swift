import XCTest

/// A real link, not demo mode: the app in the Simulator talks to `earshot-probe`
/// running on the Mac, over the Simulator's radio layer (MultipeerConnectivity).
///
/// Run with `Scripts/e2e.sh`, which starts the probe and sets the switch below.
/// It is skipped in a normal test run because it needs that second process.
final class LiveLinkTests: XCTestCase {
    @MainActor
    func testRequestMessageReceiptAndReplyOverARealLink() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EARSHOT_LIVE"] == "1",
                          "Run Scripts/e2e.sh to exercise a real link")
        continueAfterFailure = false

        // The Simulator may ask for Local Network access the first time.
        addUIInterruptionMonitor(withDescription: "Local Network") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ephemeral", "-useSamplePhoto"]
        app.launch()

        tap(app.buttons["onboarding.continue"])
        let field = app.textFields["onboarding.nameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Simulator Sam")
        tap(app.buttons["onboarding.continue"])
        tap(app.buttons["onboarding.turnOn"])

        // The probe announces itself as "Probe" and accepts every request.
        tap(app.buttons["nearby.connect.Probe"], timeout: 60)

        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 60), "The accepted request should open the chat")
        composer.tap()
        composer.typeText("Hello over the air")
        tap(app.buttons["chat.send"])

        let status = element(app, "chat.lastStatus")
        let delivered = expectation(for: NSPredicate(format: "label CONTAINS 'Delivered'"), evaluatedWith: status)
        wait(for: [delivered], timeout: 30)

        let echo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Echo: Hello over the air'")).firstMatch
        XCTAssertTrue(echo.waitForExistence(timeout: 30), "The probe's reply should arrive")

        // A photo each way: ours to the probe, and the probe's generated picture back.
        tap(app.buttons["chat.attach"])
        XCTAssertTrue(element(app, "chat.staged").waitForExistence(timeout: 10))
        tap(app.buttons["chat.send"])
        // The probe only answers once it has received and checked ours.
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Photo. Test picture'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60), "The probe's photo should arrive")
        let photoDelivered = expectation(for: NSPredicate(format: "label CONTAINS 'Delivered'"), evaluatedWith: status)
        wait(for: [photoDelivered], timeout: 30)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        wait(for: [hittable], timeout: timeout)
        element.tap()
    }
}
