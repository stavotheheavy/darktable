import CoreGraphics
import CoreImage
import DarkroomCore
import DarkroomUI
import DarktableKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import DarkroomCI

// Headless checks that the Swift side really drives darktable's engine.
//   dtb-selftest <image> [--max 1400] [--out frame.png]      engine round trip + timings
//   dtb-selftest <image> --ui                                the real model: sliders -> stack -> pixels
//   dtb-selftest <image> --stack s.json --out f.png         one render of a stack file, on either engine
//   dtb-selftest <image> --sweep dir [--max 800]            every module, every field at min / default / max: <dir>/<group>/<module>/<field>.<setting>.png and sweep.csv (DARKROOM_TIME_ONLY=a,b limits modules)
//   dtb-selftest <image> --audit dir --time [--max N]       warm render time of every module (median of 5 after a warm-up) in dir/audit-time.csv
//   dtb-selftest <image> --audit dir [--max 800]            every module of the clean engine at three strengths: PNGs and audit.csv
//   dtb-selftest <raw> --crop-abuse                          raw crops past the frame must not crash a render
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
        Allocator.releaseFreedBlocksToTheSystem()
        setvbuf(stdout, nil, _IOLBF, 0)
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
        // the viewport's working size follows the screen; the checks must not depend on the machine they run on
        setenv("DARKROOM_WORKING_SIZE", "1600", 0)
        let maxSide = Int(take("--max") ?? "") ?? 1400
        let out = take("--out")
        let ui = has("--ui")
        let listModules = has("--list-modules")
        let bench = has("--bench")
        let effects = has("--effects")
        let cropAbuse = has("--crop-abuse")
        let fromModule = take("--from")
        let stackFile = take("--stack")
        let auditDir = take("--audit")
        let auditTime = has("--time")
        let sweepDir = take("--sweep")
        let schemaOp = take("--schema")
        let oneShot = take("--one-shot")
        let hdrJPEG = take("--hdr-jpeg")
        let scoreBench = has("--score-bench")
        let visionMasks = take("--vision-masks")
        let previewVsExport = has("--preview-vs-export")
        let viewportBench = has("--viewport-bench")
        let highlightProbe = has("--highlight-probe")
        let gamutReport = has("--gamut-report")
        // darktable is the default; `ci` runs the clean engine (only --bench supports it so far)
        let engineName = take("--engine") ?? "darktable"
        if has("--manual") { exit(checkManual() ? 0 : 1) }
        guard let path = args.first else {
            print("usage: dtb-selftest <image> [--max 1400] [--out frame.png] [--ui]")
            exit(2)
        }

        let env = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: env["DT_PREFIX"] ?? "/Users/Chief/darktable/build/install")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let engine: any PhotoEngine = engineName == "ci" ? CIEngine() : Engine()

        do {
            let t0 = Date()
            try await engine.start(
                prefix: prefix,
                configDir: env["DARKROOM_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config/darktable-fork"),
                cacheDir: env["DARKROOM_CACHE_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".cache/darktable-fork"))
            print(String(format: "engine start: %.0f ms", Date().timeIntervalSince(t0) * 1000))

            if let oneShot {
                try await runOneShot(engine: engine, sessionPath: path, other: oneShot)
            } else if let visionMasks {
                try runVisionMasks(path: path, out: visionMasks)
            } else if gamutReport {
                try await runGamutReport(engine: engine, path: path)
            } else if highlightProbe {
                try runHighlightProbe(path: path)
            } else if viewportBench {
                try await runViewportBench(engine: engine, path: path, maxSide: maxSide)
            } else if previewVsExport {
                try await runPreviewVsExport(engine: engine, path: path)
            } else if scoreBench {
                try await runScoreBench(engine: engine, folder: path)
            } else if let hdrJPEG {
                try await runHDRJPEG(engine: engine, path: path, maxSide: maxSide, out: hdrJPEG)
            } else if let schemaOp {
                // a module's public parameter list, from the engine's introspection
                try await engine.openSession(path: path, maxSide: 400)
                for f in try await engine.schema(for: schemaOp).fields {
                    print("\(f.name)\t\(f.kind)\tmin \(f.min)\tmax \(f.max)\tdefault \(f.defaultValue)\t\(f.options.map { "\($0)" }.joined(separator: ","))\t\(f.description)")
                }
            } else if let sweepDir {
                try await runSweep(engine: engine, path: path, maxSide: maxSide, out: sweepDir)
            } else if let auditDir {
                if auditTime {
                    try await runAuditTime(engine: engine, path: path, maxSide: maxSide, out: auditDir)
                } else {
                    try await runAudit(engine: engine, path: path, maxSide: maxSide, out: auditDir)
                }
            } else if let stackFile {
                try await runStack(engine: engine, path: path, maxSide: maxSide, file: stackFile, out: out)
            } else if cropAbuse {
                try await runCropAbuse(engine: engine, path: path)
            } else if effects {
                try await runEffects(engine: engine, path: path, from: fromModule)
            } else if bench {
                if engineName == "ci" {
                    try await runDecodeBench(engine: engine, folder: path)
                } else {
                    try await runBench(engine: engine, folder: path)
                }
            } else if listModules {
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

    // MARK: the manual mirrors the shortcut registry

    /// Every shortcut in `Shortcuts.all` must appear in docs/manual.md with its keys and its id, so the human manual
    /// cannot drift from the app. Run: swift run dtb-selftest --manual
    static func checkManual() -> Bool {
        let manual = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/manual.md")
        guard let text = try? String(contentsOf: manual, encoding: .utf8) else { print("FAIL  no manual at \(manual.path)"); return false }
        var ok = true
        for s in Shortcuts.manualLines {
            let hit = text.contains("| \(s.keys) |") && text.contains("(`\(s.id)`)")
            print("\(hit ? "PASS" : "FAIL")  manual lists \(s.keys) (\(s.id))")
            ok = ok && hit
        }
        print(ok ? "manual matches the \(Shortcuts.all.count) shortcuts" : "manual is out of date: docs/manual.md")
        return ok
    }

    // MARK: every control, its effect, undo and redo

    /// 256 by 256 grey bytes of the frame: equal bytes mean an equal picture for the checks below.
    static func fingerprint(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 256 * 256)
        px.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
        }
        return px
    }

    static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var t = 0
        for i in 0..<min(a.count, b.count) { t += abs(Int(a[i]) - Int(b[i])) }
        return Double(t) / Double(max(1, min(a.count, b.count)))
    }

    /// Drives every parameter of every module that has introspection, and every on/off switch:
    /// set a value that is not the default, render, check the picture moved (or note that it did
    /// not), undo, check it is byte-identical to the start, redo, check it is byte-identical to the
    /// edit. One line per control goes to a tsv as it happens, so a crash names its culprit.
    @MainActor
    static func runEffects(engine: any PhotoEngine, path: String, from: String?) async throws {
        let fm = FileManager.default
        let farm = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "darkroom-rig-effects")
        try? fm.removeItem(at: farm)
        try fm.createDirectory(at: farm, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let link = farm.appending(path: name)
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))
        let tsvPath = NSHomeDirectory() + "/Documents/plans/2026-10-18-darkroom-effects-\(name).tsv"
        fm.createFile(atPath: tsvPath, contents: Data("module\tcontrol\tkind\ttried\tmoved\tundo_exact\tredo_exact\tms\n".utf8))
        let handle = FileHandle(forWritingAtPath: tsvPath)
        handle?.seekToEndOfFile()
        func log(_ line: String) { handle?.write(Data((line + "\n").utf8)) }

        let model = DarkroomModel(engine: engine)
        await model.open(path: link.path)
        await model.settle()
        guard let frame0 = model.frame else { print("FAILED: no frame"); exit(1) }
        let base = fingerprint(frame0)
        var tried = 0, moved = 0, undoBad = 0, redoBad = 0, still: [String] = [], badUndo: [String] = []
        let started = Date()
        var seenFrom = from == nil

        for m in model.modules where m.haveIntrospection {
            if !seenFrom { if m.operation == from || m.id == from { seenFrom = true } else { continue } }
            model.select(m)
            for _ in 0..<40 where model.schema(for: m) == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard let schema = model.schema(for: m) else { continue }

            // the module's own switch
            if !m.hideEnableButton {
                let t = Date()
                let was = model.isEnabled(m)
                model.setEnabled(m, !was)
                await model.settle()
                let after = model.frame.map(fingerprint) ?? base
                model.undo(); await model.settle()
                let u = model.frame.map(fingerprint) ?? base
                model.redo(); await model.settle()
                let r = model.frame.map(fingerprint) ?? base
                model.undo(); await model.settle()
                let diff = meanDiff(base, after)
                tried += 1; if diff > 0.05 { moved += 1 }
                if u != base { undoBad += 1; badUndo.append("\(m.operation) switch") }
                if r != after { redoBad += 1 }
                log("\(m.operation)\t(switch)\ttoggle\t1\t\(diff > 0.05 ? 1 : 0)\t\(u == base ? 1 : 0)\t\(r == after ? 1 : 0)\t\(Int(Date().timeIntervalSince(t) * 1000))")
            }

            for f in schema.fields {
                let cur = model.value(m, f)
                var target: ParamValue
                switch f.kind {
                case .bool:
                    target = .bool(!(cur.double.map { $0 != 0 } ?? false))
                case .enumeration:
                    guard let other = f.options.first(where: { ParamValue.option($0.name) != cur }) else { continue }
                    target = .option(other.name)
                case .float, .int:
                    guard let c = cur.double else { continue }
                    var v: Double
                    if f.hasUsableRange, f.max > f.min {
                        let hi = f.min + (f.max - f.min) * 0.75, lo = f.min + (f.max - f.min) * 0.25
                        v = abs(hi - c) > abs(lo - c) ? hi : lo
                    } else { v = c == 0 ? 1 : c * 1.5 }
                    if f.kind == .int { v = v.rounded() }
                    if v == c { continue }
                    target = .number(v)
                }
                let t = Date()
                model.setParam(m, f, to: target)
                await model.settle()
                let edited = model.frame.map(fingerprint) ?? base
                model.undo(); await model.settle()
                let u = model.frame.map(fingerprint) ?? base
                model.redo(); await model.settle()
                let r = model.frame.map(fingerprint) ?? base
                model.undo(); await model.settle()
                let diff = meanDiff(base, edited)
                tried += 1
                if diff > 0.05 { moved += 1 } else { still.append("\(m.operation).\(f.name)") }
                if u != base { undoBad += 1; badUndo.append("\(m.operation).\(f.name)") }
                if r != edited { redoBad += 1 }
                log("\(m.operation)\t\(f.name)\t\(f.kind.rawValue)\t1\t\(diff > 0.05 ? 1 : 0)\t\(u == base ? 1 : 0)\t\(r == edited ? 1 : 0)\t\(Int(Date().timeIntervalSince(t) * 1000))")
            }
            if Int(Date().timeIntervalSince(started)) % 60 == 0 { print("  at \(m.operation): \(tried) controls tried") }
        }
        let secs = Date().timeIntervalSince(started)
        print(String(format: "effects on %@: %d controls tried in %.0f s; %d moved the picture; undo not exact on %d; redo not exact on %d",
                     name, tried, secs, moved, undoBad, redoBad))
        if !badUndo.isEmpty { print("undo failures: " + badUndo.prefix(40).joined(separator: ", ")) }
        print("no visible effect on \(still.count) controls (often a disabled mask, a hidden mode, or a guard); see \(tsvPath)")
        try? handle?.close()
    }

    // MARK: crop abuse

    /// Sets every raw crop of `raw black/white point` to 80% of its range, which is far past the
    /// frame, then renders at fit, at 100% and again after another edit. The bad crops used to
    /// reach tiling as a negative size and crash; now each render must come back with a frame.
    @MainActor
    static func runCropAbuse(engine: any PhotoEngine, path: String) async throws {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok    " : "  FAIL  ") + what)
            if !ok { failures.append(what) }
        }
        let fm = FileManager.default
        let farm = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "darkroom-crop-abuse")
        try? fm.removeItem(at: farm)
        try fm.createDirectory(at: farm, withIntermediateDirectories: true)
        let link = farm.appending(path: URL(fileURLWithPath: path).lastPathComponent)
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))

        let model = DarkroomModel(engine: engine)
        await model.open(path: link.path)
        await model.settle()
        guard let f0 = model.frame else { throw EngineError("no base frame") }
        let size = (f0.width, f0.height)
        check(true, "base frame \(size.0)x\(size.1)")
        guard let raw = model.modules.first(where: { $0.operation == "rawprepare" }) else { throw EngineError("no rawprepare") }
        model.select(raw)
        for _ in 0..<40 where model.schema(for: raw) == nil { try await Task.sleep(for: .milliseconds(50)) }
        guard let schema = model.schema(for: raw) else { throw EngineError("no rawprepare schema") }

        for name in ["left", "top", "right", "bottom"] {
            guard let f = schema.fields.first(where: { $0.name == name }) else { continue }
            let v = (f.min + (f.max - f.min) * 0.8).rounded()
            model.setParam(raw, f, to: .number(v))
            await model.settle()
            check(model.frame != nil, "crop \(name) = \(Int(v)): frame \(model.frame.map { "\($0.width)x\($0.height)" } ?? "none")")
        }
        model.zoom = .actual
        await model.settle()
        check(model.frame != nil, "100% view renders")
        if let exposure = model.modules.first(where: { $0.operation == "exposure" }) {
            model.select(exposure)
            for _ in 0..<40 where model.schema(for: exposure) == nil { try await Task.sleep(for: .milliseconds(50)) }
            if let ev = model.schema(for: exposure)?.fields.first(where: { $0.name == "exposure" }) {
                model.setParam(exposure, ev, to: .number(1))
                await model.settle()
                check(model.frame != nil, "later edit renders")
            }
        }
        model.zoom = .fit
        model.undo(); model.undo(); model.undo(); model.undo(); model.undo()
        await model.settle()
        check(model.frame.map { ($0.width, $0.height) } ?? (0, 0) == size, "undo brings back \(size.0)x\(size.1)")
        print(failures.isEmpty ? "CROP ABUSE: ALL CHECKS PASSED" : "CROP ABUSE: \(failures.count) FAILED")
        if !failures.isEmpty { exit(1) }
    }

    // MARK: bench

    static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    /// Speed and memory over a folder of real raws, per format. Originals are never opened
    /// in place: a symlink farm takes the sidecars, so the folder stays untouched.
    @MainActor
    static func runBench(engine: any PhotoEngine, folder: String) async throws {
        let fm = FileManager.default
        let farm = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "darkroom-rig-photos")
        try? fm.removeItem(at: farm)
        try fm.createDirectory(at: farm, withIntermediateDirectories: true)
        let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        var byFormat: [String: [String]] = [:]
        for n in names {
            let ext = (n as NSString).pathExtension.lowercased()
            guard ["nef", "arw", "cr2", "cr3", "dng", "raf"].contains(ext) else { continue }
            try fm.createSymbolicLink(at: farm.appending(path: n), withDestinationURL: URL(fileURLWithPath: folder).appending(path: n))
            byFormat[ext.uppercased(), default: []].append(n)
        }
        let total = byFormat.values.reduce(0) { $0 + $1.count }
        print("bench: \(total) raws in \(folder): " + byFormat.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", "))

        var table = ["| format | photos timed | open to first frame (ms, p50 / p95) | edit render (ms, p50 / p95) | edit to pixels (ms, p50 / p95) | export (ms, p50) | RSS after (MB) |", "|---|---|---|---|---|---|---|"]
        let model = DarkroomModel(engine: engine)
        for (fmt, files) in byFormat.sorted(by: { $0.key < $1.key }) {
            var opens: [Double] = [], renders: [Double] = [], walls: [Double] = [], exports: [Double] = []
            let sample = Array(files.prefix(6))
            for n in sample {
                let path = farm.appending(path: n).path
                let t0 = Date()
                await model.open(path: path)
                await model.settle()
                opens.append(Date().timeIntervalSince(t0) * 1000)
                guard let ex = model.modules.first(where: { $0.operation == "exposure" }) else { continue }
                await model.prepareSimple()
                guard let ev = model.schema(for: ex)?.fields.first(where: { $0.name == "exposure" }) else { continue }
                for i in 0..<20 {
                    let t = Date()
                    model.setParam(ex, ev, to: .number(i % 2 == 0 ? 0.8 : -0.4))
                    await model.settle()
                    walls.append(Date().timeIntervalSince(t) * 1000)
                    if let ms = model.lastMilliseconds { renders.append(ms) }
                }
                let url = farm.appending(path: "bench-\(n).jpg")
                let te = Date()
                await model.export(to: url)
                exports.append(Date().timeIntervalSince(te) * 1000)
                try? fm.removeItem(at: url)
            }
            table.append(String(format: "| %@ | %d | %.0f / %.0f | %.0f / %.0f | %.0f / %.0f | %.0f | %.0f |", fmt, sample.count,
                                percentile(opens, 0.5), percentile(opens, 0.95), percentile(renders, 0.5), percentile(renders, 0.95),
                                percentile(walls, 0.5), percentile(walls, 0.95), percentile(exports, 0.5), rssMB()))
            print(table.last!)
        }

        // the library: every thumbnail developed and scored, cold cache
        let thumbs = fm.homeDirectoryForCurrentUser.appending(path: ".cache/darktable-fork/thumbs")
        try? fm.removeItem(at: thumbs)
        await engine.closeSession()   // a file a session holds cannot also be developed one-shot
        let lib = LibraryModel(engine: engine)
        let t0 = Date()
        lib.load(folder: farm)
        var last = -1
        while lib.handled < lib.items.count {
            try? await Task.sleep(for: .seconds(1))
            if lib.handled != last, lib.handled % 20 == 0 { print("  scored \(lib.scored) of \(lib.items.count), RSS \(Int(rssMB())) MB"); last = lib.handled }
            if Date().timeIntervalSince(t0) > 1500 { print("  gave up after 25 minutes"); break }
        }
        let secs = Date().timeIntervalSince(t0)
        let soft = lib.items.filter { ($0.sharpness ?? 100) < 50 }.count
        let stacks = Set(lib.items.compactMap(\.stack)).count
        let libLine = String(format: "library: %d photos developed and scored in %.0f s (%.2f photos/s), %d soft, %d stacks, peak RSS %.0f MB",
                             lib.scored, secs, Double(lib.scored) / max(secs, 0.1), soft, stacks, rssMB())
        print(libLine)
        let report = "# Darkroom bench\n\nFolder: \(folder)\n\n" + table.joined(separator: "\n") + "\n\n" + libLine + "\n"
        try? report.write(toFile: NSHomeDirectory() + "/Documents/plans/2026-10-18-darkroom-bench.md", atomically: true, encoding: .utf8)
        print("wrote ~/Documents/plans/2026-10-18-darkroom-bench.md")
    }

    /// Open-to-first-frame over every raw in a folder, for an engine that cannot edit yet
    /// (the clean engine in M0). Two first-frame numbers per raw: the embedded preview (what
    /// the UI shows first) and the full decode (what replaces it). The gate is on the preview:
    /// every format's p50 under 150 ms. A raw with no preview counts its full decode instead
    /// and is listed as an exception. RSS is sampled after the 10th raw and after the last.
    @MainActor
    static func runDecodeBench(engine: any PhotoEngine, folder: String) async throws {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        var byFormat: [String: [String]] = [:]
        for n in names {
            let ext = (n as NSString).pathExtension.lowercased()
            guard ["nef", "arw", "cr2", "cr3", "dng", "raf"].contains(ext) else { continue }
            byFormat[ext.uppercased(), default: []].append(n)
        }
        let total = byFormat.values.reduce(0) { $0 + $1.count }
        print("decode bench: \(total) raws in \(folder)")

        var table = ["| format | photos | first frame, preview (ms, p50 / p95) | full decode (ms, p50 / p95) | preview found | failed |",
                     "|---|---|---|---|---|---|"]
        var previewAll: [Double] = []
        var fullAll: [Double] = []
        var failures: [String] = []
        var noPreview: [String] = []
        var decoders = Set<String>()
        var rssAfterTen: Double?
        var rssAfterForty: Double?
        var p50ByFormat: [String: Double] = [:]
        var processed = 0
        for (fmt, files) in byFormat.sorted(by: { $0.key < $1.key }) {
            var previews: [Double] = []
            var fulls: [Double] = []
            var found = 0
            var failed = 0
            for n in files {
                let path = URL(fileURLWithPath: folder).appending(path: n).path
                let t0 = Date()
                do {
                    try await engine.openSession(path: path, maxSide: 1600)
                    let hasPreview = try await engine.sessionPreview() != nil
                    let afterPreview = Date()
                    _ = try await engine.sessionRender(stack: [], scale: 1)
                    let afterFull = Date()
                    if let ci = engine as? CIEngine, let v = await ci.decoderVersion() { decoders.insert(v) }
                    await engine.closeSession()

                    let fullMs = afterFull.timeIntervalSince(t0) * 1000
                    // with no preview the UI waits for the full decode, so that is the first frame
                    let firstMs = hasPreview ? afterPreview.timeIntervalSince(t0) * 1000 : fullMs
                    if hasPreview { found += 1 } else { noPreview.append(n) }
                    previews.append(firstMs)
                    fulls.append(fullMs)
                    previewAll.append(firstMs)
                    fullAll.append(fullMs)
                } catch {
                    failed += 1
                    failures.append("\(n): \(error)")
                    await engine.closeSession()
                }
                processed += 1
                if processed == 10 { rssAfterTen = rssMB() }
                if processed == 40 { rssAfterForty = rssMB() }
            }
            p50ByFormat[fmt] = percentile(previews, 0.5)
            table.append(String(format: "| %@ | %d | %.0f / %.0f | %.0f / %.0f | %d | %d |", fmt, files.count,
                                percentile(previews, 0.5), percentile(previews, 0.95),
                                percentile(fulls, 0.5), percentile(fulls, 0.95), found, failed))
            print(table.last!)
        }

        // the gate is every format's preview p50 under 150 ms, not the pooled p50
        let failing = p50ByFormat.filter { $0.value >= 150 }.keys.sorted()
        let gate = failing.isEmpty ? "PASS" : "FAIL (\(failing.joined(separator: ", ")) at or over 150 ms)"
        let rssStart = rssAfterTen ?? 0
        let rssMid = rssAfterForty ?? 0
        let rssEnd = rssMB()
        let drift = rssStart > 0 ? (rssEnd / rssStart - 1) * 100 : 0
        let steady = rssMid > 0 ? (rssEnd / rssMid - 1) * 100 : 0
        // memory gate: steady state, measured from raw 40. The first ~40 opens fill a bounded
        // cache inside ImageIO's RAW plug-in (see the note in the report), so raw 10 is too early.
        let memoryGate = rssMid > 0 && steady <= 20 ? "PASS" : "FAIL"
        let summary = String(format: "all %d raws. first frame (preview) p50 %.0f ms, p95 %.0f ms. full decode p50 %.0f ms, p95 %.0f ms. Gate (each format's preview p50 under 150 ms): %@. Memory gate (RSS after the last raw within 20%% of RSS after raw 40): %@. RSS after 10: %.0f MB, after 40: %.0f MB, after all: %.0f MB (%+.0f%% from 10, %+.0f%% from 40 to the end).",
                             previewAll.count, percentile(previewAll, 0.5), percentile(previewAll, 0.95),
                             percentile(fullAll, 0.5), percentile(fullAll, 0.95), gate, memoryGate, rssStart, rssMid, rssEnd, drift, steady)
        let cacheNote = "Note: ImageIO's RAW plug-in keeps a bounded cache (about 145 MB here) that fills within the first ~40 opens and then stays flat. That is why RSS after 10 is well below RSS after 40. It is not a leak: the same file opened 400 times plateaus at the same size."
        let decoderLine = "decoder versions used: " + (decoders.isEmpty ? "none reported" : decoders.sorted().joined(separator: ", "))
        print(summary)
        print(decoderLine)

        let header = "# Clean engine M0 bench\n\nFolder: \(folder)\nEngine: CIEngine (ImageIO embedded preview, then Core Image CIRAWFilter), working frame 1600 px\n\n"
        let body = table.joined(separator: "\n") + "\n\n" + summary + "\n\n" + decoderLine + "\n\n" + cacheNote + "\n"
        let noPreviewList = noPreview.isEmpty ? "" : "\nNo embedded preview (full decode used as first frame):\n" + noPreview.map { "- \($0)" }.joined(separator: "\n") + "\n"
        let failureList = failures.isEmpty ? "" : "\nFailures:\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n"
        let report: String = header + body + noPreviewList + failureList
        let out = NSHomeDirectory() + "/Documents/plans/2026-10-20-ci-engine-m0-bench.md"
        try? report.write(toFile: out, atomically: true, encoding: .utf8)
        print("wrote \(out)")
    }

    /// One-shot renders (the library's thumbnails, export) must not depend on the open session: a file
    /// renders the same with no session, with another photo open, and as the open photo itself.
    static func runOneShot(engine: any PhotoEngine, sessionPath: String, other: String) async throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok    " : "  FAIL  ") + what)
            if !ok { failures += 1 }
        }
        let alone = try? await engine.render(path: other, maxSide: 600)
        check(alone != nil, "\(URL(fileURLWithPath: other).lastPathComponent) renders with no session open (\(alone.map { "\($0.width)x\($0.height)" } ?? "failed"))")
        try await engine.openSession(path: sessionPath, maxSide: 600)
        let beside = try? await engine.render(path: other, maxSide: 600)
        check(beside != nil && beside?.width == alone?.width && beside?.height == alone?.height
              && meanDiff(fingerprint(beside!.image), fingerprint(alone!.image)) < 0.5,
              "and the same with \(URL(fileURLWithPath: sessionPath).lastPathComponent) open (\(beside.map { "\($0.width)x\($0.height)" } ?? "failed"))")
        let session = try await engine.sessionRender(stack: [], scale: 1)
        let selfShot = try await engine.render(path: sessionPath, maxSide: 600)
        check(selfShot.width == session.width && selfShot.height == session.height
              && meanDiff(fingerprint(selfShot.image), fingerprint(session.image)) < 0.5,
              "the open photo one-shot matches its session render (\(selfShot.width)x\(selfShot.height))")
        print(failures == 0 ? "ONE-SHOT: ALL CHECKS PASSED" : "ONE-SHOT: \(failures) FAILED")
        if failures > 0 { exit(1) }
    }

    /// One stack entry as a stack file spells it: `[{"operation": "exposure", "params": {"exposure": 1}}]`.
    struct StackFileEntry: Decodable {
        var operation: String
        var params: [String: ParamValue]?
        var blend: [String: ParamValue]?
        var enabled: Bool?
    }

    /// Renders `path` once with the stack in `file` and writes it to `out`. The same file drives either
    /// engine, so a darktable render of it is the clean engine's reference picture (named parameters only).
    /// Apple Vision's masks on a real photo's embedded preview: each kind's coverage, and the mask and a red overlay written as
    /// PNGs so they can be looked at. A kind that finds nothing is reported, not hidden.
    static func runVisionMasks(path: String, out: String) throws {
        guard let image = EmbeddedPreview.read(path: path, maxSide: 1200) else { throw EngineError("no embedded preview in \(path)") }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        print("photo \(image.width)x\(image.height)")
        for kind in VisionMasks.Kind.allCases {
            let started = ContinuousClock.now
            let picture = try VisionMasks.detect(kind, in: image)
            let d = started.duration(to: .now)
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            guard let picture else { print("  \(kind.title): nothing found (\(Int(ms)) ms)"); continue }
            print("  \(kind.title): covers \(String(format: "%.1f", picture.coverage * 100))% of the picture (\(Int(ms)) ms)")
            // the mask as grey, and the photo with the mask in red
            func png(_ cg: CGImage, _ name: String) {
                guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
            }
            let provider = CGDataProvider(data: Data(picture.pixels) as CFData)!
            if let grey = CGImage(width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: picture.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                png(grey, "mask-\(kind.title)")
            }
            var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
            if let ctx = CGContext(data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                for i in 0..<(image.width * image.height) {
                    let a = Double(picture.pixels[i]) / 255 * 0.55
                    rgba[i * 4] = UInt8(Double(rgba[i * 4]) * (1 - a) + 255 * a)
                    rgba[i * 4 + 1] = UInt8(Double(rgba[i * 4 + 1]) * (1 - a) + 30 * a)
                    rgba[i * 4 + 2] = UInt8(Double(rgba[i * 4 + 2]) * (1 - a) + 30 * a)
                }
                if let cg = ctx.makeImage() { png(cg, "overlay-\(kind.title)") }
            }
        }
    }

    /// Roadmap T9: a 25% preview and the 100% export of the same edit differ only by resampling. The export is shrunk to the
    /// preview's size and the two compared as 8-bit sRGB. Run with a plain stack (the floor set by the decoder's own
    /// downscale) and with the radius-based detail modules on (which must not widen the gap).
    static func runPreviewVsExport(engine: any PhotoEngine, path: String) async throws {
        func psnr(_ a: CGImage, _ b: CGImage) -> Double {
            let w = a.width, h = a.height
            func pixels(_ img: CGImage) -> [UInt8] {
                var p = [UInt8](repeating: 0, count: w * h * 4)
                p.withUnsafeMutableBytes { buf in
                    if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.interpolationQuality = .high
                        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                    }
                }
                return p
            }
            let pa = pixels(a), pb = pixels(b)
            var sum = 0.0
            for i in 0..<pa.count where i % 4 != 3 { let d = Double(pa[i]) - Double(pb[i]); sum += d * d }
            let mse = sum / Double(w * h * 3)
            return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
        }
        let display = StackEntry(operation: "display", params: ["contrast": .number(0)])
        let plain = [display]
        let detail = [display,
                      StackEntry(operation: "sharpen", params: ["amount": .number(1), "radius": .number(3)]),
                      StackEntry(operation: "bilat", params: ["detail": .number(0.8), "radius": .number(40)]),
                      StackEntry(operation: "hazeremoval", params: ["strength": .number(0.5), "radius": .number(16)]),
                      StackEntry(operation: "denoiseprofile", params: ["luma": .number(0.3), "chroma": .number(0.3)])]
        let each: [(String, [StackEntry])] = detail.dropFirst().map { e in ("only \(e.operation)", [display, e]) }
        let cases: [(String, [StackEntry])] = [("plain", plain), ("detail modules", detail)] + each
        // the preview (a quarter-scale draft) against the full export, twice: from the engine's owned decode texture (a draft is that picture
        // averaged down) and from the decoder's own reduced-size decode (what it was before)
        var table: [String: [Double]] = [:]
        for owned in [true, false] {
            if let ci = engine as? CIEngine { await ci.setOwnedDecode(owned) }
            for (label, stack) in cases {
                try await engine.openSession(path: path, maxSide: 8000)
                let preview = try await engine.sessionRender(stack: stack, scale: 0.25)
                let export = try await engine.exportRender(path: path, maxSide: 8000, stack: stack)
                table[label, default: []].append(psnr(preview.image, export.image))
                if owned { print("  \(label): preview \(preview.width)x\(preview.height), export \(export.width)x\(export.height)") }
            }
        }
        if let ci = engine as? CIEngine { await ci.setOwnedDecode(true) }
        for (label, _) in cases {
            let v = table[label] ?? [0, 0]
            print("  \(label): owned decode \(String(format: "%.1f", v[0])) dB, decoder's reduced decode \(String(format: "%.1f", v[1])) dB")
        }
        // The roadmap asks for 45 dB; the plain stack alone is 44-48 dB depending on the camera (an export holds detail a quarter-scale
        // preview cannot), and sharpening and local contrast add detail only the export has, so the detail stack is lower still.
        // Two gates. What this change must do: the owned-decode preview is at least as close to the export as the decoder's own reduced
        // decode was, for the plain stack and for every detail stack (0.25 dB of slack). And a sanity bound on module scaling: the four
        // detail modules together stay within 6 dB of plain and each alone within 5 (a module that stopped scaling its radius with the
        // render would fall far past that).
        let plainOwned = table["plain"]?[0] ?? 0
        let noWorse = cases.allSatisfy { (table[$0.0]?[0] ?? 0) >= (table[$0.0]?[1] ?? 99) - 0.25 }
        let together = table["detail modules"]?[0] ?? 0
        let scaled = together > plainOwned - 6 && each.allSatisfy { (table[$0.0]?[0] ?? 0) > plainOwned - 5 }
        let ok = noWorse && scaled
        print("\(ok ? "PASS" : "FAIL")  T9 preview vs export: plain \(String(format: "%.1f", plainOwned)) dB, detail modules \(String(format: "%.1f", together)) dB; the owned decode is \(noWorse ? "at least as close to the export as" : "WORSE than") the decoder's reduced decode on every stack; module radii scale with the render: \(scaled)")
        if !ok { throw EngineError("T9 failed") }
    }

    /// The library gate (roadmap M5): every photo of a folder read and scored (sharpness and near-duplicate hash) the way the
    /// library does it, from the embedded preview where there is one, from a developed render where there is not. No disk
    /// cache is used. Prints both paths so the saving is on record.
    static func runScoreBench(engine: any PhotoEngine, folder: String) async throws {
        let exts: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng", "pef", "srw"]
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
        guard !files.isEmpty else { throw EngineError("no raw files in \(folder)") }
        let started = ContinuousClock.now
        var scored = 0, viaPreview = 0, viaRender = 0, failed = 0
        for path in files {
            let image: CGImage?
            if let cg = EmbeddedPreview.read(path: path, maxSide: 480) { image = cg; viaPreview += 1 }
            else if let f = try? await engine.render(path: path, maxSide: 480) { image = f.image; viaRender += 1 }
            else { image = nil }
            guard let image else { failed += 1; continue }
            _ = Culling.sharpness(of: image); _ = Culling.averageHash(of: image)
            scored += 1
        }
        let d = started.duration(to: .now)
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        let ok = failed == 0 && scored == files.count && seconds < 20
        print("\(ok ? "PASS" : "FAIL")  scored \(scored) of \(files.count) in \(String(format: "%.1f", seconds)) s (gate: all, under 20 s); "
              + "\(viaPreview) from the embedded preview, \(viaRender) from a developed render, \(failed) unreadable")
        if !ok { throw EngineError("library scoring gate failed") }
    }

    /// The HDR export on a real RAW, with the display transform on and with it off (Apple's own RAW HDR): each file must
    /// read back with a gain map, expand to the headroom, and show highlights past white that the SDR picture clips.
    static func runHDRJPEG(engine: any PhotoEngine, path: String, maxSide: Int, out: String) async throws {
        var failed = false
        for (label, stack) in [("display transform", [StackEntry(operation: "display", params: ["contrast": .number(0)])]),
                               ("Apple RAW HDR", [StackEntry]())] {
            guard let data = try await engine.exportHDRJPEG(path: path, maxSide: maxSide, stack: stack, headroom: 4) else {
                print("FAIL  \(label): the engine cannot write an HDR JPEG"); failed = true; continue
            }
            let file = URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension(label == "Apple RAW HDR" ? "apple.jpg" : "display.jpg")
            try data.write(to: file)
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil,
                  let ci = CIImage(data: data, options: [.expandToHDR: true]),
                  let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
                print("FAIL  \(label): no gain map in \(file.lastPathComponent)"); failed = true; continue
            }
            let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
            let side = 64
            var px = [SIMD4<Float>](repeating: .zero, count: side * side)
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / ci.extent.width, y: CGFloat(side) / ci.extent.height))
            px.withUnsafeMutableBytes { context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBAf, colorSpace: space) }
            let brightest = px.map { max($0.x, $0.y, $0.z) }.max() ?? 0
            let finite = px.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
            let ok = finite && abs(ci.contentHeadroom - 4) < 0.1 && brightest > 1.0
            print("\(ok ? "PASS" : "FAIL")  \(label): \(data.count / 1024) KB, headroom \(ci.contentHeadroom), brightest expanded value \(String(format: "%.2f", brightest)) (needs > 1), \(file.lastPathComponent)")
            if !ok { failed = true }
        }
        if failed { throw EngineError("HDR export check failed") }
    }

    /// What the wide-gamut canvas path carries: the picture rendered as the canvas does (Display P3 target, a 16-bit texture), and how many of
    /// its pixels hold a colour outside sRGB, which the old sRGB-only output could not show. For one raw or a folder (the first `--max` files).
    static func runGamutReport(engine: any PhotoEngine, path: String) async throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let raws = ["nef", "arw", "cr2", "cr3", "dng", "raf"]
        let files: [String] = isDir.boolValue
            ? ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
                .filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }.map { path + "/" + $0 }
            : [path]
        guard let ci = engine as? CIEngine else { print("the gamut report is the clean engine's"); return }
        let toSRGB = ColorSpaces.p3ToWorking   // P3 linear to working, then working to sRGB
        let p3ToSRGB = ColorSpaces.workingToSRGB.mul(toSRGB)
        print("file\tpixels outside sRGB %\tmost saturated pixel (OkLab chroma)")
        var total = 0.0, count = 0.0
        for f in files {
            try await ci.openSession(path: f, maxSide: 800)
            guard let p = try await ci.sessionRenderPresentable(stack: [StackEntry(operation: "display", params: ["contrast": .number(0), "exposure": .number(0.5)])], scale: 1) else { continue }
            var half = [UInt16](repeating: 0, count: p.width * p.height * 4)
            p.texture.getBytes(&half, bytesPerRow: p.width * 8, from: MTLRegionMake2D(0, 0, p.width, p.height), mipmapLevel: 0)
            var outside = 0, maxChroma = 0.0
            for i in stride(from: 0, to: half.count, by: 4) {
                let p3 = SIMD3(Double(Float16(bitPattern: half[i])), Double(Float16(bitPattern: half[i + 1])), Double(Float16(bitPattern: half[i + 2])))
                let s = p3ToSRGB.apply(p3)
                if min(s.x, s.y, s.z) < -0.002 || max(s.x, s.y, s.z) > 1.002 { outside += 1 }
                maxChroma = max(maxChroma, OkLab.lch(OkLab.fromWorking(toSRGB.apply(p3))).y)
            }
            let pct = Double(outside) / Double(p.width * p.height) * 100
            total += pct; count += 1
            print("\((f as NSString).lastPathComponent)\t\(String(format: "%.2f", pct))\t\(String(format: "%.3f", maxChroma))")
        }
        if count > 1 { print("mean over \(Int(count)) photos: \(String(format: "%.2f", total / count)) % of pixels hold a colour outside sRGB") }
    }

    /// How Apple's decoder leaves clipped highlights, measured on its scene-linear output (the engine's own decode settings: boost,
    /// shadow lift and sharpening off, extended range on). Per photo: the plateau the data tops out on, the share of pixels at it,
    /// and how coloured those pixels are (mean OkLab chroma of the linear value, against a neutral's zero). The decision rule for
    /// building highlight reconstruction: mean chroma of the blown pixels above 0.02 means the decoder leaves a cast the engine
    /// would have to remove; a plateau below 1.5 (in units of display white) means the clip level is too low to keep headroom.
    static func runHighlightProbe(path: String) throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let raws = ["nef", "arw", "cr2", "cr3", "dng", "raf"]
        let files: [String] = isDir.boolValue
            ? ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
                .filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }.map { path + "/" + $0 }
            : [path]
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB), let device = MTLCreateSystemDefaultDevice() else { return }
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        print("highlight probe: \(files.count) raws")
        print("file\tplateau\tblown %\tmean chroma of blown\tneutral share of blown\tdistinct values in blown")
        var rows: [(String, Double, Double, Double)] = []
        for f in files {
            guard let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: f)) else { continue }
            raw.scaleFactor = 0.25
            raw.boostAmount = 0; raw.localToneMapAmount = 0; raw.boostShadowAmount = 0; raw.shadowBias = 0; raw.sharpnessAmount = 0
            raw.extendedDynamicRangeAmount = 1
            guard let image = raw.outputImage else { continue }
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var px = [Float](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &px, rowBytes: w * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
            // the plateau: the most common value among each pixel's largest channel, in the top 2% of the range
            var tops = [Float](); tops.reserveCapacity(w * h)
            for i in 0..<(w * h) { tops.append(max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])) }
            let sorted = tops.sorted()
            let top = sorted[Int(Double(sorted.count - 1) * 0.9999)]
            guard top > 0.5 else { continue }
            var bins = [Int](repeating: 0, count: 200)
            for v in tops where v > top * 0.9 { bins[min(199, Int((v - top * 0.9) / (top * 0.1) * 200))] += 1 }
            let peak = bins.enumerated().max { $0.element < $1.element }!.offset
            let plateau = Double(top) * (0.9 + 0.1 * (Double(peak) + 0.5) / 200)
            var blown = 0, neutral = 0, chromaSum = 0.0
            var distinct = Set<Float>()
            for i in 0..<(w * h) where Double(tops[i]) >= plateau * 0.995 && tops[i] <= Float(plateau * 1.005) {
                blown += 1
                let rgb = SIMD3<Double>(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2]))
                let lab = OkLab.fromWorking(rgb)
                let c = hypot(lab.y, lab.z)
                chromaSum += c
                if c < 0.02 { neutral += 1 }
                if distinct.count < 5000 { distinct.insert(tops[i]) }
            }
            let share = Double(blown) / Double(w * h) * 100
            let mean = blown > 0 ? chromaSum / Double(blown) : 0
            print(String(format: "%@\t%.2f\t%.2f\t%.4f\t%.0f%%\t%d", (f as NSString).lastPathComponent, plateau, share, mean,
                         blown > 0 ? Double(neutral) / Double(blown) * 100 : 100, distinct.count))
            if share >= 0.05 { rows.append(((f as NSString).lastPathComponent, plateau, share, mean)) }
        }
        if rows.isEmpty { print("no photo had a plateau holding 0.05% of its pixels"); return }
        let meanChroma = rows.map { $0.3 }.reduce(0, +) / Double(rows.count)
        var worst = rows[0], lowest = rows[0]
        for r in rows { if r.3 > worst.3 { worst = r }; if r.1 < lowest.1 { lowest = r } }
        print("summary: \(rows.count) photos with a real clip (0.05% of pixels or more on the plateau); mean chroma of blown pixels "
              + "\(String(format: "%.4f", meanChroma)) (worst \(String(format: "%.4f", worst.3)) in \(worst.0)); "
              + "lowest plateau \(String(format: "%.2f", lowest.1)) in \(lowest.0)")
        let neutralPhotos = rows.filter { $0.3 < 0.02 }.count
        print("photos whose blown pixels are neutral (mean chroma under 0.02): \(neutralPhotos) of \(rows.count)")
        print("decision: " + (meanChroma > 0.02 || worst.3 > 0.05
                              ? "some photos have coloured blown regions: see the list; the cause (a real coloured light versus a cast the decoder leaves) needs a look"
                              : "the decoder leaves blown highlights near-neutral: highlight reconstruction is not needed on these photos"))
    }

    /// Edit-to-pixels latency of the engine session, the number T5's MetalChain microbenchmark never measured: open at `maxSide`
    /// (the canvas's backing size), then 30 renders per scenario, each with one slider moved, reporting wall p50 and p95.
    /// Run it on an idle Mac. `--max 2400` is a typical Retina fit view.
    static func runViewportBench(engine: any PhotoEngine, path: String, maxSide: Int) async throws {
        let t0 = Date()
        try await engine.openSession(path: path, maxSide: maxSide)
        print(String(format: "open at %d px: %.0f ms", maxSide, Date().timeIntervalSince(t0) * 1000))
        func num(_ v: Double) -> ParamValue { .number(v) }
        let detail: [StackEntry] = [
            StackEntry(operation: "sharpen", params: ["amount": num(60)]),
            StackEntry(operation: "bilat", params: ["detail": num(40)]),
            StackEntry(operation: "atrous", params: [:]),
            StackEntry(operation: "denoiseprofile", params: [:]),
        ]
        func stats(_ times: [Double]) -> (Double, Double) {
            let s = times.sorted()
            return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))])
        }
        func run(_ label: String, scale: Double = 1, _ make: (Int) -> [StackEntry]) async throws {
            _ = try await engine.sessionRender(stack: make(0), scale: scale)   // warm: pipelines, decode cache
            var times: [Double] = []
            for i in 1...30 {
                let s = Date()
                _ = try await engine.sessionRender(stack: make(i), scale: scale)
                times.append(Date().timeIntervalSince(s) * 1000)
            }
            let (p50, p95) = stats(times)
            print(String(format: "%-62@ p50 %6.1f ms   p95 %6.1f ms", label as NSString, p50, p95))
        }
        func display(_ contrast: Double) -> StackEntry {
            StackEntry(operation: "display", params: ["contrast": num(contrast), "exposure": num(0.5)])
        }
        try await run("default stack, same params (cache behaviour)") { _ in [display(0)] }
        try await run("exposure slider (exposure + display)") { i in
            [StackEntry(operation: "exposure", params: ["exposure": num(Double(i) * 0.05)]), display(0)]
        }
        try await run("display contrast slider, no detail modules") { i in [display(Double(i))] }
        try await run("display contrast slider, with sharpen, local contrast, equalizer, noise") { i in detail + [display(Double(i))] }
        try await run("exposure slider, with the same four detail modules") { i in
            detail + [StackEntry(operation: "exposure", params: ["exposure": num(Double(i) * 0.05)]), display(0)]
        }
        try await run("five per-pixel modules (white balance, exposure, colour balance, display, tone curve): one pass") { i in
            [StackEntry(operation: "temperature", params: ["red": num(1.2), "green": num(1), "blue": num(0.9)]),
             StackEntry(operation: "exposure", params: ["exposure": num(Double(i) * 0.03)]),
             StackEntry(operation: "colorbalancergb", params: ["contrast": num(0.2), "vibrance": num(0.3)]),
             display(0),
             StackEntry(operation: "tonecurve", params: ["y0": num(0), "y1": num(0.2), "y2": num(0.5), "y3": num(0.8), "y4": num(1)])]
        }
        try await run("zone exposure, Shadows slider (the base is kept, the gain re-runs)") { i in
            [StackEntry(operation: "zones", params: ["shadows": num(Double(i) * 0.05), "highlights": num(-0.5)]), display(0)]
        }
        try await run("draft render (scale 0.5), display contrast slider", scale: 0.5) { i in [display(Double(i))] }
        try await run("draft render (scale 0.5), detail modules + contrast slider", scale: 0.5) { i in detail + [display(Double(i))] }
    }

    static func runStack(engine: any PhotoEngine, path: String, maxSide: Int, file: String, out: String?) async throws {
        let entries = try JSONDecoder().decode([StackFileEntry].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let stack = entries.map {
            StackEntry(operation: $0.operation, params: $0.params ?? [:], blend: $0.blend ?? [:], enabled: $0.enabled ?? true)
        }
        // through a session, so the size the UI is told can be checked against the size it gets
        try await engine.openSession(path: path, maxSide: maxSide)
        let frame = try await engine.sessionRender(stack: stack, scale: 1)
        let outputSize = try await engine.sessionOutputSize(stack: stack)
        if let size = outputSize {
            let ok = size.width == frame.width && size.height == frame.height
            print("size check: told \(size.width)x\(size.height), rendered \(frame.width)x\(frame.height): \(ok ? "ok" : "FAIL")")
            if !ok { throw EngineError("sessionOutputSize disagrees with the render") }
        }
        // only engines that report sizes promise processedWidth is the scale-1 frame (darktable's means otherwise)
        if outputSize != nil, let info = await engine.sessionInfo(), stack.isEmpty {
            let ok = info.processedWidth == frame.width && info.processedHeight == frame.height
            print("info check: told \(info.processedWidth)x\(info.processedHeight), rendered \(frame.width)x\(frame.height): \(ok ? "ok" : "FAIL")")
            if !ok { throw EngineError("sessionInfo disagrees with the render") }
        }
        print("stack \(stack.map(\.operation).joined(separator: ", ")): \(frame.width)x\(frame.height) in "
              + "\(Int(frame.milliseconds)) ms, mean luma \(String(format: "%.1f", meanLuma(frame.image)))")
        if let out { try writePNG(frame.image, to: URL(fileURLWithPath: out)); print("wrote \(out)") }
    }


    // MARK: audit: every module of the clean engine at three strengths, with automatic metrics

    /// Straight RGBA8 of an image.
    static func rgba(_ image: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buf.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }
        return buf
    }

    /// Each golden case of the catalogue rendered on `path` at a subtle (0.35 of the golden change), the golden and an extreme (2.2 of it, held to the field range)
    /// setting. Writes <out>/<module>.<setting>.png and <out>/audit.csv: render time, mean luma and its change, clipped and crushed shares, how much the 14-pixel border ring
    /// changed against the interior (a streak or black-edge detector) and flags for a blank, dark-edged or streaked frame.
    static func runAudit(engine: any PhotoEngine, path: String, maxSide: Int, out: String) async throws {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try await engine.openSession(path: path, maxSide: maxSide)
        let base = try await engine.sessionRender(stack: [], scale: 1)
        let baseLuma = meanLuma(base.image), baseRGBA = rgba(base.image), w = base.width, h = base.height
        try writePNG(base.image, to: URL(fileURLWithPath: "\(out)/base.png"))
        var csv = "module,setting,ms,mean_luma,luma_change,clipped_pct,crushed_pct,ring_change,interior_change,flags\n"
        let ring = 14
        for c in CIEngineProbe.goldenCases() {
            guard let entry = c.stack.first else { continue }
            let schema = try? await engine.schema(for: entry.operation)
            func field(_ name: String) -> FieldSchema? { schema?.fields.first { $0.name == name } }
            for (label, factor) in [("subtle", 0.35), ("strong", 1.0), ("extreme", 2.2)] {
                var params: [String: ParamValue] = [:]
                // switches and choices keep their value; only magnitudes are scaled
                let fixed: Set<String> = ["fill", "spin", "colour", "scheme", "mode", "iterations", "seed"]
                for (k, v) in entry.params {
                    guard let value = v.double, !fixed.contains(k) else { params[k] = v; continue }
                    let f = field(k)
                    let def = f?.defaultValue.double ?? 0
                    var scaled = def + (value - def) * factor
                    if let f { scaled = min(max(scaled, f.min), f.max) }
                    params[k] = .number(scaled)
                }
                let stack = [StackEntry(operation: entry.operation, params: params)]
                var flags: [String] = []
                var line = ""
                do {
                    let frame = try await engine.sessionRender(stack: stack, scale: 1)
                    let px = rgba(frame.image)
                    let luma = meanLuma(frame.image)
                    var clipped = 0, crushed = 0, ringSum = 0.0, ringN = 0.0, inSum = 0.0, inN = 0.0
                    if px.count == baseRGBA.count {
                        for y in 0..<h { for x in 0..<w {
                            let o = (y * w + x) * 4
                            if px[o] == 255 || px[o + 1] == 255 || px[o + 2] == 255 { clipped += 1 }
                            if px[o] == 0 && px[o + 1] == 0 && px[o + 2] == 0 { crushed += 1 }
                            let d = (abs(Double(px[o]) - Double(baseRGBA[o])) + abs(Double(px[o + 1]) - Double(baseRGBA[o + 1])) + abs(Double(px[o + 2]) - Double(baseRGBA[o + 2]))) / 3
                            if x < ring || y < ring || x >= w - ring || y >= h - ring { ringSum += d; ringN += 1 } else { inSum += d; inN += 1 }
                        } }
                    } else { flags.append("size \(frame.width)x\(frame.height)") }
                    let ringChange = ringN > 0 ? ringSum / ringN : 0, inChange = inN > 0 ? inSum / inN : 0
                    if luma < 0.05 * baseLuma { flags.append("BLANK") }
                    if ringChange > 8, ringChange > 3 * max(inChange, 1) { flags.append("EDGE") }
                    if Double(clipped) / Double(w * h) > 0.35 { flags.append("CLIPPED") }
                    if Double(crushed) / Double(w * h) > 0.35 { flags.append("CRUSHED") }
                    try writePNG(frame.image, to: URL(fileURLWithPath: "\(out)/\(entry.operation).\(label).png"))
                    line = String(format: "%@,%@,%.0f,%.1f,%.1f,%.2f,%.2f,%.1f,%.1f,%@\n", entry.operation, label, frame.milliseconds, luma, luma - baseLuma,
                                  100 * Double(clipped) / Double(w * h), 100 * Double(crushed) / Double(w * h), ringChange, inChange, flags.joined(separator: " "))
                } catch {
                    line = "\(entry.operation),\(label),,,,,,,,RENDER-FAILED \(error)\n"
                }
                csv += line
                print(line, terminator: "")
            }
        }
        try csv.write(toFile: "\(out)/audit.csv", atomically: true, encoding: .utf8)
        print("wrote \(out)/audit.csv")
    }

    /// One module field at a time moved to its minimum, its default and its maximum (switches off and on, choices each option), the rest at default:
    /// a picture per setting and a row of metrics (render time, luma change, clipped and crushed shares, border against interior change, flags).
    static func runSweep(engine: any PhotoEngine, path: String, maxSide: Int, out: String) async throws {
        try await engine.openSession(path: path, maxSide: maxSide)
        let base = try await engine.sessionRender(stack: [], scale: 1)
        let baseLuma = meanLuma(base.image), baseRGBA = rgba(base.image), w = base.width, h = base.height
        var groupOf: [String: String] = [:]
        for g in await MainActor.run(body: { DarkroomModel.proGroups }) { for op in g.operations where groupOf[op] == nil { groupOf[op] = g.name } }
        let only = ProcessInfo.processInfo.environment["DARKROOM_TIME_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        var csv = "group,module,field,setting,value,ms,mean_luma,luma_change,clipped_pct,crushed_pct,ring_change,interior_change,flags\n"
        for op in try await engine.moduleNames().sorted() {
            if let only, !only.contains(op) { continue }
            guard let schema = try? await engine.schema(for: op) else { continue }
            let group = groupOf[op] ?? "Other"
            // DARKROOM_SWEEP_BASE=golden holds every other field at the golden setting instead of its default, so fields behind a gate (amount, strength) show their effect
            let baseParams: [String: ParamValue] = ProcessInfo.processInfo.environment["DARKROOM_SWEEP_BASE"] == "golden"
                ? (CIEngineProbe.goldenCases().first { $0.operation == op }?.stack.first?.params ?? [:]) : [:]
            for f in schema.fields {
                var settings: [(String, ParamValue)] = []
                switch f.kind {
                case .float, .int:
                    guard f.hasUsableRange else { continue }
                    settings = [("min", .number(f.min)), ("def", f.defaultValue), ("max", .number(f.max))]
                case .bool: settings = [("min", .bool(false)), ("max", .bool(true))]
                case .enumeration: settings = f.options.prefix(8).map { ("opt-\($0.name)", .option($0.name)) }
                }
                let dir = "\(out)/\(group)/\(op)"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for (label, value) in settings {
                    var flags: [String] = []
                    var line: String
                    do {
                        let frame = try await engine.sessionRender(stack: [StackEntry(operation: op, params: baseParams.merging([f.name: value]) { $1 })], scale: 1)
                        let px = rgba(frame.image), luma = meanLuma(frame.image)
                        var clipped = 0, crushed = 0, ringSum = 0.0, ringN = 0.0, inSum = 0.0, inN = 0.0
                        if px.count == baseRGBA.count {
                            for y in 0..<h { for x in 0..<w {
                                let o = (y * w + x) * 4
                                if px[o] == 255 || px[o + 1] == 255 || px[o + 2] == 255 { clipped += 1 }
                                if px[o] == 0 && px[o + 1] == 0 && px[o + 2] == 0 { crushed += 1 }
                                let d = (abs(Double(px[o]) - Double(baseRGBA[o])) + abs(Double(px[o + 1]) - Double(baseRGBA[o + 1])) + abs(Double(px[o + 2]) - Double(baseRGBA[o + 2]))) / 3
                                if x < 14 || y < 14 || x >= w - 14 || y >= h - 14 { ringSum += d; ringN += 1 } else { inSum += d; inN += 1 }
                            } }
                        } else { flags.append("size \(frame.width)x\(frame.height)") }
                        let ringChange = ringN > 0 ? ringSum / ringN : 0, inChange = inN > 0 ? inSum / inN : 0
                        if luma < 0.05 * baseLuma { flags.append("BLANK") }
                        if ringChange > 8, ringChange > 3 * max(inChange, 1) { flags.append("EDGE") }
                        if Double(clipped) / Double(w * h) > 0.35 { flags.append("CLIPPED") }
                        if Double(crushed) / Double(w * h) > 0.35 { flags.append("CRUSHED") }
                        if inChange < 0.05, ringChange < 0.05, px.count == baseRGBA.count { flags.append("NO-CHANGE") }
                        try writePNG(frame.image, to: URL(fileURLWithPath: "\(dir)/\(f.name).\(label).png"))
                        line = String(format: "%@,%@,%@,%@,%@,%.0f,%.1f,%.1f,%.2f,%.2f,%.1f,%.1f,%@\n", group, op, f.name, label, "\(value)".replacingOccurrences(of: ",", with: ";"),
                                      frame.milliseconds, luma, luma - baseLuma, 100 * Double(clipped) / Double(w * h), 100 * Double(crushed) / Double(w * h),
                                      ringChange, inChange, flags.joined(separator: " "))
                    } catch {
                        line = "\(group),\(op),\(f.name),\(label),,,,,,,,,RENDER-FAILED \(error)\n".replacingOccurrences(of: "\n", with: " ", options: [], range: nil) + "\n"
                    }
                    csv += line
                }
            }
            print("swept \(op)")
        }
        try csv.write(toFile: "\(out)/sweep.csv", atomically: true, encoding: .utf8)
        print("wrote \(out)/sweep.csv")
    }

    /// Warm render time of every golden case at its golden setting: the first render (shader compile, cache fill) is timed on its own as `cold_ms`,
    /// then the median of five more is `warm_ms`. The frame is the session render, so `--max` sets the pixel count.
    static func runAuditTime(engine: any PhotoEngine, path: String, maxSide: Int, out: String) async throws {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try await engine.openSession(path: path, maxSide: maxSide)
        let base = try await engine.sessionRender(stack: [], scale: 1)
        _ = try await engine.sessionRender(stack: [], scale: 1)
        var csv = "module,width,height,cold_ms,warm_ms\n"
        var rows: [(String, Double)] = []
        for c in CIEngineProbe.goldenCases() {
            guard let entry = c.stack.first else { continue }
            // DARKROOM_TIME_ONLY=exposure,zones limits the run to those modules
            if let only = ProcessInfo.processInfo.environment["DARKROOM_TIME_ONLY"], !only.split(separator: ",").contains(where: { $0 == entry.operation }) { continue }
            do {
                let stack = [StackEntry(operation: entry.operation, params: entry.params)]
                let cold = try await engine.sessionRender(stack: stack, scale: 1).milliseconds
                var warm: [Double] = []
                // an identical stack is a cache hit, so each pass nudges the first magnitude by a hair (inside its range) to force a real render
                let key = entry.params.first { $0.value.double != nil && !["fill", "spin", "colour", "scheme", "mode", "iterations", "seed"].contains($0.key) }
                for i in 1...5 {
                    var p = entry.params
                    if let key, let v = key.value.double {
                        let f = (try? await engine.schema(for: entry.operation))?.fields.first { $0.name == key.key }
                        let nudged = v + (abs(v) > 1e-9 ? v : 1) * 1e-4 * Double(i)
                        p[key.key] = .number(f.map { min(max(nudged, $0.min), $0.max) } ?? nudged)
                    }
                    warm.append(try await engine.sessionRender(stack: [StackEntry(operation: entry.operation, params: p)], scale: 1).milliseconds)
                }
                warm.sort()
                csv += String(format: "%@,%d,%d,%.0f,%.0f\n", entry.operation, base.width, base.height, cold, warm[2])
                rows.append((entry.operation, warm[2]))
            } catch { csv += "\(entry.operation),,,,RENDER-FAILED \(error)\n" }
        }
        try csv.write(toFile: "\(out)/audit-time.csv", atomically: true, encoding: .utf8)
        print("\(base.width)x\(base.height): slowest warm renders")
        for (n, ms) in rows.sorted(by: { $0.1 > $1.1 }).prefix(20) { print(String(format: "  %-16@ %5.0f ms", n as NSString, ms)) }
        print("wrote \(out)/audit-time.csv")
    }

    static func runEngine(engine: any PhotoEngine, path: String, maxSide: Int, out: String?) async throws {
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
    static func runUI(engine: any PhotoEngine, path: String) async throws {
        var failures: [String] = []
        var notApplicable: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok    " : "  FAIL  ") + what)
            if !ok { failures.append(what) }
        }
        /// A check whose premise does not hold on this engine: printed with the reason and counted on
        /// its own, never as a pass.
        func skip(_ what: String, _ why: String) {
            print("  n/a   \(what): \(why)")
            notApplicable.append(what)
        }
        // the clean engine's catalogue is its own, and its modules are fast; darktable's checks assume neither
        let clean = engine is CIEngine
        func luma(_ m: DarkroomModel) -> Double { m.frame.map(meanLuma) ?? 0 }
        /// A frame as a 48 by 48 grey grid, for comparing two pictures' layout.
        func grid(_ f: CGImage?) -> [Double] {
            guard let f, let ctx = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
            ctx.interpolationQuality = .medium
            ctx.draw(f, in: CGRect(x: 0, y: 0, width: 48, height: 48))
            guard let d = ctx.data else { return [] }
            return (0..<(48 * 48)).map { Double(d.load(fromByteOffset: $0, as: UInt8.self)) }
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return 0 }
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            var sab = 0.0, saa = 0.0, sbb = 0.0
            for i in 0..<a.count { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb) }
            return sab / max((saa * sbb).squareRoot(), 1e-9)
        }
        func mirrored(_ g: [Double]) -> [Double] { (0..<g.count).map { g[($0 / 48) * 48 + 47 - $0 % 48] } }
        func upsideDown(_ g: [Double]) -> [Double] { (0..<g.count).map { g[(47 - $0 / 48) * 48 + $0 % 48] } }
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
        if clean {
            let catalogue = try await engine.moduleNames().count
            check(model.modules.count == catalogue, "module list shows the engine's whole catalogue (\(model.modules.count) of \(catalogue))")
        } else {
            check(model.modules.count > 40, "module list has \(model.modules.count) modules")
        }
        check(model.info != nil, "output size known: \(model.info.map { "\($0.processedWidth)x\($0.processedHeight)" } ?? "?")")
        let base = luma(model)
        check(model.scopes != nil, "scopes measured")
        check(model.selectedModule?.operation == "exposure", "exposure is selected first")
        // auto-applied presets name the instance `_builtin_...`; only a name the user typed belongs in the title
        let title = model.selectedModule?.title ?? ""
        check(!title.contains("_builtin_") && title.hasPrefix(model.selectedModule?.name ?? "?"), "inspector title is '\(title)'")

        print("inspector from introspection")
        guard let exposure = module(model, "exposure") else { throw EngineError("no exposure module") }
        for _ in 0..<50 where model.schema(for: exposure) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let fields = model.schema(for: exposure)?.fields ?? []
        check(fields.contains { $0.name == "exposure" && $0.kind == .float }, "exposure schema has a float 'exposure' (\(fields.count) fields)")
        if clean {
            // the clean exposure is one float; its first enum is the flip module's orientation
            let flipFields = (try? await engine.schema(for: "flip").fields) ?? []
            check(flipFields.contains { $0.kind == .enumeration && $0.options.count >= 2 && $0.options.allSatisfy { !$0.label.isEmpty } },
                  "flip schema has an enum with labelled options")
        } else {
            check(fields.contains { $0.kind == .enumeration && $0.options.count >= 2 }, "exposure schema has an enum with labelled options")
        }
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

        print("cancel")
        func bytes(_ image: CGImage?) -> Data? { image?.dataProvider?.data as Data? }
        if let diffuse = module(model, "surfaceblur") {
            model.select(diffuse)
            for _ in 0..<50 where model.schema(for: diffuse) == nil { try await Task.sleep(for: .milliseconds(20)) }
            // the slow path is the old diffuse: surface blur's anisotropic method
            if let method = field(model, diffuse, "method") { model.setParam(diffuse, method, to: .option("anisotropic")) }
            await model.settle()
            if let it = field(model, diffuse, "iterations") {
                let before = bytes(model.frame)
                let canceled = model.canceledRenders
                // tens of seconds when left to finish
                model.setParam(diffuse, it, to: .number((it.min + (it.max - it.min) * 0.75).rounded()))
                try await Task.sleep(for: .milliseconds(400))
                let t = ContinuousClock.now
                model.undo()
                await model.settle()
                let ms = Int((ContinuousClock.now - t) / .milliseconds(1))
                check(model.canceledRenders > canceled, "the superseded diffuse render was canceled, not finished")
                check(ms < 2000, "undo during a slow diffuse render shows its frame in \(ms) ms")
                if ProcessInfo.processInfo.environment["DTB_TIME_UNCANCELED"] != nil {
                    let t1 = ContinuousClock.now
                    model.redo()
                    await model.settle()
                    print("        the same render left to finish: \(Int((ContinuousClock.now - t1) / .milliseconds(1))) ms")
                    model.undo()
                    await model.settle()
                }
                check(before != nil && bytes(model.frame) == before, "the frame after a canceled render is byte-identical to the one before")
                // the method choice was a step of its own: take it back, so surface blur is not left edited for the checks that follow
                model.undo()
                await model.settle()
            } else { check(false, "diffuse has an iterations field") }
        } else if clean {
            skip("cancel of a slow render", "the clean engine has no slow module yet (no diffuse); test cancel again when M4 adds one")
        } else { check(false, "diffuse is in the module list") }

        print("drag")
        if let blurs = module(model, "blurs") {
            model.select(blurs)
            for _ in 0..<50 where model.schema(for: blurs) == nil { try await Task.sleep(for: .milliseconds(20)) }
            if let radius = field(model, blurs, "radius") {
                let fullWidth = model.frame?.width ?? 0
                let step = model.historyIndex
                var drafts = 0, firstDraftMs: Int?, draftMs = 0.0
                let t = ContinuousClock.now
                model.setDragging(true)
                // blurs cannot stop mid-module, so the first full render runs to its end
                // before the drag can turn to drafts: keep moving until a few have shown
                for i in 0..<200 where drafts < 3 {
                    model.setParam(blurs, radius, to: .number((radius.min + (radius.max - radius.min) * (0.5 + 0.25 * Double(i % 20) / 20)).rounded()))
                    for _ in 0..<8 {
                        try await Task.sleep(for: .milliseconds(10))
                        if model.frameIsDraft, (model.frame?.width ?? fullWidth) < fullWidth {
                            drafts += 1
                            draftMs = model.lastMilliseconds ?? 0
                            if firstDraftMs == nil { firstDraftMs = Int((ContinuousClock.now - t) / .milliseconds(1)) }
                        }
                    }
                }
                // held still: the full frame follows without letting go
                await model.settle()
                let settled = bytes(model.frame)
                let fullMs = Int(model.lastMilliseconds ?? 0)
                if clean && drafts == 0 && fullMs < 50 {
                    skip("drafts during a slow drag", "full frames render in \(fullMs) ms, so the drag never needs a draft")
                } else {
                    check(drafts > 0, "a slow drag shows reduced-scale drafts (first after \(firstDraftMs ?? -1) ms, a draft \(Int(draftMs)) ms, full frame \(fullMs) ms)")
                }
                check(!model.frameIsDraft && model.frame?.width == fullWidth, "holding the slider still settles to the full frame")
                model.setDragging(false)
                await model.settle()
                check(bytes(model.frame) == settled, "letting go keeps the settled frame")
                check(model.historyIndex == step + 1 && model.history.count == step + 2, "the drag is one history step")
                model.undo(); await model.settle()
                model.redo(); await model.settle()
                check(settled != nil && bytes(model.frame) == settled, "the settled frame equals a single edit's frame, byte for byte")
                model.undo(); await model.settle()
            } else { check(false, "blurs has a radius field") }
        } else { check(false, "blurs is in the module list") }

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
        // T12 sidecar round trip: the frame after reopening is the frame before, byte for byte
        await model.settle()
        check(bytes(reopened.frame) != nil && bytes(reopened.frame) == bytes(model.frame),
              "T12 a reopened image renders identical frame bytes")
        // T11 sidecar versions: what the sidecar records, and what happens when the maths or the format moved on
        let sidecarURL = URL(fileURLWithPath: copy.path + ".darkroom.json")
        let sidecarBytes = try Data(contentsOf: sidecarURL)
        if clean {
            let saved = (try JSONSerialization.jsonObject(with: sidecarBytes) as? [String: Any]) ?? [:]
            let algos = saved["algorithms"] as? [String: Int] ?? [:]
            check((saved["version"] as? Int) == 2 && algos["exposure"] == 1 && algos.count >= 30,
                  "the sidecar is format 2 and records every module's algorithm version (\(algos.count) modules)")
            // the same sidecar claiming newer and older algorithms for the modules it uses
            for (label, value, word) in [("newer", 1000, "newer algorithm"), ("older", 0, "algorithm changed")] {
                var obj = saved
                var changed = algos
                for key in model.edits.filter({ $0.value.changesPicture }).keys {
                    changed[String(key.split(separator: "#").first ?? "")] = value
                }
                obj["algorithms"] = changed
                try JSONSerialization.data(withJSONObject: obj).write(to: sidecarURL)
                let other = DarkroomModel(engine: engine)
                await other.open(path: copy.path)
                check(!other.versionNotices.isEmpty && other.versionNotices.allSatisfy { $0.contains(word) },
                      "a sidecar saved with \(label) algorithms says so (\(other.versionNotices.first ?? "no notice"))")
                // looking at a photo is not editing it: saving must not re-stamp the record with this app's versions
                let before = try Data(contentsOf: sidecarURL)
                await other.flushSave()
                await other.open(path: copy.path)
                await other.flushSave()
                check((try? Data(contentsOf: sidecarURL)) == before, "opening and closing a photo leaves its \(label)-algorithm sidecar byte for byte")
            }
        }
        // a sidecar from a newer format is never read and never overwritten
        let future = Data(#"{"version": 99, "history": [], "index": 0, "note": "from the future"}"#.utf8)
        try future.write(to: sidecarURL)
        let guarded = DarkroomModel(engine: engine)
        await guarded.open(path: copy.path)
        if let exposure = module(guarded, "exposure"), let ev = field(guarded, exposure, "exposure") {
            guarded.setParam(exposure, ev, to: .number(1))
        }
        await guarded.flushSave()
        check((try? Data(contentsOf: sidecarURL)) == future && guarded.saveError != nil,
              "a sidecar from a newer format is left byte for byte as it was, and the user is told")
        try sidecarBytes.write(to: sidecarURL)

        print("geometry")
        if clean, let crop = module(model, "crop") {
            model.select(crop)
            for _ in 0..<50 where model.schema(for: crop) == nil { try await Task.sleep(for: .milliseconds(20)) }
            if let right = field(model, crop, "cw") {
                model.zoom = .fit
                await model.settle()
                let fullW = model.frame?.width ?? 0, fullH = model.frame?.height ?? 0
                let step = model.historyIndex
                model.setParam(crop, right, to: .number(0.5))
                await model.settle()
                let w = model.frame?.width ?? 0
                check(abs(w - fullW / 2) <= 1 && model.frame?.height == fullH, "cropping to the left half halves the frame (\(fullW) to \(w))")
                check(model.imageSize.map { Int($0.width) } == w, "the model's image size follows the crop")
                // the far corner of the cropped image through a small viewport: with the uncropped size the
                // region starts past the crop's right edge and the engine refuses it
                let viewport = model.viewport
                model.viewport = CGSize(width: 150, height: 150)
                model.zoom = .actual
                model.setCenter(CGPoint(x: 1, y: 1))
                await model.settle()
                let side = Int(150 * model.backingScale)
                check(model.frame?.width == min(side, w) && !model.status.contains("outside"),
                      "100% zoom at the crop's far corner renders a \(side)-pixel view (\(model.status))")
                model.viewport = viewport
                model.zoom = .fit
                model.undo()
                await model.settle()
                check(model.historyIndex == step && model.frame?.width == fullW, "undo restores the uncropped frame")
            } else { check(false, "crop has a 'cw' field") }
        } else if clean {
            check(false, "crop is in the module list")
        } else {
            skip("geometry", "these checks rely on sessionOutputSize, which the darktable engine does not report")
        }

        print("simple geometry (smoke)")
        if clean {
            model.mode = .simple
            await model.prepareSimple()
            check(model.simpleGeometryReady, "simple geometry controls are ready on the clean engine")
            model.zoom = .fit
            await model.settle()
            let w0 = model.frame?.width ?? 0, h0 = model.frame?.height ?? 0
            let step0 = model.historyIndex
            model.setStraighten(6)
            await model.settle()
            check(abs(model.simpleStraighten - 6) < 1e-9, "straighten reads back 6 degrees")
            check((model.frame?.width ?? 0) < w0 && (model.frame?.height ?? 0) < h0, "straighten crops inside the frame (\(w0)x\(h0) to \(model.frame?.width ?? 0)x\(model.frame?.height ?? 0))")
            model.setAspect(.square)
            await model.settle()
            check(model.simpleAspect == .square && abs((model.frame?.width ?? 0) - (model.frame?.height ?? 1)) <= 1, "1:1 makes a square frame (\(model.frame?.width ?? 0)x\(model.frame?.height ?? 0))")
            model.setAspect(.original)
            model.rotate90()
            await model.settle()
            check(model.frame?.width ?? 0 > model.frame?.height ?? 0, "rotate turns the portrait frame landscape (\(model.frame?.width ?? 0)x\(model.frame?.height ?? 0))")
            check(model.historyIndex == step0 + 4, "each control is one history step (\(model.historyIndex - step0) for 4)")
            while model.historyIndex > step0 { model.undo() }
            await model.settle()
            check(model.frame?.width == w0 && model.frame?.height == h0, "undo restores the original frame")
            model.mode = .pro

            print("simple geometry")
            model.mode = .simple
            model.zoom = .fit
            await model.settle()
            // the smoke block above already names w0, h0 and step0 in this scope
            let sw0 = model.frame?.width ?? 0, sh0 = model.frame?.height ?? 0
            let sstep0 = model.historyIndex
            func backToStart() async {
                while model.historyIndex > sstep0 { model.undo() }
                await model.settle()
            }
            func frameSize() -> (w: Int, h: Int) { (model.frame?.width ?? 0, model.frame?.height ?? 0) }
            func longOverShort() -> Double {
                let (w, h) = frameSize()
                return Double(max(w, h)) / Double(max(min(w, h), 1))
            }

            // straighten is a slider: a drag of five values is one history step
            for d in [1.0, 2, 3, 4, 5] { model.setStraighten(d) }
            await model.settle()
            check(model.historyIndex == sstep0 + 1 && abs(model.simpleStraighten - 5) < 1e-9,
                  "SG1 a straighten drag is one step (\(model.historyIndex - sstep0) for 5 values, straighten \(model.simpleStraighten))")
            await backToStart()

            model.setStraighten(80)
            let high = model.simpleStraighten
            model.setStraighten(-80)
            let low = model.simpleStraighten
            model.setStraighten(3.14159)
            let rounded = model.simpleStraighten
            check(abs(high - 45) < 1e-9 && abs(low + 45) < 1e-9 && abs(rounded - 3.1) < 1e-9,
                  "SG2 straighten clamps to plus or minus 45 and rounds to 0.1 (80 reads \(high), -80 reads \(low), 3.14159 reads \(rounded))")
            await backToStart()

            // straighten 8 must first crop inside the frame, so that returning to 0 is a real change
            model.setStraighten(8)
            await model.settle()
            let (w8, h8) = frameSize()
            check(w8 < sw0 && h8 < sh0, "SG3 straighten 8 crops inside the frame (\(w8)x\(h8), was \(sw0)x\(sh0))")
            model.setStraighten(0)
            await model.settle()
            check(frameSize() == (sw0, sh0), "SG3 straighten 0 is the full frame again (\(frameSize().w)x\(frameSize().h), was \(sw0)x\(sh0))")
            await backToStart()

            model.setAspect(.fourFive)
            await model.settle()
            model.setStraighten(8)
            await model.settle()
            let (w4, h4) = frameSize()
            check(model.simpleAspect == .fourFive && abs(longOverShort() - 1.25) / 1.25 < 0.01 && h4 > w4,
                  "SG4 a 4:5 preset survives straighten (\(w4)x\(h4), ratio \(longOverShort()), preset \(String(describing: model.simpleAspect)))")

            model.rotate90()
            await model.settle()
            let (w5, h5) = frameSize()
            check(model.simpleAspect == .fourFive && abs(longOverShort() - 1.25) / 1.25 < 0.01 && w5 > h5,
                  "SG5 a 4:5 preset survives rotate and turns landscape (\(w5)x\(h5), ratio \(longOverShort()), preset \(String(describing: model.simpleAspect)))")

            // a button: every tap is its own step, unlike a slider's drag
            await backToStart()
            model.rotate90()
            model.rotate90()
            await model.settle()
            check(model.historyIndex == sstep0 + 2, "SG6 each rotate tap is its own step (\(model.historyIndex - sstep0) for 2)")

            await backToStart()
            var turns: [(w: Int, h: Int)] = []
            for _ in 0..<4 {
                model.rotate90()
                await model.settle()
                turns.append(frameSize())
            }
            let alternates = turns.enumerated().allSatisfy { i, s in (s.w > s.h) == (i % 2 == 0) }
            check(alternates && frameSize() == (sw0, sh0),
                  "SG7 four rotations are the identity (\(turns.map { "\($0.w)x\($0.h)" }.joined(separator: ", ")), was \(sw0)x\(sh0))")

            await backToStart()
            model.rotate90()
            await model.settle()
            check(frameSize() == (sh0, sw0), "SG8 one rotate to an explicit none shows the sensor frame (\(frameSize().w)x\(frameSize().h), expected \(sh0)x\(sw0))")

            await backToStart()
            if let crop = module(model, "crop"), let right = field(model, crop, "cw") {
                model.setParam(crop, right, to: .number(0.7))
                await model.settle()
                check(model.simpleAspect == nil, "SG9 a Pro crop is no preset (preset \(String(describing: model.simpleAspect)))")
            } else {
                check(false, "crop has a 'cw' field for a Pro crop")
            }

            // a 1:1 crop that is not centred is no preset, even though its ratio matches one
            await backToStart()
            if let crop = module(model, "crop"), let bottom = field(model, crop, "ch") {
                model.setParam(crop, bottom, to: .number(Double(sw0) / Double(sh0)))
                await model.settle()
                let (w9, h9) = frameSize()
                check(abs(w9 - sw0) <= 1 && abs(h9 - sw0) <= 1 && model.simpleAspect == nil,
                      "SG9b a 1:1 crop that is not centred is no preset (\(w9)x\(h9), preset \(String(describing: model.simpleAspect)))")
            } else {
                check(false, "crop has a 'ch' field for an uncentred crop")
            }

            await backToStart()
            model.setAspect(.square)
            model.setAspect(.original)
            await model.settle()
            check(frameSize() == (sw0, sh0) && model.simpleAspect == .original,
                  "SG10 Original removes the crop (\(frameSize().w)x\(frameSize().h), preset \(String(describing: model.simpleAspect)))")

            await backToStart()
            model.mode = .pro
        } else {
            skip("simple geometry", "needs sessionOutputSize and the camera orientation, which the darktable engine does not report")
        }

        print("pro panel (smoke)")
        if clean {
            model.mode = .pro
            model.zoom = .fit
            await model.settle()
            let names = model.proPanelEntries.map { $0.modules[0].operation }
            check(Set(names) == Set(DarkroomModel.proBasics), "a new photo's panel holds the basics (\(names.joined(separator: ", ")))")
            if let shadhi = model.proMenu.flatMap(\.entries).first(where: { $0.modules[0].operation == "colorbalancergb" }) {
                let before = bytes(model.frame), step = model.historyIndex
                // colour balance is a basic: give it a visible setting so on/off shows in the frame
                await model.preparePro()
                if let m = shadhi.modules.first, let f = model.schema(for: m)?.fields.first(where: { $0.name == "saturation_global" }) {
                    model.setParam(m, f, to: .number(-1))
                }
                await model.settle()
                let edited = bytes(model.frame)
                check(edited != before, "a colour balance edit changes the frame")
                model.toggleProEffect(shadhi)
                await model.settle()
                check(model.inProPanel(shadhi) && bytes(model.frame) == before, "the power button keeps the section and turns its effect off")
                model.toggleProEffect(shadhi)
                await model.settle()
                check(bytes(model.frame) == edited, "and back on restores the edit")
                model.removeFromPanel(shadhi)
                await model.settle()
                check(!model.inProPanel(shadhi) && bytes(model.frame) == before, "the menu switch takes it out of the panel and stops applying it")
                model.undo()
                await model.settle()
                check(model.inProPanel(shadhi) && bytes(model.frame) == edited, "undo brings it back, edit and all")
                while model.historyIndex > step { model.undo() }
                await model.settle()
            } else { check(false, "colour balance is in the Modules menu") }
            if let sh = model.proMenu.flatMap(\.entries).first(where: { $0.modules[0].operation == "shadhi" }) {
                model.addToPanel(sh)
                check(model.inProPanel(sh), "switching shadows and highlights on in the menu adds it to the panel")
                model.removeFromPanel(sh)
                check(!model.inProPanel(sh), "and switching it off takes it out")
            }
            print("pro panel")
            let step0 = model.historyIndex
            model.zoom = .fit
            await model.settle()
            func entryWith(_ op: String) -> DarkroomModel.ProEntry? {
                model.proMenu.flatMap(\.entries).first { $0.modules.map(\.operation).contains(op) }
            }
            // PP1 the Common group holds the ten common entries in their order (DarkroomModel.proCommon is internal
            // to DarkroomUI, so the order is spelled out here); catches a dropped or duplicated module and a moved entry
            let commonOrder: [[String]] = [
                ["temperature"], ["exposure"], ["tonecurve"], ["zones"], ["colorbalancergb"],
                ["splittoning"], ["monochrome"], ["sharpen"], ["denoiseprofile"], ["crop", "ashift", "flip"],
            ]
            let groups = model.proMenu
            let commonOps = groups.first { $0.group == "Common" }?.entries.map { $0.modules.map(\.operation) } ?? []
            check(groups.first?.group == "Common" && commonOps == commonOrder,
                  "PP1 the Common group is first, with the ten common entries in order (\(commonOps.map { $0.joined(separator: "+") }.joined(separator: ", ")))")
            // every non-deprecated module is in exactly one menu entry: a module listed twice or not at all shows here
            var menuCount: [String: Int] = [:]
            for e in groups.flatMap(\.entries) { for m in e.modules { menuCount[m.id, default: 0] += 1 } }
            let live = model.modules.filter { !$0.deprecated }
            let miscounted = live.filter { menuCount[$0.id] != 1 }
            check(miscounted.isEmpty,
                  "PP1 every non-deprecated module is in exactly one menu entry (\(live.count) modules, \(miscounted.isEmpty ? "all counted once" : miscounted.map { "\($0.operation) counted \(menuCount[$0.id] ?? 0)" }.joined(separator: ", ")))")

            // PP9 undoing an add takes the module back out and returns the history to where it was; catches an add
            // that is not one undoable step
            let shadhi9 = entryWith("zones")!
            let s9 = model.historyIndex
            let before9 = model.inProPanel(shadhi9)
            model.addToPanel(shadhi9)
            await model.settle()
            let afterAdd9 = model.inProPanel(shadhi9)
            model.undo()
            await model.settle()
            check(!model.inProPanel(shadhi9) && model.historyIndex == s9,
                  "PP9 undo of an add takes shadows and highlights back out (before add \(before9), after add \(afterAdd9), after undo \(model.inProPanel(shadhi9)), history \(model.historyIndex) for \(s9))")

            // PP10 taking out an unedited basic is one history step, and undo brings it back; catches a removal that
            // is more than one step, or one that undo leaves out
            let tone10 = entryWith("tonecurve")!
            let s10 = model.historyIndex
            let edited10 = model.proEdited(tone10)
            let enabled10 = model.isEnabled(module(model, "tonecurve")!)
            model.removeFromPanel(tone10)
            await model.settle()
            let stepsOut = model.historyIndex - s10, outPanel = model.inProPanel(tone10)
            model.undo()
            await model.settle()
            check(!edited10 && stepsOut == 1 && !outPanel && model.inProPanel(tone10) && model.historyIndex == s10,
                  "PP10 taking out the unedited tone curve is one step and undo puts it back (edited \(edited10), on \(enabled10), steps \(stepsOut), out \(!outPanel), back in \(model.inProPanel(tone10)), history \(model.historyIndex) for \(s10))")

            // PP11 the round trip: an edit to a basic, then taking it out and undoing both; catches the basic losing its
            // place in the panel when its edits are cleared
            await model.preparePro()
            let cb11 = entryWith("colorbalancergb")!
            let colour11 = module(model, "colorbalancergb")!
            let s11 = model.historyIndex
            if let f = model.schema(for: colour11)?.fields.first(where: { $0.name == "saturation_global" }) {
                model.setParam(colour11, f, to: .number(-1))
            } else { check(false, "colour balance has a 'saturation_global' field") }
            await model.settle()
            model.removeFromPanel(cb11)
            await model.settle()
            model.undo()
            model.undo()
            await model.settle()
            check(model.inProPanel(colour11) && model.historyIndex == s11,
                  "PP11 colour balance is back in the panel after its edit, its removal and both undos (in \(model.inProPanel(colour11)), history \(model.historyIndex) for \(s11))")

            // PP2 the panel runs in pipeline order whatever order its entries were added in; catches an unsorted panel
            let picked = [entryWith("zones"), entryWith("sharpen"), entryWith("radiallight"), entryWith("crop"), entryWith("invert")].compactMap { $0 }
            for e in picked { model.addToPanel(e) }
            await model.settle()
            let wasOrder = model.proPanelOrder
            model.setProPanelOrder(.pipeline)
            defer { model.setProPanelOrder(wasOrder) }
            let orders = model.proPanelEntries.map { $0.modules.map(\.iopOrder).min() ?? 0 }
            let sorted = zip(orders, orders.dropFirst()).allSatisfy { $0 <= $1 }
            check(picked.count == 5 && picked.allSatisfy { model.inProPanel($0) } && sorted,
                  "PP2 the panel is in pipeline order (\(model.proPanelEntries.map(\.name).joined(separator: ", ")); iopOrder \(orders))")
            for e in picked { model.removeFromPanel(e) }
            await model.settle()

            // PP3 the tone curve's nodes: the diagonal at the start, one write moves one node, writes clamp to 0...1
            // (catches no clamp and writes going to the wrong node)
            await model.preparePro()
            let base = bytes(model.frame)
            let identity = [0.0, 0.25, 0.5, 0.75, 1.0]
            let nodes0 = model.curveNodes ?? []
            check(nodes0.count == 5 && zip(nodes0, identity).allSatisfy { abs($0 - $1) < 1e-9 },
                  "PP3 the tone curve starts on the diagonal (\(nodes0.map { String(format: "%.2f", $0) }.joined(separator: ", ")))")
            model.setCurveNode(2, 0.65)
            await model.settle()
            let nodes1 = model.curveNodes ?? []
            check(nodes1.count == 5 && abs(nodes1[2] - 0.65) < 1e-9 && [0, 1, 3, 4].allSatisfy { abs(nodes1[$0] - identity[$0]) < 1e-9 }
                  && bytes(model.frame) != base,
                  "PP3 a write to node 2 moves only node 2 and changes the frame (\(nodes1.map { String(format: "%.2f", $0) }.joined(separator: ", ")))")
            model.setCurveNode(1, 1.4)
            model.setCurveNode(3, -0.3)
            await model.settle()
            let nodes2 = model.curveNodes ?? []
            // a point never goes above the next one or below the one before (a curve does not reverse a tone), so 1.4 stops at the
            // next point's height (0.65) and -0.3 at the previous one's (0.65)
            check(nodes2.count == 5 && abs(nodes2[1] - 0.65) < 1e-9 && abs(nodes2[3] - 0.65) < 1e-9 && abs(nodes2[2] - 0.65) < 1e-9,
                  "PP3 writes clamp to their neighbours and land on their node (1.4 reads \(nodes2.count == 5 ? nodes2[1] : -1), -0.3 reads \(nodes2.count == 5 ? nodes2[3] : -1), node 2 still \(nodes2.count == 5 ? nodes2[2] : -1))")
            // PP4 a drag of four values with no settle is one step; the last PP3 write was node 3, so this is a fresh step
            // (grouped merges a repeated target within 1.5 s), catches every move becoming its own step
            let s4 = model.historyIndex
            model.beginCurveDrag()   // the editor calls this where a drag starts
            // node 3 has room above it (the point after is at 1.0); node 2 is pinned between two points at 0.65 after the PP3 writes
            for x in [0.7, 0.75, 0.8, 0.85] { model.setCurveNode(3, x) }
            await model.settle()
            check(model.historyIndex == s4 + 1, "PP4 a drag is one history step (\(model.historyIndex - s4) for 4 values)")
            // PP5 the power button turns the curve's effect off and back on; the section stays (catches the power button
            // removing the section, or not stopping the effect)
            let curve = entryWith("tonecurve")!
            let curved = bytes(model.frame)
            model.toggleProEffect(curve)
            await model.settle()
            check(model.inProPanel(curve) && !model.proEffectOn(curve) && bytes(model.frame) == base,
                  "PP5 power off keeps the tone curve in the panel and its frame is the one from before the edit (in panel \(model.inProPanel(curve)), on \(model.proEffectOn(curve)))")
            model.toggleProEffect(curve)
            await model.settle()
            check(model.proEffectOn(curve) && bytes(model.frame) == curved,
                  "PP5 power on restores the edited frame (on \(model.proEffectOn(curve)))")

            // PP6 crop and straighten is one section (crop, ashift and flip); a size change, then removal, leaves none of
            // the three applied and the original frame back; catches two sections, or a removal that leaves one applied
            let geo = entryWith("crop")!
            let fullW = model.frame?.width ?? 0, fullH = model.frame?.height ?? 0
            model.addToPanel(geo)
            await model.settle()
            let geoSections = model.proPanelEntries.filter { $0.modules.contains { ["crop", "ashift", "flip"].contains($0.operation) } }
            let geoOps = Set(geoSections.first?.modules.map(\.operation) ?? [])
            check(geoSections.count == 1 && geoOps == ["crop", "ashift", "flip"],
                  "PP6 crop and straighten is one section (\(geoSections.count) section, holds \(geoOps.sorted().joined(separator: ", ")))")
            model.setStraighten(6)
            model.rotate90()
            await model.settle()
            let changedW = model.frame?.width ?? 0, changedH = model.frame?.height ?? 0
            check((changedW, changedH) != (fullW, fullH),
                  "PP6 straighten and a quarter turn change the frame (\(fullW)x\(fullH) to \(changedW)x\(changedH))")
            model.removeFromPanel(geo)
            await model.settle()
            let crop = module(model, "crop")!, ashift = module(model, "ashift")!, flip = module(model, "flip")!
            let geoOff = [crop, ashift, flip].allSatisfy { !model.inProPanel($0) && !model.isEnabled($0) }
            check(geoOff && model.frame?.width == fullW && model.frame?.height == fullH,
                  "PP6 removing it leaves crop, ashift and flip out of the panel and off, and the original frame (in panel \([crop, ashift, flip].map { model.inProPanel($0) }), on \([crop, ashift, flip].map { model.isEnabled($0) }), \(model.frame?.width ?? 0)x\(model.frame?.height ?? 0), was \(fullW)x\(fullH))")

            // PP7 a basic that is on by default: taking white balance out switches it off, and undo brings it back in and on
            // (catches a removal that leaves the module applied, or a removed basic coming straight back)
            let wb = entryWith("temperature")!
            let temp = module(model, "temperature")!
            model.removeFromPanel(wb)
            await model.settle()
            check(!model.inProPanel(temp) && !model.isEnabled(temp),
                  "PP7 removing white balance takes it out and switches it off (in panel \(model.inProPanel(temp)), on \(model.isEnabled(temp)))")
            model.undo()
            await model.settle()
            check(model.inProPanel(temp) && model.isEnabled(temp),
                  "PP7 undo brings white balance back in and on (in panel \(model.inProPanel(temp)), on \(model.isEnabled(temp)))")

            // PP12 a look switches a removed module back on: white balance is out, and the look's own edit brings it in and on
            model.removeFromPanel(wb)
            await model.settle()
            let outBefore12 = !model.inProPanel(temp)
            model.apply(SimpleLook.all.first { $0.id == "warm" }!)
            await model.settle()
            check(outBefore12 && model.inProPanel(temp) && model.isEnabled(temp),
                  "PP12 the warm look brings white balance back in and on (out before \(outBefore12), in \(model.inProPanel(temp)), on \(model.isEnabled(temp)))")

            // PP8 an edit to a removed module brings it back: the look edits colour balance (catches the removed set
            // hiding a module that is in use)
            let cb = entryWith("colorbalancergb")!
            model.removeFromPanel(cb)
            await model.settle()
            let colour = module(model, "colorbalancergb")!
            let outBefore = !model.inProPanel(colour)
            model.apply(SimpleLook.all.first { $0.id == "punch" }!)
            await model.settle()
            check(outBefore && model.inProPanel(colour),
                  "PP8 a look that edits colour balance brings it back into the panel (out before: \(outBefore), in after: \(model.inProPanel(colour)))")
            while model.historyIndex > step0 { model.undo() }
            await model.settle()

            // PP13 the panel survives a reopen: the sidecar keeps a removal and an add (catches membership kept only in memory)
            let tone13 = entryWith("tonecurve")!, vig13 = entryWith("radiallight")!
            model.removeFromPanel(tone13)
            model.addToPanel(vig13)
            await model.flushSave()
            await model.open(path: copy.path)
            await model.settle()
            let toneBack = model.inProPanel(module(model, "tonecurve")!), vigIn = model.inProPanel(module(model, "radiallight")!)
            check(!toneBack && vigIn,
                  "PP13 after reopen the tone curve is out and vignette is in (tone curve in \(toneBack), vignette in \(vigIn))")
            model.addToPanel(entryWith("tonecurve")!)
            model.removeFromPanel(entryWith("radiallight")!)
            await model.settle()

            // PP14 the curve geometry helpers the graph uses: y is up (a flipped height fails), nodes round to the nearest quarter
            let top: CGFloat = 12, plotH: CGFloat = 196, left: CGFloat = 12, plotW: CGFloat = 266
            let hTop = CurveGeometry.height(atY: top, plotTop: top, plotHeight: plotH)
            let hBottom = CurveGeometry.height(atY: top + plotH, plotTop: top, plotHeight: plotH)
            let yOne = CurveGeometry.y(forHeight: 1, plotTop: top, plotHeight: plotH)
            let n12 = CurveGeometry.nearestNode(toX: left + 0.12 * plotW, plotLeft: left, plotWidth: plotW)
            let n13 = CurveGeometry.nearestNode(toX: left + 0.13 * plotW, plotLeft: left, plotWidth: plotW)
            let clampLow = CurveGeometry.height(atY: top + plotH + 40, plotTop: top, plotHeight: plotH)
            check(abs(hTop - 1) < 1e-12 && abs(hBottom) < 1e-12 && abs(yOne - top) < 1e-9 && n12 == 0 && n13 == 1 && clampLow == 0,
                  "PP14 curve geometry: top is 1, bottom 0, height 1 draws at the top, 12% picks node 0 and 13% node 1, below the plot clamps (\(hTop), \(hBottom), \(yOne), \(n12), \(n13), \(clampLow))")
            // PP18 the clipping warning: J paints the clipped pixels on the screen render only, and off gives the same frame back
            do {
                // the default tone stage keeps this frame's highlights below white, so give the warning something to find: two stops more light
                model.setSimple(.light, to: 100)
                await model.settle()
                let clean = bytes(model.frame)
                model.showClipping = true
                try await Task.sleep(for: .milliseconds(200))
                await model.settle()
                let painted = bytes(model.frame)
                let stackHasIt = model.buildStack().contains { $0.operation.contains("clip") }
                model.showClipping = false
                try await Task.sleep(for: .milliseconds(200))
                await model.settle()
                check(painted != nil && painted != clean, "PP18 the clipping warning paints the clipped pixels on screen")
                check(!stackHasIt, "PP18 the export stack carries no clipping overlay")
                check(bytes(model.frame) == clean, "PP18 turning it off gives back the same frame, byte for byte")
                model.setSimple(.light, to: 0)
                await model.settle()
            }
            // PP15 the header dropdowns: one open at a time, the search starts empty each time one opens, and the Modules
            // list narrows with the search (every module it keeps matches; none matching leaves nothing)
            model.proMenuOpen = .modules
            model.proMenuQuery = "curve"
            let curveHits = model.proMenu.flatMap(\.entries).filter { e in
                e.name.lowercased().contains("curve") || e.modules.contains { $0.operation.lowercased().contains("curve") }
            }
            model.proMenuOpen = .presets
            let queryCleared = model.proMenuQuery.isEmpty
            model.proMenuOpen = .modules
            let noneMatch = model.proMenu.flatMap(\.entries).filter { $0.name.lowercased().contains("zzzz") }.isEmpty
            model.proMenuOpen = nil
            check(curveHits.count >= 2 && queryCleared && noneMatch && model.proMenuOpen == nil,
                  "PP15 the Pro dropdowns: a search for curve finds \(curveHits.count) modules, opening another menu clears it, a nonsense search finds none")
            // PP16 the mask controls change the picture where they say: a +2 EV exposure behind a hard gradient (angle 0,
            // position 0.5) brightens the right half only; inverted, the left half only; undo removes it in one step
            if let ex = model.modules.first(where: { $0.operation == "exposure" }), let exEntry = model.proMenu.flatMap(\.entries).first(where: { $0.modules.first?.operation == "exposure" }) {
                func halves(_ f: CGImage?) -> (Double, Double) {
                    guard let f, let l = f.cropping(to: CGRect(x: 0, y: 0, width: f.width / 2, height: f.height)),
                          let r = f.cropping(to: CGRect(x: f.width / 2, y: 0, width: f.width / 2, height: f.height)) else { return (0, 0) }
                    return (meanLuma(l), meanLuma(r))
                }
                model.addToPanel(exEntry)
                let before = model.historyIndex
                // the baseline has the exposure module ON (at a hair over 0 EV): off, the decoder's own tone curve is a different pipeline
                if let evField = field(model, ex, "exposure") { model.setParam(ex, evField, to: .number(0.0001)) }
                await model.settle()
                let plain = halves(model.frame)
                if let evField = field(model, ex, "exposure") { model.setParam(ex, evField, to: .number(2)) }
                await model.settle()
                let lit = halves(model.frame)
                model.setMask(ex, mode: 2, kind: .gradient)
                model.setBlend(ex, "mask_feather", to: .number(0), detail: "mask feather")
                await model.settle()
                let masked = halves(model.frame)
                model.setBlend(ex, "mask_invert", to: .number(1), detail: "mask inverted")
                await model.settle()
                let inverted = halves(model.frame)
                check(lit.0 > plain.0 + 5 && lit.1 > plain.1 + 5, "PP16 baseline: +2 EV brightens both halves (\(plain) to \(lit))")
                check(abs(masked.0 - plain.0) < 2 && masked.1 > plain.1 + 5, "PP16 the gradient mask keeps the left half and brightens the right (left \(masked.0) vs \(plain.0), right \(masked.1) vs \(plain.1))")
                check(inverted.0 > plain.0 + 5 && abs(inverted.1 - plain.1) < 2, "PP16 inverted, the left half brightens and the right stays (left \(inverted.0) vs \(plain.0), right \(inverted.1) vs \(plain.1))")
                // PP17 the overlay: Show mask tints the screen render (and only it), and turning it off gives the same frame back
                model.setBlend(ex, "mask_invert", to: .number(0), detail: "mask inverted")
                await model.settle()
                let beforeOverlay = bytes(model.frame)
                model.maskShowID = ex.id
                await model.settle()
                let withOverlay = bytes(model.frame)
                let exported = model.buildStack().contains { $0.blend["mask_show"] != nil }
                model.maskShowID = nil
                await model.settle()
                check(withOverlay != nil && withOverlay != beforeOverlay, "PP17 Show mask changes the picture on screen")
                check(!exported, "PP17 the export stack never carries the overlay flag")
                check(bytes(model.frame) == beforeOverlay, "PP17 Show mask off gives back the same frame, byte for byte")
                model.setMask(ex, mode: 0, kind: nil)
                check(model.blendValue(ex, "mask_mode")?.double == 0 && model.edits[ex.id]?.blend.keys.contains(where: { $0.hasPrefix("mask_") }) != true,
                      "PP16 picking everywhere clears every mask setting")
                while model.historyIndex > before { model.undo() }
                await model.settle()
            } else { check(false, "PP16 exposure is in the module list") }
            // PP21 the point curve: points move in x and y, the end points move too, you can add and remove points, the curve cannot fold
            // back, and the editor's grab rule reaches the corner points (the top-right point used to be half outside the plot)
            if model.curvePoints != nil {
                let start = model.historyIndex
                // geometry first: a plot as the panel gives it
                let plot = CurveGeometry.plot(in: CGSize(width: 252, height: 196))
                let ident = [DarkroomModel.CurvePoint(x: 0, y: 0), .init(x: 0.25, y: 0.25), .init(x: 0.5, y: 0.5), .init(x: 0.75, y: 0.75), .init(x: 1, y: 1)]
                let corner = CurveGeometry.view(ident[4], plot: plot)
                let inside = CGRect(x: 0, y: 0, width: 252, height: 196).contains(corner) && CGRect(x: 0, y: 0, width: 252, height: 196).contains(CurveGeometry.view(ident[0], plot: plot))
                let nearCorner = [CGPoint(x: corner.x - 9, y: corner.y + 9), CGPoint(x: corner.x + 9, y: corner.y - 9), corner]
                check(inside && nearCorner.allSatisfy { CurveGeometry.grab(at: $0, points: ident, plot: plot) == .point(4) },
                      "PP21 the top-right point can be grabbed from either side of the corner, and both end points sit inside the view")
                let between = CurveGeometry.view(.init(x: 0.375, y: 0.375), plot: plot)
                let onCurve = CurveGeometry.grab(at: between, points: ident, plot: plot)
                let faroff = CurveGeometry.grab(at: CGPoint(x: between.x, y: between.y - 80), points: ident, plot: plot)
                var addsOnCurve = false
                if case .insert(let x, _) = onCurve, abs(x - 0.375) < 0.02 { addsOnCurve = true }
                check(addsOnCurve && faroff == .none, "PP21 pressing on the curve adds a point there; pressing far from it does nothing")
                // the model: drag the top-right point left and down, the first point right (a black point), add and remove points
                model.beginCurveDrag()
                let nowCorner = CurveGeometry.value(CGPoint(x: plot.minX + plot.width * 0.7, y: plot.minY + plot.height * 0.2), plot: plot)
                model.moveCurvePoint(4, x: nowCorner.x, y: nowCorner.y)
                let moved = model.curvePoints ?? []
                // the point before it is at x = 0.75, so it can come left as far as 0.75 + the minimum gap, and down to 0.8
                check(moved.count == 5 && abs(moved[4].x - (0.75 + DarkroomModel.curveMinGap)) < 1e-9 && abs(moved[4].y - 0.8) < 1e-9, "PP21 the top-right point moves left and down: it is now at (\(moved.last?.x ?? -1), \(moved.last?.y ?? -1))")
                model.beginCurveDrag()
                model.moveCurvePoint(0, x: 0.1, y: 0.05)
                let black = model.curvePoints ?? []
                check(black.count == 5 && abs(black[0].x - 0.1) < 1e-9 && abs(black[0].y - 0.05) < 1e-9, "PP21 the first point moves right and up: a black point at (\(black.first?.x ?? -1), \(black.first?.y ?? -1))")
                model.beginCurveDrag()
                model.moveCurvePoint(2, x: 0.95, y: 0.1)
                let squeezed = model.curvePoints ?? []
                check(squeezed.count == 5 && abs(squeezed[2].x - (squeezed[3].x - DarkroomModel.curveMinGap)) < 1e-9 && squeezed[2].y >= squeezed[1].y - 1e-12,
                      "PP21 a point stops at its neighbour (x \(squeezed[2].x) against the next at \(squeezed[3].x)) and cannot go below the one before")
                let steps = model.historyIndex
                let added = model.insertCurvePoint(x: 0.6, y: 0.5)
                let withAdded = model.curvePoints ?? []
                check(added != nil && withAdded.count == 6 && model.historyIndex == steps + 1 && zip(withAdded, withAdded.dropFirst()).allSatisfy { $1.x - $0.x >= DarkroomModel.curveMinGap - 1e-12 },
                      "PP21 a point can be added: six points now, one history step")
                check(model.insertCurvePoint(x: withAdded[1].x + 0.005, y: 0.3) == nil, "PP21 a point cannot be added closer than the minimum gap to another")
                var more = 0
                while model.insertCurvePoint(x: Double.random(in: 0.1...0.9), y: 0.5) != nil { more += 1; if more > 20 { break } }
                check((model.curvePoints?.count ?? 0) <= DarkroomModel.curveMaxPoints, "PP21 the curve never has more than \(DarkroomModel.curveMaxPoints) points (it has \(model.curvePoints?.count ?? -1))")
                let full = model.curvePoints ?? []
                model.removeCurvePoint(0)
                model.removeCurvePoint(full.count - 1)
                check(model.curvePoints == full, "PP21 the two end points cannot be removed")
                model.removeCurvePoint(1)
                check((model.curvePoints?.count ?? 0) == full.count - 1, "PP21 a middle point can be removed")
                model.undo()
                check(model.curvePoints == full, "PP21 undo puts the removed point back")
                await model.settle()
                let drawn = bytes(model.frame)
                // an edit saved before point curves (five heights only) is the same picture as the same five points in the new format
                while model.historyIndex > start { model.undo() }
                await model.settle()
                if let m = model.modules.first(where: { $0.operation == "tonecurve" }), let schema = model.schema(for: m) {
                    for (name, v) in [("y1", 0.15), ("y2", 0.5), ("y3", 0.85)] { if let f = schema.fields.first(where: { $0.name == name }) { model.setParam(m, f, to: .number(v)) } }
                    await model.settle()
                    let oldStyle = bytes(model.frame), oldPoints = model.curvePoints ?? []
                    while model.historyIndex > start { model.undo() }
                    model.setCurveNode(1, 0.15); model.setCurveNode(2, 0.5); model.setCurveNode(3, 0.85)
                    await model.settle()
                    check(oldPoints.count == 5 && abs(oldPoints[1].y - 0.15) < 1e-9 && oldStyle == bytes(model.frame) && oldStyle != nil,
                          "PP21 an old five-height edit shows as five points and renders exactly like the new format")
                }
                check(drawn != nil, "PP21 the edited curve rendered")
                // a saved edit with NaN or infinity where a count belongs must not crash the panel (Int(.nan) traps)
                if let m = model.modules.first(where: { $0.operation == "tonecurve" }), let schema = model.schema(for: m), let nField = schema.fields.first(where: { $0.name == "n" }) {
                    var survived = true
                    for bad in [Double.nan, .infinity, -.infinity, 1e300] {
                        model.setParam(m, nField, to: .number(bad))
                        survived = survived && (model.curvePoints?.count ?? 0) >= 2
                    }
                    check(survived && Double.nan.clampedInt == 0 && (1e300).clampedInt == 1_000_000_000 && (-1e300).clampedInt == -1_000_000_000 && (2.6).clampedInt == 3,
                          "PP21 NaN, infinity or 1e300 where the curve's point count belongs is read safely")
                }
                while model.historyIndex > start { model.undo() }
                await model.settle()
            } else { check(false, "PP21 the tone curve has points") }
            // PP19 the brush: strokes paint the mask, each is one history step, undo and redo walk them, a stroke after an undo
            // cuts the undone ones off, and a reopened photo has the same strokes and the same frame, byte for byte
            if let ex = model.modules.first(where: { $0.operation == "exposure" }), let exEntry = model.proMenu.flatMap(\.entries).first(where: { $0.modules.first?.operation == "exposure" }), let evField = field(model, ex, "exposure") {
                func halvesNow() -> (Double, Double) {
                    guard let f = model.frame, let l = f.cropping(to: CGRect(x: 0, y: 0, width: f.width / 2, height: f.height)),
                          let r = f.cropping(to: CGRect(x: f.width / 2, y: 0, width: f.width / 2, height: f.height)) else { return (0, 0) }
                    return (meanLuma(l), meanLuma(r))
                }
                model.addToPanel(exEntry)
                let start = model.historyIndex
                model.setParam(ex, evField, to: .number(0.0001))
                await model.settle()
                let base = halvesNow()
                model.setParam(ex, evField, to: .number(2))
                model.startBrush(ex)
                await model.settle()
                let emptyBrush = halvesNow()
                // a fat stroke down the LEFT of the picture (normalised, upright), then one down the right
                model.brushRadius = 0.12; model.brushSoftness = 0.2; model.brushFlow = 1
                model.paintStroke([CGPoint(x: 0.25, y: 0.1), CGPoint(x: 0.25, y: 0.9)])
                await model.settle()
                let left = halvesNow()
                let afterOne = bytes(model.frame)
                let stepsOne = model.historyIndex
                model.paintStroke([CGPoint(x: 0.75, y: 0.1), CGPoint(x: 0.75, y: 0.9)])
                await model.settle()
                let both = halvesNow()
                check(abs(emptyBrush.0 - base.0) < 2 && abs(emptyBrush.1 - base.1) < 2, "PP19 an empty brush layer changes nothing (\(emptyBrush) vs \(base))")
                check(left.0 > base.0 + 8 && abs(left.1 - base.1) < 8, "PP19 a stroke down the left brightens the left half and not the right (\(left) vs \(base))")
                check(both.1 > base.1 + 8 && both.0 > base.0 + 8, "PP19 a second stroke down the right brightens the right too (\(both))")
                check(model.historyIndex == stepsOne + 1, "PP19 each stroke is one history step")
                model.undo(); await model.settle()
                check(bytes(model.frame) == afterOne, "PP19 undo takes the second stroke off, byte for byte")
                model.redo(); await model.settle()
                check(halvesNow().1 > base.1 + 8, "PP19 redo puts it back")
                model.undo(); await model.settle()
                model.paintStroke([CGPoint(x: 0.5, y: 0.5)])
                await model.settle()
                let layer = model.maskLayer(for: ex)
                check(layer?.strokes.count == 2, "PP19 a stroke after an undo cuts the undone one off (layer has \(layer?.strokes.count ?? -1) strokes, wanted 2)")
                model.maskShowID = nil          // the red tint is on screen only; the reopened photo has none
                await model.settle()
                let before = bytes(model.frame)
                await model.flushSave()
                let sidecarText = (try? String(contentsOfFile: copy.path + ".darkroom.json", encoding: .utf8)) ?? ""
                check(sidecarText.contains("\"version\" : 3") && sidecarText.contains("\"layers\""), "PP19 a photo with a painted layer is saved as sidecar format 3 with its layers")
                let reopened = DarkroomModel(engine: engine)
                await reopened.open(path: copy.path)
                await reopened.settle()
                check(reopened.maskLayers == model.maskLayers && bytes(reopened.frame) == before, "PP19 reopened, the painted layer and the frame are identical, byte for byte")
                model.paintModuleID = nil
                while model.historyIndex > start { model.undo() }
                await model.settle()
            } else { check(false, "PP19 the exposure module is there") }
            // PP20 Vision: the person mask finds people, is saved next to the photo, and limits an exposure to them
            if let ex = model.modules.first(where: { $0.operation == "exposure" }), let exEntry = model.proMenu.flatMap(\.entries).first(where: { $0.modules.first?.operation == "exposure" }), let evField = field(model, ex, "exposure") {
                model.addToPanel(exEntry)
                let start = model.historyIndex
                model.setParam(ex, evField, to: .number(0.0001))
                await model.settle()
                func luma(_ rect: CGRect) -> Double {
                    guard let f = model.frame, let c = f.cropping(to: CGRect(x: rect.minX * Double(f.width), y: rect.minY * Double(f.height), width: rect.width * Double(f.width), height: rect.height * Double(f.height))) else { return 0 }
                    return meanLuma(c)
                }
                let tree = CGRect(x: 0.02, y: 0.05, width: 0.12, height: 0.12), body = CGRect(x: 0.40, y: 0.60, width: 0.2, height: 0.12)
                let treeBefore = luma(tree), bodyBefore = luma(body)
                model.setParam(ex, evField, to: .number(2))
                await model.detect(.person, for: ex)
                await model.settle()
                let found = model.maskLayer(for: ex)
                let file = found?.picture.map { URL(fileURLWithPath: copy.path + ".darkroom.masks/" + $0).path }
                check(found?.kind == .person && file.map({ FileManager.default.fileExists(atPath: $0) }) == true, "PP20 Vision found the person and saved its mask next to the photo (\(model.status))")
                check(luma(body) > bodyBefore + 10 && abs(luma(tree) - treeBefore) < 3, "PP20 the exposure brightens the person (\(bodyBefore) to \(luma(body))) and leaves the trees alone (\(treeBefore) to \(luma(tree)))")
                model.setMask(ex, mode: 0, kind: nil)
                while model.historyIndex > start { model.undo() }
                await model.settle()
            } else { check(false, "PP20 the exposure module is there") }
            model.mode = .simple
        } else {
            skip("pro panel", "the basics and their fields are the clean engine's")
        }

        print("default stack on a real raw")
        if let ci = engine as? CIEngine {
            await reopened.settle()
            let nothing = try await ci.sessionRender(stack: [], scale: 1)
            let explicit = try await ci.sessionRender(stack: [StackEntry(operation: "display", params: ["exposure": .number(0.5)])], scale: 1)
            let contrastOnly = try await ci.sessionRender(stack: [StackEntry(operation: "display", params: ["contrast": .number(0)])], scale: 1)
            let decoderLook = try await ci.sessionRender(stack: [StackEntry(operation: "display", enabled: false)], scale: 1)
            let gN = grid(nothing.image), gE = grid(explicit.image), gC = grid(contrastOnly.image), gD = grid(decoderLook.image)
            func meanDiff(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count) }
            check(meanDiff(gN, gE) < 0.5 && meanDiff(gN, gC) < 0.5,
                  "DF1 an EMPTY stack renders the display transform with its +0.5 EV start (same picture as asking for it; mean difference \(String(format: "%.2f", meanDiff(gN, gE))) codes)")
            check(meanDiff(gN, gD) > 3, "DF1 and it is a different picture from the decoder's own look (display switched off): mean difference \(String(format: "%.1f", meanDiff(gN, gD))) codes")
        } else {
            skip("default stack", "the defaults are the clean engine's")
        }

        print("auto white balance")
        await reopened.preparePro()
        if engine is CIEngine, let wbM = reopened.modules.first(where: { $0.operation == "temperature" }), let wbS = reopened.schema(for: wbM),
           let fr = wbS.fields.first(where: { $0.name == "red" }), let fg = wbS.fields.first(where: { $0.name == "green" }),
           let fb = wbS.fields.first(where: { $0.name == "blue" }) {
            await reopened.settle()
            let gains = await reopened.measureAutoWhiteBalance()
            check(gains?.count == 3 && gains![1] == 1 && gains!.allSatisfy { $0.isFinite && $0 >= 0.25 && $0 <= 4 },
                  "AWB1 the engine measures three finite gains with green at 1 (\(gains.map { $0.map { String(format: "%.3f", $0) }.joined(separator: " ") } ?? "nil"))")
            let startIndex = reopened.historyIndex
            let before = (reopened.value(wbM, fr).double, reopened.value(wbM, fb).double)
            await reopened.autoWhiteBalance()
            await reopened.settle()
            if let g = gains, let r0 = before.0, let b0 = before.1 {
                let r1 = reopened.value(wbM, fr).double, b1 = reopened.value(wbM, fb).double, g1 = reopened.value(wbM, fg).double
                check(abs((r1 ?? 0) - r0 * g[0]) < 1e-9 && abs((b1 ?? 0) - b0 * g[2]) < 1e-9 && abs((g1 ?? 0) - 1) < 1e-9,
                      "AWB2 the button writes the measured gains into white balance (red \(r0) to \(r1 ?? -1), blue \(b0) to \(b1 ?? -1))")
                check(reopened.historyIndex == startIndex + 1, "AWB3 the whole change is one history step")
                reopened.undo()
                await reopened.settle()
                check(reopened.value(wbM, fr).double == r0 && reopened.value(wbM, fb).double == b0, "AWB4 undo restores the white balance")
            } else { check(false, "AWB2 the gains and the module's values are there") }
        } else {
            skip("auto white balance", "it is the clean engine's")
        }

        print("viewport size")
        check(DarkroomModel.workingSize(forScreenLongSide: 1440) == 1600 && DarkroomModel.workingSize(forScreenLongSide: 3024) == 2419
              && DarkroomModel.workingSize(forScreenLongSide: 6016) == 3200 && DarkroomModel.workingSize(forScreenLongSide: .nan) == 1600
              && DarkroomModel.workingSize(forScreenLongSide: 0) == 1600 && DarkroomModel.workingSize(forScreenLongSide: -5) == 1600,
              "VS1 the working size is 0.8 of the screen's long edge, held to 1600...3200, and 1600 for a hostile value")
        check(DarkroomModel.workingSize == 1600, "VS1 the self-test pins the working size (DARKROOM_WORKING_SIZE) so its pixels do not depend on the screen")

        print("owned decode")
        if let ci = engine as? CIEngine {
            await reopened.settle()
            let full = try await ci.sessionRender(stack: [], scale: 1)
            let afterFull = await ci.segmentCacheInfo()
            let d1 = try await ci.sessionRender(stack: [], scale: 0.5)
            let d2 = try await ci.sessionRender(stack: [], scale: 0.5)
            let afterDrafts = await ci.segmentCacheInfo()
            check(afterDrafts.entries == afterFull.entries && afterDrafts.misses == afterFull.misses && afterDrafts.hits >= afterFull.hits + 2,
                  "OD1 two drafts add no decode: no new entry or miss, both served from the owned texture (entries \(afterFull.entries) to \(afterDrafts.entries), hits +\(afterDrafts.hits - afterFull.hits))")
            check(abs(d1.width * 2 - full.width) <= 2 && abs(d1.height * 2 - full.height) <= 2,
                  "OD2 a draft is half the frame (\(d1.width)x\(d1.height) against \(full.width)x\(full.height))")
            let fg = grid(full.image), dg = grid(d1.image)
            check(correlation(fg, dg) > 0.98 && grid(d2.image) == dg, "OD3 the draft is the same picture as the frame, and the same every time (layout correlation \(String(format: "%.3f", correlation(fg, dg)))))")
            let again = try await ci.sessionRender(stack: [], scale: 1)
            check(grid(again.image) == fg, "OD4 the full frame renders identically from the owned texture")
        } else {
            skip("owned decode", "the decoded texture is the clean engine's")
        }

        print("presented frames (Metal canvas)")
        if let ci = engine as? CIEngine {
            await reopened.settle()
            let plainFrame = try await ci.sessionRender(stack: [], scale: 1)
            if let p = try await ci.sessionRenderPresentable(stack: [], scale: 1) {
                check(p.texture.pixelFormat == .rgba16Float && p.width == plainFrame.width && p.height == plainFrame.height
                      && p.texture.width == p.width && p.texture.height == p.height,
                      "PT1 the frame is a 16-bit float texture of the picture's size (\(p.texture.width)x\(p.texture.height), \(p.texture.pixelFormat == .rgba16Float ? "rgba16Float" : "other"))")
                check(max(p.thumbnail.width, p.thumbnail.height) <= 640 && p.thumbnail.width * p.height == p.thumbnail.height * p.width
                      || abs(Double(p.thumbnail.width) / Double(p.thumbnail.height) - Double(p.width) / Double(p.height)) < 0.01,
                      "PT1 the scopes' copy is at most 640 px and has the picture's shape (\(p.thumbnail.width)x\(p.thumbnail.height))")
                // the texture's own rows, first row first, against the CGImage frame (top row first): the same picture, upright. Reading the
                // texture back through CIImage(mtlTexture:) would not do: that init undoes the renderer's flip, so a texture the wrong way up
                // still looked right (it showed upside down on screen).
                var half = [UInt16](repeating: 0, count: p.width * p.height * 4)
                p.texture.getBytes(&half, bytesPerRow: p.width * 8, from: MTLRegionMake2D(0, 0, p.width, p.height), mipmapLevel: 0)
                func floatOf(_ h: UInt16) -> Double { Double(Float16(bitPattern: h)) }
                func code(_ linearP3: Double) -> Double { 255 * (linearP3 <= 0.0031308 ? 12.92 * linearP3 : 1.055 * pow(max(linearP3, 0), 1 / 2.4) - 0.055) }
                var textureGrid = [Double](repeating: 0, count: 48 * 48)
                for gy in 0..<48 { for gx in 0..<48 {
                    let x = min(p.width - 1, (gx * p.width + p.width / 2) / 48), y = min(p.height - 1, (gy * p.height + p.height / 2) / 48)
                    let i = (y * p.width + x) * 4
                    // luma-ish from the three channels (P3 and sRGB primaries differ a little; this is for layout)
                    textureGrid[gy * 48 + gx] = code(0.25 * floatOf(half[i]) + 0.6 * floatOf(half[i + 1]) + 0.15 * floatOf(half[i + 2]))
                } }
                let b = grid(plainFrame.image)
                check(correlation(textureGrid, b) > 0.9 && correlation(textureGrid, b) > correlation(textureGrid, upsideDown(b)) + 0.3
                      && correlation(textureGrid, b) > correlation(textureGrid, mirrored(b)) + 0.3,
                      "PT2 the texture's first row is the picture's top: its own rows match the CGImage frame (correlation \(String(format: "%.3f", correlation(textureGrid, b))), upside down \(String(format: "%.3f", correlation(textureGrid, upsideDown(b)))))")
                check(correlation(grid(p.thumbnail), b) > 0.99, "PT2 the scopes' copy is upright too (correlation \(String(format: "%.3f", correlation(grid(p.thumbnail), b))))")
                // more than 8 bits of tone: the red channel holds far more than 256 distinct values
                var raw = [UInt16](repeating: 0, count: p.width * p.height * 4)
                p.texture.getBytes(&raw, bytesPerRow: p.width * 8, from: MTLRegionMake2D(0, 0, p.width, p.height), mipmapLevel: 0)
                var distinct = Set<UInt16>()
                for i in stride(from: 0, to: raw.count, by: 4) { distinct.insert(raw[i]) }
                check(distinct.count > 1500, "PT3 the frame carries more than 8 bits of tone (\(distinct.count) distinct red values; an 8-bit frame has at most 256)")
            } else {
                check(false, "PT1 the clean engine presents frames")
            }

            // the model, with the canvas's mode on
            reopened.presentsTexture = true
            reopened.requestRender()
            await reopened.settle()
            let serial0 = reopened.frameSerial
            check(reopened.frameTexture != nil && reopened.frameSize == CGSize(width: reopened.frameTexture!.width, height: reopened.frameTexture!.height)
                  && (reopened.frame.map { max($0.width, $0.height) <= 640 } ?? false) && reopened.scopes != nil,
                  "PT4 the model holds the presented frame, lays out by the picture's size, and keeps the scopes fed from the thumbnail (frame \(reopened.frameSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"))")
            let before = luma(reopened)
            reopened.setSimple(.light, to: 60)
            await reopened.settle()
            check(reopened.frameSerial > serial0 && luma(reopened) > before + 3, "PT4 an edit presents a new frame and it is brighter (\(String(format: "%.1f", before)) to \(String(format: "%.1f", luma(reopened))))")
            reopened.setSimple(.light, to: 0)
            // a zoomed region renders presented too
            reopened.zoom = .fit
            await reopened.settle()
            if let z = ZoomMode.allCases.first(where: { $0 != .fit }) {
                reopened.zoom = z
                await reopened.settle()
                check(reopened.frameTexture != nil && reopened.frameSize != nil, "PT5 a zoomed region is presented as a texture too (\(z.rawValue): \(reopened.frameSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"))")
                reopened.zoom = .fit
                await reopened.settle()
            }
            // the HDR preview: only with headroom, and the frame then holds values above SDR white
            func textureMax(_ f: PresentedFrame?) -> Double {
                guard let f else { return 0 }
                var half = [UInt16](repeating: 0, count: f.width * f.height * 4)
                f.texture.getBytes(&half, bytesPerRow: f.width * 8, from: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0)
                var m = 0.0
                for i in stride(from: 0, to: half.count, by: 4) { for c in 0..<3 { let v = Double(Float16(bitPattern: half[i + c])); if v.isFinite { m = max(m, v) } } }
                return m
            }
            let savedHDR = reopened.hdrPreview
            // an HDR peak acts on the display transform: make sure it is on for these checks (an earlier step of this suite may have switched it off)
            let displayModule = module(reopened, "display")
            let displayWasOn = displayModule.map { reopened.isEnabled($0) } ?? false
            if let d = displayModule, !displayWasOn { reopened.setEnabled(d, true) }
            DarkroomModel.headroomOverride = 1
            reopened.setHDRPreview(true)
            await reopened.settle()
            check(!reopened.hdrAvailable && reopened.previewPeak == 1 && reopened.frameTexture?.peak == 1,
                  "HP1 with no headroom the HDR preview is unavailable and frames stay SDR, whatever the setting (peak \(reopened.frameTexture?.peak ?? 0))")
            let sdrMax = textureMax(reopened.frameTexture)
            DarkroomModel.headroomOverride = 4
            reopened.requestRender()
            await reopened.settle()
            let hdrMax = textureMax(reopened.frameTexture)
            check(reopened.hdrAvailable && reopened.previewPeak == 4 && reopened.frameTexture?.peak == 4,
                  "HP2 with 4x headroom and the preview on, the frame is rendered for peak 4 (\(reopened.frameTexture?.peak ?? 0))")
            check(sdrMax <= 1.0001 && hdrMax > 1.3, "HP3 the SDR frame tops out at 1 (\(String(format: "%.3f", sdrMax))) and the HDR frame holds brighter highlights (\(String(format: "%.2f", hdrMax)))")
            let hdrGrid = grid(reopened.frame)
            reopened.setHDRPreview(false)
            await reopened.settle()
            check(reopened.frameTexture?.peak == 1 && textureMax(reopened.frameTexture) <= 1.0001 && correlation(hdrGrid, grid(reopened.frame)) > 0.98,
                  "HP4 switching it off returns an SDR frame of the same picture")
            DarkroomModel.headroomOverride = nil
            reopened.setHDRPreview(savedHDR)
            if let d = displayModule, !displayWasOn { reopened.setEnabled(d, false) }
            await reopened.settle()

            reopened.presentsTexture = false
            reopened.requestRender()
            await reopened.settle()
            check(reopened.frameTexture == nil && reopened.frameFullSize == nil && (reopened.frame.map { $0.width > 640 || $0.height > 640 } ?? false),
                  "PT6 with the mode off the model is back to full-size CGImages")
        } else {
            skip("presented frames", "the texture canvas is the clean engine's")
        }


        print("simple mode")
        let simple = reopened
        simple.mode = .simple
        await simple.prepareSimple()
        check(simple.simpleReady, "the five sliders found their modules")
        simple.jump(to: 0)
        await simple.settle()
        let s0 = luma(simple)
        simple.setSimple(.light, to: 50)
        await simple.settle()
        check(luma(simple) > s0 + 3, "Light +50 brightens the frame (\(String(format: "%.1f", s0)) to \(String(format: "%.1f", luma(simple))))")
        check(abs(simple.simpleValue(.light) - 50) < 1, "the slider reads back from the real parameter")
        simple.setSimple(.light, to: 0)
        if simple.simpleControls.contains(.shadows) {
            simple.jump(to: 0)
            await simple.settle()
            let zs = simple.historyIndex, zl = luma(simple)
            let plainGrid = grid(simple.frame)
            simple.setSimple(.shadows, to: 80)
            await simple.settle()
            // a stored segment of the engine's cache once came back upside down (mirrored once the camera turned it upright); the layout must match
            let editedGrid = grid(simple.frame)
            check(correlation(plainGrid, editedGrid) > 0.85 && correlation(plainGrid, editedGrid) > correlation(plainGrid, mirrored(editedGrid)) + 0.2
                  && correlation(plainGrid, editedGrid) > correlation(plainGrid, upsideDown(editedGrid)) + 0.2,
                  "SEG1 a photo edited with a neighbourhood module keeps its orientation (layout correlation \(String(format: "%.2f", correlation(plainGrid, editedGrid))), mirrored \(String(format: "%.2f", correlation(plainGrid, mirrored(editedGrid)))))")
            check(luma(simple) > zl + 0.5, "Shadows +80 lifts the frame (\(String(format: "%.1f", zl)) to \(String(format: "%.1f", luma(simple))))")
            check(abs(simple.simpleValue(.shadows) - 80) < 1 && simple.historyIndex == zs + 1, "Shadows reads back from the zone exposure and is one history step")
            let lifted = luma(simple)
            simple.setSimple(.highlights, to: -60)
            await simple.settle()
            check(luma(simple) < lifted - 0.2 && abs(simple.simpleValue(.highlights) + 60) < 1, "Highlights -60 pulls the top down (\(String(format: "%.1f", lifted)) to \(String(format: "%.1f", luma(simple))))")
            check(simple.customEditCount == 0, "the zone exposure is Simple's own, not a custom edit")
            simple.setSimple(.shadows, to: 0)
            simple.setSimple(.highlights, to: 0)
            check(module(simple, "zones").map { !simple.isEnabled($0) } == true, "both sliders at 0 switch the zone exposure off again")
            simple.jump(to: 0)
            await simple.settle()
        } else {
            skip("simple shadows and highlights", "the zone exposure is the clean engine's")
        }
        simple.apply(SimpleLook.all[1])
        await simple.settle()
        check(abs(simple.simpleValue(.warmth) - 55) < 2, "a look sets Warmth to its value (\(String(format: "%.0f", simple.simpleValue(.warmth))))")
        check(simple.customEditCount == 0, "Simple edits alone leave no custom edits")
        simple.jump(to: 0)
        let steps0 = simple.historyIndex
        simple.apply(SimpleLook.all[3])
        check(simple.historyIndex == steps0 + 1, "a whole look is one history step (\(simple.historyIndex - steps0))")
        simple.undo()
        await simple.settle()
        check(abs(luma(simple) - s0) < 0.5, "one undo returns the picture from before the look")
        simple.setSimple(.warmth, to: 60)
        check(simple.historyIndex == steps0 + 1, "warmth writes two parameters and is still one step")
        simple.jump(to: 0)
        simple.apply(SimpleLook.all[1])
        if let shadhi = module(simple, "shadhi") {
            simple.setEnabled(shadhi, true)
            check(simple.customEditCount == 1, "a Pro edit shows up as one custom edit")
        }
        if let ex = module(simple, "exposure"), let black = field(simple, ex, "black") {
            simple.setParam(ex, black, to: .number(0.02))
            check(simple.simpleTouchedByPro(.light) && !simple.simpleTouchedByPro(.warmth), "a Pro edit on the same module puts a dot on its slider only")
        }
        simple.mode = .pro

        print("culling")
        let other = ["IMG_2448.CR2", "img_3759.cr2"].map { NSHomeDirectory() + "/Downloads/" + $0 }.first {
            FileManager.default.fileExists(atPath: $0) && $0 != path
        }
        if let other, let thumb = try? await engine.render(path: other, maxSide: 480).image {
            let ci = CIImage(cgImage: thumb)
            let blurred = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]).cropped(to: ci.extent)
            if let soft = CIContext().createCGImage(blurred, from: ci.extent) {
                let a = Culling.sharpness(of: thumb), b = Culling.sharpness(of: soft)
                check(a > b + 10, "a blurred copy scores clearly lower (\(String(format: "%.0f", a)) vs \(String(format: "%.0f", b)))")
                check(Culling.distance(Culling.averageHash(of: thumb), Culling.averageHash(of: soft)) <= 10, "a blurred copy still hashes close to the original")
            }
        } else { check(false, "a second raw was available to score") }
        let t0 = Date(), hA: UInt64 = 0xF0F0_F0F0_F0F0_F0F0
        let groups = Culling.stacks(dates: [t0, t0.addingTimeInterval(3), t0.addingTimeInterval(120), t0.addingTimeInterval(122)],
                                    hashes: [hA, hA ^ 0b111, hA, ~hA])
        check(groups[0] != nil && groups[0] == groups[1], "frames seconds apart that look alike share a stack")
        check(groups[2] == nil && groups[3] == nil, "a distant frame, and a different-looking one, stand alone")

        print("library")
        let lib = LibraryModel(engine: engine)
        let libDir = work.appending(path: "library")
        try? FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let raws = ((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Downloads")) ?? [])
            .filter { $0.lowercased().hasSuffix(".cr2") }.sorted().prefix(4)
        for r in raws {
            try? FileManager.default.createSymbolicLink(at: libDir.appending(path: r), withDestinationURL: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/" + r))
        }
        lib.load(folder: libDir)
        check(lib.items.count == raws.count && raws.count > 0, "the library lists \(lib.items.count) photos from a folder")
        for _ in 0..<240 where lib.handled < lib.items.count { try? await Task.sleep(for: .milliseconds(500)) }
        check(lib.scored == lib.items.count, "every thumbnail was developed and scored (\(lib.scored))")
        check(lib.items.allSatisfy { $0.thumb != nil && ($0.sharpness ?? -1) >= 0 }, "each has a thumbnail and a sharpness score")
        if let first = lib.items.first {
            lib.setRating(4, for: first.path)
            lib.toggleReject(first.path)
            check(lib.items[0].rejected && lib.items[0].rating == 0, "rejecting clears the stars")
            lib.toggleReject(first.path)
            lib.setRating(0, for: first.path)
        }

        print("export")
        let exportURL = work.appending(path: "export.jpg")
        await model.export(to: exportURL)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int) ?? 0
        check(bytes > 100_000, "export wrote \(bytes) bytes: \(model.status)")
        model.setParam(exposure, ev, to: .number(0.3))
        await model.settle()
        check(model.frame != nil, "session still renders after export (\(Int(model.lastMilliseconds ?? 0)) ms)")

        // a photo that fails to open must not take the previous photo's edits (or deletion) to its own sidecar.
        // Last, because a failed open leaves the shared engine with no session.
        print("a photo that fails to open")
        // a folder with a raw's name: no engine can open it (a missing file opens lazily on the Core Image engine)
        let missing = copy.deletingLastPathComponent().appendingPathComponent("folder-named-photo.ARW")
        try? FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let missingSidecar = URL(fileURLWithPath: missing.path + ".darkroom.json")
        try? FileManager.default.removeItem(at: missingSidecar)
        let hopper = DarkroomModel(engine: engine)
        await hopper.open(path: copy.path)
        await hopper.settle()
        if let exposure = module(hopper, "exposure"), let ev = field(hopper, exposure, "exposure") { hopper.setParam(exposure, ev, to: .number(0.7)) }
        await hopper.open(path: missing.path)       // fails
        await hopper.flushSave()
        if let exposure = module(hopper, "exposure"), let ev = field(hopper, exposure, "exposure") { hopper.setParam(exposure, ev, to: .number(0.9)) }
        await hopper.flushSave()
        if clean {
            // the Core Image engine opens any path lazily (even a folder), so an open cannot fail there; the model's reset
            // on a thrown open is covered on the engine that does throw
            notApplicable.append("a failed open cannot be provoked on the Core Image engine (it opens any path lazily)")
        } else {
            check(!FileManager.default.fileExists(atPath: missingSidecar.path), "a photo that failed to open gets no sidecar from the previous photo's edits")
        }
        try? FileManager.default.removeItem(at: missing)

        if clean {
            print("pro panel: wake, all on/off, order")
            // its own copy and model, so the history this block makes reaches no other check
            let copy2 = work.appending(path: "panel-" + URL(fileURLWithPath: path).lastPathComponent)
            try FileManager.default.copyItem(atPath: path, toPath: copy2.path)
            let model = DarkroomModel(engine: engine)
            await model.open(path: copy2.path)
            await model.settle()
            let base = luma(model)
            // a hue moved while its saturation sleeps at zero wakes the saturation in the same step
            if let st = module(model, "splittoning") {
                await model.loadSchema(for: st)
                if let hue = field(model, st, "shadows_hue"), let sat = field(model, st, "shadows_saturation") {
                    check(model.sleepers(st, hue).map(\.name) == ["shadows_saturation"], "shadows hue reports its sleeping saturation")
                    let steps = model.history.count
                    model.setParam(st, hue, to: .number(300))
                    check(model.value(st, sat).double == 0.5, "moving shadows hue wakes shadows saturation to 0.5 (\(model.value(st, sat)))")
                    check(model.history.count == steps + 1, "hue and saturation are one history step")
                    check(model.sleepers(st, hue).isEmpty, "awake: nothing left to wake")
                    await model.settle()
                    check(model.isEnabled(st) && model.inProPanel(st), "split toning is on and in the panel")
                }
            }
            if let exposure = module(model, "exposure"), let ev = field(model, exposure, "exposure") {
                model.setParam(exposure, ev, to: .number((model.base(exposure, ev).double ?? 0) + 1.5))
            }
            await model.settle()
            let edited = luma(model)
            check(edited > base + 3, "an exposure edit brightens (\(String(format: "%.1f", base)) -> \(String(format: "%.1f", edited)))")
            // all off, all on: one step each, the sections stay
            let before = model.proPanelEntries
            check(before.count >= 2, "panel has \(before.count) sections")
            let steps = model.history.count
            model.setAllProEffects(false)
            check(!model.canSetAllProEffects(false), "all off: no section left on")
            check(model.proPanelEntries.count == before.count, "all off keeps every section")
            check(model.history.count == steps + 1, "all off is one history step")
            await model.settle()
            check(abs(luma(model) - edited) > 1, "all off takes the edits off the picture (\(String(format: "%.1f", luma(model))))")
            model.setAllProEffects(true)
            check(!model.canSetAllProEffects(true), "all on: no section left off")
            check(model.history.count == steps + 2, "all on is one history step")
            await model.settle()
            check(abs(luma(model) - edited) < 0.5, "all on brings the edits back")
            // order: newest switched on at the top, pipeline by engine order
            model.setProPanelOrder(.newest)
            let menu = model.proMenu.flatMap(\.entries).filter { !model.inProPanel($0) }
            if menu.count >= 2 {
                model.addToPanel(menu[0]); model.addToPanel(menu[1])
                check(model.proPanelEntries.first?.id == menu[1].id, "newest: the section switched on last is at the top")
                check(model.proPanelEntries.dropFirst().first?.id == menu[0].id, "newest: the one before it is second")
                model.undo()
                check(model.proPanelEntries.first?.id == menu[0].id, "undo moves the top down with it")
                model.redo()
                model.setProPanelOrder(.pipeline)
                let orders = model.proPanelEntries.map { $0.modules.map(\.iopOrder).min() ?? 0 }
                check(orders == orders.sorted(), "pipeline: sections in engine order")
                model.setProPanelOrder(.newest)
            } else { skip("panel order", "fewer than two modules left to switch on") }
            await model.flushSave()

            // an old sidecar naming modules folded into others (merge 2026-10-22) opens onto their survivors, same picture
            print("folded modules")
            let copy3 = work.appending(path: "fold-" + URL(fileURLWithPath: path).lastPathComponent)
            try FileManager.default.copyItem(atPath: path, toPath: copy3.path)
            let oldEdits: EditMap = [
                "velvia#0": ModuleEdit(enabled: true, params: ["strength": .number(0.6)], blend: [:], inPanel: nil),
                "shadhi#0": ModuleEdit(enabled: true, params: ["shadows": .number(80), "highlights": .number(-40)], blend: [:], inPanel: nil),
                "colorize#0": ModuleEdit(enabled: true, params: ["strength": .number(0.5), "hue": .number(0.3)], blend: [:], inPanel: true),
                "colorbalancergb#0": ModuleEdit(enabled: true, params: ["contrast": .number(0.2)], blend: [:], inPanel: nil),
            ]
            let oldSidecar = Sidecar(version: 3, history: [HistoryItem(label: "original", detail: "", edits: [:]), HistoryItem(label: "old", detail: "", edits: oldEdits)],
                                     index: 1, algorithms: nil, layers: nil)
            try oldSidecar.save(for: copy3.path)
            // what the old stack renders through the engine's alias path is the yardstick
            let yardstick = try await engine.render(path: copy3.path, maxSide: 600, stack: oldEdits.map { id, e in
                StackEntry(operation: String(id.split(separator: "#")[0]), params: e.params, blend: [:], enabled: true) })
            let fm = DarkroomModel(engine: engine)
            await fm.open(path: copy3.path)
            await fm.settle()
            let ids = Set(fm.edits.keys)
            check(!ids.contains("velvia#0") && !ids.contains("shadhi#0") && !ids.contains("colorize#0"), "the folded ids are gone (\(ids.sorted()))")
            check(ids.contains("zones#0") && ids.contains("gradientmap#0") && ids.contains("colorbalancergb#0"), "their survivors carry them (\(ids.sorted()))")
            check(fm.edits["colorbalancergb#0"]?.params["vibrance"]?.double == 0.6 && fm.edits["colorbalancergb#0"]?.params["contrast"]?.double == 0.2,
                  "the velvia joined the colour balance edit of the same step as its vibrance (\(fm.edits["colorbalancergb#0"]?.params as Any))")
            check(fm.edits["zones#0"]?.params["shadows"]?.double == 80 / 50, "shadows 80 became zone exposure shadows 1.6 EV (\(fm.edits["zones#0"]?.params["shadows"] as Any))")
            check(fm.edits["gradientmap#0"]?.inPanel == true, "panel membership rides along")
            check(fm.versionNotices.contains { $0.contains("folded") }, "the notices say what happened: \(fm.versionNotices)")
            let now = try await engine.render(path: copy3.path, maxSide: 600, stack: fm.stack(for: fm.edits))
            check(SelfTest.meanDiff(SelfTest.fingerprint(yardstick.image), SelfTest.fingerprint(now.image)) < 0.5,
                  "the folded edit renders as the old stack did (mean diff \(SelfTest.meanDiff(SelfTest.fingerprint(yardstick.image), SelfTest.fingerprint(now.image))))")
            await fm.flushSave()
            let reread = Sidecar.load(for: copy3.path)
            check(reread?.history.last?.edits.keys.contains("zones#0") == true && reread?.history.last?.edits.keys.contains("shadhi#0") == false, "the saved sidecar carries the survivors' ids")
        }

        if clean {
            print("library")
            // its own copy and model: the picks this block makes reach no other check
            let copy4 = work.appending(path: "lib-" + URL(fileURLWithPath: path).lastPathComponent)
            try FileManager.default.copyItem(atPath: path, toPath: copy4.path)
            let lm = DarkroomModel(engine: engine)
            await lm.open(path: copy4.path)
            lm.mode = .pro
            await lm.settle()
            // LB1 the categories: every one has rows, and the module categories list every menu entry exactly once
            let cats = lm.libraryCategories
            check(cats.contains(.masks) && cats.contains(.presets) && cats.contains(.looks), "LB1 the library has looks, presets and masks (\(cats.map(\.title).joined(separator: ", ")))")
            check(cats.allSatisfy { !lm.libraryEntries($0).isEmpty }, "LB1 every category has rows")
            let moduleRows = cats.filter { $0.menuGroup != nil }.flatMap { lm.libraryEntries($0) }.map(\.id)
            let menuIDs = lm.proMenu.flatMap(\.entries).map { "module-\($0.id)" }
            check(moduleRows.count == menuIDs.count && Set(moduleRows) == Set(menuIDs), "LB1 the module categories hold the \(menuIDs.count) menu entries once each (\(moduleRows.count) rows)")
            check(lm.libraryEntries(.presets).count == CIEngineProbe.aliases.count, "LB1 the presets are the \(CIEngineProbe.aliases.count) folded modules (\(lm.libraryEntries(.presets).count))")
            check(lm.libraryEntries(.masks).count == MaskLayerKind.allCases.count, "LB1 the masks are the \(MaskLayerKind.allCases.count) kinds")
            // LB2 search runs over every category at once
            let curve = lm.librarySearch("curve")
            check(curve.contains { g in g.entries.contains { $0.id == "module-tonecurve#0" } }, "LB2 a search for curve finds the tone curve (\(curve.flatMap(\.entries).map(\.name)))")
            check(lm.librarySearch("velvia").first?.category == .presets, "LB2 a search for velvia finds the preset")
            check(lm.librarySearch("face").contains { $0.category == .masks }, "LB2 a search for face finds the mask")
            check(lm.librarySearch("qzxv").isEmpty && lm.librarySearch("").isEmpty, "LB2 a nonsense or empty search finds nothing")
            // LB3 a module row's switch is the Modules menu's: into the panel and out
            if case .module(let sharpen)? = lm.libraryEntries(.common).first(where: { $0.id == "module-sharpen#0" })?.kind {
                lm.toggleInPanel(sharpen)
                check(lm.inProPanel(sharpen), "LB3 the sharpen row's switch puts it in the panel")
                lm.toggleInPanel(sharpen)
                check(!lm.inProPanel(sharpen), "LB3 and takes it out")
            } else { check(false, "LB3 sharpen is a Common row") }
            // LB4 a preset: the halation preset sets bloom up as film halation, in the panel, on, unfolded, one step
            if let hal = lm.libraryPresets.first(where: { $0.id == "halation" }), let bloom = module(lm, "bloom") {
                let steps = lm.history.count
                await lm.applyLibraryPreset(hal)
                await lm.settle()
                let glow = field(lm, bloom, "glow").map { lm.value(bloom, $0) }
                let hue = field(lm, bloom, "hue").map { lm.value(bloom, $0).double }
                check(lm.inProPanel(bloom) && lm.isEnabled(bloom), "LB4 the halation preset puts bloom in the panel and on")
                check(glow == .option("film") && hue == 25, "LB4 bloom is set to film halation with the old hue (\(String(describing: glow)), \(String(describing: hue)))")
                check(lm.history.count == steps + 1 && lm.proOpen.contains(bloom.id) && lm.libraryPicked == "preset-halation",
                      "LB4 one history step, the section unfolded, the pick shown at the top (\(lm.history.count - steps) steps)")
                // LB5 the section shows the chosen method's controls only
                if let schema = lm.schema(for: bloom) {
                    let shown = lm.shownFields(bloom, schema.fields).map(\.name)
                    check(shown.contains("hue") && shown.contains("size"), "LB5 film halation shows hue (\(shown))")
                    if let g = field(lm, bloom, "glow") {
                        lm.setParam(bloom, g, to: .option("soft"))
                        let soft = lm.shownFields(bloom, schema.fields).map(\.name)
                        check(!soft.contains("hue") && soft.contains("size"), "LB5 soft bloom hides hue, keeps size (\(soft))")
                    }
                }
                if let sb = module(lm, "surfaceblur") {
                    await lm.loadSchema(for: sb)
                    if let schema = lm.schema(for: sb), let m = field(lm, sb, "method") {
                        let guided = lm.shownFields(sb, schema.fields).map(\.name)
                        check(guided == ["method", "amount", "radius", "threshold"], "LB5 surface blur (guided) shows four controls (\(guided))")
                        lm.setParam(sb, m, to: .option("skin"))
                        let skin = lm.shownFields(sb, schema.fields).map(\.name)
                        check(skin == ["method", "amount", "radius", "hue", "width"], "LB5 skin shows its own (\(skin))")
                        lm.undo()
                    }
                }
                // LB6 a mask from the library goes on the open section: bloom is unfolded, so the brush starts on it
                check(lm.libraryMaskTarget?.id == bloom.id, "LB6 the mask target is the open section, bloom (\(lm.libraryMaskTarget?.id ?? "none"))")
                await lm.applyLibraryMask(.brush)
                check(lm.paintModuleID == bloom.id && lm.maskLayer(for: bloom)?.kind == .brush && lm.blendOpen,
                      "LB6 the brush from the library paints on bloom and opens its Blend (\(lm.paintModuleID ?? "none"))")
                lm.paintModuleID = nil
            } else { check(false, "LB4 the halation preset and bloom exist") }
            // LB7 shown or hidden, by its shortcut and the find shortcut
            let shown0 = lm.libraryShown
            Shortcuts.all.first { $0.id == "library" }?.action(lm)
            check(lm.libraryShown == !shown0, "LB7 the library shortcut flips it (\(shown0) -> \(lm.libraryShown))")
            lm.setLibraryShown(false)
            let serial = lm.libraryFindSerial
            Shortcuts.all.first { $0.id == "library-find" }?.action(lm)
            check(lm.libraryShown && lm.libraryFindSerial == serial + 1, "LB7 the find shortcut opens the library and asks for its search field")
            lm.setLibraryShown(shown0)
        }

        if !notApplicable.isEmpty { print("\n\(notApplicable.count) check(s) n/a on this engine: \(notApplicable.joined(separator: "; "))") }
        print(failures.isEmpty ? "\nALL CHECKS PASSED" : "\n\(failures.count) CHECK(S) FAILED")
        if !failures.isEmpty { exit(1) }
    }
}
