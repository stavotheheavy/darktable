// Method: linear ramp along a direction, the graduated-neutral-density mask; GPU twin of DarkroomCore.MaskGradient.
// p = [angle radians, position, feather]; t is the signed distance from the frame centre along the direction, in units
// of the frame diagonal, plus 0.5.

import Foundation

enum MetalMaskGradient {
    static let source = #"""
static float mask_gradient(constant float *p, float x, float y, float W, float H) {
    float D = sqrt(W * W + H * H);
    float t = ((x - 0.5f * W) * cos(p[0]) + (y - 0.5f * H) * sin(p[0])) / D + 0.5f;
    return mask_ramp(p[1] - 0.5f * p[2], p[1] + 0.5f * p[2], t);
}
"""#
}
