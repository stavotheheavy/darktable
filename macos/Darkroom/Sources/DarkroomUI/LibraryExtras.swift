import DarkroomCore
import SwiftUI

/// How the library lays its photos out: the usual tiles, smaller tiles that fit more on the screen, or one row per photo.
public enum LibraryLayout: String, CaseIterable, Sendable {
    case grid = "Grid", small = "Small grid", list = "List"

    static let key = "darkroom.library.layout"
    static var saved: LibraryLayout { UserDefaults.standard.string(forKey: key).flatMap(LibraryLayout.init(rawValue:)) ?? .grid }

    var tileWidth: CGFloat { self == .small ? 96 : 170 }
    var tileHeight: CGFloat { self == .small ? 84 : 140 }
    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .small: "square.grid.3x3"
        case .list: "list.bullet"
        }
    }
}

/// The header's layout menu; on the iPhone and iPad it also opens the Recently Deleted list.
struct LibraryLayoutPicker: View {
    @Bindable var library: LibraryModel

    var body: some View {
        Menu {
            Picker("Layout", selection: $library.layout) {
                ForEach(LibraryLayout.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            if !RecentlyDeleted.systemTrash {
                Divider()
                Button { library.showingDeleted = true } label: { Label("Recently Deleted", systemImage: "trash") }
            }
        } label: {
            Image(systemName: library.layout.icon).frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(FlatCapsuleStyle())
        .accessibilityLabel("Layout")
        .rig("library-layout")
    }
}

extension View {
    /// Press and hold a photo (right-click or force touch on the Mac) for what can be done to it.
    func photoMenu(library: LibraryModel, item: LibraryItem, open: @escaping (String) -> Void,
                   compare: @escaping (String) -> Void) -> some View {
        contextMenu {
            Button { library.selected = item.path; open(item.path) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                .rig("cell-menu-open")
            Menu {
                ForEach(1...5, id: \.self) { n in
                    Button { library.setRating(n, for: item.path) } label: {
                        Label("\(n) \(n == 1 ? "star" : "stars")", systemImage: item.rating == n ? "checkmark" : "star")
                    }
                }
                if item.rating > 0 { Button("No stars") { library.setRating(item.rating, for: item.path) } }
            } label: { Label("Rate", systemImage: "star") }
            Button { library.toggleReject(item.path) } label: {
                Label(item.rejected ? "Restore" : "Reject", systemImage: item.rejected ? "arrow.uturn.backward" : "xmark")
            }
            #if !os(macOS)
            Button { library.sharing = URL(fileURLWithPath: item.path) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            #endif
            if item.stack != nil {
                Button { compare(item.path) } label: { Label("Compare stack", systemImage: "square.split.2x1") }
            }
            Divider()
            Button(role: .destructive) { library.delete(item.path) } label: { Label("Delete", systemImage: "trash") }
                .rig("cell-menu-delete")
        } preview: {
            PhotoPreview(item: item)
        }
    }

    /// The share sheet for one photo and the Recently Deleted list, both opened from the library.
    func librarySheets(_ library: LibraryModel) -> some View {
        modifier(LibrarySheets(library: library))
    }
}

private struct PhotoPreview: View {
    let item: LibraryItem
    var body: some View {
        Group {
            if let t = item.thumb {
                Image(decorative: t, scale: 1).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 200).overlay(Text(item.name).font(.caption.monospaced()))
            }
        }
        .frame(width: 300)
    }
}

private struct LibrarySheets: ViewModifier {
    @Bindable var library: LibraryModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $library.showingDeleted) { DeletedSheet(library: library) }
            #if !os(macOS)
            .sheet(isPresented: Binding(get: { library.sharing != nil }, set: { if !$0 { library.sharing = nil } })) {
                if let url = library.sharing { ActivityView(url: url).presentationDetents([.medium, .large]) }
            }
            #endif
    }
}

/// After a delete: say so for a few seconds, with the way back.
struct UndoToast: View {
    @Bindable var library: LibraryModel

    var body: some View {
        if let gone = library.lastDeleted {
            HStack(spacing: 14) {
                Text("Deleted \(gone.name)").font(.callout).lineLimit(1)
                Button("Undo") { library.undoDelete() }
                    .buttonStyle(PrimaryCapsuleStyle())
                    .rig("delete-undo")
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: gone.storedPath) {
                try? await Task.sleep(for: .seconds(6))
                if library.lastDeleted == gone { library.dismissUndo() }
            }
            .rig("delete-toast")
        }
    }
}

/// Photos deleted in the last 30 days, with a way to bring each back.
struct DeletedSheet: View {
    @Bindable var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [DeletedPhoto] = []

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    ContentUnavailableView("Nothing deleted", systemImage: "trash", description: Text("Deleted photos stay here for 30 days."))
                } else {
                    List(photos) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.name).font(.callout.monospaced())
                                Text(p.deletedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { library.restoreDeleted(p); photos = library.deletedPhotos }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { photos = library.deletedPhotos }
        .rig("deleted-sheet")
    }
}

/// One photo as a row, for the list layout.
struct PhotoRow: View {
    @Bindable var library: LibraryModel
    let item: LibraryItem
    let open: (String) -> Void
    let compare: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let t = item.thumb {
                    Image(decorative: t, scale: 1).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.white.opacity(0.06)).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 64, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .opacity(item.rejected ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.monospaced()).lineLimit(1)
                HStack(spacing: 8) {
                    if let s = item.sharpness {
                        HStack(spacing: 4) {
                            Circle().fill(dot(s)).frame(width: 7, height: 7)
                            Text("sharpness \(Int(s))")
                        }
                    } else if item.unreadable {
                        Label("Could not read", systemImage: "exclamationmark.triangle")
                    } else { Text("scoring") }
                    if library.groupStacks, item.stack != nil { Text("stack \(item.stackPosition) of \(item.stackSize)") }
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.rejected { Text("Rejected").font(.caption).foregroundStyle(.secondary) }
            else if item.rating > 0 { Text(String(repeating: "★", count: item.rating)).font(.caption).foregroundStyle(Theme.accent) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(library.selected == item.path ? Theme.accent : .white.opacity(0.08),
                                                                    lineWidth: library.selected == item.path ? 2 : 1))
        .contentShape(Rectangle())
        .id(item.path)
        .onTapGesture(count: 2) { open(item.path) }
        .simultaneousGesture(TapGesture().onEnded { library.selected = item.path })
        .photoMenu(library: library, item: item, open: open, compare: compare)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .rig("cell-\(item.name)")
    }

    private func dot(_ s: Double) -> Color {
        s < library.softBelow ? Color(red: 1, green: 0.54, blue: 0.44) : s < library.softBelow + 25 ? .yellow : Color(red: 0.44, green: 0.88, blue: 0.69)
    }
}

/// On a phone the tools row is wider than the screen, so it scrolls sideways inside its capsule instead of widening the page.
struct PhoneToolsScroll: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.isPhone {
            ScrollView(.horizontal, showsIndicators: false) { content }.frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
