import Foundation

/// One photo that was deleted from the library and can still come back.
public struct DeletedPhoto: Codable, Equatable, Sendable, Identifiable {
    public var id: String { storedPath }
    public let originalPath: String
    public let storedPath: String
    public let deletedAt: Date
    public var name: String { (originalPath as NSString).lastPathComponent }
}

/// Deleting a photo moves it out of the library instead of erasing it. The Mac uses the system Trash; the iPhone and iPad have
/// none inside the app sandbox, so the photo goes to a hidden "Recently Deleted" folder in the library folder, listed in a small
/// manifest, and is purged after 30 days. A photo's edits (`<photo>.darkroom.json`) travel with it.
public enum RecentlyDeleted {
    public static let folderName = ".Recently Deleted"
    public static let sidecarSuffix = ".darkroom.json"
    public static let keepDays = 30

    #if os(macOS)
    public static let systemTrash = true
    #else
    public static let systemTrash = false
    #endif

    public enum Failure: Error { case missing, nameTaken }

    public static func remove(_ path: String, libraryFolder: URL, now: Date = Date(), fileManager fm: FileManager = .default,
                              useSystemTrash: Bool = RecentlyDeleted.systemTrash) throws -> DeletedPhoto {
        guard fm.fileExists(atPath: path) else { throw Failure.missing }
        let sidecar = path + sidecarSuffix
        if useSystemTrash {
            var out: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
            let stored = out?.path ?? path
            if fm.fileExists(atPath: sidecar) { try? fm.trashItem(at: URL(fileURLWithPath: sidecar), resultingItemURL: nil) }
            return DeletedPhoto(originalPath: path, storedPath: stored, deletedAt: now)
        }
        let dir = libraryFolder.appendingPathComponent(folderName)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\((path as NSString).lastPathComponent)").path
        try fm.moveItem(atPath: path, toPath: stored)
        if fm.fileExists(atPath: sidecar) { try? fm.moveItem(atPath: sidecar, toPath: stored + sidecarSuffix) }
        let entry = DeletedPhoto(originalPath: path, storedPath: stored, deletedAt: now)
        writeManifest(list(in: libraryFolder, fileManager: fm) + [entry], libraryFolder: libraryFolder, fileManager: fm)
        return entry
    }

    /// Puts the photo (and its edits) back where it was; refuses when another file has taken the name.
    public static func restore(_ entry: DeletedPhoto, libraryFolder: URL, fileManager fm: FileManager = .default) throws {
        guard fm.fileExists(atPath: entry.storedPath) else { throw Failure.missing }
        guard !fm.fileExists(atPath: entry.originalPath) else { throw Failure.nameTaken }
        try fm.moveItem(atPath: entry.storedPath, toPath: entry.originalPath)
        if fm.fileExists(atPath: entry.storedPath + sidecarSuffix) {
            try? fm.moveItem(atPath: entry.storedPath + sidecarSuffix, toPath: entry.originalPath + sidecarSuffix)
        }
        writeManifest(list(in: libraryFolder, fileManager: fm).filter { $0 != entry }, libraryFolder: libraryFolder, fileManager: fm)
    }

    /// The photos waiting in the folder's Recently Deleted, newest first.
    public static func list(in libraryFolder: URL, fileManager fm: FileManager = .default) -> [DeletedPhoto] {
        guard let data = try? Data(contentsOf: manifestURL(libraryFolder)),
              let all = try? decoder.decode([DeletedPhoto].self, from: data) else { return [] }
        return all.filter { fm.fileExists(atPath: $0.storedPath) }.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Erases what has waited longer than `keepDays`; returns how many photos went.
    @discardableResult
    public static func purge(in libraryFolder: URL, now: Date = Date(), fileManager fm: FileManager = .default) -> Int {
        let all = list(in: libraryFolder, fileManager: fm)
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        let old = all.filter { $0.deletedAt < cutoff }
        for e in old {
            try? fm.removeItem(atPath: e.storedPath)
            try? fm.removeItem(atPath: e.storedPath + sidecarSuffix)
        }
        if !old.isEmpty { writeManifest(all.filter { $0.deletedAt >= cutoff }, libraryFolder: libraryFolder, fileManager: fm) }
        return old.count
    }

    private static func manifestURL(_ folder: URL) -> URL { folder.appendingPathComponent(folderName).appendingPathComponent("manifest.json") }
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    private static func writeManifest(_ entries: [DeletedPhoto], libraryFolder: URL, fileManager fm: FileManager) {
        try? fm.createDirectory(at: libraryFolder.appendingPathComponent(folderName), withIntermediateDirectories: true)
        if let d = try? encoder.encode(entries) { try? d.write(to: manifestURL(libraryFolder), options: .atomic) }
    }
}
