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

func runDetail(_ stack: [StackEntry]) -> [SIMD4<Float>] {
    do { return try CIEngineProbe.render(stack: stack, pixels: detailPx, width: detailW, height: detailH) } catch {
        print("FAIL  probe threw: \(error)")
        failures += 1
        return []
    }
}

/// Tile seams for a detail module: three regions rendered alone must equal the same pixels of the full frame, and
/// the full frame must be the oracle's (so two blank renders cannot match each other).
func detailSeams(_ stack: [StackEntry], oracle: [SIMD3<Double>]) -> (seam: Double, fullVsOracle: Double, ok: Bool) {
    let full = runDetail(stack)
    let fullErr = worstLinear(full, oracle)
    var seam = 0.0, ok = full.count == detailW * detailH && fullErr < 2e-4
    for reg in [(x: 17, y: 9, w: 20, h: 18), (x: 0, y: 0, w: 15, h: 15), (x: 30, y: 25, w: 18, h: 15)] {
        guard let part = try? CIEngineProbe.renderRegion(stack: stack, pixels: detailPx, width: detailW, height: detailH, region: reg),
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

// E3 display transform: working sRGB -> Rec.2020 -> ToneMap per channel -> DisplayTransform, at two contrasts
for contrast in [0.0, 40.0, -60.0] {
    let tone = ToneMap(contrast: contrast)
    let oracle = scene.map { p -> SIMD3<Double> in
        let r = ColorSpaces.srgbToRec2020.apply(p)
        return DisplayTransform.apply(SIMD3(tone.apply(r.x), tone.apply(r.y), tone.apply(r.z)))
    }
    let e3 = worst(run([StackEntry(operation: "display", params: ["contrast": .number(contrast)])]), oracle, oracleEncoded: true)
    check("E3 display transform at contrast \(Int(contrast)) matches the oracle within 1/255", e3 < tol, "\(e3)")
}

// E4 a chain in pipeline order regardless of stack order: white balance, exposure, then display
let chain = [StackEntry(operation: "display", params: ["contrast": .number(20)]),
             StackEntry(operation: "exposure", params: ["exposure": .number(-0.7)]),
             wbStack[0]]
let tone20 = ToneMap(contrast: 20)
let chainOracle = scene.map { p -> SIMD3<Double> in
    let lit = p * coeff * Exposure.gain(ev: -0.7)
    let r = ColorSpaces.srgbToRec2020.apply(lit)
    return DisplayTransform.apply(SIMD3(tone20.apply(r.x), tone20.apply(r.y), tone20.apply(r.z)))
}
let e4 = worst(run(chain), chainOracle, oracleEncoded: true)
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

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
