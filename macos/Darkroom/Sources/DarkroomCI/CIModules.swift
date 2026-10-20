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
    /// Geometry (flip, straighten, crop): skipped by the per-pixel loop, applied once by `CIGeometry`.
    var geometry = false

    func defaultValue(_ field: String) -> Double? {
        fields.first { $0.name == field }?.defaultValue.double
    }

    /// The numeric value of each field: from the stack entry, else the field's default.
    func values(from params: [String: ParamValue]) -> [String: Double] {
        var out: [String: Double] = [:]
        for f in fields {
            out[f.name] = params[f.name]?.double ?? f.defaultValue.double ?? 0
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
            apply: { image, v in
                try CIBridge.gain(image, scale: SIMD3(v["red"] ?? 1, v["green"] ?? 1, v["blue"] ?? 1))
            }),

        // Colour balance, as an approximation: vibrance and global saturation and contrast
        // from Core Image's own controls. Not darktable's colour balance rgb maths; the
        // difference is a known gap, not a match.
        CIModule(
            operation: "colorbalancergb", name: "color balance rgb (approximate)", iopOrder: 25,
            defaultEnabled: false,
            fields: [
                FieldSchema(name: "vibrance", description: "vibrance", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
                FieldSchema(name: "contrast", description: "contrast", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
                FieldSchema(name: "saturation_global", description: "global saturation", kind: .float,
                            min: -1, max: 1, defaultValue: .number(0), options: []),
            ],
            apply: { image, v in
                let vibrant = image.applyingFilter("CIVibrance", parameters: [
                    kCIInputAmountKey: v["vibrance"] ?? 0,
                ])
                return vibrant.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1 + (v["saturation_global"] ?? 0),
                    kCIInputContrastKey: 1 + (v["contrast"] ?? 0),
                ])
            }),

        // Exposure in stops, applied as a gain on linear light.
        CIModule(
            operation: "exposure", name: "exposure", iopOrder: 20, defaultEnabled: false,
            fields: [
                FieldSchema(name: "exposure", description: "exposure", kind: .float,
                            min: -18, max: 18, defaultValue: .number(0), options: []),
            ],
            // DarkroomCore's Exposure.gain on the oracle-checked gain kernel (darkroom-engine-check E2)
            apply: { image, v in
                let g = Exposure.gain(ev: v["exposure"] ?? 0)
                return try CIBridge.gain(image, scale: SIMD3(g, g, g))
            }),

        // Luminance sharpening: amount and the radius it works over.
        CIModule(
            operation: "sharpen", name: "sharpen", iopOrder: 30, defaultEnabled: false,
            fields: [
                FieldSchema(name: "amount", description: "amount", kind: .float,
                            min: 0, max: 2, defaultValue: .number(0.4), options: []),
                FieldSchema(name: "radius", description: "radius", kind: .float,
                            min: 0.5, max: 8, defaultValue: .number(1.5), options: []),
            ],
            apply: { image, v in
                image.applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: v["amount"] ?? 0.4,
                    kCIInputRadiusKey: v["radius"] ?? 1.5,
                ])
            }),

        // Noise reduction, approximate: Core Image's luminance noise reduction. Zero is off.
        CIModule(
            operation: "denoiseprofile", name: "denoise (profiled, approximate)", iopOrder: 5,
            defaultEnabled: false,
            fields: [
                field("strength", 0, 1, 0),
            ],
            apply: { image, v in
                image.applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": v["strength"] ?? 0,
                    "inputSharpness": 0.4,
                ])
            }),

        // Channel mixer: a 3x3 matrix on RGB; the identity leaves the image unchanged.
        CIModule(
            operation: "channelmixer", name: "channel mixer", iopOrder: 22, defaultEnabled: false,
            fields: [
                field("red_r", -2, 2, 1), field("red_g", -2, 2, 0), field("red_b", -2, 2, 0),
                field("green_r", -2, 2, 0), field("green_g", -2, 2, 1), field("green_b", -2, 2, 0),
                field("blue_r", -2, 2, 0), field("blue_g", -2, 2, 0), field("blue_b", -2, 2, 1),
            ],
            apply: { image, v in
                image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: v["red_r"] ?? 1, y: v["red_g"] ?? 0, z: v["red_b"] ?? 0, w: 0),
                    "inputGVector": CIVector(x: v["green_r"] ?? 0, y: v["green_g"] ?? 1, z: v["green_b"] ?? 0, w: 0),
                    "inputBVector": CIVector(x: v["blue_r"] ?? 0, y: v["blue_g"] ?? 0, z: v["blue_b"] ?? 1, w: 0),
                ])
            }),

        // Shadows and highlights: lift or hold the two ends of the tonal range.
        CIModule(
            operation: "shadhi", name: "shadows and highlights", iopOrder: 35, defaultEnabled: false,
            fields: [
                field("shadows", -100, 100, 0),
                field("highlights", -100, 100, 0),
            ],
            apply: { image, v in
                image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputShadowAmount": (v["shadows"] ?? 0) / 100,
                    "inputHighlightAmount": 1 + (v["highlights"] ?? 0) / 100,
                ])
            }),

        // Tone curve: five nodes across the tonal range; the identity curve has each node at
        // its own input value.
        CIModule(
            operation: "tonecurve", name: "tone curve", iopOrder: 36, defaultEnabled: false,
            fields: [
                field("y0", 0, 1, 0), field("y1", 0, 1, 0.25), field("y2", 0, 1, 0.5),
                field("y3", 0, 1, 0.75), field("y4", 0, 1, 1),
            ],
            // DarkroomCore's ToneCurve on the oracle-checked per-pixel kernel (darkroom-engine-check E-TC)
            apply: { image, v in
                let ys: [Double] = [v["y0"] ?? 0, v["y1"] ?? 0.25, v["y2"] ?? 0.5, v["y3"] ?? 0.75, v["y4"] ?? 1]
                let tangents: [Double] = ToneCurve.tangents(ys)
                let uniforms: [Float] = (ys + tangents).map { Float($0) }
                return try CIBridge.perPixel(image, source: MetalToneCurve.source, function: "tonecurveTex", uniforms: uniforms)
            }),

        // Contrast, brightness and saturation, as darktable's contrast brightness saturation
        // module names them.
        CIModule(
            operation: "colisa", name: "contrast brightness saturation", iopOrder: 28,
            defaultEnabled: false,
            fields: [
                field("contrast", -1, 1, 0), field("brightness", -1, 1, 0), field("saturation", -1, 1, 0),
            ],
            apply: { image, v in
                image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: v["brightness"] ?? 0,
                    kCIInputContrastKey: 1 + (v["contrast"] ?? 0),
                    kCIInputSaturationKey: 1 + (v["saturation"] ?? 0),
                ])
            }),

        // Velvia: boosts the less saturated colours more than the saturated ones.
        CIModule(
            operation: "velvia", name: "velvia", iopOrder: 27, defaultEnabled: false,
            fields: [field("strength", 0, 1, 0)],
            apply: { image, v in
                image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: v["strength"] ?? 0])
            }),

        // Monochrome, approximate: a single tint colour over the luminance.
        CIModule(
            operation: "monochrome", name: "monochrome (approximate)", iopOrder: 45,
            defaultEnabled: false,
            fields: [field("intensity", 0, 1, 0)],
            apply: { image, v in
                image.applyingFilter("CIColorMonochrome", parameters: [
                    kCIInputColorKey: CIColor(red: 0.5, green: 0.5, blue: 0.5),
                    kCIInputIntensityKey: v["intensity"] ?? 0,
                ])
            }),

        // Vignetting: darkens the corners. Zero strength is off.
        CIModule(
            operation: "vignette", name: "vignetting", iopOrder: 40, defaultEnabled: false,
            fields: [
                field("strength", 0, 2, 0),
                field("scale", 0, 2, 1),
            ],
            apply: { image, v in
                image.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: -(v["strength"] ?? 0),
                    kCIInputRadiusKey: 1 + (v["scale"] ?? 1) * 2,
                ])
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
                    kCIInputRadiusKey: v["size"] ?? 10,
                ])
            }),

        // Invert: a negative of the image. No parameters.
        CIModule(
            operation: "invert", name: "invert", iopOrder: 3, defaultEnabled: false,
            fields: [],
            apply: { image, _ in image.applyingFilter("CIColorInvert") }),

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
            apply: { image, v in
                let black = v["black"] ?? 0
                let white = max(v["white"] ?? 1, black + 0.01)
                let grey = min(max(v["grey"] ?? 0.5, 0.01), 0.99)
                let gamma = log(0.5) / log(grey)
                return try CIBridge.perPixel(image, source: MetalLevels.source, function: "levelsTex",
                                             uniforms: [Float(black), Float(white), Float(gamma)])
            }),

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
                let radius = v["radius"] ?? 0
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
                let radius = v["radius"] ?? 0
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
                let size = v["pixelation"] ?? 1
                guard size > 1 else { return image }
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
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v["radius"] ?? 4])
                    .cropped(to: image.extent)
                let mixed = blurred.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(strength)),
                ])
                return mixed.composited(over: image)
            }),

        // Split toning, approximate: a warm tint for highlights and a cool one for shadows.
        // Uses one tint over the image at the chosen strength; the two-tone split is not built.
        CIModule(
            operation: "splittoning", name: "split-toning (approximate)", iopOrder: 63,
            defaultEnabled: false,
            fields: [field("strength", 0, 1, 0), field("hue", 0, 1, 0.1)],
            apply: { image, v in
                let hue = v["hue"] ?? 0.1
                let tint = CIColor(red: CGFloat(0.5 + 0.5 * cos(2 * .pi * hue)),
                                   green: CGFloat(0.5 + 0.5 * cos(2 * .pi * (hue - 1.0 / 3))),
                                   blue: CGFloat(0.5 + 0.5 * cos(2 * .pi * (hue - 2.0 / 3))))
                return image.applyingFilter("CIColorMonochrome", parameters: [
                    kCIInputColorKey: tint,
                    kCIInputIntensityKey: v["strength"] ?? 0,
                ])
            }),

        // Local contrast, approximate: unsharp masking at a radius, which lifts local detail.
        CIModule(
            operation: "bilat", name: "local contrast (approximate)", iopOrder: 47,
            defaultEnabled: false,
            fields: [field("detail", 0, 2, 0), field("radius", 1, 50, 10)],
            apply: { image, v in
                image.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: v["radius"] ?? 10,
                    kCIInputIntensityKey: v["detail"] ?? 0,
                ])
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
                    kCIInputRadiusKey: 8,
                    kCIInputIntensityKey: v["strength"] ?? 0,
                ])
            }),
    ]

    /// A float field whose label is its own name, since darktable's descriptions are not carried here.
    static func field(_ name: String, _ min: Double, _ max: Double, _ value: Double) -> FieldSchema {
        FieldSchema(name: name, description: name.replacingOccurrences(of: "_", with: " "), kind: .float,
                    min: min, max: max, defaultValue: .number(value), options: [])
    }

    /// The scene-referred display transform: DarkroomCore's ToneMap and display matrix on the oracle-checked
    /// kernel. Enabling it switches the decode to scene-linear (see `CIModule.sceneReferred`).
    static let display: CIModule = {
        var m = CIModule(
            operation: "display", name: "display transform (scene-referred)", iopOrder: 90, defaultEnabled: false,
            fields: [
                FieldSchema(name: "contrast", description: "contrast", kind: .float,
                            min: -100, max: 100, defaultValue: .number(0), options: []),
            ],
            apply: { image, v in try CIBridge.toneDisplay(image, contrast: v["contrast"] ?? 0) })
        m.sceneReferred = true
        return m
    }()

    /// Flip, straighten and crop, with darktable's parameter names (read from its introspection) so one
    /// stack drives either engine. Their pixels come from `CIGeometry`; `apply` here is never called.
    static let geometryModules: [CIModule] = {
        func opt(_ name: String, _ value: Int, _ label: String) -> EnumOption { EnumOption(name: name, value: value, label: label) }
        let orientations = [
            opt("ORIENTATION_NONE", 0, "none"), opt("ORIENTATION_FLIP_HORIZONTALLY", 2, "flip horizontally"),
            opt("ORIENTATION_FLIP_VERTICALLY", 1, "flip vertically"), opt("ORIENTATION_ROTATE_180_DEG", 3, "rotate 180 deg"),
            opt("ORIENTATION_ROTATE_CW_90_DEG", 5, "rotate cw 90 deg"), opt("ORIENTATION_ROTATE_CCW_90_DEG", 6, "rotate ccw 90 deg"),
            opt("ORIENTATION_TRANSPOSE", 4, "transpose"), opt("ORIENTATION_TRANSVERSE", 7, "transverse"),
        ]
        let cropModes = [opt("ASHIFT_CROP_OFF", 0, "off"), opt("ASHIFT_CROP_LARGEST", 1, "largest"),
                         opt("ASHIFT_CROP_ASPECT", 2, "aspect")]
        var flip = CIModule(
            operation: "flip", name: "orientation", iopOrder: 1, defaultEnabled: false,
            fields: [FieldSchema(name: "orientation", description: "orientation", kind: .enumeration, min: 0, max: 0,
                                 defaultValue: .option("ORIENTATION_NONE"), options: orientations)],
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
    static let all: [CIModule] = catalogue + [display] + geometryModules

    static func named(_ operation: String) -> CIModule? {
        all.first { $0.operation == operation }
    }
}
