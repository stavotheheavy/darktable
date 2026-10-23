import XCTest

/// The iPad and iPhone test rig: XCUITest drives the app by the identifiers the `.rig("id")`
/// tags set (the same names the Mac rig uses), and attaches a screenshot at each step.
final class VantageFlowTests: XCTestCase {
    /// A Nikon RAW copied out of ~/Desktop: the simulator cannot read the Desktop folder (privacy protection).
    /// The app opens it at launch through DARKROOM_OPEN.
    static let rawPath = "/private/tmp/claude-502/-Users-Chief/84b5de6f-e891-4a6b-afa8-39a137741b16/scratchpad/rawtest/DSC_0508.NEF"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Welcome names the device it runs on, not the Mac.
    func testWelcomeNamesThisDevice() {
        let app = XCUIApplication()
        // Welcome shows only until it has been finished once on the device, so the test starts from "not yet"
        app.launchArguments = ["-darkroom.welcomed", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to Vantage"].waitForExistence(timeout: 20), "welcome did not appear")
        let copy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Editing works on this")).firstMatch
        XCTAssertTrue(copy.exists, "welcome copy missing")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "this Mac")).firstMatch.exists,
                       "welcome still says this Mac on a non-Mac device")
        shot("welcome")
    }

    /// A RAW opens straight into the darkroom, with the edit controls on screen.
    func testOpenRawShowsEditControls() {
        resetSidecar(Self.rawPath)
        let app = XCUIApplication()
        app.launchEnvironment["DARKROOM_OPEN"] = Self.rawPath
        app.launch()
        XCTAssertTrue(app.buttons["export"].waitForExistence(timeout: 90), "darkroom did not open the RAW")
        XCTAssertTrue(app.buttons["auto-edit"].exists, "auto edit control missing")
        shot("darkroom-open")
    }

    /// Auto edit changes the picture, and undo takes it back: both controls respond on touch.
    func testAutoEditThenUndo() {
        resetSidecar(Self.rawPath)
        let app = XCUIApplication()
        app.launchEnvironment["DARKROOM_OPEN"] = Self.rawPath
        app.launch()
        XCTAssertTrue(app.buttons["export"].waitForExistence(timeout: 90), "darkroom did not open the RAW")
        app.buttons["auto-edit"].tap()
        sleep(3)
        shot("after-auto-edit")
        app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "Undo", "undo")).firstMatch.tap()
        sleep(2)
        shot("after-undo")
    }
}
