// Method: OkLab (Björn Ottosson, "A perceptual color space for image processing", 2020), with the matrices
// taken from DarkroomCore.OkLab at run time, so the Metal and Swift versions use the very same numbers.
//
// Shared per-pixel colour helpers for card kernels. A card's Metal source starts with
// `MetalColorCommon.source` and then uses these functions; darkroom-metal-check CC1 to CC3 compare them with
// DarkroomCore (OkLab.fromWorking / toWorking, ColorCommon.luminance / smoothstep).
//
//   float3 cc_to_oklab(float3 rgb)     linear working RGB (sRGB primaries) to OkLab
//   float3 cc_from_oklab(float3 lab)   and back
//   float  cc_luminance(float3 rgb)    Rec.709 luminance
//   float  cc_smoothstep(float e0, float e1, float x)

import DarkroomCore
import Foundation

public enum MetalColorCommon {
    /// The working space's luminance weights as a Metal `float3(...)`, derived from ColorCommon.lumaWeights, for every kernel that needs
    /// a luminance (so the Swift oracle and the GPU use the very same numbers).
    public static var lumaVector: String {
        let w = ColorCommon.lumaWeights
        return String(format: "float3(%.9ff, %.9ff, %.9ff)", w.x, w.y, w.z)
    }

    public static let source: String = {
        func mat(_ name: String, _ m: Mat3) -> String {
            // float3x3 takes columns
            let cols = (0..<3).map { c in "float3(\((0..<3).map { r in String(format: "%.12ff", m.m[r][c]) }.joined(separator: ", ")))" }
            return "constant float3x3 \(name) = float3x3(\(cols.joined(separator: ", ")));"
        }
        return """
        #include <metal_stdlib>
        using namespace metal;

        \(mat("cc_working_to_lms", OkLab.workingToLMS))
        \(mat("cc_working_from_lms", OkLab.workingFromLMS))
        \(mat("cc_lms_to_lab", OkLab.lmsToLabMatrix))
        \(mat("cc_lab_to_lms", OkLab.labToLMSMatrix))

        static float cc_cbrt(float x) { return x < 0.0f ? -pow(-x, 1.0f / 3.0f) : pow(x, 1.0f / 3.0f); }

        static float3 cc_to_oklab(float3 rgb) {
            float3 lms = cc_working_to_lms * rgb;
            return cc_lms_to_lab * float3(cc_cbrt(lms.x), cc_cbrt(lms.y), cc_cbrt(lms.z));
        }

        static float3 cc_from_oklab(float3 lab) {
            float3 c = cc_lab_to_lms * lab;
            return cc_working_from_lms * (c * c * c);
        }

        static float cc_luminance(float3 rgb) { return dot(rgb, \(lumaVector)); }

        static float cc_smoothstep(float e0, float e1, float x) {
            float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
            return t * t * (3.0f - 2.0f * t);
        }

        """
    }()
}
