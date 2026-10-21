// Method: a luminance-driven scene-to-display tone stage with a smooth shoulder.
//   - the norm: scale all three channels by T(n) / n with n the scene luminance, so channel ratios, and with them hue,
//     are kept (T. Lottes, "Advanced Techniques and Optimization of HDR Color Pipelines", GDC 2016, on norm choice);
//   - the shoulder: a cubic Hermite roll-off that leaves the straight part with its own slope and reaches the white
//     point with slope zero, the construction ITU-R BT.2390 (Annex 5) uses for its EETF knee; the monotone limit on the
//     start slope is Fritsch and Carlson, SIAM J. Numer. Anal. 17(2), 1980;
//   - the way to white: above the knee colours blend toward their own neutral, so a bright saturated colour bleaches
//     instead of stopping at a clipped channel;
//   - the gamut step: a colour outside the display gamut keeps its OkLab lightness and hue and loses chroma until it fits
//     (B. Ottosson, "sRGB gamut clipping", 2021, the constant-lightness projection), instead of being cut per channel.
// Written from those references and from Apple's colour documentation only.
//
// Colours come in and go out in the engine's working primaries (linear Rec.2020, ColorSpaces.workingToXYZ). The gamut step maps them
// into the cube of the OUTPUT gamut (sRGB for exports and thumbnails, Display P3 for the canvas) and hands them back in working
// primaries, so Core Image's last conversion to the destination never has to clip a colour the display can show.
//
// This replaces ToneMap's per-channel extended Reinhard curve, whose `min(..., 1)` was a hard clip at +2.7 EV over grey.

import Foundation

/// The gamut the display transform maps into. Its cube is where "in gamut" is tested; the picture stays in working primaries.
public enum OutputGamut: Int, Sendable {
    case sRGB = 0, displayP3 = 1

    var toXYZ: Mat3 { self == .sRGB ? ColorSpaces.srgbToXYZ : ColorSpaces.p3ToXYZ }
    /// Working-space RGB to this gamut's linear RGB (components outside 0...1 are out of gamut).
    public var fromWorking: Mat3 { toXYZ.inverse()!.mul(ColorSpaces.workingToXYZ) }
    /// This gamut's linear RGB to working-space RGB.
    public var toWorking: Mat3 { ColorSpaces.workingToXYZ.inverse()!.mul(toXYZ) }
}

public struct SceneTone: Sendable {
    public static let grey = 0.18
    /// Scene luminance below this (grey at -14 EV) is treated as this when forming T(n) / n, so the ratio stays finite
    /// for black, and for pixels whose luminance is zero or negative because a channel is.
    public static let minEV = -14.0
    public static let ymin = grey * pow(2, minEV)

    public let contrast: Double
    /// The display-linear value the picture tops out at: 1 is SDR white, more is an HDR render's headroom.
    public let peak: Double
    /// EV over grey that maps to `peak`. The default is the decoder's top (about +4 EV with extended range) plus the
    /// display module's +0.5 EV start.
    public let whiteEV: Double
    /// 0 keeps a bright colour's hue and saturation to the top of the curve, 1 bleaches it fully into the neutral.
    public let purity: Double
    /// Gain of the straight part: log output per log input, grey at grey.
    public let slope: Double
    /// Where the shoulder starts, in EV over grey, and the display value there.
    public let kneeEV: Double
    public let kneeValue: Double
    /// d(display)/d(EV) at the knee, after the monotone limit.
    public let kneeSlope: Double
    /// Shoulder length in EV (knee to the white point of this render).
    public let shoulderEV: Double
    /// The gamut the picture is mapped into.
    public let target: OutputGamut

    public static let defaultWhiteEV = 4.5
    public static let defaultPurity = 0.5
    /// The display value the straight part may reach before the shoulder takes over, before the monotone limit lowers it.
    static let kneeLevel = 0.55

    public init(contrast: Double = 0, whiteEV: Double = SceneTone.defaultWhiteEV, purity: Double = SceneTone.defaultPurity, peak: Double = 1,
                target: OutputGamut = .sRGB) {
        let c = contrast.isFinite ? min(max(contrast, -100), 100) / 100 : 0
        let slope = c >= 0 ? 1 + 0.55 * c : 1 + 0.4 * c
        let peak = peak.isFinite ? min(max(peak, 1), 8) : 1
        let w = whiteEV.isFinite ? min(max(whiteEV, 1.5), 8) : Self.defaultWhiteEV
        self.contrast = contrast; self.peak = peak; self.slope = slope; self.target = target
        self.purity = purity.isFinite ? min(max(purity, 0), 1) : Self.defaultPurity

        // The knee comes from the SDR render, so an HDR render agrees with it everywhere below the knee. A knee that
        // would make the shoulder fold (start slope above 3x the secant, Fritsch and Carlson) is moved down until it doesn't.
        var level = Self.kneeLevel
        var kneeX = log2(level / Self.grey) / slope
        func startSlope(_ level: Double) -> Double { level * slope * log(2) }
        while level > 0.02 {
            kneeX = log2(level / Self.grey) / slope
            let h = max(w, kneeX + 0.5) - kneeX
            if startSlope(level) <= 3 * (1 - level) / h { break }
            level *= 0.9
        }
        self.kneeValue = level
        self.kneeEV = kneeX
        self.kneeSlope = startSlope(level)
        let hdrWhite = peak > 1 ? w + log2(peak) : w
        self.whiteEV = max(hdrWhite, kneeX + 0.5)
        self.shoulderEV = self.whiteEV - kneeX
    }

    /// Display-linear value for `x` EV over grey: the straight part, then the Hermite shoulder to `peak` at `whiteEV`.
    public func curve(_ x: Double) -> Double {
        if x <= kneeEV { return Self.grey * pow(2, slope * x) }
        let t = min((x - kneeEV) / shoulderEV, 1)
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2
        return h00 * kneeValue + h10 * shoulderEV * kneeSlope + h01 * peak
    }

    /// The tone-mapped value of a scene luminance.
    public func apply(_ n: Double) -> Double {
        let ne = max(n.isFinite ? n : 0, Self.ymin)
        return curve(log2(ne / Self.grey))
    }

    /// Luminance of a working-space colour (the Y row of the working primaries).
    public static func luminance(_ p: SIMD3<Double>) -> Double { ColorCommon.luminance(p) }

    /// A scene-linear working-space colour to display-linear, in working primaries and inside the target gamut's cube (0...peak): the
    /// norm, the way to white, the gamut step.
    public func displayLinear(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { return .zero }
        let n = Self.luminance(rgb)
        let ne = max(n, Self.ymin)
        let x = log2(ne / Self.grey)
        let t = curve(x)
        var out = rgb * (t / ne)
        let h = purity * Self.smoothstep(kneeEV, kneeEV + shoulderEV, x)
        if h > 0 { out += (SIMD3(repeating: t) - out) * h }
        return gamutMap(out)
    }

    /// `displayLinear` after a per-channel gain on the input (white balance, exposure and the display module's lift folded into one
    /// multiply).
    public func displayLinear(working rgb: SIMD3<Double>, gain: SIMD3<Double> = SIMD3(repeating: 1)) -> SIMD3<Double> {
        displayLinear(rgb * gain)
    }

    /// A working-space colour (any values) into the target gamut's cube 0...peak, returned in working primaries: a colour already inside is
    /// returned unchanged; one outside keeps its OkLab lightness and hue and has its chroma reduced (bisected) until it fits. Lightness at or
    /// past white gives white, at or under black gives black.
    public func gamutMap(_ working: SIMD3<Double>) -> SIMD3<Double> {
        let eps = 1e-5
        let toTarget = target.fromWorking, toWorking = target.toWorking
        func inside(_ u: SIMD3<Double>) -> Bool { min(u.x, u.y, u.z) >= -eps && max(u.x, u.y, u.z) <= 1 + eps }
        func clampedWorking(_ u: SIMD3<Double>) -> SIMD3<Double> {
            toWorking.apply(SIMD3(min(max(u.x, 0), 1), min(max(u.y, 0), 1), min(max(u.z, 0), 1)) * peak)
        }
        let wn = working / peak
        guard wn.x.isFinite, wn.y.isFinite, wn.z.isFinite else { return .zero }
        let u = toTarget.apply(wn)
        if inside(u) { return clampedWorking(u) }
        let lab = OkLab.fromWorking(wn)
        if lab.x <= 0 { return .zero }
        if lab.x >= 1 { return toWorking.apply(SIMD3(repeating: peak)) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<Self.gamutIterations {
            let mid = (lo + hi) / 2
            if inside(toTarget.apply(OkLab.toWorking(SIMD3(lab.x, lab.y * mid, lab.z * mid)))) { lo = mid } else { hi = mid }
        }
        return clampedWorking(toTarget.apply(OkLab.toWorking(SIMD3(lab.x, lab.y * lo, lab.z * lo))))
    }

    /// Bisection steps of the gamut projection (the kernel runs the same number).
    public static let gamutIterations = 20

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// What the Metal kernel reads (see MetalSceneTone): grey, slope, kneeEV, kneeValue, kneeSlope, shoulderEV, peak, purity, ymin, a spare,
    /// the nine entries of the working-to-target matrix row by row, the three gains, then the nine entries of the target-to-working matrix.
    public func uniforms(gain: SIMD3<Double> = SIMD3(repeating: 1)) -> [Float] {
        var u: [Float] = [Float(Self.grey), Float(slope), Float(kneeEV), Float(kneeValue), Float(kneeSlope)]
        u += [Float(shoulderEV), Float(peak), Float(purity), Float(Self.ymin), 0]
        let wt = target.fromWorking.m, tw = target.toWorking.m
        for r in 0..<3 { for c in 0..<3 { u.append(Float(wt[r][c])) } }
        u += [Float(gain.x), Float(gain.y), Float(gain.z)]
        for r in 0..<3 { for c in 0..<3 { u.append(Float(tw[r][c])) } }
        return u
    }
}
