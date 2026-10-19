// Chart checks for DarkroomCore. Run: swift run darkroom-core-check
import DarkroomCore
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  " + detail())")
    if !ok { failures += 1 }
}
func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double) -> Bool {
    abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.z - b.z) <= tol
}

// matrices: Rec.2020 -> sRGB -> Rec.2020 and white maps to white
let white = SIMD3<Double>(1, 1, 1)
check("rec2020 white is sRGB white", near(ColorSpaces.rec2020ToSRGB.apply(white), white, 1e-9),
      "\(ColorSpaces.rec2020ToSRGB.apply(white))")
let rt = ColorSpaces.srgbToRec2020.mul(ColorSpaces.rec2020ToSRGB)
check("rec2020 <-> sRGB round trip", near(rt.apply(SIMD3(0.2, 0.5, 0.8)), SIMD3(0.2, 0.5, 0.8), 1e-9))

// OkLab
let ow = OkLab.fromRec2020(white)
check("OkLab white is L=1, a=b=0", abs(ow.x - 1) < 2e-3 && abs(ow.y) < 2e-3 && abs(ow.z) < 2e-3, "\(ow)")
for c in [SIMD3(0.1, 0.5, 0.9), SIMD3(1, 0, 0), SIMD3(0.02, 0.03, 0.01), SIMD3(2, 1.5, 0.3)] {
    check("OkLab round trip \(c)", near(OkLab.toRec2020(OkLab.fromRec2020(c)), c, 1e-9))
}
let lch = OkLab.lch(SIMD3(0.5, 0.1, -0.05))
check("OkLCh round trip", near(OkLab.lab(lch), SIMD3(0.5, 0.1, -0.05), 1e-12))

// transfers
var tfOK = true
for i in 0...100 {
    let v = Double(i) / 100
    tfOK = tfOK && abs(Transfer.linearToSRGB(Transfer.srgbToLinear(v)) - v) < 1e-12
    tfOK = tfOK && abs(Transfer.pqDecode(Transfer.pqEncode(v)) - v) < 1e-9
    tfOK = tfOK && abs(Transfer.hlgDecode(Transfer.hlgEncode(v)) - v) < 1e-9
}
check("sRGB, PQ, HLG round trips", tfOK)
check("PQ(100 nits) ~ 0.508", abs(Transfer.pqEncode(0.01) - 0.508) < 0.002, "\(Transfer.pqEncode(0.01))")

// tone map
let neutral = ToneMap()
check("tone: grey stays near grey", abs(neutral.apply(0.18) - 0.18) < 0.03, "\(neutral.apply(0.18))")
var mono = true, prev = 0.0
for i in 0..<400 {
    let y = 0.001 * pow(1.03, Double(i))
    let o = neutral.apply(y)
    if o < prev - 1e-12 { mono = false }
    prev = o
}
check("tone: monotone and never above 1", mono && prev <= 1.0, "\(prev)")
check("tone: contrast +50 steeper than 0 around grey",
      ToneMap(contrast: 50).apply(0.18 * 1.5) - ToneMap(contrast: 50).apply(0.18 / 1.5)
      > neutral.apply(0.18 * 1.5) - neutral.apply(0.18 / 1.5))
check("tone: whites +50 brighter upper tones (0.5 scene)", ToneMap(whites: 50).apply(0.5) > neutral.apply(0.5))
check("tone: blacks -50 deeper shadows", ToneMap(blacks: -50).apply(0.005) < neutral.apply(0.005))
let hdr = ToneMap(peak: 4)
check("tone: HDR stays <= peak and SDR range matches SDR", hdr.table.max()! <= 4 && abs(hdr.apply(0.18) - neutral.apply(0.18)) < 1e-6)
check("tone: zero and negative give zero", neutral.apply(0) == 0 && neutral.apply(-1) == 0)

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
