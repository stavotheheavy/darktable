import Foundation

// Slice 3 of the cloud seam: what the client picked in a gallery Vantage sent, shown on the library's thumbnails. Vantage remembers
// which photo went to which gallery (a small JSON file next to the ratings), asks Databit Dev for the picks, and keeps the answer so the
// badges are there offline. The photographer's own stars and rejects are never touched.

public enum ClientChoice: String, Codable, Sendable, CaseIterable {
    case yes, no, `super`
    public var title: String { self == .super ? "Favourite" : (self == .yes ? "Picked" : "Declined") }
}

/// What one client said about one photo.
public struct ClientPick: Codable, Equatable, Sendable {
    public var choice: ClientChoice
    public var gallery: String
    public var sentAt: Date?
    public var note: String?
    public init(choice: ClientChoice, gallery: String, sentAt: Date?, note: String?) {
        self.choice = choice; self.gallery = gallery; self.sentAt = sentAt; self.note = note
    }
}

/// A gallery Vantage sent: where it lives and which uploaded file name is which photo on this Mac.
public struct SentGallery: Codable, Equatable, Sendable {
    public var id: String
    public var siteID: String
    public var title: String
    public var sentAt: Date
    public var files: [String: String]   // uploaded name -> original path
    public init(id: String, siteID: String, title: String, sentAt: Date, files: [String: String]) {
        self.id = id; self.siteID = siteID; self.title = title; self.sentAt = sentAt; self.files = files
    }
}

/// The library's filter on client picks.
public enum PickFilter: String, CaseIterable, Sendable {
    case all = "All photos", picked = "Client picked", favourites = "Client favourites", declined = "Client declined"

    public func allows(_ pick: ClientPick?) -> Bool {
        switch self {
        case .all: true
        case .picked: pick?.choice == .yes || pick?.choice == .super
        case .favourites: pick?.choice == .super
        case .declined: pick?.choice == .no
        }
    }
}

/// Both files live in one folder: the app's support folder, or a test's own.
public struct ClientPickStore: Sendable {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public static var standard: ClientPickStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return ClientPickStore(directory: base.appending(path: "Vantage"))
    }

    private var galleriesURL: URL { directory.appending(path: "sent-galleries.json") }
    private var picksURL: URL { directory.appending(path: "client-picks.json") }

    public func galleries() -> [SentGallery] { read(galleriesURL) ?? [] }
    public func picks() -> [String: ClientPick] { read(picksURL) ?? [:] }
    public func savePicks(_ p: [String: ClientPick]) { write(p, to: picksURL) }

    /// Adds a send to its gallery's record (the same gallery sent in several runs is one record).
    public func record(gallery id: String, site: String, title: String, files: [String: String], at date: Date = Date()) {
        var all = galleries()
        if let i = all.firstIndex(where: { $0.id == id && $0.siteID == site }) {
            all[i].files.merge(files) { _, new in new }
        } else {
            all.append(SentGallery(id: id, siteID: site, title: title, sentAt: date, files: files))
        }
        write(all, to: galleriesURL)
    }

    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(value) { try? d.write(to: url, options: .atomic) }
    }
}

/// One gallery's answer from the server.
public struct GalleryPicks: Equatable, Sendable {
    public var picksSentAt: Date?
    public var note: String?
    public var choices: [String: ClientChoice]   // uploaded file name -> choice
}

extension GalleryClient {
    public func picks(token: String, site: String, gallery: String) async throws -> GalleryPicks {
        let o = try await callForPicks(token: token, site: site, gallery: gallery)
        let g = (o["gallery"] as? [String: Any]) ?? o
        let photos = (o["photos"] as? [[String: Any]]) ?? (g["photos"] as? [[String: Any]]) ?? []
        var choices: [String: ClientChoice] = [:]
        for p in photos {
            if let name = p["filename"] as? String, let c = (p["choice"] as? String).flatMap(ClientChoice.init(rawValue:)) { choices[name] = c }
        }
        let sent = (g["picksSentAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) ?? Self.fractionalDate($0) }
        return GalleryPicks(picksSentAt: sent, note: (g["clientNote"] as? String) ?? (g["note"] as? String), choices: choices)
    }

    private static func fractionalDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s)
    }
}
