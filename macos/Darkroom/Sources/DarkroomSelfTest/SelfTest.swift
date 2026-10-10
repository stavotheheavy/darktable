import CoreGraphics
import DarktableKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Headless check that the Swift side really drives darktable's engine.
//   dtb-selftest <image> [--max 1400] [--out frame.png]
// Prints timings and proves an edit changed the pixels.

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

@main
struct SelfTest {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        let maxSide = Int(take("--max") ?? "") ?? 1400
        let out = take("--out")
        guard let path = args.first else {
            print("usage: dtb-selftest <image> [--max 1400] [--out frame.png]")
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

            await engine.shutdown()
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
}
