// Method: distance in the ellipse's own axes (the point rotated into the ellipse frame, scaled by the radii), faded with a smoothstep over the inner `feather` fraction of the radius; the GPU twin of MaskEllipse.

import Foundation

enum MetalMaskEllipse {
    static let source = #"""
static float mask_ellipse(constant float *p, float x, float y, float W, float H) {
    float D = sqrt(W * W + H * H);
    float dx = x - p[0] * W, dy = y - p[1] * H;
    float c = cos(p[4]), s = sin(p[4]);
    float u = dx * c + dy * s;
    float v = -dx * s + dy * c;
    float r = length(float2(u / (p[2] * D), v / (p[3] * D)));
    if (!isfinite(r)) { r = INFINITY; }
    return 1.0f - mask_ramp(1.0f - p[5], 1.0f, r);
}
"""#
}
