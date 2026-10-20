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

/// Worst channel difference after the sRGB encode, engine against oracle.
func worst(_ engine: [SIMD4<Float>], _ oracle: [SIMD3<Double>], oracleEncoded: Bool = false) -> Double {
    var w = 0.0
    for (i, o) in oracle.enumerated() where i < engine.count {
        let g = encode(SIMD3(Double(engine[i].x), Double(engine[i].y), Double(engine[i].z)))
        let d = g - (oracleEncoded ? o : encode(o))
        w = max(w, abs(d.x), abs(d.y), abs(d.z))
    }
    return engine.count == oracle.count ? w : .infinity
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

// E-TC tone curve: the S-curve through the engine (CIBridge.perPixel, tonecurveTex) against ToneCurve in DarkroomCore
let toneYs = [0, 0.15, 0.5, 0.85, 1.0]
let etc = worst(run([StackEntry(operation: "tonecurve", params: ["y0": .number(0), "y1": .number(0.15), "y2": .number(0.5),
                                                                  "y3": .number(0.85), "y4": .number(1)])]),
                scene.map { ToneCurve.apply($0, ys: toneYs) })
check("E-TC tone curve S-curve matches the oracle within 1/255", etc < tol, "\(etc)")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
