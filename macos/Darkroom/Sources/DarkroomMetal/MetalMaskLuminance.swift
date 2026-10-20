// Method: luminance range mask (see MaskLuminance): smoothstep window on s = sqrt(Rec.709 luminance).

import Foundation

enum MetalMaskLuminance {
    static let source = #"""
static float mask_luminance(constant float *p, float3 rgb) {
    float y = cc_luminance(rgb);
    float s = isfinite(y) ? sqrt(max(y, 0.0f)) : 0.0f;
    float low = p[0], high = p[1];
    float fw = p[2] * (high - low) * 0.5f;
    return mask_ramp(low, low + fw, s) * (1.0f - mask_ramp(high - fw, high, s));
}
"""#
}
