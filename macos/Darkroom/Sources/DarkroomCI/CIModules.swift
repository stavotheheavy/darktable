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
        "temperature", "exposure", "colorbalancergb", "channelmixer", "tonecurve", "monochrome", "rgblevels", "splittoning", "display", "invert", "colisa", "velvia",
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
            return u.allSatisfy { $0 == 0 } ? nil : FusedOp(.colorBalance, u)
        case "channelmixer":
            let names = ["red_r", "red_g", "red_b", "green_r", "green_g", "green_b", "blue_r", "blue_g", "blue_b"]
            let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
            let u: [Float] = names.indices.map { Float(v[names[$0]] ?? identity[$0]) }
            return u == identity.map { Float($0) } ? nil : FusedOp(.channelMixer, u)
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
            let hue = (v["filter_hue"] ?? 30) * .pi / 180
            return FusedOp(.monochrome, [Float(intensity), Float(v["filter_strength"] ?? 0), Float(cos(hue)), Float(sin(hue))])
        case "invert":
            return FusedOp(.invert, [])
        case "velvia":
            // Velvia is the colour balance kernel with vibrance only
            let strength = v["strength"] ?? 0
            return strength == 0 ? nil : FusedOp(.colorBalance, [0, 0, Float(strength)])
        case "colisa":
            let brightness = v["brightness"] ?? 0
            let u: [Double] = [v["contrast"] ?? 0, v["saturation"] ?? 0, 0, Colisa.gain(brightness: brightness)]
            return u[0] == 0 && u[1] == 0 && brightness == 0 ? nil : FusedOp(.colisa, u.map { Float($0) })
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

    /// A fusable module on its own (masked, partly faded, or the only one in its run): the same op through the same kernel.
    static func applyFused(_ operation: String, _ image: CIImage, _ v: [String: Double]) throws -> CIImage {
        guard let op = fusedOp(operation, v) else { return image }
        return try CIBridge.fused(image, ops: [op])
    }

    /// Modules that read a neighbourhood (a blur radius, a guided filter, wavelet levels): the expensive ones. The segment cache keeps
    /// the picture after each of them, so a slider moved further down the stack does not run them again.
    static let neighbourhoodOperations: Set<String> = [
        "sharpen", "denoiseprofile", "bilat", "atrous", "hazeremoval", "zones", "clahe", "soften", "blurs", "lowpass", "bloom", "highlights",
    ]

    /// The display-referred modules: they assume 0...1 values (a curve, levels, a contrast about 0.5, a lift of the shadows) and are
    /// only meaningful on display light, so with a scene-referred module on they run after it. Every other module is scene-referred
    /// (a gain, a colour balance, white balance, neighbourhood filters, vignette, masks) and runs before the display transform.
    /// `invert` is raw-level negative inversion and stays early; `bloom` is glow from over-bright light, a scene-light effect. Checked, module by module, by darkroom-engine-check E-DOM.
    static let displayReferredOperations: Set<String> = [
        "tonecurve", "rgblevels", "rgbcurve", "basecurve", "colisa", "colorcorrection", "colorcontrast", "velvia", "shadhi",
        "relight", "dither", "colorize", "clahe", "splittoning",
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
            operation: "colorbalancergb", name: "color balance (OkLab)", iopOrder: 25,
            defaultEnabled: false,
            fields: [
                FieldSchema(name: "vibrance", description: "vibrance", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
                FieldSchema(name: "contrast", description: "contrast", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
                FieldSchema(name: "saturation_global", description: "global saturation", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
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

        // Channel mixer: a 3x3 matrix on RGB; the identity leaves the image unchanged.
        CIModule(
            operation: "channelmixer", name: "channel mixer", iopOrder: 22, defaultEnabled: false,
            fields: [
                field("red_r", -2, 2, 1), field("red_g", -2, 2, 0), field("red_b", -2, 2, 0),
                field("green_r", -2, 2, 0), field("green_g", -2, 2, 1), field("green_b", -2, 2, 0),
                field("blue_r", -2, 2, 0), field("blue_g", -2, 2, 0), field("blue_b", -2, 2, 1),
            ],
            // DarkroomCore's ChannelMixer on the oracle-checked per-pixel kernel (darkroom-engine-check E-CM)
            apply: { image, v in try CIModule.applyFused("channelmixer", image, v) }),

        // Shadows and highlights: lift or hold the two ends of the tonal range.
        CIModule(
            operation: "shadhi", name: "shadows and highlights", iopOrder: 35, defaultEnabled: false,
            fields: [
                field("shadows", -100, 100, 0),
                field("highlights", -100, 100, 0),
            ],
            // DarkroomCore's Shadhi: the zone exposure's shadows and highlights controls (darkroom-engine-check E-SHD)
            apply: { image, v in
                let settings = Shadhi.settings(shadows: v["shadows"] ?? 0, highlights: v["highlights"] ?? 0)
                guard !settings.isIdentity else { return image }
                let e = image.extent
                let r = ZoneExposure.radius(scale: settings.scale, longSide: Int(max(e.width, e.height)))
                return try CIBridge.zoneExposure(image, evs: settings.zoneEVs, radius: r)
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

        // Contrast, brightness and saturation, as darktable's contrast brightness saturation
        // module names them.
        CIModule(
            operation: "colisa", name: "contrast brightness saturation", iopOrder: 28,
            defaultEnabled: false,
            fields: [
                field("contrast", -1, 1, 0), field("brightness", -1, 1, 0), field("saturation", -1, 1, 0),
            ],
            // DarkroomCore's Colisa on the oracle-checked per-pixel kernel (darkroom-engine-check E-CL): contrast about middle grey,
            // OkLab saturation, brightness as 2^(2 * brightness) of exposure
            apply: { image, v in try CIModule.applyFused("colisa", image, v) }),

        // Velvia: boosts the less saturated colours more than the saturated ones.
        CIModule(
            operation: "velvia", name: "velvia", iopOrder: 27, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0)],
            // DarkroomCore's Velvia (the colour balance vibrance) on the oracle-checked per-pixel kernel (darkroom-engine-check E-VE)
            apply: { image, v in try CIModule.applyFused("velvia", image, v) }),

        // Monochrome: black and white with a colour filter. Intensity 0 leaves the image unchanged; greys stay grey.
        CIModule(
            operation: "monochrome", name: "monochrome", iopOrder: 45,
            defaultEnabled: false,
            fields: [field("intensity", 0, 1, 0), field("filter_hue", 0, 360, 30), field("filter_strength", 0, 1, 0)],
            // DarkroomCore's Monochrome on the oracle-checked per-pixel kernel (darkroom-engine-check E-MO)
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
            apply: { image, v in
                image.applyingFilter("CIBloom", parameters: [
                    kCIInputIntensityKey: v["strength"] ?? 0,
                    kCIInputRadiusKey: (v["size"] ?? 10) * (v["_scale"] ?? 1),
                ])
            }),

        // Invert: a negative of the image, the complement of each channel's display-encoded value. No parameters.
        CIModule(
            operation: "invert", name: "invert", iopOrder: 3, defaultEnabled: false,
            fields: [],
            // DarkroomCore's Invert on the oracle-checked per-pixel kernel (darkroom-engine-check E-IV)
            apply: { image, v in try CIModule.applyFused("invert", image, v) }),

        // Gamma, approximate basecurve: a power curve on the image. 1.0 is the identity.
        CIModule(
            operation: "basecurve", name: "base curve (gamma, approximate)", iopOrder: 34,
            defaultEnabled: false,
            fields: [field("gamma", 0.2, 3, 1)],
            apply: { image, v in
                image.applyingFilter("CIGammaAdjust", parameters: [
                    "inputPower": v["gamma"] ?? 1,
                ])
            }),

        // Levels: black, grey and white points on the encoded value, one kernel per pixel. Checked by
        // LV1-LV5 (darkroom-core-check), the levels Metal check (darkroom-metal-check) and E-LV (darkroom-engine-check).
        CIModule(
            operation: "rgblevels", name: "rgb levels", iopOrder: 33,
            defaultEnabled: false,
            fields: [field("black", 0, 0.5, 0), field("grey", 0.1, 0.9, 0.5), field("white", 0.5, 1, 1)],
            apply: { image, v in try CIModule.applyFused("rgblevels", image, v) }),

        // Colorize, approximate: tints the image towards a hue at a strength.
        CIModule(
            operation: "colorize", name: "colorize (approximate)", iopOrder: 46, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("hue", 0, 1, 0)],
            apply: { image, v in
                let hue = v["hue"] ?? 0
                let tint = CIColor(red: CGFloat(0.5 + 0.5 * cos(2 * .pi * hue)),
                                   green: CGFloat(0.5 + 0.5 * cos(2 * .pi * (hue - 1.0 / 3))),
                                   blue: CGFloat(0.5 + 0.5 * cos(2 * .pi * (hue - 2.0 / 3))))
                return image.applyingFilter("CIColorMonochrome", parameters: [
                    kCIInputColorKey: tint,
                    kCIInputIntensityKey: v["strength"] ?? 0,
                ])
            }),

        // Blur, approximate: a Gaussian blur over the image, mixed in by opacity.
        CIModule(
            operation: "blurs", name: "blurs (approximate)", iopOrder: 48, defaultEnabled: false,
            fields: [field("radius", 0, 50, 0)],
            apply: { image, v in
                let radius = (v["radius"] ?? 0) * (v["_scale"] ?? 1)
                guard radius > 0 else { return image }
                return image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: image.extent)
            }),

        // Low-pass, approximate: keeps the fine detail removed by a blur, as its detail.
        CIModule(
            operation: "lowpass", name: "lowpass (approximate)", iopOrder: 49, defaultEnabled: false,
            fields: [field("radius", 0, 50, 0)],
            apply: { image, v in
                let radius = (v["radius"] ?? 0) * (v["_scale"] ?? 1)
                guard radius > 0 else { return image }
                let blurred = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: image.extent)
                return blurred
            }),

        // Dither, approximate: posterizes the image to a number of levels.
        CIModule(
            operation: "dither", name: "dither or posterize (approximate)", iopOrder: 60,
            defaultEnabled: false,
            fields: [field("levels", 2, 64, 64)],
            apply: { image, v in
                image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": v["levels"] ?? 64])
            }),

        // Censorize, approximate: pixelates the image; a larger size hides more detail.
        CIModule(
            operation: "censorize", name: "censorize (approximate)", iopOrder: 61, defaultEnabled: false,
            fields: [field("pixelation", 1, 100, 1)],
            apply: { image, v in
                let size = max((v["pixelation"] ?? 1) * (v["_scale"] ?? 1), 1)
                guard (v["pixelation"] ?? 1) > 1 else { return image }
                return image.applyingFilter("CIPixellate", parameters: [
                    "inputScale": size,
                    "inputCenter": CIVector(x: image.extent.midX, y: image.extent.midY),
                ]).cropped(to: image.extent)
            }),

        // Soften, approximate: a blurred copy mixed back over the image.
        CIModule(
            operation: "soften", name: "soften (approximate)", iopOrder: 62, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("radius", 1, 30, 4)],
            apply: { image, v in
                let strength = v["strength"] ?? 0
                guard strength > 0 else { return image }
                let blurred = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: (v["radius"] ?? 4) * (v["_scale"] ?? 1)])
                    .cropped(to: image.extent)
                let mixed = blurred.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(strength)),
                ])
                return mixed.composited(over: image)
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
            operation: "bilat", name: "local contrast", iopOrder: 47,
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

        // RGB curve, approximate: the same five-node curve as tone curve, applied to every channel.
        CIModule(
            operation: "rgbcurve", name: "rgb curve (approximate)", iopOrder: 32, defaultEnabled: false,
            fields: [
                field("y0", 0, 1, 0), field("y1", 0, 1, 0.25), field("y2", 0, 1, 0.5),
                field("y3", 0, 1, 0.75), field("y4", 0, 1, 1),
            ],
            apply: { image, v in
                image.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: v["y0"] ?? 0),
                    "inputPoint1": CIVector(x: 0.25, y: v["y1"] ?? 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: v["y2"] ?? 0.5),
                    "inputPoint3": CIVector(x: 0.75, y: v["y3"] ?? 0.75),
                    "inputPoint4": CIVector(x: 1, y: v["y4"] ?? 1),
                ])
            }),

        // Relight (fill light), approximate: lifts the shadows, leaves the highlights.
        CIModule(
            operation: "relight", name: "fill light (approximate)", iopOrder: 26, defaultEnabled: false,
            fields: [field("fill", 0, 1, 0)],
            apply: { image, v in
                image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputShadowAmount": v["fill"] ?? 0,
                    "inputHighlightAmount": 1,
                ])
            }),

        // Colour contrast, approximate: a saturation change from Core Image's colour controls.
        CIModule(
            operation: "colorcontrast", name: "color contrast (approximate)", iopOrder: 29,
            defaultEnabled: false,
            fields: [field("saturation", -1, 1, 0)],
            apply: { image, v in
                image.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1 + (v["saturation"] ?? 0),
                ])
            }),

        // Colour correction, approximate: a brightness and contrast shift.
        CIModule(
            operation: "colorcorrection", name: "color correction (approximate)", iopOrder: 31,
            defaultEnabled: false,
            fields: [field("brightness", -1, 1, 0), field("contrast", -1, 1, 0)],
            apply: { image, v in
                image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: v["brightness"] ?? 0,
                    kCIInputContrastKey: 1 + (v["contrast"] ?? 0),
                ])
            }),

        // Clahe, approximate: local contrast by unsharp masking; not the tile-based CLAHE.
        CIModule(
            operation: "clahe", name: "old local contrast (approximate)", iopOrder: 64,
            defaultEnabled: false,
            fields: [field("strength", 0, 2, 0)],
            apply: { image, v in
                image.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 8 * (v["_scale"] ?? 1),
                    kCIInputIntensityKey: v["strength"] ?? 0,
                ])
            }),
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
            operation: "ashift", name: "rotate and straighten", iopOrder: 95, defaultEnabled: false,
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
    /// the curves, levels) are per channel and did not move. `colorize` is a Core Image filter that weighs the channels, so it moved too.
    static let workingSpaceVersions: [String: Int] = [
        "display": 3, "colorbalancergb": 2, "monochrome": 2, "splittoning": 2, "sharpen": 2, "bilat": 2, "atrous": 2,
        "denoiseprofile": 2, "hazeremoval": 2, "zones": 2, "colorize": 2,
        // not the working space: invert was Core Image's complement of the linear value and is now the complement of the encoded one
        "invert": 2,
        // same: colisa was Core Image's colour controls (pivot 0.5, additive brightness) and is now scene-referred
        "colisa": 2,
        // same: velvia was Core Image's vibrance and is now the OkLab vibrance step of colour balance
        "velvia": 2,
        // same: vignette was Core Image's CIVignette and is now a scene-referred exposure change through the radial light matte
        "vignette": 2,
        // same: shadhi was Core Image's CIHighlightShadowAdjust and is now the zone exposure's shadows and highlights
        "shadhi": 2,
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
