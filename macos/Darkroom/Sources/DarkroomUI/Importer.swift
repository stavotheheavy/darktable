import Foundation
#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#endif

/// Photos and Files hand an iPhone app short-lived, security-scoped references, not folders it can keep.
/// So everything brought in is copied into the app's own Documents/Imports, and the library reads from there.
enum PhotoImport {
    static var folder: URL {
        let dir = Platform.homeDirectory.appending(path: "Documents/Imports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func supported(_ url: URL) -> Bool { LibraryModel.extensions.contains(url.pathExtension.lowercased()) }

    private static func size(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }

    /// Copies one file in and returns the local copy. The same file brought in twice (same name and size)
    /// returns the copy already there; a different file with a taken name gets a numbered name.
    /// The coordinated read is what makes iCloud Drive, Google Drive and Dropbox download the file first.
    static func copyIn(_ src: URL) -> URL? {
        let fm = FileManager.default
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: .withoutChanges, error: &error) { readable in
            let stem = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            var target = folder.appending(path: src.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                if size(target) == size(readable) { result = target; return }
                target = folder.appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                n += 1
            }
            if (try? fm.copyItem(at: readable, to: target)) != nil { result = target }
        }
        return result
    }

    /// Files from the Files picker go in as they are; a folder contributes the photos directly inside it.
    /// Returns how many photos were copied; `progress` is called after each one.
    static func copyIn(_ picked: [URL], progress: (Int) -> Void = { _ in }) -> [URL] {
        var out: [URL] = []
        for url in picked {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let files = isFolder
                ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).filter(supported)
                : [url]
            for file in files {
                if let copy = copyIn(file) { out.append(copy); progress(out.count) }
            }
        }
        return out
    }

    /// The path to open for a file the picker returned. The Mac reads it where it is.
    static func localPath(for url: URL) async -> String {
        #if os(iOS)
        let copies = await Task.detached { copyIn([url]) }.value
        return copies.first?.path ?? url.path
        #else
        return url.path
        #endif
    }
}

#if os(iOS)
/// A photo chosen in the Photos picker, copied into Imports in its original format (RAW and HEIC kept).
private struct PickedPhoto: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            guard let copy = PhotoImport.copyIn(received.file) else { throw CocoaError(.fileWriteUnknown) }
            return PickedPhoto(url: copy)
        }
    }
    let url: URL
}

extension LibraryModel {
    func importFiles(_ urls: [URL]) async {
        status = "Importing"
        let copied = await Task.detached {
            PhotoImport.copyIn(urls) { done in Task { @MainActor in self.status = "Importing \(done)" } }
        }.value
        finishImport(copied.count)
    }

    func importPhotos(_ items: [PhotosPickerItem]) async {
        var copied = 0
        for item in items {
            status = "Importing \(copied + 1) of \(items.count)"
            if (try? await item.loadTransferable(type: PickedPhoto.self)) != nil { copied += 1 }
        }
        finishImport(copied)
    }

    private func finishImport(_ copied: Int) {
        load(folder: PhotoImport.folder)
        if copied == 0 { status = "Nothing was imported. The files may be unsupported or still downloading." }
    }
}

/// The one way to bring photos in on an iPhone or iPad: the Photos library, or Files, which also lists
/// iCloud Drive and every cloud app that offers its files there (Google Drive, Dropbox, OneDrive and so on).
struct ImportMenu<Content: View>: View {
    let library: LibraryModel
    @ViewBuilder var label: () -> Content
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photos library", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("Files and cloud apps", systemImage: "folder") }
        } label: { label() }
        .photosPicker(isPresented: $showPhotos, selection: $picked, matching: .images, preferredItemEncoding: .current)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await library.importPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.rawImage, .image, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
        .rig("import-menu")
    }
}
#endif
