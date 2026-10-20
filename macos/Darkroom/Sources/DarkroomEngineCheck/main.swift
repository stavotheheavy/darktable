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

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
