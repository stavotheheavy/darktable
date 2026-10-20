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

// C1 tone curve: the per-pixel buffer kernel (MetalToneCurve) on a 64 by 64 ramp from 0 to 1.5, against ToneCurve
do {
    let ys = [0, 0.15, 0.5, 0.85, 1.0]
    let uniforms = (ys + ToneCurve.tangents(ys)).map { Float($0) }
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

print(failures == 0 ? "\nall Metal checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
