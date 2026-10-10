import CoreGraphics
import DarkroomUI
import DarktableKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Headless checks that the Swift side really drives darktable's engine.
//   dtb-selftest <image> [--max 1400] [--out frame.png]      engine round trip + timings
//   dtb-selftest <image> --ui                                the real model: sliders -> stack -> pixels
//
// What this cannot check is how the Liquid Glass views look: SwiftUI draws through the window
// server, so offscreen snapshots come out blank or flat. That needs the app on screen.

func meanLuma(_ image: CGImage) -> Double {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
    let stride = image.bytesPerRow
    var sum = 0.0
    var n = 0.0
    // B,G,R,x little-endian; sample every 4th pixel, plenty for a mean
    for y in Swift.stride(from: 0, to: image.height, by: 4) {
        for x in Swift.stride(from: 0, to: image.width, by: 4) {
            let o = y * stride + x * 4
            sum += 0.0722 * Double(p[o]) + 0.7152 * Double(p[o + 1]) + 0.2126 * Double(p[o + 2])
            n += 1
        }
    }
    return n > 0 ? sum / n : 0
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw EngineError("cannot create \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw EngineError("cannot write \(url.path)") }
}

func describe(_ stack: [StackEntry]) -> String {
    stack.map { e in
        let f = e.params.keys.sorted().map { "\($0)=\(String(format: "%g", e.params[$0]?.double ?? 0))" }.joined(separator: ", ")
        return "\(e.operation)(\(f))"
    }.joined(separator: " + ")
}

@main
struct SelfTest {
    @MainActor
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        func has(_ flag: String) -> Bool {
            guard let i = args.firstIndex(of: flag) else { return false }
            args.remove(at: i)
            return true
        }
        let maxSide = Int(take("--max") ?? "") ?? 1400
        let out = take("--out")
        let ui = has("--ui")
        let listModules = has("--list-modules")
        guard let path = args.first else {
            print("usage: dtb-selftest <image> [--max 1400] [--out frame.png] [--ui]")
            exit(2)
        }

        let env = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: env["DT_PREFIX"] ?? "/Users/Chief/darktable/build/install")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let engine = Engine()

        do {
            let t0 = Date()
            try await engine.start(
                prefix: prefix,
                configDir: home.appending(path: ".config/darktable-fork"),
                cacheDir: home.appending(path: ".cache/darktable-fork"))
            print(String(format: "engine start: %.0f ms", Date().timeIntervalSince(t0) * 1000))

            if listModules {
                try await engine.openSession(path: path, maxSide: 400)
                for m in try await engine.sessionModules() {
                    print("\(m.id)\t\(m.name)\t\(m.haveIntrospection ? "params" : "-")\t\(m.deprecated ? "deprecated" : "")")
                }
            } else if ui {
                try await runUI(engine: engine, path: path)
            } else {
                try await runEngine(engine: engine, path: path, maxSide: maxSide, out: out)
            }
            await engine.shutdown()
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }

    static func runEngine(engine: Engine, path: String, maxSide: Int, out: String?) async throws {
        let modules = try await engine.moduleNames()
        let defExp = try await engine.defaultValue(operation: "exposure", field: "exposure")
        print("modules known: \(modules.count); exposure default: \(defExp.map { String($0) } ?? "n/a")")

        let base = try await engine.render(path: path, maxSide: maxSide)
        print("baseline: \(base.width)x\(base.height) in \(Int(base.milliseconds)) ms, mean luma \(String(format: "%.1f", meanLuma(base.image)))")
        if let out { try writePNG(base.image, to: URL(fileURLWithPath: out)); print("wrote \(out)") }

        var times: [Double] = []
        var lumaUp = 0.0, lumaDown = 0.0
        for i in 0..<3 {
            let up = try await engine.render(
                path: path, maxSide: maxSide,
                stack: [StackEntry(operation: "exposure", params: ["exposure": 1.0])])
            let down = try await engine.render(
                path: path, maxSide: maxSide,
                stack: [StackEntry(operation: "exposure", params: ["exposure": -1.0])])
            times += [up.milliseconds, down.milliseconds]
            if i == 0 { lumaUp = meanLuma(up.image); lumaDown = meanLuma(down.image) }
        }
        let avg = times.reduce(0, +) / Double(times.count)
        print(String(format: "edit renders: avg %.0f ms, min %.0f, max %.0f (n=%d)",
                     avg, times.min() ?? 0, times.max() ?? 0, times.count))
        print(String(format: "exposure -1 EV luma %.1f  <  +1 EV luma %.1f : %@",
                     lumaDown, lumaUp, lumaDown < lumaUp ? "edit applied" : "NO CHANGE"))
    }

    /// Drives the real DarkroomModel the way the controls do, and checks what comes out.
    @MainActor
    static func runUI(engine: Engine, path: String) async throws {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok    " : "  FAIL  ") + what)
            if !ok { failures.append(what) }
        }
        func luma(_ m: DarkroomModel) -> Double { m.frame.map(meanLuma) ?? 0 }
        func module(_ m: DarkroomModel, _ op: String) -> ModuleInfo? { m.modules.first { $0.operation == op } }
        func field(_ m: DarkroomModel, _ mod: ModuleInfo, _ name: String) -> FieldSchema? {
            m.schema(for: mod)?.fields.first { $0.name == name }
        }

        // a private copy: the sidecar this test writes must not land in anyone's folder
        let work = FileManager.default.temporaryDirectory.appending(path: "dtb-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = work.appending(path: URL(fileURLWithPath: path).lastPathComponent)
        try FileManager.default.copyItem(atPath: path, toPath: copy.path)
        defer { try? FileManager.default.removeItem(at: work) }

        let model = DarkroomModel(engine: engine)
        await model.bootstrap(openingFirstArgument: false)
        await model.open(path: copy.path)
        await model.settle()

        print("open")
        check(model.frame != nil, "a frame is on screen")
        check(model.modules.count > 40, "module list has \(model.modules.count) modules")
        check(model.info != nil, "output size known: \(model.info.map { "\($0.processedWidth)x\($0.processedHeight)" } ?? "?")")
        let base = luma(model)
        check(model.scopes != nil, "scopes measured")
        check(model.selectedModule?.operation == "exposure", "exposure is selected first")

        print("inspector from introspection")
        guard let exposure = module(model, "exposure") else { throw EngineError("no exposure module") }
        for _ in 0..<50 where model.schema(for: exposure) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let fields = model.schema(for: exposure)?.fields ?? []
        check(fields.contains { $0.name == "exposure" && $0.kind == .float }, "exposure schema has a float 'exposure' (\(fields.count) fields)")
        check(fields.contains { $0.kind == .enumeration && $0.options.count >= 2 }, "exposure schema has an enum with labelled options")
        if let mode = fields.first(where: { $0.kind == .enumeration }) {
            print("        enum \(mode.name): \(mode.options.map(\.label).joined(separator: ", "))")
        }

        print("editing")
        guard let ev = field(model, exposure, "exposure") else { throw EngineError("no exposure field") }
        // relative to this image's own imported state: some raws arrive with exposure already on
        let baseEv = model.base(exposure, ev).double ?? 0
        let startedOn = exposure.enabled
        print("        imported exposure: \(startedOn ? "on" : "off"), \(String(format: "%+.2f", baseEv)) EV")
        model.setParam(exposure, ev, to: .number(baseEv + 1.5))
        await model.settle()
        let up = luma(model)
        check(up > base + 3, "exposure +1.5 EV brightens (\(String(format: "%.1f", base)) -> \(String(format: "%.1f", up)))")
        check(model.isEnabled(exposure), "changing a control leaves the module on")
        check(model.history.count == 2 && model.historyIndex == 1, "one history step")
        model.setParam(exposure, ev, to: .number(baseEv + 2.0))
        model.setParam(exposure, ev, to: .number(baseEv + 1.5))
        check(model.history.count == 2, "dragging merges into one step")
        await model.settle()
        print("        edit render \(Int(model.lastMilliseconds ?? 0)) ms")

        model.undo()
        await model.settle()
        check(abs(luma(model) - base) < 0.5, "undo returns to the original frame")
        check(model.isEnabled(exposure) == startedOn, "undo restores the module's imported on/off state")
        model.redo()
        await model.settle()
        check(luma(model) > base + 3, "redo restores the edit")

        print("enable, blend, reset")
        if let sharpen = module(model, "sharpen") {
            model.setEnabled(sharpen, true)
            check(model.isEnabled(sharpen), "sharpen switched on")
            model.setEnabled(sharpen, false)
            check(!model.isEnabled(sharpen), "sharpen switched off again")
        }
        model.setBlend(exposure, "mask_mode", to: .number(1), detail: "blend: uniformly")
        model.setBlend(exposure, "opacity", to: .number(40), detail: "opacity: 40%")
        await model.settle()
        let half = luma(model)
        check(half > base + 0.5 && half < up - 0.5, "40% opacity lands between original and edit (\(String(format: "%.1f", half)))")
        let entry = model.buildStack().first { $0.operation == "exposure" }
        check(entry?.blend["opacity"] == .number(40), "blend travels in the stack entry")
        model.resetModule(exposure)
        await model.settle()
        check(abs(luma(model) - base) < 0.5, "module reset returns to the original frame")

        print("compare and snapshot")
        model.setParam(exposure, ev, to: .number(baseEv + 1.5))
        await model.settle()
        let edited = luma(model)
        model.showingOriginal = true
        await model.settle()
        check(abs(luma(model) - base) < 0.5, "hold-to-compare shows the original")
        model.showingOriginal = false
        await model.settle()
        check(abs(luma(model) - edited) < 0.5, "release returns to the edit")
        model.takeSnapshot()
        model.setParam(exposure, ev, to: .number(baseEv - 1.0))
        await model.settle()
        let dark = luma(model)
        model.showingSnapshot = true
        await model.settle()
        check(abs(luma(model) - edited) < 0.5 && dark < edited, "snapshot shows the earlier edit")
        model.showingSnapshot = false
        await model.settle()

        print("zoom and probe")
        model.viewport = CGSize(width: 900, height: 600)
        model.zoom = .actual
        await model.settle()
        let zw = model.frame?.width ?? 0, zh = model.frame?.height ?? 0
        check(zw > 0 && zw <= Int(900 * model.backingScale) && zh <= Int(600 * model.backingScale),
              "100% region is viewport sized: \(zw)x\(zh)")
        model.pan(byFraction: CGSize(width: 0.1, height: 0))
        await model.settle()
        check(model.frame != nil, "pan re-renders (\(Int(model.lastMilliseconds ?? 0)) ms)")
        model.zoom = .fit
        await model.settle()
        let pr = model.sample(x: (model.frame?.width ?? 2) / 2, y: (model.frame?.height ?? 2) / 2)
        check(pr != nil && pr!.r <= 255, "pixel probe reads the frame: \(pr.map { "\($0.r) \($0.g) \($0.b)" } ?? "none")")

        print("scopes")
        if let s = model.scopes {
            let peak = s.histogram[3].max() ?? 0
            check(s.histogram.count == 4 && peak > 0.99, "histogram has data")
            check((s.waveform.max() ?? 0) > 0.99, "waveform has data")
            check((s.vectorscope.max() ?? 0) > 0.99, "vectorscope has data")
        } else { check(false, "scopes measured after edits") }

        print("history jump")
        model.jump(to: 0)
        await model.settle()
        check(abs(luma(model) - base) < 0.5, "jump to step 0 shows the original")
        model.jump(to: model.history.count - 1)
        await model.settle()

        print("save and reload")
        await model.flushSave()
        check(FileManager.default.fileExists(atPath: copy.path + ".darkroom.json"), "sidecar written next to the raw")
        let saved = model.edits
        let reopened = DarkroomModel(engine: engine)
        await reopened.open(path: copy.path)
        await reopened.settle()
        check(reopened.edits == saved && reopened.history.count == model.history.count,
              "a reopened image restores its edits and history")
        check(abs(luma(reopened) - dark) < 1.0, "and renders the same frame")

        print("export")
        let exportURL = work.appending(path: "export.jpg")
        await model.export(to: exportURL)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int) ?? 0
        check(bytes > 100_000, "export wrote \(bytes) bytes: \(model.status)")
        model.setParam(exposure, ev, to: .number(0.3))
        await model.settle()
        check(model.frame != nil, "session still renders after export (\(Int(model.lastMilliseconds ?? 0)) ms)")

        print(failures.isEmpty ? "\nALL CHECKS PASSED" : "\n\(failures.count) CHECK(S) FAILED")
        if !failures.isEmpty { exit(1) }
    }
}
