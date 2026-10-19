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
    /// The engine could not develop this file (damaged, unsupported, or held open elsewhere).
    public var unreadable = false
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
        let dir = ProcessInfo.processInfo.environment["DARKROOM_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/darktable-fork")
        return dir.appending(path: "darkroom-ratings.json")
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
    /// Files the engine could not develop; they still count as handled, so the status can finish.
    public private(set) var failed = 0
    public var handled: Int { scored + failed }
    public var paused = false
    /// Grid columns as drawn, so up and down arrows move a row.
    public var columns = 5

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
        failed = 0
        status = items.isEmpty ? "No photos in \(folder.lastPathComponent)" : "Reading \(items.count) photos"
        selected = items.first?.path
        loading = Task { await self.makeThumbnails() }
    }

    private func makeThumbnails() async {
        let paths = items.map(\.path)
        for path in paths {
            while paused, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
            if Task.isCancelled { return }
            guard items.contains(where: { $0.path == path }) else { continue }
            let developed = await Self.thumbnail(for: path, engine: engine)
            // the folder may have been switched while the engine worked; the list is a different
            // array now, so the index has to be found again and a cancelled pass must not touch it
            if Task.isCancelled { return }
            guard let i = items.firstIndex(where: { $0.path == path }) else { continue }
            guard let frame = developed else {
                items[i].unreadable = true
                failed += 1
                status = handled == items.count ? summary() : "Scoring \(handled) of \(items.count)"
                continue
            }
            items[i].thumb = frame
            items[i].sharpness = Culling.sharpness(of: frame)
            items[i].hash = Culling.averageHash(of: frame)
            scored += 1
            status = handled == items.count ? summary() : "Scoring \(handled) of \(items.count)"
            if scored % 8 == 0 || handled == items.count { regroup() }
        }
        regroup()
        status = summary()
    }

    private func summary() -> String {
        let soft = items.filter { ($0.sharpness ?? 100) < softBelow }.count
        let stacks = Set(items.compactMap(\.stack)).count
        let broken = failed > 0 ? ", \(failed) could not be read" : ""
        return "\(items.count) photos, \(soft) soft, \(stacks) stacks\(broken)"
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

    /// The frames of a stack in capture order.
    public func members(ofStackWith path: String) -> [LibraryItem] {
        guard let g = items.first(where: { $0.path == path })?.stack else { return [] }
        return items.filter { $0.stack == g }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// Keeps one frame of a stack and rejects the others. Nothing is deleted.
    public func keepOnly(_ path: String) {
        for m in members(ofStackWith: path) where m.path != path {
            if let i = items.firstIndex(where: { $0.path == m.path }) { items[i].rejected = true; items[i].rating = 0; persist(items[i]) }
        }
        if let i = items.firstIndex(where: { $0.path == path }) { items[i].rejected = false; persist(items[i]) }
    }

    /// A larger developed copy for comparing; not cached, made on demand.
    public func preview(for path: String) async -> CGImage? {
        try? await engine.render(path: path, maxSide: 1400).image
    }

    /// Arrow keys: move the selection through the photos in the order shown.
    public func moveSelection(by d: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        let cur = list.firstIndex { $0.path == selected } ?? 0
        selected = list[min(list.count - 1, max(0, cur + d))].path
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
    @State private var comparing: String?
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
                ScrollViewReader { proxy in
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
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in
                    library.columns = max(1, Int((w - 28 + 12) / (170 + 12)))
                }
                .onChange(of: library.selected) { _, new in
                    if let new { withAnimation(.none) { proxy.scrollTo(new, anchor: .center) } }
                }
                }
            }

            VStack {
                header
                Spacer()
                if library.selected != nil, !library.items.isEmpty { selectionBar }
            }
            .padding(12)

            if let path = comparing {
                CompareView(library: library, start: path) { comparing = nil }
                    .transition(.opacity)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.return) {
            guard let sel = library.selected else { return .ignored }
            open(sel); return .handled
        }
        .onKeyPress(.leftArrow) { library.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { library.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { library.moveSelection(by: -library.columns); return .handled }
        .onKeyPress(.downArrow) { library.moveSelection(by: library.columns); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345xX")) { press in
            guard let sel = library.selected, let c = press.characters.first else { return .ignored }
            if c == "x" || c == "X" { library.toggleReject(sel) } else if let n = Int(String(c)) { if n == 3, Rig.canary("deadstar") { return .handled }; library.setRating(n, for: sel) }
            return .handled
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.load(folder: url) }
        }
        .rig("library")
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { choosing = true } label: { Image(systemName: "folder").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Choose a folder").rig("choose-folder")
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
                    .rig("stacks-toggle")
                Button { library.sharpestFirst.toggle() } label: { Label("Sharpest first", systemImage: "arrow.up.arrow.down") }
                    .buttonStyle(FlatCapsuleStyle(on: library.sharpestFirst))
                    .rig("sort-sharp")
                    .overlay(alignment: .trailing) {
                        if Rig.canary("overlap") {
                            Button { } label: { Text("Extra").font(.caption) }.buttonStyle(FlatCapsuleStyle()).rig("canary-extra").offset(x: 30)
                        }
                    }
                HStack(spacing: 6) {
                    Text("Soft below").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $library.softBelow, in: 10...90, step: 1).tint(Theme.accent).frame(width: 110)
                        .accessibilityLabel("Soft below")
                        .rig("soft-below")
                        .onAppear { if Rig.enabled { Rig.setters["soft-below"] = { library.softBelow = (10 + 80 * $0).rounded() } } }
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
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(n) stars")
                }
            }
            Button { if let p = sel?.path { library.toggleReject(p) } } label: {
                Label(sel?.rejected == true ? "Restore" : "Reject", systemImage: "xmark")
            }
            .buttonStyle(FlatCapsuleStyle(on: sel?.rejected == true))
            if let sel, sel.stack != nil {
                Button { comparing = sel.path } label: { Label("Compare stack", systemImage: "square.split.2x1") }
                    .buttonStyle(FlatCapsuleStyle())
                    .rig("compare-stack")
            }
            Button { if let p = sel?.path { open(p) } } label: { Text("Open in darkroom") }
                .buttonStyle(PrimaryCapsuleStyle())
                .rig("open-selected")
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
            .overlay {
                if item.unreadable {
                    VStack(spacing: 4) { Image(systemName: "exclamationmark.triangle"); Text("Could not read").font(.caption) }
                        .foregroundStyle(.secondary)
                }
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
        .id(item.path)
        .onTapGesture(count: 2) { open(item.path) }
        .onTapGesture { library.selected = item.path }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .rig("cell-\(item.name)")
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
                .rig("empty-choose")
            if let restore { Button("Open the last folder", action: restore).buttonStyle(.plain).foregroundStyle(.secondary) }
        }
    }
}


/// Two frames of one stack side by side, large enough to judge focus. The best frame by
/// score is pinned on the left; arrow keys move the right-hand frame through the others.
struct CompareView: View {
    @Bindable var library: LibraryModel
    let start: String
    let close: () -> Void
    @State private var members: [LibraryItem] = []
    @State private var pinned = 0
    @State private var other = 0
    @State private var frames: [String: CGImage] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.085, blue: 0.105).ignoresSafeArea()
            HStack(spacing: 10) {
                pane(index: pinned, pinned: true)
                pane(index: other, pinned: false)
            }
            .padding(.top, 84).padding(.bottom, 168).padding(.horizontal, 12)

            VStack {
                HStack {
                    Button(action: close) { Label("Back to the library", systemImage: "chevron.left") }
                        .buttonStyle(FlatCapsuleStyle()).padding(8).glassEffect(.regular, in: .capsule)
                    Spacer()
                }
                Spacer()
                bar
            }
            .padding(12)
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress("k") {
            guard members.indices.contains(other) else { return .ignored }
            library.keepOnly(members[other].path); close(); return .handled
        }
        .task {
            members = library.members(ofStackWith: start)
            pinned = members.firstIndex { $0.bestInStack } ?? 0
            other = members.indices.first { $0 != pinned } ?? 0
            focused = true
            for m in members { if let f = await library.preview(for: m.path) { frames[m.path] = f } }
        }
        .rig("compare")
    }

    private func step(_ d: Int) {
        let idx = members.indices.filter { $0 != pinned }
        guard let pos = idx.firstIndex(of: other), !idx.isEmpty else { return }
        other = idx[(pos + d + idx.count) % idx.count]
    }

    private func pane(index: Int, pinned isPinned: Bool) -> some View {
        let m = members.indices.contains(index) ? members[index] : nil
        return ZStack(alignment: .topLeading) {
            if let m, let f = frames[m.path] {
                Image(decorative: f, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let m {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 0.44, green: 0.88, blue: 0.69)).frame(width: 7, height: 7)
                    Text("\(Int(m.sharpness ?? 0))").font(.callout.monospacedDigit())
                    if m.bestInStack { Text("Best of \(m.stackSize)").font(.callout.weight(.semibold)).foregroundStyle(Theme.accent) }
                }
                .padding(.horizontal, 14).frame(height: 40).glassEffect(.regular, in: .capsule).padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(isPinned ? Theme.accent : .white.opacity(0.12), lineWidth: isPinned ? 3 : 1))
    }

    private var bar: some View {
        let current = members.indices.contains(other) ? members[other] : nil
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Stack of \(members.count)").font(.callout.weight(.semibold))
                Spacer()
                Text("\u{2190} \u{2192} switch   K keep right   Esc close").font(.caption.monospaced()).foregroundStyle(.secondary)
                if let current {
                    Button { library.keepOnly(current.path); close() } label: { Text("Keep this one") }
                        .buttonStyle(PrimaryCapsuleStyle())
                        .rig("keep-this")
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(members.enumerated()), id: \.offset) { i, m in
                    Group {
                        if let t = m.thumb { Image(decorative: t, scale: 1).resizable().scaledToFill() } else { Color.white.opacity(0.1) }
                    }
                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(i == other ? Theme.accent : .white.opacity(0.12), lineWidth: i == other ? 3 : 1))
                    .onTapGesture { if i != pinned { other = i } else { pinned = other; other = i } }
                }
                Spacer()
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }
}
