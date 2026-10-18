import DarktableKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Which screen the window shows. The library is where the app starts; the darkroom is one photo.
public enum Screen: Sendable { case library, darkroom }

public struct LibraryItem: Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let date: Date?
    public var thumb: CGImage?
    public var sharpness: Double?
    public var hash: UInt64?
    public var rating = 0
    public var rejected = false
    /// Near-duplicates share a number; nil means the frame stands alone.
    public var stack: Int?
    public var stackPosition = 0
    public var stackSize = 0
    public var bestInStack = false

    public static func == (a: LibraryItem, b: LibraryItem) -> Bool {
        a.path == b.path && a.rating == b.rating && a.rejected == b.rejected && a.sharpness == b.sharpness
            && a.stack == b.stack && (a.thumb == nil) == (b.thumb == nil)
    }
}

/// Stars and rejects are kept in one small file, keyed by path, so the raw files stay untouched.
struct RatingStore {
    struct Entry: Codable { var rating: Int; var rejected: Bool }
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/darktable-fork/darkroom-ratings.json")
    }
    static func load() -> [String: Entry] {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
        return m
    }
    static func save(_ m: [String: Entry]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
    }
}

@MainActor
@Observable
public final class LibraryModel {
    public private(set) var folder: URL?
    public private(set) var items: [LibraryItem] = []
    public var selected: String?
    /// Frames scoring under this are flagged soft.
    public var softBelow = 50.0
    public var groupStacks = true
    public var sharpestFirst = false
    public private(set) var status = "Choose a folder of photos"
    public private(set) var scored = 0
    public var paused = false

    private let engine: Engine
    private var store = RatingStore.load()
    private var loading: Task<Void, Never>?
    static let extensions: Set<String> = ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "jpg", "jpeg", "tif", "tiff", "png"]
    static let lastFolderKey = "darkroom.library.folder"

    public init(engine: Engine) {
        self.engine = engine
    }

    public var shown: [LibraryItem] {
        sharpestFirst ? items.sorted { ($0.sharpness ?? -1) > ($1.sharpness ?? -1) } : items
    }

    public var restoredFolder: URL? {
        UserDefaults.standard.string(forKey: Self.lastFolderKey).map { URL(fileURLWithPath: $0) }
    }

    public func load(folder: URL) {
        loading?.cancel()
        self.folder = folder
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        items = files.map { url in
            var it = LibraryItem(path: url.path, name: url.lastPathComponent, date: Self.captureDate(of: url.path))
            if let e = store[url.path] { it.rating = e.rating; it.rejected = e.rejected }
            return it
        }
        scored = 0
        status = items.isEmpty ? "No photos in \(folder.lastPathComponent)" : "Reading \(items.count) photos"
        selected = items.first?.path
        loading = Task { await self.makeThumbnails() }
    }

    private func makeThumbnails() async {
        let paths = items.map(\.path)
        for path in paths {
            while paused, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
            if Task.isCancelled { return }
            guard let frame = await Self.thumbnail(for: path, engine: engine) else { continue }
            guard let i = items.firstIndex(where: { $0.path == path }) else { continue }
            items[i].thumb = frame
            items[i].sharpness = Culling.sharpness(of: frame)
            items[i].hash = Culling.averageHash(of: frame)
            scored += 1
            status = scored == items.count ? summary() : "Scoring \(scored) of \(items.count)"
            if scored % 8 == 0 || scored == items.count { regroup() }
        }
        regroup()
        status = summary()
    }

    private func summary() -> String {
        let soft = items.filter { ($0.sharpness ?? 100) < softBelow }.count
        let stacks = Set(items.compactMap(\.stack)).count
        return "\(items.count) photos, \(soft) soft, \(stacks) stacks"
    }

    func regroup() {
        let groups = Culling.stacks(dates: items.map(\.date), hashes: items.map(\.hash))
        var members: [Int: [Int]] = [:]
        for (i, g) in groups.enumerated() { if let g { members[g, default: []].append(i) } }
        for i in items.indices { items[i].stack = groups[i]; items[i].stackSize = 0; items[i].bestInStack = false }
        for (_, idx) in members {
            let ordered = idx.sorted { (items[$0].date ?? .distantPast) < (items[$1].date ?? .distantPast) }
            let best = ordered.max { (items[$0].sharpness ?? 0) < (items[$1].sharpness ?? 0) }
            for (n, i) in ordered.enumerated() {
                items[i].stackPosition = n + 1
                items[i].stackSize = ordered.count
                items[i].bestInStack = (i == best)
            }
        }
    }

    public func setRating(_ r: Int, for path: String) {
        guard let i = items.firstIndex(where: { $0.path == path }) else { return }
        items[i].rating = items[i].rating == r ? 0 : r
        items[i].rejected = false
        persist(items[i])
    }

    public func toggleReject(_ path: String) {
        guard let i = items.firstIndex(where: { $0.path == path }) else { return }
        items[i].rejected.toggle()
        if items[i].rejected { items[i].rating = 0 }
        persist(items[i])
    }

    private func persist(_ it: LibraryItem) {
        store[it.path] = .init(rating: it.rating, rejected: it.rejected)
        RatingStore.save(store)
    }

    // MARK: files

    static func captureDate(of path: String) -> Date? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let ex = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = ex[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    /// A 480 pixel developed copy, cached on disk until the file changes.
    static func thumbnail(for path: String, engine: Engine) async -> CGImage? {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/darktable-fork/thumbs")
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        let key = path.utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }
        let file = cache.appending(path: "\(key)-\(Int(mtime)).jpg")
        if let src = CGImageSourceCreateWithURL(file as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        guard let frame = try? await engine.render(path: path, maxSide: 480) else { return nil }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, frame.image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return frame.image
    }
}

// MARK: view

public struct LibraryView: View {
    @Bindable var library: LibraryModel
    let open: (String) -> Void
    @State private var choosing = false
    @FocusState private var focused: Bool

    public init(library: LibraryModel, open: @escaping (String) -> Void) {
        self.library = library
        self.open = open
    }

    public var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.085, blue: 0.105).ignoresSafeArea()

            if library.items.isEmpty {
                EmptyLibrary(choose: { choosing = true }, restore: library.restoredFolder.map { f in { library.load(folder: f) } })
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(library.shown) { item in
                            Cell(library: library, item: item, open: open)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 88)
                    .padding(.bottom, 96)
                }
            }

            VStack {
                header
                Spacer()
                if library.selected != nil, !library.items.isEmpty { selectionBar }
            }
            .padding(12)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345xX")) { press in
            guard let sel = library.selected, let c = press.characters.first else { return .ignored }
            if c == "x" || c == "X" { library.toggleReject(sel) } else if let n = Int(String(c)) { library.setRating(n, for: sel) }
            return .handled
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.load(folder: url) }
        }
        .accessibilityIdentifier("library")
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { choosing = true } label: { Image(systemName: "folder").frame(width: 34, height: 34) }
                    .buttonStyle(.plain).accessibilityLabel("Choose a folder").accessibilityIdentifier("choose-folder")
                VStack(alignment: .leading, spacing: 0) {
                    Text(library.folder?.lastPathComponent ?? "Library").font(.callout.weight(.medium))
                    Text(library.status).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 12).padding(.trailing, 18).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            HStack(spacing: 8) {
                Button { library.groupStacks.toggle() } label: { Label("Stacks", systemImage: "square.stack") }
                    .buttonStyle(FlatCapsuleStyle(on: library.groupStacks))
                Button { library.sharpestFirst.toggle() } label: { Label("Sharpest first", systemImage: "arrow.up.arrow.down") }
                    .buttonStyle(FlatCapsuleStyle(on: library.sharpestFirst))
                    .accessibilityIdentifier("sort-sharp")
                HStack(spacing: 6) {
                    Text("Soft below").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $library.softBelow, in: 10...90, step: 1).tint(Theme.accent).frame(width: 110)
                    Text("\(Int(library.softBelow))").font(.caption.monospacedDigit()).frame(width: 24)
                }
            }
            .padding(8)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var selectionBar: some View {
        let sel = library.items.first { $0.path == library.selected }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(sel?.name ?? "").font(.callout.monospaced().weight(.medium))
                Text(sel?.sharpness.map { "sharpness \(Int($0))" } ?? "scoring").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { n in
                    Button { if let p = sel?.path { library.setRating(n, for: p) } } label: {
                        Image(systemName: n <= (sel?.rating ?? 0) ? "star.fill" : "star")
                            .foregroundStyle(n <= (sel?.rating ?? 0) ? Theme.accent : .secondary)
                            .frame(width: 36, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(n) stars")
                }
            }
            Button { if let p = sel?.path { library.toggleReject(p) } } label: {
                Label(sel?.rejected == true ? "Restore" : "Reject", systemImage: "xmark")
            }
            .buttonStyle(FlatCapsuleStyle(on: sel?.rejected == true))
            Button { if let p = sel?.path { open(p) } } label: { Text("Open in darkroom") }
                .buttonStyle(PrimaryCapsuleStyle())
                .accessibilityIdentifier("open-selected")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct Cell: View {
    @Bindable var library: LibraryModel
    let item: LibraryItem
    let open: (String) -> Void

    var body: some View {
        let soft = (item.sharpness ?? 100) < library.softBelow
        VStack(spacing: 4) {
            ZStack {
                if let t = item.thumb {
                    Image(decorative: t, scale: 1).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.white.opacity(0.06)).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                if item.rejected || soft { RoundedRectangle(cornerRadius: 14).fill(.black.opacity(item.rejected ? 0.6 : 0.28)) }
            }
            .overlay(alignment: .topLeading) {
                if let s = item.sharpness { badge { Circle().fill(dot(s)).frame(width: 7, height: 7); Text("\(Int(s))").font(.caption.monospacedDigit()) } }
            }
            .overlay(alignment: .topTrailing) {
                if library.groupStacks, item.stack != nil { badge { Text("\(item.stackPosition) of \(item.stackSize)").font(.caption) } }
            }
            .overlay(alignment: .bottomLeading) {
                if library.groupStacks, item.bestInStack { badge { Text("Best of stack").font(.caption).foregroundStyle(Theme.accent) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.rejected { badge { Text("Rejected").font(.caption) } }
                else if item.rating > 0 { badge { Text(String(repeating: "★", count: item.rating)).font(.caption).foregroundStyle(Theme.accent) } }
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(library.selected == item.path ? Theme.accent : .white.opacity(0.1),
                                                                        lineWidth: library.selected == item.path ? 3 : 1))
            Text(item.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item.path) }
        .onTapGesture { library.selected = item.path }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityIdentifier("cell-\(item.name)")
    }

    private func dot(_ s: Double) -> Color {
        s < library.softBelow ? Color(red: 1, green: 0.54, blue: 0.44) : s < library.softBelow + 25 ? .yellow : Color(red: 0.44, green: 0.88, blue: 0.69)
    }

    private func badge<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 5) { c() }
            .padding(.horizontal, 8).frame(height: 24)
            .background(.black.opacity(0.62), in: Capsule())
            .padding(8)
    }
}

private struct EmptyLibrary: View {
    let choose: () -> Void
    let restore: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder").font(.system(size: 30)).frame(width: 64, height: 64)
                .background(Color.white.opacity(0.1), in: Circle())
            Text("Bring in your first photos").font(.title2.weight(.semibold))
            Text("Choose a folder. Soft frames and near-duplicates are flagged as it loads, on this Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Button(action: choose) { Text("Choose a folder") }.buttonStyle(PrimaryCapsuleStyle())
                .accessibilityIdentifier("empty-choose")
            if let restore { Button("Open the last folder", action: restore).buttonStyle(.plain).foregroundStyle(.secondary) }
        }
    }
}
