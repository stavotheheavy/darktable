import AppKit
import Foundation

// Slice 2 of the cloud seam: send photos from the open folder to a Databit Dev client gallery, as JPEGs with their edits applied
// (originals and RAW files never leave this Mac). The server side is the existing owner flow (create a gallery, ask for upload links,
// PUT each file straight to storage, complete, share), reached with the device token from sign-in.

public struct GallerySite: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// What the site's plan allows for galleries: "full", "ended" or "none".
    public var galleries: String
    public var usable: Bool { galleries == "full" }
}

public struct GalleryUploadLink: Equatable, Sendable {
    public var photoID: String
    public var filename: String
    public var url: URL
}

public struct GalleryShare: Equatable, Sendable {
    public var link: String
    public var code: String
}

public enum GalleryError: LocalizedError, Equatable {
    case signedOut, plan(String), full, overQuota, closed(String), tooLarge(String), server(String), offline, exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to Databit Dev first"
        case .plan(let m): m
        case .full: "This gallery is full (2000 photos)"
        case .overQuota: "Your storage is full. Free some space or add a storage pack on Databit Dev"
        case .closed(let m): m
        case .tooLarge(let n): "\(n) is over 50 MB, so Databit Dev would refuse it"
        case .server(let m): m
        case .offline: "Could not reach Databit Dev"
        case .exportFailed(let n): "Vantage could not make a JPEG of \(n)"
        }
    }
}

/// The owner calls, Bearer-authenticated, JSON only (the origin guard refuses anything else).
public struct GalleryClient: Sendable {
    public var base: URL
    public var session: URLSession
    public init(base: URL, session: URLSession = .shared) { self.base = base; self.session = session }

    public func sites(token: String) async throws -> [GallerySite] {
        let o = try await call("api/portal/sites", method: "GET", token: token)
        let list = (o["sites"] as? [[String: Any]]) ?? []
        return list.compactMap { s in
            guard let id = (s["siteId"] as? String) ?? (s["id"] as? String) else { return nil }
            let name = (s["businessName"] as? String) ?? (s["name"] as? String) ?? (s["slug"] as? String) ?? id
            return GallerySite(id: id, name: name, galleries: s["galleries"] as? String ?? "none")
        }
    }

    public func createGallery(token: String, site: String, title: String, clientName: String, clientEmail: String?) async throws -> String {
        var body: [String: Any] = ["title": title, "clientName": clientName]
        if let e = clientEmail, !e.isEmpty { body["clientEmail"] = e }
        let o = try await call("api/portal/galleries", method: "POST", token: token, site: site, body: body)
        guard let id = o["id"] as? String else { throw GalleryError.server("Databit Dev did not return a gallery id") }
        return id
    }

    /// Asks for upload links for `files` (name, byte count), at most 50. Files the server already has come back in `skipped`.
    public func requestUploads(token: String, site: String, gallery: String, files: [(name: String, bytes: Int)]) async throws -> (links: [GalleryUploadLink], skipped: [String], refused: [(name: String, reason: String)]) {
        let body: [String: Any] = ["role": "proof", "files": files.map { ["filename": $0.name, "contentType": "image/jpeg", "byteLength": $0.bytes] }]
        let o = try await call("api/portal/galleries/\(gallery)/uploads", method: "POST", token: token, site: site, body: body)
        let links = ((o["uploads"] as? [[String: Any]]) ?? []).compactMap { u -> GalleryUploadLink? in
            guard let id = u["photoId"] as? String, let s = u["url"] as? String, let url = URL(string: s, relativeTo: base)?.absoluteURL else { return nil }
            return GalleryUploadLink(photoID: id, filename: u["filename"] as? String ?? "", url: url)
        }
        let refused = ((o["refused"] as? [[String: Any]]) ?? []).map { (name: $0["filename"] as? String ?? "a file", reason: $0["reason"] as? String ?? "refused") }
        return (links, (o["skipped"] as? [String]) ?? [], refused)
    }

    /// The bytes go straight to storage with exactly the type and length the link was signed for; no Databit credentials leave with them.
    public func put(_ link: GalleryUploadLink, data: Data) async throws {
        var r = URLRequest(url: link.url)
        r.httpMethod = "PUT"
        r.timeoutInterval = 120
        r.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await session.upload(for: r, from: data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw GalleryError.server("Storage refused the upload (\(status))") }
        } catch let e as GalleryError { throw e } catch { throw GalleryError.offline }
    }

    /// The owner's read of one gallery (GET api/portal/galleries/:id): its photos with the client's choices.
    func callForPicks(token: String, site: String, gallery: String) async throws -> [String: Any] {
        try await call("api/portal/galleries/\(gallery)", method: "GET", token: token, site: site)
    }

    public func complete(token: String, site: String, gallery: String, photoIDs: [String]) async throws {
        _ = try await call("api/portal/galleries/\(gallery)/uploads/complete", method: "POST", token: token, site: site, body: ["photoIds": photoIDs])
    }

    public func share(token: String, site: String, gallery: String) async throws -> GalleryShare {
        let o = try await call("api/portal/galleries/\(gallery)/share", method: "POST", token: token, site: site, body: [:])
        guard let link = o["link"] as? String, let code = o["code"] as? String else { throw GalleryError.server("Databit Dev did not return a link") }
        return GalleryShare(link: link, code: code)
    }

    private func call(_ path: String, method: String, token: String, site: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if let site { c.queryItems = [URLQueryItem(name: "site", value: site)] }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, status: Int
        do {
            let (d, response) = try await session.data(for: r)
            data = d; status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch { throw GalleryError.offline }
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(status) { return o }
        let code = o["code"] as? String ?? o["error"] as? String ?? ""
        switch (status, code) {
        case (401, _): throw GalleryError.signedOut
        case (403, "plan_ended"): throw GalleryError.plan("This site's plan has ended, so galleries are read-only. Renew it on Databit Dev")
        case (404, _): throw GalleryError.plan("This site has no gallery plan, or the gallery is gone")
        case (409, "gallery_full"): throw GalleryError.full
        case (409, "over_quota"): throw GalleryError.overQuota
        case (409, "archived"): throw GalleryError.closed("This gallery is archived")
        case (409, "delivered"): throw GalleryError.closed("This gallery was already delivered")
        default: throw GalleryError.server((o["error"] as? String) ?? "Databit Dev answered \(status)")
        }
    }
}

/// Makes the JPEG of one photo with its own saved edits, on a second engine, so the photo open in the darkroom is never switched.
@MainActor
public final class GalleryExporter {
    public static let maxSide = 3000
    public static let quality = 0.88
    private let model: DarkroomModel
    private var started = false

    public init(model: DarkroomModel = DarkroomModel(engine: EngineChoice.make())) { self.model = model }

    public func jpeg(for path: String, to url: URL) async -> Bool {
        if !started { await model.bootstrap(openingFirstArgument: false); started = true }
        await model.open(path: path)
        await model.settle()
        return await model.exportJPEG(to: url, maxSide: Self.maxSide, quality: Self.quality)
    }
}

/// One Send to gallery run: the sheet's inputs and where the send is. A retry sends only what has not gone yet.
@MainActor @Observable
public final class GallerySendModel {
    public enum Phase: Equatable { case choosing, working(String, Double), done(GalleryShare), failed(String) }

    public var phase: Phase = .choosing
    public var sites: [GallerySite] = []
    public var siteID: String?
    public var title = ""
    public var clientName = ""
    public var clientEmail = ""
    public var selection: Set<String> = []
    public private(set) var sitesLoaded = false
    /// The last failure was the plan (no gallery plan, or it ended): the sheet offers Subscribe.
    public private(set) var needsPlan = false

    private var galleryID: String?
    private var uploaded: Set<String> = []
    private var client: GalleryClient
    private let token: () -> String?
    private let exporter: (String, URL) async -> Bool
    private let store: ClientPickStore
    private var sentNames: [String: String] = [:]

    public init(client: GalleryClient, token: @escaping () -> String?, exporter: @escaping (String, URL) async -> Bool, store: ClientPickStore = .standard) {
        self.client = client; self.token = token; self.exporter = exporter; self.store = store
    }

    public var usableSites: [GallerySite] { sites.filter(\.usable) }
    public var canSend: Bool {
        guard case .choosing = phase else { if case .failed = phase { return true }; return false }
        return siteID != nil && !selection.isEmpty && !title.trimmingCharacters(in: .whitespaces).isEmpty && !clientName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func loadSites() async {
        guard let t = token() else { phase = .failed(GalleryError.signedOut.errorDescription!); return }
        do {
            sites = try await client.sites(token: t)
            sitesLoaded = true
            if siteID == nil { siteID = usableSites.first?.id }
            if usableSites.isEmpty { needsPlan = true; phase = .failed("None of your sites has galleries on its plan. Vantage Pro includes them") }
        } catch { phase = .failed((error as? GalleryError)?.errorDescription ?? error.localizedDescription) }
    }

    /// Sends `photos` (path, name) in the order given. Safe to call again after a failure: the gallery and the photos already up are kept.
    public func send(photos: [(path: String, name: String)]) async {
        guard let t = token() else { phase = .failed(GalleryError.signedOut.errorDescription!); return }
        guard let site = siteID else { phase = .failed("Pick a site that has galleries on its plan"); return }
        let chosen = photos.filter { selection.contains($0.path) && !uploaded.contains($0.path) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "vantage-gallery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 1 JPEGs
            var files: [(path: String, name: String, url: URL, bytes: Int)] = []
            var used = Set<String>()
            for (i, p) in chosen.enumerated() {
                phase = .working("Making JPEG \(i + 1) of \(chosen.count)", Double(i) / Double(max(chosen.count, 1)) * 0.4)
                var stem = (p.name as NSString).deletingPathExtension, n = 2
                while used.contains(stem.lowercased()) { stem = "\((p.name as NSString).deletingPathExtension)-\(n)"; n += 1 }
                used.insert(stem.lowercased())
                let url = dir.appending(path: stem + ".jpg")
                guard await exporter(p.path, url) else { throw GalleryError.exportFailed(p.name) }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                guard bytes > 0 else { throw GalleryError.exportFailed(p.name) }
                guard bytes <= 50_000_000 else { throw GalleryError.tooLarge(p.name) }
                files.append((p.path, stem + ".jpg", url, bytes))
            }
            // 2 the gallery
            if galleryID == nil {
                phase = .working("Creating the gallery", 0.42)
                galleryID = try await client.createGallery(token: t, site: site, title: title.trimmingCharacters(in: .whitespaces),
                                                           clientName: clientName.trimmingCharacters(in: .whitespaces), clientEmail: clientEmail.trimmingCharacters(in: .whitespaces))
            }
            let gallery = galleryID!
            // 3 uploads, 50 at a time
            var done = 0
            for batch in stride(from: 0, to: files.count, by: 50).map({ Array(files[$0..<min($0 + 50, files.count)]) }) {
                let r = try await client.requestUploads(token: t, site: site, gallery: gallery, files: batch.map { ($0.name, $0.bytes) })
                if let bad = r.refused.first { throw GalleryError.server("Databit Dev refused \(bad.name): \(bad.reason)") }
                var ids: [String] = [], paths: [String] = []
                for link in r.links {
                    guard let f = batch.first(where: { $0.name == link.filename }) else { continue }
                    phase = .working("Uploading \(done + 1) of \(files.count)", 0.45 + Double(done) / Double(max(files.count, 1)) * 0.5)
                    guard let data = try? Data(contentsOf: f.url) else { throw GalleryError.exportFailed(f.name) }
                    try await client.put(link, data: data)
                    ids.append(link.photoID); paths.append(f.path); sentNames[f.name] = f.path; done += 1
                }
                if !ids.isEmpty { try await client.complete(token: t, site: site, gallery: gallery, photoIDs: ids) }
                // only now are they safe: a failure before this point sends them again (the server reuses the pending rows)
                for path in paths { uploaded.insert(path) }
                for f in batch where r.skipped.contains(f.name) { uploaded.insert(f.path); sentNames[f.name] = f.path; done += 1 }
            }
            // 4 the client link
            phase = .working("Making the client link", 0.97)
            let share = try await client.share(token: t, site: site, gallery: gallery)
            store.record(gallery: gallery, site: site, title: title.trimmingCharacters(in: .whitespaces), files: sentNames)
            phase = .done(share)
        } catch {
            if case GalleryError.plan = error { needsPlan = true }
            phase = .failed((error as? GalleryError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
