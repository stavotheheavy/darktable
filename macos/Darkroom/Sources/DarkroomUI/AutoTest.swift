import AppKit
import DarktableKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A scripted run inside the real app, switched on by DARKROOM_AUTOTEST. It drives the
/// model the way a person would, so the actual views render for every module, and it
/// logs one line per step so a crash shows exactly where it happened.
///
///   DARKROOM_AUTOTEST=modules   select each module, switch it on, render, reset
///   DARKROOM_AUTOTEST=ui        tabs, scopes, zoom, snapshot, undo, backgrounds
///   DARKROOM_AUTOTEST=simple    Simple mode's geometry controls, one screenshot per step (DARKROOM_SHOTS)
///   DARKROOM_AUTOTEST=pro       Pro mode's panel: default, curve edited, modules added, a section off, at two window sizes
@MainActor
public enum AutoTest {
    private static func log(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    public static func runIfRequested(model: DarkroomModel) async {
        guard let scenario = ProcessInfo.processInfo.environment["DARKROOM_AUTOTEST"], !scenario.isEmpty else { return }

        for _ in 0..<300 where model.frame == nil { try? await Task.sleep(for: .milliseconds(100)) }
        await model.settle()
        guard model.frame != nil else {
            log("AUTOTEST FAIL no image after 30 s: \(model.status)")
            exit(2)
        }
        log("AUTOTEST start \(scenario): \(model.modules.count) modules, frame \(model.frame!.width)x\(model.frame!.height)")

        switch scenario {
        case "modules": await modules(model)
        case "ui": await ui(model)
        case "shots": await shots(model)
        case "simple": await simple(model)
        case "pro": await pro(model)
        default:
            await modules(model)
            await ui(model)
        }
        log("AUTOTEST OK")
        exit(0)
    }

    private static func modules(_ model: DarkroomModel) async {
        let env = ProcessInfo.processInfo.environment
        let from = Int(env["DARKROOM_AUTOTEST_FROM"] ?? "") ?? 0
        let withDeprecated = env["DARKROOM_AUTOTEST_DEPRECATED"] == "1"
        model.showDeprecated = withDeprecated
        var slow: [(String, Double)] = []
        for (i, m) in model.modules.enumerated() {
            if i < from { continue }
            if m.deprecated && !withDeprecated && !m.enabled { continue }
            log("[\(i + 1)/\(model.modules.count)] select \(m.id) (\(m.name))")
            model.select(m)
            try? await Task.sleep(for: .milliseconds(150))
            for _ in 0..<40 where m.haveIntrospection && model.schema(for: m) == nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
            let fields = model.schema(for: m)?.fields.count ?? -1
            guard !m.hideEnableButton else {
                log("    fields \(fields), always on")
                continue
            }

            model.setEnabled(m, !m.enabled)
            await model.settle()
            let ms = model.lastMilliseconds ?? 0
            let status = model.status
            let ok = model.frame != nil && !status.lowercased().contains("fail") && !status.lowercased().contains("error")
            log("    fields \(fields), \(m.enabled ? "off" : "on") -> \(Int(ms)) ms, \(ok ? "ok" : "ERROR: \(status)")")
            if ms > 600 { slow.append((m.id, ms)) }

            model.resetModule(m)
            await model.settle()
        }
        if !slow.isEmpty { log("slow renders: " + slow.map { "\($0.0) \(Int($0.1)) ms" }.joined(separator: ", ")) }
    }

    // MARK: pictures of the live window

    /// The app's own window as an image. The window server composites the glass, so this
    /// is what is on screen, taken without any screen-recording permission because it is
    /// the app's own window.
    private static func capture(to path: String) -> Bool {
        guard let win = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 400 }) else {
            log("    no window to capture")
            return false
        }
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return false }
        let fn = unsafeBitCast(sym, to: Create.self)
        guard let image = fn(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                             UInt32(win.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?
            .takeRetainedValue() else { return false }
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Simple mode before and after straighten, rotate and a 4:5 crop, then every step undone. The edit
    /// mode the person had is put back, since setting it is remembered across launches.
    private static func simple(_ model: DarkroomModel) async {
        let dir = ProcessInfo.processInfo.environment["DARKROOM_SHOTS"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String) async {
            await model.settle()
            try? await Task.sleep(for: .milliseconds(900))
            let ok = capture(to: "\(dir)/\(name).png")
            log("shot \(name): \(ok ? "written" : "FAILED") frame \(model.frame?.width ?? 0)x\(model.frame?.height ?? 0)")
        }
        let previousMode = model.mode
        NSApp.activate()
        model.mode = .simple
        await model.prepareSimple()
        log("simple geometry ready: \(model.simpleGeometryReady)")
        let start = model.historyIndex
        await shot("s1-simple")
        model.setStraighten(6)
        await shot("s2-straighten-6")
        model.rotate90()
        await shot("s3-rotated")
        model.setAspect(.fourFive)
        await shot("s4-aspect-4x5")
        // the looks section opened (it is folded by default), then put back as the person had it
        let looksKey = "darkroom.simple.looksOpen"
        let looksWereOpen = UserDefaults.standard.object(forKey: looksKey) as? Bool
        UserDefaults.standard.set(true, forKey: looksKey)
        if let warm = SimpleLook.all.first(where: { $0.id == "warm" }) { model.apply(warm) }
        await shot("s4b-warm-look")
        if let open = looksWereOpen { UserDefaults.standard.set(open, forKey: looksKey) } else { UserDefaults.standard.removeObject(forKey: looksKey) }
        while model.historyIndex > start { model.undo() }
        await shot("s5-undone")
        model.mode = previousMode
    }

    /// Pro mode at a small and a large window: the four basics, an edited curve, added modules, a section switched
    /// off. The edit mode and the window frame are put back afterwards.
    private static func pro(_ model: DarkroomModel) async {
        let dir = ProcessInfo.processInfo.environment["DARKROOM_SHOTS"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String) async {
            await model.settle()
            try? await Task.sleep(for: .milliseconds(900))
            let ok = capture(to: "\(dir)/\(name).png")
            log("shot \(name): \(ok ? "written" : "FAILED") panel \(model.proPanelEntries.map(\.name).joined(separator: ", "))")
        }
        let previousMode = model.mode
        guard let win = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 400 }) else { log("no window"); return }
        let previousFrame = win.frame
        NSApp.activate()
        model.mode = .pro
        let start = model.historyIndex
        for (label, size) in [("small", CGSize(width: 900, height: 689)), ("large", CGSize(width: 1440, height: 900))] {
            win.setFrame(CGRect(origin: win.frame.origin, size: size), display: true)
            while model.historyIndex > start { model.undo() }
            await model.preparePro()
            await shot("p1-\(label)-basics")
            model.setCurveNode(1, 0.18)
            model.setCurveNode(3, 0.84)
            await shot("p2-\(label)-curve")
            for op in ["shadhi", "vignette"] {
                if let e = model.proMenu.flatMap(\.entries).first(where: { $0.modules[0].operation == op }) { model.addToPanel(e) }
            }
            await model.preparePro()
            await shot("p3-\(label)-added")
            if let curve = model.proPanelEntries.first(where: { $0.modules[0].operation == "tonecurve" }) { model.toggleProEffect(curve) }
            await shot("p4-\(label)-curve-off")
            model.proMenuOpen = .modules
            await shot("p5-\(label)-modules-menu")
            model.proMenuQuery = "curve"
            await shot("p6-\(label)-modules-search")
            model.proMenuQuery = "zzz"
            await shot("p7-\(label)-modules-search-empty")
            model.proMenuOpen = .presets
            await shot("p8-\(label)-presets-menu")
            model.proMenuOpen = .history
            await shot("p9-\(label)-history-menu")
            model.proMenuOpen = nil
            // the mask controls: exposure unfolded alone, its Blend and mask section open on a gradient, then an ellipse
            if let ex = model.modules.first(where: { $0.operation == "exposure" }), let entry = model.proPanelEntries.first(where: { $0.modules.first?.operation == "exposure" }) {
                model.proOpen = [entry.id]
                model.blendOpen = true
                model.setMask(ex, mode: 2, kind: .gradient)
                await shot("p10-\(label)-mask-gradient")
                model.setMask(ex, mode: 2, kind: .ellipse)
                await shot("p11-\(label)-mask-ellipse")
                model.maskShowID = ex.id
                await shot("p12-\(label)-mask-overlay-ellipse")
                model.setMask(ex, mode: 2, kind: .gradient)
                model.setBlend(ex, "mask_angle", to: .number(35), detail: "angle")
                model.setBlend(ex, "mask_feather", to: .number(0.3), detail: "feather")
                await shot("p13-\(label)-mask-overlay-gradient")
                model.maskShowID = nil
                model.setMask(ex, mode: 0, kind: nil)
                model.blendOpen = false
            }
            // radial light from the Modules menu, set up as a spotlight on the subject
            if let e = model.proMenu.flatMap(\.entries).first(where: { $0.modules.first?.operation == "radiallight" }), let m = e.modules.first {
                model.addToPanel(e)
                await model.preparePro()
                if let s = model.schema(for: m) {
                    for (k, v) in [("exposure", 1.3), ("x", 0.5), ("y", 0.55), ("size", 0.3), ("shape", 0.75), ("feather", 0.6)] {
                        if let f = s.fields.first(where: { $0.name == k }) { model.setParam(m, f, to: .number(v)) }
                    }
                }
                model.proOpen = [e.id]
                await shot("p14-\(label)-radial-light")
                model.removeFromPanel(e)
            }
            // the clipping warning
            model.showClipping = true
            try? await Task.sleep(for: .milliseconds(300))
            await shot("p15-\(label)-clipping")
            model.showClipping = false
        }
        while model.historyIndex > start { model.undo() }
        win.setFrame(previousFrame, display: true)
        model.mode = previousMode
    }

    private static func shots(_ model: DarkroomModel) async {
        let dir = ProcessInfo.processInfo.environment["DARKROOM_SHOTS"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String) async {
            await model.settle()
            try? await Task.sleep(for: .milliseconds(700))
            let ok = capture(to: "\(dir)/\(name).png")
            log("shot \(name): \(ok ? "written" : "FAILED")")
        }
        NSApp.activate()
        await shot("01-default")

        if let cb = model.modules.first(where: { $0.operation == "colorbalancergb" }) {
            model.select(cb)
            try? await Task.sleep(for: .milliseconds(400))
            if let f = model.schema(for: cb)?.fields.first(where: { $0.name == "contrast" }) {
                model.setParam(cb, f, to: .number(0.25))
            }
            await shot("02-colorbalance")
        }
        if let ex = model.modules.first(where: { $0.operation == "exposure" }) {
            model.select(ex)
            try? await Task.sleep(for: .milliseconds(400))
            if let f = model.schema(for: ex)?.fields.first(where: { $0.name == "exposure" }) {
                model.setParam(ex, f, to: .number(0.8))
            }
            model.blendOpen = true
            model.setBlend(ex, "mask_mode", to: .number(1), detail: "blend: uniformly")
            await shot("03-blend")
        }
        model.leftTab = .history
        await shot("04-history")
        model.leftTab = .modules
        model.scopeMode = .waveform
        await shot("05-waveform")
        model.scopeMode = .vectorscope
        await shot("06-vectorscope")
        model.scopeMode = .histogram
        model.backdrop = .neutralGrey
        await shot("07-neutral-grey")
        model.backdrop = .lightGrey
        await shot("08-light-grey")
        model.backdrop = .depthGrey
        model.viewport = CGSize(width: 1280, height: 800)
        model.zoom = .actual
        await shot("09-zoom100")
        model.zoom = .fit
        await shot("10-fit")
    }

    private static func ui(_ model: DarkroomModel) async {
        for tab in LeftTab.allCases { model.leftTab = tab; try? await Task.sleep(for: .milliseconds(200)); log("tab \(tab.rawValue)") }
        model.leftTab = .modules
        for s in ScopeMode.allCases { model.scopeMode = s; try? await Task.sleep(for: .milliseconds(200)); log("scope \(s.rawValue)") }

        if let exposure = model.modules.first(where: { $0.operation == "exposure" }),
           let f = model.schema(for: exposure)?.fields.first(where: { $0.name == "exposure" }) {
            model.select(exposure)
            model.setParam(exposure, f, to: .number(1.0))
            await model.settle()
            log("edit exposure -> \(Int(model.lastMilliseconds ?? 0)) ms")
            model.takeSnapshot()
            model.setParam(exposure, f, to: .number(-1.0))
            await model.settle()
            model.showingSnapshot = true
            await model.settle()
            model.showingSnapshot = false
            model.undo(); await model.settle()
            model.redo(); await model.settle()
            log("snapshot, undo, redo")
        }

        for z in ZoomMode.allCases {
            model.zoom = z
            await model.settle()
            try? await Task.sleep(for: .milliseconds(200))
            log("zoom \(z.rawValue) -> frame \(model.frame?.width ?? 0)x\(model.frame?.height ?? 0)")
        }
        model.zoom = .fit
        await model.settle()

        for b in BackdropStyle.presets {
            model.backdrop = b
            try? await Task.sleep(for: .milliseconds(150))
            log("backdrop \(b.name)")
        }
        model.backdrop = .depthGrey
        model.jump(to: 0)
        await model.settle()
    }
}
