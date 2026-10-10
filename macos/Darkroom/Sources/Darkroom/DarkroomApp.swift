import DarktableKit
import SwiftUI
import UniformTypeIdentifiers

// Phase 0 milestone: a real image rendered by darktable's engine inside a SwiftUI
// window, with an exposure slider that re-renders. The layout is deliberately
// plain; the Liquid Glass design from the canvas is built on top of this.

@main
struct DarkroomApp: App {
    var body: some Scene {
        WindowGroup("Darkroom") {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
    }
}

@MainActor
@Observable
final class DarkroomModel {
    var image: CGImage?
    var exposure: Double = 0.7
    var status = "Choose an image to start"
    var lastMilliseconds: Double?

    private let engine = Engine()
    private var path: String?
    private var edited = false
    private var pending: Task<Void, Never>?

    func bootstrap() async {
        let env = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: env["DT_PREFIX"] ?? "/Users/Chief/darktable/build/install")
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            try await engine.start(
                prefix: prefix,
                configDir: home.appending(path: ".config/darktable-fork"),
                cacheDir: home.appending(path: ".cache/darktable-fork"))
            if let d = try await engine.defaultValue(operation: "exposure", field: "exposure") {
                exposure = d
            }
        } catch {
            status = "Engine did not start: \(error)"
            return
        }
        if CommandLine.arguments.count > 1 { await open(path: CommandLine.arguments[1]) }
    }

    func open(path: String) async {
        self.path = path
        edited = false
        await render()
    }

    func exposureChanged() {
        edited = true
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            await render()
        }
    }

    private func render() async {
        guard let path else { return }
        let stack = edited ? [StackEntry(operation: "exposure", params: ["exposure": exposure])] : []
        do {
            let frame = try await engine.render(path: path, maxSide: 1400, stack: stack)
            image = frame.image
            lastMilliseconds = frame.milliseconds
            status = "\(frame.width) x \(frame.height)"
        } catch {
            status = "\(error)"
        }
    }
}

struct ContentView: View {
    @State private var model = DarkroomModel()
    @State private var choosing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                Text(model.status).foregroundStyle(.secondary)
            }

            VStack {
                Spacer()
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 14) {
                        Button("Open") { choosing = true }
                            .buttonStyle(.glass)

                        HStack(spacing: 12) {
                            Text("Exposure").font(.callout)
                            Slider(value: $model.exposure, in: -3...3)
                                .frame(width: 280)
                                .onChange(of: model.exposure) { model.exposureChanged() }
                            Text(String(format: "%+.2f EV", model.exposure))
                                .font(.callout.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        if let ms = model.lastMilliseconds {
                            Text("\(Int(ms)) ms")
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .task { await model.bootstrap() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.rawImage, .image]) { result in
            if case .success(let url) = result { Task { await model.open(path: url.path) } }
        }
    }
}
