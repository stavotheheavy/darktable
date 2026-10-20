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
    ]

    static func named(_ operation: String) -> CIModule? {
        catalogue.first { $0.operation == operation }
    }
}
