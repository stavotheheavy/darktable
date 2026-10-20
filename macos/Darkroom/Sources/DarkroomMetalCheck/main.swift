// Metal oracle checks (checkpoint B1). Run: swift run darkroom-metal-check
// Each Metal kernel must match the DarkroomCore CPU reference within 1/255 after the display transform.
import DarkroomCore
import DarkroomMetal
import Foundation
import Metal

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  " + detail())")
    if !ok { failures += 1 }
}

let kernel: MetalExposureWB
do {
    kernel = try MetalExposureWB()
} catch {
    print("FAIL  no Metal device or kernel: \(error)")
    exit(1)
}

// a 64 by 64 scene: a warm to cool gradient with some values above 1 (HDR-ish highlights)
let n = 64
var cpuInput: [SIMD3<Double>] = []
for y in 0..<n {
    for x in 0..<n {
        let t = Double(x) / Double(n - 1)
        cpuInput.append(SIMD3(0.02 + 1.6 * t, 0.1 + 0.5 * Double(y) / Double(n - 1), 0.9 - 0.7 * t))
    }
}
let gpuInput = cpuInput.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 1) }

// one scale per channel: exposure gain times white balance, as the chain would compute it
let ev = 0.5, kelvin = 5000.0, tint = 10.0
let gain = Exposure.gain(ev: ev)
let wb = WhiteBalance.gains(kelvin: kelvin, tint: tint)
let scale = SIMD3<Float>(Float(gain * wb.x), Float(gain * wb.y), Float(gain * wb.z))

let gpuOut = kernel.run(gpuInput, scale: scale)
check("metal returns one pixel per input", gpuOut.count == gpuInput.count, "got \(gpuOut.count)")

var worstDisplay = 0.0, worstLinear = 0.0
for (i, c) in cpuInput.enumerated() where i < gpuOut.count {
    let cpuScene = c * (gain * wb)
    let gpuScene = SIMD3<Double>(Double(gpuOut[i].x), Double(gpuOut[i].y), Double(gpuOut[i].z))
    worstLinear = max(worstLinear, (cpuScene - gpuScene).max())
    let cpuDisplay = DisplayTransform.apply(cpuScene)
    let gpuDisplay = DisplayTransform.apply(gpuScene)
    let d = cpuDisplay - gpuDisplay
    worstDisplay = max(worstDisplay, Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z)))
}
check("exposure + WB on Metal matches the CPU oracle within 1/255 (display)",
      worstDisplay <= 1.0 / 255, "worst display error \(worstDisplay)")
print("      worst linear error \(worstLinear), worst display error \(worstDisplay)")
check("alpha passes through", gpuOut.allSatisfy { $0.w == 1 })

// B2 tone and display: tone per channel, then the Rec.2020 to sRGB display transform, against the CPU chain
let toneKernel: MetalToneDisplay
do {
    toneKernel = try MetalToneDisplay()
} catch {
    print("FAIL  no tone kernel: \(error)")
    exit(1)
}
let toneMap = ToneMap()
let rec = ColorSpaces.rec2020ToSRGB
let columns = [rec.apply(SIMD3(1, 0, 0)), rec.apply(SIMD3(0, 1, 0)), rec.apply(SIMD3(0, 0, 1))]
    .map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }

func checkToneDisplay(_ kernel: MetalToneDisplay, _ name: String, _ scene: [SIMD3<Double>]) {
    let input = scene.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 1) }
    let out = kernel.run(input, tone: toneMap, columns: columns)
    guard out.count == input.count else {
        check(name, false, "got \(out.count) pixels, expected \(input.count)")
        return
    }
    var worst = 0.0
    for (i, px) in input.enumerated() {
        // compare from the same Float-rounded inputs the GPU saw
        let s = SIMD3<Double>(Double(px.x), Double(px.y), Double(px.z))
        let cpu = DisplayTransform.apply(SIMD3(toneMap.apply(s.x), toneMap.apply(s.y), toneMap.apply(s.z)))
        let g = out[i]
        let d = cpu - SIMD3<Double>(Double(g.x), Double(g.y), Double(g.z))
        worst = Swift.max(worst, Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z)))
    }
    check(name, worst <= 1.0 / 255, "worst display error \(worst)")
}

// HDR colour gradient: scene values from near black to about 4 (above the SDR white)
var gradient: [SIMD3<Double>] = []
for y in 0..<n {
    for x in 0..<n {
        let t = Double(x) / Double(n - 1), v = Double(y) / Double(n - 1)
        gradient.append(SIMD3(0.001 + 4 * t, 0.02 + 1.5 * v, 0.2 + 2.5 * (1 - t) * v))
    }
}
checkToneDisplay(toneKernel, "B2 HDR colour gradient matches the CPU chain within 1/255", gradient)

// sRGB ramp: 256 neutral steps from black to scene white
let ramp = (0..<256).map { SIMD3(repeating: Double($0) / 255) }
checkToneDisplay(toneKernel, "B2 neutral ramp matches the CPU chain within 1/255", ramp)

// B3 sharpen: one line of 512 pixels with a sharp step and a bright spike, against Sharpen.line on the CPU
let sharpenKernel: MetalSharpen
do {
    sharpenKernel = try MetalSharpen()
} catch {
    print("FAIL  no sharpen kernel: \(error)")
    exit(1)
}
var line: [SIMD3<Double>] = []
for i in 0..<512 {
    let step = i < 200 ? 0.1 : (i < 320 ? 0.7 : 0.25)
    let spike = (i == 400) ? 3.0 : 0.0
    line.append(SIMD3(step + spike, 0.5 * step, 0.2 + 0.001 * Double(i)))
}
let lineInput = line.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 1) }
let lineRounded = lineInput.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
let sharpened = sharpenKernel.run(lineInput, amount: 0.6)
check("B3 sharpen returns one pixel per input", sharpened.count == lineInput.count, "got \(sharpened.count)")
let cpuSharp = Sharpen.line(lineRounded, amount: 0.6)
var worstSharpDisplay = 0.0
for i in 0..<min(cpuSharp.count, sharpened.count) {
    let g = sharpened[i]
    let gpu = SIMD3<Double>(Double(g.x), Double(g.y), Double(g.z))
    let d = DisplayTransform.apply(cpuSharp[i]) - DisplayTransform.apply(gpu)
    worstSharpDisplay = Swift.max(worstSharpDisplay, Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z)))
}
check("B3 sharpen on Metal matches the CPU oracle within 1/255 (display)",
      worstSharpDisplay <= 1.0 / 255, "worst display error \(worstSharpDisplay)")
print("      worst sharpen display error \(worstSharpDisplay)")

// T5 first numbers (not the full test): the Metal chain exposure, tone + display, sharpen on a 2560 by 1440
// viewport, timed from input to output over 30 runs. Excludes decode, the app, and the 24 MP frame.
do {
    let w = 2560, h = 1440
    let frame = (0..<(w * h)).map { i -> SIMD4<Float> in
        let x = Float(i % w) / Float(w), y = Float(i / w) / Float(h)
        return SIMD4(0.02 + 2.5 * x, 0.1 + 0.8 * y, 0.3 + 0.5 * (1 - x), 1)
    }
    let chain: MetalChain
    do {
        chain = try MetalChain()
    } catch {
        print("FAIL  no chain: \(error)")
        exit(1)
    }
    // one command buffer must match the three kernels run one after another
    let once = chain.run(frame, scale: SIMD3(repeating: 0.9), columns: columns, amount: 0.6)
    let stepwise = sharpenKernel.run(toneKernel.run(kernel.run(frame, scale: SIMD3(repeating: 0.9)),
                                                    tone: toneMap, columns: columns), amount: 0.6)
    var worstChain: Float = 0
    for i in 0..<min(once.count, stepwise.count) {
        let d = once[i] - stepwise[i]
        worstChain = Swift.max(worstChain, Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z)))
    }
    check("chain in one command buffer matches the stepwise kernels", once.count == stepwise.count && worstChain < 1e-6,
          "worst \(worstChain)")

    var times: [Double] = [], gpuTimes: [Double] = []
    for _ in 0..<30 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let out = chain.run(frame, scale: SIMD3(repeating: 0.9), columns: columns, amount: 0.6)
        let t1 = DispatchTime.now().uptimeNanoseconds
        precondition(out.count == frame.count)
        times.append(Double(t1 - t0) / 1_000_000)
        gpuTimes.append(chain.lastGPUMilliseconds)
    }
    times.sort()
    gpuTimes.sort()
    let p50 = times[times.count / 2], p95 = times[Int(Double(times.count) * 0.95) - 1]
    let g95 = gpuTimes[Int(Double(gpuTimes.count) * 0.95) - 1]
    print("      viewport 2560x1440 GPU chain in one command buffer, 30 runs: p50 \(String(format: "%.1f", p50)) ms, p95 \(String(format: "%.1f", p95)) ms, budget 16 ms")
    print("      of which GPU execution p95 \(String(format: "%.1f", g95)) ms (copies in and out excluded)")
    check("T5 viewport p95 under 16 ms (exposure, tone+display, sharpen)", p95 < 16, "p95 \(p95) ms")

    // texture path: the source is already on the GPU and the result stays in a texture, as the app would use it
    guard let source = chain.makeSource(frame) else {
        print("FAIL  texture path: no source buffer")
        exit(1)
    }
    var texTimes: [Double] = [], texGPU: [Double] = []
    var lastTexture: MTLTexture?
    for _ in 0..<30 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let tex = chain.renderToTexture(source: source, width: w, height: h, scale: SIMD3(repeating: 0.9),
                                        columns: columns, amount: 0.6)
        let t1 = DispatchTime.now().uptimeNanoseconds
        texTimes.append(Double(t1 - t0) / 1_000_000)
        texGPU.append(chain.lastGPUMilliseconds)
        lastTexture = tex
    }
    guard let tex = lastTexture else {
        print("FAIL  texture path: no texture rendered")
        exit(1)
    }
    // read the texture back once, outside the timing, and compare with the buffer path
    var texPixels = [SIMD4<Float>](repeating: .zero, count: w * h)
    texPixels.withUnsafeMutableBytes { raw in
        tex.getBytes(raw.baseAddress!, bytesPerRow: w * MemoryLayout<SIMD4<Float>>.stride,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    }
    var worstTex: Float = 0
    for i in 0..<min(texPixels.count, once.count) {
        let d = texPixels[i] - once[i]
        worstTex = Swift.max(worstTex, Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z)))
    }
    check("texture output matches the buffer path", worstTex < 1e-6, "worst \(worstTex)")
    texTimes.sort()
    texGPU.sort()
    let tp50 = texTimes[texTimes.count / 2], tp95 = texTimes[Int(Double(texTimes.count) * 0.95) - 1]
    let tg95 = texGPU[Int(Double(texGPU.count) * 0.95) - 1]
    print("      texture path (source on GPU, result in texture), 30 runs: p50 \(String(format: "%.1f", tp50)) ms, p95 \(String(format: "%.1f", tp95)) ms, GPU p95 \(String(format: "%.1f", tg95)) ms")
    check("T5 texture path p95 under 16 ms (no host copies)", tp95 < 16, "p95 \(tp95) ms")
}

// levels (rgblevels): black 0.1, grey 0.4, white 0.9 on a 64 by 64 ramp from 0 to 1.5, on Metal against Levels.apply
do {
    let black = 0.1, grey = 0.4, white = 0.9
    let hi = max(white, black + 0.01)
    let mid = min(max(grey, 0.01), 0.99)
    let gamma = log(0.5) / log(mid)
    let levelsRamp = (0..<(n * n)).map { i -> SIMD4<Float> in
        let v = 1.5 * Float(i) / Float(n * n - 1)
        return SIMD4(v, v, v, 1)
    }
    let levelsOut = try MetalPerPixel.run(source: MetalLevels.source, function: "levelsBuf", pixels: levelsRamp,
                                          uniforms: [Float(black), Float(hi), Float(gamma)])
    func shown(_ v: Double) -> Double { min(max(Transfer.linearToSRGB(v), 0), 1) }
    var worstLevels = 0.0
    for (px, g) in zip(levelsRamp, levelsOut) {
        let cpu = Levels.apply(Double(px.x), black: black, grey: grey, white: white)
        worstLevels = max(worstLevels, abs(shown(cpu) - shown(Double(g.x))))
    }
    // NaN fails `max`, so finiteness is its own check
    let levelsFinite = levelsOut.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }
    check("levels on Metal outputs are all finite", levelsFinite)
    check("levels on Metal matches Levels.apply within 1/255 (encoded)",
          levelsOut.count == levelsRamp.count && worstLevels <= 1.0 / 255, "worst \(worstLevels), count \(levelsOut.count)")
} catch {
    check("levels on Metal ran", false, "\(error)")
}

// LV-M2 past white: 4096 pixels whose channels differ and span 0...3.0 linear, compared unclamped against Levels.apply
do {
    let black = 0.1, grey = 0.4, white = 0.9
    let hi = max(white, black + 0.01)
    let mid = min(max(grey, 0.01), 0.99)
    let gamma = log(0.5) / log(mid)
    let pastRamp = (0..<4096).map { i -> SIMD4<Float> in
        let t = Float(i) / 4095
        return SIMD4(3.0 * t, 3.0 * (1 - t), 3.0 * Float((i * 37) % 4096) / 4095, 1)
    }
    let pastOut = try MetalPerPixel.run(source: MetalLevels.source, function: "levelsBuf", pixels: pastRamp,
                                        uniforms: [Float(black), Float(hi), Float(gamma)])
    var pastFinite = pastOut.count == pastRamp.count
    var worstRel = 0.0
    for (px, g) in zip(pastRamp, pastOut) {
        let cpu = Levels.apply(SIMD3(Double(px.x), Double(px.y), Double(px.z)), black: black, grey: grey, white: white)
        let gpu = SIMD3(Double(g.x), Double(g.y), Double(g.z))
        pastFinite = pastFinite && gpu.x.isFinite && gpu.y.isFinite && gpu.z.isFinite
        for k in 0..<3 {
            worstRel = max(worstRel, abs(gpu[k] - cpu[k]) / max(1, abs(cpu[k])))
        }
    }
    check("LV-M2 past white on Metal is finite and within 1e-4 of Levels.apply (unclamped)",
          pastFinite && worstRel < 1e-4, "finite \(pastFinite), worst relative \(worstRel)")
} catch {
    check("LV-M2 past white on Metal ran", false, "\(error)")
}

// C1 tone curve: the per-pixel buffer kernel (MetalToneCurve) on a 64 by 64 ramp from 0 to 1.5, against ToneCurve
do {
    let ys = [0, 0.15, 0.5, 0.85, 1.0]
    let uniforms = ToneCurve.uniforms(xs: ToneCurve.legacyXs, ys: ys)
    let ramp = (0..<(n * n)).map { i -> SIMD4<Float> in
        let v = Float(i) / Float(n * n - 1) * 1.5
        return SIMD4(v, v, v, 1)
    }
    let out = try MetalPerPixel.run(source: MetalToneCurve.source, function: "tonecurveBuf", pixels: ramp, uniforms: uniforms)
    // compare after the sRGB encode, clamped to 0...1 on both sides
    func encodedClamp(_ p: SIMD3<Double>) -> SIMD3<Double> {
        func e(_ x: Double) -> Double { min(max(Transfer.linearToSRGB(x), 0), 1) }
        return SIMD3(e(p.x), e(p.y), e(p.z))
    }
    var worstCurve = 0.0
    for (i, px) in ramp.enumerated() where i < out.count {
        let want = ToneCurve.apply(SIMD3(Double(px.x), Double(px.y), Double(px.z)), ys: ys)
        let got = SIMD3(Double(out[i].x), Double(out[i].y), Double(out[i].z))
        let d = encodedClamp(want) - encodedClamp(got)
        worstCurve = Swift.max(worstCurve, Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z)))
    }
    check("C1 tone curve on Metal matches the CPU oracle within 1/255 (after sRGB encode)",
          out.count == ramp.count && worstCurve <= 1.0 / 255, "worst encoded error \(worstCurve)")
} catch {
    check("C1 tone curve kernel ran", false, "\(error)")
}

// C3 point curve: seven uneven points with a raised black point and a lowered white point, on the Metal kernel against the oracle
do {
    let sane = ToneCurve.sanitized(xs: [0.05, 0.18, 0.31, 0.52, 0.7, 0.86, 0.95], ys: [0.08, 0.2, 0.25, 0.6, 0.66, 0.92, 0.97])
    let uniforms = ToneCurve.uniforms(xs: sane.xs, ys: sane.ys)
    let count = 4096
    let pixels = (0..<count).map { i -> SIMD4<Float> in
        let t = Double(i) / Double(count - 1)
        return SIMD4(Float(-0.2 + 4.2 * t), Float(4.0 - 4.2 * t), Float(1.5 * t), 1)
    }
    let out = try MetalPerPixel.run(source: MetalToneCurve.source, function: "tonecurveBuf", pixels: pixels, uniforms: uniforms)
    var worstRel = 0.0, allFinite = out.count == count
    for (i, px) in pixels.enumerated() where i < out.count {
        let cpu = ToneCurve.apply(SIMD3(Double(px.x), Double(px.y), Double(px.z)), xs: sane.xs, ys: sane.ys)
        let gpu = SIMD3(Double(out[i].x), Double(out[i].y), Double(out[i].z))
        for c in 0..<3 {
            if !gpu[c].isFinite { allFinite = false }
            worstRel = Swift.max(worstRel, Swift.abs(gpu[c] - cpu[c]) / Swift.max(1, Swift.abs(cpu[c])))
        }
    }
    check("C3 a seven-point curve with uneven points on Metal matches the CPU oracle (unclamped, -0.2...4.0)",
          allFinite && worstRel < 1e-4, "finite \(allFinite), worst relative error \(worstRel)")
} catch {
    check("C3 point curve kernel ran", false, "\(error)")
}

// C2 tone curve extrapolation: channels span -0.2...4.0 linear, unclamped, with the asymmetric curve from TC6
do {
    let ys = [0.05, 0.3, 0.55, 0.7, 0.9]
    let uniforms = ToneCurve.uniforms(xs: ToneCurve.legacyXs, ys: ys)
    let count = 4096
    let pixels = (0..<count).map { i -> SIMD4<Float> in
        let t = Double(i) / Double(count - 1)
        return SIMD4(Float(-0.2 + 4.2 * t), Float(4.0 - 4.2 * t), Float(2 * t), 1)
    }
    let out = try MetalPerPixel.run(source: MetalToneCurve.source, function: "tonecurveBuf", pixels: pixels, uniforms: uniforms)
    var worstRel = 0.0, allFinite = out.count == count
    for (i, px) in pixels.enumerated() where i < out.count {
        let cpu = ToneCurve.apply(SIMD3(Double(px.x), Double(px.y), Double(px.z)), ys: ys)
        let gpu = SIMD3(Double(out[i].x), Double(out[i].y), Double(out[i].z))
        for c in 0..<3 {
            if !gpu[c].isFinite { allFinite = false }
            worstRel = Swift.max(worstRel, Swift.abs(gpu[c] - cpu[c]) / Swift.max(1, Swift.abs(cpu[c])))
        }
    }
    check("C2 tone curve extrapolation past white and below black matches the CPU oracle",
          allFinite && worstRel < 1e-4, "finite \(allFinite), worst relative error \(worstRel)")
} catch {
    check("C2 tone curve extrapolation kernel ran", false, "\(error)")
}

// CC1-CC3: the shared colour helpers every colour card's kernel uses, against DarkroomCore
do {
    let probe = MetalColorCommon.source + """
    kernel void ccLabBuf(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]],
                         constant float *u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        dst[i] = float4(cc_to_oklab(src[i].rgb), 1);
    }
    kernel void ccRoundBuf(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]],
                           constant float *u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        dst[i] = float4(cc_from_oklab(cc_to_oklab(src[i].rgb)), 1);
    }
    kernel void ccMiscBuf(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]],
                          constant float *u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        dst[i] = float4(cc_luminance(src[i].rgb), cc_smoothstep(0.2f, 0.6f, src[i].r), 0, 1);
    }
    """
    // colours from deep shadow to past white, every hue
    let sweep: [SIMD4<Float>] = (0..<4096).map { i in
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 2.5 * t
        return SIMD4(Float(v * (0.6 + 0.4 * cos(h))), Float(v * (0.6 + 0.4 * cos(h - 2.1))), Float(v * (0.6 + 0.4 * cos(h + 2.1))), 1)
    }
    let rgb = sweep.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
    let lab = try MetalPerPixel.run(source: probe, function: "ccLabBuf", pixels: sweep, uniforms: [])
    var worstLab = 0.0, finite = true
    for (g, c) in zip(lab, rgb) {
        let o = OkLab.fromWorking(c)
        if !(g.x.isFinite && g.y.isFinite && g.z.isFinite) { finite = false }
        worstLab = max(worstLab, abs(Double(g.x) - o.x), abs(Double(g.y) - o.y), abs(Double(g.z) - o.z))
    }
    check("CC1 cc_to_oklab matches OkLab.fromWorking within 2e-5", finite && worstLab < 2e-5, "worst \(worstLab), finite \(finite)")
    let round = try MetalPerPixel.run(source: probe, function: "ccRoundBuf", pixels: sweep, uniforms: [])
    var worstRound = 0.0
    for (g, c) in zip(round, rgb) {
        for k in 0..<3 { worstRound = max(worstRound, abs(Double(g[k]) - c[k]) / max(1, abs(c[k]))) }
    }
    check("CC2 cc_from_oklab(cc_to_oklab(x)) returns x within 1e-4", worstRound < 1e-4, "worst \(worstRound)")
    let misc = try MetalPerPixel.run(source: probe, function: "ccMiscBuf", pixels: sweep, uniforms: [])
    var worstMisc = 0.0
    for (g, c) in zip(misc, rgb) {
        worstMisc = max(worstMisc, abs(Double(g.x) - ColorCommon.luminance(c)) / max(1, ColorCommon.luminance(c)),
                        abs(Double(g.y) - ColorCommon.smoothstep(0.2, 0.6, c.x)))
    }
    check("CC3 cc_luminance and cc_smoothstep match ColorCommon within 1e-5", worstMisc < 1e-5, "worst \(worstMisc)")
    let grey = OkLab.fromWorking(SIMD3(0.18, 0.18, 0.18))
    // exactly neutral: workingToLMS is white-normalised (it was 7e-5 off before)
    check("CC3 grey is neutral in OkLab (chroma under 1e-12)", hypot(grey.y, grey.z) < 1e-12, "\(grey)")
    let white = OkLab.fromWorking(SIMD3(1, 1, 1))
    check("CC3 white is L = 1, a = b = 0", abs(white.x - 1) < 1e-12 && hypot(white.y, white.z) < 1e-12, "\(white)")
} catch {
    check("CC1-CC3 colour helpers ran", false, "\(error)")
}

// CB colour balance kernel against ColorBalance, on the same 4096 colours as CB1 in DarkroomCoreCheck
do {
    let cbPixels: [SIMD4<Float>] = (0..<4096).map { i in
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 2.5 * t
        return SIMD4(Float(v * (0.6 + 0.4 * cos(h))), Float(v * (0.6 + 0.4 * cos(h - 2.1))), Float(v * (0.6 + 0.4 * cos(h + 2.1))), 1)
    }
    let cbOut = try MetalPerPixel.run(source: MetalColorBalance.source, function: "colorbalanceBuf", pixels: cbPixels,
                                      uniforms: [0.3, 0.4, 0.5])
    var cbFinite = cbOut.count == cbPixels.count, cbWorst = 0.0
    for (g, p) in zip(cbOut, cbPixels) {
        guard g.x.isFinite, g.y.isFinite, g.z.isFinite else { cbFinite = false; continue }
        let input = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
        let want = ColorBalance.apply(input, contrast: 0.3, saturation: 0.4, vibrance: 0.5)
        for k in 0..<3 { cbWorst = max(cbWorst, abs(Double(g[k]) - want[k]) / max(1, abs(want[k]))) }
    }
    check("CB colorbalanceBuf is finite and matches ColorBalance within relative 1e-4 unclamped",
          cbFinite && cbWorst < 1e-4, "finite \(cbFinite), worst relative error \(cbWorst)")
} catch {
    check("CB colorbalanceBuf kernel ran", false, "\(error)")
}

// CB-M2 the black guard on the GPU: without `y > 0`, pow(0, -0.5) is infinite and 0 times infinity is NaN
do {
    let blackPixels: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1), SIMD4(0.001, 0.002, 0.0005, 1), SIMD4(2, 1.5, 0.3, 1)]
    let blackOut = try MetalPerPixel.run(source: MetalColorBalance.source, function: "colorbalanceBuf", pixels: blackPixels,
                                         uniforms: [-0.5, 0, 0])
    let exactBlack = blackOut[0].x == 0 && blackOut[0].y == 0 && blackOut[0].z == 0
    let allFiniteBlack = blackOut.count == blackPixels.count
        && blackOut.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    check("CB-M2 exact black stays exactly (0, 0, 0) at contrast -0.5 on Metal, every output finite",
          exactBlack && allFiniteBlack, "black \(blackOut[0]), all finite \(allFiniteBlack)")
} catch {
    check("CB-M2 black guard kernel ran", false, "\(error)")
}

// CM channel mixer on Metal (mixerBuf) against ChannelMixer, unclamped, on non-symmetric rows so a transposed kernel fails
do {
    let cmRows: [[Double]] = [[0.9, 0.2, -0.1], [0.05, 1.1, -0.15], [-0.2, 0.3, 0.9]]
    let cmUniforms = cmRows.flatMap { $0 }.map { Float($0) }
    let cmPixels = (0..<4096).map { i -> SIMD4<Float> in
        let t = Double(i) / 4095
        return SIMD4(Float(3 * t), Float(3 * (t * 13).truncatingRemainder(dividingBy: 1)), Float(3 * abs(sin(t * 29))), 1)
    }
    let cmOut = try MetalPerPixel.run(source: MetalChannelMixer.source, function: "mixerBuf", pixels: cmPixels, uniforms: cmUniforms)
    var worstMix = 0.0, cmFinite = cmOut.count == cmPixels.count
    for (g, p) in zip(cmOut, cmPixels) {
        guard g.x.isFinite, g.y.isFinite, g.z.isFinite else { cmFinite = false; continue }
        let c = ChannelMixer.apply(SIMD3(Double(p.x), Double(p.y), Double(p.z)), rows: cmRows)
        for k in 0..<3 { worstMix = max(worstMix, abs(Double(g[k]) - c[k]) / max(1, abs(c[k]))) }
    }
    check("CM mixer on Metal matches ChannelMixer unclamped within relative 1e-5", cmFinite && worstMix < 1e-5,
          "worst \(worstMix), finite \(cmFinite)")
} catch {
    check("CM mixer kernel ran", false, "\(error)")
}

// monochrome with a colour filter: 4096 colours sweeping every hue at chroma up to 0.25, clamped to 0.002...2.5,
// on Metal (monochromeBuf) against Monochrome.apply, unclamped; intensity 0.8, filter hue 200, strength 0.7
do {
    let moHueDegrees = 200.0
    let moRamp = (0..<4096).map { i -> SIMD3<Double> in
        let t = Double(i) / 4096
        let lab = OkLab.lab(SIMD3(0.2 + 0.7 * t, 0.02 + 0.23 * t, 2 * .pi * Double(i % 512) / 512))
        let rgb = OkLab.toWorking(lab)
        return SIMD3(min(max(rgb.x, 0.002), 2.5), min(max(rgb.y, 0.002), 2.5), min(max(rgb.z, 0.002), 2.5))
    }
    let moFloat = moRamp.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 1) }
    let moHue = moHueDegrees * .pi / 180
    let moOut = try MetalPerPixel.run(source: MetalMonochrome.source, function: "monochromeBuf", pixels: moFloat,
                                      uniforms: [0.8, 0.7, Float(cos(moHue)), Float(sin(moHue))])
    var moFinite = moOut.count == moRamp.count
    var moWorst = 0.0
    for (px, g) in zip(moRamp, moOut) {
        let cpu = Monochrome.apply(px, intensity: 0.8, filterHueDegrees: moHueDegrees, filterStrength: 0.7)
        let gpu = SIMD3(Double(g.x), Double(g.y), Double(g.z))
        moFinite = moFinite && gpu.x.isFinite && gpu.y.isFinite && gpu.z.isFinite
        for k in 0..<3 {
            moWorst = max(moWorst, abs(gpu[k] - cpu[k]) / max(1, abs(cpu[k])))
        }
    }
    check("MO-M monochrome on Metal is finite and within 1e-4 of Monochrome.apply (unclamped)",
          moFinite && moWorst < 1e-4, "finite \(moFinite), worst relative error \(moWorst)")
} catch {
    check("MO-M monochrome on Metal ran", false, "\(error)")
}

// split toning on Metal against SplitToning.apply (unclamped): every hue, deep shadow to past white
do {
    let count = 4096
    let pixels = (0..<count).map { i -> SIMD4<Float> in
        let t = Double(i) / Double(count - 1), h = t * 37 * 2 * .pi, v = 0.002 + 2.5 * t
        return SIMD4(Float(v * (0.6 + 0.4 * cos(h))), Float(v * (0.6 + 0.4 * cos(h - 2.1))), Float(v * (0.6 + 0.4 * cos(h + 2.1))), 1)
    }
    // the uniforms as CIModules builds them: pivot, shadows (a, b), highlights (a, b)
    let shH = 220 * Double.pi / 180, hiH = 60 * Double.pi / 180
    let uniforms: [Float] = [0.5 + 0.25 * 0.3, Float(0.08 * 0.8 * cos(shH)), Float(0.08 * 0.8 * sin(shH)),
                             Float(0.08 * 0.6 * cos(hiH)), Float(0.08 * 0.6 * sin(hiH))]
    let out = try MetalPerPixel.run(source: MetalSplitToning.source, function: "splitBuf", pixels: pixels, uniforms: uniforms)
    var worstRel = 0.0, allFinite = out.count == count
    for (i, px) in pixels.enumerated() where i < out.count {
        let cpu = SplitToning.apply(SIMD3(Double(px.x), Double(px.y), Double(px.z)), shadowsHueDegrees: 220, shadowsSaturation: 0.8,
                                    highlightsHueDegrees: 60, highlightsSaturation: 0.6, balance: 0.3)
        let gpu = SIMD3(Double(out[i].x), Double(out[i].y), Double(out[i].z))
        for c in 0..<3 {
            if !gpu[c].isFinite { allFinite = false }
            worstRel = Swift.max(worstRel, Swift.abs(gpu[c] - cpu[c]) / Swift.max(1, Swift.abs(cpu[c])))
        }
    }
    check("split toning on Metal is finite and within 1e-4 of SplitToning.apply (unclamped)",
          allFinite && worstRel < 1e-4, "finite \(allFinite), worst relative error \(worstRel)")
} catch {
    check("split toning kernel ran", false, "\(error)")
}

// SceneTone: the display module's Metal kernel (scenetoneBuf) against the oracle, SDR and HDR, on neutrals and saturated colours
do {
    for (label, tone) in [("SDR", SceneTone(contrast: 20)), ("HDR peak 4", SceneTone(peak: 4)), ("purity 0", SceneTone(purity: 0))] {
        var pixels: [SIMD4<Float>] = []
        var v = 1e-5
        while v < 40 { pixels.append(SIMD4(Float(v), Float(v), Float(v), 1)); v *= 1.07 }
        for i in 0..<12 { for j in 0..<12 { for k in 0..<12 {
            pixels.append(SIMD4(Float(i) * 0.3, Float(j) * 0.3, Float(k) * 0.3, 1))
        } } }
        pixels.append(SIMD4(-0.2, 0.5, 1.5, 1)); pixels.append(SIMD4(-1, -1, -1, 1)); pixels.append(SIMD4(0, 0, 0, 1))
        let out = try MetalPerPixel.run(source: MetalSceneTone.source, function: "scenetoneBuf", pixels: pixels, uniforms: tone.uniforms())
        var worst = 0.0
        for (i, px) in pixels.enumerated() where i < out.count {
            let want = tone.displayLinear(SIMD3(Double(px.x), Double(px.y), Double(px.z)))
            let got = SIMD3(Double(out[i].x), Double(out[i].y), Double(out[i].z))
            guard got.x.isFinite, got.y.isFinite, got.z.isFinite else { worst = .infinity; break }
            let d = want - got
            worst = Swift.max(worst, Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z)) / Swift.max(1, Swift.max(want.x, want.y, want.z)))
        }
        check("SC1 scene tone kernel (\(label)) matches the oracle within 5e-4 relative over \(pixels.count) pixels", out.count == pixels.count && worst < 5e-4, "\(worst)")
    }
} catch {
    check("scene tone kernel ran", false, "\(error)")
}

print(failures == 0 ? "\nall Metal checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
