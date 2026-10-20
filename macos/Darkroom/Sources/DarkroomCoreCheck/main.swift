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
// LV levels: black, grey and white points on the sRGB-encoded value
let levelsRamp = (0...4096).map { 1.5 * Double($0) / 4096 }

// LV1 identity: the defaults leave every value unchanged
let lvIdentity = levelsRamp.allSatisfy { abs(Levels.apply($0, black: 0, grey: 0.5, white: 1) - $0) < 1e-9 }
check("LV1 levels at the defaults is the identity", lvIdentity)

// LV2 points: encoded input 0.1 goes to 0, 0.9 goes to 1, and the grey point 0.1 + 0.4 * 0.8 goes to 0.5
func levelsEncodedOut(_ e: Double) -> Double {
    Transfer.linearToSRGB(Levels.apply(Transfer.srgbToLinear(e), black: 0.1, grey: 0.4, white: 0.9))
}
check("LV2 black point: encoded 0.1 goes to 0", abs(levelsEncodedOut(0.1)) < 1e-9, "\(levelsEncodedOut(0.1))")
check("LV2 white point: encoded 0.9 goes to 1", abs(levelsEncodedOut(0.9) - 1) < 1e-9, "\(levelsEncodedOut(0.9))")
let lvGrey = 0.1 + 0.4 * 0.8
check("LV2 grey point: encoded \(lvGrey) goes to 0.5", abs(levelsEncodedOut(lvGrey) - 0.5) < 1e-9,
      "\(levelsEncodedOut(lvGrey))")

// LV3 monotone: the output never decreases over the ramp
func levelsMonotone(_ black: Double, _ grey: Double, _ white: Double) -> Bool {
    var previous = -Double.infinity
    for v in levelsRamp {
        let out = Levels.apply(v, black: black, grey: grey, white: white)
        if out < previous { return false }
        previous = out
    }
    return true
}
check("LV3 monotone for (0.1, 0.4, 0.9)", levelsMonotone(0.1, 0.4, 0.9))
check("LV3 monotone for (0, 0.7, 1)", levelsMonotone(0, 0.7, 1))

// LV4 HDR kept: above white, a brighter input stays brighter
let lvHigh = Levels.apply(1.4, black: 0, grey: 0.5, white: 0.9)
let lvLow = Levels.apply(1.0, black: 0, grey: 0.5, white: 0.9)
check("LV4 linear 1.4 stays above linear 1.0 when white is 0.9", lvHigh > lvLow, "\(lvHigh) vs \(lvLow)")

// LV5 guards: the guards must keep every output finite, and monotone where black equals white
let lvGuarded = levelsRamp.allSatisfy { Levels.apply($0, black: 0.4, grey: 0.5, white: 0.3).isFinite }
check("LV5 white below black gives finite outputs", lvGuarded)
let lvEqual = levelsRamp.allSatisfy { Levels.apply($0, black: 0.5, grey: 0.5, white: 0.5).isFinite }
check("LV5 black equal to white gives finite outputs", lvEqual)
check("LV5 black equal to white is monotone", levelsMonotone(0.5, 0.5, 0.5))
let lvGrey0 = levelsRamp.allSatisfy { Levels.apply($0, black: 0, grey: 0, white: 1).isFinite }
check("LV5 grey 0 gives finite outputs", lvGrey0)
let lvGrey1 = levelsRamp.allSatisfy { Levels.apply($0, black: 0, grey: 1, white: 1).isFinite }
check("LV5 grey 1 gives finite outputs", lvGrey1)

// tone curve: identity at the defaults, nodes hit, monotone, no overshoot, HDR keeps rising
let identityYs = [0, 0.25, 0.5, 0.75, 1.0]
let sYs = [0, 0.15, 0.5, 0.85, 1.0]

// TC1 identity: default heights return the input over a 0...1.5 ramp
var worstIdentity = 0.0
for i in 0...4096 {
    let v = 1.5 * Double(i) / 4096
    worstIdentity = max(worstIdentity, abs(ToneCurve.apply(v, ys: identityYs) - v))
}
check("TC1 tone curve identity returns the input", worstIdentity < 1e-9, "\(worstIdentity)")

// TC2 nodes: the S-curve passes through its nodes
let sTan = ToneCurve.tangents(sYs)
let nodeMid = ToneCurve.curve(0.5, ys: sYs, tangents: sTan)
let nodeLow = ToneCurve.curve(0.25, ys: sYs, tangents: sTan)
check("TC2 tone curve passes through the nodes", abs(nodeMid - sYs[2]) < 1e-12 && abs(nodeLow - sYs[1]) < 1e-12,
      "\(nodeMid) \(nodeLow)")

// TC3 monotone: the S-curve and a curve with a flat-then-rising shoulder never decrease over the ramp
for ys in [sYs, [0, 0.4, 0.6, 0.65, 1.0]] {
    var rising = true, last = -Double.infinity
    for i in 0...4096 {
        let o = ToneCurve.apply(1.5 * Double(i) / 4096, ys: ys)
        if o < last - 1e-12 { rising = false }
        last = o
    }
    check("TC3 tone curve \(ys) never decreases", rising)
}

// TC4 no overshoot: encoded output stays in 0...1 for encoded input in 0...1
var encodedInRange = true
for i in 0...1000 {
    let c = ToneCurve.curve(Double(i) / 1000, ys: sYs, tangents: sTan)
    if c < -1e-12 || c > 1 + 1e-12 { encodedInRange = false }
}
check("TC4 S-curve does not overshoot 0...1", encodedInRange)

// TC5 HDR kept: the S-curve keeps rising past white
let hdrAbove = ToneCurve.apply(1.2, ys: sYs) > ToneCurve.apply(1.0, ys: sYs)
check("TC5 S-curve input 1.2 is above input 1.0", hdrAbove,
      "\(ToneCurve.apply(1.2, ys: sYs)) vs \(ToneCurve.apply(1.0, ys: sYs))")

// TC6 extrapolation: past white and below black each end extends linearly with its own tangent
let asymYs = [0.05, 0.3, 0.55, 0.7, 0.9]
let asymM = ToneCurve.tangents(asymYs)
check("TC6 the two ends have different tangents", asymM[0] != asymM[4], "\(asymM[0]) \(asymM[4])")
let tc6Hi = ToneCurve.curve(1.4, ys: asymYs, tangents: asymM)
let tc6Lo = ToneCurve.curve(-0.3, ys: asymYs, tangents: asymM)
check("TC6 above 1 extends from y4 with m4", abs(tc6Hi - (asymYs[4] + asymM[4] * 0.4)) < 1e-12, "\(tc6Hi)")
check("TC6 below 0 extends from y0 with m0", abs(tc6Lo - (asymYs[0] + asymM[0] * -0.3)) < 1e-12, "\(tc6Lo)")

// G-series: geometry (flip, straighten, crop), the oracle DarkroomCI's geometry reads its affine map from
do {
    let size = SIMD2<Double>(300, 200)
    func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tol: Double = 1e-9) -> Bool { abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol }
    let corners = [SIMD2<Double>(0, 0), SIMD2(300, 0), SIMD2(0, 200), SIMD2(300, 200)]
    // G1 every orientation sends the corners to the output's corners, and the named cases go where they say
    for o in Orientation.allCases {
        let out = o.outputSize(size)
        let mapped = corners.map { o.map($0, size: size) }
        let onCorners = mapped.allSatisfy { ($0.x == 0 || $0.x == out.x) && ($0.y == 0 || $0.y == out.y) }
        check("G1 \(o) maps corners onto corners", onCorners && Set(mapped.map { "\($0)" }).count == 4, "\(mapped)")
    }
    check("G1 rotate cw 90: top-left goes to top-right", close(Orientation.rotateCW90.map(.zero, size: size), SIMD2(200, 0)))
    check("G1 rotate ccw 90: top-left goes to bottom-left", close(Orientation.rotateCCW90.map(.zero, size: size), SIMD2(0, 300)))
    check("G1 flip horizontally: top-left goes to top-right", close(Orientation.flipHorizontal.map(.zero, size: size), SIMD2(300, 0)))
    check("G1 flip vertically: top-left goes to bottom-left", close(Orientation.flipVertical.map(.zero, size: size), SIMD2(0, 200)))
    var p = SIMD2<Double>(37, 141), sz = size
    for _ in 0..<4 { p = Orientation.rotateCW90.map(p, size: sz); sz = Orientation.rotateCW90.outputSize(sz) }
    check("G1 four quarter turns are the identity", close(p, SIMD2(37, 141)), "\(p)")
    check("G1 names and values agree", Orientation(name: "ORIENTATION_ROTATE_CW_90_DEG") == Orientation(value: 5)
          && Orientation(name: "ORIENTATION_FLIP_HORIZONTALLY") == Orientation(value: 2) && Orientation(value: 99) == .none)

    // G2 rotation round trip and the inscribed rectangles fit inside the rotated image
    let q = Straighten.rotate(Straighten.rotate(SIMD2(12, 190), size: size, degrees: 13), size: size, degrees: -13)
    check("G2 rotate +13 then -13 degrees is the identity", close(q, SIMD2(12, 190), 1e-9), "\(q)")
    var fits = true
    for deg in [-44.0, -20, -3, 0.5, 7, 30, 45] {
        for shape in [SIMD2<Double>(300, 200), SIMD2(200, 300), SIMD2(400, 100), SIMD2(100, 100)] {
            for mode in [StraightenCrop.largest, .aspect] {
                let r = Straighten.inscribedSize(shape, degrees: deg, mode: mode)
                let o = shape / 2 - r / 2
                for c in [o, o + SIMD2(r.x, 0), o + SIMD2(0, r.y), o + r] where !Straighten.insideRotated(c, size: shape, degrees: deg) {
                    fits = false
                }
            }
        }
    }
    check("G2 largest and aspect rectangles have every corner inside the rotated image", fits)

    // G3 the closed form is the largest-area centred rectangle (brute force over aspect ratios)
    var worstRatio = 1.0
    for deg in [3.0, 10, 25, 40] {
        for shape in [SIMD2<Double>(300, 200), SIMD2(400, 100), SIMD2(150, 150)] {
            let closed = Straighten.inscribedSize(shape, degrees: deg, mode: .largest)
            var best = 0.0
            for i in 1...2000 {
                let aspect = exp(-3 + 6 * Double(i) / 2000)        // width over height, 0.05...20
                // the largest scale for this aspect, by bisection on "all corners inside"
                var lo = 0.0, hi = 2 * max(shape.x, shape.y)
                for _ in 0..<50 {
                    let mid = (lo + hi) / 2
                    let r = SIMD2(mid * aspect, mid), o = shape / 2 - r / 2
                    let inside = [o, o + SIMD2(r.x, 0), o + SIMD2(0, r.y), o + r].allSatisfy {
                        Straighten.insideRotated($0, size: shape, degrees: deg)
                    }
                    if inside { lo = mid } else { hi = mid }
                }
                best = max(best, lo * aspect * lo)
            }
            worstRatio = min(worstRatio, closed.x * closed.y / best)
        }
    }
    check("G3 closed-form largest rectangle is within 0.1% of the brute-force best", worstRatio > 0.999 && worstRatio < 1.001, "\(worstRatio)")

    // G4 aspect mode keeps the aspect ratio and is maximal: 0.2% larger no longer fits
    let a = Straighten.inscribedSize(size, degrees: 9, mode: .aspect)
    check("G4 aspect mode keeps the aspect ratio", abs(a.x / a.y - 1.5) < 1e-12, "\(a)")
    let big = a * 1.002, bo = size / 2 - big / 2
    let stillFits = [bo, bo + SIMD2(big.x, 0), bo + SIMD2(0, big.y), bo + big].allSatisfy {
        Straighten.insideRotated($0, size: size, degrees: 9)
    }
    check("G4 aspect mode is the largest such rectangle", !stillFits)
    check("G4 zero rotation keeps the full frame", Straighten.inscribedSize(size, degrees: 0, mode: .largest) == size
          && Straighten.inscribedSize(size, degrees: 0, mode: .aspect) == size)

    // G5 crop: the guard, the size, and the crop's top-left becoming the output origin
    check("G5 a zeroed crop entry is the full frame", CropRect(left: 0, top: 0, right: 0, bottom: 0) == .full)
    check("G5 out-of-range edges are clamped", CropRect(left: -1, top: 0.2, right: 3, bottom: 0.9) == CropRect(left: 0, top: 0.2, right: 1, bottom: 0.9))
    let cropOnly = GeometrySpec(crop: CropRect(left: 0.1, top: 0.25, right: 0.6, bottom: 0.75))
    check("G5 crop output size", close(cropOnly.outputSize(size), SIMD2(150, 100), 1e-9), "\(cropOnly.outputSize(size))")
    check("G5 crop top-left maps to the output origin", close(cropOnly.map(SIMD2(30, 50), size: size), .zero, 1e-9))

    // G6 a full spec: the input centre lands in the output centre when the crop is centred
    let full = GeometrySpec(orientation: .rotateCW90, degrees: 6,
                            straightenCrop: Straighten.cropFractions(SIMD2(200, 300), degrees: 6, mode: .largest),
                            crop: CropRect(left: 0.2, top: 0.1, right: 0.8, bottom: 0.9))
    let centre = full.map(size / 2, size: size), out = full.outputSize(size)
    check("G6 flip, straighten and centred crop keep the centre", close(centre, out / 2, 1e-9), "\(centre) vs \(out / 2)")
    // G7 direction: positive rotation turns the picture anticlockwise on screen (darktable's convention,
    // seen in a reference render): a point right of the centre moves up
    let turned = Straighten.rotate(size / 2 + SIMD2(10, 0), size: size, degrees: 90)
    check("G7 +90 degrees takes the point right of centre to above it", close(turned, size / 2 + SIMD2(0, -10), 1e-9), "\(turned)")

    // G8 straighten's crop fractions keep exactly the inscribed rectangle, centred; zero rotation keeps all
    for (deg, mode) in [(8.0, StraightenCrop.largest), (-15.0, .aspect)] {
        let f = Straighten.cropFractions(size, degrees: deg, mode: mode)
        let spec = GeometrySpec(degrees: deg, straightenCrop: f)
        let want = Straighten.inscribedSize(size, degrees: deg, mode: mode)
        check("G8 \(mode) crop fractions keep the inscribed size at \(deg) degrees", close(spec.outputSize(size), want, 1e-9),
              "\(spec.outputSize(size)) vs \(want)")
        check("G8 \(mode) crop keeps the centre at \(deg) degrees", close(spec.map(size / 2, size: size), want / 2, 1e-9))
    }
    check("G8 off keeps the whole bounding box", Straighten.cropFractions(size, degrees: 20, mode: .off) == .full)
    check("G8 no rotation needs no crop", Straighten.cropFractions(size, degrees: 0, mode: .largest) == .full)
    // G9 composing orientations: four clockwise quarter turns are none; cw then ccw is none; mirror twice is none;
    // and `then` agrees with mapping point by point for every pair
    var o = Orientation.none
    for _ in 0..<4 { o = o.then(.rotateCW90) }
    check("G9 four clockwise quarter turns compose to none", o == .none)
    check("G9 cw then ccw is none; mirror twice is none", Orientation.rotateCW90.then(.rotateCCW90) == .none
          && Orientation.flipHorizontal.then(.flipHorizontal) == .none && Orientation.rotateCW90.then(.rotateCW90) == .rotate180)
    var composesPointwise = true
    for a in Orientation.allCases {
        for b in Orientation.allCases {
            let c = a.then(b), p = SIMD2<Double>(1.25, 0.5), mid = a.outputSize(size)
            if !close(c.map(p, size: size), b.map(a.map(p, size: size), size: mid)) { composesPointwise = false }
        }
    }
    check("G9 every pair composes point by point", composesPointwise)
    check("G9 names round trip", Orientation.allCases.allSatisfy { Orientation(name: $0.name) == $0 })

    // G10 centred aspect crops follow the picture's shape and are as large as fit
    let land = CropRect.centred(longOverShort: 1.25, in: SIMD2(300, 200))   // landscape 3:2 to 5:4
    let lw = (land.right - land.left) * 300, lh = (land.bottom - land.top) * 200
    check("G10 landscape 4:5 is a landscape 5:4 at full height", abs(lw / lh - 1.25) < 1e-12 && abs(lh - 200) < 1e-9, "\(lw)x\(lh)")
    let port = CropRect.centred(longOverShort: 16.0 / 9, in: SIMD2(200, 300))
    let pw = (port.right - port.left) * 200, ph = (port.bottom - port.top) * 300
    check("G10 portrait 16:9 is a portrait 9:16 at full height... or width", abs(ph / pw - 16.0 / 9) < 1e-12 && (abs(pw - 200) < 1e-9 || abs(ph - 300) < 1e-9), "\(pw)x\(ph)")
    check("G10 centred", abs(land.left - (1 - land.right)) < 1e-12 && abs(port.top - (1 - port.bottom)) < 1e-12)
    check("G10 a bad ratio is no crop", CropRect.centred(longOverShort: 0.5, in: SIMD2(3, 2)) == .full && CropRect.centred(longOverShort: .nan, in: SIMD2(3, 2)) == .full)
    check("G6 identity spec is the identity", GeometrySpec().isIdentity && close(GeometrySpec().map(SIMD2(5, 7), size: size), SIMD2(5, 7)))
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
