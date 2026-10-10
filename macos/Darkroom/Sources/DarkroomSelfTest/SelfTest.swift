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
        let f = e.params.keys.sorted().map { "\($0)=\(String(format: "%g", e.params[$0] ?? 0))" }.joined(separator: ", ")
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

            if ui {
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

    /// Drives the real DarkroomModel the way the sliders do.
    @MainActor
    static func runUI(engine: Engine, path: String) async throws {
        let model = DarkroomModel(engine: engine)
        await model.bootstrap(openingFirstArgument: false)

        await model.open(path: path)
        await model.settle()
        guard let first = model.image else { throw EngineError("no image after open: \(model.status)") }
        print("open: \(first.width)x\(first.height), luma \(String(format: "%.1f", meanLuma(first))), \(Int(model.lastMilliseconds ?? 0)) ms, stack: [\(describe(model.buildStack()))]")

        func spec(_ id: String) -> SliderSpec { Catalog.spec(id)! }
        var results: [(String, Double, Double)] = []   // label, luma, ms

        model.set(spec("exposure"), to: 1.0)
        await model.settle()
        results.append(("exposure +1.0", meanLuma(model.image!), model.lastMilliseconds ?? 0))
        print("exposure +1: luma \(String(format: "%.1f", results[0].1)), \(Int(results[0].2)) ms, stack: [\(describe(model.buildStack()))]")

        // shadows lifts the dark end: the picture gets lighter, and the exposure edit stays
        model.beginScrub()
        model.set(spec("shadows"), to: 60)
        await model.settle()
        let scrubSize = "\(model.image!.width)x\(model.image!.height)"
        print("shadows +60 while scrubbing: \(scrubSize), luma \(String(format: "%.1f", meanLuma(model.image!))), \(Int(model.lastMilliseconds ?? 0)) ms")
        model.endScrub()
        await model.settle()
        let fullSize = "\(model.image!.width)x\(model.image!.height)"
        print("shadows +60 released: \(fullSize), luma \(String(format: "%.1f", meanLuma(model.image!))), \(Int(model.lastMilliseconds ?? 0)) ms, stack: [\(describe(model.buildStack()))]")

        model.set(spec("sharpen"), to: 1.0)
        await model.settle()
        print("sharpen 50%: stack: [\(describe(model.buildStack()))]")

        model.reset(.light)
        await model.settle()
        print("reset light: luma \(String(format: "%.1f", meanLuma(model.image!))), stack: [\(describe(model.buildStack()))]")
    }
}
