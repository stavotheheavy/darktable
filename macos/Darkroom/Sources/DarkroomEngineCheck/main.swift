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
    let oracle = scene.map { tone.displayLinear($0) }
    let e3 = worst(run([StackEntry(operation: "display", params: ["contrast": .number(contrast)])]), oracle)
    check("E3 display transform at contrast \(Int(contrast)) matches the oracle within 1/255", e3 < tol, "\(e3)")
}

// E4 a chain in pipeline order regardless of stack order: white balance, exposure, then display
let chain = [StackEntry(operation: "display", params: ["contrast": .number(20)]),
             StackEntry(operation: "exposure", params: ["exposure": .number(-0.7)]),
             wbStack[0]]
let tone20 = SceneTone(contrast: 20)
let chainOracle = scene.map { p -> SIMD3<Double> in
    tone20.displayLinear(p * coeff * Exposure.gain(ev: -0.7))
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
    let toDisplay: (SIMD3<Double>) -> SIMD3<Double> = { tone.displayLinear($0) }
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

// E-IV invert: the per-pixel kernel through the engine against Invert in DarkroomCore (the module has no parameters)
let invertStack = [StackEntry(operation: "invert", params: [:])]
let invertOracle = scene.map { Invert.apply($0) }
let eIV = worst(run(invertStack), invertOracle)
check("E-IV invert matches the oracle within 1/255", eIV < tol, "\(eIV)")
let eIVLinear = worstLinear(run(invertStack), invertOracle)
check("E-IV invert matches the oracle unclamped (relative 1e-4)", eIVLinear < 1e-4, "\(eIVLinear)")

// E-CBS colisa: the fused per-pixel kernel through the engine against Colisa in DarkroomCore
let colisaStack = [StackEntry(operation: "colisa", params: ["contrast": .number(0.4), "brightness": .number(0.3), "saturation": .number(0.5)])]
let colisaOracle = scene.map { Colisa.apply($0, contrast: 0.4, brightness: 0.3, saturation: 0.5) }
let eCL = worst(run(colisaStack), colisaOracle)
check("E-CBS colisa matches the oracle within 1/255", eCL < tol, "\(eCL)")
let eCLLinear = worstLinear(run(colisaStack), colisaOracle)
check("E-CBS colisa matches the oracle unclamped (relative 1e-4)", eCLLinear < 1e-4, "\(eCLLinear)")

// E-VE velvia: the fused per-pixel kernel through the engine against Velvia in DarkroomCore
let velviaStack = [StackEntry(operation: "velvia", params: ["strength": .number(0.7)])]
let velviaOracle = scene.map { Velvia.apply($0, strength: 0.7) }
let eVE = worst(run(velviaStack), velviaOracle)
check("E-VE velvia matches the oracle within 1/255", eVE < tol, "\(eVE)")
let eVELinear = worstLinear(run(velviaStack), velviaOracle)
check("E-VE velvia matches the oracle unclamped (relative 1e-4)", eVELinear < 1e-4, "\(eVELinear)")

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
    let lum = Plane(width: fw, height: fh, values: px.map { ColorCommon.luminance(SIMD3(Double($0.x), Double($0.y), Double($0.z))) })
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

// E-ZE zone exposure through the engine: the guided base and the zone gain on the GPU against ZoneExposure in DarkroomCore, across tile
// seams, and the identity at all zeros (the radius is a fraction of the frame, so it follows the render scale by itself)
do {
    let ze: [String: ParamValue] = ["shadows": .number(1.2), "highlights": .number(-1), "blacks": .number(0.5), "z_p1": .number(0.4), "scale": .number(0.1)]
    let stack = [StackEntry(operation: "zones", params: ze)]
    let settings = ZoneExposure.Settings(values: ["shadows": 1.2, "highlights": -1, "blacks": 0.5, "z_p1": 0.4, "scale": 0.1])
    let want = ZoneExposure.apply(detailImg, width: detailW, height: detailH, settings: settings)
    let got = runDetail(stack)
    let eZ = worstLinear(got, want), eEnc = worst(got, want)
    check("E-ZE zone exposure matches the oracle within 1/255 and unclamped within 2e-4", eEnc < tol && eZ < 2e-4, "encoded \(eEnc), linear \(eZ)")
    check("E-ZE the oracle really changes the fixture (a no-op GPU path would fail)", worstLinear(detailPx, want) > 0.05, "\(worstLinear(detailPx, want))")
    let seams = detailSeams(stack, oracle: want)
    check("E-ZE-seam zone exposure renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    check("E-ZE-zero all zones at zero returns the input untouched", runDetail([StackEntry(operation: "zones", params: [:])]) == detailPx)
    // it is a scene-domain module: with the display transform on it runs before it, whichever order the stack lists them in
    let both = runDetail([StackEntry(operation: "display", params: ["contrast": .number(0)]), StackEntry(operation: "zones", params: ze)])
    let displayOnly = runDetail([StackEntry(operation: "display", params: ["contrast": .number(0)])])
    let tone = SceneTone()
    let zonesThenDisplay = want.map { tone.displayLinear($0) }
    check("E-ZE-order with display on, zones runs before it (scene light)", worst(both, zonesThenDisplay) < tol && worst(both, zonesThenDisplay) < worst(displayOnly, zonesThenDisplay),
          "\(worst(both, zonesThenDisplay))")
}

// E-DOM domains: every display-referred module runs after the display transform when it is on (the stack's own order is not
// what decides), and the result differs from the other order, so the order is not a no-op
do {
    let displayEntry = StackEntry(operation: "display", params: ["contrast": .number(0), "exposure": .number(0)])
    let displayRendered = runDetail([displayEntry])
    let order = Array(CIEngineProbe.displayReferredOperations).sorted()
    var wrong: [String] = [], commute: [String] = []
    for case let c in CIEngineProbe.goldenCases() where order.contains(c.operation) {
        let entry = c.stack[0]
        let engineOrder = runDetail([entry, displayEntry])
        guard let after = try? CIEngineProbe.renderSized(stack: [entry], pixels: displayRendered, width: detailW, height: detailH).pixels,
              let before = try? CIEngineProbe.renderSized(stack: [displayEntry], pixels: runDetail([entry]), width: detailW, height: detailH).pixels,
              engineOrder.count == after.count else { wrong.append(c.operation); continue }
        func gap(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
            var w = 0.0
            for (x, y) in zip(a, b) { for k in 0..<3 { w = max(w, abs(Double(x[k]) - Double(y[k]))) } }
            return w
        }
        if gap(engineOrder, after) > 1e-4 { wrong.append("\(c.operation) \(gap(engineOrder, after))") }
        if gap(engineOrder, before) < 4.0 / 255 { commute.append(c.operation) }
    }
    check("E-DOM all \(order.count) display-referred modules run after the display transform", wrong.isEmpty && order.count == 16, "\(wrong)")
    check("E-DOM for each of them the other order gives a visibly different picture (those that do not: \(commute))", commute.isEmpty, "\(commute)")
    check("E-DOM zones and the scene modules are not in the display set", !CIEngineProbe.displayReferredOperations.contains("zones")
          && !CIEngineProbe.displayReferredOperations.contains("exposure") && !CIEngineProbe.displayReferredOperations.contains("bloom") && !CIEngineProbe.displayReferredOperations.contains("colorbalancergb"))
}

// E-FOLD gains fold into one multiply: white balance and exposure join the display kernel, or run as one pass before the next module
do {
    let wb = StackEntry(operation: "temperature", params: ["red": .number(coeff.x), "green": .number(coeff.y), "blue": .number(coeff.z)])
    let ex = StackEntry(operation: "exposure", params: ["exposure": .number(0.9)])
    let g = Exposure.gain(ev: 0.9)
    // gains only: one pass, the product
    let eGains = worst(run([ex, wb]), scene.map { $0 * coeff * g })
    check("E-FOLD white balance and exposure together are the product of the two gains", eGains < tol, "\(eGains)")
    // a gain run, then a module that is not a gain: the run applies as one pass before it, in pipeline order
    let cb = StackEntry(operation: "colorbalancergb", params: ["contrast": .number(0.25), "saturation_global": .number(0.3)])
    let cbOracle = scene.map { p -> SIMD3<Double> in
        let lit = p * coeff * g
        let (lc, sat) = (0.25, 0.3)
        _ = (lc, sat)
        return lit
    }
    let viaCB = run([cb, ex, wb]), withoutCB = run([cb])
    _ = cbOracle
    let expected = (try? CIEngineProbe.render(stack: [cb], pixels: scene.map { p in let q = p * coeff * g; return SIMD4(Float(q.x), Float(q.y), Float(q.z), 1) }, width: n, height: n)) ?? []
    var eCB = viaCB.count == expected.count ? 0.0 : Double.infinity
    for (a, b) in zip(viaCB, expected) { for k in 0..<3 { eCB = max(eCB, abs(Double(a[k]) - Double(b[k])) / max(1, Double(abs(b[k])))) } }
    check("E-FOLD gains run before the next module (colour balance sees the gained picture, as in pipeline order)", eCB < 2e-4 && withoutCB != viaCB, "\(eCB)")
    // a gain with an opacity under 100 is not folded: it is a module of its own, mixed back over its input
    let half = StackEntry(operation: "exposure", params: ["exposure": .number(1)], blend: ["opacity": .number(50)])
    let eHalf = worst(run([half, wb]), scene.map { ($0 * 0.5 + $0 * Exposure.gain(ev: 1) * 0.5) * coeff })
    check("E-FOLD a gain at 50% opacity is not folded away (mixed over its input, then white balance)", eHalf < tol, "\(eHalf)")
    // a disabled display transform leaves the run to be applied at the end
    let off = StackEntry(operation: "display", params: [:], enabled: false)
    check("E-FOLD with the display transform off the gains still apply", worst(run([wb, ex, off]), scene.map { $0 * coeff * g }) < tol)
    // display's own lift joins the same multiply
    let tone0 = SceneTone()
    let eLift = worst(run([wb, ex, StackEntry(operation: "display", params: ["contrast": .number(0), "exposure": .number(0.5)])]),
                      scene.map { tone0.displayLinear(working: $0, gain: coeff * g * Exposure.gain(ev: 0.5)) })
    check("E-FOLD white balance, exposure and display's lift fold into one multiply and match the oracle", eLift < tol, "\(eLift)")
}

// E-SEG segment cache: a render through the cache is the render without it (the texture's orientation included), a slider moved after a
// neighbourhood module reuses the cached picture, and anything that changes the pixels before it makes a new entry
do {
    // a stored segment is a 16-bit float texture and the uncached chain keeps 32-bit intermediates: the two agree to half-float rounding (sharpening
    // amplifies it a little); an upside-down or stale picture is off by 0.5 or more
    let segTol = 4e-3
    if let probe = try? SegmentProbe() {
        let wb = StackEntry(operation: "temperature", params: ["red": .number(1.3), "green": .number(1), "blue": .number(0.8)])
        func stack(contrast: Double = 0, sharpen: Double = 0.5, ev: Double = 0.4) -> [StackEntry] {
            [wb, StackEntry(operation: "exposure", params: ["exposure": .number(ev)]),
             StackEntry(operation: "sharpen", params: ["amount": .number(sharpen)]),
             StackEntry(operation: "atrous", params: ["detail_1": .number(0.5)]),
             StackEntry(operation: "display", params: ["contrast": .number(contrast), "exposure": .number(0.5)])]
        }
        func gap(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            var w = 0.0
            for (x, y) in zip(a, b) { for k in 0..<3 { w = max(w, abs(Double(x[k]) - Double(y[k])) / max(1, Double(abs(y[k])))) } }
            return w
        }
        let r = { (s: [StackEntry], cached: Bool) in (try? probe.render(stack: s, pixels: detailPx, width: detailW, height: detailH, cached: cached)) ?? [] }
        // one, two and three stored segments: a flip per segment would cancel in pairs, so the count matters
        for (n, ops) in [(1, ["sharpen"]), (2, ["sharpen", "atrous"]), (3, ["sharpen", "atrous", "bilat"])] {
            let own = try? SegmentProbe()
            let s: [StackEntry] = ops.map { StackEntry(operation: $0, params: [:]) } + [StackEntry(operation: "display", params: ["contrast": .number(0), "exposure": .number(0.5)])]
            let via = (try? own?.render(stack: s, pixels: detailPx, width: detailW, height: detailH, cached: true)) ?? nil
            let direct = (try? own?.render(stack: s, pixels: detailPx, width: detailW, height: detailH, cached: false)) ?? nil
            let hit = (try? own?.render(stack: s, pixels: detailPx, width: detailW, height: detailH, cached: true)) ?? nil
            check("E-SEG-orient \(n) stored segment\(n == 1 ? "" : "s") come back upright (first render and a cache hit both equal the uncached picture; an upside-down one is far off)",
                  via != nil && direct != nil && hit != nil && gap(via!, direct!) < segTol && gap(hit!, direct!) < segTol && own!.entries == n,
                  "first \(via.map { gap($0, direct ?? []) } ?? -1), hit \(hit.map { gap($0, direct ?? []) } ?? -1), entries \(own?.entries ?? -1)")
        }
        let first = r(stack(), true), plain = r(stack(), false)
        check("E-SEG the first render through the cache (it stores two segments) equals the render without it", gap(first, plain) < segTol && probe.entries == 2, "gap \(gap(first, plain)), entries \(probe.entries)")
        let hits0 = probe.hits
        let again = r(stack(), true)
        check("E-SEG the same stack again is served from the cache and is identical", probe.hits == hits0 + 1 && again == first, "hits \(probe.hits - hits0)")
        let moved = r(stack(contrast: 35), true)
        check("E-SEG a slider moved after the neighbourhood modules reuses the cache (no new entry) and matches an uncached render",
              probe.hits == hits0 + 2 && probe.entries == 2 && gap(moved, r(stack(contrast: 35), false)) < segTol && gap(moved, first) > 0.01,
              "hits \(probe.hits - hits0), entries \(probe.entries), gap \(gap(moved, r(stack(contrast: 35), false)))")
        let sharper = r(stack(sharpen: 1.2), true)
        check("E-SEG changing a module inside the segment makes a new entry; the picture is the new one, never the old (no stale hit)",
              probe.entries > 2 && gap(sharper, r(stack(sharpen: 1.2), false)) < segTol && gap(sharper, first) > 1e-3, "entries \(probe.entries), vs uncached \(gap(sharper, r(stack(sharpen: 1.2), false))), vs old \(gap(sharper, first))")
        let earlier = r(stack(ev: -0.8), true)
        check("E-SEG changing a gain before the segments invalidates them (exposure -0.8: not the old picture, matches uncached)",
              gap(earlier, r(stack(ev: -0.8), false)) < segTol && gap(earlier, first) > 0.01, "\(gap(earlier, first))")
        // a render that draws a mask over the picture skips the cache
        let entriesBefore = probe.entries
        var shown = stack()
        shown[2] = StackEntry(operation: "sharpen", params: ["amount": .number(0.5)], blend: ["mask_mode": .number(2), "mask_kind": .number(0), "mask_show": .number(1)])
        _ = r(shown, true)
        check("E-SEG a render that shows a mask over the picture does not touch the cache", probe.entries == entriesBefore)
    } else {
        check("E-SEG the segment probe could not start", false)
    }
}

// E-CTX the app's own context (half float, linear Rec.2020, CIEngine.makeContext) renders what the full-precision probe context does: the
// oracle checks above run in float, so this is what ties them to the pictures the app shows
do {
    if let probe = try? SegmentProbe() {
        let cases: [(String, [StackEntry])] = [
            ("white balance, exposure, display", chain),
            ("tone curve after display", [StackEntry(operation: "display", params: ["contrast": .number(0)]),
                                          StackEntry(operation: "tonecurve", params: ["y0": .number(0), "y1": .number(0.15), "y2": .number(0.5), "y3": .number(0.85), "y4": .number(1)])]),
            ("colour balance", [StackEntry(operation: "colorbalancergb", params: ["contrast": .number(0.3), "saturation_global": .number(0.4)])]),
            ("rgb levels", [StackEntry(operation: "rgblevels", params: ["black": .number(0.1), "grey": .number(0.4), "white": .number(0.9)])]),
        ]
        for (name, stack) in cases {
            let app = (try? probe.render(stack: stack, pixels: input, width: n, height: n, cached: false)) ?? []
            let full = run(stack)
            var e = app.count == full.count ? 0.0 : Double.infinity
            for (a, b) in zip(app, full) {
                for k in 0..<3 {
                    guard a[k].isFinite else { e = .infinity; continue }
                    e = max(e, abs(Double(a[k]) - Double(b[k])) / max(1, abs(Double(b[k]))))
                }
            }
            check("E-CTX the app's context agrees with the float context on \(name) within 2e-3 relative", e < 2e-3, "\(e)")
        }
    } else {
        check("E-CTX the app's context could not start", false)
    }
}

// T5v the viewport: edit-to-pixels at 2200 x 1467 (the size that used to fall off Core Image's cache) in the app's own context and through the
// segment cache, with the viewport's 8-bit read-back. The default edit (white balance, exposure, display) and a display-contrast drag with the
// four detail modules on must both stay under 16 ms at p95. Load-sensitive like any timing: it has several times of margin on an idle Mac.
do {
    if let probe = try? SegmentProbe() {
        let vw = 2200, vh = 1467
        let big: [SIMD4<Float>] = (0..<(vw * vh)).map { i in
            let x = Double(i % vw) / Double(vw), y = Double(i / vw) / Double(vh)
            return SIMD4(Float(0.05 + 0.6 * x * y + 0.02 * sin(x * 90)), Float(0.04 + 0.5 * x), Float(0.03 + 0.4 * y), 1)
        }
        let source = probe.makeSource(pixels: big, width: vw, height: vh)
        func p95(_ make: (Int) -> [StackEntry]) -> Double {
            _ = try? probe.timeFrame(stack: make(0), source: source)
            var times: [Double] = []
            for i in 1...30 { if let ms = try? probe.timeFrame(stack: make(i), source: source) { times.append(ms) } }
            guard times.count == 30 else { return .infinity }
            return times.sorted()[Int(Double(times.count) * 0.95) - 1]
        }
        let wbEntry = StackEntry(operation: "temperature", params: ["red": .number(1.2), "green": .number(1), "blue": .number(0.9)])
        let defaultEdit = p95 { i in [wbEntry, StackEntry(operation: "exposure", params: ["exposure": .number(Double(i) * 0.02)]),
                                      StackEntry(operation: "display", params: ["contrast": .number(0), "exposure": .number(0.5)])] }
        let detail: [StackEntry] = [StackEntry(operation: "sharpen", params: ["amount": .number(0.8)]), StackEntry(operation: "bilat", params: [:]),
                                    StackEntry(operation: "atrous", params: [:]), StackEntry(operation: "denoiseprofile", params: [:])]
        let drag = p95 { i in detail + [StackEntry(operation: "display", params: ["contrast": .number(Double(i)), "exposure": .number(0.5)])] }
        print("      viewport \(vw)x\(vh): default edit p95 \(String(format: "%.1f", defaultEdit)) ms, contrast drag with four detail modules p95 \(String(format: "%.1f", drag)) ms")
        check("T5v viewport p95 under 16 ms for the default edit at \(vw) px", defaultEdit < 16, "\(defaultEdit)")
        check("T5v viewport p95 under 16 ms for a contrast drag with the four detail modules on (the segment cache)", drag < 16, "\(drag)")
    } else {
        check("T5v the segment probe could not start", false)
    }
}

// E-DIT the viewport's dither: a dark smooth ramp (linear 0.0005...0.02, about sRGB codes 6 to 40) rendered to 8 bits. Plain, it is a
// staircase; dithered, the codes average to the ideal value over a few pixels, the error stays within a code and a half, and black and
// white are left alone. The mutation is the plain render (no dither), which has the larger local error.
do {
    if let probe = try? SegmentProbe() {
        let dw = 1024, dh = 16
        func linear(_ x: Int) -> Double { 0.0005 + 0.02 * Double(x) / Double(dw) }
        func codeOf(_ v: Double) -> Double { 255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) }
        let ramp: [SIMD4<Float>] = (0..<(dw * dh)).map { i in let v = Float(linear(i % dw)); return SIMD4(v, v, v, 1) }
        if let plain = try? probe.codes8(pixels: ramp, width: dw, height: dh, dither: false),
           let dith = try? probe.codes8(pixels: ramp, width: dw, height: dh, dither: true) {
            func localError(_ codes: [UInt8], window: Int) -> (worst: Double, mean: Double) {
                var worst = 0.0, sum = 0.0, n = 0
                var x0 = 0
                while x0 + window <= dw {
                    var m = 0.0, ideal = 0.0
                    for y in 0..<dh { for x in x0..<(x0 + window) { m += Double(codes[y * dw + x]); ideal += codeOf(linear(x)) } }
                    let e = (m - ideal) / Double(window * dh)
                    worst = max(worst, abs(e)); sum += e; n += 1; x0 += window
                }
                return (worst, sum / Double(n))
            }
            let p = localError(plain, window: 4), d = localError(dith, window: 4)
            var maxDev = 0.0
            for y in 0..<dh { for x in 0..<dw { maxDev = max(maxDev, abs(Double(dith[y * dw + x]) - codeOf(linear(x)))) } }
            check("E-DIT dithered, the local error over 4 pixels by 16 rows is under 0.2 code and under half the plain staircase's (\(String(format: "%.2f", d.worst)) vs \(String(format: "%.2f", p.worst)))",
                  d.worst < 0.2 && d.worst < 0.5 * p.worst, "\(d.worst) vs \(p.worst)")
            check("E-DIT the dither is unbiased (mean error under 0.02 code) and never moves a pixel more than 1.5 codes", abs(d.mean) < 0.02 && maxDev < 1.5, "mean \(d.mean), max \(maxDev)")
            check("E-DIT it does not move the average level of a smooth ramp away from the plain render's", abs(d.mean - p.mean) < 0.05)
        } else {
            check("E-DIT the ramp rendered", false)
        }
        // black, white and mid grey: black and white stay exactly, mid grey stays within a code
        let edge: [SIMD4<Float>] = (0..<64).map { i in i < 21 ? SIMD4(0, 0, 0, 1) : (i < 42 ? SIMD4(1, 1, 1, 1) : SIMD4(0.2158, 0.2158, 0.2158, 1)) }
        if let e = try? probe.codes8(pixels: edge, width: 64, height: 1, dither: true) {
            check("E-DIT black stays 0, white stays 255, mid grey (sRGB code 128) stays within a code",
                  e[0..<21].allSatisfy { $0 == 0 } && e[21..<42].allSatisfy { $0 == 255 } && e[42..<64].allSatisfy { abs(Int($0) - 128) <= 1 },
                  "\(Array(e[0..<4])) \(Array(e[21..<25])) \(Array(e[42..<48]))")
        }
        let a = try? probe.codes8(pixels: ramp, width: dw, height: dh, dither: true)
        let b = try? probe.codes8(pixels: ramp, width: dw, height: dh, dither: true)
        check("E-DIT the same picture dithers the same way every time", a != nil && a == b)
    } else {
        check("E-DIT the segment probe could not start", false)
    }
}


// E-SEG-zones the zone exposure's base is kept between slider moves: only the gain pass re-runs, and the picture is the one without the cache
do {
    if let probe = try? SegmentProbe() {
        func zs(_ shadows: Double, _ highlights: Double = 0) -> [StackEntry] {
            [StackEntry(operation: "zones", params: ["shadows": .number(shadows), "highlights": .number(highlights), "scale": .number(0.1)]),
             StackEntry(operation: "display", params: ["contrast": .number(0), "exposure": .number(0.5)])]
        }
        func gap(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            var w = 0.0
            for (x, y) in zip(a, b) { for k in 0..<3 { w = max(w, abs(Double(x[k]) - Double(y[k])) / max(1, Double(abs(y[k])))) } }
            return w
        }
        let r = { (s: [StackEntry], cached: Bool) in (try? probe.render(stack: s, pixels: detailPx, width: detailW, height: detailH, cached: cached)) ?? [] }
        let first = r(zs(1.0), true)
        check("E-SEG-zones the first render through the cache (base and result stored) equals the uncached one", gap(first, r(zs(1.0), false)) < 4e-3 && probe.entries == 2, "entries \(probe.entries), gap \(gap(first, r(zs(1.0), false)))")
        let hits0 = probe.hits
        let moved = r(zs(1.6, -0.5), true)
        check("E-SEG-zones moving the sliders reuses the base (one new entry, the result; one hit) and matches the uncached render",
              probe.entries == 3 && probe.hits == hits0 + 1 && gap(moved, r(zs(1.6, -0.5), false)) < 4e-3 && gap(moved, first) > 0.01,
              "entries \(probe.entries), hits \(probe.hits - hits0), gap \(gap(moved, r(zs(1.6, -0.5), false)))")
    } else {
        check("E-SEG-zones the segment probe could not start", false)
    }
}

// E-FU fusion: 50 random stacks of 2 to 6 per-pixel modules (their golden settings, some at partial opacity so a run is cut in two, a few with
// the display transform), rendered fused (one pass per run) and unfused (one pass per module): the same picture within 1/255 encoded and
// 2e-4 unclamped, and the fused run really is one pass (a stack of n fusable modules makes one op list)
do {
    let pool = CIEngineProbe.goldenCases().filter { CIEngineProbe.fusableOperations.contains($0.operation) }.map { $0.stack[0] }
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
    var worstEnc = 0.0, worstLin = 0.0, cases = 0, moved = 0
    for _ in 0..<50 {
        var chosen = pool
        for i in stride(from: chosen.count - 1, to: 0, by: -1) { chosen.swapAt(i, next() % (i + 1)) }
        let count = 2 + next() % 5
        chosen = Array(chosen.prefix(count))
        // some entries run at partial opacity: they are not fused, so they cut the run
        chosen = chosen.map { e in
            next() % 5 == 0 ? StackEntry(operation: e.operation, params: e.params, blend: ["opacity": .number(60)]) : e
        }
        let fusedOut = (try? CIEngineProbe.renderSized(stack: chosen, pixels: detailPx, width: detailW, height: detailH, fuse: true).pixels) ?? []
        let plainOut = (try? CIEngineProbe.renderSized(stack: chosen, pixels: detailPx, width: detailW, height: detailH, fuse: false).pixels) ?? []
        guard fusedOut.count == plainOut.count, !fusedOut.isEmpty else { worstEnc = .infinity; continue }
        cases += 1
        let want = plainOut.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }
        worstEnc = max(worstEnc, worst(fusedOut, want))
        worstLin = max(worstLin, worstLinear(fusedOut, want))
        if worstLinear(plainOut, detailPx.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }) > 0.02 { moved += 1 }
    }
    check("E-FU \(cases) random stacks of per-pixel modules: fused equals unfused within 1/255 encoded and 2e-4 linear", cases == 50 && worstEnc < tol && worstLin < 2e-4, "encoded \(worstEnc), linear \(worstLin)")
    check("E-FU the random stacks change the picture (a pass-through would fail): \(moved) of 50", moved >= 40, "\(moved)")
    check("E-FU a run is one op list: white balance, exposure, colour balance, tone curve and display make five ops, one pass",
          CIEngineProbe.fusedRunLengths([StackEntry(operation: "display", params: [:]), StackEntry(operation: "tonecurve", params: [:]),
                                         StackEntry(operation: "colorbalancergb", params: ["contrast": .number(0.2)]),
                                         StackEntry(operation: "exposure", params: ["exposure": .number(0.3)]),
                                         StackEntry(operation: "temperature", params: ["red": .number(1.2)])]) == [5])
    check("E-FU a neighbourhood module cuts the run in two",
          CIEngineProbe.fusedRunLengths([StackEntry(operation: "exposure", params: ["exposure": .number(0.3)]),
                                         StackEntry(operation: "sharpen", params: [:]),
                                         StackEntry(operation: "display", params: [:]),
                                         StackEntry(operation: "tonecurve", params: [:])]) == [1, 2])
}

// E-HR highlight reconstruction on the GPU against HighlightRebuild: the oracle's own A2 and A3 pictures, a patch that touches the picture's corner
// (the windows run off it: zero padding), seams, and strength
do {
    let n = 41
    func field(_ f: SIMD3<Double>, patch: [SIMD3<Double>: ClosedRange<Int>] = [:]) -> [SIMD3<Double>] { [SIMD3<Double>](repeating: f, count: n * n) }
    func withPatch(_ f: SIMD3<Double>, value: SIMD3<Double>, x: ClosedRange<Int>, y: ClosedRange<Int>) -> [SIMD3<Double>] {
        var img = field(f)
        for yy in y { for xx in x { img[yy * n + xx] = value } }
        return img
    }
    let cases: [(String, [SIMD3<Double>])] = [
        ("clipped patch on a warm field (A2)", withPatch(SIMD3(0.7, 0.4, 0.25), value: SIMD3(repeating: 1), x: 12...28, y: 12...28)),
        ("clipped patch on dark branches (A2)", withPatch(SIMD3(repeating: 0.05), value: SIMD3(repeating: 1), x: 12...28, y: 12...28)),
        ("blown red in a warm field (A3)", withPatch(SIMD3(0.7, 0.4, 0.25), value: SIMD3(1.0, 0.9, 0.5), x: 19...21, y: 19...21)),
        ("a patch touching the corner (windows run off the picture: the nearest edge pixel is read)", withPatch(SIMD3(0.7, 0.4, 0.25), value: SIMD3(repeating: 1), x: 0...8, y: 0...8)),
        ("a patch touching the far edge", withPatch(SIMD3(0.6, 0.5, 0.3), value: SIMD3(1.0, 1.0, 0.8), x: 33...40, y: 15...25)),
    ]
    var allOK = true
    for (label, img) in cases {
        let px = img.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        let want = HighlightRebuild.apply(img, width: n, height: n, clip: 1, strength: 1)
        let stack = [StackEntry(operation: "highlights", params: ["clip": .number(1), "strength": .number(1)])]
        let got = (try? CIEngineProbe.renderSized(stack: stack, pixels: px, width: n, height: n).pixels) ?? []
        let e = worstLinear(got, want)
        let changed = worstLinear(px, want) > 0.05
        // the clipped patch among dark branches is already neutral white: the rebuild has nothing to change, and the GPU must agree on that
        let ok = got.count == n * n && e < 2e-4 && (changed || label.contains("dark branches"))
        allOK = allOK && ok
        check("E-HR \(label): the GPU matches the oracle unclamped within 2e-4 (and the oracle changes the picture)", ok, "\(e), changed \(changed)")
    }
    // seams: a region renders what the full frame has there (the windows reach 16 px)
    let seamImg = cases[3].1
    let seamPx = seamImg.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
    let seamStack = [StackEntry(operation: "highlights", params: ["clip": .number(1), "strength": .number(1)])]
    if let full = try? CIEngineProbe.renderSized(stack: seamStack, pixels: seamPx, width: n, height: n).pixels {
        var worstSeam = 0.0
        for reg in [(x: 3, y: 2, w: 20, h: 18), (x: 0, y: 0, w: 15, h: 15), (x: 25, y: 20, w: 16, h: 21)] {
            guard let part = try? CIEngineProbe.renderRegion(stack: seamStack, pixels: seamPx, width: n, height: n, region: reg), part.count == reg.w * reg.h else { worstSeam = .infinity; continue }
            for yy in 0..<reg.h { for xx in 0..<reg.w {
                let a = part[yy * reg.w + xx], b = full[(reg.y + yy) * n + reg.x + xx]
                for c in 0..<3 { worstSeam = max(worstSeam, abs(Double(a[c]) - Double(b[c]))) }
            } }
        }
        check("E-HR-seam regions render the same as the full frame (the 16 px windows cross the tile edge)", worstSeam < 1e-6, "\(worstSeam)")
    }
    let src = cases[0].1.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
    let off = (try? CIEngineProbe.renderSized(stack: [StackEntry(operation: "highlights", params: ["strength": .number(0)])], pixels: src, width: n, height: n).pixels) ?? []
    check("E-HR strength 0 returns the picture untouched", off == src)
    let half = (try? CIEngineProbe.renderSized(stack: [StackEntry(operation: "highlights", params: ["clip": .number(1), "strength": .number(0.5)])], pixels: src, width: n, height: n).pixels) ?? []
    let wantHalf = HighlightRebuild.apply(cases[0].1, width: n, height: n, clip: 1, strength: 0.5)
    check("E-HR strength 0.5 is halfway between the picture and the rebuild", worstLinear(half, wantHalf) < 2e-4, "\(worstLinear(half, wantHalf))")
    check("E-HR the highlight module is on the scene side of the display transform", !CIEngineProbe.displayReferredOperations.contains("highlights"))
}









// E-DEF the stack a session render runs: the modules that are on by default join it, a module's own entry wins, and the starting values sit
// under what the user edited. The model sends only edited modules, and without this the display transform never ran in the app.
do {
    let empty = CIEngineProbe.withDefaults([])
    let ops = Set(empty.map(\.operation))
    check("E-DEF an empty stack gains the modules that are on by default (white balance and the display transform), and no others",
          ops == ["temperature", "display"], "\(ops.sorted())")
    check("E-DEF the display transform starts with its +0.5 EV lift", empty.first { $0.operation == "display" }?.params["exposure"]?.double == 0.5)
    check("E-DEF the empty stack wants the scene-linear decode, as the default is scene-referred", CIEngineProbe.wantsSceneLinear(empty))
    let off = CIEngineProbe.withDefaults([StackEntry(operation: "display", enabled: false)])
    check("E-DEF a stack that switches the display transform off keeps it off (no second entry) and keeps the decoder's own look",
          off.filter { $0.operation == "display" }.count == 1 && off.first { $0.operation == "display" }?.enabled == false && !CIEngineProbe.wantsSceneLinear(off))
    let edited = CIEngineProbe.withDefaults([StackEntry(operation: "display", params: ["contrast": .number(30)])])
    let d = edited.first { $0.operation == "display" }
    check("E-DEF editing only the contrast keeps the +0.5 EV lift under it", d?.params["contrast"]?.double == 30 && d?.params["exposure"]?.double == 0.5)
    let own = CIEngineProbe.withDefaults([StackEntry(operation: "display", params: ["exposure": .number(-1)])])
    check("E-DEF an edited exposure bias wins over the start value", own.first { $0.operation == "display" }?.params["exposure"]?.double == -1)
    check("E-DEF other modules are untouched, and the probe's own path (CIEngine.process) still treats an empty stack as the identity",
          CIEngineProbe.withDefaults([StackEntry(operation: "sharpen")]).filter { $0.operation == "sharpen" }.count == 1 && worst(run([]), scene) < 1e-6)
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

// E-GF graduated filter through the engine: against the oracle, tile seams, the zero shortcut
do {
    let params: [String: ParamValue] = ["exposure": .number(-1.3), "position": .number(0.45), "angle": .number(-70), "feather": .number(0.4)]
    let stack = [StackEntry(operation: "graduated", params: params)]
    let spec = GraduatedFilter.spec(position: 0.45, angle: -70, feather: 0.4)
    let want = GraduatedFilter.apply(detailImg, width: detailW, height: detailH, ev: -1.3, spec: spec)
    let got = runDetail(stack)
    check("E-GF graduated filter matches the oracle within 1/255 and unclamped within 2e-4", worst(got, want) < tol && worstLinear(got, want) < 2e-4,
          "encoded \(worst(got, want)), linear \(worstLinear(got, want))")
    check("E-GF the oracle really changes the fixture (a no-op GPU path would fail)", worstLinear(detailPx, want) > 0.05)
    let seams = detailSeams(stack, oracle: want)
    check("E-GF-seam graduated filter renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    check("E-GF-zero exposure 0 returns the input untouched", runDetail([StackEntry(operation: "graduated", params: ["exposure": .number(0)])]) == detailPx)
}

// E-VG vignette through the engine: against the oracle (radial light turned inside out), tile seams and the zero shortcut
do {
    let stack = [StackEntry(operation: "vignette", params: ["strength": .number(1.2), "scale": .number(0.9)])]
    let want = Vignette.apply(detailImg, width: detailW, height: detailH, strength: 1.2, scale: 0.9)
    let got = runDetail(stack)
    check("E-VG vignette matches the oracle within 1/255 and unclamped within 2e-4", worst(got, want) < tol && worstLinear(got, want) < 2e-4,
          "encoded \(worst(got, want)), linear \(worstLinear(got, want))")
    check("E-VG the oracle really changes the fixture (a no-op GPU path would fail)", worstLinear(detailPx, want) > 0.05)
    let seams = detailSeams(stack, oracle: want)
    check("E-VG-seam vignette renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    check("E-VG-zero strength 0 returns the input untouched", runDetail([StackEntry(operation: "vignette", params: ["strength": .number(0)])]) == detailPx)
}

// E-SHD shadows and highlights through the engine: the zone exposure path with the slider mapping, against Shadhi in DarkroomCore, across tile
// seams, and the identity at zero
do {
    let stack = [StackEntry(operation: "shadhi", params: ["shadows": .number(80), "highlights": .number(-60)])]
    let want = Shadhi.apply(detailImg, width: detailW, height: detailH, shadows: 80, highlights: -60)
    let got = runDetail(stack)
    check("E-SHD shadows and highlights matches the oracle within 1/255 and unclamped within 2e-4", worst(got, want) < tol && worstLinear(got, want) < 2e-4,
          "encoded \(worst(got, want)), linear \(worstLinear(got, want))")
    check("E-SHD the oracle really changes the fixture (a no-op GPU path would fail)", worstLinear(detailPx, want) > 0.05, "\(worstLinear(detailPx, want))")
    let seams = detailSeams(stack, oracle: want)
    check("E-SHD-seam shadows and highlights renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    check("E-SHD-zero both sliders at 0 returns the input untouched", runDetail([StackEntry(operation: "shadhi", params: [:])]) == detailPx)
}

// E-BLM bloom through the engine: the bright pass, three box means and the add on the GPU against Bloom in DarkroomCore, across tile seams,
// and the identity at strength 0. Size 12 is a radius of 4 per pass at render scale 1.
do {
    let stack = [StackEntry(operation: "bloom", params: ["strength": .number(0.6), "size": .number(12)])]
    let want = Bloom.apply(detailImg, width: detailW, height: detailH, strength: 0.6, radius: Bloom.radius(size: 12))
    let got = runDetail(stack)
    check("E-BLM bloom matches the oracle within 1/255 and unclamped within 2e-4", worst(got, want) < tol && worstLinear(got, want) < 2e-4,
          "encoded \(worst(got, want)), linear \(worstLinear(got, want))")
    check("E-BLM the oracle really changes the fixture (a no-op GPU path would fail)", worstLinear(detailPx, want) > 0.01, "\(worstLinear(detailPx, want))")
    let seams = detailSeams(stack, oracle: want)
    check("E-BLM-seam bloom renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
    check("E-BLM-zero strength 0 returns the input untouched", runDetail([StackEntry(operation: "bloom", params: ["strength": .number(0)])]) == detailPx)
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

// E-CZ colour zones: the fused per-pixel kernel through the engine against ColorZones in DarkroomCore
do {
    var czU = [Double](repeating: 0, count: 24)
    for k in 0..<24 { czU[k] = sin(Double(k) * 1.7 + 0.3) * 0.9 }
    var czParams: [String: ParamValue] = [:]
    for (kind, name) in ["hue", "sat", "light"].enumerated() {
        for (b, band) in ColorZones.bandNames.enumerated() { czParams["\(band)_\(name)"] = .number(czU[kind * 8 + b]) }
    }
    let czEngine = run([StackEntry(operation: "colorzones", params: czParams)])
    let czOracle = scene.map { ColorZones.apply($0, u: czU) }
    let eCZ = worst(czEngine, czOracle)
    check("E-CZ colour zones match the oracle within 1/255", eCZ < tol, "\(eCZ)")
    check("E-CZ zero sliders change nothing (within float rounding)", worstLinear(run([StackEntry(operation: "colorzones", params: [:])]), scene) < 1e-4)
}

// E-SCV saturation by lightness: the fused per-pixel kernel through the engine against SatCurve in DarkroomCore
do {
    let scvU: [Double] = [0.8, -0.6, 0.5]
    let scvEngine = run([StackEntry(operation: "satcurvergb", params: ["shadows": .number(0.8), "mids": .number(-0.6), "highlights": .number(0.5)])])
    let scvOracle = scene.map { SatCurve.apply($0, u: scvU) }
    let eSCV = worst(scvEngine, scvOracle)
    check("E-SCV saturation by lightness matches the oracle within 1/255 and unclamped within 1e-4", eSCV < tol && worstLinear(scvEngine, scvOracle) < 1e-4,
          "encoded \(eSCV), linear \(worstLinear(scvEngine, scvOracle))")
    check("E-SCV zero sliders change nothing (within float rounding)", worstLinear(run([StackEntry(operation: "satcurvergb", params: [:])]), scene) < 1e-4)
}

// E-LG four-way colour balance: the fused per-pixel kernel through the engine against LiftGammaGain in DarkroomCore
do {
    let lgV: [String: Double] = ["shadows_hue": 220, "shadows_sat": 0.7, "shadows_lum": 0.4, "mids_hue": 40, "mids_sat": 0.5, "mids_lum": -0.3,
                                 "highlights_hue": 80, "highlights_sat": 0.6, "highlights_lum": 0.5]
    let lgT = LiftGammaGain.terms(lgV)
    let lgEngine = run([StackEntry(operation: "colorbalance", params: lgV.mapValues { .number($0) })])
    let lgOracle = scene.map { LiftGammaGain.apply($0, slope: lgT.slope, offset: lgT.offset, power: lgT.power) }
    let eLG = worst(lgEngine, lgOracle)
    check("E-LG four-way colour balance matches the oracle within 1/255 and unclamped within 1e-4", eLG < tol && worstLinear(lgEngine, lgOracle) < 1e-4,
          "encoded \(eLG), linear \(worstLinear(lgEngine, lgOracle))")
    check("E-LG zero settings change nothing (within float rounding)", worstLinear(run([StackEntry(operation: "colorbalance", params: [:])]), scene) < 1e-4)
}

// E-RC rgb curve: five nodes through the engine against ToneCurve in DarkroomCore (the tone curve's oracle, on every channel)
do {
    let rcYs = [0.05, 0.3, 0.45, 0.8, 0.95]
    let rcEngine = run([StackEntry(operation: "rgbcurve", params: ["y0": .number(0.05), "y1": .number(0.3), "y2": .number(0.45), "y3": .number(0.8), "y4": .number(0.95)])])
    let rcOracle = scene.map { ToneCurve.apply($0, ys: rcYs) }
    check("E-RC rgb curve matches the oracle within 1/255", worst(rcEngine, rcOracle) < tol, "\(worst(rcEngine, rcOracle))")
    check("E-RC the default curve changes nothing (unclamped within 1e-3)", worstLinear(run([StackEntry(operation: "rgbcurve", params: [:])]), scene) < 1e-3)
}

// E-CCT colour contrast and E-CCR colour correction: the fused per-pixel kernels through the engine against their oracles
do {
    let ctEngine = run([StackEntry(operation: "colorcontrast", params: ["saturation": .number(0.6)])])
    let ctOracle = scene.map { ColorContrast.apply($0, saturation: 0.6) }
    check("E-CCT colour contrast matches the oracle within 1/255 and unclamped within 1e-4", worst(ctEngine, ctOracle) < tol && worstLinear(ctEngine, ctOracle) < 1e-4,
          "encoded \(worst(ctEngine, ctOracle)), linear \(worstLinear(ctEngine, ctOracle))")
    let crEngine = run([StackEntry(operation: "colorcorrection", params: ["brightness": .number(0.3), "contrast": .number(0.5)])])
    let crOracle = scene.map { ColorCorrection.apply($0, brightness: 0.3, contrast: 0.5) }
    check("E-CCR colour correction matches the oracle within 1/255 and unclamped within 1e-4", worst(crEngine, crOracle) < tol && worstLinear(crEngine, crOracle) < 1e-4,
          "encoded \(worst(crEngine, crOracle)), linear \(worstLinear(crEngine, crOracle))")
    check("E-CCT E-CCR zero settings change nothing (within float rounding)",
          worstLinear(run([StackEntry(operation: "colorcontrast", params: [:]), StackEntry(operation: "colorcorrection", params: [:])]), scene) < 1e-4)
}

// E-BSC base curve, E-DTH posterize, E-COZ colorize: the fused per-pixel kernels through the engine against their oracles
do {
    let bsEngine = run([StackEntry(operation: "basecurve", params: ["gamma": .number(1.7)])])
    let bsOracle = scene.map { BaseCurve.apply($0, gamma: 1.7) }
    check("E-BSC base curve matches the oracle within 1/255", worst(bsEngine, bsOracle) < tol, "\(worst(bsEngine, bsOracle))")
    let dtEngine = run([StackEntry(operation: "dither", params: ["levels": .number(12)])])
    let dtOracle = scene.map { Posterize.apply($0, levels: 12) }
    check("E-DTH posterize matches the oracle within 1/255", worst(dtEngine, dtOracle) < tol, "\(worst(dtEngine, dtOracle))")
    let czEngine2 = run([StackEntry(operation: "colorize", params: ["strength": .number(0.7), "hue": .number(0.35)])])
    let czOracle2 = scene.map { Colorize.apply($0, strength: 0.7, hue: 0.35) }
    check("E-COZ colorize matches the oracle within 1/255 and unclamped within 1e-4", worst(czEngine2, czOracle2) < tol && worstLinear(czEngine2, czOracle2) < 1e-4,
          "encoded \(worst(czEngine2, czOracle2)), linear \(worstLinear(czEngine2, czOracle2))")
    check("E-BSC E-COZ zero settings change nothing (gamma 1, strength 0; within 1/255)",
          worst(run([StackEntry(operation: "basecurve", params: [:]), StackEntry(operation: "colorize", params: [:])]), scene.map { BaseCurve.apply($0, gamma: 1) }) < tol)
}

// E-BLR blur, E-LPF low-pass, E-SOF soften, E-MSC censorize: the GPU paths against Blur, Soften and Mosaic in DarkroomCore, across tile seams
do {
    let blurWant = Blur.apply(detailImg, width: detailW, height: detailH, radius: Blur.radius(px: 12))
    for (op, tag) in [("blurs", "E-BLR"), ("lowpass", "E-LPF")] {
        let stack = [StackEntry(operation: op, params: ["radius": .number(12)])]
        let got = runDetail(stack)
        check("\(tag) \(op) matches the oracle within 1/255 and unclamped within 2e-4", worst(got, blurWant) < tol && worstLinear(got, blurWant) < 2e-4,
              "encoded \(worst(got, blurWant)), linear \(worstLinear(got, blurWant))")
        check("\(tag) the oracle really changes the fixture", worstLinear(detailPx, blurWant) > 0.01, "\(worstLinear(detailPx, blurWant))")
        let seams = detailSeams(stack, oracle: blurWant)
        check("\(tag)-seam \(op) renders the same in a region as in the full frame", seams.ok, "seam \(seams.seam), full vs oracle \(seams.fullVsOracle)")
        check("\(tag)-zero radius 0 returns the input untouched", runDetail([StackEntry(operation: op, params: [:])]) == detailPx)
    }
    let softStack = [StackEntry(operation: "soften", params: ["strength": .number(0.7), "radius": .number(9)])]
    let softWant = Soften.apply(detailImg, width: detailW, height: detailH, strength: 0.7, radius: Blur.radius(px: 9))
    let softGot = runDetail(softStack)
    check("E-SOF soften matches the oracle within 1/255 and unclamped within 2e-4", worst(softGot, softWant) < tol && worstLinear(softGot, softWant) < 2e-4,
          "encoded \(worst(softGot, softWant)), linear \(worstLinear(softGot, softWant))")
    check("E-SOF the oracle really changes the fixture", worstLinear(detailPx, softWant) > 0.01, "\(worstLinear(detailPx, softWant))")
    let softSeams = detailSeams(softStack, oracle: softWant)
    check("E-SOF-seam soften renders the same in a region as in the full frame", softSeams.ok, "seam \(softSeams.seam), full vs oracle \(softSeams.fullVsOracle)")
    check("E-SOF-zero strength 0 returns the input untouched", runDetail([StackEntry(operation: "soften", params: [:])]) == detailPx)

    let mosStack = [StackEntry(operation: "censorize", params: ["pixelation": .number(7)])]
    let mosWant = Mosaic.apply(detailImg, width: detailW, height: detailH, block: 7)
    let mosGot = runDetail(mosStack)
    check("E-MSC censorize matches the oracle within 1/255 and unclamped within 2e-4", worst(mosGot, mosWant) < tol && worstLinear(mosGot, mosWant) < 2e-4,
          "encoded \(worst(mosGot, mosWant)), linear \(worstLinear(mosGot, mosWant))")
    check("E-MSC the oracle really changes the fixture", worstLinear(detailPx, mosWant) > 0.01, "\(worstLinear(detailPx, mosWant))")
    let mosSeams = detailSeams(mosStack, oracle: mosWant)
    check("E-MSC-seam censorize renders the same in a region as in the full frame", mosSeams.ok, "seam \(mosSeams.seam), full vs oracle \(mosSeams.fullVsOracle)")
    check("E-MSC-zero pixelation 1 returns the input untouched", runDetail([StackEntry(operation: "censorize", params: [:])]) == detailPx)
}

// E-SOL solarize, E-NEG negadoctor, E-LLT low light, E-CMX channel mixer with adaptation: the fused kernels through the engine against their oracles
do {
    let solEngine = run([StackEntry(operation: "solarize", params: ["threshold": .number(0.45), "strength": .number(0.8)])])
    let solOracle = scene.map { Solarize.apply($0, threshold: 0.45, strength: 0.8) }
    check("E-SOL solarize matches the oracle within 1/255", worst(solEngine, solOracle) < tol, "\(worst(solEngine, solOracle))")
    let negEngine = run([StackEntry(operation: "negadoctor", params: ["dmin_r": .number(0.8), "dmin_g": .number(0.5), "dmin_b": .number(0.35),
                                                                      "gamma": .number(1.6), "exposure": .number(0.2), "black": .number(0.01)])])
    let negOracle = scene.map { NegativeFilm.apply($0, dmin: SIMD3(0.8, 0.5, 0.35), gamma: 1.6, exposure: 0.2, black: 0.01) }
    check("E-NEG negadoctor matches the oracle within 1/255", worst(negEngine, negOracle) < tol, "\(worst(negEngine, negOracle))")
    let llEngine = run([StackEntry(operation: "lowlight", params: ["strength": .number(0.8)])])
    let llOracle = scene.map { LowLight.apply($0, strength: 0.8) }
    check("E-LLT low light matches the oracle within 1/255 and unclamped within 1e-4", worst(llEngine, llOracle) < tol && worstLinear(llEngine, llOracle) < 1e-4,
          "encoded \(worst(llEngine, llOracle)), linear \(worstLinear(llEngine, llOracle))")
    let cmRows: [[Double]] = [[1, 0.1, 0], [0, 1, 0.05], [0.02, 0, 1]]
    var cmParams: [String: ParamValue] = ["temperature": .number(3200), "strength": .number(0.9)]
    let cmNames = ["red_r", "red_g", "red_b", "green_r", "green_g", "green_b", "blue_r", "blue_g", "blue_b"]
    for (i, n) in cmNames.enumerated() { cmParams[n] = .number(cmRows[i / 3][i % 3]) }
    let cmM = ChannelMixerRGB.matrix(kelvin: 3200, strength: 0.9, rows: cmRows)
    let cmEngine = run([StackEntry(operation: "channelmixerrgb", params: cmParams)])
    let cmOracle = scene.map { ChannelMixer.apply($0, rows: cmM) }
    check("E-CMX channel mixer with adaptation matches the oracle within 1/255 and unclamped within 1e-4", worst(cmEngine, cmOracle) < tol && worstLinear(cmEngine, cmOracle) < 1e-4,
          "encoded \(worst(cmEngine, cmOracle)), linear \(worstLinear(cmEngine, cmOracle))")
    check("E-CMX zero strength and identity rows change nothing", worstLinear(run([StackEntry(operation: "channelmixerrgb", params: [:])]), scene) < 1e-4)
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
