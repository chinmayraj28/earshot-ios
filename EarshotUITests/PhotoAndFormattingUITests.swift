import XCTest

/// Formatting and photos, against demo mode. Demo people are real Earshot engines, so a
/// photo really travels in pieces over the in-memory radio and is checked before "Delivered".
final class PhotoAndFormattingUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: Formatting

    @MainActor
    func testFormattedMessageShowsStylesAndATappableLink() {
        let app = launch("-demo", "populated")
        tap(app.buttons["conversation.Maya Okafor"], timeout: 20)
        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("see *you* at https://example.com/a_b ok_")
        tap(app.buttons["chat.send"])

        // VoiceOver reads it as it looks: markers that took effect are gone, the trailing "ok_" stays.
        let bubble = element(app, "You: see you at https://example.com/a_b ok_", labelContains: true)
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "The formatted bubble should be read without its markers")
        // The link is its own element, intact (underscores and all), and can be tapped.
        let link = app.links["https://example.com/a_b"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "The detected link should be a link element")
        XCTAssertTrue(link.isHittable)
        link.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Tapping the link hands it to the system")
        app.activate()
    }

    // MARK: Photos

    @MainActor
    func testSendingAPhotoShowsProgressThenDelivered() {
        let app = launch("-demo", "populated", "-useSamplePhoto")
        tap(app.buttons["conversation.Maya Okafor"], timeout: 20)
        let attach = app.buttons["chat.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        waitForLabel(element(app, "chat.title"), toContain: "Maya", timeout: 5)
        // Maya connects a moment after launch; until then the button explains instead.
        let connected = element(app, "Connected", labelContains: true)
        XCTAssertTrue(connected.waitForExistence(timeout: 15))
        tap(attach)

        let staged = element(app, "chat.staged")
        XCTAssertTrue(staged.waitForExistence(timeout: 5), "The picked photo waits above the field")
        XCTAssertTrue(staged.label.contains("location and camera details removed"), "Got: \(staged.label)")
        let composer = element(app, "chat.composer")
        focus(app, composer)
        composer.typeText("Platform 3, by the _clock_")
        tap(app.buttons["chat.send"])

        let bubble = element(app, "You: Photo. Platform 3, by the clock", labelContains: true)
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "The photo bubble should appear with its caption")
        XCTAssertFalse(staged.exists, "The composer is cleared after sending")
        waitForLabel(element(app, "chat.lastStatus"), toContain: "Delivered", timeout: 30)
        XCTAssertTrue(element(app, "Got the photo", labelContains: true).waitForExistence(timeout: 20),
                      "Maya's phone received it and replied")
    }

    @MainActor
    func testPhotoOpensFullScreenWithShareAndDelete() {
        let app = launch("-demo", "populated")
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)
        let photo = app.buttons["chat.photo"]
        tap(photo, timeout: 10)

        let image = element(app, "viewer.image")
        XCTAssertTrue(image.waitForExistence(timeout: 10), "The viewer should show the photo")
        XCTAssertTrue(image.label.contains("Photo from Jonas. The queue for the food trucks"), "Got: \(image.label)")
        XCTAssertTrue(app.buttons["viewer.share"].exists)
        image.doubleTap() // zoom in, then out
        image.doubleTap()

        tap(app.buttons["viewer.delete"])
        let confirm = app.buttons["Delete from This Phone"]
        tap(confirm, timeout: 5)
        XCTAssertTrue(element(app, "chat.composer").waitForExistence(timeout: 10), "Back in the chat")
        let gone = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"),
                                                      evaluatedWith: app.buttons["chat.photo"])], timeout: 5)
        XCTAssertEqual(gone, .completed, "The deleted photo is no longer in the conversation")
    }

    /// The share sheet works with no photo-library permission at all. Verified here: without
    /// an `NSPhotoLibraryAddUsageDescription` string, iOS leaves "Save Image" out of the sheet
    /// (it offers Copy, Save to Files, AirDrop and other apps instead). Adding that string
    /// would bring back "Save Image" together with a one-time permission prompt, so it is not added.
    @MainActor
    func testShareSheetOpensWithoutAskingForPhotoAccess() throws {
        let app = launch("-demo", "populated")
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)
        tap(app.buttons["chat.photo"], timeout: 10)
        tap(app.buttons["viewer.share"], timeout: 10)
        let copy = app.cells.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 15), "The share sheet should open with the photo")
        XCTAssertFalse(app.cells.matching(NSPredicate(format: "label == %@", "Save Image")).firstMatch.exists)
        copy.tap()
        sleep(1)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "No permission prompt")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element(app, "viewer.image").exists, "Back on the photo")
    }

    @MainActor
    func testAttachExplainsWhyPhotosAreUnavailable() {
        let app = launch("-demo", "populated")

        // Jonas is out of range: photos are only sent over a live link.
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)
        let attach = app.buttons["chat.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        XCTAssertEqual(attach.value as? String, "Unavailable")
        tap(attach)
        let help = element(app, "chat.attachUnavailable")
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        XCTAssertTrue(help.label.contains("only be sent while you and Jonas are connected"), "Got: \(help.label)")
        app.navigationBars.buttons.firstMatch.tap()

        // Priya runs an older Earshot: connected, texting works, photos don't.
        tap(app.buttons["nearby.connect.Priya Raman"], timeout: 20)
        XCTAssertTrue(element(app, "chat.composer").waitForExistence(timeout: 25))
        waitForLabel(element(app, "chat.title"), toContain: "Priya", timeout: 5)
        tap(app.buttons["chat.attach"])
        let priyaHelp = element(app, "chat.attachUnavailable")
        XCTAssertTrue(priyaHelp.waitForExistence(timeout: 5))
        XCTAssertTrue(priyaHelp.label.contains("can't receive photos yet"), "Got: \(priyaHelp.label)")
    }

    // MARK: Screenshots

    /// Captures the new states for docs/screenshots. Skipped unless the runner is started with
    /// `TEST_RUNNER_EARSHOT_SCREENSHOTS=1`. Run once in light and once in dark appearance.
    @MainActor
    func testCapturePhotoAndFormattingScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EARSHOT_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_EARSHOT_SCREENSHOTS=1 to capture screenshots")
        let app = launch("-demo", "populated", "-useSamplePhoto")
        tap(app.buttons["conversation.Maya Okafor"], timeout: 20)
        XCTAssertTrue(element(app, "Connected", labelContains: true).waitForExistence(timeout: 15))
        let composer = element(app, "chat.composer")
        composer.tap()
        composer.typeText("Meet at *gate 4*, map: https://example.com/station_map or call +44 20 7946 0958 ~maybe~")
        tap(app.buttons["chat.send"])
        XCTAssertTrue(app.links.firstMatch.waitForExistence(timeout: 5))
        tap(app.buttons["chat.attach"])
        XCTAssertTrue(element(app, "chat.staged").waitForExistence(timeout: 5))
        focus(app, composer)
        composer.typeText("Platform 3, by the _clock_")
        sleep(1)
        attach(app, "photo-staged")
        tap(app.buttons["chat.send"])
        waitForLabel(element(app, "chat.lastStatus"), toContain: "Sending photo", timeout: 5)
        attach(app, "photo-sending")
        waitForLabel(element(app, "chat.lastStatus"), toContain: "Delivered", timeout: 30)
        XCTAssertTrue(element(app, "Got it", labelContains: true).waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "Got the photo", labelContains: true).waitForExistence(timeout: 20))
        sleep(1)
        attach(app, "chat-formatting-and-photo")

        composer.tap()
        composer.typeText("Can you send a photo of the board?")
        tap(app.buttons["chat.send"])
        XCTAssertTrue(element(app, "chat.incomingPhoto").waitForExistence(timeout: 20))
        attach(app, "photo-receiving")
        XCTAssertTrue(element(app, "Photo. Here you go", labelContains: true).waitForExistence(timeout: 30))

        tap(app.buttons["chat.photo"].firstMatch)
        XCTAssertTrue(element(app, "viewer.image").waitForExistence(timeout: 10))
        sleep(1)
        attach(app, "photo-viewer")
        tap(app.buttons["viewer.close"])

        app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["conversation.Jonas Weber"], timeout: 10)
        tap(app.buttons["chat.attach"])
        XCTAssertTrue(element(app, "chat.attachUnavailable").waitForExistence(timeout: 5))
        attach(app, "photo-unavailable")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ key: String, labelContains: Bool = false) -> XCUIElement {
        if labelContains {
            return app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", key)).firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: key).firstMatch
    }

    /// Taps a text field and waits for the keyboard, so typing never races the layout.
    @MainActor
    private func focus(_ app: XCUIApplication, _ field: XCUIElement) {
        tap(field)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard should appear")
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

    @MainActor
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        wait(for: [hittable], timeout: timeout)
        element.tap()
    }
}
