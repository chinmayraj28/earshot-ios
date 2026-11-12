import XCTest

/// Runs Xcode's built-in accessibility audit on the main screens in demo mode.
///
/// Checked: contrast, hit regions, element descriptions, clipped text, traits.
/// Not checked here, on purpose:
/// - `.dynamicType`: the audit flags list headers/footers and rows as "partially unsupported"
///   even though they use text styles; it also flags the chat title, which is capped like a
///   system navigation title. Dynamic Type is verified with screenshots at XXXL and AX sizes.
/// - `.elementDetection`: avatar initials are decorative and deliberately hidden from
///   VoiceOver (the row's combined label already says the name).
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    @MainActor
    func testHomeChatAndSettingsPassAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "populated"]
        app.launch()
        XCTAssertTrue(app.buttons["nearby.connect.Elena Costa"].waitForExistence(timeout: 20))
        try audit(app, "Home")

        app.buttons["conversation.Maya Okafor"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch.waitForExistence(timeout: 10))
        sleep(2) // let the push and the transcript settle; mid-animation text reads as low contrast
        try audit(app, "Chat")

        app.buttons["chat.details"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "contact.safetyCode").firstMatch.waitForExistence(timeout: 10))
        try audit(app, "Contact")

        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.switches["settings.visible"].waitForExistence(timeout: 10))
        try audit(app, "Settings")
    }

    @MainActor
    func testOnboardingPassesAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "firstRun"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 20))
        try audit(app, "Onboarding")
    }

    @MainActor
    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        let types: XCUIAccessibilityAuditType = [.contrast, .hitRegion, .sufficientElementDescription, .textClipped, .trait]
        try app.performAccessibilityAudit(for: types) { issue in
            print("AUDIT [\(screen)] \(issue.auditType) – \(issue.compactDescription) – \(issue.element?.debugDescription.prefix(160) ?? "no element")")
            return false
        }
    }
}
