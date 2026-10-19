// Metal oracle checks (checkpoint B1). Run: swift run darkroom-metal-check
// Each Metal kernel must match the DarkroomCore CPU reference within 1/255 after the display transform.
import DarkroomCore
import DarkroomMetal
import Foundation

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

print(failures == 0 ? "\nall Metal checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
