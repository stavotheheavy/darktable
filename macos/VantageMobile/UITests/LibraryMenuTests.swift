import XCTest

/// The library: press and hold a photo for its menu, Delete moves it to Recently Deleted and Undo brings it back,
/// and the layout menu switches between grid, small grid and list.
final class LibraryMenuTests: XCTestCase {
    static let scratch = "/private/tmp/claude-502/-Users-Chief/84b5de6f-e891-4a6b-afa8-39a137741b16/scratchpad"
    static let folder = scratch + "/libtest"
    static let photoNames = ["A.NEF", "B.NEF", "C.NEF"]

    override func setUpWithError() throws {
        continueAfterFailure = true
        let fm = FileManager.default
        try? fm.removeItem(atPath: Self.folder)
        try fm.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
        for n in Self.photoNames { try fm.copyItem(atPath: Self.scratch + "/rawtest/DSC_0508.NEF", toPath: Self.folder + "/" + n) }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func launch(layout: String = "Grid") -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-darkroom.welcomed", "YES", "-darkroom.library.folder", Self.folder, "-darkroom.library.layout", layout]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(cell(app, "A.NEF").waitForExistence(timeout: 60), "the library did not show the photos")
        return app
    }

    private func cell(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["cell-\(name)"].firstMatch
    }

    func testHoldAPhotoForItsMenuThenDeleteAndUndo() throws {
        let app = launch()
        cell(app, "A.NEF").press(forDuration: 1.3)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 6), "the menu did not open on press and hold")
        for label in ["Open", "Rate", "Reject"] { XCTAssertTrue(app.buttons[label].exists, "the menu has no \(label)") }
        shot("library-menu")
        delete.tap()
        let gone = cell(app, "A.NEF")
        XCTAssertTrue(gone.waitForNonExistence(timeout: 10), "the photo is still in the library after Delete")
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: Self.folder + "/A.NEF"), "the file is still in the library folder")
        let trash = (try? fm.contentsOfDirectory(atPath: Self.folder + "/.Recently Deleted")) ?? []
        XCTAssertTrue(trash.contains { $0.hasSuffix("-A.NEF") }, "the file did not go to Recently Deleted")
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no Undo after Delete")
        shot("library-deleted-toast")
        undo.tap()
        XCTAssertTrue(cell(app, "A.NEF").waitForExistence(timeout: 30), "Undo did not bring the photo back")
        XCTAssertTrue(fm.fileExists(atPath: Self.folder + "/A.NEF"), "the file is not back in the folder")
        XCTAssertTrue(cell(app, "B.NEF").exists && cell(app, "C.NEF").exists, "the other photos went missing")
    }

    func testLayoutMenuSwitchesGridSmallGridAndList() throws {
        let app = launch()
        // a wide screen shows the layout button; a phone folds it into the Options menu
        let direct = app.buttons["Layout"].firstMatch
        let options = app.buttons["Options"].firstMatch
        XCTAssertTrue(direct.waitForExistence(timeout: 10) || options.exists, "no layout menu")
        let big = cell(app, "A.NEF").frame
        shot("layout-grid")
        for (choice, id) in [("Small grid", "layout-small"), ("List", "layout-list")] {
            if direct.exists { direct.tap() } else {
                options.tap()
                // the choices sit inline in the menu on some systems and behind a Layout row on others
                if !app.buttons[choice].waitForExistence(timeout: 3) {
                    let layoutRow = app.buttons["Layout"].firstMatch
                    XCTAssertTrue(layoutRow.waitForExistence(timeout: 5), "the Options menu has no Layout")
                    layoutRow.tap()
                }
            }
            let item = app.buttons[choice]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "the layout menu has no \(choice)")
            item.tap(); sleep(2)
            XCTAssertTrue(cell(app, "A.NEF").exists, "the photo vanished in \(choice)")
            shot(id)
            if choice == "Small grid" { XCTAssertLessThan(cell(app, "A.NEF").frame.width, big.width, "small tiles are not smaller") }
            else { XCTAssertGreaterThan(cell(app, "A.NEF").frame.width, big.width, "a list row is not wider than a tile") }
        }
    }
}
