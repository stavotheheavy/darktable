import AppKit
import DarktableKit
import Foundation
import Network
import ObjectiveC
import SwiftUI

/// The test rig's way into the running app. Off unless DARKROOM_RIG=<port> is set; then a
/// tiny HTTP server on 127.0.0.1 lets a script look at the accessibility tree, press and set
/// controls, send keys, switch screens, take a picture of the window and read timings. Every
/// action counts as one click so a tester can report clicks per task.
@MainActor
public final class Rig {
    static var shared: Rig?

    private let model: DarkroomModel
    private let library: LibraryModel
    private let go: (Screen) -> Void
    private let openPhoto: (String) -> Void
    private let currentScreen: () -> Screen
    private var listener: NWListener?
    private var clicks = 0
    /// Set by the library view so the rig can tell whether the compare view is showing.
    static var comparing = false
    /// Registered by the library view: opens the compare view for the selected photo.
    static var compareHook: (() -> Bool)?
    private var comparingNow: (() -> Bool)? { { Self.comparing } }

    public static func startIfRequested(model: DarkroomModel, library: LibraryModel,
                                        screen: @escaping () -> Screen, go: @escaping (Screen) -> Void,
                                        open: @escaping (String) -> Void) {
        guard let p = ProcessInfo.processInfo.environment["DARKROOM_RIG"], let port = UInt16(p), shared == nil else { return }
        let rig = Rig(model: model, library: library, screen: screen, go: go, open: open)
        shared = rig
        silenceUnhandledKeys()
        rig.listen(port: port)
    }

    /// A key the app does not handle makes AppKit beep. A test script sends hundreds, so in rig runs
    /// the beep is switched off (a person's real keystrokes in a normal run still get it).
    private static func silenceUnhandledKeys() {
        guard let m = class_getInstanceMethod(NSResponder.self, #selector(NSResponder.noResponder(for:))) else { return }
        let quiet: @convention(block) (AnyObject, Selector) -> Void = { _, _ in }
        method_setImplementation(m, imp_implementationWithBlock(quiet))
    }

    private init(model: DarkroomModel, library: LibraryModel, screen: @escaping () -> Screen,
                 go: @escaping (Screen) -> Void, open: @escaping (String) -> Void) {
        self.model = model; self.library = library; self.go = go; self.openPhoto = open; self.currentScreen = screen
    }

    // MARK: server

    private func listen(port: UInt16) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            print("rig: could not listen on \(port)"); return
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in self?.receive(conn, buffer: Data()) }
        }
        l.start(queue: .main)
        listener = l
        print("rig: listening on 127.0.0.1:\(port)")
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let (method, path, body) = Self.parse(buf) {
                Task { @MainActor in
                    let (type, payload) = await self.handle(method: method, path: path, body: body)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
                }
            } else if done || err != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// A complete request, or nil while more bytes are expected.
    private static func parse(_ d: Data) -> (String, String, Data)? {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[d.startIndex..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var length = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            length = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = d[r.upperBound...]
        guard body.count >= length else { return nil }
        return (String(first[0]), String(first[1]), Data(body.prefix(length)))
    }

    private func json(_ o: Any) -> (String, Data) {
        ("application/json", (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    private func handle(method: String, path: String, body: Data) async -> (String, Data) {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        switch (method, route) {
        case ("GET", "/state"): return json(state())
        case ("GET", "/tree"): return json(tree())
        case ("GET", "/modules"):
            return json(model.modules.map { ["id": $0.id, "op": $0.operation, "name": $0.name, "enabled": model.isEnabled($0), "params": $0.haveIntrospection] as [String: Any] })
        case ("GET", "/fingerprint"): return json(fingerprint())
        case ("GET", "/screen"): return ("image/png", screenshot() ?? Data())
        case ("POST", "/reset"): clicks = 0; return json(["ok": true])
        case ("POST", "/act"):
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            return json(await act(o))
        default: return json(["error": "unknown route \(method) \(route)"])
        }
    }

    // MARK: state

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

    private func state() -> [String: Any] {
        [
            "screen": currentScreen() == .library ? "library" : "darkroom",
            "mode": model.mode.rawValue.lowercased(),
            "file": model.fileName,
            "status": model.status,
            "uiHidden": model.uiHidden,
            "showingOriginal": model.showingOriginal,
            "canUndo": model.canUndo, "canRedo": model.canRedo,
            "historyCount": model.history.count, "historyIndex": model.historyIndex,
            "lastRenderMs": model.lastMilliseconds ?? -1,
            "zoom": model.zoom.rawValue,
            // Pro's panel, in order: the section, its first operation, effect on, unfolded
            "pro": model.proPanelEntries.map { ["name": $0.name, "op": $0.modules[0].operation,
                                                "on": model.proEffectOn($0), "open": model.proOpen.contains($0.id)] as [String: Any] },
            "curve": model.curveNodes ?? [],
            "looksOpen": UserDefaults.standard.bool(forKey: SimplePanel.looksOpenKey),
            "rssMB": Int(Self.rssMB()),
            "clicks": clicks,
            "library": ["order": library.shown.prefix(6).map { "\($0.name):\(Int($0.sharpness ?? -1))" }, "comparing": library.items.isEmpty ? false : (comparingNow?() ?? false),
                        "items": library.items.count, "scored": library.scored, "failed": library.failed,
                        "selected": library.selected ?? "",
                        "selectedRating": library.items.first { $0.path == library.selected }?.rating ?? -1,
                        "selectedRejected": library.items.first { $0.path == library.selected }?.rejected ?? false, "status": library.status],
        ]
    }

    // MARK: tree (the controls that tagged themselves with .rig)

    struct Entry { var frame: CGRect; var enabled: Bool }
    static var registry: [String: Entry] = [:]
    /// Slider setters, keyed like the registry: fraction 0...1 of the slider's range.
    static var setters: [String: (Double) -> Void] = [:]
    static let enabled = ProcessInfo.processInfo.environment["DARKROOM_RIG"] != nil
    /// Planted bugs for the testers, named in DARKROOM_CANARY (comma separated). Rig runs only.
    static func canary(_ name: String) -> Bool {
        enabled && (ProcessInfo.processInfo.environment["DARKROOM_CANARY"] ?? "").split(separator: ",").contains { $0 == name }
    }

    private var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && $0.contentView != nil } }

    private func tree() -> [String: Any] {
        let w = window?.contentView?.bounds.size ?? .zero
        let win = CGRect(origin: .zero, size: w)
        // rows inside a scrolling list stay registered when scrolled out of sight; they are only
        // audited while their centre is inside the list's visible frame
        func clip(_ key: String) -> CGRect? {
            if key.hasPrefix("param-") { return Self.registry["inspector-scroll"]?.frame }
            if (key.hasPrefix("module-") || key.hasPrefix("enable-")), key != "module-list", key != "module-search" { return Self.registry["module-list"]?.frame }
            return nil
        }
        let items = Self.registry.sorted { $0.key < $1.key }.filter { k, e in
            guard let c = clip(k) else { return true }
            return c.contains(CGPoint(x: e.frame.midX, y: e.frame.midY))
        }
        func row(_ k: String, _ e: Entry) -> [String: Any] {
            ["id": k, "enabled": e.enabled, "x": Int(e.frame.minX), "y": Int(e.frame.minY), "w": Int(e.frame.width), "h": Int(e.frame.height)]
        }
        var overlaps: [[String: Any]] = [], outside: [[String: Any]] = [], small: [[String: Any]] = [], target44: [[String: Any]] = []
        for (i, a) in items.enumerated() {
            if !win.insetBy(dx: -1, dy: -1).contains(a.value.frame) { outside.append(row(a.key, a.value)) }
            if a.value.frame.width < 24 || a.value.frame.height < 24 { small.append(row(a.key, a.value)) }
            else if a.value.frame.height < 40 { target44.append(row(a.key, a.value)) }
            // grid cells scroll beneath the floating bars on purpose, so they are not compared
            if a.key.hasPrefix("cell-") || a.key == "library" { continue }
            for b in items[(i + 1)...] {
                if b.key.hasPrefix("cell-") || b.key == "library" { continue }
                let r = a.value.frame.intersection(b.value.frame)
                if r.isNull || r.width * r.height < 16 { continue }
                if a.value.frame.contains(b.value.frame) || b.value.frame.contains(a.value.frame) { continue }
                overlaps.append(["a": row(a.key, a.value), "b": row(b.key, b.value), "area": Int(r.width * r.height)])
            }
        }
        return ["window": ["w": Int(w.width), "h": Int(w.height)], "elements": items.map { row($0.key, $0.value) },
                "audit": ["overlaps": overlaps, "outside": outside, "smallerThan24": small, "heightUnder40": target44]]
    }

    // MARK: synthetic mouse and keys, delivered to the window like a real person's

    private func point(_ p: CGPoint) -> NSPoint? {
        guard let cv = window?.contentView else { return nil }
        let local = cv.isFlipped ? NSPoint(x: p.x, y: p.y) : NSPoint(x: p.x, y: cv.bounds.height - p.y)
        return cv.convert(local, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint, n: Int = 1, queued: Bool = false) {
        guard let win = window, let pt = point(p),
              let ev = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) else { return }
        // clicks are sent straight to the window; a drag is queued because a slider's tracking loop reads the queue
        if queued { NSApp.postEvent(ev, atStart: false) } else { win.sendEvent(ev) }
    }

    /// A point in root coordinates as a screen point in CGEvent's space (origin top left of the main display).
    private func screenPoint(_ p: CGPoint) -> CGPoint? {
        guard let win = window, let cv = win.contentView, let screen = NSScreen.screens.first else { return nil }
        let local = cv.isFlipped ? NSPoint(x: p.x, y: p.y) : NSPoint(x: p.x, y: cv.bounds.height - p.y)
        let inWin = cv.convert(local, to: nil)
        let onScreen = win.convertPoint(toScreen: inWin)
        return CGPoint(x: onScreen.x, y: screen.frame.height - onScreen.y)
    }

    private func hid(_ type: CGEventType, _ p: CGPoint) {
        guard let sp = screenPoint(p), let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: sp, mouseButton: .left) else { return }
        ev.post(tap: .cghidEventTap)
    }

    private func hidDrag(from a: CGPoint, to b: CGPoint) async {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        hid(.mouseMoved, a); try? await Task.sleep(for: .milliseconds(60))
        hid(.leftMouseDown, a); try? await Task.sleep(for: .milliseconds(80))
        for s in 1...12 {
            let t = CGFloat(s) / 12
            hid(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(for: .milliseconds(30))
        }
        hid(.leftMouseUp, b); try? await Task.sleep(for: .milliseconds(100))
    }

    private func click(_ p: CGPoint, count: Int = 1) async {
        // a window of an inactive app ignores clicks, as it would for a person
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(120))
        // move the pointer there first: SwiftUI controls only press after the pointer has entered them
        mouse(.mouseMoved, at: p)
        try? await Task.sleep(for: .milliseconds(80))
        for i in 1...count {
            mouse(.leftMouseDown, at: p, n: i)
            try? await Task.sleep(for: .milliseconds(40))
            mouse(.leftMouseUp, at: p, n: i)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    private func drag(from a: CGPoint, to b: CGPoint) async {
        window?.makeKeyAndOrderFront(nil)
        mouse(.leftMouseDown, at: a, queued: true)
        try? await Task.sleep(for: .milliseconds(60))
        for s in 1...10 {
            let t = CGFloat(s) / 10
            mouse(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), queued: true)
            try? await Task.sleep(for: .milliseconds(40))
        }
        mouse(.leftMouseUp, at: b, queued: true)
        try? await Task.sleep(for: .milliseconds(80))
    }

    // MARK: actions

    private func act(_ o: [String: Any]) async -> [String: Any] {
        clicks += 1
        var result: [String: Any] = ["ok": false]
        if let key = o["click"] as? String {
            guard let e = Self.registry[key] else { return ["ok": false, "error": "no control tagged \(key)"] }
            let c = CGPoint(x: e.frame.midX, y: e.frame.midY)
            await click(c, count: (o["count"] as? Int) ?? 1)
            result = ["ok": true, "clicked": key, "enabled": e.enabled, "at": [Int(c.x), Int(c.y)]]
        } else if let xy = o["clickAt"] as? [Double], xy.count == 2 {
            await click(CGPoint(x: xy[0], y: xy[1])); result = ["ok": true]
        } else if let ui = o["ui"] as? String {
            // header toggles at model level (synthetic single clicks are dropped by SwiftUI controls)
            switch ui {
            case "hide": model.uiHidden.toggle()
            case "original": if model.history.count > 1 { model.showingOriginal.toggle() }
            case "back": go(.library); library.paused = false
            default:
                if ui.hasPrefix("zoom:"), let z = ZoomMode.allCases.first(where: { $0.rawValue == String(ui.dropFirst(5)) }) { model.zoom = z }
                else { return ["ok": false, "error": "unknown ui action"] }
            }
            result = ["ok": true]
        } else if let lib = o["library"] as? String {
            // model-level library actions: select:<path>, sort, stacks, compare, rate:<n>, reject
            let parts = lib.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "select": if parts.count > 1 { library.selected = library.items.first { $0.path == parts[1] || $0.name == parts[1] }?.path ?? library.selected }
            case "sort": library.sharpestFirst.toggle()
            case "stacks": library.groupStacks.toggle()
            case "compare": result = ["ok": Self.compareHook?() ?? false]; return result
            case "rate": if parts.count > 1, let n = Int(parts[1]), let sel = library.selected { library.setRating(n, for: sel) }
            case "reject": if let sel = library.selected { library.toggleReject(sel) }
            default: return ["ok": false, "error": "unknown library action"]
            }
            result = ["ok": true, "selected": library.selected ?? ""]
        } else if let pro = o["pro"] as? String {
            // model-level Pro actions (native menus cannot be clicked by the rig):
            // add|remove|power|fold <op>, preset <look id>, history <index>, curve <node 0-4> <0..1>
            let parts = pro.split(separator: " ").map(String.init)
            let entry = parts.count > 1 ? model.proMenu.flatMap(\.entries).first { $0.modules.contains { $0.operation == parts[1] } } : nil
            switch parts.first ?? "" {
            case "add": guard let e = entry else { return ["ok": false, "error": "no module \(parts.dropFirst().joined())"] }; model.addToPanel(e)
            case "remove": guard let e = entry else { return ["ok": false, "error": "no module \(parts.dropFirst().joined())"] }; model.removeFromPanel(e)
            case "power": guard let e = entry, model.inProPanel(e) else { return ["ok": false, "error": "not in the panel"] }; model.toggleProEffect(e)
            case "fold": guard let e = entry else { return ["ok": false, "error": "no module"] }; model.toggleProFold(e)
            case "preset": guard parts.count > 1, let look = SimpleLook.all.first(where: { $0.id == parts[1] }) else { return ["ok": false, "error": "no look"] }; model.apply(look)
            case "history": guard parts.count > 1, let i = Int(parts[1]), model.history.indices.contains(i) else { return ["ok": false, "error": "no step"] }; model.jump(to: i)
            case "curve": guard parts.count > 2, let i = Int(parts[1]), let y = Double(parts[2]) else { return ["ok": false, "error": "curve <node> <0..1>"] }; model.setCurveNode(i, y)
            default: return ["ok": false, "error": "unknown pro action"]
            }
            result = ["ok": true, "panel": model.proPanelEntries.map(\.name)]
        } else if let id = o["select"] as? String {
            guard let m = model.modules.first(where: { $0.id == id || $0.operation == id }) else { return ["ok": false, "error": "no module \(id)"] }
            model.select(m); result = ["ok": true, "selected": m.id]
        } else if let key = o["slide"] as? String, let frac = o["to"] as? Double {
            guard let set = Self.setters[key] else { return ["ok": false, "error": "no slider tagged \(key)"] }
            set(min(1, max(0, frac))); result = ["ok": true, "slid": key, "to": frac]
        } else if let key = o["drag"] as? String, let v = o["to"] as? Double {
            guard let e = Self.registry[key] else { return ["ok": false, "error": "no control tagged \(key)"] }
            let from = CGFloat((o["from"] as? Double) ?? 0.5), to = CGFloat(v)
            let y = e.frame.midY
            let a = CGPoint(x: e.frame.minX + e.frame.width * from, y: y), b = CGPoint(x: e.frame.minX + e.frame.width * to, y: y)
            if (o["hid"] as? Bool) == true { await hidDrag(from: a, to: b) } else { await drag(from: a, to: b) }
            result = ["ok": true, "dragged": key]
        } else if let k = o["key"] as? String, let win = window {
            var mods: NSEvent.ModifierFlags = []
            if (o["cmd"] as? Bool) == true { mods.insert(.command) }
            if (o["shift"] as? Bool) == true { mods.insert(.shift) }
            // named keys carry the character and key code a real keyboard sends
            let named: [String: (String, UInt16)] = [
                "return": ("\r", 36), "escape": ("\u{1B}", 53), "tab": ("\t", 48), "space": (" ", 49),
                "left": ("\u{F702}", 123), "right": ("\u{F703}", 124), "up": ("\u{F700}", 126), "down": ("\u{F701}", 125)]
            let (chars, code) = named[k.lowercased()] ?? (k, 0)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: win.windowNumber, context: nil, characters: chars,
                                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(ev, atStart: false)
                }
            }
            result = ["ok": true, "key": k]
        } else if let p = o["open"] as? String {
            // waits for the photo to be developed, so a script can time open to first frame honestly
            let t0 = Date()
            library.selected = p
            go(.darkroom)
            await model.open(path: p)
            await model.settle()
            result = ["ok": true, "openMs": Int(Date().timeIntervalSince(t0) * 1000), "lastRenderMs": model.lastMilliseconds ?? -1,
                      "hasFrame": model.frame != nil]
        } else if let s = o["screen"] as? String {
            go(s == "library" ? .library : .darkroom); result = ["ok": true]
        } else if let m = o["mode"] as? String {
            model.mode = m == "simple" ? .simple : .pro; result = ["ok": true]
        } else if let size = o["resize"] as? [Double], size.count == 2, let win = window {
            win.setContentSize(NSSize(width: size[0], height: size[1])); result = ["ok": true]
        } else if o["undo"] != nil {
            model.undo(); result = ["ok": true]
        } else if o["redo"] != nil {
            model.redo(); result = ["ok": true]
        } else if o["settle"] != nil {
            let t0 = Date()
            await model.settle()
            result = ["ok": true, "lastRenderMs": model.lastMilliseconds ?? -1, "waitedMs": Int(Date().timeIntervalSince(t0) * 1000), "hasFrame": model.frame != nil]
        } else if let key = o["folder"] as? String {
            library.load(folder: URL(fileURLWithPath: key)); result = ["ok": true]
        } else {
            clicks -= 1
            result = ["ok": false, "error": "unknown action"]
        }
        return result
    }

    /// A hash of the developed frame (128 by 128, all three channels), so a script can say
    /// "this picture is byte-for-byte the one from before" without decoding a PNG.
    private func fingerprint() -> [String: Any] {
        guard let f = model.frame else { return ["hash": "none"] }
        let w = 128, h = 128
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(f, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var hsh: UInt64 = 0xcbf29ce484222325
        var sum = 0
        for (i, b) in px.enumerated() where i % 4 != 3 { hsh = (hsh ^ UInt64(b)) &* 0x100000001b3; sum += Int(b) }
        return ["hash": String(hsh, radix: 16), "mean": Double(sum) / Double(w * h * 3), "w": f.width, "h": f.height]
    }

    private func screenshot() -> Data? {
        guard let win = window else { return nil }
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Create.self)
        guard let img = fn(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(win.windowNumber),
                           CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

/// Tags a control for the rig: its on-screen frame and whether it is enabled are recorded, so a
/// script can click it by name and the audit can look for overlaps. It is also the control's
/// accessibility identifier. Costs nothing when the rig is off.
struct RigTag: ViewModifier {
    let id: String
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if Rig.enabled {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("rigRoot")) }) { Rig.registry[id] = .init(frame: $0, enabled: isEnabled) }
                .onChange(of: isEnabled) { _, now in Rig.registry[id]?.enabled = now }
                .onDisappear { Rig.registry[id] = nil }
                .accessibilityIdentifier(id)
        } else {
            content.accessibilityIdentifier(id)
        }
    }
}

extension View {
    func rig(_ id: String) -> some View { modifier(RigTag(id: id)) }
}
