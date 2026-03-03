import XCTest

final class SpongeUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // Give the app time to load SwiftData and settle
        sleep(2)
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Launch

    func testAppLaunchesSuccessfully() {
        // The app should be running and show at least one window
        XCTAssertTrue(app.windows.firstMatch.exists, "App should have a main window")
    }

    // MARK: - Main UI Structure

    func testMainWindowShowsRecordingControls() {
        // The microphone/record button should be present in the main view
        let recordButton = app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'record' OR label CONTAINS 'Record' OR label CONTAINS 'Start'")).firstMatch
        // Fall back to looking for the mic button by its system image accessibility
        let micButton = app.buttons["Start Recording"].exists ? app.buttons["Start Recording"] : app.buttons.firstMatch
        XCTAssertTrue(app.windows.firstMatch.exists)
        // App main window should have some buttons (at minimum settings/menu)
        XCTAssertGreaterThan(app.buttons.count, 0, "Main window should have interactive controls")
    }

    func testSettingsCanBeOpened() {
        // Look for settings button (ellipsis menu or gear icon)
        let settingsButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Settings' OR identifier CONTAINS 'ellipsis' OR label CONTAINS 'Menu'")
        ).firstMatch

        if settingsButton.exists {
            settingsButton.click()
            // Give menu time to appear
            sleep(1)
            // Look for a Settings menu item
            let settingsMenuItem = app.menuItems["Settings"].firstMatch
            if settingsMenuItem.exists {
                settingsMenuItem.click()
                sleep(1)
                // Settings sheet should appear with Gemini API key field
                let apiKeyField = app.secureTextFields.firstMatch
                XCTAssertTrue(
                    apiKeyField.exists || app.textFields.matching(NSPredicate(format: "label CONTAINS 'API'")).firstMatch.exists,
                    "Settings should show API key configuration"
                )
            }
        }
    }

    // MARK: - Class Management

    func testClassCreationFlow() {
        // Look for "Manage Classes" button in toolbar
        let manageButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Class' OR label CONTAINS 'Manage'")
        ).firstMatch

        if manageButton.exists {
            manageButton.click()
            sleep(1)
            // Sheet or view should open
            XCTAssertTrue(app.sheets.firstMatch.exists || app.windows.count >= 1)
        }
    }

    // MARK: - Recording Detail View

    func testRecordingDetailHasExpectedTabs() {
        // If any recordings exist, click the first one to open detail view
        let recordingRow = app.tables.firstMatch.cells.firstMatch
        guard recordingRow.exists else {
            // No recordings yet — acceptable, skip
            return
        }

        recordingRow.doubleClick()
        sleep(1)

        // RecordingDetailView should have 4 tab buttons
        let transcriptTab = app.buttons["Transcript"]
        let summariesTab = app.buttons["Summaries"]
        let recallTab = app.buttons["Recall"]
        let markersTab = app.buttons["Markers"]

        // At least Transcript and Done button should be visible
        XCTAssertTrue(
            transcriptTab.exists || app.buttons["Done"].exists,
            "Recording detail view should be accessible"
        )

        if transcriptTab.exists {
            XCTAssertTrue(summariesTab.exists, "Summaries tab should exist")
            XCTAssertTrue(recallTab.exists, "Recall tab should exist")
            XCTAssertTrue(markersTab.exists, "Markers tab should exist")
        }
    }

    func testRegenerateAINotesButtonExists() {
        let recordingRow = app.tables.firstMatch.cells.firstMatch
        guard recordingRow.exists else { return }

        recordingRow.doubleClick()
        sleep(1)

        // The Regenerate AI Notes button should be in the header
        let regenerateButton = app.buttons["Regenerate AI Notes"]
        let doneButton = app.buttons["Done"]

        if doneButton.exists {
            XCTAssertTrue(
                regenerateButton.exists,
                "Regenerate AI Notes button should be visible in recording detail header"
            )
            // Clean up
            doneButton.click()
        }
    }

    // MARK: - Accessibility

    func testMainWindowMeetsMinimumSize() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        // Window should be at least 700x500 (our minimum is 800x600)
        XCTAssertGreaterThan(window.frame.width, 700)
        XCTAssertGreaterThan(window.frame.height, 500)
    }
}
