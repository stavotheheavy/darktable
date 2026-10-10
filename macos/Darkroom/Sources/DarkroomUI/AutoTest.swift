import DarktableKit
import Foundation
import SwiftUI

/// A scripted run inside the real app, switched on by DARKROOM_AUTOTEST. It drives the
/// model the way a person would, so the actual views render for every module, and it
/// logs one line per step so a crash shows exactly where it happened.
///
///   DARKROOM_AUTOTEST=modules   select each module, switch it on, render, reset
///   DARKROOM_AUTOTEST=ui        tabs, scopes, zoom, snapshot, undo, backgrounds
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
