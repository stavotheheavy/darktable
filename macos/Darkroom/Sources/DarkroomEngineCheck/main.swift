// Engine-path checks (E-series). Run: swift run darkroom-engine-check
// A stack goes through the engine the app runs (CIEngine.applyStack, via CIEngineProbe) and must match the
// DarkroomCore oracle within 1/255 after the sRGB encode. This is what "wired" means in the ledger.
import DarkroomCI
import DarkroomCore
import CoreImage
import DarkroomEngineAPI
import DarkroomMetal
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  " + detail())")
    if !ok { failures += 1 }
}

// 64 by 64 working-space pixels: a warm to cool gradient, deep shadows to highlights above 1
let n = 64
let input: [SIMD4<Float>] = (0..<n * n).map { i in
    let t = Double(i % n) / Double(n - 1), u = Double(i / n) / Double(n - 1)
    return SIMD4(Float(0.001 + 2.4 * t * t), Float(0.002 + 0.9 * u), Float(1.2 - 1.1 * t), 1)
}
let scene = input.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }

func encode(_ v: SIMD3<Double>) -> SIMD3<Double> {
    func e(_ x: Double) -> Double { min(max(Transfer.linearToSRGB(max(x, 0)), 0), 1) }
    return SIMD3(e(v.x), e(v.y), e(v.z))
}

/// Worst channel difference after the sRGB encode, engine against oracle. A non-finite engine value is an
/// infinite error: `max(w, .nan)` would otherwise return `w` and let a NaN kernel pass.
func worst(_ engine: [SIMD4<Float>], _ oracle: [SIMD3<Double>], oracleEncoded: Bool = false) -> Double {
    var w = 0.0
    for (i, o) in oracle.enumerated() where i < engine.count {
        guard engine[i].x.isFinite, engine[i].y.isFinite, engine[i].z.isFinite else { return .infinity }
        let g = encode(SIMD3(Double(engine[i].x), Double(engine[i].y), Double(engine[i].z)))
        let d = g - (oracleEncoded ? o : encode(o))
        w = max(w, abs(d.x), abs(d.y), abs(d.z))
    }
    return engine.count == oracle.count ? w : .infinity
}

/// Worst relative difference on unclamped linear values: |engine - oracle| / max(1, |oracle|). For checks past
/// white, where the encoded comparison above clamps everything to 0...1. Non-finite is an infinite error.
func worstLinear(_ engine: [SIMD4<Float>], _ oracle: [SIMD3<Double>]) -> Double {
    guard engine.count == oracle.count else { return .infinity }
    var w = 0.0
    for (e, o) in zip(engine, oracle) {
        let g = SIMD3<Double>(Double(e.x), Double(e.y), Double(e.z))
        guard g.x.isFinite, g.y.isFinite, g.z.isFinite else { return .infinity }
        for c in 0..<3 { w = max(w, abs(g[c] - o[c]) / max(1, abs(o[c]))) }
    }
    return w
}

func run(_ stack: [StackEntry]) -> [SIMD4<Float>] {
    do { return try CIEngineProbe.render(stack: stack, pixels: input, width: n, height: n) } catch {
        print("FAIL  probe threw: \(error)")
        failures += 1
        return []
    }
}

let tol = 1.0 / 255

// The S5 detail modules are checked on a textured image (the 64 by 64 gradient above has no detail to act on).
let detailW = 48, detailH = 40
let detailImg = DetailCommon.fixture(width: detailW, height: detailH)
let detailPx: [SIMD4<Float>] = detailImg.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }

func runDetail(_ stack: [StackEntry], rasters: [MaskPicture] = []) -> [SIMD4<Float>] {
    do { return try CIEngineProbe.renderSized(stack: stack, pixels: detailPx, width: detailW, height: detailH, rasters: rasters).pixels } catch {
        print("FAIL  probe threw: \(error)")
        failures += 1
        return []
    }
}

// Mask helpers (S6). A mask kind is checked by rendering its GPU matte against DarkroomCore's, and by a masked module.
/// Worst absolute difference between the GPU matte for `spec` on `detailImg` and `Mask.plane`. Non-finite or a wrong
/// size is an infinite error.
func maskMatteError(_ spec: MaskSpec) -> Double {
    guard let gpu = try? CIEngineProbe.filter(.mask(spec), pixels: detailPx, width: detailW, height: detailH),
          gpu.count == detailW * detailH else { return .infinity }
    let want = Mask.plane(spec, rgb: detailImg, width: detailW, height: detailH)
    var w = 0.0
    for (g, o) in zip(gpu, want.values) { w = g.x.isFinite ? max(w, abs(Double(g.x) - o)) : .infinity }
    return w
}

/// A +1 EV exposure entry (gain 2) carrying `blend`, the module the mask checks run through the engine.
func maskedExposure(_ blend: [String: ParamValue]) -> StackEntry {
    StackEntry(operation: "exposure", params: ["exposure": .number(1)], blend: blend)
}

/// What a +1 EV exposure behind `spec` must give on `detailImg`.
func maskedExposureOracle(_ spec: MaskSpec) -> [SIMD3<Double>] {
    Mask.apply(spec, to: detailImg, width: detailW, height: detailH) { $0.map { $0 * 2 } }
}

/// Tile seams for a detail module: three regions rendered alone must equal the same pixels of the full frame, and
/// the full frame must be the oracle's (so two blank renders cannot match each other).
func detailSeams(_ stack: [StackEntry], oracle: [SIMD3<Double>], rasters: [MaskPicture] = []) -> (seam: Double, fullVsOracle: Double, ok: Bool) {
    let full = runDetail(stack, rasters: rasters)
    let fullErr = worstLinear(full, oracle)
    var seam = 0.0, ok = full.count == detailW * detailH && fullErr < 2e-4
    for reg in [(x: 17, y: 9, w: 20, h: 18), (x: 0, y: 0, w: 15, h: 15), (x: 30, y: 25, w: 18, h: 15)] {
        guard let part = try? CIEngineProbe.renderRegion(stack: stack, pixels: detailPx, width: detailW, height: detailH, region: reg, rasters: rasters),
              part.count == reg.w * reg.h, full.count == detailW * detailH else { ok = false; continue }
        for yy in 0..<reg.h { for xx in 0..<reg.w {
            let a = part[yy * reg.w + xx], b = full[(reg.y + yy) * detailW + reg.x + xx]
            for c in 0..<4 {
                guard a[c].isFinite else { ok = false; continue }
                seam = max(seam, abs(Double(a[c]) - Double(b[c])))
            }
        } }
    }
    return (seam, fullErr, ok && seam < 1e-6)
}

// E0 an empty stack is the identity
let identity = run([])
check("E0 empty stack returns the input", worst(identity, scene) < 1e-6, "\(worst(identity, scene))")

// E1 white balance coefficients = per-channel gain
let coeff = SIMD3<Double>(1.8, 1.0, 1.4)
let wbStack = [StackEntry(operation: "temperature", params: ["red": .number(coeff.x), "green": .number(coeff.y), "blue": .number(coeff.z)])]
let e1 = worst(run(wbStack), scene.map { $0 * coeff })
check("E1 white balance matches the oracle within 1/255", e1 < tol, "\(e1)")

// E2 exposure = DarkroomCore's Exposure.gain
let ev = 1.3
let e2 = worst(run([StackEntry(operation: "exposure", params: ["exposure": .number(ev)])]), scene.map { $0 * Exposure.gain(ev: ev) })
check("E2 exposure matches the oracle within 1/255", e2 < tol, "\(e2)")

// E3 display transform: working sRGB -> Rec.2020 -> SceneTone (luminance norm, shoulder, gamut step), at three contrasts
for contrast in [0.0, 40.0, -60.0] {
    let tone = SceneTone(contrast: contrast)
    let oracle = scene.map { tone.displayLinear(ColorSpaces.srgbToRec2020.apply($0)) }
    let e3 = worst(run([StackEntry(operation: "display", params: ["contrast": .number(contrast)])]), oracle)
    check("E3 display transform at contrast \(Int(contrast)) matches the oracle within 1/255", e3 < tol, "\(e3)")
}

// E4 a chain in pipeline order regardless of stack order: white balance, exposure, then display
let chain = [StackEntry(operation: "display", params: ["contrast": .number(20)]),
             StackEntry(operation: "exposure", params: ["exposure": .number(-0.7)]),
             wbStack[0]]
let tone20 = SceneTone(contrast: 20)
let chainOracle = scene.map { p -> SIMD3<Double> in
    tone20.displayLinear(ColorSpaces.srgbToRec2020.apply(p * coeff * Exposure.gain(ev: -0.7)))
}
let e4 = worst(run(chain), chainOracle)
check("E4 white balance, exposure, display chain matches the oracle within 1/255", e4 < tol, "\(e4)")

// E5 opacity mixes the module back over its input
let half = StackEntry(operation: "exposure", params: ["exposure": .number(1)], blend: ["opacity": .number(50)])
let e5 = worst(run([half]), scene.map { $0 * 0.5 + $0 * Exposure.gain(ev: 1) * 0.5 })
check("E5 50% opacity is the mean of input and module output", e5 < tol, "\(e5)")

// E6 only scene-referred modules switch the decode to scene-linear
check("E6 display switches the decode to scene-linear", CIEngineProbe.wantsSceneLinear(chain))
check("E6 exposure alone keeps the decoder's tone curve", !CIEngineProbe.wantsSceneLinear([half]))
var off = chain[0]
off.enabled = false
check("E6 a disabled display keeps the decoder's tone curve", !CIEngineProbe.wantsSceneLinear([off]))

// E8 past white: exposure +2.5 EV takes the highlights to about 15; compared unclamped
let hot = 2.5
let e8 = worstLinear(run([StackEntry(operation: "exposure", params: ["exposure": .number(hot)])]), scene.map { $0 * Exposure.gain(ev: hot) })
check("E8 exposure past white matches the oracle unclamped (relative 1e-5)", e8 < 1e-5, "\(e8)")
// E9 the harness itself: a NaN from the engine must fail both comparisons
var poisoned = identity
if !poisoned.isEmpty { poisoned[7].y = .nan }
check("E9 a NaN output fails worst()", worst(poisoned, scene) == .infinity)
check("E9 a NaN output fails worstLinear()", worstLinear(poisoned, scene) == .infinity)

// E7 the per-pixel card path: one source, a texture entry for the engine and a buffer entry for the checks
let probeSource = """
#include <metal_stdlib>
using namespace metal;
static float3 probe_apply(float3 c, constant float *u) { return c * u[0] + u[1]; }
kernel void probeTex(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                     constant float *u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    dst.write(float4(probe_apply(c.rgb, u), c.a), gid);
}
kernel void probeBuf(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]],
                     constant float *u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    dst[i] = float4(probe_apply(src[i].rgb, u), src[i].a);
}
"""
let probeOracle = scene.map { $0 * 0.6 + 0.05 }
do {
    let buf = try MetalPerPixel.run(source: probeSource, function: "probeBuf", pixels: input, uniforms: [0.6, 0.05])
    let e7a = worst(buf, probeOracle)
    check("E7 per-pixel buffer path matches its oracle", e7a < tol, "\(e7a)")
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let img = CIImage(bitmapData: input.withUnsafeBytes { Data($0) }, bytesPerRow: n * 16,
                      size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: space)
    let out = try CIBridge.perPixel(img, source: probeSource, function: "probeTex", uniforms: [0.6, 0.05])
    let ctx = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
    var px = [SIMD4<Float>](repeating: .zero, count: n * n)
    px.withUnsafeMutableBytes { b in
        ctx.render(out, toBitmap: b.baseAddress!, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                   format: .RGBAf, colorSpace: space)
    }
    let e7b = worst(px, probeOracle)
    check("E7 per-pixel texture path inside Core Image matches its oracle", e7b < tol, "\(e7b)")
} catch {
    check("E7 per-pixel path ran", false, "\(error)")
}

// E-LV rgblevels: the levels kernel through the engine, black 0.1, grey 0.4, white 0.9
let eLV = worst(run([StackEntry(operation: "rgblevels", params: ["black": .number(0.1), "grey": .number(0.4), "white": .number(0.9)])]),
                scene.map { Levels.apply($0, black: 0.1, grey: 0.4, white: 0.9) })
check("E-LV rgblevels matches the oracle within 1/255", eLV < tol, "\(eLV)")

// E-TC tone curve: the S-curve through the engine (CIBridge.perPixel, tonecurveTex) against ToneCurve in DarkroomCore
let toneYs = [0, 0.15, 0.5, 0.85, 1.0]
let etc = worst(run([StackEntry(operation: "tonecurve", params: ["y0": .number(0), "y1": .number(0.15), "y2": .number(0.5),
                                                                  "y3": .number(0.85), "y4": .number(1)])]),
                scene.map { ToneCurve.apply($0, ys: toneYs) })
check("E-TC tone curve S-curve matches the oracle within 1/255", etc < tol, "\(etc)")

// E-TC2 with the display transform on, the tone curve runs after it, on display light (not on scene light before it)
do {
    let ys = [0.0, 0.15, 0.5, 0.85, 1.0]
    let curve = StackEntry(operation: "tonecurve", params: ["y0": .number(0), "y1": .number(0.15), "y2": .number(0.5), "y3": .number(0.85), "y4": .number(1)])
    let display = StackEntry(operation: "display", params: ["contrast": .number(0)])
    let tone = SceneTone(contrast: 0)
    let toDisplay: (SIMD3<Double>) -> SIMD3<Double> = { tone.displayLinear(ColorSpaces.srgbToRec2020.apply($0)) }
    let after = scene.map { ToneCurve.apply(toDisplay($0), ys: ys) }
    let before = scene.map { toDisplay(ToneCurve.apply($0, ys: ys)) }
    // listed curve-first on purpose: the engine orders them, not the list
    let got = run([curve, display])
    let eAfter = worst(got, after), eBefore = worst(got, before)
    check("E-TC2 tone curve after the display transform matches the oracle within 1/255", eAfter < tol, "\(eAfter)")
    check("E-TC2 and it is not the curve-before-display order (the two differ by more than 4/255)", eBefore > 4.0 / 255, "\(eBefore)")
}

// G-E geometry through the engine: three coloured 3x3 markers on a dark 120x80 frame must land where the
// DarkroomCore oracle maps them, and the output must have the oracle's size
do {
    let gw = 120, gh = 80
    // marker top-left pixels; each is one channel, so the centroid of that channel finds it
    let markers: [(x: Int, y: Int, channel: Int)] = [(20, 15, 0), (90, 20, 1), (40, 60, 2)]
    var frame = [SIMD4<Float>](repeating: SIMD4(0.01, 0.01, 0.01, 1), count: gw * gh)
    for m in markers {
        for dy in 0..<3 { for dx in 0..<3 { frame[(m.y + dy) * gw + m.x + dx][m.channel] = 1 } }
    }
    func centroid(_ px: [SIMD4<Float>], _ w: Int, _ h: Int, _ c: Int) -> SIMD2<Double>? {
        var sum = SIMD2<Double>(0, 0), weight = 0.0
        for y in 0..<h { for x in 0..<w {
            let v = Double(px[y * w + x][c]) - 0.05
            if v > 0.2 { sum += SIMD2(Double(x) + 0.5, Double(y) + 0.5) * v; weight += v }
        } }
        return weight > 0 ? sum / weight : nil
    }
    func geometryCase(_ name: String, _ stack: [StackEntry], _ spec: GeometrySpec, tol: Double, camera: Orientation = .none) {
        do {
            let r = try CIEngineProbe.renderSized(stack: stack, pixels: frame, width: gw, height: gh, camera: camera)
            let want = spec.outputSize(SIMD2(Double(gw), Double(gh)))
            let sizeOK = r.width == max(1, Int(want.x.rounded())) && r.height == max(1, Int(want.y.rounded()))
            var worstMiss = 0.0
            for m in markers {
                let expected = spec.map(SIMD2(Double(m.x) + 1.5, Double(m.y) + 1.5), size: SIMD2(Double(gw), Double(gh)))
                let inside = expected.x >= 1 && expected.y >= 1 && expected.x <= Double(r.width) - 1 && expected.y <= Double(r.height) - 1
                guard inside else { continue }  // cropped away
                guard let got = centroid(r.pixels, r.width, r.height, m.channel) else { worstMiss = .infinity; continue }
                worstMiss = max(worstMiss, max(abs(got.x - expected.x), abs(got.y - expected.y)))
            }
            let finite = r.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
            check("G-E \(name): size \(r.width)x\(r.height) and markers within \(tol) px", sizeOK && worstMiss <= tol && finite,
                  "size \(r.width)x\(r.height) want \(want), worst miss \(worstMiss), finite \(finite)")
        } catch {
            check("G-E \(name) rendered", false, "\(error)")
        }
    }
    let names = ["ORIENTATION_NONE", "ORIENTATION_FLIP_VERTICALLY", "ORIENTATION_FLIP_HORIZONTALLY", "ORIENTATION_ROTATE_180_DEG",
                 "ORIENTATION_TRANSPOSE", "ORIENTATION_ROTATE_CW_90_DEG", "ORIENTATION_ROTATE_CCW_90_DEG", "ORIENTATION_TRANSVERSE"]
    for n in names {
        geometryCase("flip \(n)", [StackEntry(operation: "flip", params: ["orientation": .option(n)])],
                     GeometrySpec(orientation: Orientation(name: n)), tol: 0.01)
    }
    // straighten keeps what cl/cr/ct/cb say; the editor fills them from cropmode with Straighten.cropFractions
    for (deg, mode) in [(7.0, StraightenCrop.largest), (-12.0, .aspect), (20.0, .off)] {
        let f = Straighten.cropFractions(SIMD2(Double(gw), Double(gh)), degrees: deg, mode: mode)
        geometryCase("straighten \(deg) \(mode)",
                     [StackEntry(operation: "ashift", params: ["rotation": .number(deg), "cl": .number(f.left), "ct": .number(f.top),
                                                              "cr": .number(f.right), "cb": .number(f.bottom)])],
                     GeometrySpec(degrees: deg, straightenCrop: f), tol: 0.6)
    }
    geometryCase("crop", [StackEntry(operation: "crop", params: ["cx": .number(0.1), "cy": .number(0.1), "cw": .number(0.9), "ch": .number(0.95)])],
                 GeometrySpec(crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.95)), tol: 0.01)
    let combined: [StackEntry] = [
        StackEntry(operation: "crop", params: ["cx": .number(0.05), "cy": .number(0.1), "cw": .number(0.95), "ch": .number(0.9)]),
        StackEntry(operation: "flip", params: ["orientation": .option("ORIENTATION_ROTATE_CW_90_DEG")]),
        StackEntry(operation: "ashift", params: ["rotation": .number(5)]),
        StackEntry(operation: "exposure", params: ["exposure": .number(0.5)]),
    ]
    geometryCase("flip, straighten, crop and exposure together", combined,
                 GeometrySpec(orientation: .rotateCW90, degrees: 5, crop: CropRect(left: 0.05, top: 0.1, right: 0.95, bottom: 0.9)), tol: 0.6)
    // the camera's orientation is the default flip; an explicit flip replaces it (absolute from the sensor),
    // ORIENTATION_NULL means "the camera's"
    geometryCase("camera orientation is the default flip", [], GeometrySpec(orientation: .rotateCCW90), tol: 0.01, camera: .rotateCCW90)
    geometryCase("explicit flip none overrides the camera", [StackEntry(operation: "flip", params: ["orientation": .option("ORIENTATION_NONE")])],
                 GeometrySpec(), tol: 0.01, camera: .rotateCCW90)
    geometryCase("ORIENTATION_NULL keeps the camera's", [StackEntry(operation: "flip", params: ["orientation": .option("ORIENTATION_NULL")])],
                 GeometrySpec(orientation: .rotateCCW90), tol: 0.01, camera: .rotateCCW90)
    // straighten runs in sensor orientation, before the camera's flip
    geometryCase("straighten before the camera flip", [StackEntry(operation: "ashift", params: ["rotation": .number(9)])],
                 GeometrySpec(orientation: .rotateCW90, degrees: 9), tol: 0.6, camera: .rotateCW90)

    // G-X the EXIF table checked against Core Image's own orienting: markers must land in the same places
    for exif in UInt32(1)...8 {
        let o = CIEngineProbe.orientation(exif: exif)
        do {
            let ci = try CIEngineProbe.renderSized(stack: [], pixels: frame, width: gw, height: gh, coreImageOrientation: exif)
            let spec = GeometrySpec(orientation: o)
            var miss = 0.0
            for m in markers {
                let expected = spec.map(SIMD2(Double(m.x) + 1.5, Double(m.y) + 1.5), size: SIMD2(Double(gw), Double(gh)))
                guard let got = centroid(ci.pixels, ci.width, ci.height, m.channel) else { miss = .infinity; continue }
                miss = max(miss, abs(got.x - expected.x), abs(got.y - expected.y))
            }
            check("G-X EXIF \(exif) is \(o), as Core Image orients it", miss <= 0.01, "miss \(miss), size \(ci.width)x\(ci.height)")
        } catch {
            check("G-X EXIF \(exif) rendered", false, "\(error)")
        }
    }
    // unsupported straighten fields are an error, not a silent skip
    do {
        _ = try CIEngineProbe.renderSized(stack: [StackEntry(operation: "ashift", params: ["lensshift_v": .number(0.2)])],
                                          pixels: frame, width: gw, height: gh)
        check("G-E lens shift is refused", false, "rendered anyway")
    } catch {
        check("G-E lens shift is refused", "\(error)".contains("lensshift") || "\(error)".contains("lens"), "\(error)")
    }
}

// E-CB colour balance in OkLab (Simple's Contrast and Color sliders) through the per-pixel kernel
let eCB = run([StackEntry(operation: "colorbalancergb", params: ["contrast": .number(0.3), "saturation_global": .number(0.4),
                                                                  "vibrance": .number(0.5)])])
let eCBWant = scene.map { ColorBalance.apply($0, contrast: 0.3, saturation: 0.4, vibrance: 0.5) }
let eCBEncoded = worst(eCB, eCBWant), eCBLinear = worstLinear(eCB, eCBWant)
check("E-CB colour balance matches the oracle within 1/255 and unclamped within 1e-4",
      eCBEncoded < tol && eCBLinear < 1e-4, "encoded \(eCBEncoded), linear \(eCBLinear)")

// E-CM channel mixer: a non-symmetric 3x3 through the engine (CIBridge.perPixel, mixerTex) against ChannelMixer, unclamped
let cmRows: [[Double]] = [[0.9, 0.2, -0.1], [0.05, 1.1, -0.15], [-0.2, 0.3, 0.9]]
let cmStack = [StackEntry(operation: "channelmixer", params: [
    "red_r": .number(0.9), "red_g": .number(0.2), "red_b": .number(-0.1),
    "green_r": .number(0.05), "green_g": .number(1.1), "green_b": .number(-0.15),
    "blue_r": .number(-0.2), "blue_g": .number(0.3), "blue_b": .number(0.9),
])]
let cmOracle = scene.map { ChannelMixer.apply($0, rows: cmRows) }
let cmOut = run(cmStack)
let eCM = worst(cmOut, cmOracle), eCMLinear = worstLinear(cmOut, cmOracle)
check("E-CM channel mixer matches the oracle within 1/255 and unclamped (relative 1e-5)", eCM < tol && eCMLinear < 1e-5,
      "encoded \(eCM), linear \(eCMLinear)")

// E-MO monochrome with a colour filter: the per-pixel kernel through the engine (monochromeTex) against Monochrome in DarkroomCore
let monoStack = [StackEntry(operation: "monochrome", params: ["intensity": .number(0.8), "filter_hue": .number(200), "filter_strength": .number(0.7)])]
let monoOracle = scene.map { Monochrome.apply($0, intensity: 0.8, filterHueDegrees: 200, filterStrength: 0.7) }
let eMO = worst(run(monoStack), monoOracle)
check("E-MO monochrome matches the oracle within 1/255", eMO < tol, "\(eMO)")
let eMOLinear = worstLinear(run(monoStack), monoOracle)
check("E-MO monochrome matches the oracle unclamped (relative 1e-4)", eMOLinear < 1e-4, "\(eMOLinear)")

// E-ST split toning: the same settings through the engine (CIBridge.perPixel, splitTex) against SplitToning in DarkroomCore
let eSTEngine = run([StackEntry(operation: "splittoning", params: [
    "shadows_hue": .number(220), "shadows_saturation": .number(0.8),
    "highlights_hue": .number(60), "highlights_saturation": .number(0.6), "balance": .number(0.3),
])])
let eSTOracle = scene.map { SplitToning.apply($0, shadowsHueDegrees: 220, shadowsSaturation: 0.8,
                                              highlightsHueDegrees: 60, highlightsSaturation: 0.6, balance: 0.3) }
let eST = worst(eSTEngine, eSTOracle)
let eSTLinear = worstLinear(eSTEngine, eSTOracle)
check("E-ST split toning matches the oracle within 1/255 and unclamped within 1e-4", eST < tol && eSTLinear < 1e-4,
      "encoded \(eST), linear \(eSTLinear)")

// F-E the neighbourhood filters on the GPU, through Core Image, against DarkroomCore.Filters; regions against the full frame
do {
    let fw = 64, fh = 48
    // three different textures per channel so a channel mix-up shows
    let px: [SIMD4<Float>] = (0..<(fw * fh)).map { i in
        let x = Double(i % fw), y = Double(i / fw)
        return SIMD4(Float(0.4 + 0.25 * sin(x / 3.1) * cos(y / 4.7)), Float(0.5 + 0.3 * sin(x / 1.7 + y / 2.3)),
                     Float(0.2 + 0.15 * cos(x * y / 37)), 1)
    }
    func plane(_ c: Int) -> Plane { Plane(width: fw, height: fh, values: px.map { Double($0[c]) }) }
    func worstAgainst(_ got: [SIMD4<Float>], _ want: [Plane]) -> Double {
        var w = 0.0
        for (i, g) in got.enumerated() {
            for c in 0..<3 {
                guard g[c].isFinite else { return .infinity }
                w = max(w, abs(Double(g[c]) - want[c].values[i]))
            }
        }
        return got.count == fw * fh ? w : .infinity
    }
    func run(_ f: CIEngineProbe.Filter, region: (x: Int, y: Int, w: Int, h: Int)? = nil) -> [SIMD4<Float>] {
        (try? CIEngineProbe.filter(f, pixels: px, width: fw, height: fh, region: region)) ?? []
    }
    for r in [1, 3, 20] {
        let e = worstAgainst(run(.box(r)), (0..<3).map { Filters.boxMean(plane($0), radius: r) })
        check("F-E1 box mean radius \(r) on the GPU matches the oracle within 2e-6", e < 2e-6, "\(e)")
    }
    for level in 0...3 {
        let e = worstAgainst(run(.atrous(level)), (0..<3).map { Filters.atrousSmooth(plane($0), level: level) })
        check("F-E2 à trous smoothing level \(level) on the GPU matches the oracle within 2e-6", e < 2e-6, "\(e)")
    }
    let lum = Plane(width: fw, height: fh, values: px.map { 0.2126 * Double($0.x) + 0.7152 * Double($0.y) + 0.0722 * Double($0.z) })
    let ge = worstAgainst(run(.guided(4, 1e-3)), (0..<3).map { Filters.guided(guide: lum, input: plane($0), radius: 4, eps: 1e-3) })
    check("F-E3 guided filter (radius 4, eps 1e-3, luminance guide) on the GPU matches the oracle within 2e-4", ge < 2e-4, "\(ge)")
    // F-E4 tile seams: a region renders exactly what the full frame has there, inside and at the edges, and the
    // full frame is the oracle's (so an empty render cannot pass by matching another empty render)
    let oracles: [String: [Plane]] = [
        "box": (0..<3).map { Filters.boxMean(plane($0), radius: 5) },
        "atrous": (0..<3).map { Filters.atrousSmooth(plane($0), level: 2) },
        "guided": (0..<3).map { Filters.guided(guide: lum, input: plane($0), radius: 4, eps: 1e-3) },
    ]
    for (name, f) in [("box", CIEngineProbe.Filter.box(5)), ("atrous", .atrous(2)), ("guided", .guided(4, 1e-3))] {
        let full = run(f)
        let fullErr = worstAgainst(full, oracles[name]!)
        var worstSeam = 0.0, ok = full.count == fw * fh && fullErr < 2e-4
        for reg in [(x: 17, y: 9, w: 30, h: 25), (x: 0, y: 0, w: 20, h: 20), (x: 50, y: 30, w: 14, h: 18)] {
            let part = run(f, region: reg)
            guard part.count == reg.w * reg.h else { ok = false; continue }
            for yy in 0..<reg.h { for xx in 0..<reg.w {
                let a = part[yy * reg.w + xx], b = full[(reg.y + yy) * fw + reg.x + xx]
                for c in 0..<4 { worstSeam = max(worstSeam, abs(Double(a[c]) - Double(b[c]))); if !a[c].isFinite { ok = false } }
            } }
        }
        check("F-E4 \(name) renders the same in a region as in the full frame (inside and at the edges), and the full frame is the oracle's",
              ok && worstSeam < 1e-6, "seam \(worstSeam), full vs oracle \(fullErr)")
    }
}

// E-DC the square-root luminance kernels on the GPU against DarkroomCore.DetailCommon
do {
    let fw = 48, fh = 40
    let img = DetailCommon.fixture(width: fw, height: fh)
    let px: [SIMD4<Float>] = img.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
    let s = DetailCommon.sqrtLuminance(img, width: fw, height: fh)
    let got = (try? CIEngineProbe.filter(.sqrtLuminance, pixels: px, width: fw, height: fh)) ?? []
    var e = got.count == fw * fh ? 0.0 : Double.infinity
    for (i, g) in got.enumerated() { for c in 0..<3 { e = g[c].isFinite ? max(e, abs(Double(g[c]) - s.values[i])) : .infinity } }
    check("E-DC1 square-root luminance on the GPU matches the oracle within 1e-6", e < 1e-6, "\(e)")
    let round = (try? CIEngineProbe.filter(.sqrtLuminanceRoundTrip, pixels: px, width: fw, height: fh)) ?? []
    var r = round.count == fw * fh ? 0.0 : Double.infinity
    for (i, g) in round.enumerated() { for c in 0..<3 { r = g[c].isFinite ? max(r, abs(Double(g[c]) - img[i][c]) / max(1, abs(img[i][c]))) : .infinity } }
    check("E-DC2 replacing s by itself on the GPU gives the image back within 1e-5", r < 1e-5, "\(r)")
}

// E-SH the 2-D sharpen through the engine (Core Image blur chain, per-pixel combine) against Sharpen2D
do {
    let stack = [StackEntry(operation: "sharpen", params: ["amount": .number(0.9), "radius": .number(3)])]
    let want = Sharpen2D.apply(detailImg, width: detailW, height: detailH, amount: 0.9, radius: 3)
    let got = runDetail(stack)
    let e = worst(got, want), el = worstLinear(got, want)
    check("E-SH sharpen (amount 0.9, radius 3) matches the oracle within 1/255 and unclamped within 2e-4",
          e < tol && el < 2e-4, "encoded \(e), linear \(el)")
    let seam = detailSeams(stack, oracle: want)
    check("E-SH-seam sharpen tiles match the full frame and the oracle (seam \(seam.seam), full vs oracle \(seam.fullVsOracle))",
          seam.ok, "seam \(seam.seam), full vs oracle \(seam.fullVsOracle)")
    // radius 1 is level 0: the level map has to reach the GPU as well
    let stack0 = [StackEntry(operation: "sharpen", params: ["amount": .number(0.9), "radius": .number(1)])]
    let want0 = Sharpen2D.apply(detailImg, width: detailW, height: detailH, amount: 0.9, radius: 1)
    let got0 = runDetail(stack0)
    let e0 = worst(got0, want0), el0 = worstLinear(got0, want0)
    check("E-SH-L0 sharpen at radius 1 (level 0) matches the oracle within 1/255 and unclamped within 2e-4",
          e0 < tol && el0 < 2e-4, "encoded \(e0), linear \(el0)")
}

// E-LC local contrast (DarkroomCore.LocalContrast) through the engine, on the textured fixture
do {
    let stack = [StackEntry(operation: "bilat", params: ["detail": .number(0.8), "radius": .number(5)])]
    let oracle = LocalContrast.apply(detailImg, width: detailW, height: detailH, detail: 0.8, radius: 5)
    let got = runDetail(stack)
    let e = worst(got, oracle), el = worstLinear(got, oracle)
    check("E-LC local contrast (detail 0.8, radius 5) matches the oracle within 1/255 and 2e-4 unclamped",
          e < tol && el < 2e-4, "encoded \(e), linear \(el)")
    let seams = detailSeams(stack, oracle: oracle)
    check("E-LC-seam local contrast renders the same in a region as in the full frame, and the full frame is the oracle's",
          seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
}

// E-LC-neg local contrast flattens at negative detail
do {
    let stack = [StackEntry(operation: "bilat", params: ["detail": .number(-1), "radius": .number(3)])]
    let oracle = LocalContrast.apply(detailImg, width: detailW, height: detailH, detail: -1, radius: 3)
    let got = runDetail(stack)
    let e = worst(got, oracle), el = worstLinear(got, oracle)
    check("E-LC-neg local contrast (detail -1, radius 3) matches the oracle within 1/255 and 2e-4 unclamped",
          e < tol && el < 2e-4, "encoded \(e), linear \(el)")
}

// E-EQ the contrast equalizer through the engine (CIBridge.contrastEqualizer) against ContrastEqualizer, with tile seams
do {
    let eqStack = [StackEntry(operation: "atrous", params: ["fine": .number(0.6), "medium": .number(-0.4), "coarse": .number(0.9)])]
    let oracle = ContrastEqualizer.apply(detailImg, width: detailW, height: detailH, fine: 0.6, medium: -0.4, coarse: 0.9)
    let eqEngine = runDetail(eqStack)
    let eqErr = worst(eqEngine, oracle), eqLinear = worstLinear(eqEngine, oracle)
    check("E-EQ contrast equalizer matches the oracle within 1/255 and unclamped within 2e-4",
          eqErr < tol && eqLinear < 2e-4, "encoded \(eqErr), unclamped \(eqLinear)")
    let eqSeams = detailSeams(eqStack, oracle: oracle)
    check("E-EQ-seam contrast equalizer tiles match the full frame, and the full frame is the oracle's",
          eqSeams.ok, "seam \(eqSeams.seam), full vs oracle \(eqSeams.fullVsOracle)")
    // fine alone: the finest group is wired to the GPU's finest bands
    let fineStack = [StackEntry(operation: "atrous", params: ["fine": .number(1)])]
    let fineOracle = ContrastEqualizer.apply(detailImg, width: detailW, height: detailH, fine: 1, medium: 0, coarse: 0)
    let fineEngine = runDetail(fineStack)
    let fineErr = worst(fineEngine, fineOracle), fineLinear = worstLinear(fineEngine, fineOracle)
    check("E-EQ-fine fine +1 alone matches the oracle within 1/255 and unclamped within 2e-4",
          fineErr < tol && fineLinear < 2e-4, "encoded \(fineErr), unclamped \(fineLinear)")
    // all sliders at 0: the input comes back untouched, bit for bit (a non-finite value never compares equal)
    let zeroStack = [StackEntry(operation: "atrous", params: ["fine": .number(0), "medium": .number(0), "coarse": .number(0)])]
    let zeroEngine = runDetail(zeroStack)
    let zeroExact = zeroEngine.count == detailPx.count && zip(zeroEngine, detailPx).allSatisfy { $0 == $1 }
    check("E-EQ-zero all sliders at 0 return the input bit-exactly", zeroExact,
          "count \(zeroEngine.count) of \(detailPx.count)")
}

// E-NR the wavelet noise reduction through the engine against DarkroomCore.NoiseReduction on the textured fixture
let nrCases: [(name: String, luma: Double, chroma: Double)] = [
    ("E-NR", 0.4, 0.6), ("E-NR-luma", 0.8, 0), ("E-NR-chroma", 0, 0.8),
]
for c in nrCases {
    let stack = [StackEntry(operation: "denoiseprofile", params: ["luma": .number(c.luma), "chroma": .number(c.chroma)])]
    let got = runDetail(stack)
    let want = NoiseReduction.apply(detailImg, width: detailW, height: detailH, luma: c.luma, chroma: c.chroma)
    let eEnc = worst(got, want), eLin = worstLinear(got, want)
    check("\(c.name) noise reduction luma \(c.luma) chroma \(c.chroma) matches the oracle (encoded \(eEnc), linear \(eLin))",
          eEnc < tol && eLin < 2e-4, "encoded \(eEnc), linear \(eLin)")
}
let nrStack = [StackEntry(operation: "denoiseprofile", params: ["luma": .number(0.4), "chroma": .number(0.6)])]
let nrSeam = detailSeams(nrStack, oracle: NoiseReduction.apply(detailImg, width: detailW, height: detailH, luma: 0.4, chroma: 0.6))
check("E-NR-seam noise reduction regions match the full frame, and the full frame is the oracle's (seam \(nrSeam.seam), full vs oracle \(nrSeam.fullVsOracle))",
      nrSeam.ok, "seam \(nrSeam.seam), full vs oracle \(nrSeam.fullVsOracle)")

// E-M the local-mask plumbing through the engine (kind 0 = the whole frame): the module applies, inversion keeps the
// input, opacity mixes, refinement of a constant mask changes nothing, and tiles agree with the full frame
do {
    let ex = StackEntry(operation: "exposure", params: ["exposure": .number(1)])
    func masked(_ blend: [String: ParamValue]) -> StackEntry {
        StackEntry(operation: "exposure", params: ["exposure": .number(1)], blend: blend)
    }
    let m0: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(0)]
    let plain = runDetail([ex]).map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
    let doubled = detailImg.map { $0 * 2 }
    let eMask = worstLinear(runDetail([masked(m0)]), plain)
    check("E-M1 a whole-frame local mask applies the module exactly as no mask does", eMask < 1e-6, "\(eMask)")
    var inv = m0; inv["mask_invert"] = .number(1)
    let eInv = worstLinear(runDetail([masked(inv)]), detailImg)
    check("E-M2 an inverted whole-frame mask leaves the input untouched", eInv < 1e-6, "\(eInv)")
    var op = m0; op["opacity"] = .number(40)
    let want = zip(detailImg, doubled).map { $0 + ($1 - $0) * 0.4 }
    let eOp = worstLinear(runDetail([masked(op)]), want)
    check("E-M3 opacity 40 mixes the module's output 40% over its input", eOp < 1e-5, "\(eOp)")
    var ref = m0; ref["mask_refine"] = .number(5)
    let eRef = worstLinear(runDetail([masked(ref)]), plain)
    check("E-M4 refining a constant mask changes nothing", eRef < 2e-4, "\(eRef)")
    let seams = detailSeams([masked(ref)], oracle: plain)
    check("E-M5 a refined mask renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    var bad = m0; bad["mask_kind"] = .number(99)
    check("E-M6 an unknown mask kind is an error, never a silent skip",
          (try? CIEngineProbe.render(stack: [masked(bad)], pixels: detailPx, width: detailW, height: detailH)) == nil)
}

// E-M7 module values from a sidecar are held to the schema: a NaN or absurd radius renders like the default or the maximum
do {
    func lc(_ radius: Double) -> [SIMD4<Float>] {
        runDetail([StackEntry(operation: "bilat", params: ["detail": .number(0.8), "radius": .number(radius)])])
    }
    func same(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Bool {
        a.count == detailW * detailH && a.count == b.count && zip(a, b).allSatisfy { $0.x.isFinite && $0 == $1 }
    }
    check("E-M7 a NaN radius renders like the default radius (10)", same(lc(.nan), lc(10)))
    check("E-M7 an absurd radius renders like the maximum radius (50)", same(lc(1e18), lc(50)))
}

// GR: linear gradient mask (card maskgradient)
do {
    let grBlend: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(1), "mask_angle": .number(30),
                                         "mask_position": .number(0.4), "mask_feather": .number(0.3)]
    let grSpec = Mask.spec(from: grBlend.compactMapValues { $0.double })!
    let grSpec2 = Mask.spec(from: ["mask_mode": 2, "mask_kind": 1, "mask_angle": 200, "mask_position": 0.6, "mask_feather": 0.5])!
    let m1 = maskMatteError(grSpec), m2 = maskMatteError(grSpec2)
    check("E-GR-matte GPU matte equals Mask.plane (two specs)", m1 < 1e-4 && m2 < 1e-4, "\(m1) \(m2)")
    let gs = runDetail([maskedExposure(grBlend)]), go = maskedExposureOracle(grSpec)
    let gw = worst(gs, go), gl = worstLinear(gs, go)
    check("E-GR-stack masked exposure matches the oracle", gw < tol && gl < 2e-4, "\(gw) \(gl)")
    let sm = detailSeams([maskedExposure(grBlend)], oracle: go)
    check("E-GR-seam regions rendered alone equal the full frame", sm.ok, "\(sm)")
    var grInv = grBlend; grInv["mask_invert"] = .number(1)
    var invSpec = grSpec; invSpec.invert = true
    let iv = runDetail([maskedExposure(grInv)]), io = maskedExposureOracle(invSpec)
    let iw = worst(iv, io), il = worstLinear(iv, io)
    check("E-GR-invert inverted mask matches the inverted oracle", iw < tol && il < 2e-4, "\(iw) \(il)")
}

// MaskEllipse (EL): GPU matte, stack, seams and inversion against the oracle
do {
    let b1: [String: Double] = ["mask_cx": 0.4, "mask_cy": 0.6, "mask_rx": 0.3, "mask_ry": 0.15, "mask_rotation": 25, "mask_feather": 0.4]
    let b2: [String: Double] = ["mask_cx": 0.7, "mask_cy": 0.3, "mask_rx": 0.2, "mask_ry": 0.2, "mask_rotation": 0, "mask_feather": 0.6]
    func spec(_ b: [String: Double]) -> MaskSpec { Mask.spec(from: b.merging(["mask_mode": 2, "mask_kind": 2]) { $1 })! }
    let e1 = maskMatteError(spec(b1)), e2 = maskMatteError(spec(b2))
    check("E-EL-matte GPU matte equals the oracle", e1 < 1e-4 && e2 < 1e-4, "worst \(e1), \(e2)")

    func blend(_ b: [String: Double], invert: Bool = false) -> [String: ParamValue] {
        var out = b.mapValues { ParamValue.number($0) }
        out["mask_mode"] = .number(2); out["mask_kind"] = .number(2)
        if invert { out["mask_invert"] = .number(1) }
        return out
    }
    let s = spec(b1), oracle = maskedExposureOracle(s)
    let got = runDetail([maskedExposure(blend(b1))])
    let wr = worst(got, oracle), wl = worstLinear(got, oracle)
    check("E-EL-stack masked exposure equals the oracle", wr < tol && wl < 2e-4, "encoded \(wr), linear \(wl)")

    let seam = detailSeams([maskedExposure(blend(b1))], oracle: oracle)
    check("E-EL-seam regions equal the full frame", seam.ok, "seam \(seam.seam), full vs oracle \(seam.fullVsOracle)")

    var si = s; si.invert = true
    let gi = runDetail([maskedExposure(blend(b1, invert: true))])
    let wri = worst(gi, maskedExposureOracle(si)), wli = worstLinear(gi, maskedExposureOracle(si))
    check("E-EL-invert inverted mask equals the oracle", wri < tol && wli < 2e-4, "encoded \(wri), linear \(wli)")
}

// E-LU: luminance range mask (kind 3) through the engine
do {
    let b1: [String: ParamValue] = ["mask_low": .number(0.25), "mask_high": .number(0.75), "mask_feather": .number(0.5),
                                    "mask_mode": .number(2), "mask_kind": .number(3)]
    let b2: [String: ParamValue] = ["mask_low": .number(0.0), "mask_high": .number(0.5), "mask_feather": .number(0.8),
                                    "mask_mode": .number(2), "mask_kind": .number(3)]
    func specOf(_ b: [String: ParamValue]) -> MaskSpec { Mask.spec(from: b.compactMapValues { $0.double })! }
    let s1 = specOf(b1), s2 = specOf(b2)
    let m1 = maskMatteError(s1), m2 = maskMatteError(s2)
    check("E-LU-matte the luminance matte on the GPU equals the oracle for two specs (\(m1), \(m2))", m1 < 1e-4 && m2 < 1e-4, "\(m1) \(m2)")
    let gpu = (try? CIEngineProbe.filter(.mask(s1), pixels: detailPx, width: detailW, height: detailH)) ?? []
    check("E-LU-varies the matte has values under 0.1 and over 0.9",
          gpu.count == detailW * detailH && gpu.contains { $0.x < 0.1 } && gpu.contains { $0.x > 0.9 })
    let got = runDetail([maskedExposure(b1)]), want = maskedExposureOracle(s1)
    let w1 = worst(got, want), w2 = worstLinear(got, want)
    check("E-LU-stack a luminance-masked +1 EV exposure matches the oracle (\(w1), \(w2))", w1 < tol && w2 < 2e-4, "\(w1) \(w2)")
    let sm = detailSeams([maskedExposure(b1)], oracle: want)
    check("E-LU-seam luminance mask regions match the full frame and the oracle (seam \(sm.seam), full vs oracle \(sm.fullVsOracle))",
          sm.ok, "seam \(sm.seam), full vs oracle \(sm.fullVsOracle)")
    var bi = b1; bi["mask_invert"] = .number(1)
    var si = s1; si.invert = true
    let gi = runDetail([maskedExposure(bi)]), wi = maskedExposureOracle(si)
    let i1 = worst(gi, wi), i2 = worstLinear(gi, wi)
    check("E-LU-invert the inverted luminance mask matches the inverted oracle (\(i1), \(i2))", i1 < tol && i2 < 2e-4, "\(i1) \(i2)")
}


// CO: the colour range mask (kind 4)
do {
    let b1: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(4), "mask_hue": .number(60),
                                    "mask_hue_width": .number(60), "mask_chroma_min": .number(0.02), "mask_feather": .number(0.5)]
    let b2: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(4), "mask_hue": .number(250),
                                    "mask_hue_width": .number(90), "mask_chroma_min": .number(0.01), "mask_feather": .number(0.6)]
    func specOf(_ b: [String: ParamValue]) -> MaskSpec { Mask.spec(from: b.compactMapValues { $0.double })! }
    let s1 = specOf(b1), s2 = specOf(b2)
    let m1 = maskMatteError(s1), m2 = maskMatteError(s2)
    check("E-CO-matte the GPU colour matte equals the oracle for two specs", m1 < 1e-4 && m2 < 1e-4, "\(m1) \(m2)")
    let gpu = (try? CIEngineProbe.filter(.mask(s1), pixels: detailPx, width: detailW, height: detailH)) ?? []
    let lo = gpu.map { Double($0.x) }.min() ?? .nan, hi = gpu.map { Double($0.x) }.max() ?? .nan
    check("E-CO-varies the matte has a value under 0.1 and one over 0.9", lo < 0.1 && hi > 0.9, "min \(lo) max \(hi)")
    let got = runDetail([maskedExposure(b1)])
    let want = maskedExposureOracle(s1)
    let eT = worst(got, want), eL = worstLinear(got, want)
    check("E-CO-stack a colour-masked exposure equals the oracle", eT < tol && eL < 2e-4, "\(eT) \(eL)")
    let seam = detailSeams([maskedExposure(b1)], oracle: want)
    check("E-CO-seam regions render the same as the full frame", seam.ok, "seam \(seam.seam), full vs oracle \(seam.fullVsOracle)")
    var inv = b1; inv["mask_invert"] = .number(1)
    var sInv = s1; sInv.invert = true
    let gotI = runDetail([maskedExposure(inv)])
    let wantI = maskedExposureOracle(sInv)
    let eIT = worst(gotI, wantI), eIL = worstLinear(gotI, wantI)
    check("E-CO-invert the inverted colour mask equals the oracle", eIT < tol && eIL < 2e-4, "\(eIT) \(eIL)")
}

// E-M8 a NaN or infinite mask kind or mode is an error, never a crash (the error message must not trap either)
do {
    for blend: [String: ParamValue] in [["mask_mode": .number(2), "mask_kind": .number(.nan)],
                                        ["mask_mode": .number(2), "mask_kind": .number(.infinity)],
                                        ["mask_mode": .number(.infinity)], ["mask_mode": .number(.nan), "mask_kind": .number(1)]] {
        let threw = (try? CIEngineProbe.render(stack: [maskedExposure(blend)], pixels: detailPx, width: detailW, height: detailH)) == nil
        check("E-M8 a non-finite mask value is an error, not a crash (\(blend.keys.sorted()))", threw)
    }
}

// F-E5 / E-DH: the min filter and haze removal on the GPU
do {
    let fw = 64, fh = 48
    let px: [SIMD4<Float>] = (0..<(fw * fh)).map { i in
        let x = Double(i % fw), y = Double(i / fw)
        return SIMD4(Float(0.4 + 0.25 * sin(x / 3.1) * cos(y / 4.7)), Float(0.5 + 0.3 * sin(x / 1.7 + y / 2.3)),
                     Float(0.2 + 0.15 * cos(x * y / 37)), 1)
    }
    for r in [1, 4, 12] {
        let got = (try? CIEngineProbe.filter(.min(r), pixels: px, width: fw, height: fh)) ?? []
        var e = got.count == fw * fh ? 0.0 : Double.infinity
        for c in 0..<3 {
            let want = Filters.minFilter(Plane(width: fw, height: fh, values: px.map { Double($0[c]) }), radius: r)
            for (i, g) in got.enumerated() { e = g[c].isFinite ? max(e, abs(Double(g[c]) - want.values[i])) : .infinity }
        }
        check("F-E5 min filter radius \(r) on the GPU matches the oracle exactly (min is exact in float): \(e)", e < 1e-7, "\(e)")
    }
    let dh: [String: ParamValue] = ["strength": .number(0.7), "radius": .number(4), "airlight": .number(1)]
    let stack = [StackEntry(operation: "hazeremoval", params: dh)]
    let want = Dehaze.apply(detailImg, width: detailW, height: detailH, strength: 0.7, radius: 4, airlight: 1)
    let got = runDetail(stack)
    let eDH = worstLinear(got, want), eEnc = worst(got, want)
    check("E-DH haze removal matches the oracle within 1/255 and unclamped within 2e-4", eEnc < tol && eDH < 2e-4, "encoded \(eEnc), linear \(eDH)")
    check("E-DH the oracle really changes the fixture (a no-op GPU path would fail)", worstLinear(detailPx, want) > 0.05, "\(worstLinear(detailPx, want))")
    let seams = detailSeams(stack, oracle: want)
    check("E-DH-seam haze removal renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    let zero = runDetail([StackEntry(operation: "hazeremoval", params: ["strength": .number(0)])])
    check("E-DH-zero strength 0 returns the input untouched", zero == detailPx)
}

// T10 HDR: a ramp from deep shadow to 4 stops over white through the display transform; the SDR render, the HDR
// render and the exported file (an SDR JPEG carrying a gain map) must agree with each other and with SceneTone
do {
    let rw = 256, rh = 32, headroom = 4.0
    func evAt(_ column: Int) -> Double { -8.0 + 14.5 * Double(column) / Double(rw - 1) }   // 0.18 * 2^ev: 0.0007 ... 16
    let ramp: [SIMD4<Float>] = (0..<(rw * rh)).map { i in
        let y = Float(0.18 * pow(2, evAt(i % rw)))
        return SIMD4(y, y, y, 1)
    }
    let stack = [StackEntry(operation: "display", params: ["contrast": .number(0)])]
    let sdr = (try? CIEngineProbe.render(stack: stack, pixels: ramp, width: rw, height: rh)) ?? []
    let hdr = (try? CIEngineProbe.renderHDR(stack: stack, pixels: ramp, width: rw, height: rh, headroom: headroom)) ?? []
    let sized = sdr.count == rw * rh && hdr.count == rw * rh
    let tone = SceneTone(contrast: 0, peak: headroom)
    var eOracle = sized ? 0.0 : Double.infinity, eSDRRange = sized ? 0.0 : Double.infinity
    var hdrMax = 0.0, sdrMax = 0.0, below = false
    for c in 0..<rw where sized {
        let p = ramp[c], h = hdr[c], s = sdr[c]
        guard h.x.isFinite, h.y.isFinite, h.z.isFinite, s.x.isFinite else { eOracle = .infinity; continue }
        let want = tone.apply(Double(p.x))
        for k in 0..<3 { eOracle = max(eOracle, abs(Double(h[k]) - want) / max(1, want)) }
        if evAt(c) < 1.5 { for k in 0..<3 { eSDRRange = max(eSDRRange, abs(Double(h[k]) - Double(s[k]))) } }
        hdrMax = max(hdrMax, Double(h.x)); sdrMax = max(sdrMax, Double(s.x))
        if h.x < s.x - 1e-6 { below = true }
    }
    check("T10a the HDR render matches SceneTone(peak: 4) on the ramp (relative, unclamped)", eOracle < 2e-4, "\(eOracle)")
    check("T10b below the knee (1.5 stops over grey) the HDR render equals the SDR render", eSDRRange < 1e-6, "\(eSDRRange)")
    check("T10c the SDR render tops out at 1, the HDR render at the headroom, and HDR never darkens SDR",
          abs(sdrMax - 1) < 1e-6 && hdrMax > 3.9 && hdrMax < 4.0001 && !below, "sdr \(sdrMax), hdr \(hdrMax), darker \(below)")

    let data = try? CIEngineProbe.hdrJPEG(stack: stack, pixels: ramp, width: rw, height: rh, headroom: headroom)
    check("T10d the export is a JPEG", data != nil && data!.starts(with: [0xFF, 0xD8]))
    if let data, let src = CGImageSourceCreateWithData(data as CFData, nil) {
        // the base picture: what a viewer without gain-map support shows
        let decodedSDR = CGImageSourceCreateImageAtIndex(src, 0, nil)
        var eBase = Double.infinity, eMean = Double.infinity
        if let cg = decodedSDR, cg.width == rw, cg.height == rh,
           let ctx = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: rw * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: rw, height: rh))
            let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: rw * rh * 4)
            var worstE = 0.0, sum = 0.0
            for c in 0..<rw {
                let want = encode(SIMD3(Double(sdr[c].x), Double(sdr[c].y), Double(sdr[c].z)))
                for k in 0..<3 {
                    let d = abs(Double(bytes[(rh / 2 * rw + c) * 4 + k]) / 255 - want[k])
                    worstE = max(worstE, d); sum += d
                }
            }
            eBase = worstE; eMean = sum / Double(rw * 3)
        }
        check("T10e the SDR base picture of the file matches the SDR render (JPEG loss only)", eBase < 12.0 / 255 && eMean < 2.0 / 255, "worst \(eBase * 255)/255, mean \(eMean * 255)/255")
        let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [CFString: Any]
        let desc = aux?[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any]
        let gw = desc?["Width"] as? Int ?? 0, gh = desc?["Height"] as? Int ?? 0, bpr = desc?["BytesPerRow"] as? Int ?? 0
        check("T10f the gain map is one 8-bit channel (grey) and no larger than the picture",
              (desc?["PixelFormat"] as? UInt32) == 0x4C303038 && bpr == gw && gw > 0 && gw <= rw && gh > 0 && gh <= rh,
              "\(gw)x\(gh) bpr \(bpr) format \(String(describing: desc?["PixelFormat"]))")
        check("T10g the file also carries the ISO 21496-1 gain map",
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil)
    } else { check("T10e-g the file can be read back", false) }
    // a viewer with headroom expands the file back to HDR
    if let data, let ci = CIImage(data: data, options: [.expandToHDR: true]), let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
       let device = MTLCreateSystemDefaultDevice() {
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        var back = [SIMD4<Float>](repeating: .zero, count: rw * rh)
        back.withUnsafeMutableBytes { context.render(ci, toBitmap: $0.baseAddress!, rowBytes: rw * 16, bounds: CGRect(x: 0, y: 0, width: rw, height: rh), format: .RGBAf, colorSpace: space) }
        let mid = rh / 2 * rw
        var eLow = 0.0, eHigh = 0.0, finite = true
        for c in 0..<rw {
            let b = back[mid + c]
            guard b.x.isFinite, b.y.isFinite, b.z.isFinite else { finite = false; continue }
            let want = Double(hdr[c].x)
            if evAt(c) < 1.0 { eLow = max(eLow, abs(Double(b.x) - want) / max(want, 0.02)) }
            if evAt(c) > 3.5 { eHigh = max(eHigh, abs(Double(b.x) - want) / want) }
        }
        check("T10h expanding the file to HDR reports the headroom", abs(ci.contentHeadroom - 4) < 0.1, "\(ci.contentHeadroom)")
        check("T10i expanded, the SDR range returns to the SDR render and the highlights to the HDR render",
              finite && eLow < 0.05 && eHigh < 0.15, "low \(eLow), high \(eHigh)")
    } else { check("T10h-i the file expands to HDR", false) }
}

// E-SC render scale: radii are full-resolution pixels, so a preview (scale 0.5) of radius R looks like radius R/2 at full size
do {
    func img(_ stack: [StackEntry], scale: Double) -> [SIMD4<Float>] {
        (try? CIEngineProbe.render(stack: stack, pixels: detailPx, width: detailW, height: detailH, scale: scale)) ?? []
    }
    func same(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Bool { a.count == detailW * detailH && a == b }
    func lc(_ radius: Double) -> [StackEntry] { [StackEntry(operation: "bilat", params: ["detail": .number(0.8), "radius": .number(radius)])] }
    check("E-SC1 local contrast: radius 12 at scale 0.5 renders as radius 6 at scale 1", same(img(lc(12), scale: 0.5), img(lc(6), scale: 1)))
    check("E-SC1 and not as radius 12 at scale 1 (the scale is used)", !same(img(lc(12), scale: 0.5), img(lc(12), scale: 1)))
    func sh(_ radius: Double) -> [StackEntry] { [StackEntry(operation: "sharpen", params: ["amount": .number(1), "radius": .number(radius)])] }
    check("E-SC2 sharpen: radius 6 at scale 0.5 renders as radius 3 at scale 1", same(img(sh(6), scale: 0.5), img(sh(3), scale: 1)))
    func hz(_ radius: Double) -> [StackEntry] { [StackEntry(operation: "hazeremoval", params: ["strength": .number(0.8), "radius": .number(radius)])] }
    check("E-SC3 haze removal: radius 16 at scale 0.5 renders as radius 8 at scale 1", same(img(hz(16), scale: 0.5), img(hz(8), scale: 1)))
    // a spatial matte (a gradient), so the refinement radius changes the picture, unlike a constant matte
    var m: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(1), "mask_angle": .number(20), "mask_feather": .number(0.05), "mask_refine": .number(10)]
    let e = StackEntry(operation: "exposure", params: ["exposure": .number(1)], blend: m)
    m["mask_refine"] = .number(5)
    let h = StackEntry(operation: "exposure", params: ["exposure": .number(1)], blend: m)
    check("E-SC4 mask refinement: radius 10 at scale 0.5 renders as radius 5 at scale 1", same(img([e], scale: 0.5), img([h], scale: 1)))
    check("E-SC4 and not as radius 10 at scale 1 (the refinement radius matters here)", !same(img([e], scale: 0.5), img([e], scale: 1)))
    func bl(_ r: Double) -> [StackEntry] { [StackEntry(operation: "blurs", params: ["radius": .number(r)])] }
    check("E-SC6 blurs: radius 8 at scale 0.5 renders as radius 4 at scale 1", same(img(bl(8), scale: 0.5), img(bl(4), scale: 1)) && !same(img(bl(8), scale: 0.5), img(bl(8), scale: 1)))
    check("E-SC5 a hostile scale (NaN, 0, 99) is held to 0.001...1 and renders",
          [Double.nan, 0, 99].allSatisfy { img(lc(10), scale: $0).count == detailW * detailH })
}

// T11 version stability: every module, at its current algorithm version, renders the fixture exactly as its stored golden
// image says (a Float16 RGB file under Goldens/). `swift run darkroom-engine-check --update-goldens` rewrites them, which is the
// reviewed, deliberate step after a module's maths changes and its algorithmVersion goes up.
do {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Goldens")
    let update = CommandLine.arguments.contains("--update-goldens")
    if update { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func store(_ px: [SIMD4<Float>]) -> Data {
        var halves: [Float16] = []
        halves.reserveCapacity(px.count * 3)
        for p in px { halves += [Float16(p.x), Float16(p.y), Float16(p.z)] }
        return halves.withUnsafeBytes { Data($0) }
    }
    func load(_ data: Data) -> [SIMD3<Double>] {
        let n = data.count / 6
        return data.withUnsafeBytes { raw in
            let h = raw.bindMemory(to: Float16.self)
            return (0..<n).map { SIMD3(Double(h[$0 * 3]), Double(h[$0 * 3 + 1]), Double(h[$0 * 3 + 2])) }
        }
    }
    var cases = 0, rewritten = 0
    for c in CIEngineProbe.goldenCases() {
        cases += 1
        let file = dir.appendingPathComponent("\(c.operation).v\(c.version).f16")
        let got = runDetail(c.stack)
        guard got.count == detailW * detailH, got.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            check("T11 \(c.operation) v\(c.version) renders a finite frame of the input's size (\(got.count) pixels, wanted \(detailW * detailH))", false); continue
        }
        if update { try? store(got).write(to: file); rewritten += 1; continue }
        guard let data = try? Data(contentsOf: file), data.count == detailW * detailH * 6 else {
            check("T11 \(c.operation) v\(c.version) has a golden image (run --update-goldens after reviewing the change)", false, file.lastPathComponent)
            continue
        }
        let want = load(data)
        let eEnc = worst(got, want, oracleEncoded: false), eLin = worstLinear(got, want)
        check("T11 \(c.operation) v\(c.version) renders as its golden image", eEnc < tol && eLin < 5e-3, "encoded \(eEnc), linear \(eLin)")
        let moved = worstLinear(detailPx, want)
        check("T11 \(c.operation)'s golden case really changes the picture", moved > 1e-3 || c.operation == "display", "\(moved)")
    }
    if update { print("wrote \(rewritten) golden images to \(dir.path)"); exit(0) }
    check("T11 the suite covers every catalogue module (\(cases) cases)", cases >= 30, "\(cases)")
}

// PL parity list: every darktable module is classified once, and the list agrees with the catalogue
do {
    let dt = ParityList.darktableModules
    let entries = ParityList.entries
    let ops = entries.map(\.operation)
    check("PL1 the list names \(dt.count) darktable modules, none twice", Set(dt).count == dt.count && dt.count == 90, "\(dt.count)")
    check("PL1 every darktable module is classified exactly once",
          dt.allSatisfy { d in entries.filter { $0.operation == d }.count == 1 }, "\(dt.filter { d in entries.filter { $0.operation == d }.count != 1 })")
    check("PL1 and nothing else is in the list but our own modules",
          Set(ops).subtracting(dt).isSubset(of: Set(ParityList.ownModules)) && ops.count == Set(ops).count,
          "\(Set(ops).subtracting(dt))")
    let catalogue = CIEngineProbe.catalogue()
    let inCatalogue = Set(catalogue.map(\.operation))
    func isBuilt(_ s: ParityStatus) -> Bool { switch s { case .exact, .unverified, .approximate: true; default: false } }
    check("PL2 every catalogue module is in the list", inCatalogue.allSatisfy { ParityList.entry($0) != nil },
          "\(inCatalogue.filter { ParityList.entry($0) == nil })")
    check("PL2 a module marked exact, unverified or approximate is in the catalogue, and no other is",
          entries.filter { isBuilt($0.status) }.allSatisfy { inCatalogue.contains($0.operation) }
            && entries.filter { !isBuilt($0.status) }.allSatisfy { !inCatalogue.contains($0.operation) },
          "\(entries.filter { isBuilt($0.status) != inCatalogue.contains($0.operation) }.map(\.operation))")
    let mislabelled = catalogue.filter { m in
        guard let s = ParityList.entry(m.operation)?.status else { return false }
        return (s == .approximate) != m.name.contains("approximate")
    }.map(\.operation)
    check("PL3 'approximate' in the list is exactly 'approximate' in the module's name", mislabelled.isEmpty, "\(mislabelled)")
    let exactOps = Set(entries.filter { $0.status == .exact }.map(\.operation))
    let badCover = entries.filter { if case .covered(let by) = $0.status { return by != "masks" && !exactOps.contains(by) } else { return false } }.map(\.operation)
    check("PL4 a module 'covered by' another is covered by an exact module (or by masks)", badCover.isEmpty, "\(badCover)")
    let goldenOps = Set(CIEngineProbe.goldenCases().map(\.operation))
    check("PL5 every exact, unverified or approximate module that is not geometry has a golden case",
          entries.filter { isBuilt($0.status) }.allSatisfy { goldenOps.contains($0.operation) || ["flip", "ashift", "crop"].contains($0.operation) })
    let counts = Dictionary(grouping: entries) { e -> String in
        switch e.status { case .exact: "exact"; case .unverified: "unverified"; case .approximate: "approximate"
        case .covered: "covered"; case .planned: "planned"; case .dropped: "dropped" }
    }.mapValues(\.count)
    print("     parity: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    if let i = CommandLine.arguments.firstIndex(of: "--parity-doc"), i + 1 < CommandLine.arguments.count {
        try? ParityList.markdown(catalogue: catalogue.map(\.operation)).write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
        print("wrote the parity list to \(CommandLine.arguments[i + 1])")
    }
}

// MS the mask controls the app shows (MaskSchema) against the engine that reads them
do {
    var misses: [String] = [], badDefaults: [String] = [], nonFinite: [String] = []
    for kind in MaskKind.allCases {
        let base: [String: Double] = ["mask_mode": 2, "mask_kind": Double(kind.rawValue)]
        var atDefaults = base
        for c in kind.controls { atDefaults[c.key] = c.defaultValue }
        guard let empty = Mask.spec(from: base), let full = Mask.spec(from: atDefaults) else { misses.append("\(kind.title): no spec"); continue }
        if zip(empty.p, full.p).contains(where: { abs($0 - $1) > 1e-12 }) || empty.p.count != full.p.count { badDefaults.append(kind.title) }
        for c in kind.controls {
            let far = (c.range.upperBound - c.defaultValue) >= (c.defaultValue - c.range.lowerBound) ? c.range.upperBound : c.range.lowerBound
            var moved = atDefaults; moved[c.key] = c.defaultValue + 0.6 * (far - c.defaultValue)
            if Mask.spec(from: moved)?.p == full.p { misses.append("\(kind.title).\(c.key)") }
            for end in [c.range.lowerBound, c.range.upperBound] {
                var edge = atDefaults; edge[c.key] = end
                guard let s = Mask.spec(from: edge) else { nonFinite.append("\(kind.title).\(c.key)"); continue }
                for (x, y, rgb) in [(5.5, 5.5, SIMD3(0.2, 0.3, 0.4)), (40.5, 30.5, SIMD3(1.5, 0.1, 0.0)), (24.0, 20.0, SIMD3(0, 0, 0))] {
                    let a = Mask.alpha(s, x: x, y: y, width: 48, height: 40, rgb: rgb)
                    if !(a.isFinite && a >= 0 && a <= 1) { nonFinite.append("\(kind.title).\(c.key)=\(end)") }
                }
            }
        }
    }
    check("MS1 every control the app shows for a mask kind changes what the engine parses (a typo in a key would not)", misses.isEmpty, "\(misses)")
    check("MS1 the app's defaults are the engine's defaults, for every kind", badDefaults.isEmpty, "\(badDefaults)")
    check("MS1 at both ends of every control's range the mask is a finite weight in 0...1", nonFinite.isEmpty, "\(nonFinite)")
    let base: [String: Double] = ["mask_mode": 2, "mask_kind": 1]
    check("MS1 the shared controls: invert and edge refine are read",
          Mask.spec(from: base.merging(["mask_invert": 1]) { $1 })?.invert == true
            && Mask.spec(from: base.merging([MaskCommon.refine.key: 7]) { $1 })?.refineRadius == 7)
}

// E-MQ masks live in the upright picture: the GPU matte equals the oracle for every orientation, and a portrait-shot frame
// through the engine brightens the right half of the upright picture, not the right half of the sensor
do {
    var worstMatte = 0.0
    for o in Orientation.allCases {
        for blend in [["mask_mode": 2.0, "mask_kind": 1, "mask_angle": 33, "mask_feather": 0.3],
                      ["mask_mode": 2.0, "mask_kind": 2, "mask_cx": 0.3, "mask_cy": 0.7, "mask_rx": 0.2, "mask_ry": 0.1, "mask_rotation": 20, "mask_feather": 0.4]] {
            var s = Mask.spec(from: blend)!
            s.orientation = o
            worstMatte = max(worstMatte, maskMatteError(s))
        }
    }
    check("E-MQ1 the GPU matte equals the oracle for all eight camera orientations (gradient and ellipse)", worstMatte < 1e-4, "\(worstMatte)")
    let blend: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(1), "mask_angle": .number(0), "mask_position": .number(0.5), "mask_feather": .number(0)]
    let plain = (try? CIEngineProbe.renderSized(stack: [StackEntry(operation: "exposure", params: ["exposure": .number(1)])],
                                                 pixels: detailPx, width: detailW, height: detailH, camera: .rotateCW90)) ?? (pixels: [SIMD4<Float>](), width: 0, height: 0)
    let masked = (try? CIEngineProbe.renderSized(stack: [maskedExposure(blend)], pixels: detailPx, width: detailW, height: detailH, camera: .rotateCW90)) ?? (pixels: [SIMD4<Float>](), width: 0, height: 0)
    let clean = (try? CIEngineProbe.renderSized(stack: [], pixels: detailPx, width: detailW, height: detailH, camera: .rotateCW90)) ?? (pixels: [SIMD4<Float>](), width: 0, height: 0)
    var okLeft = masked.pixels.count == detailW * detailH && masked.width == detailH && masked.height == detailW, okRight = okLeft
    if okLeft {
        for y in 0..<masked.height { for x in 0..<masked.width {
            let i = y * masked.width + x
            let want = x < masked.width / 2 ? clean.pixels[i] : plain.pixels[i]
            for c in 0..<3 where !(masked.pixels[i][c].isFinite && abs(masked.pixels[i][c] - want[c]) <= 1e-4 * max(1, abs(want[c]))) {
                if x < masked.width / 2 { okLeft = false } else { okRight = false }
            }
        } }
    }
    check("E-MQ2 in a portrait-shot frame the left half of the upright picture is untouched", okLeft)
    check("E-MQ2 and the right half of the upright picture has the exposure", okRight)
}

// E-MS the mask overlay: where the matte is 1 the picture is half red, elsewhere untouched
do {
    var blend: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(1), "mask_angle": .number(0), "mask_position": .number(0.5), "mask_feather": .number(0)]
    let plain = runDetail([maskedExposure(blend)])
    blend["mask_show"] = .number(1)
    let shown = runDetail([maskedExposure(blend)])
    var leftOK = shown.count == detailW * detailH, rightOK = leftOK
    if leftOK {
        for y in 0..<detailH { for x in 0..<detailW {
            let i = y * detailW + x, p = plain[i], s = shown[i]
            guard s.x.isFinite, s.y.isFinite, s.z.isFinite else { leftOK = false; rightOK = false; continue }
            if x < detailW / 2 {
                if abs(s.x - p.x) > 1e-5 || abs(s.y - p.y) > 1e-5 || abs(s.z - p.z) > 1e-5 { leftOK = false }
            } else {
                // half the exposed picture plus half of (1, 0.12, 0.12)
                let want = SIMD3(0.5 * p.x + 0.5, 0.5 * p.y + 0.06, 0.5 * p.z + 0.06)
                if abs(s.x - want.x) > 2e-4 * max(1, want.x) || abs(s.y - want.y) > 2e-4 * max(1, want.y) || abs(s.z - want.z) > 2e-4 * max(1, want.z) { rightOK = false }
            }
        } }
    }
    check("E-MS1 outside the mask the overlay changes nothing", leftOK)
    check("E-MS1 inside the mask the picture is half red (0.5 * picture + 0.5 * (1, 0.12, 0.12))", rightOK)
    var none = blend; none["mask_mode"] = .number(1)
    let flat = runDetail([maskedExposure(none)]), flatPlain = runDetail([maskedExposure(["mask_mode": .number(1)])])
    check("E-MS1 a module with no local mask ignores the flag", flat == flatPlain)
}

// E-RL radial light through the engine: against the oracle, tile seams, the zero shortcut, and in a portrait-shot frame
do {
    let params: [String: ParamValue] = ["exposure": .number(1.2), "x": .number(0.4), "y": .number(0.6), "size": .number(0.25), "shape": .number(0.7),
                                         "rotation": .number(25), "feather": .number(0.4), "outside": .number(0)]
    let stack = [StackEntry(operation: "radiallight", params: params)]
    let spec = RadialLight.spec(x: 0.4, y: 0.6, size: 0.25, shape: 0.7, rotation: 25, feather: 0.4, outside: false)
    let want = RadialLight.apply(detailImg, width: detailW, height: detailH, ev: 1.2, spec: spec)
    let got = runDetail(stack)
    check("E-RL radial light matches the oracle within 1/255 and unclamped within 2e-4", worst(got, want) < tol && worstLinear(got, want) < 2e-4,
          "encoded \(worst(got, want)), linear \(worstLinear(got, want))")
    check("E-RL the oracle really changes the fixture (a no-op GPU path would fail)", worstLinear(detailPx, want) > 0.05)
    let seams = detailSeams(stack, oracle: want)
    check("E-RL-seam radial light renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    check("E-RL-zero exposure 0 returns the input untouched", runDetail([StackEntry(operation: "radiallight", params: ["exposure": .number(0)])]) == detailPx)
    var outside = params; outside["outside"] = .number(1)
    let wantOut = RadialLight.apply(detailImg, width: detailW, height: detailH, ev: 1.2,
                                    spec: RadialLight.spec(x: 0.4, y: 0.6, size: 0.25, shape: 0.7, rotation: 25, feather: 0.4, outside: true))
    check("E-RL-outside the surround variant matches the oracle", worstLinear(runDetail([StackEntry(operation: "radiallight", params: outside)]), wantOut) < 2e-4)
    // a portrait-shot frame: the ellipse sits where the UPRIGHT picture puts it
    var cam = spec; cam.orientation = .rotateCW90
    let wantCam = RadialLight.apply(detailImg, width: detailW, height: detailH, ev: 1.2, spec: cam)
    if let r = try? CIEngineProbe.renderSized(stack: stack, pixels: detailPx, width: detailW, height: detailH, camera: .rotateCW90), r.width == detailH, r.height == detailW {
        var e = 0.0
        for y in 0..<detailH { for x in 0..<detailW {
            let u = Orientation.rotateCW90.map(SIMD2(Double(x) + 0.5, Double(y) + 0.5), size: SIMD2(Double(detailW), Double(detailH)))
            let p = r.pixels[Int(u.y) * r.width + Int(u.x)], o = wantCam[y * detailW + x]
            for c in 0..<3 { let d = abs(Double(p[c]) - o[c]) / max(1, abs(o[c])); e = d.isFinite ? max(e, d) : .infinity }
        } }
        check("E-RL-camera in a portrait-shot frame the radial light matches the oracle with the camera's orientation", e < 2e-4, "\(e)")
    } else { check("E-RL-camera renders", false) }
}

// E-CL the clipping overlay on the GPU against DarkroomCore.Clipping, on a sweep that has blown, crushed and fine pixels
do {
    let n = 64
    var px: [SIMD4<Float>] = []
    for i in 0..<(n * n) {
        let t = Double(i) / Double(n * n - 1)
        // channels walk different curves through 0 ... 2.5 and a little below 0, so all three states and their borders occur
        let r = -0.05 + 2.6 * t, g = 1.1 - 1.2 * abs(sin(t * 37)), b = 0.5 + 0.55 * sin(t * 11)
        px.append(SIMD4(Float(r), Float(g), Float(b), 1))
    }
    let got = (try? CIEngineProbe.filter(.clipping, pixels: px, width: n, height: n)) ?? []
    var worstErr = got.count == px.count ? 0.0 : Double.infinity, states = Set<String>()
    for (i, p) in px.enumerated() where i < got.count {
        let rgb = SIMD3(Double(p.x), Double(p.y), Double(p.z))
        // skip pixels within float rounding of a boundary: the CPU decides them in Double, the GPU in Float
        let near = [Clipping.blownFrom, Clipping.crushedTo].contains { c in rgb.indices.contains { abs(rgb[$0] - c) < 2e-6 } }
        if near { continue }
        states.insert("\(Clipping.state(rgb))")
        let want = Clipping.tint(rgb)
        for c in 0..<3 { let d = abs(Double(got[i][c]) - want[c]); worstErr = got[i][c].isFinite ? max(worstErr, d) : .infinity }
    }
    check("E-CL1 the GPU clipping overlay matches the oracle on a sweep with blown, crushed and fine pixels (\(states.sorted()))", worstErr < 1e-5 && states.count == 3, "\(worstErr)")
}

// E-RS raster masks (brush and detected): the engine reads a painted picture where the pixel sits in the upright photo
do {
    // a painted raster: a thick diagonal stroke and an eraser nick, on a 3:2 upright picture
    let strokes = [BrushStroke(points: [SIMD2(0.1, 0.15), SIMD2(0.5, 0.5), SIMD2(0.9, 0.85)], radius: 0.12, softness: 0.5, flow: 1, erase: false),
                   BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.05, softness: 0, flow: 1, erase: true)]
    let size = Brush.rasterSize(aspect: Double(detailW) / Double(detailH))
    let raster = Brush.rasterize(strokes[...], width: size.width, height: size.height, id: "layer1.2")
    let picture = MaskPicture(id: raster.id, width: raster.width, height: raster.height, pixels: raster.pixels)
    let blend: [String: ParamValue] = ["mask_mode": .number(2), "mask_kind": .number(5), "mask_raster": .option(raster.id)]
    var spec = Mask.spec(from: ["mask_mode": 2, "mask_kind": 5])!
    spec.raster = raster
    func engine(_ stack: [StackEntry], camera: Orientation = .none, rasters: [MaskPicture] = [picture]) -> (pixels: [SIMD4<Float>], width: Int, height: Int)? {
        try? CIEngineProbe.renderSized(stack: stack, pixels: detailPx, width: detailW, height: detailH, camera: camera, rasters: rasters)
    }
    let stack = [maskedExposure(blend)]
    let want = maskedExposureOracle(spec)
    let got = engine(stack)?.pixels ?? []
    // the engine's matte is 8 bit, so allow a quantisation step of the weight in the picture
    let eLin = worstLinear(got, want)
    check("E-RS1 a painted raster mask through the engine matches the oracle (the 8-bit matte allows 6e-3)", eLin < 6e-3 && worst(got, want) < tol, "linear \(eLin), encoded \(worst(got, want))")
    check("E-RS1 the paint really shows: the masked picture differs from the unmasked and from the all-masked one",
          worstLinear(got, detailImg) > 0.05 && worstLinear(got, detailImg.map { $0 * 2 }) > 0.05)
    let seams = detailSeams(stack, oracle: want, rasters: [picture])
    check("E-RS2 a raster mask renders the same in a region as in the full frame (the matte is a cropped image)", seams.seam < 1e-6 && seams.fullVsOracle < 6e-3, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    var invBlend = blend; invBlend["mask_invert"] = .number(1)
    var invSpec = spec; invSpec.invert = true
    check("E-RS3 inverted, the raster mask is the complement", worstLinear(engine([maskedExposure(invBlend)])?.pixels ?? [], maskedExposureOracle(invSpec)) < 6e-3)
    check("E-RS4 a missing raster changes nothing: the module has no effect where it has no mask",
          worstLinear(engine(stack, rasters: [])?.pixels ?? [], detailImg) < 1e-6)
    // a portrait-shot frame: the stroke runs where the UPRIGHT picture has it
    var camSpec = spec; camSpec.orientation = .rotateCW90
    let wantCam = Mask.apply(camSpec, to: detailImg, width: detailW, height: detailH) { $0.map { $0 * 2 } }
    if let r = engine(stack, camera: .rotateCW90), r.width == detailH, r.height == detailW {
        var e = 0.0
        for y in 0..<detailH { for x in 0..<detailW {
            let u = Orientation.rotateCW90.map(SIMD2(Double(x) + 0.5, Double(y) + 0.5), size: SIMD2(Double(detailW), Double(detailH)))
            let p = r.pixels[Int(u.y) * r.width + Int(u.x)], o = wantCam[y * detailW + x]
            for c in 0..<3 { let d = abs(Double(p[c]) - o[c]) / max(1, abs(o[c])); e = d.isFinite ? max(e, d) : .infinity }
        } }
        check("E-RS5 in a portrait-shot frame the painted mask lands where the upright picture has it", e < 6e-3, "\(e)")
    } else { check("E-RS5 renders", false) }
    var refined = blend; refined["mask_refine"] = .number(4)
    var refinedSpec = spec; refinedSpec.refineRadius = 4
    check("E-RS6 edge refine works on a raster mask (guided by the photo)", worstLinear(engine([maskedExposure(refined)])?.pixels ?? [], maskedExposureOracle(refinedSpec)) < 2e-2)
}

// E-TP the point curve through the engine: points against the oracle, an old five-height edit equal to its new-format twin,
// hostile values made safe, tile seams
do {
    func entry(_ params: [String: Double]) -> StackEntry { StackEntry(operation: "tonecurve", params: params.mapValues { .number($0) }) }
    func oracle(_ xs: [Double], _ ys: [Double]) -> [SIMD3<Double>] {
        let s = ToneCurve.sanitized(xs: xs, ys: ys)
        return detailImg.map { ToneCurve.apply($0, xs: s.xs, ys: s.ys) }
    }
    let xs = [0.03, 0.2, 0.31, 0.55, 0.8, 0.97], ys = [0.05, 0.14, 0.3, 0.62, 0.88, 0.97]
    var p: [String: Double] = ["n": 6]
    for i in 0..<6 { p["x\(i)"] = xs[i]; p["y\(i)"] = ys[i] }
    let want = oracle(xs, ys), got = runDetail([entry(p)])
    check("E-TP1 a six-point curve through the engine matches the oracle (1/255 and 2e-4 unclamped)", worst(got, want) < tol && worstLinear(got, want) < 2e-4, "\(worst(got, want)) \(worstLinear(got, want))")
    check("E-TP1 and it really moves the picture", worstLinear(detailPx, want) > 0.03)
    let seams = detailSeams([entry(p)], oracle: want)
    check("E-TP2 the point curve renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    // an edit saved before point curves (only y0...y4) is the same picture as the same five points in the new format
    let legacy = entry(["y1": 0.15, "y2": 0.5, "y3": 0.85])
    let twin = entry(["n": 5, "x0": 0, "x1": 0.25, "x2": 0.5, "x3": 0.75, "x4": 1, "y0": 0, "y1": 0.15, "y2": 0.5, "y3": 0.85, "y4": 1])
    check("E-TP3 an old five-height edit renders exactly as its new-format twin", runDetail([legacy]) == runDetail([twin]) && runDetail([legacy]) != detailPx)
    let hostile = entry(["n": 11, "x0": 0.9, "x1": 0.1, "x2": 5, "x3": -2, "y0": 7, "y1": -3, "y2": 0.4, "y3": 0.9, "x4": 0.5, "y4": 0.2, "x5": 0.5, "y5": 0.2, "x6": 0.5, "y6": 0.2, "x7": 0.5, "y7": 0.2])
    let h = runDetail([hostile])
    check("E-TP4 a point count of 11 with unsorted, out-of-range points renders a finite picture", h.count == detailW * detailH && h.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    check("E-TP5 n = 1 or a NaN count falls back to the old five-height path", runDetail([entry(["n": 1, "y2": 0.4])]) == runDetail([entry(["y2": 0.4])]))
    check("E-TP6 two points (0,0) and (1,1) change nothing (within float rounding)", worstLinear(runDetail([entry(["n": 2, "x0": 0, "y0": 0, "x1": 1, "y1": 1])]), detailImg) < 1e-4)
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
