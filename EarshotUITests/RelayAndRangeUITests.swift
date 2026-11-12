import XCTest

/// Relaying through friends and the Range test screen, in demo mode.
/// The relay states come from opt-in launch arguments (`-demoRelay …`), see LaunchOptions.swift.
final class RelayAndRangeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testRelaySwitchChangesFooterAndStaysOff() {
        let app = launch("-demo", "populated")
        openSettings(app)

        let toggle = app.switches["settings.relay"]
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1", "Relaying is on by default")
        let footer = element(app, "settings.relay.footer")
        XCTAssertTrue(footer.label.hasPrefix("On:"), "Got: \(footer.label)")

        toggle.switches.firstMatch.tap()
        waitForLabel(footer, toContain: "Off: this phone takes no part", timeout: 5)
        XCTAssertEqual(toggle.value as? String, "0")

        // Leave Settings and come back: the choice is kept.
        app.navigationBars.buttons.firstMatch.tap()
        openSettings(app)
        let again = app.switches["settings.relay"]
        scrollTo(again, in: app)
        XCTAssertEqual(again.value as? String, "0", "The switch should stay off")
        XCTAssertTrue(element(app, "settings.relay.footer").label.contains("connect directly"))
    }

    @MainActor
    func testSealedMessageCountsFriendsPhonesAndIsNotDelivered() {
        let app = launch("-demo", "populated", "-demoRelay", "sealed")
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)

        let status = element(app, "chat.lastStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("2 friends' phones have a copy"), "Got: \(status.label)")
        XCTAssertTrue(status.label.contains("Not delivered yet"), "Got: \(status.label)")
        XCTAssertTrue(element(app, "chat.banner").label.contains("messages can travel through friends"))
    }

    @MainActor
    func testSealedMessageWithOneFriendUsesSingular() {
        let app = launch("-demo", "populated", "-demoRelay", "sealed", "-demoRelayHandoffs", "1")
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)
        let status = element(app, "chat.lastStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("One friend's phone has a copy"), "Got: \(status.label)")
    }

    @MainActor
    func testDeliveredAndIncomingThroughFriendsAreMarked() {
        let app = launch("-demo", "populated", "-demoRelay", "delivered")
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)

        let status = element(app, "chat.lastStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Delivered"), "Got: \(status.label)")
        XCTAssertTrue(status.label.contains("through friends"), "Got: \(status.label)")
        let marker = element(app, "chat.viaFriends")
        XCTAssertTrue(marker.exists, "The reply that came through friends should be marked")
        XCTAssertEqual(marker.label, "Arrived through friends' phones")
    }

    @MainActor
    func testPlainWaitingWhenRelayingIsNotAvailable() {
        let app = launch("-demo", "populated")
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)
        let status = element(app, "chat.lastStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Waiting for Jonas"), "Got: \(status.label)")
        XCTAssertFalse(status.label.contains("ealed"))
        XCTAssertTrue(element(app, "chat.banner").label.contains("messages wait until you are near each other"))
    }

    @MainActor
    func testContactDetailsSaysWhenRelayingStarts() {
        let app = launch("-demo", "populated")
        tap(app.buttons["conversation.Jonas Weber"], timeout: 20)
        tap(app.buttons["chat.details"])
        let row = element(app, "contact.relay")
        scrollTo(row, in: app)
        XCTAssertTrue(row.label.contains("Relaying starts after you two next connect directly"), "Got: \(row.label)")
    }

    @MainActor
    func testCarriedMessagesShowAndCanBeDeleted() {
        let app = launch("-demo", "populated", "-demoRelay", "carrying")
        openSettings(app)
        let carrying = element(app, "settings.relay.carrying")
        scrollTo(carrying, in: app)
        XCTAssertTrue(carrying.label.hasPrefix("Carrying 3 sealed messages for friends"), "Got: \(carrying.label)")

        let delete = app.buttons["settings.relay.deleteCarried"]
        scrollTo(delete, in: app)
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                       "Delete Carried Messages", "settings.relay.deleteCarried")).firstMatch
        tap(confirm)
        let gone = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: carrying)],
                                    timeout: 5)
        XCTAssertEqual(gone, .completed, "The carried messages should be gone")
    }

    @MainActor
    func testRangeTestShowsEventsAndClears() {
        let app = launch("-demo", "populated")
        openSettings(app)
        let link = app.buttons["settings.rangeTest"]
        scrollTo(link, in: app)
        link.tap()

        XCTAssertTrue(element(app, "range.notice").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "range.notice").label.contains("never saved or sent"))
        XCTAssertTrue(element(app, "range.event").waitForExistence(timeout: 5), "Sample events should be listed")
        XCTAssertTrue(element(app, "range.longestGap").exists)
        XCTAssertTrue(app.staticTexts["Phone a3f1"].exists || element(app, "Phone a3f1", labelContains: true).exists)

        tap(app.buttons["range.clear"])
        XCTAssertTrue(element(app, "range.empty").waitForExistence(timeout: 5), "Clear should empty the log")
        XCTAssertFalse(element(app, "range.event").exists)
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
    private func openSettings(_ app: XCUIApplication) {
        tap(app.buttons["home.settings"], timeout: 20)
        XCTAssertTrue(app.switches["settings.visible"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ key: String, labelContains: Bool = false) -> XCUIElement {
        if labelContains {
            return app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", key)).firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: key).firstMatch
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Couldn't scroll to \(element)", file: file, line: line)
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
        XCTAssertEqual(result, .completed, "Expected \"\(text)\", got \"\(element.exists ? element.label : "<missing>")\"",
                       file: file, line: line)
    }
}
