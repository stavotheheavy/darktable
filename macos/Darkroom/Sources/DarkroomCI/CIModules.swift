import CoreImage
import DarkroomEngineAPI

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
    let apply: @Sendable (CIImage, [String: Double]) -> CIImage

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
            apply: { image, v in
                image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: v["red"] ?? 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: v["green"] ?? 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: v["blue"] ?? 1, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
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
            apply: { image, v in
                image.applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: v["exposure"] ?? 0,
                ])
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
            apply: { image, v in
                image.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: v["y0"] ?? 0),
                    "inputPoint1": CIVector(x: 0.25, y: v["y1"] ?? 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: v["y2"] ?? 0.5),
                    "inputPoint3": CIVector(x: 0.75, y: v["y3"] ?? 0.75),
                    "inputPoint4": CIVector(x: 1, y: v["y4"] ?? 1),
                ])
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
    ]

    /// A float field whose label is its own name, since darktable's descriptions are not carried here.
    static func field(_ name: String, _ min: Double, _ max: Double, _ value: Double) -> FieldSchema {
        FieldSchema(name: name, description: name.replacingOccurrences(of: "_", with: " "), kind: .float,
                    min: min, max: max, defaultValue: .number(value), options: [])
    }

    static func named(_ operation: String) -> CIModule? {
        catalogue.first { $0.operation == operation }
    }
}
