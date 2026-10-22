import XCTest

/// Saves the Pro screen as PNG files for the design review: each orientation, and each edge tab opened.
/// Landscape files come out sideways (the screenshot is the upright buffer), so the caller rotates them.
final class ShotTests: XCTestCase {
    static let rawPath = "/private/tmp/claude-502/-Users-Chief/84b5de6f-e891-4a6b-afa8-39a137741b16/scratchpad/rawtest/DSC_0508.NEF"
    static let outDir = "/private/tmp/claude-502/-Users-Chief/84b5de6f-e891-4a6b-afa8-39a137741b16/scratchpad/shots"

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(Self.outDir)/\(device)-\(name).png"))
    }

    /// A fresh launch with the library shown or hidden, so every screen starts from a known state.
    private func launch(library: Bool, orientation: UIDeviceOrientation, mode: String = "Pro") -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-darkroom.mode", mode, "-darkroom.libraryShown", library ? "YES" : "NO"]
        app.launchEnvironment["DARKROOM_OPEN"] = Self.rawPath
        XCUIDevice.shared.orientation = orientation
        app.launch()
        XCTAssertTrue(app.buttons["export"].waitForExistence(timeout: 90), "darkroom did not open")
        sleep(4)
        return app
    }

    /// Pinches the photo in, then out, saving each state: the photo should scale in place about the fingers.
    private func pinchShots(_ app: XCUIApplication, prefix: String) {
        let photo = app.descendants(matching: .any)["photo"]
        guard photo.waitForExistence(timeout: 10) else { XCTFail("photo element missing"); return }
        photo.pinch(withScale: 2.5, velocity: 3); sleep(2)
        save("\(prefix)-pinch-in")
        photo.pinch(withScale: 0.4, velocity: -3); sleep(2)
        save("\(prefix)-pinch-out")
    }

    func testScreens() throws {
        try XCTSkipIf(device == "iphone", "the phone has its own layout; see testPhoneScreens")
        // portrait: the base screen, then each tab opened
        var app = launch(library: false, orientation: .portrait)
        save("portrait-pro")
        if app.buttons["portrait-library-tab"].exists {
            app.buttons["portrait-library-tab"].tap(); sleep(2)
            save("portrait-library-open")
        }
        app = launch(library: false, orientation: .portrait)
        if app.buttons["portrait-panel-tab"].exists {
            app.buttons["portrait-panel-tab"].tap(); sleep(2)
            save("portrait-panel-open")
        }
        // pinch the photo on a fresh portrait launch
        app = launch(library: false, orientation: .portrait)
        pinchShots(app, prefix: "portrait")
        // landscape
        _ = launch(library: true, orientation: .landscapeLeft)
        save("landscape-pro")
        // Simple mode, both orientations
        _ = launch(library: false, orientation: .portrait, mode: "Simple")
        save("portrait-simple")
        _ = launch(library: false, orientation: .landscapeLeft, mode: "Simple")
        save("landscape-simple")
        XCUIDevice.shared.orientation = .portrait
    }

    /// The iPhone layout: the base screen, then a tray tool opened, and the UI hidden.
    func testPhoneScreens() throws {
        try XCTSkipIf(device == "ipad", "iPad has its own layout; see testScreens")
        var app = launch(library: false, orientation: .portrait, mode: "Simple")
        save("portrait")
        pinchShots(app, prefix: "portrait")
        app = launch(library: false, orientation: .portrait, mode: "Simple")
        for tool in ["light", "looks", "crop"] {
            let tile = app.buttons["phone-tool-\(tool)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 10), "tray tool \(tool) missing")
            tile.tap(); sleep(2)
            save("portrait-\(tool)")
            tile.tap(); sleep(1)
        }
        app.buttons["hide-ui"].tap(); sleep(2)
        save("portrait-hidden")
        app = launch(library: false, orientation: .landscapeLeft, mode: "Simple")
        save("landscape")
        let light = app.buttons["phone-tool-light"]
        if light.waitForExistence(timeout: 10) { light.tap(); sleep(2); save("landscape-light") }
        XCUIDevice.shared.orientation = .portrait
    }
}
