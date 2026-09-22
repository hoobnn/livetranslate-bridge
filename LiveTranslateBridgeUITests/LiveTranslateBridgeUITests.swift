import XCTest

final class LiveTranslateBridgeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCopyFeedbackAndClearCancellation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sampleBoard", "-appLanguage", "en", "-logPaneExpanded", "NO"]
        app.launch()
        let copy = app.buttons["transcript.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertTrue(copy.isEnabled)
        recordAppearance(app, name: "Subtitles-light")
        copy.click()
        XCTAssertTrue(app.buttons["transcript.copy"].label.contains("Copied"))

        app.buttons["transcript.clear"].click()
        XCTAssertTrue(app.buttons["transcript.cancelClear"].waitForExistence(timeout: 3))
        app.buttons["transcript.cancelClear"].click()
        XCTAssertTrue(copy.isEnabled, "Cancelling must preserve the transcript")

        app.buttons["transcript.clear"].click()
        app.buttons["transcript.confirmClear"].click()
        XCTAssertFalse(copy.isEnabled)
    }

    @MainActor
    func testDiagnosticsRoundTripPreservesTranscript() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sampleBoard", "-appLanguage", "en", "-logPaneExpanded", "NO", "-previewDark"]
        app.launch()
        XCTAssertTrue(app.buttons["transcript.copy"].waitForExistence(timeout: 10))
        recordAppearance(app, name: "Subtitles-dark")
        app.radioButtons["Diagnostics"].click()
        XCTAssertFalse(app.buttons["transcript.copy"].exists)
        recordAppearance(app, name: "Diagnostics-dark")
        app.radioButtons["Subtitles"].click()
        XCTAssertTrue(app.buttons["transcript.copy"].isEnabled)
        app.buttons["session.setup"].click()
        XCTAssertTrue(app.staticTexts["Session"].waitForExistence(timeout: 3))
    }
    @MainActor
    private func recordAppearance(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
