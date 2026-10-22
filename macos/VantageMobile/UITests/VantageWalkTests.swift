import XCTest

/// The walk-through: drives the app by the rig identifiers and fails when a control is missing or does nothing.
/// The iPad and the iPhone have different layouts, so each has its own walk; the other device skips it.
final class VantageWalkTests: XCTestCase {
    static let rawPath = "/private/tmp/claude-502/-Users-Chief/84b5de6f-e891-4a6b-afa8-39a137741b16/scratchpad/rawtest/DSC_0508.NEF"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launchOpen(mode: String, orientation: UIDeviceOrientation = .portrait) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-darkroom.mode", mode]
        app.launchEnvironment["DARKROOM_OPEN"] = Self.rawPath
        XCUIDevice.shared.orientation = orientation
        app.launch()
        XCTAssertTrue(find(app, "export").waitForExistence(timeout: 90), "darkroom did not open")
        sleep(3)
        return app
    }

    /// Finds an element by identifier across the element types a rig control can be.
    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let b = app.buttons[id]
        if b.exists { return b }
        let o = app.otherElements[id]
        if o.exists { return o }
        return app.descendants(matching: .any)[id].firstMatch
    }

    /// The control must exist; returns it for the next step.
    @discardableResult
    private func must(_ app: XCUIApplication, _ id: String, _ what: String) -> XCUIElement {
        let el = find(app, id)
        XCTAssertTrue(el.waitForExistence(timeout: 8), "missing control: \(what) (\(id))")
        return el
    }

    /// A tap that must land: the control exists and can be hit on the screen.
    private func tap(_ app: XCUIApplication, _ id: String, _ what: String) {
        let el = must(app, id, what)
        guard el.exists else { return }
        XCTAssertTrue(el.isHittable, "\(what) (\(id)) exists but cannot be hit: it is off the screen or covered")
        if el.isHittable { el.tap(); sleep(2) }
    }

    /// The phone's tray scrolls sideways, so a tile past the edge is reached by swiping the tray, as a person would.
    private func reveal(_ app: XCUIApplication, tile id: String) {
        for _ in 0..<4 {
            if find(app, id).exists, find(app, id).isHittable { return }
            app.scrollViews.firstMatch.swipeLeft()
        }
    }

    private func picture(_ app: XCUIApplication) -> Data {
        find(app, "photo").screenshot().pngRepresentation
    }

    // MARK: iPad

    func testIPad_WelcomeNamesDevice() throws {
        try XCTSkipUnless(isPad)
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to Vantage"].waitForExistence(timeout: 20), "welcome did not appear")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "this iPad")).firstMatch.exists, "welcome does not say this iPad")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "this Mac")).firstMatch.exists, "welcome still says this Mac")
        shot("ipad-welcome")
    }

    func testIPad_ProControlsAndEdits() throws {
        try XCTSkipUnless(isPad)
        let app = launchOpen(mode: "Pro", orientation: .landscapeLeft)
        for (id, what) in [("back", "back"), ("photo", "photo"), ("undo", "undo"), ("redo", "redo"), ("auto-edit", "auto edit"),
                           ("hide-ui", "hide UI"), ("export", "export")] {
            must(app, id, what)
        }
        let before = picture(app)
        tap(app, "auto-edit", "auto edit")
        let after = picture(app)
        XCTAssertNotEqual(before, after, "auto edit did not change the picture")
        tap(app, "undo", "undo")
        // the photo's screenshot includes the floating UI, which also changes with undo, so compare the controls instead
        XCTAssertTrue(find(app, "redo").isEnabled, "redo is not available after undo")
        shot("ipad-pro-after-undo")
    }

    func testIPad_PortraitTabsOpenAndClose() throws {
        try XCTSkipUnless(isPad)
        let app = launchOpen(mode: "Pro")
        tap(app, "portrait-library-tab", "library tab")
        XCTAssertFalse(find(app, "portrait-library-tab").exists, "the library tab is still showing after it was tapped")
        shot("ipad-library-open")
        tap(app, "portrait-panel-tab", "panel tab")
        XCTAssertFalse(find(app, "portrait-panel-tab").exists, "the panel tab is still showing after it was tapped")
        shot("ipad-panel-open")
    }

    func testIPad_PinchMovesThePictureButNotTheTools() throws {
        try XCTSkipUnless(isPad)
        let app = launchOpen(mode: "Simple")
        let exportBefore = find(app, "export").frame
        let before = picture(app)
        find(app, "photo").pinch(withScale: 2.5, velocity: 3)
        sleep(2)
        XCTAssertNotEqual(before, picture(app), "pinching in did not change the picture")
        XCTAssertEqual(find(app, "export").frame, exportBefore, "the Export button moved when the photo was pinched")
        shot("ipad-pinched")
    }

    /// An attached keyboard: a plain key goes through the shortcut registry, a Command key through its hidden button.
    func testIPad_KeyboardShortcuts() throws {
        try XCTSkipUnless(isPad)
        let app = launchOpen(mode: "Simple", orientation: .landscapeLeft)
        let before = picture(app)
        app.typeKey("a", modifierFlags: [])           // A: auto edit
        sleep(5)
        XCTAssertNotEqual(before, picture(app), "the A key did not run auto edit")
        app.typeKey("z", modifierFlags: .command)     // Command-Z: undo
        sleep(2)
        XCTAssertTrue(find(app, "redo").isEnabled, "Command-Z did not undo")
        shot("ipad-keyboard")
    }

    func testIPad_ExportAndRotate() throws {
        try XCTSkipUnless(isPad)
        let app = launchOpen(mode: "Simple", orientation: .landscapeLeft)
        tap(app, "export", "export")
        // export ends in the system share sheet
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 40), "the share sheet did not open after export")
        shot("ipad-share-sheet")
        let close = app.buttons["Close"]
        if close.exists { close.tap() } else { app.swipeDown() }
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app is not running after export")
        XCTAssertFalse(sheet.exists, "the share sheet did not close")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        must(app, "export", "export after rotating")
        shot("ipad-rotated")
    }

    // MARK: iPhone

    func testPhone_ControlsAndCanvas() throws {
        try XCTSkipIf(isPad)
        let app = launchOpen(mode: "Simple")
        for (id, what) in [("back", "back"), ("photo", "photo"), ("export", "export"), ("hide-ui", "hide UI"), ("undo", "undo"),
                           ("redo", "redo"), ("auto-edit", "auto edit"), ("zoom-in", "zoom in"), ("zoom-out", "zoom out"),
                           ("zoom-fit", "fit"), ("phone-tool-light", "light tile"), ("phone-tool-crop", "crop tile")] {
            if id == "phone-tool-crop" { reveal(app, tile: id) }
            let el = must(app, id, what)
            if el.exists { XCTAssertTrue(el.isHittable, "\(what) (\(id)) cannot be hit on the phone") }
        }
        let before = picture(app)
        tap(app, "zoom-in", "zoom in")
        XCTAssertNotEqual(before, picture(app), "zoom in did not change the picture")
        tap(app, "zoom-fit", "fit")
        XCTAssertEqual(before, picture(app), "fit did not bring the photo back")
        shot("phone-base")
    }

    func testPhone_LightSliderEditsThePicture() throws {
        try XCTSkipIf(isPad)
        let app = launchOpen(mode: "Simple")
        let before = picture(app)
        tap(app, "phone-tool-light", "light tile")
        let slider = must(app, "phone-slider", "light slider")
        if slider.exists { slider.adjust(toNormalizedSliderPosition: 0.9); sleep(3) }
        XCTAssertNotEqual(before, picture(app), "moving the Light slider did not change the picture")
        shot("phone-light-edited")
        tap(app, "phone-reset", "reset")
        tap(app, "phone-done", "done")
        XCTAssertFalse(find(app, "phone-slider").exists, "the control did not close after Done")
    }

    func testPhone_LooksAndCropOpen() throws {
        try XCTSkipIf(isPad)
        let app = launchOpen(mode: "Simple")
        tap(app, "phone-tool-looks", "looks tile")
        let look = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'look-'")).firstMatch
        XCTAssertTrue(look.waitForExistence(timeout: 5), "no look buttons in the Looks control")
        shot("phone-looks")
        reveal(app, tile: "phone-tool-crop")
        tap(app, "phone-tool-crop", "crop tile")
        for (id, what) in [("phone-straighten", "straighten"), ("phone-rotate", "rotate")] {
            must(app, id, what)
        }
        let aspects = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'phone-aspect-'"))
        XCTAssertGreaterThanOrEqual(aspects.count, 4, "the aspect buttons are missing from the Crop control")
        shot("phone-crop")
    }

    func testPhone_HideUIKeepsTheEssentials() throws {
        try XCTSkipIf(isPad)
        let app = launchOpen(mode: "Simple")
        tap(app, "hide-ui", "hide UI")
        XCTAssertTrue(find(app, "export").isHittable, "Export is not reachable with the UI hidden")
        XCTAssertFalse(find(app, "phone-tool-light").isHittable, "the tray is still reachable with the UI hidden")
        shot("phone-hidden")
        tap(app, "hide-ui", "show UI")
        XCTAssertTrue(find(app, "phone-tool-light").isHittable, "the tray did not come back")
    }

    func testPhone_LandscapeNothingOffScreen() throws {
        try XCTSkipIf(isPad)
        let app = launchOpen(mode: "Simple", orientation: .landscapeLeft)
        for (id, what) in [("back", "back"), ("export", "export"), ("zoom-in", "zoom in"), ("undo", "undo"), ("phone-tool-light", "light tile")] {
            let el = must(app, id, what)
            if el.exists { XCTAssertTrue(el.isHittable, "\(what) (\(id)) cannot be hit in landscape") }
        }
        shot("phone-landscape")
        XCUIDevice.shared.orientation = .portrait
    }
}
