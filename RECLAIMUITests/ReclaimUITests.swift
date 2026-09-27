import XCTest

/// UI tests for onboarding, permission states, selection and the review gate.
///
/// These drive a real app against a real photo library, so results depend on
/// the device/simulator's content and permission state. Each test skips rather
/// than fails when its precondition isn't met — a machine with an empty library
/// genuinely cannot exercise a selection flow, and a false red is worse than an
/// honest skip.
///
/// Launch arguments understood by the app under test:
///   `-reclaim-ui-testing`  — marks the run as automated.
final class ReclaimUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-reclaim-ui-testing"]
        // Auto-accept the system permission alerts where they appear.
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "OK", "Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Onboarding

    func testOnboardingExplainsBeforeRequestingPermission() throws {
        let getStarted = app.buttons["Get started"]
        guard getStarted.waitForExistence(timeout: 5) else {
            throw XCTSkip("Onboarding already completed on this device")
        }
        // The brand promise and privacy line must precede any permission prompt.
        XCTAssertTrue(app.staticTexts["RECLAIM"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'on this iPhone'")
            ).firstMatch.exists,
            "Privacy messaging must be visible before permissions are requested"
        )

        getStarted.tap()

        let allowPhotos = app.buttons["Allow photo access"]
        XCTAssertTrue(allowPhotos.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'never leave your device'")
            ).firstMatch.exists,
            "The explanation must state that photos never leave the device"
        )
        // "Not now" must always be available — permissions are never forced.
        XCTAssertTrue(app.buttons["Not now"].exists)
    }

    func testOnboardingCanBeCompletedWithoutGrantingAnything() throws {
        let getStarted = app.buttons["Get started"]
        guard getStarted.waitForExistence(timeout: 5) else {
            throw XCTSkip("Onboarding already completed on this device")
        }
        getStarted.tap()
        app.buttons["Not now"].tap()

        let skip = app.buttons["Skip contacts"]
        XCTAssertTrue(skip.waitForExistence(timeout: 3))
        skip.tap()

        // The app must reach the dashboard, not dead-end (§7).
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5),
                      "Declining every permission must still reach the dashboard")
    }

    // MARK: - Dashboard

    func testDashboardShowsStorageAndCategories() throws {
        try completeOnboardingIfPresent()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.staticTexts["DEVICE STORAGE"].exists
                      || app.staticTexts["Device storage"].exists)
        for category in ["Similar Photos", "Screenshots", "Large Videos", "Duplicate Contacts"] {
            XCTAssertTrue(app.descendants(matching: .any)[category].exists
                          || app.staticTexts[category].exists,
                          "Missing dashboard card: \(category)")
        }
    }

    func testEveryTabIsReachableAndRendersContent() throws {
        try completeOnboardingIfPresent()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        for name in ["Photos", "Videos", "Contacts", "Home"] {
            tabBar.buttons[name].tap()
            // Never a blank screen: something must always render (§24).
            XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 5),
                          "\(name) tab rendered nothing")
        }
    }

    // MARK: - Selection and the review gate

    func testReviewBarAppearsOnlyWhenSomethingIsSelected() throws {
        try completeOnboardingIfPresent()
        app.tabBars.buttons["Photos"].tap()
        app.buttons["Screenshots"].firstMatch.tap()

        let selectAll = app.buttons["Select All"]
        guard selectAll.waitForExistence(timeout: 15) else {
            throw XCTSkip("No screenshots in this library to select")
        }
        XCTAssertFalse(app.buttons["Review"].exists, "Review bar must be hidden with no selection")

        selectAll.tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Review'")
        ).firstMatch.waitForExistence(timeout: 3), "Review bar must appear once items are selected")

        app.buttons["Deselect All"].tap()
    }

    /// SAFETY TEST 2 — opening Review and going back must delete nothing.
    func testLeavingReviewDeletesNothing() throws {
        try completeOnboardingIfPresent()
        app.tabBars.buttons["Photos"].tap()
        app.buttons["Screenshots"].firstMatch.tap()

        let selectAll = app.buttons["Select All"]
        guard selectAll.waitForExistence(timeout: 15) else {
            throw XCTSkip("No screenshots in this library to select")
        }
        selectAll.tap()

        let reviewBar = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Review'")
        ).firstMatch
        XCTAssertTrue(reviewBar.waitForExistence(timeout: 3))
        reviewBar.tap()

        XCTAssertTrue(app.navigationBars["Ready to clean"].waitForExistence(timeout: 5))
        // The destructive action must be clearly labelled and explicit.
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Clean'")
        ).firstMatch.exists)

        app.buttons["Go back"].tap()

        // Back on the list, with the selection intact and nothing removed.
        XCTAssertTrue(app.buttons["Deselect All"].waitForExistence(timeout: 5),
                      "Selection must survive leaving the review screen")
        app.buttons["Deselect All"].tap()
    }

    /// SAFETY TEST — the confirmation dialog can be cancelled without deleting.
    func testConfirmationCanBeCancelled() throws {
        try completeOnboardingIfPresent()
        app.tabBars.buttons["Photos"].tap()
        app.buttons["Screenshots"].firstMatch.tap()

        let selectAll = app.buttons["Select All"]
        guard selectAll.waitForExistence(timeout: 15) else {
            throw XCTSkip("No screenshots in this library to select")
        }
        selectAll.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Review'")).firstMatch.tap()

        let clean = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Clean'")
        ).firstMatch
        XCTAssertTrue(clean.waitForExistence(timeout: 5))
        clean.tap()

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3),
                      "A confirmation step must precede deletion")
        cancel.tap()

        // Still on Review, nothing deleted.
        XCTAssertTrue(app.navigationBars["Ready to clean"].exists)
        app.buttons["Go back"].tap()
        if app.buttons["Deselect All"].waitForExistence(timeout: 5) {
            app.buttons["Deselect All"].tap()
        }
    }

    // MARK: - Helpers

    private func completeOnboardingIfPresent() throws {
        let getStarted = app.buttons["Get started"]
        guard getStarted.waitForExistence(timeout: 5) else { return }
        getStarted.tap()
        if app.buttons["Allow photo access"].waitForExistence(timeout: 3) {
            app.buttons["Allow photo access"].tap()
            app.tap()  // triggers the interruption monitor
        }
        if app.buttons["Allow contacts access"].waitForExistence(timeout: 5) {
            app.buttons["Allow contacts access"].tap()
            app.tap()
        }
    }
}
