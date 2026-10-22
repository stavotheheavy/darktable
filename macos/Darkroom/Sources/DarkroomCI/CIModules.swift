import CoreImage
import DarkroomCore
import DarkroomEngineAPI
import DarkroomMetal

/// One edit the clean engine can apply: its parameter schema, defaults and the Core Image
/// filter chain it runs. Written from Apple's Core Image filter documentation only.
struct CIModule: Sendable {
    let operation: String
    let name: String
    /// Pipeline position; lower runs first.
    let iopOrder: Int
    let defaultEnabled: Bool
    let fields: [FieldSchema]
    /// Applies the module to `image` with `values`, keyed by field name.
    let apply: @Sendable (CIImage, [String: Double]) throws -> CIImage
    /// Wants the decoder's scene-linear output (no boost tone curve) when enabled.
    var sceneReferred = false
    /// The modules whose work is one pixel in, one pixel out, on our own Metal functions: a run of them is one pass over the frame
    /// (see MetalFused). The engine fuses them when they are unmasked and at full opacity.
    static let fusableOperations: Set<String> = [
        "temperature", "exposure", "colorbalancergb", "tonecurve", "monochrome", "rgblevels", "splittoning", "display", "invert", "colorzones", "satcurvergb", "colorbalance", "dither", "solarize", "negadoctor", "lowlight", "channelmixerrgb",
        "gradientmap", "bleachbypass", "channelcurves", "chromalimit", "warmth",
        "highlightrolloff", "lumabands", "lumacurve", "scurve", "colorharmonizer", "selectivecolor", 
    ]

    /// The fused op a fusable module stands for with these values, or nil when the module does nothing at them. This is the one place the
    /// module's settings become kernel uniforms: the module's own `apply` (used when it is masked or partly faded) goes through here too.
    static func fusedOp(_ operation: String, _ v: [String: Double]) -> FusedOp? {
        switch operation {
        case "temperature":
            let g = SIMD3(v["red"] ?? 1, v["green"] ?? 1, v["blue"] ?? 1)
            return g == SIMD3(1, 1, 1) ? nil : FusedOp(.gain, [Float(g.x), Float(g.y), Float(g.z)])
        case "exposure":
            let g = Float(Exposure.gain(ev: v["exposure"] ?? 0))
            return g == 1 ? nil : FusedOp(.gain, [g, g, g])
        case "colorbalancergb":
            let u = [Float(v["contrast"] ?? 0), Float(v["saturation_global"] ?? 0), Float(v["vibrance"] ?? 0)]
            let brightness = v["brightness"] ?? 0
            if brightness != 0 { return FusedOp(.colisa, u + [Float(Colisa.gain(brightness: brightness))]) }
            return u.allSatisfy { $0 == 0 } ? nil : FusedOp(.colorBalance, u)
        case "tonecurve":
            let n = Int((v["n"] ?? 0).rounded())
            let points: (xs: [Double], ys: [Double])
            if n >= 2 {
                let count = min(n, ToneCurve.maxPoints)
                points = ToneCurve.sanitized(xs: (0..<count).map { v["x\($0)"] ?? 1 }, ys: (0..<count).map { v["y\($0)"] ?? 1 })
            } else {
                points = ToneCurve.sanitized(xs: ToneCurve.legacyXs, ys: [v["y0"] ?? 0, v["y1"] ?? 0.25, v["y2"] ?? 0.5, v["y3"] ?? 0.75, v["y4"] ?? 1])
            }
            return FusedOp(.toneCurve, ToneCurve.uniforms(xs: points.xs, ys: points.ys))
        case "monochrome":
            let intensity = v["intensity"] ?? 0
            guard intensity > 0 else { return nil }
            if v["method"] == 1 { return FusedOp(.bwMixer, [Float(v["red"] ?? 0.263), Float(v["green"] ?? 0.678), Float(v["blue"] ?? 0.059), Float(intensity)]) }
            let hue = (v["filter_hue"] ?? 30) * .pi / 180
            return FusedOp(.monochrome, [Float(intensity), Float(v["filter_strength"] ?? 0), Float(cos(hue)), Float(sin(hue))])
        case "invert":
            return FusedOp(.invert, [])
        case "colorzones":
            let u: [Float] = ["hue", "sat", "light"].flatMap { kind in ColorZones.bandNames.map { Float(v["\($0)_\(kind)"] ?? 0) } }
            return u.allSatisfy { $0 == 0 } ? nil : FusedOp(.colorZones, u)
        case "satcurvergb":
            let u = [Float(v["shadows"] ?? 0), Float(v["mids"] ?? 0), Float(v["highlights"] ?? 0)]
            return u.allSatisfy { $0 == 0 } ? nil : FusedOp(.satCurve, u)
        case "colorbalance":
            let t = LiftGammaGain.terms(v)
            let u: [Float] = [t.slope, t.offset, t.power].flatMap { [Float($0.x), Float($0.y), Float($0.z)] }
            return u == [1, 1, 1, 0, 0, 0, 1, 1, 1] ? nil : FusedOp(.liftGammaGain, u)
        case "dither":
            return FusedOp(.posterize, [Float(max((v["levels"] ?? 64).rounded(), 2) - 1)])
        case "solarize":
            let strength = v["strength"] ?? 0
            return strength == 0 ? nil : FusedOp(.solarize, [Float(v["threshold"] ?? 0.5), Float(strength)])
        case "negadoctor":
            return FusedOp(.negadoctor, [Float(v["dmin_r"] ?? 0.8), Float(v["dmin_g"] ?? 0.5), Float(v["dmin_b"] ?? 0.35),
                                         Float(v["gamma"] ?? 1.6), Float(v["exposure"] ?? 0.2), Float(v["black"] ?? 0)])
        case "lowlight":
            let strength = v["strength"] ?? 0
            return strength == 0 ? nil : FusedOp(.lowLight, [Float(strength)])
        case "channelmixerrgb":
            let names = ["red_r", "red_g", "red_b", "green_r", "green_g", "green_b", "blue_r", "blue_g", "blue_b"]
            let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
            let rows = (0..<3).map { r in (0..<3).map { c in v[names[r * 3 + c]] ?? identity[r * 3 + c] } }
            let m = ChannelMixerRGB.matrix(kelvin: v["temperature"] ?? 6500, strength: v["strength"] ?? 0, rows: rows)
            let u = m.flatMap { $0 }.map { Float($0) }
            return u == identity.map { Float($0) } ? nil : FusedOp(.channelMixer, u)
        case "gradientmap":
            let strength = v["strength"] ?? 0
            guard strength != 0 else { return nil }
            let stops = [GradientMap.stop(hueDegrees: v["shadows_hue"] ?? 230, saturation: v["shadows_sat"] ?? 0.7),
                         GradientMap.stop(hueDegrees: v["mids_hue"] ?? 0, saturation: v["mids_sat"] ?? 0),
                         GradientMap.stop(hueDegrees: v["highlights_hue"] ?? 60, saturation: v["highlights_sat"] ?? 0.6)]
            return FusedOp(.gradientMap, [Float(strength)] + stops.flatMap { [Float($0.x), Float($0.y)] })
        case "bleachbypass":
            let strength = v["strength"] ?? 0
            return strength == 0 ? nil : FusedOp(.bleachBypass, [Float(strength)])
        case "channelcurves":
            let identity: [Double] = [0.25, 0.5, 0.75, 0.25, 0.5, 0.75, 0.25, 0.5, 0.75]
            let heights = ChannelCurves.channels.flatMap { c in (1...3).map { v["\(c)_y\($0)"] ?? identity[$0 - 1] } }
            return heights == identity ? nil : FusedOp(.channelCurves, ChannelCurves.uniforms(heights: heights))
        case "chromalimit":
            let limit = v["limit"] ?? ChromaLimit.off
            return limit >= ChromaLimit.off ? nil : FusedOp(.chromaLimit, [Float(limit)])
        case "warmth":
            if v["method"] == 1 {
                let density = v["density"] ?? 0
                guard density != 0 else { return nil }
                let gain = LiftGammaGain.tint(hueDegrees: v["hue"] ?? 45, strength: 1)
                return FusedOp(.photoFilter, [Float(gain.x), Float(gain.y), Float(gain.z), Float(density), Float(v["preserve"] ?? 1)])
            }
            let u = [Float(v["warmth"] ?? 0), Float(v["tint"] ?? 0)]
            return u.allSatisfy { $0 == 0 } ? nil : FusedOp(.warmth, u)
        case "highlightrolloff":
            let amount = v["amount"] ?? 0
            guard amount != 0 else { return nil }
            if v["curve"] == 1 { return FusedOp(.reinhard, [Float(v["white"] ?? 4), Float(amount)]) }
            return FusedOp(.highlightRolloff, [Float(v["white"] ?? 1), Float(v["knee"] ?? 0.7), Float(amount)])
        case "lumabands":
            let u = LumaBands.names.map { Float(v[$0] ?? 0) }
            return u.allSatisfy { $0 == 0 } ? nil : FusedOp(.lumaBands, u)
        case "lumacurve":
            let ys: [Double] = [v["y0"] ?? 0, v["y1"] ?? 0.25, v["y2"] ?? 0.5, v["y3"] ?? 0.75, v["y4"] ?? 1]
            if ys == [0, 0.25, 0.5, 0.75, 1] { return nil }
            let p = ToneCurve.sanitized(xs: ToneCurve.legacyXs, ys: ys)
            return FusedOp(.lumaCurve, ToneCurve.uniforms(xs: p.xs, ys: p.ys))
        case "scurve":
            let contrast = v["contrast"] ?? 0
            return contrast == 0 ? nil : FusedOp(.sCurve, [Float(SCurve.exponent(contrast: contrast)), Float(v["pivot"] ?? 0.5)])
        case "colorharmonizer":
            let amount = v["amount"] ?? 0
            guard amount != 0 else { return nil }
            let sch = ColorHarmony.scheme(Int((v["scheme"] ?? 0).rounded()), baseDegrees: v["base"] ?? 0)
            let hues = (sch.hues + [0, 0, 0, 0]).prefix(4).map { Float($0) }
            return FusedOp(.colorHarmony, [Float(sch.hues.count)] + hues + [Float(sch.halfGap), Float(amount)])
        case "selectivecolor":
            let u: [Float] = SelectiveColor.families.flatMap { f in SelectiveColor.inks.map { Float(v["\(f)_\($0)"] ?? 0) } }
            return u.allSatisfy { $0 == 0 } ? nil : FusedOp(.selectiveColor, u)
        case "rgblevels":
            let black = v["black"] ?? 0
            let white = max(v["white"] ?? 1, black + 0.01)
            let grey = min(max(v["grey"] ?? 0.5, 0.01), 0.99)
            return FusedOp(.levels, [Float(black), Float(white), Float(log(0.5) / log(grey))])
        case "splittoning":
            let pivot = 0.5 + 0.25 * (v["balance"] ?? 0)
            let sh = (v["shadows_hue"] ?? 220) * .pi / 180, hh = (v["highlights_hue"] ?? 60) * .pi / 180
            let ss = 0.08 * (v["shadows_saturation"] ?? 0), hs = 0.08 * (v["highlights_saturation"] ?? 0)
            return FusedOp(.splitToning, [pivot, ss * cos(sh), ss * sin(sh), hs * cos(hh), hs * sin(hh)].map { Float($0) })
        case "display":
            // the module's own lift is a gain on the input, inside the tone kernel
            let lift = Exposure.gain(ev: v["exposure"] ?? 0)
            let tone = SceneTone(contrast: v["contrast"] ?? 0, whiteEV: v["white"] ?? SceneTone.defaultWhiteEV,
                                 purity: v["purity"] ?? SceneTone.defaultPurity, peak: v["peak"] ?? 1,
                                 target: OutputGamut(rawValue: Int(v["_target"] ?? 0)) ?? .sRGB)
            return FusedOp(.sceneTone, tone.uniforms(gain: SIMD3(repeating: lift)))
        default:
            return nil
        }
    }

    /// A remap module's picture: the warp, magnified by the smallest zoom that keeps every edge pixel inside the frame when `fill` is on.
    static func applyRemap(_ image: CIImage, _ kind: Remap.Kind, fill: Double) throws -> CIImage {
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        return try CIBridge.remap(image, kind: kind, zoom: fill >= 0.5 ? Remap.fillScale(kind, width: w, height: h) : 1)
    }

    /// A fusable module on its own (masked, partly faded, or the only one in its run): the same op through the same kernel.
    static func applyFused(_ operation: String, _ image: CIImage, _ v: [String: Double]) throws -> CIImage {
        let ops = fusedOps(operation, v)
        guard !ops.isEmpty else { return image }
        return try CIBridge.fused(image, ops: ops)
    }

    /// Every fused op a module stands for: a merged module runs the kernels of the modules it absorbed before or after its own, in the
    /// pipeline order those modules had, so an old edit folded into it renders the same. The engine's fused pass takes the list as is.
    static func fusedOps(_ operation: String, _ v: [String: Double]) -> [FusedOp] {
        var ops: [FusedOp] = []
        switch operation {
        case "colorzones":   // hue rotate (was iopOrder 17) ran before the bands (24)
            let degrees = v["hue_all"] ?? 0
            if degrees != 0 { let t = degrees * .pi / 180; ops.append(FusedOp(.hueRotate, [Float(cos(t)), Float(sin(t))])) }
        case "lumabands":    // fill light (26) ran before the bands (39)
            let ev = v["ev"] ?? 0
            if ev != 0 { ops.append(FusedOp(.relight, [Float(ev), Float(v["center"] ?? -1), Float(v["width"] ?? 4)])) }
        default: break
        }
        if let own = fusedOp(operation, v) { ops.append(own) }
        switch operation {
        case "rgblevels":    // base curve (34) ran after levels (33); fade (67) last
            let gamma = v["gamma"] ?? 1
            if gamma != 1 { ops.append(FusedOp(.baseCurve, [Float(gamma)])) }
            let black = v["fade_black"] ?? 0, white = v["fade_white"] ?? 0
            if black != 0 || white != 0 { ops.append(FusedOp(.fadeLook, [Float(black), Float(white)])) }
        case "channelcurves":   // cross process (57) ran after the curves (37)
            let amount = v["cross_process"] ?? 0
            if amount != 0 { ops.append(FusedOp(.crossProcess, [Float(amount)])) }
        default: break
        }
        return ops
    }

    /// A choice field: the option's `value` is what `values(from:)` hands the module.
    static func choice(_ name: String, _ description: String, _ initial: String, _ options: [(String, Int, String)]) -> FieldSchema {
        FieldSchema(name: name, description: description, kind: .enumeration, min: 0, max: 0, defaultValue: .option(initial),
                    options: options.map { EnumOption(name: $0.0, value: $0.1, label: $0.2) })
    }

    // MARK: aliases: the modules folded into another (merge of 2026-10-22)

    /// An operation that no longer exists on its own: the survivor it became a setting of, its old name (the Library's presets will
    /// carry it), and how its old parameters become the survivor's. An old sidecar, an old check stack or a `--stack` file that names
    /// it renders exactly as before, through the survivor.
    struct CIAlias: Sendable {
        let survivor: String
        let name: String
        let map: @Sendable ([String: ParamValue]) -> [String: ParamValue]
    }

    static let aliases: [String: CIAlias] = {
        @Sendable func n(_ p: [String: ParamValue], _ k: String, _ d: Double) -> Double { p[k]?.double ?? d }
        @Sendable func num(_ d: Double) -> ParamValue { .number(d) }
        var a: [String: CIAlias] = [:]
        a["colisa"] = CIAlias(survivor: "colorbalancergb", name: "contrast brightness saturation") { p in
            ["contrast": num(n(p, "contrast", 0)), "brightness": num(n(p, "brightness", 0)), "saturation_global": num(n(p, "saturation", 0))] }
        a["velvia"] = CIAlias(survivor: "colorbalancergb", name: "velvia") { p in ["vibrance": num(n(p, "strength", 0))] }
        a["colorcontrast"] = CIAlias(survivor: "colorbalancergb", name: "color contrast") { p in ["saturation_global": num(n(p, "saturation", 0))] }
        a["colorcorrection"] = CIAlias(survivor: "colorbalancergb", name: "color correction") { p in
            ["brightness": num(n(p, "brightness", 0)), "contrast": num(n(p, "contrast", 0))] }
        a["rgbcurve"] = CIAlias(survivor: "tonecurve", name: "rgb curve") { p in
            var out: [String: ParamValue] = ["n": num(0)]
            for (i, d) in [0, 0.25, 0.5, 0.75, 1].enumerated() { out["y\(i)"] = num(n(p, "y\(i)", d)) }
            return out }
        a["basecurve"] = CIAlias(survivor: "rgblevels", name: "base curve (gamma)") { p in ["gamma": num(n(p, "gamma", 1))] }
        a["fadelook"] = CIAlias(survivor: "rgblevels", name: "fade") { p in ["fade_black": num(n(p, "black", 0)), "fade_white": num(n(p, "white", 0))] }
        a["channelmixer"] = CIAlias(survivor: "channelmixerrgb", name: "channel mixer (plain)") { p in
            var out: [String: ParamValue] = ["strength": num(0), "temperature": num(6500)]
            for (i, k) in ["red_r", "red_g", "red_b", "green_r", "green_g", "green_b", "blue_r", "blue_g", "blue_b"].enumerated() { out[k] = num(n(p, k, i % 4 == 0 ? 1 : 0)) }
            return out }
        a["bwmixer"] = CIAlias(survivor: "monochrome", name: "black and white mixer") { p in
            ["method": .option("weights"), "intensity": num(n(p, "amount", 0)), "red": num(n(p, "red", 0.263)), "green": num(n(p, "green", 0.678)), "blue": num(n(p, "blue", 0.059))] }
        // colorize is the gradient map with one tint on every stop: Colorize.chroma / GradientMap.chroma of saturation (core-check GMP-CZ)
        a["colorize"] = CIAlias(survivor: "gradientmap", name: "colorize") { p in
            let hue = n(p, "hue", 0) * 360, sat = Colorize.chroma / GradientMap.chroma
            return ["strength": num(n(p, "strength", 0)), "shadows_hue": num(hue), "mids_hue": num(hue), "highlights_hue": num(hue),
                    "shadows_sat": num(sat), "mids_sat": num(sat), "highlights_sat": num(sat)] }
        a["photofilter"] = CIAlias(survivor: "warmth", name: "photo filter") { p in
            ["method": .option("filter"), "hue": num(n(p, "hue", 45)), "density": num(n(p, "density", 0)), "preserve": num(n(p, "preserve", 1))] }
        a["huerotate"] = CIAlias(survivor: "colorzones", name: "hue rotate") { p in ["hue_all": num(n(p, "degrees", 0))] }
        a["crossprocess"] = CIAlias(survivor: "channelcurves", name: "cross process") { p in ["cross_process": num(n(p, "amount", 0))] }
        a["reinhard"] = CIAlias(survivor: "highlightrolloff", name: "Reinhard tone") { p in
            ["curve": .option("reinhard"), "white": num(n(p, "white", 4)), "amount": num(n(p, "amount", 0))] }
        a["relight"] = CIAlias(survivor: "lumabands", name: "fill light") { p in
            ["ev": num(n(p, "ev", 0)), "center": num(n(p, "center", -1)), "width": num(n(p, "width", 4))] }
        a["shadhi"] = CIAlias(survivor: "zones", name: "shadows and highlights") { p in
            ["shadows": num(n(p, "shadows", 0) / Shadhi.sliderPerEV), "highlights": num(n(p, "highlights", 0) / Shadhi.sliderPerEV)] }
        return a
    }()

    /// The stack with every aliased entry rewritten onto its survivor (blend and enabled kept).
    static func resolve(_ stack: [StackEntry]) -> [StackEntry] {
        stack.map { e in
            guard let a = aliases[e.operation] else { return e }
            return StackEntry(operation: a.survivor, params: a.map(e.params), blend: e.blend, enabled: e.enabled)
        }
    }

    /// Modules that read a neighbourhood (a blur radius, a guided filter, wavelet levels): the expensive ones. The segment cache keeps
    /// the picture after each of them, so a slider moved further down the stack does not run them again.
    static let neighbourhoodOperations: Set<String> = [
        "sharpen", "denoiseprofile", "bilat", "atrous", "hazeremoval", "zones", "clahe", "soften", "blurs", "lowpass", "censorize", "highpass", "hdrtone", "deconvsharp", "chromadenoise", "mediandenoise", "deband", "skinsmooth", "texturebands", "halation", "caradial", "distortion", "perspective", "tiltshift", "defringe", "surfaceblur", "lensblur", "motionblur", "radialblur", "diffuse", "kuwahara", "nlmeans", "bilateral", "emboss", "sketch", "halftone", "retouch", "bloom", "highlights",
    ]

    /// The display-referred modules: they assume 0...1 values (a curve, levels, a contrast about 0.5, a lift of the shadows) and are
    /// only meaningful on display light, so with a scene-referred module on they run after it. Every other module is scene-referred
    /// (a gain, a colour balance, white balance, neighbourhood filters, vignette, masks) and runs before the display transform.
    /// `invert` is raw-level negative inversion and stays early; `bloom` is glow from over-bright light, a scene-light effect. Checked, module by module, by darkroom-engine-check E-DOM.
    static let displayReferredOperations: Set<String> = [
        "tonecurve", "rgblevels", "dither", "clahe", "splittoning", "solarize", "grain", "highpass", "bleachbypass", "channelcurves", "lumacurve", "scurve",
        // a negative is of what is on screen: complemented before the tone map, the dark scene values come out bright and the picture washes out
        "invert",
    ]
    /// Goes up whenever the module's maths changes. Saved with an edit (the sidecar), so a later app can tell the picture
    /// would now look different; darkroom-engine-check's golden images (T11) fail until the new version has goldens.
    var algorithmVersion = 1
    /// Geometry (flip, straighten, crop): skipped by the per-pixel loop, applied once by `CIGeometry`.
    var geometry = false

    func defaultValue(_ field: String) -> Double? {
        fields.first { $0.name == field }?.defaultValue.double
    }

    /// The numeric value of each field: from the stack entry, else the field's default. The engine adds `_scale` (the
    /// render's size against native pixels) for modules whose radii are full-resolution pixels.
    func values(from params: [String: ParamValue]) -> [String: Double] {
        var out: [String: Double] = [:]
        for f in fields {
            // a choice field hands the module its option's value (its default option's when unset or unknown)
            if f.kind == .enumeration {
                let name = params[f.name]?.option ?? f.defaultValue.option
                out[f.name] = Double(f.options.first { $0.name == name }?.value ?? f.options.first?.value ?? 0)
                continue
            }
            let fallback = f.defaultValue.double ?? 0
            var v = params[f.name]?.double ?? fallback
            // params come from sidecars and history: a value that is not a number falls back to the default, and a
            // number outside the field's range is held to it (modules turn radii into loop counts and buffer sizes)
            if !v.isFinite { v = fallback }
            if (f.kind == .float || f.kind == .int), f.min < f.max { v = Swift.min(Swift.max(v, f.min), f.max) }
            out[f.name] = v
        }
        return out
    }
}

extension CIModule {
    /// Every module the clean engine knows, in pipeline order.
    static let catalogue: [CIModule] = [
        // White balance as per-channel gains on the decoded linear image, named as darktable
        // names them (red, green, blue coefficients). 1.0 leaves the image unchanged.
        CIModule(
            operation: "temperature", name: "white balance", iopOrder: 10, defaultEnabled: true,
            fields: [
                FieldSchema(name: "red", description: "red", kind: .float,
                            min: 0, max: 8, defaultValue: .number(1), options: []),
                FieldSchema(name: "green", description: "green", kind: .float,
                            min: 0, max: 8, defaultValue: .number(1), options: []),
                FieldSchema(name: "blue", description: "blue", kind: .float,
                            min: 0, max: 8, defaultValue: .number(1), options: []),
            ],
            // the oracle-checked gain kernel (darkroom-metal-check B2, darkroom-engine-check E1)
            apply: { image, v in try CIModule.applyFused("temperature", image, v) }),

        // Colour balance in OkLab: contrast, global saturation and vibrance, the fields Simple's
        // Contrast and Color sliders write. ColorBalance in DarkroomCore is the oracle, and the
        // per-pixel kernel is checked against it (darkroom-engine-check E-CB).
        CIModule(
            operation: "colorbalancergb", name: "contrast and saturation", iopOrder: 25,
            defaultEnabled: false,
            fields: [
                FieldSchema(name: "vibrance", description: "vibrance", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
                FieldSchema(name: "contrast", description: "contrast", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
                FieldSchema(name: "saturation_global", description: "global saturation", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
                // brightness is contrast brightness saturation's third slider: an exposure gain of 2^(2b) after the colour step (the colisa kernel)
                field("brightness", -1, 1, 0),
            ],
            apply: { image, v in try CIModule.applyFused("colorbalancergb", image, v) }),

        // Exposure in stops, applied as a gain on linear light.
        CIModule(
            operation: "exposure", name: "exposure", iopOrder: 20, defaultEnabled: false,
            fields: [
                FieldSchema(name: "exposure", description: "exposure", kind: .float,
                            min: -18, max: 18, defaultValue: .number(0), options: []),
            ],
            // DarkroomCore's Exposure.gain on the oracle-checked gain kernel (darkroom-engine-check E2)
            apply: { image, v in try CIModule.applyFused("exposure", image, v) }),

        // Two-dimensional unsharp mask on the square root of luminance: amount and the radius it works over.
        CIModule(
            operation: "sharpen", name: "sharpen", iopOrder: 30, defaultEnabled: false,
            fields: [
                FieldSchema(name: "amount", description: "amount", kind: .float,
                            min: 0, max: 2, defaultValue: .number(0.4), options: []),
                FieldSchema(name: "radius", description: "radius", kind: .float,
                            min: 0.5, max: 8, defaultValue: .number(1.5), options: []),
            ],
            apply: { image, v in
                try CIBridge.sharpen2D(image, amount: v["amount"] ?? 0.4, radius: (v["radius"] ?? 1.5) * (v["_scale"] ?? 1))
            }),

        // Wavelet noise reduction: luminance and colour strength, each 0...1. Zero is off, and both zero is the identity
        // (darkroom-core-check NR1, darkroom-engine-check E-NR). DarkroomCore's NoiseReduction is the oracle.
        CIModule(
            operation: "denoiseprofile", name: "noise reduction", iopOrder: 5,
            defaultEnabled: false,
            fields: [
                field("luma", 0, 1, 0),
                field("chroma", 0, 1, 0),
            ],
            apply: { image, v in
                try CIBridge.noiseReduction(image, luma: (v["luma"] ?? 0) * (v["_scale"] ?? 1), chroma: (v["chroma"] ?? 0) * (v["_scale"] ?? 1))
            }),

        // Tone curve: five nodes across the tonal range; the identity curve has each node at
        // its own input value.
        CIModule(
            operation: "tonecurve", name: "tone curve", iopOrder: 36, defaultEnabled: false,
            // `n` 0 is the first version's curve: five heights y0...y4 at x = 0, 0.25, 0.5, 0.75, 1 (an old edit has only those).
            // `n` 2...8 is a point curve: points 0..<n at (x_i, y_i), as the editor writes them.
            fields: [
                field("n", 0, 8, 0),
                field("y0", 0, 1, 0), field("y1", 0, 1, 0.25), field("y2", 0, 1, 0.5), field("y3", 0, 1, 0.75), field("y4", 0, 1, 1),
                field("y5", 0, 1, 1), field("y6", 0, 1, 1), field("y7", 0, 1, 1),
                field("x0", 0, 1, 0), field("x1", 0, 1, 0.25), field("x2", 0, 1, 0.5), field("x3", 0, 1, 0.75), field("x4", 0, 1, 1),
                field("x5", 0, 1, 1), field("x6", 0, 1, 1), field("x7", 0, 1, 1),
            ],
            // DarkroomCore's ToneCurve on the oracle-checked per-pixel kernel (darkroom-engine-check E-TC)
            apply: { image, v in try CIModule.applyFused("tonecurve", image, v) }),

        // Monochrome: black and white with a colour filter. Intensity 0 leaves the image unchanged; greys stay grey.
        CIModule(
            operation: "monochrome", name: "black and white", iopOrder: 45,
            defaultEnabled: false,
            // method "filter": the OkLab colour filter (Monochrome); "weights": the grey as a weighted sum of the scene-linear channels
            // (BWMixer, the old black and white mixer). Both on their own oracle-checked kernels (E-MO, E-BWM).
            fields: [field("intensity", 0, 1, 0), choice("method", "method", "filter", [("filter", 0, "colour filter"), ("weights", 1, "channel weights")]),
                     field("filter_hue", 0, 360, 30), field("filter_strength", 0, 1, 0),
                     field("red", -1, 2, 0.263), field("green", -1, 2, 0.678), field("blue", -1, 2, 0.059)],
            apply: { image, v in try CIModule.applyFused("monochrome", image, v) }),

        // Vignetting: darkens the corners. Zero strength is off.
        CIModule(
            operation: "vignette", name: "vignetting", iopOrder: 40, defaultEnabled: false,
            fields: [
                field("strength", 0, 2, 0),
                field("scale", 0, 2, 1),
            ],
            // DarkroomCore's Vignette: radial light turned inside out (darkroom-engine-check E-VG)
            apply: { image, v in
                let strength = v["strength"] ?? 0
                guard strength > 0 else { return image }
                var spec = Vignette.spec(scale: v["scale"] ?? 1)
                spec.orientation = Orientation(value: Int(v["_camera"] ?? 0))
                let g = Exposure.gain(ev: Vignette.ev(strength: strength))
                let after = try CIBridge.gain(image, scale: SIMD3(g, g, g))
                return try CIBridge.blendMasked(before: image, after: after, mask: try CIBridge.localMask(image, spec: spec), opacity: 1)
            }),

        // Bloom: a soft glow around the bright parts. Zero strength is off.
        CIModule(
            operation: "bloom", name: "bloom", iopOrder: 42, defaultEnabled: false,
            fields: [
                field("strength", 0, 1, 0),
                field("size", 1, 50, 10),
            ],
            // DarkroomCore's Bloom: highlights through a soft knee, three box means, added back (darkroom-engine-check E-BLM). The size
            // is in pixels of the full-size picture, so it follows the render scale.
            apply: { image, v in
                try CIBridge.bloom(image, strength: v["strength"] ?? 0, radius: Bloom.radius(size: (v["size"] ?? 10) * (v["_scale"] ?? 1)))
            }),

        // Invert: a negative of the image, the complement of each channel's display-encoded value. No parameters.
        CIModule(
            operation: "invert", name: "invert", iopOrder: 3, defaultEnabled: false,
            fields: [],
            // DarkroomCore's Invert on the oracle-checked per-pixel kernel (darkroom-engine-check E-IV)
            apply: { image, v in try CIModule.applyFused("invert", image, v) }),

        // Levels: black, grey and white points on the encoded value, one kernel per pixel. Checked by
        // LV1-LV5 (darkroom-core-check), the levels Metal check (darkroom-metal-check) and E-LV (darkroom-engine-check).
        CIModule(
            operation: "rgblevels", name: "levels", iopOrder: 33,
            defaultEnabled: false,
            // gamma is the old base curve (out = e^gamma, after the levels); fade black and white are the old fade look (output levels,
            // the matte print), the last per-pixel step. Each runs on its own kernel, so an old edit renders the same.
            fields: [field("black", 0, 0.5, 0), field("grey", 0.1, 0.9, 0.5), field("white", 0.5, 1, 1),
                     field("gamma", 0.2, 3, 1), field("fade_black", 0, 0.3, 0), field("fade_white", 0, 0.3, 0)],
            apply: { image, v in try CIModule.applyFused("rgblevels", image, v) }),

        // Blur: three box means in a row (a Gaussian-like blur at any radius), the radius in pixels of the full-size picture.
        // Blur in DarkroomCore is the oracle (BLR1-BLR6, E-BLR in darkroom-engine-check).
        CIModule(
            operation: "blurs", name: "blurs", iopOrder: 48, defaultEnabled: false,
            fields: [field("radius", 0, 50, 0)],
            apply: { image, v in
                try CIBridge.blur(image, radius: Blur.radius(px: (v["radius"] ?? 0) * (v["_scale"] ?? 1)))
            }),

        // Low-pass: a blur of the tone (the square-root luminance) given back as a gain, so colour detail survives (unlike `blurs`). LowPass in DarkroomCore is the oracle
        // (LPS1-LPS5, E-LPF).
        CIModule(
            operation: "lowpass", name: "lowpass (tone)", iopOrder: 49, defaultEnabled: false,
            fields: [field("radius", 0, 50, 0)],
            apply: { image, v in try CIBridge.lowPass(image, radius: Blur.radius(px: (v["radius"] ?? 0) * (v["_scale"] ?? 1))) }),

        // Dither or posterize: the encoded value quantised to a number of levels per channel, no noise. Posterize in DarkroomCore is
        // the oracle (DTH1-DTH5, posterizeBuf in darkroom-metal-check, E-DTH in darkroom-engine-check).
        CIModule(
            operation: "dither", name: "posterize", iopOrder: 60,
            defaultEnabled: false,
            fields: [field("levels", 2, 64, 64)],
            apply: { image, v in try CIModule.applyFused("dither", image, v) }),

        // Censorize: a mosaic, every block of the given size shows its centre pixel. Mosaic in DarkroomCore is the oracle (MSC1-MSC5, E-MSC).
        CIModule(
            operation: "censorize", name: "censorize", iopOrder: 61, defaultEnabled: false,
            fields: [field("pixelation", 1, 100, 1)],
            apply: { image, v in
                try CIBridge.mosaic(image, block: Mosaic.block(pixelation: v["pixelation"] ?? 1, scale: v["_scale"] ?? 1))
            }),

        // Soften: the picture mixed toward its own blur. Soften in DarkroomCore is the oracle (SOF1-SOF5, E-SOF).
        CIModule(
            operation: "soften", name: "soften", iopOrder: 62, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("radius", 1, 30, 4)],
            apply: { image, v in
                try CIBridge.soften(image, strength: v["strength"] ?? 0, radius: Blur.radius(px: (v["radius"] ?? 4) * (v["_scale"] ?? 1)))
            }),

        // Colour zones: a hue shift, a saturation change and a lightness change for each of eight hue bands, blended smoothly
        // between neighbouring bands in OkLab; greys are left alone. ColorZones in DarkroomCore is the oracle (CZ1-CZ8 in
        // darkroom-core-check, colorzonesBuf in darkroom-metal-check, E-CZ in darkroom-engine-check).
        CIModule(
            operation: "colorzones", name: "color zones", iopOrder: 24,
            defaultEnabled: false,
            // hue_all turns every hue alike (the old hue rotate, its own kernel, before the bands)
            fields: [field("hue_all", -180, 180, 0)] + ["hue", "sat", "light"].flatMap { kind in ColorZones.bandNames.map { field("\($0)_\(kind)", -1, 1, 0) } },
            apply: { image, v in try CIModule.applyFused("colorzones", image, v) }),

        // Saturation by lightness: a saturation change for the shadows, the mids and the highlights, blended smoothly over OkLab
        // lightness. SatCurve in DarkroomCore is the oracle (SCV1-SCV6 in darkroom-core-check, satcurveBuf in darkroom-metal-check,
        // E-SCV in darkroom-engine-check).
        CIModule(
            operation: "satcurvergb", name: "saturation by lightness", iopOrder: 23,
            defaultEnabled: false,
            fields: [field("shadows", -1, 1, 0), field("mids", -1, 1, 0), field("highlights", -1, 1, 0)],
            apply: { image, v in try CIModule.applyFused("satcurvergb", image, v) }),

        // Four-way colour balance: a tint and a brightness for the shadows (CDL offset), the midtones (power about scene white) and
        // the highlights (slope), on scene-linear values. LiftGammaGain in DarkroomCore is the oracle (LG1-LG7 in darkroom-core-check,
        // lggBuf in darkroom-metal-check, E-LG in darkroom-engine-check).
        CIModule(
            operation: "colorbalance", name: "lift, gamma, gain", iopOrder: 21,
            defaultEnabled: false,
            fields: ["shadows", "mids", "highlights"].flatMap { r in
                [field("\(r)_hue", 0, 360, 0), field("\(r)_sat", 0, 1, 0), field("\(r)_lum", -1, 1, 0)]
            },
            apply: { image, v in try CIModule.applyFused("colorbalance", image, v) }),

        // Solarize: tones above a threshold mirrored about it, on the encoded value (the Sabattier effect). Solarize in DarkroomCore is the
        // oracle (SOL1-SOL5, solarizeBuf in darkroom-metal-check, E-SOL in darkroom-engine-check).
        CIModule(
            operation: "solarize", name: "solarize", iopOrder: 59, defaultEnabled: false,
            fields: [field("threshold", 0, 1, 0.5), field("strength", 0, 1, 0)],
            apply: { image, v in try CIModule.applyFused("solarize", image, v) }),

        // Negadoctor: a scanned colour negative turned positive from its density, E = exposure * (Dmin / T)^gamma - black, per channel, on
        // scene-linear values. NegativeFilm in DarkroomCore is the oracle (NEG1-NEG5, negadoctorBuf, E-NEG).
        CIModule(
            operation: "negadoctor", name: "film negative", iopOrder: 6, defaultEnabled: false,
            fields: [field("dmin_r", 0.02, 1, 0.8), field("dmin_g", 0.02, 1, 0.5), field("dmin_b", 0.02, 1, 0.35),
                     field("gamma", 0.3, 4, 1.6), field("exposure", 0.02, 8, 0.2), field("black", -0.2, 0.2, 0)],
            apply: { image, v in try CIModule.applyFused("negadoctor", image, v) }),

        // Low light: a Purkinje-shift model, dim parts mixed toward a cool scotopic grey. LowLight in DarkroomCore is the oracle
        // (LLT1-LLT5, lowlightBuf, E-LLT).
        CIModule(
            operation: "lowlight", name: "low light", iopOrder: 44, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0)],
            apply: { image, v in try CIModule.applyFused("lowlight", image, v) }),

        // Channel mixer with chromatic adaptation: the mixer's 3x3 after an adaptation from a black-body illuminant of the given temperature
        // to D65 (Bradford), blended by the strength. ChannelMixerRGB in DarkroomCore is the oracle (CMX1-CMX6, E-CMX); it runs on the mixer kernel.
        CIModule(
            operation: "channelmixerrgb", name: "channel mixer", iopOrder: 15, defaultEnabled: false,
            fields: [field("temperature", 1700, 25000, 6500), field("strength", 0, 1, 0)]
                + ["red_r", "red_g", "red_b", "green_r", "green_g", "green_b", "blue_r", "blue_g", "blue_b"].enumerated().map { i, n in field(n, -2, 2, i % 4 == 0 ? 1 : 0) },
            apply: { image, v in try CIModule.applyFused("channelmixerrgb", image, v) }),

        // Grain: lattice value noise from the pixel position, added to the encoded value with a midtone weight, the same on all channels. Grain in
        // DarkroomCore is the oracle (GRN1-GRN7, E-GRN in darkroom-engine-check).
        CIModule(
            operation: "grain", name: "grain", iopOrder: 65, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("size", 0.5, 12, 1.5), field("seed", 0, 1000, 0)],
            apply: { image, v in
                try CIBridge.grain(image, strength: v["strength"] ?? 0, size: (v["size"] ?? 1.5) * (v["_scale"] ?? 1),
                                   seed: UInt32(min(max((v["seed"] ?? 0).rounded(), 0), 1000)))
            }),

        // High pass: the encoded value minus its own blur, on mid-grey; edges and texture on a flat grey. Highpass in DarkroomCore is the oracle
        // (HPF1-HPF5, E-HPF in darkroom-engine-check).
        CIModule(
            operation: "highpass", name: "high pass", iopOrder: 66, defaultEnabled: false,
            fields: [field("radius", 1, 50, 8), field("strength", 0, 4, 1)],
            apply: { image, v in
                try CIBridge.highpass(image, strength: v["strength"] ?? 1, radius: Blur.radius(px: (v["radius"] ?? 8) * (v["_scale"] ?? 1)))
            }),

        // Gradient map: the picture's lightness picks a colour from a three-stop gradient (shadows, midtones, highlights) and the pixel's OkLab
        // chroma is mixed toward it; lightness is kept. GradientMap in DarkroomCore is the oracle (GMP1-GMP5, E-GMP).
        CIModule(
            operation: "gradientmap", name: "gradient map", iopOrder: 56, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("shadows_hue", 0, 360, 230), field("shadows_sat", 0, 1, 0.7), field("mids_hue", 0, 360, 0),
                     field("mids_sat", 0, 1, 0), field("highlights_hue", 0, 360, 60), field("highlights_sat", 0, 1, 0.6)],
            apply: { image, v in try CIModule.applyFused("gradientmap", image, v) }),

        // Bleach bypass: partial desaturation plus an overlay of the luminance, on the encoded value. BleachBypass in DarkroomCore is the oracle (BLB1-BLB4, E-BLB).
        CIModule(
            operation: "bleachbypass", name: "bleach bypass", iopOrder: 58, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0)],
            apply: { image, v in try CIModule.applyFused("bleachbypass", image, v) }),

        // Channel curves: a monotone curve of its own on each of red, green and blue (three movable nodes each). ChannelCurves in DarkroomCore is the
        // oracle (CHC1-CHC5, E-CHC).
        CIModule(
            operation: "channelcurves", name: "channel curves", iopOrder: 37, defaultEnabled: false,
            // cross_process is the old cross process look (fixed contrasty curves with lifted blue), its own kernel after the curves
            fields: ChannelCurves.channels.flatMap { c in [field("\(c)_y1", 0, 1, 0.25), field("\(c)_y2", 0, 1, 0.5), field("\(c)_y3", 0, 1, 0.75)] }
                + [field("cross_process", 0, 1, 0)],
            apply: { image, v in try CIModule.applyFused("channelcurves", image, v) }),

        // Chroma limit: a soft tanh limit on OkLab chroma so very saturated colours stop short of clipping. ChromaLimit in DarkroomCore is the oracle (CHL1-CHL5, E-CHL).
        CIModule(
            operation: "chromalimit", name: "chroma limit", iopOrder: 38, defaultEnabled: false,
            fields: [field("limit", 0.05, 0.4, 0.4)],
            apply: { image, v in try CIModule.applyFused("chromalimit", image, v) }),

        // Warmth: a warm / cool and a magenta / green look slider in OkLab, after white balance. Warmth in DarkroomCore is the oracle (WRM1-WRM4, E-WRM).
        CIModule(
            operation: "warmth", name: "warmth and tint", iopOrder: 16, defaultEnabled: false,
            // method "offset": the OkLab warm/cool and magenta/green look; "filter": the old photo filter, a coloured filter on the scene
            // light with the luminosity kept (hue, density, preserve). Each on its own oracle-checked kernel (E-WRM, E-PFT).
            fields: [choice("method", "method", "offset", [("offset", 0, "warm and tint"), ("filter", 1, "colour filter")]),
                     field("warmth", -1, 1, 0), field("tint", -1, 1, 0),
                     field("hue", 0, 360, 45), field("density", 0, 1, 0), field("preserve", 0, 1, 1)],
            apply: { image, v in try CIModule.applyFused("warmth", image, v) }),

        // Highlight roll-off: a tanh shoulder on scene luminance above a knee, colour ratios kept. HighlightRolloff in DarkroomCore is the oracle (HRO1-HRO5, E-HRO).
        CIModule(
            operation: "highlightrolloff", name: "highlight compression", iopOrder: 27, defaultEnabled: false,
            // curve "shoulder": the tanh roll-off above the knee; "reinhard": the old Reinhard tone (extended Reinhard on scene
            // luminance, white only). Each on its own oracle-checked kernel (E-HRO, E-RNH).
            fields: [choice("curve", "curve", "shoulder", [("shoulder", 0, "soft shoulder"), ("reinhard", 1, "Reinhard")]),
                     field("white", 0.5, 16, 1), field("knee", 0.3, 0.95, 0.7), field("amount", 0, 1, 0)],
            apply: { image, v in try CIModule.applyFused("highlightrolloff", image, v) }),

        // Luminosity bands: an exposure change by the pixel's own luminance in five bands. LumaBands in DarkroomCore is the oracle (LMB1-LMB5, E-LMB).
        CIModule(
            operation: "lumabands", name: "luminosity bands", iopOrder: 39, defaultEnabled: false,
            // ev, center and width are the old fill light: one movable band (a Gaussian window of tone), its own kernel before the fixed bands
            fields: LumaBands.names.map { field($0, -3, 3, 0) } + [field("ev", -2, 2, 0), field("center", -5, 3, -1), field("width", 1, 10, 4)],
            apply: { image, v in try CIModule.applyFused("lumabands", image, v) }),

        // HDR tone: base and detail compression, the base (guided filter of the log luminance) pulled toward middle grey. HdrTone in DarkroomCore is the
        // oracle (HDT1-HDT5, E-HDT in darkroom-engine-check).
        CIModule(
            operation: "hdrtone", name: "HDR tone compression", iopOrder: 41, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("scale", 0.005, 0.2, ZoneExposure.defaultScale)],
            apply: { image, v in
                let e = image.extent
                let r = ZoneExposure.radius(scale: v["scale"] ?? ZoneExposure.defaultScale, longSide: Int(max(e.width, e.height)))
                return try CIBridge.hdrTone(image, amount: v["amount"] ?? 0, radius: r)
            }),

        // Luminosity curve: a monotone cubic on OkLab lightness, chroma kept. LumaCurve in DarkroomCore is the oracle (LMC1-LMC5, E-LMC).
        CIModule(
            operation: "lumacurve", name: "luminosity curve", iopOrder: 68, defaultEnabled: false,
            fields: [field("y0", 0, 1, 0), field("y1", 0, 1, 0.25), field("y2", 0, 1, 0.5), field("y3", 0, 1, 0.75), field("y4", 0, 1, 1)],
            apply: { image, v in try CIModule.applyFused("lumacurve", image, v) }),

        // S-curve: a bias-and-gain contrast curve about a pivot on the encoded value. SCurve in DarkroomCore is the oracle (SCC1-SCC5, E-SCC).
        CIModule(
            operation: "scurve", name: "S-curve contrast", iopOrder: 69, defaultEnabled: false,
            fields: [field("contrast", -1, 1, 0), field("pivot", 0.2, 0.8, 0.5)],
            apply: { image, v in try CIModule.applyFused("scurve", image, v) }),

        // Deconvolution sharpen: Richardson-Lucy with the three-box blur as the point spread function. Deconvolution in DarkroomCore is the oracle (DCV1-DCV5, E-DCV).
        CIModule(
            operation: "deconvsharp", name: "deconvolution sharpen", iopOrder: 70, defaultEnabled: false,
            fields: [field("radius", 1, 10, 2), field("iterations", 1, 10, 4), field("amount", 0, 1, 0)],
            apply: { image, v in
                try CIBridge.deconvolve(image, radius: Blur.radius(px: (v["radius"] ?? 2) * (v["_scale"] ?? 1)),
                                        iterations: Int((v["iterations"] ?? 4).rounded()), amount: v["amount"] ?? 0)
            }),

        // Chroma denoise: the OkLab a and b planes smoothed by a guided filter guided by luminance; lightness untouched. ChromaDenoise in DarkroomCore is the oracle (CDN1-CDN5, E-CDN).
        CIModule(
            operation: "chromadenoise", name: "chroma denoise", iopOrder: 7, defaultEnabled: false,
            fields: [field("radius", 1, 30, 6), field("amount", 0, 1, 0)],
            apply: { image, v in
                try CIBridge.fractionalWindow(image, radius: (v["radius"] ?? 6) * (v["_scale"] ?? 1)) { img, n in try CIBridge.chromaDenoise(img, radius: n, amount: v["amount"] ?? 0) }
            }),

        // Median denoise: each channel the median of its 3x3 or 5x5 neighbourhood. MedianDenoise in DarkroomCore is the oracle (MDN1-MDN5, E-MDN).
        CIModule(
            operation: "mediandenoise", name: "hot pixels (median)", iopOrder: 8, defaultEnabled: false,
            fields: [field("radius", 1, 2, 1), field("amount", 0, 1, 0)],
            apply: { image, v in try CIBridge.medianDenoise(image, radius: Int((v["radius"] ?? 1).rounded()), amount: v["amount"] ?? 0) }),

        // Deband: smooth gradients replaced by their blur, edges kept. Deband in DarkroomCore is the oracle (DBD1-DBD5, E-DBD).
        CIModule(
            operation: "deband", name: "deband", iopOrder: 9, defaultEnabled: false,
            fields: [field("radius", 2, 30, 8), field("threshold", 0.002, 0.05, 0.01), field("strength", 0, 1, 0)],
            apply: { image, v in
                try CIBridge.deband(image, radius: Blur.radius(px: (v["radius"] ?? 8) * (v["_scale"] ?? 1)), threshold: v["threshold"] ?? 0.01, strength: v["strength"] ?? 0)
            }),

        // Skin smooth: an edge-aware smooth mixed in by a skin-hue matte. SkinSmooth in DarkroomCore is the oracle (SKS1-SKS5, E-SKS).
        CIModule(
            operation: "skinsmooth", name: "skin smoothing", iopOrder: 43, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("radius", 2, 40, 10), field("hue", 0, 360, 55), field("width", 15, 90, 35)],
            apply: { image, v in
                try CIBridge.fractionalWindow(image, radius: (v["radius"] ?? 10) * (v["_scale"] ?? 1)) {
                    img, n in try CIBridge.skinSmooth(img, radius: n, amount: v["amount"] ?? 0, hueDegrees: v["hue"] ?? 55, widthDegrees: v["width"] ?? 35)
                }
            }),

        // Texture bands: a band-pass of the luminance (blur at the radius minus blur at three times it) added back as a gain. TextureBands in DarkroomCore is the
        // oracle (TXB1-TXB5, E-TXB).
        CIModule(
            operation: "texturebands", name: "texture and clarity", iopOrder: 71, defaultEnabled: false,
            fields: [field("radius", 2, 40, 6), field("amount", -1, 2, 0)],
            apply: { image, v in try CIBridge.textureBands(image, radiusPixels: (v["radius"] ?? 6) * (v["_scale"] ?? 1), amount: v["amount"] ?? 0) }),

        // Halation: the highlights blurred widely and added back, tinted warm. Halation in DarkroomCore is the oracle (HLT1-HLT5, E-HLT).
        CIModule(
            operation: "halation", name: "halation", iopOrder: 72, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("size", 5, 100, 30), field("hue", 0, 360, 25)],
            apply: { image, v in
                try CIBridge.halation(image, strength: v["strength"] ?? 0, radius: Blur.radius(px: (v["size"] ?? 30) * (v["_scale"] ?? 1)),
                                      tint: Halation.tint(hueDegrees: v["hue"] ?? 25))
            }),

        // Lateral chromatic aberration: the red and blue channels scaled about the centre (percent of the radius; real lenses are a few hundredths), green fixed, bilinear.
        // `fill` (on by default) magnifies just enough that no edge pixel is repeated. Remap in DarkroomCore is the oracle (CAR1-CAR4, FIL1-FIL5, E-CAR).
        CIModule(
            operation: "caradial", name: "chromatic aberration (radial)", iopOrder: 2, defaultEnabled: false,
            fields: [field("red", -0.5, 0.5, 0), field("blue", -0.5, 0.5, 0), field("fill", 0, 1, 1)],
            apply: { image, v in try CIModule.applyRemap(image, .chromaticAberration(red: (v["red"] ?? 0) / 100, blue: (v["blue"] ?? 0) / 100), fill: v["fill"] ?? 1) }),

        // Lens distortion: Brown's radial polynomial, bilinear; `fill` (on by default) magnifies just enough that no edge pixel is repeated. Remap in DarkroomCore is the oracle
        // (DST1-DST4, FIL1-FIL5, E-DST).
        CIModule(
            operation: "distortion", name: "lens distortion", iopOrder: 93, defaultEnabled: false,
            fields: [field("k1", -0.5, 0.5, 0), field("k2", -0.5, 0.5, 0), field("fill", 0, 1, 1)],
            apply: { image, v in try CIModule.applyRemap(image, .distortion(k1: v["k1"] ?? 0, k2: v["k2"] ?? 0), fill: v["fill"] ?? 1) }),

        // Perspective: a keystone as a plane projective map about the centre, bilinear; `fill` (on by default) magnifies just enough that no edge pixel is repeated.
        // Remap in DarkroomCore is the oracle (PSP1-PSP4, FIL1-FIL5, E-PSP).
        CIModule(
            operation: "perspective", name: "perspective (keystone)", iopOrder: 94, defaultEnabled: false,
            fields: [field("horizontal", -0.5, 0.5, 0), field("vertical", -0.5, 0.5, 0), field("fill", 0, 1, 1)],
            apply: { image, v in try CIModule.applyRemap(image, .perspective(horizontal: v["horizontal"] ?? 0, vertical: v["vertical"] ?? 0), fill: v["fill"] ?? 1) }),

        // Tilt-shift: a sharp band across the frame, a wide blur beyond it. TiltShift in DarkroomCore is the oracle (TLS1-TLS5, E-TLS).
        CIModule(
            operation: "tiltshift", name: "tilt-shift", iopOrder: 73, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("radius", 1, 60, 20), field("position", 0, 1, 0.5), field("angle", -90, 90, 0),
                     field("width", 0, 1, 0.2), field("transition", 0.02, 1, 0.25)],
            apply: { image, v in
                try CIBridge.tiltShift(image, radius: Blur.radius(px: (v["radius"] ?? 20) * (v["_scale"] ?? 1)), position: v["position"] ?? 0.5,
                                       angleDegrees: v["angle"] ?? 0, bandWidth: v["width"] ?? 0.2, transition: v["transition"] ?? 0.25, amount: v["amount"] ?? 0)
            }),

        // Defringe: colour taken out of strong edges where the colour is in the fringe hue. Defringe in DarkroomCore is the oracle (DFR1-DFR5, E-DFR).
        CIModule(
            operation: "defringe", name: "defringe", iopOrder: 12, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("radius", 1, 30, 4), field("hue", 0, 360, 320), field("width", 10, 90, 40)],
            apply: { image, v in
                try CIBridge.defringe(image, radius: Blur.radius(px: (v["radius"] ?? 4) * (v["_scale"] ?? 1)), strength: v["strength"] ?? 0,
                                      hueDegrees: v["hue"] ?? 320, widthDegrees: v["width"] ?? 40)
            }),

        // Colour harmonizer: each hue pulled toward the nearest hue of a harmony scheme (complementary, triad, tetrad, analogous) from a base hue; chroma and lightness kept.
        // ColorHarmony in DarkroomCore is the oracle (HRM1-HRM5, E-HRM).
        CIModule(
            operation: "colorharmonizer", name: "colour harmonizer", iopOrder: 24, defaultEnabled: false,
            fields: [field("scheme", 0, 3, 0), field("base", 0, 360, 30), field("amount", 0, 1, 0)],
            apply: { image, v in try CIModule.applyFused("colorharmonizer", image, v) }),

        // Surface blur: an edge-preserving blur (guided filter guided by luminance) over the whole picture. SurfaceBlur in DarkroomCore is the oracle (SRB1-SRB4, E-SRB).
        CIModule(
            operation: "surfaceblur", name: "surface blur", iopOrder: 74, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("radius", 1, 40, 8), field("threshold", 0.0005, 0.05, 0.004)],
            apply: { image, v in
                try CIBridge.surfaceBlur(image, radius: (v["radius"] ?? 8) * (v["_scale"] ?? 1), eps: v["threshold"] ?? 0.004, amount: v["amount"] ?? 0)
            }),

        // Lens blur: a disc blur with bright highlights spread into bokeh discs. LensBlur in DarkroomCore is the oracle (LNB1-LNB5, E-LNB).
        CIModule(
            operation: "lensblur", name: "lens blur", iopOrder: 75, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("radius", 1, 30, 8), field("highlights", 0, 8, 2)],
            apply: { image, v in
                try CIBridge.fractionalWindow(image, radius: (v["radius"] ?? 8) * (v["_scale"] ?? 1)) { img, n in try CIBridge.lensBlur(img, radius: n, boost: v["highlights"] ?? 2, amount: v["amount"] ?? 0) }
            }),

        // Motion blur: the mean of samples along a line. MotionBlur in DarkroomCore is the oracle (MOB1-MOB5, E-MOB).
        CIModule(
            operation: "motionblur", name: "motion blur", iopOrder: 76, defaultEnabled: false,
            fields: [field("length", 0, 100, 0), field("angle", -90, 90, 0)],
            apply: { image, v in try CIBridge.motionBlur(image, length: Int(((v["length"] ?? 0) * (v["_scale"] ?? 1)).rounded()), angleDegrees: v["angle"] ?? 0) }),

        // Radial blur: a zoom or a spin about a centre point. RadialBlur in DarkroomCore is the oracle (RDB1-RDB5, E-RDB).
        CIModule(
            operation: "radialblur", name: "radial blur (zoom or spin)", iopOrder: 77, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("spin", 0, 1, 0), field("centre_x", 0, 1, 0.5), field("centre_y", 0, 1, 0.5)],
            apply: { image, v in
                try CIBridge.radialBlur(image, spin: (v["spin"] ?? 0) >= 0.5, amount: v["amount"] ?? 0, centreX: v["centre_x"] ?? 0.5, centreY: v["centre_y"] ?? 0.5)
            }),

        // Diffusion: Perona-Malik anisotropic diffusion on the square root of the scene value. Diffusion in DarkroomCore is the oracle (DIF1-DIF5, E-DIF).
        CIModule(
            operation: "diffuse", name: "diffuse (anisotropic)", iopOrder: 78, defaultEnabled: false,
            fields: [field("iterations", 0, 30, 0), field("threshold", 0.01, 0.5, 0.1)],
            apply: { image, v in try CIBridge.diffuse(image, iterations: Int((v["iterations"] ?? 0).rounded()), threshold: v["threshold"] ?? 0.1) }),

        // Kuwahara: the painterly edge-preserving smoother. Kuwahara in DarkroomCore is the oracle (KUW1-KUW5, E-KUW).
        CIModule(
            operation: "kuwahara", name: "painterly (Kuwahara)", iopOrder: 79, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("radius", 1, 8, 3)],
            apply: { image, v in try CIBridge.fractionalWindow(image, radius: (v["radius"] ?? 3) * (v["_scale"] ?? 1)) { img, n in try CIBridge.kuwahara(img, radius: n, amount: v["amount"] ?? 0) } }),

        // Selective colour: cyan, magenta, yellow and black sliders for each of six colour families, relative, on the encoded value. SelectiveColor in DarkroomCore is the oracle
        // (SLC1-SLC5, E-SLC).
        CIModule(
            operation: "selectivecolor", name: "selective colour", iopOrder: 30, defaultEnabled: false,
            fields: SelectiveColor.families.flatMap { f in SelectiveColor.inks.map { field("\(f)_\($0)", -1, 1, 0) } },
            apply: { image, v in try CIModule.applyFused("selectivecolor", image, v) }),

        // Non-local means: the weighted mean of similar patches in a 7 x 7 window (Buades, Coll, Morel). NonLocalMeans in DarkroomCore is the oracle (NLM1-NLM5, E-NLM).
        CIModule(
            operation: "nlmeans", name: "non-local means denoise", iopOrder: 80, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("strength", 0.01, 0.3, 0.06)],
            apply: { image, v in try CIBridge.nonLocalMeans(image, h: v["strength"] ?? 0.06, amount: v["amount"] ?? 0) }),

        // Bilateral filter: spatial and colour-range Gaussians (Tomasi and Manduchi). BilateralFilter in DarkroomCore is the oracle (BIL1-BIL5, E-BIL).
        CIModule(
            operation: "bilateral", name: "bilateral filter", iopOrder: 81, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("radius", 1, 10, 4), field("range", 0.01, 0.5, 0.1)],
            apply: { image, v in
                try CIBridge.fractionalWindow(image, radius: (v["radius"] ?? 4) * (v["_scale"] ?? 1)) { img, n in try CIBridge.bilateral(img, radius: n, range: v["range"] ?? 0.1, amount: v["amount"] ?? 0) }
            }),

        // Emboss: the directional derivative of the encoded luminance on mid-grey. Emboss in DarkroomCore is the oracle (EMB1-EMB5, E-EMB).
        CIModule(
            operation: "emboss", name: "emboss", iopOrder: 82, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("angle", -180, 180, 135), field("strength", 0.5, 8, 3)],
            apply: { image, v in try CIBridge.emboss(image, angleDegrees: v["angle"] ?? 135, strength: v["strength"] ?? 3, amount: v["amount"] ?? 0) }),

        // Sketch: Sobel edges of the encoded luminance as dark lines on white. Sketch in DarkroomCore is the oracle (SKT1-SKT5, E-SKT).
        CIModule(
            operation: "sketch", name: "pencil sketch", iopOrder: 83, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("strength", 1, 20, 6)],
            apply: { image, v in try CIBridge.sketch(image, strength: v["strength"] ?? 6, amount: v["amount"] ?? 0) }),

        // Halftone: ink dots on a turned grid, the area following the darkness. Halftone in DarkroomCore is the oracle (HLF1-HLF5, E-HLF).
        CIModule(
            operation: "halftone", name: "halftone", iopOrder: 84, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("size", 3, 40, 10), field("angle", -45, 45, 15), field("colour", 0, 1, 0)],
            apply: { image, v in
                try CIBridge.halftone(image, size: max(((v["size"] ?? 10) * (v["_scale"] ?? 1)).rounded(), 1), angleDegrees: v["angle"] ?? 15, colour: (v["colour"] ?? 0) >= 0.5, amount: v["amount"] ?? 0)
            }),

        // Retouch: one spot, cloned or healed (the destination's low frequencies with the source's detail). CloneSpot in DarkroomCore is the oracle (RTC1-RTC5, E-RTC).
        CIModule(
            operation: "retouch", name: "retouch spot (clone or heal)", iopOrder: 85, defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("src_x", 0, 1, 0.3), field("src_y", 0, 1, 0.5), field("dst_x", 0, 1, 0.6), field("dst_y", 0, 1, 0.5),
                     field("radius", 0.005, 0.3, 0.06), field("feather", 0, 1, 0.5), field("heal", 0, 1, 1)],
            apply: { image, v in try CIBridge.cloneSpot(image, spot: CloneSpot.Spot(values: v)) }),

        // Liquify: a bulge or pinch warp about a point, bilinear. Remap in DarkroomCore is the oracle (LQF1-LQF4, E-LQF).
        CIModule(
            operation: "liquify", name: "liquify (bulge or pinch)", iopOrder: 92, defaultEnabled: false,
            fields: [field("strength", -1, 1, 0), field("centre_x", 0, 1, 0.5), field("centre_y", 0, 1, 0.5), field("radius", 0.05, 1, 0.25)],
            apply: { image, v in
                try CIBridge.remap(image, kind: .warp(centreX: v["centre_x"] ?? 0.5, centreY: v["centre_y"] ?? 0.5, radius: v["radius"] ?? 0.25, strength: v["strength"] ?? 0))
            }),

        // Split toning: a shadows tint and a highlights tint in OkLab, each with its own hue and saturation,
        // split at a balance pivot. Checked by ST1-ST7 (darkroom-core-check), splitBuf (darkroom-metal-check)
        // and E-ST (darkroom-engine-check).
        CIModule(
            operation: "splittoning", name: "split-toning", iopOrder: 63,
            defaultEnabled: false,
            fields: [
                field("shadows_hue", 0, 360, 220), field("shadows_saturation", 0, 1, 0),
                field("highlights_hue", 0, 360, 60), field("highlights_saturation", 0, 1, 0),
                field("balance", -1, 1, 0),
            ],
            // DarkroomCore's SplitToning on the oracle-checked per-pixel kernel (darkroom-engine-check E-ST)
            apply: { image, v in try CIModule.applyFused("splittoning", image, v) }),

        // Local contrast: a guided filter on square-root luminance, so the boost stops at strong edges (no halos).
        // LocalContrast in DarkroomCore is the oracle, and the GPU path is checked against it (darkroom-engine-check E-LC).
        CIModule(
            operation: "bilat", name: "texture and clarity", iopOrder: 47,
            defaultEnabled: false,
            fields: [field("detail", -1, 2, 0), field("radius", 1, 50, 10)],
            apply: { image, v in
                try CIBridge.localContrast(image, detail: v["detail"] ?? 0, radius: (v["radius"] ?? 10) * (v["_scale"] ?? 1))
            }),

        // Contrast equalizer: wavelet gains on fine, medium and coarse detail of the square-root luminance.
        CIModule(
            operation: "atrous", name: "contrast equalizer", iopOrder: 50, defaultEnabled: false,
            fields: [field("fine", -1, 1, 0), field("medium", -1, 1, 0), field("coarse", -1, 1, 0)],
            apply: { image, v in
                try CIBridge.contrastEqualizer(image, fine: v["fine"] ?? 0, medium: v["medium"] ?? 0, coarse: v["coarse"] ?? 0)
            }),

        // Radial light: an exposure change inside (or, with `outside`, around) a soft ellipse. DarkroomCore.RadialLight is the
        // oracle; the matte is the engine's own ellipse mask on the upright picture. Exposure 0 is the identity.
        CIModule(
            operation: "radiallight", name: "radial light", iopOrder: 52, defaultEnabled: false,
            fields: [
                field("exposure", -4, 4, 0), field("x", 0, 1, 0.5), field("y", 0, 1, 0.5), field("size", 0.02, 1, 0.3),
                field("shape", 0.2, 1, 1), field("rotation", -90, 90, 0), field("feather", 0, 1, 0.5),
                FieldSchema(name: "outside", description: "outside", kind: .bool, min: 0, max: 1, defaultValue: .number(0), options: []),
            ],
            apply: { image, v in
                let ev = v["exposure"] ?? 0
                guard ev != 0 else { return image }
                var spec = RadialLight.spec(x: v["x"] ?? 0.5, y: v["y"] ?? 0.5, size: v["size"] ?? 0.3, shape: v["shape"] ?? 1,
                                            rotation: v["rotation"] ?? 0, feather: v["feather"] ?? 0.5, outside: (v["outside"] ?? 0) != 0)
                spec.orientation = Orientation(value: Int(v["_camera"] ?? 0))
                let g = Exposure.gain(ev: ev)
                let after = try CIBridge.gain(image, scale: SIMD3(g, g, g))
                return try CIBridge.blendMasked(before: image, after: after, mask: try CIBridge.localMask(image, spec: spec), opacity: 1)
            }),

        // Graduated filter: an exposure change through a soft linear gradient, for a bright sky or a dark foreground. DarkroomCore.GraduatedFilter is
        // the oracle; the matte is the engine's own gradient mask on the upright picture. Exposure 0 is the identity.
        CIModule(
            operation: "graduated", name: "graduated filter", iopOrder: 53, defaultEnabled: false,
            fields: [field("exposure", -4, 4, 0), field("position", 0, 1, 0.5), field("angle", -180, 180, -90), field("feather", 0, 1, 0.5)],
            apply: { image, v in
                let ev = v["exposure"] ?? 0
                guard ev != 0 else { return image }
                var spec = GraduatedFilter.spec(position: v["position"] ?? 0.5, angle: v["angle"] ?? -90, feather: v["feather"] ?? 0.5)
                spec.orientation = Orientation(value: Int(v["_camera"] ?? 0))
                let g = Exposure.gain(ev: ev)
                let after = try CIBridge.gain(image, scale: SIMD3(g, g, g))
                return try CIBridge.blendMasked(before: image, after: after, mask: try CIBridge.localMask(image, spec: spec), opacity: 1)
            }),

        // Highlight reconstruction: a fully clipped pixel takes its colour from nearby reliable pixels (neutral where there are none), a partly
        // clipped one rebuilds its lost channels from the colour of its surroundings. `clip` is the level the data clips at, in scene units
        // (about 3.0 on the camera files measured); `strength` 0 is off. Off by default: Apple's decoder already leaves clipped highlights
        // neutral (dtb-selftest --highlight-probe), so this is for the files where it does not. Checked by A1-A3 (darkroom-core-check) and E-HR.
        CIModule(
            operation: "highlights", name: "highlight reconstruction", iopOrder: 4, defaultEnabled: false,
            fields: [field("clip", 0.5, 8, 3), field("strength", 0, 1, 1)],
            apply: { image, v in try CIBridge.highlightRebuild(image, clip: v["clip"] ?? 3, strength: v["strength"] ?? 1) }),

        // Haze removal: the dark channel prior with a guided-filter-refined transmission. Strength 0 is the identity.
        // Checked by DH1-DH7 (darkroom-core-check) and E-DH (darkroom-engine-check).
        CIModule(
            operation: "hazeremoval", name: "haze removal", iopOrder: 51, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("radius", 1, 40, 8), field("airlight", 0.2, 4, 1)],
            apply: { image, v in
                try CIBridge.dehaze(image, strength: v["strength"] ?? 0, radius: (v["radius"] ?? 8) * (v["_scale"] ?? 1), airlight: v["airlight"] ?? 1)
            }),

        // Zone exposure: an exposure change in stops by zone, read from the picture's edge-aware smoothed brightness, so shadows
        // lift and highlights hold without halos or lost texture. Scene domain (runs on scene-linear light, before the display
        // transform). All zero is the identity. Checked by ZE1 to ZE6 (darkroom-core-check) and E-ZE (darkroom-engine-check).
        CIModule(
            operation: "zones", name: "zone exposure", iopOrder: 55, defaultEnabled: false,
            fields: [
                field("z_m7", -3, 3, 0), field("z_m6", -3, 3, 0), field("z_m5", -3, 3, 0), field("z_m4", -3, 3, 0),
                field("z_m3", -3, 3, 0), field("z_m2", -3, 3, 0), field("z_m1", -3, 3, 0), field("z_0", -3, 3, 0),
                field("z_p1", -3, 3, 0), field("z_p2", -3, 3, 0),
                field("shadows", -2, 2, 0), field("highlights", -2, 2, 0), field("blacks", -2, 2, 0), field("whites", -2, 2, 0),
                field("scale", 0.005, 0.2, ZoneExposure.defaultScale),
            ],
            apply: { image, v in
                let settings = ZoneExposure.Settings(values: v)
                guard !settings.isIdentity else { return image }
                let e = image.extent
                let r = ZoneExposure.radius(scale: settings.scale, longSide: Int(max(e.width, e.height)))
                return try CIBridge.zoneExposure(image, evs: settings.zoneEVs, radius: r)
            }),

        // Clahe: contrast limited adaptive histogram equalisation on a grid of tiles (Zuiderveld 1994), the new luminance given back as a gain. Clahe in DarkroomCore is the oracle
        // (CLH1-CLH6, E-CLH); the GPU twin builds each tile's mapping in a threadgroup.
        CIModule(
            operation: "clahe", name: "adaptive contrast (CLAHE)", iopOrder: 64,
            defaultEnabled: false,
            fields: [field("amount", 0, 1, 0), field("tiles", 2, 16, 8), field("clip", 1, 10, 3)],
            apply: { image, v in try CIBridge.clahe(image, tiles: Int((v["tiles"] ?? 8).rounded()), clip: v["clip"] ?? 3, amount: v["amount"] ?? 0) }),
    ]

    /// A float field whose label is its own name, since darktable's descriptions are not carried here.
    static func field(_ name: String, _ min: Double, _ max: Double, _ value: Double) -> FieldSchema {
        FieldSchema(name: name, description: name.replacingOccurrences(of: "_", with: " "), kind: .float,
                    min: min, max: max, defaultValue: .number(value), options: [])
    }

    /// The scene-referred display transform: DarkroomCore's SceneTone (luminance norm, Hermite shoulder, gamut step) on the
    /// oracle-checked kernel. Version 2; version 1 was the per-channel extended Reinhard ToneMap, which clipped at +2.7 EV. Enabling it switches the decode to scene-linear (see `CIModule.sceneReferred`).
    static let display: CIModule = {
        var m = CIModule(
            operation: "display", name: "display transform (scene-referred)", iopOrder: 90, defaultEnabled: true,
            fields: [
                FieldSchema(name: "contrast", description: "contrast", kind: .float,
                            min: -100, max: 100, defaultValue: .number(0), options: []),
                // scene-linear raw data sits dark of display white; this lifts it into the tone map's range
                FieldSchema(name: "exposure", description: "exposure bias (EV)", kind: .float,
                            min: -3, max: 3, defaultValue: .number(0), options: []),
                // the scene brightness, in stops over middle grey, that reaches display white
                FieldSchema(name: "white", description: "white point (EV over grey)", kind: .float,
                            min: 1.5, max: 8, defaultValue: .number(SceneTone.defaultWhiteEV), options: []),
                // 0 keeps a bright colour's hue and saturation to the top of the curve, 1 lets it bleach to white
                FieldSchema(name: "purity", description: "path to white", kind: .float,
                            min: 0, max: 1, defaultValue: .number(SceneTone.defaultPurity), options: []),
            ],
            apply: { image, v in try CIModule.applyFused("display", image, v) })
        m.algorithmVersion = 2
        m.sceneReferred = true
        return m
    }()

    /// Where a new photo's display transform starts, in stops, so an untouched raw lands near the camera's own brightness.
    /// The field's own default stays 0: a saved edit that has no value (older sidecars) means "no lift".
    static let defaultExposureBias = 0.5

    /// Where a module starts when nothing has been edited, where that differs from the field's own default (an absent value in a saved edit
    /// means the field default, so older sidecars keep their look). `sessionModules` reports these as the module's values, and a session
    /// render puts them under whatever the stack sets (see `CIEngine.withDefaults`).
    static let startParams: [String: [String: ParamValue]] = [
        "display": ["exposure": .number(defaultExposureBias)],
    ]

    /// The stack a session or export render runs: the modules that are on by default (white balance, the display transform) join it unless
    /// the stack already has an entry for them (an entry that says `enabled: false` switches one off), and a module's starting values sit under
    /// its own. The model sends only what the user edited, and without this the display transform never ran by default. The static
    /// `CIEngine.process` and the probe do NOT do this, so an empty stack there stays the identity the oracle checks rely on.
    static func withDefaults(_ stack: [StackEntry]) -> [StackEntry] {
        var out = stack.map { e -> StackEntry in
            guard let start = startParams[e.operation] else { return e }
            var merged = e
            merged.params = start.merging(e.params) { _, edited in edited }
            return merged
        }
        for m in all where m.defaultEnabled && !m.geometry && !out.contains(where: { $0.operation == m.operation }) {
            out.append(StackEntry(operation: m.operation, params: startParams[m.operation] ?? [:]))
        }
        return out
    }

    /// Flip, straighten and crop, with darktable's parameter names (read from its introspection) so one
    /// stack drives either engine. Their pixels come from `CIGeometry`; `apply` here is never called.
    static let geometryModules: [CIModule] = {
        func opt(_ name: String, _ value: Int, _ label: String) -> EnumOption { EnumOption(name: name, value: value, label: label) }
        let orientations = [
            opt("ORIENTATION_NULL", -1, "camera"), opt("ORIENTATION_NONE", 0, "none"), opt("ORIENTATION_FLIP_HORIZONTALLY", 2, "flip horizontally"),
            opt("ORIENTATION_FLIP_VERTICALLY", 1, "flip vertically"), opt("ORIENTATION_ROTATE_180_DEG", 3, "rotate 180 deg"),
            opt("ORIENTATION_ROTATE_CW_90_DEG", 5, "rotate cw 90 deg"), opt("ORIENTATION_ROTATE_CCW_90_DEG", 6, "rotate ccw 90 deg"),
            opt("ORIENTATION_TRANSPOSE", 4, "transpose"), opt("ORIENTATION_TRANSVERSE", 7, "transverse"),
        ]
        let cropModes = [opt("ASHIFT_CROP_OFF", 0, "off"), opt("ASHIFT_CROP_LARGEST", 1, "largest"),
                         opt("ASHIFT_CROP_ASPECT", 2, "aspect")]
        var flip = CIModule(
            operation: "flip", name: "orientation", iopOrder: 1, defaultEnabled: false,
            fields: [FieldSchema(name: "orientation", description: "orientation", kind: .enumeration, min: 0, max: 0,
                                 // the camera's, so an explicit "none" differs from the default and is kept
                                 defaultValue: .option("ORIENTATION_NULL"), options: orientations)],
            apply: { image, _ in image })
        var straighten = CIModule(
            operation: "ashift", name: "straighten", iopOrder: 95, defaultEnabled: false,
            fields: [field("rotation", -45, 45, 0),
                     FieldSchema(name: "cropmode", description: "automatic cropping", kind: .enumeration, min: 0, max: 0,
                                 defaultValue: .option("ASHIFT_CROP_LARGEST"), options: cropModes),
                     field("cl", 0, 1, 0), field("cr", 0, 1, 1), field("ct", 0, 1, 0), field("cb", 0, 1, 1)],
            apply: { image, _ in image })
        var crop = CIModule(
            operation: "crop", name: "crop", iopOrder: 96, defaultEnabled: false,
            fields: [field("cx", 0, 1, 0), field("cy", 0, 1, 0), field("cw", 0, 1, 1), field("ch", 0, 1, 1)],
            apply: { image, _ in image })
        flip.geometry = true
        straighten.geometry = true
        crop.geometry = true
        return [flip, straighten, crop]
    }()

    /// The catalogue as the engine lists it: the Core Image modules, the display transform, then geometry.
    /// Modules whose output moved when the working space changed from sRGB primaries to Rec.2020 (their luminance, OkLab or tone stage is
    /// in the working primaries): a saved edit made before shows the "maths changed" notice. The other modules (gains, curves, levels,
    /// the curves, levels) are per channel and did not move. `colorize` is a Core Image filter that weighs the channels, so it moved too (3: then Core Image's CIColorMonochrome became the OkLab tint mix).
    static let workingSpaceVersions: [String: Int] = [
        "display": 3, "colorbalancergb": 3, "monochrome": 3, "splittoning": 2, "sharpen": 3, "bilat": 2, "atrous": 2,
        "denoiseprofile": 2, "hazeremoval": 2, "zones": 2,
        // not the working space: invert was Core Image's complement of the linear value and is now the complement of the encoded one
        "invert": 2,
        // merge wave 2 (2026-10-22): the survivors that grew the controls of a module folded into them
        "rgblevels": 2, "warmth": 2, "colorzones": 2, "channelcurves": 2, "highlightrolloff": 2, "lumabands": 2,
        "vignette": 2,
        "bloom": 2,
        "distortion": 2, "perspective": 2, "caradial": 2,
        "radialblur": 2,
        "clahe": 2,
        "dither": 2,
        "blurs": 3, "lowpass": 4, "soften": 3, "censorize": 2,
        "defringe": 2, "highpass": 2, "retouch": 3, "texturebands": 2,
        "kuwahara": 2,
    ]

    static let all: [CIModule] = (catalogue + [display] + geometryModules).map { module in
        guard let version = workingSpaceVersions[module.operation] else { return module }
        var m = module
        m.algorithmVersion = version
        return m
    }

    static func named(_ operation: String) -> CIModule? {
        all.first { $0.operation == operation }
    }
}
