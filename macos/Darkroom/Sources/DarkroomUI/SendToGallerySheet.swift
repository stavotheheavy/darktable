import SwiftUI

/// Send to gallery: pick photos from the open folder, name the gallery and the client, send. See GallerySend.swift.
struct SendToGallerySheet: View {
    @Bindable var cloud: DarkroomModel
    let library: LibraryModel
    let close: () -> Void
    @State private var send: GallerySendModel
    @State private var copied: String?

    init(cloud: DarkroomModel, library: LibraryModel, close: @escaping () -> Void) {
        self.cloud = cloud; self.library = library; self.close = close
        let exporter = GalleryExporter()
        let base = cloud.cloudClient.base, store = cloud.cloudStore
        let model = GallerySendModel(client: GalleryClient(base: base), token: { store.read() },
                                     exporter: { path, url in await exporter.jpeg(for: path, to: url) })
        model.title = library.folder?.lastPathComponent ?? ""
        model.selection = Set(library.items.filter { !$0.rejected && !$0.unreadable }.map(\.path))
        _send = State(initialValue: model)
    }

    private var photos: [LibraryItem] { library.items.filter { !$0.unreadable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Send to gallery").font(.title3.weight(.semibold))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Close").rig("gallery-close")
            }
            if !cloud.cloudSignedIn {
                Text("Sign in to Databit Dev first. Your galleries and clients live there.").foregroundStyle(.secondary)
                Button("Sign in to Databit Dev\u{2026}") { Task { await cloud.signInToCloud() } }
                    .buttonStyle(.glass).disabled(cloud.cloudBusy).rig("gallery-sign-in")
                if let m = cloud.cloudMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
            } else {
                switch send.phase {
                case .choosing, .failed: form
                case .working(let what, let fraction): working(what, fraction)
                case .done(let share): done(share)
                }
            }
        }
        .padding(22)
        .frame(width: 640, height: 600, alignment: .topLeading)
        .task(id: cloud.cloudSignedIn) { if cloud.cloudSignedIn, !send.sitesLoaded { await send.loadSites() } }
        .rig("gallery-sheet")
    }

    @ViewBuilder private var form: some View {
        if case .failed(let message) = send.phase {
            Text(message).font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true).rig("gallery-error")
        }
        if send.usableSites.count > 1 {
            Picker("Site", selection: $send.siteID) {
                ForEach(send.usableSites) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        HStack(spacing: 10) {
            TextField("Gallery title", text: $send.title).textFieldStyle(.roundedBorder).rig("gallery-title")
            TextField("Client name", text: $send.clientName).textFieldStyle(.roundedBorder).rig("gallery-client")
            TextField("Client email (optional)", text: $send.clientEmail).textFieldStyle(.roundedBorder).rig("gallery-email")
        }
        HStack {
            Text("\(send.selection.count) of \(photos.count) photos").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button("All") { send.selection = Set(photos.map(\.path)) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            Button("None") { send.selection = [] }.buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(photos) { item in
                    let on = send.selection.contains(item.path)
                    Button {
                        if on { send.selection.remove(item.path) } else { send.selection.insert(item.path) }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let t = item.thumb { Image(decorative: t, scale: 1).resizable().scaledToFill() }
                                else { Color.white.opacity(0.08) }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
                            .opacity(on ? 1 : 0.4)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Theme.accent : Color.white.opacity(0.7)).padding(4)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.name).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        HStack {
            Text("Sent as JPEGs with your edits, up to 3000 px. Originals stay here.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Send") {
                Task { await send.send(photos: photos.map { ($0.path, $0.name) }) }
            }
            .buttonStyle(.glassProminent).disabled(!send.canSend).rig("gallery-send")
        }
    }

    private func working(_ what: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: fraction)
            Text(what).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .rig("gallery-working")
    }

    private func done(_ share: GalleryShare) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sent. Your client can open the gallery now.", systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold))
            row("Link", share.link)
            row("Code", share.code)
            Text("Databit Dev shows the code only once, so copy it now. Sharing again makes a new one.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Button("Done") { close() }.buttonStyle(.glassProminent).rig("gallery-done") }
        }
        .rig("gallery-result")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button(copied == title ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copied = title
            }.buttonStyle(.glass).controlSize(.small)
        }
    }
}
