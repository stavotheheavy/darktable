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

// T1 exposure round trip: +1 EV then -1 EV returns the ramp within 1e-3 (4096 steps, below clip)
var worstRound = 0.0
for i in 0..<4096 {
    let v = 0.5 * Double(i) / 4095
    worstRound = max(worstRound, abs(v * Exposure.gain(ev: 1) * Exposure.gain(ev: -1) - v))
}
check("T1 exposure +1 then -1 EV round trip", worstRound < 1e-3, "\(worstRound)")
check("T1 +1 EV doubles, -1 EV halves", Exposure.gain(ev: 1) == 2 && Exposure.gain(ev: -1) == 0.5)

// T2 clipped sky: a blown patch with equal channels must stay neutral after WB of +-1500 K
for k in [5000.0, 8000.0] {
    let g = WhiteBalance.gains(kelvin: k)
    let applied = WhiteBalance.clipNeutral(SIMD3(1, 1, 1), gains: g) * g
    let spread = (applied.max() - applied.min()) / applied.max()
    check("T2 clipped patch neutral at \(Int(k)) K", spread < 0.02, "spread \(spread)")
    let unclipped = SIMD3(1.0, 1.0, 1.0) * g
    check("T2 control: without clipNeutral the patch tints at \(Int(k)) K",
          (unclipped.max() - unclipped.min()) / unclipped.max() > 0.02)
}
check("T2 neutral reference gives unit gains", near(WhiteBalance.gains(kelvin: 6500), SIMD3(1, 1, 1), 1e-9))
let warm = WhiteBalance.gains(kelvin: 5000)
check("T2 warm light: blue gain above red gain", warm.z > warm.x, "\(warm)")

// T4 downstream-only recompute: dragging sharpen re-runs only sharpen; dragging WB re-runs WB and later
func chain(ev: Double, kelvin: Double, sharpen: Double) -> [Stage] {
    EditChain.stages(ev: ev, kelvin: kelvin, tint: 0, contrast: 0, sharpen: sharpen)
}
let source = (0..<64).map { SIMD3(0.02 + 0.007 * Double($0), 0.1, 0.3) }
let graph = StageGraph(stageCount: 5)
_ = graph.render(chain(ev: 0.5, kelvin: 6500, sharpen: 0.4), input: source)
let base = graph.executions
let afterSharpen = graph.render(chain(ev: 0.5, kelvin: 6500, sharpen: 0.8), input: source)
check("T4 sharpen drag runs only sharpen",
      ["exposure", "whitebalance", "tone"].allSatisfy { graph.executions[$0] == base[$0] }
      && graph.executions["sharpen"] == base["sharpen"]! + 1, "\(graph.executions)")
_ = graph.render(chain(ev: 0.5, kelvin: 8000, sharpen: 0.8), input: source)
let afterWB = graph.executions
check("T4 WB drag re-runs WB, tone, sharpen, not exposure",
      afterWB["exposure"] == base["exposure"]
      && afterWB["whitebalance"] == base["whitebalance"]! + 1
      && afterWB["tone"] == base["tone"]! + 1
      && afterWB["sharpen"] == base["sharpen"]! + 2)
let fresh = StageGraph(stageCount: 5).render(chain(ev: 0.5, kelvin: 6500, sharpen: 0.8), input: source)
check("T4 cached render equals fresh render", zip(afterSharpen, fresh).allSatisfy { near($0, $1, 1e-12) })

// display transform: white to white, black to black, output stays in 0...1, and monotone
check("display: scene white maps to display white", near(DisplayTransform.apply(white), white, 1e-6),
      "\(DisplayTransform.apply(white))")
check("display: black maps to black", near(DisplayTransform.apply(SIMD3(0, 0, 0)), SIMD3(0, 0, 0), 1e-12))
var displayOK = true, lastDisplay = -1.0
for i in 0...400 {
    let v = DisplayTransform.apply(SIMD3(repeating: 0.001 * pow(1.03, Double(i))))
    if v.x < lastDisplay || v.x < 0 || v.x > 1 { displayOK = false }
    lastDisplay = v.x
}
check("display: monotone and within 0...1", displayOK)

// tint: positive adds green (lower red and blue gain against green); zero is neutral
let tintUp = WhiteBalance.gains(kelvin: 6500, tint: 50)
let tintDown = WhiteBalance.gains(kelvin: 6500, tint: -50)
check("tint +50 gives green relative to magenta", tintUp.x < 1 && tintUp.z < 1 && tintUp.y == 1, "\(tintUp)")
check("tint -50 gives magenta relative to green", tintDown.x > tintUp.x, "\(tintDown)")
check("tint 0 is neutral at 6500 K", near(WhiteBalance.gains(kelvin: 6500, tint: 0), SIMD3(1, 1, 1), 1e-9))

// A1 highlight sources: dark foliage, a clipped patch, and a flat grey field on a 9 by 9 image
do {
    let n = 9
    var img = [SIMD3<Double>](repeating: SIMD3(repeating: 0.7), count: n * n)  // above sourceHi of clip
    for y in 0..<n { img[y * n] = SIMD3(0.04, 0.1, 0.03) }  // foliage in column 0
    for y in 3...5 { for x in 3...5 { img[y * n + x] = SIMD3(repeating: 1) } }  // clipped patch
    let w = HighlightSources.weights(img, width: n, height: n)
    check("A1 clipped pixel weight is 0", w[4 * n + 4] == 0)
    check("A1 pixel next to a clip is excluded", w[4 * n + 2] == 0, "\(w[4 * n + 2])")
    check("A1 dark foliage weight is 0", w[4 * n + 0] == 0)
    check("A1 pixel on the foliage edge is excluded", w[4 * n + 1] == 0, "\(w[4 * n + 1])")
    check("A1 flat bright field far from clip and edges has weight 1", w[8 * n + 8] == 1, "\(w[8 * n + 8])")
    check("A1 weights stay in 0...1", w.allSatisfy { $0 >= 0 && $0 <= 1 })
}

// A2 rebuild: a clipped patch (x and y 12...28) on dark branches comes out neutral; on a warm field it keeps the warm colour
do {
    let n = 41
    func patchImage(_ field: SIMD3<Double>) -> [SIMD3<Double>] {
        var img = [SIMD3<Double>](repeating: field, count: n * n)
        for y in 12...28 { for x in 12...28 { img[y * n + x] = SIMD3(repeating: 1) } }
        return img
    }
    let dark = HighlightRebuild.rebuild(patchImage(SIMD3(repeating: 0.05)), width: n, height: n)
    let c = dark[20 * n + 20]
    check("A2 clipped sky among dark branches is neutral white", (c.max() - c.min()) < 0.02, "\(c)")
    let warm = HighlightRebuild.rebuild(patchImage(SIMD3(0.7, 0.4, 0.25)), width: n, height: n)
    let w = warm[20 * n + 20]
    check("A2 clipped patch on a warm field keeps the warm hue", w.x > w.z + 0.5, "\(w)")
    check("A2 pixels outside the patch are unchanged", warm[0] == SIMD3(0.7, 0.4, 0.25))
}

// A3 partly clipped: a 3 by 3 patch whose red has blown (1.0, 0.9, 0.5) inside a warm field
do {
    let n = 41
    func partial(_ field: SIMD3<Double>) -> [SIMD3<Double>] {
        var img = [SIMD3<Double>](repeating: field, count: n * n)
        for y in 19...21 { for x in 19...21 { img[y * n + x] = SIMD3(1.0, 0.9, 0.5) } }
        return img
    }
    let warm = HighlightRebuild.rebuild(partial(SIMD3(0.7, 0.4, 0.25)), width: n, height: n)
    let w = warm[20 * n + 20]
    check("A3 blown red in a warm field rebuilds above clip", w.x > 1.2, "\(w)")
    check("A3 unclipped green and blue keep their values", w.y == 0.9 && w.z == 0.5, "\(w)")
    let dark = HighlightRebuild.rebuild(partial(SIMD3(repeating: 0.05)), width: n, height: n)
    check("A3 with no support the blown red stays at clip", dark[20 * n + 20].x == 1.0, "\(dark[20 * n + 20])")
}

// AW auto white balance (grey world): a 64 by 64 scene of 8 by 8 patches of 8 by 8 pixels, neutral on average.
// `replaced` swaps given patches (by index 8 * i + j) for fixed values; the rest take the colour times `cast`.
func patchScene(cast: SIMD3<Double> = SIMD3(1, 1, 1), replaced: [Int: SIMD3<Double>] = [:]) -> [SIMD3<Double>] {
    var img = [SIMD3<Double>](repeating: SIMD3(repeating: 0), count: 64 * 64)
    for i in 0..<8 {
        for j in 0..<8 {
            let a = 2 * Double.pi * Double(8 * i + j) / 64
            let colour = 0.3 * SIMD3<Double>(1 + 0.6 * cos(a), 1 + 0.6 * cos(a - 2.094), 1 + 0.6 * cos(a + 2.094))
            let value = replaced[8 * i + j] ?? colour * cast
            for y in 0..<8 { for x in 0..<8 { img[(8 * i + y) * 64 + 8 * j + x] = value } }
        }
    }
    return img
}
// ten patches spread evenly over the 64 (indices 0, 6, 12, 19, 25, 32, 38, 44, 51, 57)
let spread = (0..<10).map { $0 * 64 / 10 }
func withinCast(_ g: SIMD3<Double>, _ cast: SIMD3<Double>, _ tol: Double) -> Bool {
    let r = g * cast
    return abs(r.x - 1) <= tol && abs(r.y - 1) <= tol && abs(r.z - 1) <= tol
}
let castWB = SIMD3<Double>(1.3, 1.0, 0.7)
let white64 = SIMD3<Double>(1, 1, 1)

check("AW1 neutral scene gives unit gains", near(AutoWhiteBalance.gains(patchScene(), width: 64, height: 64), white64, 1e-6),
      "\(AutoWhiteBalance.gains(patchScene(), width: 64, height: 64))")
let castGains = AutoWhiteBalance.gains(patchScene(cast: castWB), width: 64, height: 64)
check("AW2 cast removed within 2%", withinCast(castGains, castWB, 0.02), "\(castGains)")
let clippedGains = AutoWhiteBalance.gains(
    patchScene(cast: castWB, replaced: Dictionary(uniqueKeysWithValues: spread.map { ($0, white64) })),
    width: 64, height: 64)
check("AW3 clipped patches ignored, cast removed within 2%", withinCast(clippedGains, castWB, 0.02), "\(clippedGains)")
let blackGains = AutoWhiteBalance.gains(
    patchScene(cast: castWB, replaced: Dictionary(uniqueKeysWithValues: spread.map { ($0, SIMD3<Double>(0.005, 0.002, 0.009)) })),
    width: 64, height: 64)
check("AW4 near-black patches ignored, cast removed within 2%", withinCast(blackGains, castWB, 0.02), "\(blackGains)")
let allClipped = AutoWhiteBalance.gains([SIMD3<Double>](repeating: white64, count: 64 * 64), width: 64, height: 64)
let allBlack = AutoWhiteBalance.gains([SIMD3<Double>](repeating: SIMD3(repeating: 0), count: 64 * 64), width: 64, height: 64)
check("AW5 nothing reliable gives unit gains", near(allClipped, white64, 1e-12) && near(allBlack, white64, 1e-12),
      "clipped \(allClipped), black \(allBlack)")
check("AW6 size mismatch gives unit gains",
      near(AutoWhiteBalance.gains(patchScene(cast: castWB), width: 64, height: 63), white64, 1e-12))

// AW7 dark rule: 15 opposite pairs (k and k + 32) become dark red, luminance about 0.0044. Each pair's hues cancel, so the rest still average neutral.
let darkRed = SIMD3<Double>(0.019, 0.0005, 0.0005)
let darkPairs = (0...14).flatMap { [$0, $0 + 32] }
let darkScene = patchScene(cast: castWB, replaced: Dictionary(uniqueKeysWithValues: darkPairs.map { ($0, darkRed) }))
let darkGains = AutoWhiteBalance.gains(darkScene, width: 64, height: 64)
check("AW7 dark patches ignored, cast removed within 1e-6", withinCast(darkGains, castWB, 1e-6), "\(darkGains)")
// control, as T2: plain grey world over all pixels, dark patches counted, is more than 3% off on red
var allSum = SIMD3<Double>(repeating: 0)
for p in darkScene { allSum += p }
let allMean = allSum / Double(darkScene.count)
let plainGains = SIMD3(allMean.y / allMean.x, 1, allMean.y / allMean.z)
check("AW7 control: plain grey world over all pixels is more than 3% off on red", abs(castWB.x * plainGains.x - 1) > 0.03,
      "\(castWB.x * plainGains.x)")

// AW8 1% floor: 50 of 10000 pixels (0.5%) are reliable, so the answer is unit gains, not the gains of those 50
var floorImg = [SIMD3<Double>](repeating: SIMD3(repeating: 0.001), count: 100 * 100)
for k in 0..<50 { floorImg[k] = SIMD3(0.4, 0.3, 0.2) }
let floorGains = AutoWhiteBalance.gains(floorImg, width: 100, height: 100)
check("AW8 under 1% reliable gives unit gains", near(floorGains, white64, 1e-12), "\(floorGains)")

// AW9 clamp: red gain would be about 0.167, so it is held at the 0.25 floor
let clampGains = AutoWhiteBalance.gains(patchScene(cast: SIMD3(6.0, 1.0, 1.0)), width: 64, height: 64, clip: 10)
check("AW9 red gain clamped to exactly 0.25", clampGains.x == 0.25, "\(clampGains.x)")

// AW10 the 0.95 factor: 0.96 is above 0.95 * clip, so the pair 0 and 32 is excluded
let edgeScene = patchScene(cast: castWB, replaced: [0: SIMD3(0.96, 0.5, 0.5), 32: SIMD3(0.96, 0.5, 0.5)])
let edgeGains = AutoWhiteBalance.gains(edgeScene, width: 64, height: 64)
check("AW10 pixels at 0.96 excluded, cast removed within 1e-6", withinCast(edgeGains, castWB, 1e-6), "\(edgeGains)")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
