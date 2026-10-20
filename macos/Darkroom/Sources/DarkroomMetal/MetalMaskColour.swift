// Method: colour range mask in OkLab (Ottosson, "A perceptual color space for image processing", 2020): the GPU twin of
// DarkroomCore.MaskColour. p = [hue (rad), half-width (rad), chroma floor, feather].

import Foundation

enum MetalMaskColour {
    static let source = #"""
static float mask_colour(constant float *p, float3 rgb) {
    float3 lab = cc_to_oklab(rgb);
    float C = length(lab.yz);
    float h = atan2(lab.z, lab.y);
    float dh = fabs(atan2(sin(h - p[0]), cos(h - p[0])));
    if (!isfinite(dh) || !isfinite(C)) { return 0.0f; }
    float hueW = 1.0f - mask_ramp(p[1] * (1.0f - p[3]), p[1], dh);
    float chromaW = p[2] <= 0.0f ? 1.0f : mask_ramp(p[2] * (1.0f - p[3]), p[2], C);
    return hueW * chromaW;
}
"""#
}
