import Foundation

/// The app keeps a photo's edits in a `.darkroom.json` file next to it, so a test that edits the test photo would leave its
/// edits for the next one. Every test deletes that file first, so each starts from the untouched photo.
func resetSidecar(_ rawPath: String) {
    try? FileManager.default.removeItem(atPath: rawPath + ".darkroom.json")
}
