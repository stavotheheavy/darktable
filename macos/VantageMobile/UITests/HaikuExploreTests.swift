import XCTest

/// Haiku exploration on iPhone: taps each tool tile, moves each slider to 0.1 and 0.9, and exercises
/// Reset, Done, Auto edit, Undo, Redo, zoom, Hide and Show UI, and rotate. Each step attaches a screenshot.
final class HaikuExploreTests: XCTestCase {
    static let rawPath = "/private/tmp/claude-502/-Users-Chief/84b5de6f-e891-4a6b-afa8-39a137741b16/scratchpad/rawtest/DSC_0508.NEF"
    static let tools = ["looks", "light", "shadows", "highlights", "contrast", "color", "warmth", "detail", "white-balance", "crop"]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func note(_ text: String) {
        add(XCTAttachment(string: text))
    }

    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let b = app.buttons[id]
        if b.exists { return b }
        return app.descendants(matching: .any)[id].firstMatch
    }

    /// The tray scrolls sideways: a tile past the edge is reached by swiping the tray, as a person would.
    private func reveal(_ app: XCUIApplication, _ id: String) {
        guard id.hasPrefix("phone-tool-") else { return }
        for _ in 0..<4 {
            let el = find(app, id)
            if el.exists, el.isHittable { return }
            app.scrollViews.firstMatch.swipeLeft()
        }
    }

    private func tapId(_ app: XCUIApplication, _ id: String) -> Bool {
        reveal(app, id)
        let el = find(app, id)
        guard el.waitForExistence(timeout: 5), el.isHittable else {
            note("UNREACHABLE: \(id)")
            XCTFail("\(id) not reachable")
            return false
        }
        el.tap()
        sleep(1)
        return true
    }

    private func launch() -> XCUIApplication {
        resetSidecar(Self.rawPath)
        let app = XCUIApplication()
        app.launchEnvironment["DARKROOM_OPEN"] = Self.rawPath
        app.launch()
        return app
    }

    func testIPhoneExplore() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the phone's tray exists only on the iPhone")
        let app = launch()
        guard find(app, "export").waitForExistence(timeout: 90) else {
            XCTFail("darkroom did not open")
            shot("explore-no-open")
            return
        }
        sleep(2)
        shot("explore-open")

        for id in Self.tools {
            let tile = "phone-tool-\(id)"
            guard tapId(app, tile) else { continue }
            shot("explore-\(id)-open")
            let slider = app.sliders["phone-slider"].exists ? app.sliders["phone-slider"] : app.sliders.firstMatch
            if slider.exists && slider.isHittable {
                slider.adjust(toNormalizedSliderPosition: 0.1)
                sleep(1)
                shot("explore-\(id)-slider-0.1")
                slider.adjust(toNormalizedSliderPosition: 0.9)
                sleep(1)
                shot("explore-\(id)-slider-0.9")
            }
            if find(app, "phone-reset").exists {
                _ = tapId(app, "phone-reset")
                shot("explore-\(id)-reset")
            }
            _ = tapId(app, "phone-done")
            shot("explore-\(id)-done")
        }

        _ = tapId(app, "auto-edit")
        shot("explore-auto-edit")
        _ = tapId(app, "undo")
        shot("explore-undo")
        _ = tapId(app, "redo")
        shot("explore-redo")

        for _ in 0..<3 {
            _ = tapId(app, "zoom-in")
        }
        shot("explore-zoom-in-x3")
        _ = tapId(app, "zoom-fit")
        shot("explore-zoom-fit")

        _ = tapId(app, "hide-ui")
        shot("explore-hidden")
        _ = tapId(app, "hide-ui")
        shot("explore-shown")

        _ = tapId(app, "phone-tool-crop")
        _ = tapId(app, "phone-rotate")
        shot("explore-rotated-90")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("explore-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("explore-portrait")
        app.terminate()
    }
}
