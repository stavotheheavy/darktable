import XCTest

/// Haiku walk-through: drives the controls by the rig identifiers and attaches a screenshot per step.
/// Each step records what it found, so one missing control does not stop the rest of the walk.
final class VantageWalkTests: XCTestCase {
    static let rawPath = "/private/tmp/claude-502/-Users-Chief/84b5de6f-e891-4a6b-afa8-39a137741b16/scratchpad/rawtest/DSC_0508.NEF"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launchOpen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DARKROOM_OPEN"] = Self.rawPath
        app.launch()
        return app
    }

    /// Finds an element by identifier across the element types a rig control can be.
    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let buttons = app.buttons[id]
        if buttons.exists { return buttons }
        let others = app.otherElements[id]
        if others.exists { return others }
        return app.descendants(matching: .any)[id].firstMatch
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, _ id: String, _ step: String) -> Bool {
        let el = find(app, id)
        guard el.waitForExistence(timeout: 5) else {
            XCTContext.runActivity(named: "MISSING \(step): \(id)") { _ in }
            add(XCTAttachment(string: "MISSING \(step): identifier \(id) not found"))
            return false
        }
        el.tap()
        sleep(2)
        return true
    }

    private func check(_ app: XCUIApplication, _ id: String, _ step: String) -> Bool {
        let el = find(app, id)
        let ok = el.waitForExistence(timeout: 5)
        add(XCTAttachment(string: "\(step): \(id) exists=\(ok) hittable=\(ok ? el.isHittable : false)"))
        return ok
    }

    func testA_IPadWelcomeAndOpen() {
        let app = XCUIApplication()
        app.launch()
        shot("welcome-1")
        let title = app.staticTexts["Welcome to Vantage"]
        add(XCTAttachment(string: "welcome title exists=\(title.waitForExistence(timeout: 20))"))
        tap(app, "welcome-continue", "welcome continue")
        shot("welcome-2-mode")
        tap(app, "welcome-mode-continue", "mode continue")
        shot("welcome-3-folder")
        app.terminate()
    }

    func testB_OpenRawEditScreen() {
        let app = launchOpen()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        sleep(2)
        shot("b-open-raw")
        _ = check(app, "photo", "photo area")
        _ = check(app, "auto-edit", "auto edit")
        _ = check(app, "undo", "undo")
        _ = check(app, "redo", "redo")
        _ = check(app, "compare", "compare")
        _ = check(app, "hide-ui", "hide ui")
        _ = check(app, "crop-tool", "crop tool")
        _ = check(app, "export", "export")
        _ = check(app, "library", "library")
        _ = check(app, "mode-pro", "mode pro")
        _ = check(app, "mode-simple", "mode simple")
        app.terminate()
    }

    func testC_SimpleModeLooksUndoRedoCompareHide() {
        let app = launchOpen()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        tap(app, "auto-edit", "auto edit")
        shot("c-after-auto-edit")
        tap(app, "undo", "undo")
        shot("c-after-undo")
        tap(app, "redo", "redo")
        shot("c-after-redo")
        tap(app, "look-\("natural")", "look natural")
        shot("c-after-look")
        let compare = find(app, "compare")
        if compare.waitForExistence(timeout: 5) {
            compare.press(forDuration: 1.5)
            shot("c-compare-held")
        }
        tap(app, "hide-ui", "hide ui")
        shot("c-hidden-ui")
        tap(app, "show-ui", "show ui")
        shot("c-shown-ui")
        app.terminate()
    }

    func testD_ProModeLibraryModuleSliderUndo() {
        let app = launchOpen()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        tap(app, "mode-pro", "mode pro")
        shot("d-pro-mode")
        tap(app, "pro-library", "pro library")
        shot("d-pro-library")
        tap(app, "module-list", "module list")
        shot("d-module-list")
        tap(app, "module-exposure", "exposure module")
        shot("d-exposure-panel")
        tap(app, "enable-exposure", "enable exposure")
        shot("d-exposure-enabled")
        tap(app, "undo", "undo")
        shot("d-after-undo")
        app.terminate()
    }

    func testE_CropThenCancel() {
        let app = launchOpen()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        tap(app, "crop-tool", "crop tool")
        shot("e-crop-open")
        _ = check(app, "crop-box", "crop box")
        _ = check(app, "crop-reset", "crop reset")
        tap(app, "back", "cancel crop via back")
        shot("e-crop-cancelled")
        app.terminate()
    }

    func testF_ExportCompletes() {
        let app = launchOpen()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        tap(app, "export", "export")
        sleep(10)
        shot("f-export")
        app.terminate()
    }

    func testG_LibraryControls() {
        let app = launchOpen()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        tap(app, "library", "library")
        shot("g-library")
        tap(app, "stacks-toggle", "stacks toggle")
        shot("g-stacks")
        _ = check(app, "sort-sharp", "sort control")
        tap(app, "send-gallery", "send to gallery")
        shot("g-send-gallery")
        app.terminate()
    }

    func testH_RotateIPad() {
        let app = launchOpen()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("h-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("h-portrait")
        app.terminate()
    }
}
