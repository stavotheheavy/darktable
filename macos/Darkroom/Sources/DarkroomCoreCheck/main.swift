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

// CB colour balance (Simple's Contrast and Color sliders) in OkLab
// 4096 colours from deep shadow to past white, every hue
let cbSweep: [SIMD3<Double>] = (0..<4096).map { i in
    let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 2.5 * t
    return SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
}

// CB1 the defaults are the identity
var cb1Worst = 0.0
for c in cbSweep {
    let o = ColorBalance.apply(c, contrast: 0, saturation: 0, vibrance: 0)
    // max() drops NaN, so a non-finite output is an infinite error
    guard o.x.isFinite, o.y.isFinite, o.z.isFinite else { cb1Worst = .infinity; continue }
    for k in 0..<3 { cb1Worst = max(cb1Worst, abs(o[k] - c[k]) / abs(c[k])) }
}
check("CB1 defaults are the identity on 4096 colours within 1e-9 relative", cb1Worst < 1e-9, "\(cb1Worst)")

// CB2 contrast pivots on middle grey and scales above and below it by 2^c
let grey18 = ColorBalance.apply(SIMD3(repeating: 0.18), contrast: 0.5, saturation: 0, vibrance: 0)
check("CB2 contrast 0.5 leaves middle grey (0.18) unchanged within 1e-12", near(grey18, SIMD3(repeating: 0.18), 1e-12), "\(grey18)")
let grey36 = ColorBalance.apply(SIMD3(repeating: 0.36), contrast: 0.5, saturation: 0, vibrance: 0)
let want36 = 0.36 * 2.0.squareRoot()
check("CB2 contrast 0.5 lifts grey 0.36 to 0.36 * 2^0.5 within 1e-9", near(grey36, SIMD3(repeating: want36), 1e-9), "\(grey36) want \(want36)")

// CB3 contrast keeps hue: every channel scales together, and the OkLab cube root is homogeneous
let cb3in = SIMD3<Double>(0.3, 0.12, 0.05)
let hue3In = OkLab.lch(OkLab.fromWorking(cb3in)).z
let hue3Out = OkLab.lch(OkLab.fromWorking(ColorBalance.apply(cb3in, contrast: 0.5, saturation: 0, vibrance: 0))).z
check("CB3 contrast 0.5 keeps the OkLab hue within 1e-9 rad", abs(ColorCommon.hueDifference(hue3Out, hue3In)) < 1e-9,
      "\(hue3Out - hue3In)")

// CB4 saturation -1 is grey, and L is untouched
let cb4in = OkLab.fromWorking(cb3in)
let cb4out = OkLab.fromWorking(ColorBalance.apply(cb3in, contrast: 0, saturation: -1, vibrance: 0))
check("CB4 saturation -1 gives OkLab chroma under 1e-6", hypot(cb4out.y, cb4out.z) < 1e-6, "\(hypot(cb4out.y, cb4out.z))")
check("CB4 saturation -1 keeps OkLab L within 1e-9", abs(cb4out.x - cb4in.x) < 1e-9, "\(cb4out.x - cb4in.x)")

// CB5 (roadmap gate T6) saturation +0.5 is hue-safe: 36 hues at L 0.6, chroma 0.04
var cb5Drift = 0.0, cb5Chroma = 0.0, cb5L = 0.0, cb5Min = Double.infinity, cb5Finite = true
for i in 0..<36 {
    let h = Double(i) * 10 * .pi / 180
    let rgb = OkLab.toWorking(SIMD3(0.6, 0.04 * cos(h), 0.04 * sin(h)))
    let out = ColorBalance.apply(rgb, contrast: 0, saturation: 0.5, vibrance: 0)
    // max() and min() drop NaN, so a non-finite output fails the finite check explicitly
    if !(out.x.isFinite && out.y.isFinite && out.z.isFinite) { cb5Finite = false; continue }
    let before = OkLab.lch(OkLab.fromWorking(rgb)), after = OkLab.lch(OkLab.fromWorking(out))
    cb5Drift = max(cb5Drift, abs(ColorCommon.hueDifference(after.z, before.z)))
    cb5Chroma = max(cb5Chroma, abs(after.y - 0.06))
    cb5L = max(cb5L, abs(after.x - 0.6))
    cb5Min = min(cb5Min, out.min())
}
check("CB5 every output is finite", cb5Finite, "a non-finite output")
check("CB5 saturation +0.5 keeps every hue within 2 degrees", cb5Finite && cb5Drift * 180 / .pi < 2, "\(cb5Drift * 180 / .pi) degrees")
check("CB5 saturation +0.5 gives chroma 0.06 within 1e-9", cb5Chroma < 1e-9, "\(cb5Chroma)")
check("CB5 saturation +0.5 keeps L within 1e-9", cb5L < 1e-9, "\(cb5L)")
check("CB5 saturation +0.5 does not clip (every channel >= -1e-9)", cb5Min >= -1e-9, "\(cb5Min)")

// CB6 vibrance favours dull colours: the chroma ratio is 1 + v * (1 - smoothstep(0, 0.2, C))
func cbVibranceRatio(_ chroma: Double) -> Double {
    let rgb = OkLab.toWorking(SIMD3(0.6, chroma * cos(1.0), chroma * sin(1.0)))
    let inC = OkLab.lch(OkLab.fromWorking(rgb)).y
    let outC = OkLab.lch(OkLab.fromWorking(ColorBalance.apply(rgb, contrast: 0, saturation: 0, vibrance: 0.6))).y
    return outC / inC
}
let ratio02 = cbVibranceRatio(0.02), ratio18 = cbVibranceRatio(0.18)
check("CB6 vibrance 0.6 gives chroma 0.02 a ratio of 1.5832 within 1e-9", abs(ratio02 - 1.5832) < 1e-9, "\(ratio02)")
check("CB6 vibrance 0.6 gives chroma 0.18 a ratio of 1.0168 within 1e-9", abs(ratio18 - 1.0168) < 1e-9, "\(ratio18)")
check("CB6 the dull colour gains the larger ratio", ratio02 > ratio18, "\(ratio02) vs \(ratio18)")

// CB7 black stays black (no pow(0, negative)), and an HDR colour stays finite
let cb7Black = ColorBalance.apply(SIMD3(0, 0, 0), contrast: -0.5, saturation: 0, vibrance: 0)
check("CB7 black stays exactly black at contrast -0.5", cb7Black == SIMD3(0, 0, 0), "\(cb7Black)")
let cb7Hot = ColorBalance.apply(SIMD3(4, 3, 2), contrast: 0.3, saturation: 0.3, vibrance: 0.3)
check("CB7 HDR (4, 3, 2) gives finite channels", cb7Hot.x.isFinite && cb7Hot.y.isFinite && cb7Hot.z.isFinite, "\(cb7Hot)")

// CM channel mixer: a 3x3 on linear RGB, nothing clamped
let cmIdentity = [[1.0, 0, 0], [0, 1, 0], [0, 0, 1]]
let cmGrid = (0..<4096).map { i in SIMD3(Double(i % 16) / 15 * 3, Double((i / 16) % 16) / 15 * 3, Double(i / 256) / 15 * 3) }
check("CM1 identity rows give the input exactly on 4096 colours", cmGrid.allSatisfy { near(ChannelMixer.apply($0, rows: cmIdentity), $0, 1e-12) })
check("CM2 swap red and blue", near(ChannelMixer.apply(SIMD3(0.7, 0.2, 0.1), rows: [[0, 0, 1], [0, 1, 0], [1, 0, 0]]), SIMD3(0.1, 0.2, 0.7), 1e-12))
let cmMono = [[0.3, 0.6, 0.1], [0.3, 0.6, 0.1], [0.3, 0.6, 0.1]]
check("CM3 a mono mix", near(ChannelMixer.apply(SIMD3(0.5, 0.25, 1.0), rows: cmMono), SIMD3(0.4, 0.4, 0.4), 1e-12))
check("CM4 no clamp above white", near(ChannelMixer.apply(SIMD3(1.5, 0.2, 0.1), rows: [[2, 0, 0], [0, 2, 0], [0, 0, 2]]), SIMD3(3.0, 0.4, 0.2), 1e-12))
check("CM4 no clamp below black", near(ChannelMixer.apply(SIMD3(0.4, 0.5, 0.6), rows: [[-1, 0, 0], [0, 1, 0], [0, 0, 1]]), SIMD3(-0.4, 0.5, 0.6), 1e-12))

// MO monochrome with a colour filter: intensity 0 leaves colours alone, intensity 1 gives the luminance grey,
// the filter lightens its own hue and darkens the opposite, and greys and zero stay put
let moColours = (0..<4096).map { i in
    SIMD3(Double(i % 16) / 15 * 1.5 + 0.01, Double((i / 16) % 16) / 15 * 1.5 + 0.01, Double(i / 256) / 15 * 1.5 + 0.01)
}
let moIdentity = moColours.allSatisfy { near(Monochrome.apply($0, intensity: 0, filterHueDegrees: 30, filterStrength: 1), $0, 1e-12) }
check("MO1 intensity 0 is the identity on 4096 colours", moIdentity)
let moWhite = Monochrome.apply(SIMD3(0.5, 0.25, 1.0), intensity: 1, filterHueDegrees: 30, filterStrength: 0)
let moLumaGrey = ColorCommon.luminance(SIMD3(0.5, 0.25, 1.0))   // the working space's weights (Rec.2020: 0.2627, 0.6780, 0.0593)
check("MO2 plain black and white is the working space's luminance grey (\(String(format: "%.4f", moLumaGrey)), not Rec.709's 0.3573)",
      near(moWhite, SIMD3(repeating: moLumaGrey), 1e-12) && abs(moLumaGrey - 0.3573) > 0.002, "\(moWhite)")
let moGrey = Monochrome.apply(SIMD3(repeating: 0.3), intensity: 1, filterHueDegrees: 30, filterStrength: 1)
check("MO3 greys ignore the filter", near(moGrey, SIMD3(repeating: 0.3), 1e-9), "\(moGrey)")
func moColour(_ hueDegrees: Double) -> SIMD3<Double> {
    OkLab.toWorking(OkLab.lab(SIMD3(0.6, 0.15, hueDegrees * .pi / 180)))
}
let moHot = moColour(30), moCold = moColour(210)
let hotRatio = Monochrome.apply(moHot, intensity: 1, filterHueDegrees: 30, filterStrength: 0.5).x
    / Monochrome.apply(moHot, intensity: 1, filterHueDegrees: 30, filterStrength: 0).x
let coldRatio = Monochrome.apply(moCold, intensity: 1, filterHueDegrees: 30, filterStrength: 0.5).x
    / Monochrome.apply(moCold, intensity: 1, filterHueDegrees: 30, filterStrength: 0).x
check("MO4 the filter's own hue is lighter by 1.5", abs(hotRatio - 1.5) < 1e-9, "\(hotRatio)")
check("MO4 the opposite hue is darker by 0.5", abs(coldRatio - 0.5) < 1e-9, "\(coldRatio)")
let moHalf = Monochrome.apply(SIMD3(0.5, 0.25, 1.0), intensity: 0.5, filterHueDegrees: 30, filterStrength: 0)
check("MO5 half intensity is the midpoint of input and grey", near(moHalf, (SIMD3(0.5, 0.25, 1.0) + moWhite) / 2, 1e-12), "\(moHalf)")
let moHotOut = Monochrome.apply(SIMD3(4, 3, 2), intensity: 1, filterHueDegrees: 30, filterStrength: 1)
let moZero = Monochrome.apply(SIMD3(0, 0, 0), intensity: 1, filterHueDegrees: 30, filterStrength: 1)
let moFinite = [moHotOut, moZero].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
check("MO6 past white and black give finite outputs", moFinite, "\(moHotOut) \(moZero)")
check("MO6 black stays black", moZero == SIMD3(0, 0, 0), "\(moZero)")

// MO7 the chroma fade: at chroma 0.075 (half of the 0.15 full fade) the filter's factor is 1 + 0.5 * 0.5 = 1.25
// on its own hue and 1 - 0.5 * 0.5 = 0.75 on the opposite hue; without the fade both would be 1.5 and 0.5
func moFadeColour(_ hueDegrees: Double) -> SIMD3<Double> {
    OkLab.toWorking(OkLab.lab(SIMD3(0.6, 0.075, hueDegrees * .pi / 180)))
}
let moFadeHot = moFadeColour(30), moFadeCold = moFadeColour(210)
let fadeHotRatio = Monochrome.apply(moFadeHot, intensity: 1, filterHueDegrees: 30, filterStrength: 0.5).x
    / Monochrome.apply(moFadeHot, intensity: 1, filterHueDegrees: 30, filterStrength: 0).x
let fadeColdRatio = Monochrome.apply(moFadeCold, intensity: 1, filterHueDegrees: 30, filterStrength: 0.5).x
    / Monochrome.apply(moFadeCold, intensity: 1, filterHueDegrees: 30, filterStrength: 0).x
check("MO7 half chroma: the filter's own hue is lighter by 1.25", abs(fadeHotRatio - 1.25) < 1e-9, "\(fadeHotRatio)")
check("MO7 half chroma: the opposite hue is darker by 0.75", abs(fadeColdRatio - 0.75) < 1e-9, "\(fadeColdRatio)")

// IV invert: the complement of each channel's display-encoded value. Black and white swap, applying it twice gives the input back,
// middle grey (0.5 encoded) stays put, and past the ends it saturates to the opposite end
check("IV1 black becomes white and white becomes black",
      near(Invert.apply(SIMD3(0, 0, 0)), SIMD3(1, 1, 1), 1e-12) && near(Invert.apply(SIMD3(1, 1, 1)), SIMD3(0, 0, 0), 1e-12))
let ivGrid = (0...255).map { Transfer.srgbToLinear(Double($0) / 255) }
let ivInvolution = ivGrid.allSatisfy { x in
    near(Invert.apply(Invert.apply(SIMD3(x, 1 - x, x * x))), SIMD3(x, 1 - x, x * x), 1e-9)
}
check("IV2 applying it twice gives the input back on 256 steps of 0...1", ivInvolution)
let ivMid = Transfer.srgbToLinear(0.5)
let ivMidOut = Invert.apply(SIMD3(repeating: ivMid))
check("IV3 middle grey (0.5 encoded, \(String(format: "%.4f", ivMid)) linear) is a fixed point", near(ivMidOut, SIMD3(repeating: ivMid), 1e-12), "\(ivMidOut)")
// the wrong rule, 1 - x on the linear value, must be told apart by IV3: it would send middle grey to 0.786
check("IV3 the linear complement is not this module (1 - 0.214 is far from 0.214)", abs((1 - ivMid) - ivMid) > 0.5)
check("IV4 past white is black and below black is white", near(Invert.apply(SIMD3(4, -0.5, 1.0)), SIMD3(0, 1, 0), 1e-12),
      "\(Invert.apply(SIMD3(4, -0.5, 1.0)))")
let ivBad = Invert.apply(SIMD3(.infinity, -.infinity, .nan))
check("IV5 infinities saturate and a NaN is black, so the output is finite", near(ivBad, SIMD3(0, 1, 1), 1e-12), "\(ivBad)")
let ivMonotone = zip(ivGrid, ivGrid.dropFirst()).allSatisfy { Invert.apply(SIMD3(repeating: $0)).x >= Invert.apply(SIMD3(repeating: $1)).x }
check("IV6 a lighter input never gives a lighter output", ivMonotone)
check("IV7 each channel is its own", Invert.apply(SIMD3(0.2, 0.5, 0.8)).x == Invert.apply(SIMD3(0.2, 0, 0)).x
      && Invert.apply(SIMD3(0.2, 0.5, 0.8)).z == Invert.apply(SIMD3(0, 0, 0.8)).z)

// CBS colisa: contrast about middle grey on luminance (hue kept), OkLab saturation (lightness kept), brightness as 2^(2b) of exposure
check("CBS1 all three at 0 is the identity on 4096 colours",
      moColours.allSatisfy { near(Colisa.apply($0, contrast: 0, brightness: 0, saturation: 0), $0, 1e-9) })
let clGrey = Colisa.apply(SIMD3(repeating: 0.1), contrast: 0, brightness: 0.5, saturation: 0)
check("CBS2 brightness 0.5 is +1 EV, a gain of 2^(2 * 0.5) = 2: 0.1 becomes 0.2", near(clGrey, SIMD3(repeating: 0.2), 1e-9), "\(clGrey)")
check("CBS2 brightness -0.5 halves: 0.4 becomes 0.2",
      near(Colisa.apply(SIMD3(repeating: 0.4), contrast: 0, brightness: -0.5, saturation: 0), SIMD3(repeating: 0.2), 1e-9))
// the wrong rule, an additive offset (Core Image's brightness), would give 0.1 + 0.5 = 0.6 and lift black: told apart by CL2
check("CBS2 an additive brightness is not this module (0.6 is far from 0.2)", abs((0.1 + 0.5) - 0.2) > 0.3)
check("CBS2 black stays black at any brightness", near(Colisa.apply(SIMD3(0, 0, 0), contrast: 0, brightness: 1, saturation: 0), SIMD3(0, 0, 0), 1e-12))
let clPivot = Colisa.apply(SIMD3(repeating: 0.18), contrast: 0.7, brightness: 0, saturation: 0)
check("CBS3 middle grey (0.18) does not move with contrast", near(clPivot, SIMD3(repeating: 0.18), 1e-9), "\(clPivot)")
check("CBS3 contrast 0.7 darkens 0.09 to 0.09 * 0.5^0.7 and lightens 0.36 to 0.36 * 2^0.7",
      near(Colisa.apply(SIMD3(repeating: 0.09), contrast: 0.7, brightness: 0, saturation: 0), SIMD3(repeating: 0.09 * pow(0.5, 0.7)), 1e-9)
      && near(Colisa.apply(SIMD3(repeating: 0.36), contrast: 0.7, brightness: 0, saturation: 0), SIMD3(repeating: 0.36 * pow(2.0, 0.7)), 1e-9))
let clColour = moColour(30)
let clContrasted = Colisa.apply(clColour, contrast: 0.6, brightness: 0, saturation: 0)
let clRatio = clContrasted / clColour
check("CBS3 contrast keeps hue: every channel scales by the same factor",
      abs(clRatio.x - clRatio.y) < 1e-9 && abs(clRatio.y - clRatio.z) < 1e-9, "\(clRatio)")
let clLabIn = OkLab.fromWorking(clColour)
let clNeutral = Colisa.apply(clColour, contrast: 0, brightness: 0, saturation: -1)
let clLabNeutral = OkLab.fromWorking(clNeutral)
check("CBS4 saturation -1 is neutral at the same OkLab lightness",
      abs(clNeutral.x - clNeutral.y) < 1e-6 && abs(clNeutral.y - clNeutral.z) < 1e-6 && abs(clLabNeutral.x - clLabIn.x) < 1e-9, "\(clNeutral)")
let clLabDouble = OkLab.fromWorking(Colisa.apply(clColour, contrast: 0, brightness: 0, saturation: 1))
check("CBS4 saturation 1 doubles the chroma and keeps the lightness",
      abs(hypot(clLabDouble.y, clLabDouble.z) / hypot(clLabIn.y, clLabIn.z) - 2) < 1e-9 && abs(clLabDouble.x - clLabIn.x) < 1e-9)
check("CBS5 brightness multiplies whatever contrast and saturation did",
      near(Colisa.apply(clColour, contrast: 0.4, brightness: 0.3, saturation: 0.5),
           Colisa.apply(clColour, contrast: 0.4, brightness: 0, saturation: 0.5) * pow(2, 0.6), 1e-9))
let clExtremeA = Colisa.apply(SIMD3(4, 3, 2), contrast: -1, brightness: 1, saturation: 1)
let clExtremeB = Colisa.apply(SIMD3(0, 0, 0), contrast: -1, brightness: 1, saturation: 1)
check("CBS6 the extremes are finite past white and at black",
      [clExtremeA, clExtremeB].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(clExtremeA) \(clExtremeB)")

// VE velvia: OkLab chroma times 1 + strength * w, w = 1 - smoothstep(0, 0.2, chroma): pale colours gain most, vivid ones are left alone,
// lightness and hue are kept
func veColour(_ chroma: Double, _ hueDegrees: Double = 30) -> SIMD3<Double> {
    OkLab.toWorking(OkLab.lab(SIMD3(0.6, chroma, hueDegrees * .pi / 180)))
}
func veChroma(_ rgb: SIMD3<Double>) -> Double { let lab = OkLab.fromWorking(rgb); return hypot(lab.y, lab.z) }
func veRatio(_ chroma: Double, _ strength: Double) -> Double { veChroma(Velvia.apply(veColour(chroma), strength: strength)) / veChroma(veColour(chroma)) }
check("VE1 strength 0 is the identity on 4096 colours", moColours.allSatisfy { near(Velvia.apply($0, strength: 0), $0, 1e-9) })
let veWant = 1 + 0.8 * (1 - ColorCommon.smoothstep(0, 0.2, 0.02))
check("VE2 a pale colour (chroma 0.02) at strength 0.8 gains \(String(format: "%.4f", veWant))x", abs(veRatio(0.02, 0.8) - veWant) < 1e-6, "\(veRatio(0.02, 0.8))")
check("VE3 a vivid colour (chroma 0.25, past the 0.2 fade) is left alone", abs(veRatio(0.25, 1) - 1) < 1e-6, "\(veRatio(0.25, 1))")
// uniform saturation would give the same ratio at every chroma: the strict order is what tells velvia from it
let veOrder = [0.03, 0.08, 0.15].map { veRatio($0, 1) }
check("VE4 the paler the colour the bigger the gain (a uniform saturation boost would not)",
      veOrder[0] > veOrder[1] && veOrder[1] > veOrder[2] && veOrder[2] > 1, "\(veOrder)")
let veIn = OkLab.fromWorking(veColour(0.05, 200)), veOut = OkLab.fromWorking(Velvia.apply(veColour(0.05, 200), strength: 1))
check("VE5 lightness and hue are kept", abs(veOut.x - veIn.x) < 1e-9 && abs(atan2(veOut.z, veOut.y) - atan2(veIn.z, veIn.y)) < 1e-9)
check("VE6 a grey stays grey", near(Velvia.apply(SIMD3(repeating: 0.3), strength: 1), SIMD3(repeating: 0.3), 1e-9))
let veExtremes = [Velvia.apply(SIMD3(4, 3, 2), strength: 1), Velvia.apply(SIMD3(0, 0, 0), strength: 1)]
check("VE7 past white and at black the output is finite", veExtremes.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(veExtremes)")

// ST split toning: greys are built in OkLab (a = b = 0) so their chroma is exactly zero before the tint
func splitGrey(_ L: Double) -> SIMD3<Double> { OkLab.toWorking(SIMD3(L, 0, 0)) }
func splitRun(_ c: SIMD3<Double>, shH: Double = 0, shS: Double = 0, hiH: Double = 0, hiS: Double = 0, balance: Double = 0) -> SIMD3<Double> {
    SplitToning.apply(c, shadowsHueDegrees: shH, shadowsSaturation: shS, highlightsHueDegrees: hiH, highlightsSaturation: hiS, balance: balance)
}
func hueErrorDegrees(_ lab: SIMD3<Double>, _ wantDegrees: Double) -> Double {
    abs(ColorCommon.hueDifference(OkLab.lch(lab).z, wantDegrees * .pi / 180)) * 180 / .pi
}

// ST1 zero saturations are the identity on 4096 colours
var stWorstIdentity = 0.0, stFinite1 = true
for i in 0..<4096 {
    let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 2.5 * t
    let c = SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
    let out = splitRun(c)
    for k in 0..<3 {
        // inputs are at least 0.0004, so dividing by |input| is safe; max() would drop a NaN, hence the explicit check
        if !out[k].isFinite { stFinite1 = false }
        stWorstIdentity = max(stWorstIdentity, abs(out[k] - c[k]) / abs(c[k]))
    }
}
check("ST1 zero saturations are the identity within 1e-9 relative, finite", stWorstIdentity < 1e-9 && stFinite1, "worst \(stWorstIdentity), finite \(stFinite1)")

// ST2 shadows take the shadow hue: grey at L 0.2 gets a chroma of 0.08 at 220 degrees
let st2 = OkLab.fromWorking(splitRun(splitGrey(0.2), shH: 220, shS: 1))
let st2Chroma = OkLab.lch(st2).y
check("ST2 shadow tint hue is 220 within 2 degrees", hueErrorDegrees(st2, 220) < 2, "\(OkLab.lch(st2).z)")
check("ST2 shadow tint chroma is 0.08 within 1e-9", abs(st2Chroma - 0.08 * (1 - ColorCommon.smoothstep(0.3, 0.7, 0.2))) < 1e-9, "\(st2Chroma)")

// ST3 highlights take the highlight hue: grey at L 0.9 gets a chroma of 0.08 at 60 degrees
let st3 = OkLab.fromWorking(splitRun(splitGrey(0.9), hiH: 60, hiS: 1))
check("ST3 highlight tint hue is 60 within 2 degrees", hueErrorDegrees(st3, 60) < 2, "\(OkLab.lch(st3).z)")
check("ST3 highlight tint chroma is 0.08 within 1e-9", abs(OkLab.lch(st3).y - 0.08) < 1e-9, "\(OkLab.lch(st3).y)")

// ST4 a shadow tint stays out of the highlights
let st4 = OkLab.fromWorking(splitRun(splitGrey(0.9), shH: 220, shS: 1))
check("ST4 a shadow tint leaves a highlight grey neutral (chroma under 1e-9)", OkLab.lch(st4).y < 1e-9, "\(OkLab.lch(st4).y)")

// ST5 lightness never changes, for ST2 to ST4 and a coloured input
var worstL = 0.0, stFinite5 = true
let st5Cases: [(SIMD3<Double>, Double, Double, Double, Double)] = [
    (splitGrey(0.2), 220, 1, 0, 0), (splitGrey(0.9), 0, 0, 60, 1), (splitGrey(0.9), 220, 1, 0, 0), (SIMD3(0.6, 0.3, 0.1), 220, 1, 60, 1),
]
for (c, shH, shS, hiH, hiS) in st5Cases {
    let inL = OkLab.fromWorking(c).x
    let out = splitRun(c, shH: shH, shS: shS, hiH: hiH, hiS: hiS)
    if !(out.x.isFinite && out.y.isFinite && out.z.isFinite) { stFinite5 = false }
    let outL = OkLab.fromWorking(out).x
    if !outL.isFinite { stFinite5 = false }
    // max() drops a NaN, so a non-finite lightness is also counted as a failure above
    worstL = max(worstL, abs(outL - inL))
}
check("ST5 lightness is unchanged within 1e-9, finite", worstL < 1e-9 && stFinite5, "worst \(worstL), finite \(stFinite5)")

// ST6 balance moves the pivot: at L 0.55 the shadows weight is 0.5 at balance 0 and 1 at balance +1
let st6Neutral = OkLab.lch(OkLab.fromWorking(splitRun(splitGrey(0.55), shH: 220, shS: 1))).y
let st6Warm = OkLab.lch(OkLab.fromWorking(splitRun(splitGrey(0.55), shH: 220, shS: 1, balance: 1))).y
check("ST6 balance 0 gives the chroma of pivot 0.5 within 1e-9",
      abs(st6Neutral - 0.08 * (1 - ColorCommon.smoothstep(0.3, 0.7, 0.55))) < 1e-9, "\(st6Neutral)")
check("ST6 balance +1 gives the chroma of pivot 0.75 within 1e-9",
      abs(st6Warm - 0.08 * (1 - ColorCommon.smoothstep(0.55, 0.95, 0.55))) < 1e-9, "\(st6Warm)")
check("ST6 balance +1 tints more than balance 0 at this grey", st6Warm > st6Neutral, "\(st6Warm) vs \(st6Neutral)")

// ST7 past white: finite output
let st7 = splitRun(SIMD3(4, 3, 2), shH: 220, shS: 1, hiH: 60, hiS: 1)
check("ST7 past white stays finite", st7.x.isFinite && st7.y.isFinite && st7.z.isFinite, "\(st7)")

// F-series: the neighbourhood filters (box mean, guided filter, à trous) the detail modules are built on
do {
    // a textured 40x30 plane: smooth waves plus a deterministic "noise" term
    let w = 40, h = 30
    let tex = Plane(width: w, height: h, values: (0..<(w * h)).map { i in
        let x = Double(i % w), y = Double(i / w)
        return 0.4 + 0.25 * sin(x / 3.1) * cos(y / 4.7) + 0.05 * sin(x * 12.9898 + y * 78.233)
    })
    // F1 box mean equals a brute-force window sum with clamped edges
    let r = 3, fast = Filters.boxMean(tex, radius: r)
    var worst = 0.0
    for y in 0..<h { for x in 0..<w {
        var s = 0.0
        for dy in -r...r { for dx in -r...r { s += tex.at(x + dx, y + dy) } }
        worst = max(worst, abs(s / Double((2 * r + 1) * (2 * r + 1)) - fast.values[y * w + x]))
    } }
    check("F1 box mean equals the brute-force window mean, edges clamped", worst < 1e-12, "\(worst)")
    // F2 identities
    let flat = Plane(width: w, height: h, fill: 0.37)
    check("F2 box mean of a constant is the constant; radius 0 is the identity",
          Filters.boxMean(flat, radius: 5).values.allSatisfy { abs($0 - 0.37) < 1e-12 } && Filters.boxMean(tex, radius: 0) == tex)
    // F3 the guided filter's limits: tiny eps self-guided keeps the input; huge eps is the box of the box
    let keep = Filters.guided(guide: tex, input: tex, radius: 4, eps: 1e-12)
    let keepErr = zip(keep.values, tex.values).map { abs($0 - $1) }.max() ?? .infinity
    check("F3 self-guided with eps 1e-12 returns the input", keepErr < 1e-4, "\(keepErr)")
    let wide = Filters.guided(guide: tex, input: tex, radius: 4, eps: 1e9)
    let boxbox = Filters.boxMean(Filters.boxMean(tex, radius: 4), radius: 4)
    let wideErr = zip(wide.values, boxbox.values).map { abs($0 - $1) }.max() ?? .infinity
    check("F3 with eps 1e9 the guided filter is the box mean of the box mean", wideErr < 1e-6, "\(wideErr)")
    check("F3 a constant stays constant", Filters.guided(guide: flat, input: flat, radius: 4, eps: 1e-3).values.allSatisfy { abs($0 - 0.37) < 1e-12 })
    // F4 edge preservation: a 0.1 / 0.9 step stays sharp under the guided filter, and box blurring (the control) smears it
    let step = Plane(width: w, height: h, values: (0..<(w * h)).map { $0 % w < 20 ? 0.1 : 0.9 })
    let g = Filters.guided(guide: step, input: step, radius: 4, eps: 1e-4)
    let left = g.at(19, 15), right = g.at(20, 15), boxLeft = Filters.boxMean(step, radius: 4).at(19, 15)
    check("F4 the guided filter keeps a step sharp (\(left) | \(right)); box mean smears it (\(boxLeft))",
          left < 0.15 && right > 0.85 && boxLeft > 0.4, "")
    let finite = g.values.allSatisfy(\.isFinite) && keep.values.allSatisfy(\.isFinite) && wide.values.allSatisfy(\.isFinite)
    check("F4 guided outputs are finite", finite)
    // F5 à trous splits and sums back exactly
    let (bands, residual) = Filters.atrous(tex, levels: 5)
    var sum = residual
    for b in bands { sum = Plane.zip(sum, b, +) }
    let recon = zip(sum.values, tex.values).map { abs($0 - $1) }.max() ?? .infinity
    check("F5 à trous bands plus the residual give back the input", recon < 1e-12, "\(recon)")
    // F6 a constant has no detail
    check("F6 a constant has zero detail in every band", Filters.atrous(flat, levels: 4).details.allSatisfy { $0.values.allSatisfy { abs($0) < 1e-15 } })
    // F7 band selectivity: a 2-pixel checkerboard lives in the finest band
    let checker = Plane(width: w, height: h, values: (0..<(w * h)).map { ((($0 % w) + ($0 / w)) % 2 == 0) ? 0.3 : 0.7 })
    let cb = Filters.atrous(checker, levels: 4).details.map { $0.values.reduce(0) { $0 + $1 * $1 } }
    let frac = cb[0] / max(cb.reduce(0, +), 1e-30)
    check("F7 a 2-pixel checkerboard puts most of its detail energy in the finest band (\(String(format: "%.3f", frac)))", frac > 0.9)
}

// DC: the square-root luminance helpers the S5 detail cards share
do {
    let w = 48, h = 40
    let img = DetailCommon.fixture(width: w, height: h)
    let s = DetailCommon.sqrtLuminance(img, width: w, height: h)
    check("DC1 the fixture is finite, positive and has a past-white corner", img.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x > 0 && $0.y > 0 && $0.z > 0 } && img.contains { $0.x > 1 })
    let back = DetailCommon.applying(sqrtLuminance: s, to: img)
    var rt = 0.0
    for (a, b) in zip(back, img) { for c in 0..<3 { rt = max(rt, abs(a[c] - b[c]) / max(1, abs(b[c]))) } }
    check("DC1 giving a pixel back its own square-root luminance is the identity", rt < 1e-12, "\(rt)")
    let doubled = DetailCommon.applying(sqrtLuminance: s.map { 2 * $0 }, to: img)
    var scale = 0.0
    for (a, b) in zip(doubled, img) { for c in 0..<3 { scale = max(scale, abs(a[c] - 4 * b[c]) / max(1, 4 * abs(b[c]))) } }
    check("DC2 doubling s multiplies luminance and every channel by 4 (hue and chroma ratios stay)", scale < 1e-12, "\(scale)")
    let dark = DetailCommon.applying(sqrtLuminance: Plane(width: 2, height: 1, values: [5, -1]),
                                     to: [SIMD3(1e-8, 1e-8, 1e-8), SIMD3(0.3, 0.2, 0.1)])
    check("DC3 a pixel at or under the minimum luminance is left alone", dark[0] == SIMD3(1e-8, 1e-8, 1e-8), "\(dark[0])")
    check("DC3 a negative new s gives black, not NaN", dark[1] == SIMD3(0, 0, 0), "\(dark[1])")
}

// SH: the 2-D unsharp mask on the square root of luminance (Sharpen2D)
do {
    let fw = 48, fh = 40
    let fx = DetailCommon.fixture(width: fw, height: fh)
    // the step: 40 wide, 16 high, grey, Y = 0.09 (s = 0.3) left of x = 20 and Y = 0.36 (s = 0.6) from there on
    let sw = 40, sh = 16
    let stepGrey: [SIMD3<Double>] = (0..<(sw * sh)).map { i in
        let y = i % sw < 20 ? 0.09 : 0.36
        return SIMD3(y, y, y)
    }
    // the largest relative difference, channel by channel, and infinite when a value is not finite or the counts differ
    func relErr(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        guard a.count == b.count else { return .infinity }
        var w = 0.0
        for (x, y) in zip(a, b) {
            for c in 0..<3 {
                guard x[c].isFinite else { return .infinity }
                w = max(w, abs(x[c] - y[c]) / max(1, abs(y[c])))
            }
        }
        return w
    }

    // SH1 amount 0 is the identity
    let id1 = relErr(Sharpen2D.apply(fx, width: fw, height: fh, amount: 0, radius: 3), fx)
    let id2 = relErr(Sharpen2D.apply(stepGrey, width: sw, height: sh, amount: 0, radius: 1), stepGrey)
    check("SH1 amount 0 is the identity on the fixture and on the step (\(id1), \(id2))", id1 < 1e-12 && id2 < 1e-12, "\(id1), \(id2)")

    // SH2 a flat colour stays flat at any amount and radius; black stays exactly black
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: 16 * 16)
    let flatOut = Sharpen2D.apply(flat, width: 16, height: 16, amount: 2, radius: 8)
    let flatErr = relErr(flatOut, flat)
    check("SH2 a flat colour is unchanged at amount 2, radius 8 (\(flatErr))", flatErr < 1e-12, "\(flatErr)")
    let blackOut = Sharpen2D.apply([SIMD3<Double>](repeating: .zero, count: 16 * 16), width: 16, height: 16, amount: 2, radius: 8)
    check("SH2 black stays exactly (0, 0, 0)", blackOut.allSatisfy { $0 == SIMD3(0, 0, 0) })

    // SH3 the method: s' = s + amount (s - base) with base from three à trous smoothings, on every pixel with Y > 1e-6
    let s = DetailCommon.sqrtLuminance(fx, width: fw, height: fh)
    let base = Filters.atrousSmooth(Filters.atrousSmooth(Filters.atrousSmooth(s, level: 0), level: 1), level: 2)
    let out3 = Sharpen2D.apply(fx, width: fw, height: fh, amount: 0.7, radius: 4)   // radius 4 is cascade 2 exactly
    var m3 = 0.0
    for i in fx.indices where ColorCommon.luminance(fx[i]) > 1e-6 {
        let want = max(s.values[i] + 0.7 * (s.values[i] - base.values[i]), 0)
        let d = abs(sqrt(max(ColorCommon.luminance(out3[i]), 0)) - want)
        m3 = d.isFinite ? max(m3, d) : .infinity
    }
    check("SH3 sqrt(Y_out) equals s + 0.7 (s - base) with the three-level blur within 1e-9 (\(m3))", m3 < 1e-9, "\(m3)")

    // SH4 edge overshoot on the step at radius 1.5 (level 1, reach 6): undershoot left of the edge, overshoot right,
    // and the pixels beyond the reach are untouched
    let out4 = Sharpen2D.apply(stepGrey, width: sw, height: sh, amount: 1, radius: 1.5)
    let row = 8
    let under = sqrt(ColorCommon.luminance(out4[row * sw + 19])), over = sqrt(ColorCommon.luminance(out4[row * sw + 20]))
    check("SH4 the edge undershoots at x = 19 (\(under)) and overshoots at x = 20 (\(over))", under < 0.3 && over > 0.6, "\(under), \(over)")
    var far = 0.0
    for y in 0..<sh { for x in 0..<sw where x <= 13 || x >= 26 {
        far = max(far, relErr([out4[y * sw + x]], [stepGrey[y * sw + x]]))
    } }
    check("SH4 pixels with x <= 13 or x >= 26 are unchanged within 1e-12 (\(far))", far < 1e-12, "\(far)")

    // SH5 the amount is linear in s: s'(2) - s = 2 (s'(1) - s)
    let out5a = Sharpen2D.apply(stepGrey, width: sw, height: sh, amount: 1, radius: 1.5)
    let out5b = Sharpen2D.apply(stepGrey, width: sw, height: sh, amount: 2, radius: 1.5)
    var lin = 0.0
    for i in stepGrey.indices {
        let s0 = sqrt(ColorCommon.luminance(stepGrey[i]))
        let s1 = sqrt(ColorCommon.luminance(out5a[i])), s2 = sqrt(ColorCommon.luminance(out5b[i]))
        let d = abs((s2 - s0) - 2 * (s1 - s0))
        lin = d.isFinite ? max(lin, d) : .infinity
    }
    check("SH5 the change in s is linear in amount within 1e-9 (\(lin))", lin < 1e-9, "\(lin)")

    // SH6 hue and chroma are untouched: each channel's gain is the same
    let out6 = Sharpen2D.apply(fx, width: fw, height: fh, amount: 1.2, radius: 2)
    var hue = 0.0
    for i in fx.indices {
        let r = out6[i].x / fx[i].x, g = out6[i].y / fx[i].y, b = out6[i].z / fx[i].z
        let d = max(abs(r - g), abs(r - b)) / max(1, abs(r))
        hue = d.isFinite ? max(hue, d) : .infinity
    }
    check("SH6 every channel gets the same gain (hue and chroma ratios stay) within 1e-9 (\(hue))", hue < 1e-9, "\(hue)")

    // SH7 the radius picks the blur level, and the blur reaches as far as its level says
    let cas: [(Double, Int, Int, Double)] = [(0, -1, -1, 0), (0.5, -1, 0, 0.5), (1, 0, 1, 0), (2, 1, 2, 0), (4, 2, 3, 0), (8, 3, 3, 0), (100, 3, 3, 0), (-1, -1, -1, 0)]
    let casOK = cas.allSatisfy { let c = Sharpen2D.cascades(radius: $0.0); return c.lo == $0.1 && c.hi == $0.2 && abs(c.weight - $0.3) < 1e-12 }
    let mid = Sharpen2D.cascades(radius: 3)
    check("SH7 the cascades are none, 0, 1, 2, 3 at radius 0, 1, 2, 4, 8, and in between blend the two nearest by log2", casOK && mid.lo == 1 && mid.hi == 2 && abs(mid.weight - (log2(3.0) - 1)) < 1e-12)
    let sm = [0.2, 0.5, 0.8, 1.3, 2.5, 5.0, 8.0].map { Sharpen2D.apply(fx, width: fw, height: fh, amount: 1, radius: $0) }
    let smDiffs = zip(sm, sm.dropFirst()).map { relErr($1, $0) }
    check("SH7b every step of the radius slider changes the picture, below 1 px too (the preview's range)", smDiffs.allSatisfy { $0 > 1e-6 }, "\(smDiffs)")
    let near = Sharpen2D.apply(stepGrey, width: sw, height: sh, amount: 1, radius: 1)
    let nearErr = relErr([near[8 * sw + 10]], [stepGrey[8 * sw + 10]])
    check("SH7 at radius 1 the pixel ten from the edge is unchanged (\(nearErr))", nearErr < 1e-12, "\(nearErr)")
    let wide = Sharpen2D.apply(stepGrey, width: sw, height: sh, amount: 1, radius: 8)
    let wideMove = abs(sqrt(ColorCommon.luminance(wide[8 * sw + 10])) - 0.3)
    check("SH7 at radius 8 the same pixel moves by more than 1e-3 in s (\(wideMove))", wideMove > 1e-3, "\(wideMove)")

    // SH8 finite everywhere on the fixture (past white, pixels near black) at the strongest setting
    let out8 = Sharpen2D.apply(fx, width: fw, height: fh, amount: 2, radius: 8)
    check("SH8 finite everywhere at amount 2, radius 8", out8.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
}

// LC local contrast on square-root luminance (DarkroomCore.LocalContrast)
do {
    let fw = 48, fh = 40
    let fix = DetailCommon.fixture(width: fw, height: fh)
    // max that cannot hide a NaN: max(w, .nan) returns w, so a non-finite term makes the accumulator infinite
    func absorb(_ acc: Double, _ term: Double) -> Double { term.isFinite ? max(acc, term) : .infinity }
    func maxDiff(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        var w = 0.0
        for (p, q) in zip(a, b) { for c in 0..<3 { w = absorb(w, abs(p[c] - q[c])) } }
        return a.count == b.count ? w : .infinity
    }
    func finite(_ a: [SIMD3<Double>]) -> Bool { a.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } }
    // a grey step at x = 20 (s = 0.2 left, s = 0.8 right) and a grey sine wave in s (Y = s^2)
    let stepGrey: [SIMD3<Double>] = (0..<(40 * 16)).map { i in SIMD3(repeating: i % 40 < 20 ? 0.04 : 0.64) }
    let waveGrey: [SIMD3<Double>] = (0..<(60 * 60)).map { i in
        let s = 0.5 + 0.02 * sin(2 * Double.pi * Double(i % 60) / 8)
        return SIMD3(repeating: s * s)
    }
    func popStd(_ p: Plane, width: Int) -> Double {
        var vals: [Double] = []
        for y in 20..<40 { for x in 20..<40 { vals.append(p.values[y * width + x]) } }
        let m = vals.reduce(0, +) / Double(vals.count)
        return sqrt(vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count))
    }

    // LC1 detail 0 is the identity; flat colour at detail 2 is unchanged
    let id = LocalContrast.apply(fix, width: fw, height: fh, detail: 0, radius: 5)
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: 16 * 16)
    let flatOut = LocalContrast.apply(flat, width: 16, height: 16, detail: 2, radius: 2)
    let lc1 = maxDiff(id, fix), lc1b = maxDiff(flatOut, flat)
    check("LC1 detail 0 is the identity, and flat colour at detail 2 is unchanged, within 1e-12",
          lc1.isFinite && lc1 < 1e-12 && lc1b.isFinite && lc1b < 1e-12, "\(lc1), \(lc1b)")

    // LC2 the method: sqrt(Y_out) = max(s + 0.8 (s - guided(s)), 0) on every pixel
    let s = DetailCommon.sqrtLuminance(fix, width: fw, height: fh)
    let ref = Filters.guided(guide: s, input: s, radius: 5, eps: 0.01)
    let out = LocalContrast.apply(fix, width: fw, height: fh, detail: 0.8, radius: 5)
    let sOut = DetailCommon.sqrtLuminance(out, width: fw, height: fh)
    var e2 = 0.0
    for i in fix.indices where 0.2126 * fix[i].x + 0.7152 * fix[i].y + 0.0722 * fix[i].z > 1e-6 {
        e2 = absorb(e2, abs(sOut.values[i] - max(s.values[i] + 0.8 * (s.values[i] - ref.values[i]), 0)))
    }
    check("LC2 sqrt(Y_out) equals max(s + 0.8 (s - guided), 0) within 1e-9", e2.isFinite && e2 < 1e-9, "\(e2)")

    // LC3 edge-aware: the boost at the step is much smaller than a box base would give
    let stepS = DetailCommon.sqrtLuminance(stepGrey, width: 40, height: 16)
    let stepOut = DetailCommon.sqrtLuminance(LocalContrast.apply(stepGrey, width: 40, height: 16, detail: 1, radius: 4), width: 40, height: 16)
    let boxBase = Filters.boxMean(stepS, radius: 4)
    var dGuided = 0.0, dBox = 0.0
    for x in 19...20 {
        let i = 8 * 40 + x
        dGuided = absorb(dGuided, abs(stepOut.values[i] - stepS.values[i]))
        dBox = absorb(dBox, abs(stepS.values[i] - boxBase.values[i]))
    }
    let ratio3 = dGuided / dBox
    check("LC3 the boost at the step is under 0.3 times the box-base boost (edge-aware, no halo)",
          dGuided.isFinite && dBox.isFinite && ratio3.isFinite && ratio3 < 0.3, "guided \(dGuided), box \(dBox), ratio \(ratio3)")

    // LC4 and LC5 positive detail boosts texture, negative detail flattens it
    let waveS = DetailCommon.sqrtLuminance(waveGrey, width: 60, height: 60)
    let inStd = popStd(waveS, width: 60)
    let up = popStd(DetailCommon.sqrtLuminance(LocalContrast.apply(waveGrey, width: 60, height: 60, detail: 1, radius: 4), width: 60, height: 60), width: 60)
    let down = popStd(DetailCommon.sqrtLuminance(LocalContrast.apply(waveGrey, width: 60, height: 60, detail: -1, radius: 4), width: 60, height: 60), width: 60)
    let ratio4 = up / inStd, ratio5 = down / inStd
    check("LC4 detail 1 raises the population std of s by 1.85 to 2.05 times", ratio4.isFinite && ratio4 > 1.85 && ratio4 < 2.05, "\(ratio4)")
    check("LC5 detail -1 flattens: the std of s falls under 0.1 times", ratio5.isFinite && ratio5 < 0.1, "\(ratio5)")

    // LC6 hue and chroma are untouched: each channel's ratio to its input is the same
    let fixOut = LocalContrast.apply(fix, width: fw, height: fh, detail: 1, radius: 6)
    var e6 = 0.0
    for (p, q) in zip(fixOut, fix) {
        let rx = p.x / q.x, ry = p.y / q.y, rz = p.z / q.z
        e6 = absorb(absorb(e6, abs(rx - ry) / max(1, abs(rx))), abs(rx - rz) / max(1, abs(rx)))
    }
    check("LC6 each channel's ratio to its input is the same on every pixel (hue and chroma kept)", e6.isFinite && e6 < 1e-9, "\(e6)")

    // LC7 finite on the fixture at detail 2 and -1, and black stays black
    var blackIn = fix
    blackIn[0] = SIMD3(0, 0, 0)
    let o2 = LocalContrast.apply(blackIn, width: fw, height: fh, detail: 2, radius: 5)
    let o7 = LocalContrast.apply(blackIn, width: fw, height: fh, detail: -1, radius: 5)
    check("LC7 output is finite at detail 2 and -1, and black stays exactly black",
          finite(LocalContrast.apply(fix, width: fw, height: fh, detail: 2, radius: 5)) && finite(o2) && finite(o7)
          && o2[0] == SIMD3(0, 0, 0) && o7[0] == SIMD3(0, 0, 0))
}

// EQ: the contrast equalizer, wavelet gains on fine, medium and coarse detail of the square-root luminance
do {
    let w = 140, h = 140
    /// A grey image (Y, Y, Y) whose square-root luminance is s(x, y).
    func grey(_ s: (Int, Int) -> Double) -> [SIMD3<Double>] {
        (0..<(w * h)).map { i in let v = s(i % w, i / w); return SIMD3(repeating: v * v) }
    }
    let checker = grey { x, y in (x + y) % 2 == 0 ? 0.4 : 0.6 }
    func wave(_ period: Double, _ amp: Double) -> [SIMD3<Double>] {
        grey { x, _ in 0.5 + amp * sin(2 * Double.pi * Double(x) / period) }
    }
    func sqrtLuma(_ rgb: [SIMD3<Double>]) -> [Double] {
        DetailCommon.sqrtLuminance(rgb, width: w, height: h).values
    }
    /// Population standard deviation over rows and columns 40..<100, output over input.
    func stdRatio(_ input: [SIMD3<Double>], _ output: [SIMD3<Double>]) -> Double {
        func sd(_ v: [Double]) -> Double {
            var vals: [Double] = []
            for y in 40..<100 { for x in 40..<100 { vals.append(v[y * w + x]) } }
            let m = vals.reduce(0, +) / Double(vals.count)
            return sqrt(vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count))
        }
        return sd(sqrtLuma(output)) / sd(sqrtLuma(input))
    }

    // EQ1 all gains 0 is the identity, and a flat colour at +1 on every slider is unchanged (no detail invented)
    let fx = DetailCommon.fixture(width: 48, height: 40)
    /// The largest per-channel difference; a non-finite value is an infinite error.
    func maxDiff(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        zip(a, b).reduce(0.0) { acc, pair in
            let d = pair.0 - pair.1
            return d.x.isFinite && d.y.isFinite && d.z.isFinite ? max(acc, abs(d.x), abs(d.y), abs(d.z)) : .infinity
        }
    }
    let idErr = maxDiff(ContrastEqualizer.apply(fx, width: 48, height: 40, fine: 0, medium: 0, coarse: 0), fx)
    check("EQ1 all gains 0 is the identity on the fixture", idErr < 1e-12, "\(idErr)")
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: 20 * 20)
    let flatOut = ContrastEqualizer.apply(flat, width: 20, height: 20, fine: 1, medium: 1, coarse: 1)
    let flatErr = maxDiff(flatOut, flat)
    check("EQ1 a flat colour at fine = medium = coarse = 1 is unchanged", flatErr < 1e-12, "\(flatErr)")

    // EQ2 the method: the bands of Filters.atrous, grouped and gained as the card says, give the output's square root
    let eq2 = ContrastEqualizer.apply(fx, width: 48, height: 40, fine: 0.5, medium: -0.3, coarse: 0.8)
    let s2 = DetailCommon.sqrtLuminance(fx, width: 48, height: 40)
    let (bands, res) = Filters.atrous(s2, levels: 5)
    var eq2Err = 0.0
    for i in fx.indices where ColorCommon.luminance(fx[i]) > 1e-6 {
        let expect = max(res.values[i] + 1.5 * (bands[0].values[i] + bands[1].values[i]) + 0.7 * (bands[2].values[i] + bands[3].values[i])
                         + 1.8 * bands[4].values[i], 0)
        let got = sqrt(ColorCommon.luminance(eq2[i]))
        eq2Err = got.isFinite ? max(eq2Err, abs(got - expect)) : .infinity
    }
    check("EQ2 the output's square-root luminance is the band formula (fine 0.5, medium -0.3, coarse 0.8)", eq2Err < 1e-9, "\(eq2Err)")

    // EQ3 the 2-pixel checker lives in the finest band, so only fine moves it
    func inCentre(_ i: Int) -> Bool { let x = i % w, y = i / w; return (62...77).contains(x) && (62...77).contains(y) }
    let cs = sqrtLuma(checker)
    let fineUp = sqrtLuma(ContrastEqualizer.apply(checker, width: w, height: h, fine: 1, medium: 0, coarse: 0))
    /// The largest error over the centre pixels; a non-finite output is an infinite error.
    func centreError(_ out: [Double], _ expected: (Int) -> Double) -> Double {
        cs.indices.filter(inCentre).reduce(0.0) { acc, i in
            out[i].isFinite ? max(acc, abs(out[i] - expected(i))) : .infinity
        }
    }
    let fineErr = centreError(fineUp) { 0.5 + 2 * (cs[$0] - 0.5) }
    check("EQ3 fine = +1 doubles the checker about 0.5", fineErr < 1e-9, "\(fineErr)")
    let otherUp = sqrtLuma(ContrastEqualizer.apply(checker, width: w, height: h, fine: 0, medium: 1, coarse: 1))
    let otherErr = centreError(otherUp) { cs[$0] }
    check("EQ3 medium = coarse = +1 leave the checker unchanged", otherErr < 1e-9, "\(otherErr)")
    let fineDown = sqrtLuma(ContrastEqualizer.apply(checker, width: w, height: h, fine: -1, medium: 0, coarse: 0))
    let downErr = centreError(fineDown) { _ in 0.5 }
    check("EQ3 fine = -1 flattens the checker to 0.5", downErr < 1e-9, "\(downErr)")

    // EQ4 each slider answers its own scale (the card's prototype numbers)
    let coarseOnLong = stdRatio(wave(64, 0.1), ContrastEqualizer.apply(wave(64, 0.1), width: w, height: h, fine: 0, medium: 0, coarse: 1))
    check("EQ4 coarse +1 on a 64-pixel wave gives a std ratio in 1.35...1.65 (\(String(format: "%.3f", coarseOnLong)))",
          (1.35...1.65).contains(coarseOnLong), "\(coarseOnLong)")
    let fineOnLong = stdRatio(wave(64, 0.1), ContrastEqualizer.apply(wave(64, 0.1), width: w, height: h, fine: 1, medium: 0, coarse: 0))
    check("EQ4 fine +1 on a 64-pixel wave gives a std ratio in 0.97...1.08 (\(String(format: "%.3f", fineOnLong)))",
          (0.97...1.08).contains(fineOnLong), "\(fineOnLong)")
    let fineOnShort = stdRatio(wave(8, 0.05), ContrastEqualizer.apply(wave(8, 0.05), width: w, height: h, fine: 1, medium: 0, coarse: 0))
    check("EQ4 fine +1 on an 8-pixel wave gives a std ratio in 1.65...1.95 (\(String(format: "%.3f", fineOnShort)))",
          (1.65...1.95).contains(fineOnShort), "\(fineOnShort)")
    let coarseOnShort = stdRatio(wave(8, 0.05), ContrastEqualizer.apply(wave(8, 0.05), width: w, height: h, fine: 0, medium: 0, coarse: 1))
    check("EQ4 coarse +1 on an 8-pixel wave gives a std ratio in 0.99...1.01 (\(String(format: "%.4f", coarseOnShort)))",
          (0.99...1.01).contains(coarseOnShort), "\(coarseOnShort)")
    let mediumOn16 = stdRatio(wave(16, 0.05), ContrastEqualizer.apply(wave(16, 0.05), width: w, height: h, fine: 0, medium: 1, coarse: 0))
    check("EQ4 medium +1 on a 16-pixel wave gives a std ratio in 1.55...1.80 (\(String(format: "%.3f", mediumOn16)))",
          (1.55...1.80).contains(mediumOn16), "\(mediumOn16)")
    let coarseOn16 = stdRatio(wave(16, 0.05), ContrastEqualizer.apply(wave(16, 0.05), width: w, height: h, fine: 0, medium: 0, coarse: 1))
    check("EQ4 coarse +1 on a 16-pixel wave gives a std ratio in 0.99...1.02 (\(String(format: "%.4f", coarseOn16)))",
          (0.99...1.02).contains(coarseOn16), "\(coarseOn16)")

    // EQ5 hue and chroma are untouched: every channel is scaled by the same gain
    let eq5 = ContrastEqualizer.apply(fx, width: 48, height: 40, fine: 0.5, medium: 0.5, coarse: 0.5)
    var eq5Err = 0.0
    for (o, i) in zip(eq5, fx) {
        let r0 = o.x / i.x
        for c in 1..<3 {
            let rc = o[c] / i[c]
            let rel = rc.isFinite && r0.isFinite ? abs(rc - r0) / max(abs(r0), 1e-12) : .infinity
            eq5Err = max(eq5Err, rel)
        }
    }
    check("EQ5 each channel is scaled by the same gain (hue and chroma unchanged)", eq5Err < 1e-9, "\(eq5Err)")

    // EQ6 finite at both extremes, and black stays black
    let up = ContrastEqualizer.apply(fx, width: 48, height: 40, fine: 1, medium: 1, coarse: 1)
    let down = ContrastEqualizer.apply(fx, width: 48, height: 40, fine: -1, medium: -1, coarse: -1)
    check("EQ6 the output is finite at +1 and at -1 on every slider", up.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
          && down.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    let black = [SIMD3<Double>](repeating: SIMD3(0, 0, 0), count: 16 * 16)
    let blackOut = ContrastEqualizer.apply(black, width: 16, height: 16, fine: 1, medium: -1, coarse: 1)
    check("EQ6 black stays exactly (0, 0, 0)", blackOut.allSatisfy { $0 == SIMD3(0, 0, 0) })
}

// NR: wavelet noise reduction. Each fixture's signs come from a 64-bit LCG started at state 1, one draw per sign.
do {
    func signs(_ count: Int) -> [Double] {
        var state: UInt64 = 1
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 63 == 1 ? 1 : -1
        }
    }
    /// The largest per-channel difference; a non-finite value or a length mismatch is an infinite error.
    func maxDiff(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        guard a.count == b.count else { return .infinity }
        var m = 0.0
        for (p, q) in zip(a, b) {
            for c in 0..<3 {
                let d = abs(p[c] - q[c])
                guard d.isFinite else { return .infinity }
                m = max(m, d)
            }
        }
        return m
    }
    /// `max(acc, term)` that keeps a non-finite term: `max` would return `acc` for a NaN term and lose the NaN.
    func maxFinite(_ acc: Double, _ term: Double) -> Double { term.isFinite ? max(acc, term) : .infinity }
    func popStd(_ v: [Double]) -> Double {
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)).squareRoot()
    }
    let w = 48, h = 40
    let img = DetailCommon.fixture(width: w, height: h)

    // NR1 identity: both strengths 0 on the fixture; a flat colour at full strength is unchanged
    let idZero = NoiseReduction.apply(img, width: w, height: h, luma: 0, chroma: 0)
    check("NR1 luma 0 and chroma 0 return the fixture unchanged", maxDiff(idZero, img) < 1e-12, "\(maxDiff(idZero, img))")
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: 16 * 16)
    let flatOut = NoiseReduction.apply(flat, width: 16, height: 16, luma: 1, chroma: 1)
    check("NR1 a flat colour at luma 1, chroma 1 is unchanged", maxDiff(flatOut, flat) < 1e-12, "\(maxDiff(flatOut, flat))")

    // NR2 the band constants: 256 by 256 white noise, population std of bands 0...3 away from the edges
    let n = 256
    let white = Plane(width: n, height: n, values: signs(n * n))
    let (bands, _) = Filters.atrous(white, levels: 4)
    for j in 0..<4 {
        var inner: [Double] = []
        for y in 40..<(n - 40) { for x in 40..<(n - 40) { inner.append(bands[j].values[y * n + x]) } }
        let sd = popStd(inner), want = NoiseReduction.bandNoise[j]
        let rel = abs(sd - want) / want
        check("NR2 band \(j) std of unit white noise is \(String(format: "%.4f", sd)), constant \(want), within 8%",
              rel < 0.08, "\(sd)")
    }

    // the two fixtures of the card: lumaNoise is grey with s = 0.5 + 0.03 sign; chromaNoise is 0.25 (1 + 0.1 sign) per channel
    let ln = 64
    let lumaS = signs(ln * ln).map { 0.5 + 0.03 * $0 }
    let lumaImg = lumaS.map { SIMD3<Double>(repeating: $0 * $0) }
    let csigns = signs(3 * ln * ln)
    let chromaImg = (0..<(ln * ln)).map { i in
        SIMD3<Double>(0.25 * (1 + 0.1 * csigns[3 * i]), 0.25 * (1 + 0.1 * csigns[3 * i + 1]), 0.25 * (1 + 0.1 * csigns[3 * i + 2]))
    }

    // NR3 luminance noise goes and the grey stays grey
    let lumaOut = NoiseReduction.apply(lumaImg, width: ln, height: ln, luma: 0.3, chroma: 0)
    let sOut = lumaOut.map { ColorCommon.luminance($0).squareRoot() }
    let sStd = popStd(sOut) / 0.03
    check("NR3 output s has std \(String(format: "%.4f", sStd)) x the noise (under 0.1; the card expects 0.035)", sStd < 0.1, "\(sStd)")
    let spread = lumaOut.reduce(0.0) { maxFinite(maxFinite($0, abs($1.x - $1.y)), abs($1.y - $1.z)) }
    check("NR3 the grey stays grey (all channels equal within 1e-12)", spread < 1e-12, "\(spread)")

    // NR4 shrinkage is bounded by the sum of the thresholds
    let lumaOut1 = NoiseReduction.apply(lumaImg, width: ln, height: ln, luma: 0.1, chroma: 0)
    var maxMove = 0.0
    for (o, s) in zip(lumaOut1, lumaS) { maxMove = maxFinite(maxMove, abs(ColorCommon.luminance(o).squareRoot() - s)) }
    let bound = 3 * 0.1 * 0.1 * (0.890 + 0.201 + 0.086 + 0.041) + 1e-9
    check("NR4 the largest move of s is \(String(format: "%.5f", maxMove)), at most \(String(format: "%.5f", bound))",
          maxMove <= bound, "\(maxMove)")

    // NR5 colour noise goes and brightness stays
    let chromaOut = NoiseReduction.apply(chromaImg, width: ln, height: ln, luma: 0, chroma: 1)
    var lumaErr = 0.0
    for (o, i) in zip(chromaOut, chromaImg) {
        let yo = ColorCommon.luminance(o), yi = ColorCommon.luminance(i)
        lumaErr = maxFinite(lumaErr, abs(yo - yi) / yi)
    }
    check("NR5 the output luminance equals the input luminance (relative error \(lumaErr))", lumaErr < 1e-9, "\(lumaErr)")
    for c in 0..<3 {
        let inRatio = chromaImg.map { $0[c] / ColorCommon.luminance($0) }
        let outRatio = chromaOut.map { $0[c] / ColorCommon.luminance($0) }
        let before = popStd(inRatio), after = popStd(outRatio)
        check("NR5 channel \(c): the ratio std falls from \(String(format: "%.4f", before)) to \(String(format: "%.4f", after)) (under 0.1 times)",
              after < 0.1 * before, "\(after)")
    }

    // NR6 the two stages do not leak into each other
    let lumaChromaOnly = NoiseReduction.apply(lumaImg, width: ln, height: ln, luma: 0, chroma: 1)
    check("NR6a grey with chroma only is unchanged (q = (1, 1, 1) everywhere)", maxDiff(lumaChromaOnly, lumaImg) < 1e-9,
          "\(maxDiff(lumaChromaOnly, lumaImg))")
    let lumaOnly = NoiseReduction.apply(chromaImg, width: ln, height: ln, luma: 1, chroma: 0)
    var ratioErr = 0.0
    for (o, i) in zip(lumaOnly, chromaImg) {
        let yo = ColorCommon.luminance(o), yi = ColorCommon.luminance(i)
        for c in 0..<3 { ratioErr = maxFinite(ratioErr, abs(o[c] / yo - i[c] / yi)) }
    }
    check("NR6b luma only keeps every pixel's ratios (out / Y equals in / Y)", ratioErr < 1e-9, "\(ratioErr)")

    // NR7 the soft threshold
    check("NR7 soft(0.5, 0.2) == 0.3", abs(NoiseReduction.soft(0.5, 0.2) - 0.3) < 1e-12)
    check("NR7 soft(-0.5, 0.2) == -0.3", abs(NoiseReduction.soft(-0.5, 0.2) + 0.3) < 1e-12)
    check("NR7 soft(0.1, 0.2) == 0 and soft(-0.1, 0.2) == 0",
          NoiseReduction.soft(0.1, 0.2) == 0 && NoiseReduction.soft(-0.1, 0.2) == 0)
    check("NR7 soft(0.3, 0) == 0.3", NoiseReduction.soft(0.3, 0) == 0.3)

    // NR8 finite and non-negative at full strength on the fixture (past-white corner, a strong edge), black stays black
    var blackImg = img
    blackImg[0] = SIMD3(0, 0, 0)
    let full = NoiseReduction.apply(blackImg, width: w, height: h, luma: 1, chroma: 1)
    let finite = full.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    let nonNeg = full.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.z >= 0 }
    check("NR8 the output is finite and non-negative at luma 1, chroma 1", finite && nonNeg)
    check("NR8 black stays exactly black", full[0] == SIMD3(0, 0, 0), "\(full[0])")
}

// M: the local-mask plumbing every kind shares (kind 0 = the whole frame; the kinds have their own tests)
do {
    check("M1 ramp: 0 below, 1 above, smooth between, a hard step when the edges meet",
          Mask.ramp(0.2, 0.6, 0.1) == 0 && Mask.ramp(0.2, 0.6, 0.7) == 1 && abs(Mask.ramp(0.2, 0.6, 0.4) - 0.5) < 1e-12
            && Mask.ramp(0.5, 0.5, 0.49) == 0 && Mask.ramp(0.5, 0.5, 0.5) == 1 && Mask.ramp(0.5, 0.2, 0.3) == 0)
    check("M2 a blend without mask_mode 2, or with an unknown kind, is no mask",
          Mask.spec(from: [:]) == nil && Mask.spec(from: ["mask_mode": 1, "mask_kind": 0]) == nil
            && Mask.spec(from: ["mask_mode": 2, "mask_kind": 99]) == nil && Mask.spec(from: ["mask_mode": 2]) == nil)
    let s = Mask.spec(from: ["mask_mode": 2, "mask_kind": 0, "mask_invert": 1, "mask_refine": 6.4, "opacity": 40])
    check("M2 the spec reads kind, invert, refine radius (rounded) and opacity (0...1)",
          s == MaskSpec(kind: 0, invert: true, refineRadius: 6, opacity: 0.4, p: []), "\(String(describing: s))")
    check("M2 opacity is clamped to 0...100 and a negative refine radius to 0",
          Mask.spec(from: ["mask_mode": 2, "mask_kind": 0, "opacity": 250, "mask_refine": -3])?.opacity == 1
            && Mask.spec(from: ["mask_mode": 2, "mask_kind": 0, "mask_refine": -3])?.refineRadius == 0)
    let w = 24, h = 20
    let img = DetailCommon.fixture(width: w, height: h)
    let full = Mask.plane(MaskSpec(kind: 0), rgb: img, width: w, height: h)
    check("M3 the whole-frame mask is 1 everywhere; inverted it is 0 everywhere",
          full.values.allSatisfy { $0 == 1 }
            && Mask.plane(MaskSpec(kind: 0, invert: true), rgb: img, width: w, height: h).values.allSatisfy { $0 == 0 })
    let refined = Mask.plane(MaskSpec(kind: 0, refineRadius: 4), rgb: img, width: w, height: h)
    check("M3 refining a constant mask leaves it constant", refined.values.allSatisfy { abs($0 - 1) < 1e-9 })
    let after = img.map { $0 * 2 }
    var mix = 0.0
    for (i, o) in Mask.blend(before: img, after: after, mask: full, opacity: 0.25).enumerated() {
        for c in 0..<3 { let want = img[i][c] * 1.25; mix = o[c].isFinite ? max(mix, abs(o[c] - want)) : .infinity }
    }
    check("M4 blend: before + (after - before) * opacity * mask", mix < 1e-12, "\(mix)")
    let half = Plane(width: w, height: h, values: (0..<(w * h)).map { $0 % 2 == 0 ? 1 : 0 })
    let part = Mask.blend(before: img, after: after, mask: half, opacity: 1)
    check("M4 a mask of 0 keeps the input, a mask of 1 takes the module's output",
          part[0] == after[0] && part[1] == img[1])
}

// M5: a hostile or corrupt sidecar cannot crash or exhaust the mask parser
do {
    let huge = Mask.spec(from: ["mask_mode": 2, "mask_kind": 0, "mask_refine": 1e18])
    check("M5 a huge refine radius is clamped to \(Mask.maxRefineRadius)", huge?.refineRadius == Mask.maxRefineRadius, "\(String(describing: huge?.refineRadius))")
    check("M5 a NaN or infinite refine radius is 0, not a trap",
          Mask.spec(from: ["mask_mode": 2, "mask_kind": 0, "mask_refine": .nan])?.refineRadius == 0
            && Mask.spec(from: ["mask_mode": 2, "mask_kind": 0, "mask_refine": .infinity])?.refineRadius == 0)
    check("M5 a NaN, infinite or absurd mask kind is no mask, not a trap",
          Mask.spec(from: ["mask_mode": 2, "mask_kind": .nan]) == nil && Mask.spec(from: ["mask_mode": 2, "mask_kind": .infinity]) == nil
            && Mask.spec(from: ["mask_mode": 2, "mask_kind": 1e300]) == nil)
}

// MG: linear gradient mask (card maskgradient)
do {
    func ga(_ b: [String: Double], _ x: Double, _ y: Double) -> Double {
        MaskGradient.alpha(p: MaskGradient.params(b), x: x, y: y, width: 48, height: 40)
    }
    let hard: [String: Double] = ["mask_angle": 0, "mask_position": 0.5, "mask_feather": 0]
    check("GR1 angle 0 hard edge grows to the right, independent of y",
          [5.0, 35.0].allSatisfy { ga(hard, 23.5, $0) == 0 && ga(hard, 24.5, $0) == 1 } && ga(hard, 0.5, 20) == 0 && ga(hard, 47.5, 20) == 1)
    var h90 = hard; h90["mask_angle"] = 90
    check("GR2 angle 90 grows downward, independent of x",
          [5.0, 40.0].allSatisfy { ga(h90, $0, 19.5) == 0 && ga(h90, $0, 20.5) == 1 })
    let soft: [String: Double] = ["mask_angle": 0, "mask_position": 0.5, "mask_feather": 0.4]
    var mono = true, prev = -1.0
    for i in 0..<48 { let a = ga(soft, Double(i) + 0.5, 20); if a < prev { mono = false }; prev = a }
    check("GR3 feather band centred and the stated width",
          abs(ga(soft, 24.0, 20) - 0.5) < 1e-12 && abs(ga(soft, 11.5036, 20)) < 1e-9 && abs(ga(soft, 36.4964, 20) - 1) < 1e-9 && mono,
          "\(ga(soft, 24, 20)) \(ga(soft, 11.5036, 20)) \(ga(soft, 36.4964, 20)) mono \(mono)")
    var h180 = hard; h180["mask_angle"] = 180
    check("GR4 angle 180 is the mirror of angle 0",
          (0..<48).allSatisfy { ga(h180, Double($0) + 0.5, 20) == 1 - ga(hard, Double($0) + 0.5, 20) })
    var h25 = hard; h25["mask_position"] = 0.25
    check("GR5 position 0.25 puts the edge at x = 8.3795", ga(h25, 7.5, 20) == 0 && ga(h25, 8.5, 20) == 1)
    let pd = MaskGradient.params([:])
    var p90 = MaskGradient.params(["mask_angle": 90])
    check("GR6 keys: defaults, degrees, clamps",
          pd == [0, 0.5, 0.2] && abs(p90[0] - .pi / 2) < 1e-12
          && MaskGradient.params(["mask_position": 1.7])[1] == 1 && MaskGradient.params(["mask_position": -0.3])[1] == 0
          && MaskGradient.params(["mask_feather": 2])[2] == 1 && MaskGradient.params(["mask_feather": -1])[2] == 0, "\(pd)")
    p90 = []
    let rot: [String: Double] = ["mask_angle": 45, "mask_position": 0.5, "mask_feather": 0.3]
    check("GR7 rotation about the frame centre",
          abs(ga(rot, 24, 20) - 0.5) < 1e-12 && abs(ga(rot, 29, 17) + ga(rot, 19, 23) - 1) < 1e-12)
    let g8: [String: Double] = ["mask_angle": 33, "mask_position": 0.4, "mask_feather": 0.5]
    var ok8 = true
    for i in 0..<20 { for j in 0..<20 {
        let a = ga(g8, (Double(i) + 0.5) * 48 / 20, (Double(j) + 0.5) * 40 / 20)
        if !(a.isFinite && a >= 0 && a <= 1) { ok8 = false }
    } }
    check("GR8 finite and within 0...1", ok8)
}

// MaskEllipse (EL1...EL8): frame 48 by 40, D = hypot(48, 40)
do {
    let W = 48.0, H = 40.0, D = hypot(W, H)
    func el(_ b: [String: Double], _ x: Double, _ y: Double) -> Double {
        MaskEllipse.alpha(p: MaskEllipse.params(b), x: x, y: y, width: W, height: H)
    }
    let d0 = el([:], 24, 20), d1 = el([:], 0.5, 0.5)
    check("EL1 centre is 1, far corner is 0", d0 == 1 && d1 == 0, "centre \(d0), corner \(d1)")

    let hard: [String: Double] = ["mask_rx": 0.2, "mask_ry": 0.1, "mask_feather": 0]
    let hx = (el(hard, 24 + 12.4, 20), el(hard, 24 + 12.6, 20)), hy = (el(hard, 24, 20 + 6.2), el(hard, 24, 20 + 6.3))
    check("EL2 hard edge on the axes (rx, ry in diagonals)", hx == (1, 0) && hy == (1, 0), "x \(hx), y \(hy)")

    let fe: [String: Double] = ["mask_rx": 0.2, "mask_ry": 0.2, "mask_feather": 0.5]
    let f75 = el(fe, 24 + 0.2 * D * 0.75, 20), f50 = el(fe, 24 + 0.2 * D * 0.5, 20), f100 = el(fe, 24 + 0.2 * D, 20)
    check("EL3 feather fades inward from the edge", abs(f75 - 0.5) < 1e-9 && abs(f50 - 1) < 1e-12 && abs(f100) < 1e-9,
          "r.75 \(f75), r.5 \(f50), r1 \(f100)")

    func rot(_ deg: Double) -> [String: Double] { ["mask_rx": 0.3, "mask_ry": 0.1, "mask_feather": 0, "mask_rotation": deg] }
    let a45 = (el(rot(45), 34, 30), el(rot(45), 34, 10)), m45 = (el(rot(-45), 34, 30), el(rot(-45), 34, 10))
    check("EL4 rotation sign", a45 == (1, 0) && m45 == (0, 1), "45 \(a45), -45 \(m45)")

    let ck: [String: Double] = ["mask_cx": 0.25, "mask_cy": 0.75, "mask_rx": 0.2, "mask_ry": 0.2]
    let c1 = el(ck, 12, 30), c2 = el(ck, 36, 10)
    check("EL5 centre keys", c1 == 1 && c2 == 0, "centre \(c1), far \(c2)")

    let pd = MaskEllipse.params([:])
    let pz = MaskEllipse.params(["mask_rx": 0]), pr = MaskEllipse.params(["mask_rotation": 90])
    let pf = MaskEllipse.params(["mask_feather": 3]), pc = MaskEllipse.params(["mask_cx": -2])
    check("EL6 keys, defaults and clamps",
          pd == [0.5, 0.5, 0.25, 0.25, 0, 0.2] && pz[2] == 1e-4 && abs(pr[4] - Double.pi / 2) < 1e-12 && pf[5] == 1 && pc[0] == 0,
          "defaults \(pd), rx0 \(pz[2]), rot90 \(pr[4]), feather3 \(pf[5]), cx-2 \(pc[0])")

    let sym: [String: Double] = ["mask_rotation": 30, "mask_feather": 0.4]
    var symErr = 0.0
    for d in [(4.0, 7.0), (-9.0, 2.0)] { symErr = max(symErr, abs(el(sym, 24 + d.0, 20 + d.1) - el(sym, 24 - d.0, 20 - d.1))) }
    check("EL7 point symmetry about the centre", symErr < 1e-12, "worst \(symErr)")

    var ok = true
    for b in [[String: Double](), ["mask_rx": 0, "mask_rotation": 33, "mask_feather": 0.3]] {
        for i in 0..<20 { for j in 0..<20 {
            let a = el(b, (Double(i) + 0.5) * W / 20, (Double(j) + 0.5) * H / 20)
            if !(a.isFinite && a >= 0 && a <= 1) { ok = false }
        } }
    }
    check("EL8 finite, within 0...1, no NaN at the radius floor", ok)
}

// LU: luminance range mask
do {
    func grey(_ s: Double) -> SIMD3<Double> { SIMD3(repeating: s * s) }
    func a(_ low: Double, _ high: Double, _ f: Double, _ rgb: SIMD3<Double>) -> Double {
        MaskLuminance.alpha(p: MaskLuminance.params(["mask_low": low, "mask_high": high, "mask_feather": f]), rgb: rgb)
    }
    check("LU1 hard window: 0.29 out, 0.31 in, 0.69 in, 0.71 out",
          a(0.3, 0.7, 0, grey(0.29)) == 0 && a(0.3, 0.7, 0, grey(0.31)) == 1 && a(0.3, 0.7, 0, grey(0.69)) == 1 && a(0.3, 0.7, 0, grey(0.71)) == 0)
    let l275 = a(0.2, 0.8, 0.5, grey(0.275)), l5 = a(0.2, 0.8, 0.5, grey(0.5)), l725 = a(0.2, 0.8, 0.5, grey(0.725))
    let l2 = a(0.2, 0.8, 0.5, grey(0.2)), l8 = a(0.2, 0.8, 0.5, grey(0.8))
    check("LU2 feather ramps sit inside the window (0.275 and 0.725 are half, 0.5 is 1, the ends 0)",
          abs(l275 - 0.5) < 1e-9 && abs(l5 - 1) < 1e-12 && abs(l725 - 0.5) < 1e-9 && abs(l2) < 1e-9 && abs(l8) < 1e-9,
          "\(l275) \(l5) \(l725) \(l2) \(l8)")
    let col = SIMD3<Double>(0.5, 0.2, 0.1), gy = grey(sqrt(0.2126 * 0.5 + 0.7152 * 0.2 + 0.0722 * 0.1))
    let d1 = abs(a(0.45, 0.55, 0, col) - a(0.45, 0.55, 0, gy)), d2 = abs(a(0.2, 0.8, 0.5, col) - a(0.2, 0.8, 0.5, gy))
    check("LU3 it is Rec.709 luminance, not a channel", max(d1, d2) < 1e-12 && a(0.45, 0.55, 0, col) == 1, "\(d1) \(d2)")
    check("LU4 the window is on sqrt(Y): Y 0.25 in, Y 0.1 out, Y 0.5 out",
          a(0.4, 0.6, 0, SIMD3(repeating: 0.25)) == 1 && a(0.4, 0.6, 0, SIMD3(repeating: 0.1)) == 0 && a(0.4, 0.6, 0, SIMD3(repeating: 0.5)) == 0)
    let pd = MaskLuminance.params([:]), ps = MaskLuminance.params(["mask_low": 0.8, "mask_high": 0.2])
    check("LU5 keys: defaults, swap, feather clamp, low clamp",
          pd == [0.2, 0.8, 0.25] && ps[0] == 0.2 && ps[1] == 0.8 && MaskLuminance.params(["mask_feather": 5])[2] == 1
          && MaskLuminance.params(["mask_low": -1])[0] == 0, "\(pd) \(ps)")
    let blk = SIMD3<Double>(0, 0, 0), neg = SIMD3<Double>(-1, -1, -1), wht = SIMD3<Double>(9, 9, 9)
    let nv = a(0, 0.5, 0, neg)
    check("LU6 extremes: black, negative treated as black, past white",
          a(0, 0.5, 0, blk) == 1 && a(0.2, 0.8, 0, blk) == 0 && nv.isFinite && nv == a(0, 0.5, 0, blk)
          && a(0.2, 0.8, 0, wht) == 0 && a(0.2, 4, 0, wht) == 1)
    var up = true, down = true, prevU = -1.0, prevD = 2.0
    for k in 0...15 {
        let u = a(0.2, 0.8, 0.5, grey(0.2 + 0.01 * Double(k)))
        if u < prevU { up = false }
        prevU = u
        let dn = a(0.2, 0.8, 0.5, grey(0.65 + 0.01 * Double(k)))
        if dn > prevD { down = false }
        prevD = dn
    }
    check("LU7 the rising ramp never decreases, the falling ramp never increases", up && down && prevU > 0.99 && prevD < 1e-9)
    let fx = DetailCommon.fixture(width: 48, height: 40), pdef = MaskLuminance.params([:])
    let av = fx.map { MaskLuminance.alpha(p: pdef, rgb: $0) }
    check("LU8 finite and within 0...1 on the detail fixture", av.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
}


// CO: the colour range mask (kind 4)
do {
    func col(_ L: Double, _ C: Double, _ hDeg: Double) -> SIMD3<Double> {
        let h = hDeg * .pi / 180
        return OkLab.toWorking(SIMD3(L, C * cos(h), C * sin(h)))
    }
    func a(_ b: [String: Double], _ c: SIMD3<Double>) -> Double { MaskColour.alpha(p: MaskColour.params(b), rgb: c) }
    let hard: [String: Double] = ["mask_hue": 30, "mask_hue_width": 20, "mask_chroma_min": 0.02, "mask_feather": 0]
    check("CO1 hue window, hard: 1 inside the half-width, 0 outside on both sides",
          a(hard, col(0.6, 0.1, 30)) == 1 && a(hard, col(0.6, 0.1, 45)) == 1
            && a(hard, col(0.6, 0.1, 55)) == 0 && a(hard, col(0.6, 0.1, 5)) == 0)
    let wrap: [String: Double] = ["mask_hue": 350, "mask_hue_width": 30, "mask_chroma_min": 0.02, "mask_feather": 0]
    check("CO2 the hue difference wraps around 360 degrees",
          a(wrap, col(0.6, 0.1, 10)) == 1 && a(wrap, col(0.6, 0.1, 40)) == 0)
    let fe: [String: Double] = ["mask_hue": 30, "mask_hue_width": 40, "mask_chroma_min": 0.02, "mask_feather": 0.5]
    let f1 = a(fe, col(0.6, 0.1, 50)), f2 = a(fe, col(0.6, 0.1, 60)), f3 = a(fe, col(0.6, 0.1, 70))
    check("CO3 feather fades inward from the half-width edge (1 at dh 20, 0.5 at 30, 0 at 40)",
          abs(f1 - 1) < 1e-9 && abs(f2 - 0.5) < 1e-9 && abs(f3) < 1e-9, "\(f1) \(f2) \(f3)")
    let ch: [String: Double] = ["mask_hue": 30, "mask_hue_width": 90, "mask_chroma_min": 0.02, "mask_feather": 0]
    var chf = ch; chf["mask_feather"] = 0.5
    let c15 = a(chf, col(0.6, 0.015, 30))
    check("CO4 chroma floor: below is 0, above is 1, feathered middle is 0.5, exact grey is 0",
          a(ch, col(0.6, 0.01, 30)) == 0 && a(ch, col(0.6, 0.03, 30)) == 1 && abs(c15 - 0.5) < 1e-9
            && a(ch, SIMD3(0.3, 0.3, 0.3)) == 0, "\(c15)")
    let lt: [String: Double] = ["mask_hue": 30, "mask_hue_width": 20, "mask_chroma_min": 0.02, "mask_feather": 0.5]
    let l1 = a(lt, col(0.2, 0.1, 30)), l2 = a(lt, col(0.6, 0.1, 30)), l3 = a(lt, col(0.9, 0.1, 30))
    check("CO5 lightness is ignored", abs(l1 - l2) < 1e-9 && abs(l2 - l3) < 1e-9, "\(l1) \(l2) \(l3)")
    let d = MaskColour.params([:])
    let dWant = [30 * Double.pi / 180, 30 * Double.pi / 180, 0.02, 0.3]
    check("CO6 the keys: defaults and clamps",
          zip(d, dWant).allSatisfy { abs($0 - $1) < 1e-12 } && d.count == 4
            && abs(MaskColour.params(["mask_hue_width": 400])[1] - Double.pi) < 1e-12
            && abs(MaskColour.params(["mask_hue_width": 0])[1] - Double.pi / 180) < 1e-12
            && MaskColour.params(["mask_chroma_min": -1])[2] == 0 && MaskColour.params(["mask_chroma_min": 2])[2] == 0.5
            && MaskColour.params(["mask_feather": 9])[3] == 1)
    var fin = true
    for floor in [0.0, 0.02] {
        let b: [String: Double] = ["mask_chroma_min": floor]
        for c in [SIMD3(0.0, 0, 0), SIMD3(4.0, 3, 2), SIMD3(-0.2, 0.1, 0.3)] {
            let v = a(b, c)
            if !(v.isFinite && v >= 0 && v <= 1) { fin = false }
        }
    }
    check("CO7 extremes (black, past white, negative) give a finite alpha within 0...1", fin)
    let g = a(["mask_hue": 0, "mask_hue_width": 179, "mask_chroma_min": 0], SIMD3(0.3, 0.3, 0.3))
    check("CO8 a chroma floor of 0 does not exclude greys, and a grey's undefined hue gives no NaN",
          g.isFinite && g >= 0 && g <= 1, "\(g)")
}

// S6 review additions: points where the right rule and the wrong one give different answers
do {
    let W = 48.0, H = 40.0, D = (W * W + H * H).squareRoot()
    func alpha(_ blend: [String: Double], x: Double = 24, y: Double = 20, rgb: SIMD3<Double> = SIMD3(0.3, 0.3, 0.3)) -> Double {
        Mask.alpha(Mask.spec(from: blend.merging(["mask_mode": 2]) { $1 })!, x: x, y: y, width: W, height: H, rgb: rgb)
    }
    func close(_ a: Double, _ b: Double, _ e: Double = 1e-9) -> Bool { a.isFinite && abs(a - b) < e }
    // a smoothstep is 0.15625 a quarter of the way up (a linear ramp would say 0.25)
    let gq = alpha(["mask_kind": 1, "mask_angle": 0, "mask_position": 0.5, "mask_feather": 0.4], x: 24 + (0.4 - 0.5) * D)
    check("MR1 gradient: a quarter of the way up the soft band is the smoothstep 0.15625, not 0.25", close(gq, 0.15625), "\(gq)")
    let eq = alpha(["mask_kind": 2, "mask_rx": 0.2, "mask_ry": 0.2, "mask_feather": 0.5], x: 24 + 0.625 * 0.2 * D)
    check("MR2 ellipse: r = 0.625 in the fade is 1 - 0.15625", close(eq, 0.84375), "\(eq)")
    func grey(_ s: Double) -> SIMD3<Double> { SIMD3(repeating: s * s) }
    let lq = alpha(["mask_kind": 3, "mask_low": 0.2, "mask_high": 0.8, "mask_feather": 0.5], rgb: grey(0.2375))
    check("MR3 luminance: a quarter of the way up the soft ramp is 0.15625", close(lq, 0.15625), "\(lq)")
    func col(_ L: Double, _ C: Double, _ hDeg: Double) -> SIMD3<Double> {
        let h = hDeg * .pi / 180
        return OkLab.toWorking(SIMD3(L, C * cos(h), C * sin(h)))
    }
    let cq = alpha(["mask_kind": 4, "mask_hue": 30, "mask_hue_width": 40, "mask_chroma_min": 0.02, "mask_feather": 0.5], rgb: col(0.6, 0.1, 55))
    check("MR4 colour: dh 25 in the 20...40 fade is 1 - 0.15625", close(cq, 0.84375), "\(cq)")
    // the luminance is the working space's (Rec.2020 weights): (0.5, 0.2, 0.1) is s = sqrt(Y); Rec.709 (0.5065), the channel mean (0.5164) and
    // Rec.601 (0.5276) are all more than 0.005 away, so a narrow window around the right s catches any of them
    let sYes = ColorCommon.luminance(SIMD3(0.5, 0.2, 0.1)).squareRoot()
    let inWindow = alpha(["mask_kind": 3, "mask_low": sYes - 0.002, "mask_high": sYes + 0.002, "mask_feather": 0], rgb: SIMD3(0.5, 0.2, 0.1))
    let belowWindow = alpha(["mask_kind": 3, "mask_low": sYes + 0.003, "mask_high": 0.9, "mask_feather": 0], rgb: SIMD3(0.5, 0.2, 0.1))
    let others = [0.5065, 0.5164, 0.5276].allSatisfy { abs($0 - sYes) > 0.005 }
    check("MR5 luminance mask uses the working space's weights (a window around s = \(String(format: "%.4f", sYes)) holds it; Rec.709, Rec.601 and the mean are outside)",
          inWindow == 1 && belowWindow == 0 && others, "in \(inWindow), below \(belowWindow), others apart \(others)")
    // lightness must not leak into the colour weight: inside both soft bands the answer is 0.25 at every lightness
    let leaks = [0.2, 0.6, 0.9].map {
        alpha(["mask_kind": 4, "mask_hue": 30, "mask_hue_width": 20, "mask_chroma_min": 0.02, "mask_feather": 0.5], rgb: col($0, 0.015, 45))
    }
    check("MR6 colour mask: inside both soft bands the weight is 0.25 at every lightness", leaks.allSatisfy { close($0, 0.25) }, "\(leaks)")
}

// DF / DH: the minimum filter and haze removal (dark channel prior)
do {
    let w = 40, h = 30
    let tex = Plane(width: w, height: h, values: (0..<(w * h)).map { i in
        let x = Double(i % w), y = Double(i / w)
        return 0.4 + 0.25 * sin(x / 3.1) * cos(y / 4.7) + 0.05 * sin(x * 12.9898 + y * 78.233)
    })
    let r = 3, fast = Filters.minFilter(tex, radius: r)
    var worst = 0.0
    for y in 0..<h { for x in 0..<w {
        var m = Double.infinity
        for dy in -r...r { for dx in -r...r { m = min(m, tex.at(x + dx, y + dy)) } }
        let d = abs(m - fast.values[y * w + x])
        worst = d.isFinite ? max(worst, d) : .infinity
    } }
    check("DF1 min filter equals the brute-force window minimum, edges clamped", worst < 1e-15, "\(worst)")
    check("DF1 min filter radius 0 is the identity and never exceeds the input", Filters.minFilter(tex, radius: 0) == tex
          && zip(fast.values, tex.values).allSatisfy { $0 <= $1 })

    func close(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>], _ tol: Double) -> Double {
        guard a.count == b.count else { return .infinity }
        var e = 0.0
        for (x, y) in zip(a, b) { for c in 0..<3 { e = x[c].isFinite ? max(e, abs(x[c] - y[c]) / max(1, abs(y[c]))) : .infinity } }
        return e
    }
    let fw = 48, fh = 40
    let base = DetailCommon.fixture(width: fw, height: fh)
    check("DH1 strength 0 is the identity", Dehaze.apply(base, width: fw, height: fh, strength: 0, radius: 8, airlight: 1) == base)
    // a clear scene whose every pixel has a zero channel (dark channel 0), hazed with transmission 0.6 and airlight 1
    let clear = base.map { c -> SIMD3<Double> in let d = c - SIMD3(repeating: min(c.x, c.y, c.z)); return SIMD3(min(d.x, 1), min(d.y, 1), min(d.z, 1)) }   // a haze-free scene is no brighter than the airlight
    let hazy = clear.map { $0 * 0.6 + SIMD3(repeating: 0.4) }
    let rec = close(Dehaze.apply(hazy, width: fw, height: fh, strength: 1, radius: 3, airlight: 1), clear, 1e-9)
    check("DH2 haze with transmission 0.6 is removed exactly (dark channel prior recovers it)", rec < 1e-9, "\(rec)")
    let half = hazy.map { ($0 - SIMD3(repeating: 1)) / 0.8 + SIMD3(repeating: 1) }
    let hs = close(Dehaze.apply(hazy, width: fw, height: fh, strength: 0.5, radius: 3, airlight: 1), half, 1e-9)
    check("DH3 strength 0.5 removes half the haze: t = 1 - 0.5 * 0.4 = 0.8", hs < 1e-9, "\(hs)")
    let hazy2 = clear.map { $0 * 0.5 + SIMD3(repeating: 1) }
    let rec2 = close(Dehaze.apply(hazy2, width: fw, height: fh, strength: 1, radius: 3, airlight: 2), clear, 1e-9)
    let wrongA = close(Dehaze.apply(hazy2, width: fw, height: fh, strength: 1, radius: 3, airlight: 1), clear, 1e-9)
    check("DH4 airlight 2 recovers a scene hazed with airlight 2", rec2 < 1e-9, "\(rec2)")
    check("DH4 airlight 1 does not (the airlight is used)", wrongA > 0.05, "\(wrongA)")
    // t below the 0.1 floor: dark channel 0.95, strength 1 gives t = 0.05, floored to 0.1: (0.95 - 1) / 0.1 + 1 = 0.5 (no floor: 0)
    let nearAir = Dehaze.apply([SIMD3<Double>](repeating: SIMD3(repeating: 0.95), count: fw * fh), width: fw, height: fh, strength: 1, radius: 3, airlight: 1)
    check("DH5 the transmission floor 0.1 holds: (0.95 - 1) / 0.1 + 1 = 0.5",
          nearAir.allSatisfy { abs($0.x - 0.5) < 1e-9 && abs($0.y - 0.5) < 1e-9 && abs($0.z - 0.5) < 1e-9 }, "\(nearAir[0])")
    let atAir = Dehaze.apply([SIMD3<Double>](repeating: SIMD3(repeating: 1), count: fw * fh), width: fw, height: fh, strength: 1, radius: 3, airlight: 1)
    check("DH5 a pixel equal to the airlight stays the airlight (no 0/0)", atAir.allSatisfy { $0 == SIMD3(1, 1, 1) }, "\(atAir[0])")
    // light brighter than the airlight is not haze: it passes through (no (2 - 1) / 0.1 + 1 = 11)
    let lamp = [SIMD3<Double>](repeating: SIMD3(repeating: 2), count: fw * fh)
    let lampOut = Dehaze.apply(lamp, width: fw, height: fh, strength: 0.5, radius: 3, airlight: 1)
    check("DH5b a highlight above the airlight is unchanged by haze removal", lampOut.allSatisfy { abs($0.x - 2) < 1e-9 && abs($0.y - 2) < 1e-9 && abs($0.z - 2) < 1e-9 }, "\(lampOut[0])")
    // a dark scene beside a bright sky: the refined transmission spreads, but nothing goes negative
    let skyEdge = (0..<(fw * fh)).map { i in i % fw < fw / 2 ? SIMD3<Double>(repeating: 2) : SIMD3(0.2, 0.25, 0.3) }
    let skyOut = Dehaze.apply(skyEdge, width: fw, height: fh, strength: 1, radius: 3, airlight: 1)
    check("DH5c next to a bright sky no pixel goes negative or non-finite", skyOut.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.z >= 0 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    var finite = true
    let ext = base + [SIMD3<Double>](repeating: SIMD3(-0.2, 0.1, 0.3), count: fw * 2)
    for (s, rad, a) in [(1.0, 8.0, 0.2), (1.0, 1.0, 4.0), (0.6, 40.0, 1.0), (1.0, 5.0, 0.2)] {
        let out = Dehaze.apply(ext, width: fw, height: fh + 2, strength: s, radius: rad, airlight: a)
        finite = finite && out.count == ext.count && out.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    }
    check("DH6 finite at strength 1, a dim airlight, radius 1 and 40, past-white and negative colours", finite)
}

// MQ masks live in the upright picture: the camera's orientation maps each sensor pixel to where it sits as shot
do {
    func grad(_ o: Orientation, x: Double, y: Double) -> Double {
        var s = Mask.spec(from: ["mask_mode": 2, "mask_kind": 1, "mask_angle": 0, "mask_position": 0.5, "mask_feather": 0])!
        s.orientation = o
        return Mask.alpha(s, x: x, y: y, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3))
    }
    check("MQ1 upright frame: angle 0 grows to the right (sensor x decides)", grad(.none, x: 10.5, y: 5) == 0 && grad(.none, x: 40.5, y: 5) == 1)
    check("MQ1 rotate CW 90 (a portrait shot): the same gradient still grows to the RIGHT of the upright picture, which is sensor y going up",
          grad(.rotateCW90, x: 10.5, y: 39.5) == 0 && grad(.rotateCW90, x: 10.5, y: 0.5) == 1 && grad(.rotateCW90, x: 40.5, y: 0.5) == 1
            && grad(.rotateCW90, x: 40.5, y: 39.5) == 0)
    check("MQ1 rotate CCW 90: growing right is sensor y going down",
          grad(.rotateCCW90, x: 10.5, y: 0.5) == 0 && grad(.rotateCCW90, x: 10.5, y: 39.5) == 1)
    check("MQ1 rotate 180 flips it: growing right is sensor x going left", grad(.rotate180, x: 40.5, y: 5) == 0 && grad(.rotate180, x: 10.5, y: 5) == 1)
    var ell = Mask.spec(from: ["mask_mode": 2, "mask_kind": 2, "mask_rx": 0.1, "mask_ry": 0.1, "mask_feather": 0])!
    ell.orientation = .rotateCW90
    check("MQ1 an ellipse at the centre stays at the centre of a rotated frame, and the far corner stays outside",
          Mask.alpha(ell, x: 24, y: 20, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3)) == 1
            && Mask.alpha(ell, x: 1, y: 1, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3)) == 0)
    // an off-centre ellipse (cx 0.25, cy 0.25 of the UPRIGHT picture): upright 40x48 centre (10, 12) is sensor (12, 40 - 10 = 30) for CW 90
    var off = Mask.spec(from: ["mask_mode": 2, "mask_kind": 2, "mask_cx": 0.25, "mask_cy": 0.25, "mask_rx": 0.05, "mask_ry": 0.05, "mask_feather": 0])!
    off.orientation = .rotateCW90
    check("MQ1 an off-centre ellipse lands where the upright picture puts it (sensor (12, 30) for a CW 90 shot, not (12, 10))",
          Mask.alpha(off, x: 12, y: 30, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3)) == 1
            && Mask.alpha(off, x: 12, y: 10, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3)) == 0)
}

// GF graduated filter: an exposure change through a soft linear gradient
do {
    let w = 48, h = 40
    let flat = [SIMD3<Double>](repeating: SIMD3(0.2, 0.15, 0.1), count: w * h)
    func at(_ img: [SIMD3<Double>], _ x: Int, _ y: Int) -> SIMD3<Double> { img[y * w + x] }
    let up = GraduatedFilter.spec(position: 0.5, angle: -90, feather: 0)
    check("GF1 exposure 0 is the identity", GraduatedFilter.apply(flat, width: w, height: h, ev: 0, spec: up) == flat)
    let out = GraduatedFilter.apply(flat, width: w, height: h, ev: -1, spec: up)
    check("GF2 angle -90 lands on the top: the top row halves per EV, the bottom row is untouched",
          at(out, 24, 0) == SIMD3(0.1, 0.075, 0.05) && at(out, 24, h - 1) == SIMD3(0.2, 0.15, 0.1))
    let down = GraduatedFilter.apply(flat, width: w, height: h, ev: -1, spec: GraduatedFilter.spec(position: 0.5, angle: 90, feather: 0))
    check("GF3 angle 90 lands on the bottom, the opposite side", at(down, 24, h - 1) == SIMD3(0.1, 0.075, 0.05) && at(down, 24, 0) == SIMD3(0.2, 0.15, 0.1))
    let soft = GraduatedFilter.apply(flat, width: w, height: h, ev: -1, spec: GraduatedFilter.spec(position: 0.5, angle: -90, feather: 0.6))
    var rising = true
    for y in 1..<h where at(soft, 24, y).x < at(soft, 24, y - 1).x - 1e-12 { rising = false }
    check("GF4 with a feather the change eases in: values rise monotonically from the filtered side to the clear side and pass through the middle",
          rising && at(soft, 24, 0).x < at(soft, 24, h - 1).x && at(soft, 24, h / 2).x > 0.1 && at(soft, 24, h / 2).x < 0.2)
    let left = GraduatedFilter.apply(flat, width: w, height: h, ev: -1, spec: GraduatedFilter.spec(position: 0.5, angle: 180, feather: 0))
    check("GF5 angle 180 lands on the left", at(left, 0, 20) == SIMD3(0.1, 0.075, 0.05) && at(left, w - 1, 20) == SIMD3(0.2, 0.15, 0.1))
}

// RL radial light: an exposure change through a soft ellipse
do {
    let w = 48, h = 40
    let flat = [SIMD3<Double>](repeating: SIMD3(0.2, 0.15, 0.1), count: w * h)
    func at(_ img: [SIMD3<Double>], _ x: Int, _ y: Int) -> SIMD3<Double> { img[y * w + x] }
    let hard = RadialLight.spec(x: 0.5, y: 0.5, size: 0.2, shape: 1, rotation: 0, feather: 0, outside: false)
    check("RL1 exposure 0 is the identity", RadialLight.apply(flat, width: w, height: h, ev: 0, spec: hard) == flat)
    let lit = RadialLight.apply(flat, width: w, height: h, ev: 1, spec: hard)
    check("RL2 inside the ellipse the light doubles per EV, outside nothing changes",
          at(lit, 24, 20) == SIMD3(0.4, 0.3, 0.2) && at(lit, 0, 0) == SIMD3(0.2, 0.15, 0.1) && at(lit, 47, 39) == SIMD3(0.2, 0.15, 0.1))
    let around = RadialLight.apply(flat, width: w, height: h, ev: 1, spec: RadialLight.spec(x: 0.5, y: 0.5, size: 0.2, shape: 1, rotation: 0, feather: 0, outside: true))
    check("RL3 outside: the centre stays and the surround takes the change", at(around, 24, 20) == SIMD3(0.2, 0.15, 0.1) && at(around, 0, 0) == SIMD3(0.4, 0.3, 0.2))
    // the mix is linear in the matte: gain 1 + (2 - 1) * alpha, read from the oracle's own matte at a feathered pixel
    let soft = RadialLight.spec(x: 0.5, y: 0.5, size: 0.2, shape: 1, rotation: 0, feather: 0.5, outside: false)
    let softLit = RadialLight.apply(flat, width: w, height: h, ev: 1, spec: soft)
    let alpha = Mask.alpha(soft, x: 33.5, y: 20.5, width: Double(w), height: Double(h), rgb: SIMD3(0.2, 0.15, 0.1))
    let got = at(softLit, 33, 20).x, want = 0.2 * (1 + alpha)
    check("RL4 in the feather the change is mixed by the matte (alpha \(String(format: "%.3f", alpha)) is strictly between 0 and 1)",
          alpha > 0.05 && alpha < 0.95 && abs(got - want) < 1e-12, "\(got) vs \(want)")
    let squashed = RadialLight.apply(flat, width: w, height: h, ev: 1, spec: RadialLight.spec(x: 0.5, y: 0.5, size: 0.2, shape: 0.5, rotation: 0, feather: 0, outside: false))
    check("RL5 shape 0.5 halves the height: a pixel 8 up and down is inside the circle but outside the squashed ellipse",
          at(lit, 24, 28).x == 0.4 && at(squashed, 24, 28).x == 0.2 && at(squashed, 33, 20).x == 0.4)
    let fixture = DetailCommon.fixture(width: w, height: h)
    var finite = true
    for ev in [-4.0, 4.0] {
        let out = RadialLight.apply(fixture, width: w, height: h, ev: ev, spec: soft)
        finite = finite && out.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    }
    check("RL6 finite on the textured fixture (past white, near black) at -4 and +4 EV; black stays black",
          finite && RadialLight.apply([SIMD3(0, 0, 0)], width: 1, height: 1, ev: 3, spec: hard) == [SIMD3(0, 0, 0)])
}

// VG vignette: radial light turned inside out. The centre is left alone, the corners take the full change, the fall is smooth and
// symmetric about the centre, and it does not depend on the picture's size
do {
    let w = 64, h = 48
    let flat = [SIMD3<Double>](repeating: SIMD3(0.4, 0.3, 0.2), count: w * h)
    func at(_ img: [SIMD3<Double>], _ x: Int, _ y: Int) -> SIMD3<Double> { img[y * w + x] }
    check("VG1 strength 0 is the identity", Vignette.apply(flat, width: w, height: h, strength: 0, scale: 1) == flat)
    let vg = Vignette.apply(flat, width: w, height: h, strength: 1, scale: 1)
    let centre = at(vg, w / 2, h / 2).x / 0.4, corner = at(vg, 0, 0).x / 0.4, edge = at(vg, 0, h / 2).x / 0.4
    check("VG2 the centre is left alone and the corner takes nearly the full -2 EV (a gain of 0.25)",
          centre > 0.97 && corner < 0.30 && corner >= 0.25 - 1e-9, "centre \(centre), corner \(corner)")
    var falling = true, previous = Double.infinity
    for x in stride(from: w / 2, through: 0, by: -1) { let g = at(vg, x, h / 2).x; falling = falling && g <= previous + 1e-12; previous = g }
    check("VG3 the light only falls from the centre to the left edge, and the centre is lighter than the edge, which is lighter than the corner",
          falling && centre > edge && edge > corner, "centre \(centre), edge \(edge), corner \(corner)")
    var symmetric = true
    for y in 0..<h { for x in 0..<w { symmetric = symmetric && near(at(vg, x, y), at(vg, w - 1 - x, h - 1 - y), 1e-12) } }
    check("VG4 the vignette is symmetric about the picture's centre", symmetric)
    func meanGain(_ scale: Double) -> Double {
        Vignette.apply(flat, width: w, height: h, strength: 1, scale: scale).reduce(0) { $0 + $1.x / 0.4 } / Double(w * h)
    }
    check("VG5 a bigger circle leaves more of the picture alone", meanGain(1.6) > meanGain(1) && meanGain(1) > meanGain(0.6),
          "\(meanGain(0.6)) \(meanGain(1)) \(meanGain(1.6))")
    let allGains = vg.map { $0.x / 0.4 }
    check("VG6 no pixel is lighter than the input or darker than the full -2 EV", allGains.allSatisfy { $0 <= 1 + 1e-9 && $0 >= 0.25 - 1e-9 })
    let corner2 = at(Vignette.apply(flat, width: w, height: h, strength: 2, scale: 1), 0, 0).x / 0.4
    check("VG7 strength 2 darkens the corner more, down to -4 EV (a gain of 0.0625)", corner2 < corner && corner2 >= 0.0625 - 1e-9, "\(corner2)")
    let big = Vignette.apply([SIMD3<Double>](repeating: SIMD3(0.4, 0.3, 0.2), count: 128 * 96), width: 128, height: 96, strength: 1, scale: 1)
    let sameSpot = abs(at(vg, 16, 12).x - big[24 * 128 + 32].x) / 0.4
    check("VG8 the same spot of the picture gets the same gain at twice the size (within 0.02)", sameSpot < 0.02, "\(sameSpot)")
}

// SHD shadows and highlights: the zone exposure's two semantic controls. A dark region lifts and a bright one holds, each by its own gain
// (a global exposure would give both the same), and the sliders map -100...100 to -2...+2 EV
do {
    let w = 64, h = 32
    let darkPx = SIMD3(0.02, 0.018, 0.015), brightPx = SIMD3(0.6, 0.5, 0.4)
    let split = (0..<(w * h)).map { $0 % w < w / 2 ? darkPx : brightPx }
    func gain(_ img: [SIMD3<Double>], at x: Int) -> Double { img[(h / 2) * w + x].x / split[(h / 2) * w + x].x }
    check("SHD1 both sliders at 0 is the identity", Shadhi.apply(split, width: w, height: h, shadows: 0, highlights: 0) == split)
    let both = Shadhi.apply(split, width: w, height: h, shadows: 100, highlights: -50)
    let zones = ZoneExposure.apply(split, width: w, height: h, settings: ZoneExposure.Settings(shadows: 2, highlights: -1))
    check("SHD2 +100 shadows and -50 highlights are +2 EV and -1 EV on the zone exposure", both == zones)
    let lifted = Shadhi.apply(split, width: w, height: h, shadows: 100, highlights: 0)
    check("SHD3 shadows +100 lifts the dark region by over 2.5x and leaves the bright one alone",
          gain(lifted, at: 8) > 2.5 && abs(gain(lifted, at: 56) - 1) < 1e-6, "dark \(gain(lifted, at: 8)), bright \(gain(lifted, at: 56))")
    let held = Shadhi.apply(split, width: w, height: h, shadows: 0, highlights: -100)
    check("SHD4 highlights -100 pulls the bright region below 0.5x and leaves the dark one alone",
          gain(held, at: 56) < 0.5 && abs(gain(held, at: 8) - 1) < 1e-6, "dark \(gain(held, at: 8)), bright \(gain(held, at: 56))")
    // the wrong rule, one global exposure, gives both regions the same gain: SHD3 and SHD4 tell it apart
    check("SHD5 the two regions get different gains (a global exposure would give both the same)", abs(gain(lifted, at: 8) - gain(lifted, at: 56)) > 1)
    let ratio = lifted[(h / 2) * w + 8] / split[(h / 2) * w + 8]
    check("SHD6 colour ratios are kept: every channel scales by the same gain", abs(ratio.x - ratio.y) < 1e-9 && abs(ratio.y - ratio.z) < 1e-9, "\(ratio)")
    let extremes = Shadhi.apply([SIMD3(4, 3, 2), SIMD3(0, 0, 0), SIMD3(0.2, 0.2, 0.2), SIMD3(0.01, 0.01, 0.01)], width: 2, height: 2, shadows: 100, highlights: 100)
    check("SHD7 past white and at black the output is finite", extremes.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(extremes)")
}

// BLM bloom: the highlights, blurred by three box means, added back. Nothing above the knee is no glow; a bright dot lights its surround and
// loses nothing; light only goes up
do {
    let w = 41, h = 41, r = 2.0        // three passes of radius 2 reach 6 px, far from the borders at 20
    let dark = SIMD3<Double>(0.2, 0.15, 0.1)
    var dot = [SIMD3<Double>](repeating: dark, count: w * h)
    dot[20 * w + 20] = SIMD3(3, 3, 3)
    func at(_ img: [SIMD3<Double>], _ x: Int, _ y: Int) -> SIMD3<Double> { img[y * w + x] }
    check("BLM1 strength 0 is the identity", Bloom.apply(dot, width: w, height: h, strength: 0, radius: r) == dot)
    let flat = [SIMD3<Double>](repeating: dark, count: w * h)
    check("BLM2 nothing above the knee gives no glow: a dark picture comes back untouched", Bloom.apply(flat, width: w, height: h, strength: 1, radius: r) == flat)
    let lit = Bloom.apply(dot, width: w, height: h, strength: 0.5, radius: r)
    check("BLM3 beyond the glow's reach (3 x 2 px) a pixel is untouched", at(lit, 0, 0) == dark && at(lit, 20, 27) == dark && at(lit, 27, 20) == dark,
          "\(at(lit, 20, 27)) \(at(lit, 27, 20))")
    var added = 0.0
    for i in lit.indices { added += lit[i].x - dot[i].x }
    check("BLM4 the glow keeps the light it was given: the added light is strength x the dot's light (0.5 x 3)", abs(added - 1.5) < 1e-9, "\(added)")
    var falling = true, previous = Double.infinity
    for x in 20...27 { let g = at(lit, x, 20).x - at(dot, x, 20).x; falling = falling && g <= previous + 1e-12; previous = g }
    check("BLM5 the glow falls away from the dot and is symmetric about it", falling && near(at(lit, 15, 20) - at(dot, 15, 20), at(lit, 25, 20) - at(dot, 25, 20), 1e-12))
    func reach(_ radius: Double) -> Int {
        let out = Bloom.apply(dot, width: w, height: h, strength: 1, radius: radius)
        return (0..<w).filter { out[20 * w + $0].x - dot[20 * w + $0].x > 1e-9 }.count
    }
    check("BLM6 a bigger radius reaches further", reach(1) < reach(2) && reach(2) < reach(3), "\(reach(1)) \(reach(2)) \(reach(3))")
    check("BLM7 light only goes up", zip(lit, dot).allSatisfy { $0.x >= $1.x && $0.y >= $1.y && $0.z >= $1.z })
    check("BLM8 the glow is on the colour of the highlight: a red dot lights its surround red",
          { let red = Bloom.apply([SIMD3<Double>](repeating: .zero, count: w * h).enumerated().map { $0.offset == 20 * w + 20 ? SIMD3(3, 0.1, 0.1) : $0.element },
                                  width: w, height: h, strength: 1, radius: r)
            let p = at(red, 22, 20); return p.x > 0.01 && p.y < p.x * 0.2 }())
    check("BLM9 the size sets the radius, fractional: 30 px is 10 per pass, 1 px is a third, 0 and NaN are none",
          Bloom.radius(size: 30) == 10 && abs(Bloom.radius(size: 1) - 1.0 / 3) < 1e-12 && Bloom.radius(size: 0) == 0 && Bloom.radius(size: .nan) == 0)
    let extremes = Bloom.apply([SIMD3(4, 3, 2), SIMD3(0, 0, 0), SIMD3(0.9, 0.9, 0.9), SIMD3(100, 100, 100)], width: 2, height: 2, strength: 1, radius: 1)
    check("BLM10 past white and at black the output is finite", extremes.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(extremes)")
}

// CL clipping warning: blown and crushed by the 8-bit encode, the rule the histogram readout counts
do {
    func enc(_ v: Double) -> Double { Transfer.srgbToLinear(v / 255) }
    check("CL1 a channel that encodes to 255 is blown, to 254 is not; 0 is crushed, 1 is not",
          Clipping.state(SIMD3(enc(255), 0.5, 0.5)) == .blown && Clipping.state(SIMD3(enc(254), 0.5, 0.5)) == .fine
            && Clipping.state(SIMD3(0.5, enc(0), 0.5)) == .crushed && Clipping.state(SIMD3(0.5, enc(1), 0.5)) == .fine)
    check("CL1 past white (scene values above 1) is blown; negative is crushed",
          Clipping.state(SIMD3(3, 0.2, 0.2)) == .blown && Clipping.state(SIMD3(-0.1, 0.2, 0.2)) == .crushed)
    check("CL2 blown wins when a pixel is both: pure red (1, 0, 0)", Clipping.state(SIMD3(1, 0, 0)) == .blown)
    let mid = SIMD3(0.3, 0.4, 0.5)
    check("CL3 a pixel that is neither keeps its colour exactly", Clipping.tint(mid) == mid)
    let b = Clipping.tint(SIMD3(1.5, 0.5, 0.5)), c = Clipping.tint(SIMD3(0, 0.5, 0.5))
    check("CL3 the tint is an 85% mix toward red for blown (\(b)) and blue for crushed (\(c))",
          abs(b.x - (1.5 + (1 - 1.5) * 0.85)) < 1e-12 && abs(b.y - (0.5 + (0.1 - 0.5) * 0.85)) < 1e-12
            && abs(c.z - (0.5 + (1 - 0.5) * 0.85)) < 1e-12 && abs(c.x - (0 + 0.15 * 0.85)) < 1e-12)
    // the count the histogram makes (a channel at 255 / at 0 on an 8-bit frame) equals the count of this rule on the same values
    var agree = true
    for r in stride(from: 0, through: 255, by: 5) { for g in stride(from: 0, through: 255, by: 51) { for bl in [0, 1, 128, 254, 255] {
        let lin = SIMD3(enc(Double(r)), enc(Double(g)), enc(Double(bl)))
        let hist = r == 255 || g == 255 || bl == 255 ? Clipping.State.blown : (r == 0 || g == 0 || bl == 0 ? .crushed : .fine)
        if Clipping.state(lin) != hist { agree = false }
    } } }
    check("CL4 the overlay and the histogram readout call the same pixels clipped (8-bit sweep)", agree)
}

// RK / BR: raster masks (painted or detected pictures of the upright photo) and the brush that paints them
do {
    let r = MaskRaster(id: "t", width: 4, height: 2, pixels: [0, 85, 170, 255, 255, 170, 85, 0])
    func s(_ x: Int, _ y: Int) -> Double { r.sample(u: (Double(x) + 0.5) / 4, v: (Double(y) + 0.5) / 2) }
    check("RK1 sampling at a pixel centre gives that pixel", abs(s(1, 0) - 85.0 / 255) < 1e-12 && abs(s(3, 1) - 0) < 1e-12 && abs(s(0, 1) - 1) < 1e-12)
    check("RK1 halfway between two pixels is their mean, in x and in y",
          abs(r.sample(u: 0.5, v: 0.25) - 0.5) < 1e-12 && abs(r.sample(u: 0.125, v: 0.5) - 0.5) < 1e-12)
    check("RK1 outside the picture clamps to the edge pixel; NaN is 0",
          abs(r.sample(u: -3, v: 0.25) - 0) < 1e-12 && abs(r.sample(u: 9, v: 0.25) - 1) < 1e-12 && r.sample(u: .nan, v: 0.5) == 0)
    var spec = Mask.spec(from: ["mask_mode": 2, "mask_kind": 5])!
    check("RK2 a raster kind with no raster is 0 everywhere, inverted or not",
          Mask.alpha(spec, x: 3, y: 3, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3)) == 0
            && { var i = spec; i.invert = true; return Mask.alpha(i, x: 3, y: 3, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3)) == 0 }())
    spec.raster = MaskRaster(id: "c", width: 2, height: 2, pixels: [255, 0, 0, 0])
    func a(_ o: Orientation, _ x: Double, _ y: Double, invert: Bool = false) -> Double {
        var sp = spec; sp.orientation = o; sp.invert = invert
        return Mask.alpha(sp, x: x, y: y, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3))
    }
    check("RK3 an upright frame reads the raster where the pixel is: top-left bright, bottom-right dark", a(.none, 1, 1) > 0.99 && a(.none, 47, 39) < 0.01)
    check("RK3 in a CW 90 shot the picture's top-left is the sensor's bottom-left, not its top-left",
          a(.rotateCW90, 1, 39) > 0.99 && a(.rotateCW90, 1, 1) < 0.05 && a(.rotateCW90, 40, 1) < 0.01)
    check("RK3 invert is 1 - weight", abs(a(.none, 1, 1, invert: true) - (1 - a(.none, 1, 1))) < 1e-12)

    // an asymmetric picture (the top half bright), so swapping x and y, or turning the frame the wrong way, cannot pass
    var topHalf = Mask.spec(from: ["mask_mode": 2, "mask_kind": 5])!
    topHalf.raster = MaskRaster(id: "h", width: 2, height: 2, pixels: [255, 255, 0, 0])
    func h(_ o: Orientation, _ x: Double, _ y: Double) -> Double {
        var sp = topHalf; sp.orientation = o
        return Mask.alpha(sp, x: x, y: y, width: 48, height: 40, rgb: SIMD3(0.3, 0.3, 0.3))
    }
    check("RK4 an upright frame: the top half of the picture is the top half of the frame, at any x",
          h(.none, 40, 1) > 0.99 && h(.none, 1, 1) > 0.99 && h(.none, 40, 39) < 0.01 && h(.none, 1, 39) < 0.01)
    check("RK4 a CW 90 shot: the picture's top half is the sensor's LEFT half (x < 24), at any y",
          h(.rotateCW90, 5, 20) > 0.99 && h(.rotateCW90, 5, 38) > 0.99 && h(.rotateCW90, 43, 20) < 0.01 && h(.rotateCW90, 43, 2) < 0.01)
    check("RK4 a 180 shot: the picture's top half is the sensor's bottom half", h(.rotate180, 20, 39) > 0.99 && h(.rotate180, 20, 1) < 0.01)

    func px(_ m: MaskRaster, _ x: Int, _ y: Int) -> Int { Int(m.pixels[y * m.width + x]) }
    let one = BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.1, softness: 0, flow: 1, erase: false)
    let hard = Brush.rasterize([one][...], width: 100, height: 80, id: "b")
    check("BR1 a hard dab: 255 at the centre and out to the radius, 0 beyond it", px(hard, 50, 40) == 255 && px(hard, 58, 40) == 255 && px(hard, 70, 40) == 0 && px(hard, 50, 5) == 0)
    var softStroke = one; softStroke.softness = 1
    let soft = Brush.rasterize([softStroke][...], width: 100, height: 80, id: "s")
    check("BR2 a soft dab fades: about half weight halfway out (\(px(soft, 56, 40))), a hair under full at the centre (\(px(soft, 50, 40)))",
          abs(px(soft, 56, 40) - 125) <= 4 && px(soft, 50, 40) >= 250 && px(soft, 50, 40) > px(soft, 56, 40) && px(soft, 56, 40) > px(soft, 62, 40))
    var half = one; half.flow = 0.5
    let flow = Brush.rasterize([half][...], width: 100, height: 80, id: "f")
    check("BR3 flow caps the weight: 0.5 gives 128 at most", flow.pixels.max() == 128 || flow.pixels.max() == 127, "\(flow.pixels.max() ?? 0)")
    let line = BrushStroke(points: [SIMD2(0.2, 0.5), SIMD2(0.8, 0.5)], radius: 0.1, softness: 0, flow: 1, erase: false)
    let lined = Brush.rasterize([line][...], width: 100, height: 80, id: "l")
    check("BR4 a stroke is continuous: every pixel on its path is full, none is skipped", (25...75).allSatisfy { px(lined, $0, 40) == 255 })
    var eraser = one; eraser.erase = true
    let erased = Brush.rasterize([line, eraser][...], width: 100, height: 80, id: "e")
    check("BR5 an eraser removes weight where it passes and leaves the rest", px(erased, 50, 40) == 0 && px(erased, 30, 40) == 255 && px(erased, 70, 40) == 255)
    let twice = Brush.rasterize([half, half][...], width: 100, height: 80, id: "t")
    check("BR6 strokes combine with the over rule: two at flow 0.5 make 0.75 (\(px(twice, 50, 40)))", abs(px(twice, 50, 40) - 191) <= 1)
    let first = Brush.rasterize([line, eraser][...].prefix(1), width: 100, height: 80, id: "p")
    check("BR7 the first n strokes of a layer are exactly that layer at n (undo is a smaller n)", first.pixels == lined.pixels && erased.pixels != lined.pixels)
    check("BR8 raster size keeps the picture's shape: 3:2 landscape is 1024 x 683, portrait 683 x 1024",
          Brush.rasterSize(aspect: 1.5) == (1024, 683) && Brush.rasterSize(aspect: 2.0 / 3) == (683, 1024))
    let hostile = BrushStroke(points: [SIMD2(.nan, 0.5), SIMD2(5, -4), SIMD2(0.5, .infinity)], radius: .nan, softness: .nan, flow: 7, erase: false)
    let safe = Brush.rasterize([hostile][...], width: 64, height: 48, id: "h")
    check("BR9 NaN, infinite and wild strokes cannot crash the rasteriser", safe.pixels.count == 64 * 48)
    let data = try JSONEncoder().encode(line)
    let back = try JSONDecoder().decode(BrushStroke.self, from: data)
    check("BR10 a stroke round-trips through its compact JSON", back.points.count == 2 && abs(back.points[1].x - 0.8) < 1e-4 && back.radius == line.radius && back.erase == false && data.count < 150, "\(data.count) bytes")

    // drawn selections: lasso, linear and radial
    let sq: [SIMD2<Double>] = [SIMD2(0.25, 0.25), SIMD2(0.75, 0.25), SIMD2(0.75, 0.75), SIMD2(0.25, 0.75)]
    let hardLasso = MaskShapes.rasterize(.lasso, points: sq, feather: 0, width: 100, height: 80, id: "l0")
    check("LAS1 a lasso: 255 inside, 0 outside", px(hardLasso, 50, 40) == 255 && px(hardLasso, 10, 10) == 0 && px(hardLasso, 90, 70) == 0 && px(hardLasso, 50, 5) == 0)
    let areaFraction = Double(hardLasso.pixels.reduce(0) { $0 + Int($1) }) / 255 / Double(100 * 80)
    check("LAS2 a lasso's area is the polygon's (a quarter of the picture)", abs(areaFraction - 0.25) < 0.004, "\(areaFraction)")
    let reversed = MaskShapes.rasterize(.lasso, points: sq.reversed(), feather: 0, width: 100, height: 80, id: "l1")
    check("LAS3 the same lasso drawn the other way round is identical", reversed.pixels == hardLasso.pixels)
    let softLasso = MaskShapes.rasterize(.lasso, points: sq, feather: 1, width: 100, height: 80, id: "l2")
    let edge = (px(softLasso, 25, 40), px(softLasso, 20, 40), px(softLasso, 30, 40))
    check("LAS4 feather softens the edge: partial weight on it, inside above it, outside below it, centre still 255",
          px(softLasso, 50, 40) == 255 && edge.0 > 60 && edge.0 < 200 && edge.1 < edge.0 && edge.2 > edge.0, "\(edge)")
    let bow: [SIMD2<Double>] = [SIMD2(0.2, 0.2), SIMD2(0.8, 0.8), SIMD2(0.8, 0.2), SIMD2(0.2, 0.8)]
    let tied = MaskShapes.rasterize(.lasso, points: bow, feather: 0, width: 100, height: 80, id: "l3")
    check("LAS5 a self-crossing lasso fills even-odd (the bow tie's left and right wedges, not top and bottom)",
          px(tied, 25, 40) == 255 && px(tied, 75, 40) == 255 && px(tied, 50, 15) == 0 && px(tied, 50, 65) == 0)
    let lin = MaskShapes.rasterize(.linear, points: [SIMD2(0.5, 0.2), SIMD2(0.5, 0.8)], feather: 0, width: 100, height: 80, id: "n")
    let column = (0..<80).map { px(lin, 50, $0) }
    check("LAS6 linear: 255 before the first point, 0 after the second, 128 half way, never rising",
          column[5] == 255 && column[75] == 0 && abs(column[40] - 128) <= 8 && zip(column, column.dropFirst()).allSatisfy { $0 >= $1 } && px(lin, 5, 40) == px(lin, 95, 40))
    let rad = MaskShapes.rasterize(.radial, points: [SIMD2(0.5, 0.5), SIMD2(0.8, 0.8)], feather: 0.5, width: 100, height: 80, id: "r")
    check("LAS7 radial: 255 at the centre, 0 outside the ellipse, soft on the rim, symmetric about the centre",
          px(rad, 50, 40) == 255 && px(rad, 90, 40) == 0 && px(rad, 50, 70) == 0 && px(rad, 70, 40) > 0 && px(rad, 70, 40) < 255 && abs(px(rad, 29, 40) - px(rad, 70, 40)) <= 2)
    let junk = MaskShapes.rasterize(.lasso, points: [SIMD2(.nan, 0.5), SIMD2(9, -9), SIMD2(0.5, .infinity)], feather: .nan, width: 64, height: 48, id: "j")
    let few = MaskShapes.rasterize(.radial, points: [SIMD2(0.5, 0.5)], feather: 0.3, width: 64, height: 48, id: "k")
    check("LAS8 NaN, infinite and too few points cannot crash and give an empty or valid picture", junk.pixels.count == 64 * 48 && few.pixels.allSatisfy { $0 == 0 })
}

// TP point curve: free points, uneven spacing, black and white points, and the safety net around them
do {
    // the first version's formula, written out independently, for five evenly spaced points
    func legacyTangents(_ ys: [Double]) -> [Double] {
        let h = 0.25
        var d = [Double](repeating: 0, count: 4), m = [Double](repeating: 0, count: 5)
        for k in 0..<4 { d[k] = (ys[k + 1] - ys[k]) / h }
        m[0] = d[0]; m[4] = d[3]
        for k in 1...3 { m[k] = d[k - 1] * d[k] > 0 ? (d[k - 1] + d[k]) / 2 : 0 }
        for k in 0..<4 {
            if d[k] == 0 { m[k] = 0; m[k + 1] = 0; continue }
            let a = m[k] / d[k], b = m[k + 1] / d[k]
            if a * a + b * b > 9 { let t = 3 / (a * a + b * b).squareRoot(); m[k] = t * a * d[k]; m[k + 1] = t * b * d[k] }
        }
        return m
    }
    var worstLegacy = 0.0
    for ys in [[0, 0.15, 0.5, 0.85, 1], [0.05, 0.3, 0.55, 0.7, 0.9], [0, 0.4, 0.6, 0.65, 1], [0, 0, 0.5, 1, 1], [0.1, 0.1, 0.1, 0.1, 0.1]] as [[Double]] {
        let a = ToneCurve.tangents(xs: ToneCurve.legacyXs, ys: ys), b = legacyTangents(ys)
        for k in 0..<5 { worstLegacy = max(worstLegacy, abs(a[k] - b[k])) }
    }
    check("TP1 five evenly spaced points give the first version's tangents (weighted mean = plain mean)", worstLegacy < 1e-12, "\(worstLegacy)")

    let xs = [0.0, 0.1, 0.35, 0.4, 0.8, 1.0], ys = [0.0, 0.05, 0.3, 0.55, 0.85, 1.0]
    let m = ToneCurve.tangents(xs: xs, ys: ys)
    check("TP2 an uneven six-point curve passes through every point", (0..<6).allSatisfy { abs(ToneCurve.curve(xs[$0], xs: xs, ys: ys, tangents: m) - ys[$0]) < 1e-12 })
    var rising = true, inside = true, last = -Double.infinity
    for i in 0...20000 {
        let e = Double(i) / 20000
        let v = ToneCurve.curve(e, xs: xs, ys: ys, tangents: m)
        if v < last - 1e-12 { rising = false }
        last = v
        let k = min(xs.lastIndex { $0 <= e } ?? 0, 4)
        if v < ys[k] - 1e-12 || v > ys[k + 1] + 1e-12 { inside = false }
    }
    check("TP3 monotone data with uneven spacing gives a curve that never decreases and never leaves the band between neighbouring points", rising && inside)
    // a black point: the first point right of 0 and above 0 means inputs below it extend with the end tangent (and can go negative)
    let bx = [0.1, 0.5, 1.0], by = [0.0, 0.5, 1.0], bm = ToneCurve.tangents(xs: bx, ys: by)
    check("TP4 below the first point the curve extends linearly with its tangent: (0.05 gives y0 + m0 * -0.05), negative here",
          abs(ToneCurve.curve(0.05, xs: bx, ys: by, tangents: bm) - (by[0] + bm[0] * -0.05)) < 1e-12 && ToneCurve.curve(0.05, xs: bx, ys: by, tangents: bm) < 0)
    let wx = [0.0, 0.5, 0.9], wy = [0.0, 0.5, 0.8], wm = ToneCurve.tangents(xs: wx, ys: wy)
    check("TP4 above the last point it extends linearly with its tangent", abs(ToneCurve.curve(1.2, xs: wx, ys: wy, tangents: wm) - (wy[2] + wm[2] * 0.3)) < 1e-12)
    // sanitising
    let valid = ToneCurve.sanitized(xs: xs, ys: ys)
    check("TP5 a valid set comes back unchanged", valid.xs == xs && valid.ys == ys)
    let hostile = ToneCurve.sanitized(xs: [.nan, 0.9, 0.2, -4, 7, 0.5, 0.5, 0.5, 0.5, 0.5], ys: [2, -1, .infinity, 0.3, 0.2, 0.9, .nan, 0.1, 0.2, 0.3])
    var okShape = hostile.xs.count == 8 && hostile.ys.count == 8
    for i in 1..<hostile.xs.count where okShape {
        okShape = hostile.xs[i] - hostile.xs[i - 1] >= ToneCurve.minGap - 1e-12 && hostile.ys[i] >= hostile.ys[i - 1]
    }
    check("TP5 hostile points (NaN, infinity, out of range, unsorted, ten of them) become 8 safe ones: gaps kept, x in 0...1, y rising",
          okShape && hostile.xs.allSatisfy { $0 >= 0 && $0 <= 1 } && hostile.ys.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(hostile)")
    check("TP5 fewer than two points is the identity pair", ToneCurve.sanitized(xs: [0.3], ys: [0.9]).xs == [0, 1] && ToneCurve.sanitized(xs: [], ys: []).ys == [0, 1])
    let crowded = ToneCurve.sanitized(xs: [0.5, 0.5, 0.5, 0.5, 0.5], ys: [0, 0, 0, 0, 0])
    check("TP5 five points all at x = 0.5 are spread out to fit inside 0...1 with the minimum gap", crowded.xs.last! <= 1 && crowded.xs[0] >= 0 && zip(crowded.xs, crowded.xs.dropFirst()).allSatisfy { $1 - $0 >= ToneCurve.minGap - 1e-12 })
    // the uniforms the Metal kernel reads
    let u = ToneCurve.uniforms(xs: xs, ys: ys)
    check("TP6 the kernel's uniforms are [n, 8 xs, 8 ys, 8 tangents] with unused slots 0", u.count == 25 && u[0] == 6 && u[1] == Float(xs[0]) && u[6] == Float(xs[5]) && u[7] == 0 && u[8] == 0 && u[9] == Float(ys[0]) && u[14] == Float(ys[5]) && u[15] == 0 && u[16] == 0 && u[17] == Float(m[0]) && u[22] == Float(m[5]) && u[23] == 0)
    // apply on a ramp: identity for the identity points, finite on hostile ones
    var worstId = 0.0
    for i in 0...400 { let v = 1.5 * Double(i) / 400; worstId = max(worstId, abs(ToneCurve.apply(v, xs: [0, 1], ys: [0, 1]) - v)) }
    check("TP7 two points (0,0) and (1,1) are the identity, past white included", worstId < 1e-9, "\(worstId)")
}

// MARK: SceneTone (the display module's tone stage, version 2)

func encodeLinear(_ v: Double) -> Double { min(max(Transfer.linearToSRGB(max(v, 0)), 0), 1) }
let tsLumaWeights = SIMD3<Double>(0.2627, 0.6780, 0.0593)

// TS1 monotone, C1 at the knee, slope zero at the white point, for contrast, white point and peak across their ranges
do {
    var monotone = true, c1 = 0.0, endSlope = 0.0, cases = 0
    for contrast in [-100.0, -50, 0, 50, 100] {
        for white in [2.0, 3.0, 4.5, 6.0, 8.0] {
            for peak in [1.0, 4.0, 8.0] {
                let t = SceneTone(contrast: contrast, whiteEV: white, peak: peak)
                cases += 1
                var prev = -1.0
                var x = -14.0
                while x < 10 {
                    let v = t.curve(x)
                    if !(v.isFinite) || v < prev - 1e-12 || (x < t.whiteEV - 0.05 && v <= prev) { monotone = false }
                    prev = v; x += 0.01
                }
                let e = 1e-5
                let left = (t.curve(t.kneeEV) - t.curve(t.kneeEV - e)) / e, right = (t.curve(t.kneeEV + e) - t.curve(t.kneeEV)) / e
                c1 = max(c1, abs(left - right) / max(abs(left), 1e-9))
                endSlope = max(endSlope, abs(t.curve(t.whiteEV) - t.curve(t.whiteEV - e)) / e)
            }
        }
    }
    check("TS1 the curve is monotone (strictly below the white point) for \(cases) settings", monotone)
    check("TS1 the slope is continuous at the knee (relative jump under 1e-3)", c1 < 1e-3, "\(c1)")
    check("TS1 the slope reaches zero at the white point", endSlope < 1e-3, "\(endSlope)")
}

// TS2 headroom kept: at the defaults every half stop from +2 to +4 EV over grey lands on a different, clearly separated code
// (the old per-channel curve flattened +3.0 and +3.5 to 255, which is the JPEG highlight), and +4 EV is within 3 codes of white
do {
    let t = SceneTone()
    let codes = stride(from: 2.0, through: 4.0, by: 0.5).map { 255 * encodeLinear(t.curve($0)) }
    var gap = Double.infinity
    for i in 1..<codes.count { gap = min(gap, codes[i] - codes[i - 1]) }
    check("TS2 half-stop steps from +2 to +4 EV are at least 2 codes apart", gap >= 2, "codes \(codes.map { Int($0) }), smallest step \(gap)")
    check("TS2 +4 EV is within 3 codes of white, and +4.5 EV is white", codes.last! >= 252 && abs(t.curve(4.5) - 1) < 1e-9, "\(codes.last!)")
    let old = ToneMap()
    let oldCodes = [3.0, 3.5].map { 255 * encodeLinear(old.apply(0.18 * pow(2, $0))) }
    check("TS2 mutation: the old ToneMap puts +3.0 and +3.5 EV on the same code (255)", oldCodes[0].rounded() == 255 && oldCodes[1].rounded() == 255, "\(oldCodes)")
}

// TS3 grey stays grey exactly, and the contrast pivot sits at middle grey
do {
    let t = SceneTone()
    var worstSpread = 0.0, worstValue = 0.0
    var v = 1e-5
    while v < 16 {
        let o = t.displayLinear(SIMD3(repeating: v))
        worstSpread = max(worstSpread, max(o.x, o.y, o.z) - min(o.x, o.y, o.z))
        worstValue = max(worstValue, abs(o.y - t.apply(v)))
        v *= 1.05
    }
    check("TS3 neutral in, neutral out (channel spread under 1e-12) across 1e-5...16", worstSpread < 1e-12, "\(worstSpread)")
    // the Rec.2020 to sRGB matrix is derived from the primaries, and its white is about 1e-6 off 1 (see ColorMath), so a neutral is within that
    check("TS3 a neutral lands on the tone curve (within the derived matrix's 2e-6 white error)", worstValue < 2e-6, "\(worstValue)")
    check("TS3 middle grey maps to 0.18 at any contrast", [-100.0, 0, 100].allSatisfy { abs(SceneTone(contrast: $0).apply(0.18) - 0.18) < 1e-12 })
    check("TS3 contrast +50 is steeper than 0 around grey",
          SceneTone(contrast: 50).apply(0.27) - SceneTone(contrast: 50).apply(0.12) > SceneTone().apply(0.27) - SceneTone().apply(0.12))
    check("TS3 a lower white point brightens the upper tones", SceneTone(whiteEV: 3).apply(0.9) > SceneTone(whiteEV: 5).apply(0.9))
}

// TS4 hue: 36 hues at chroma 0.12 and +1, +2.5, +3.5 EV over grey keep their OkLab hue (purity 0), including the colours the gamut step has
// to bring inside; applying the curve per channel instead (the mutation) moves hue by more than 2 degrees on at least 10 hues at +2.5 EV;
// purity 0.5 bleaches the top (chroma at +3.5 EV under half of chroma at +1 EV)
do {
    let keep = SceneTone(purity: 0)
    func hueDegrees(_ srgbLinear: SIMD3<Double>) -> Double {
        OkLab.lch(OkLab.fromWorking(srgbLinear)).z * 180 / .pi
    }
    func chroma(_ srgbLinear: SIMD3<Double>) -> Double { OkLab.lch(OkLab.fromWorking(srgbLinear)).y }
    var worstDrift = 0.0, mutantBad = 0, gamutHit = 0
    var chromaLow = 0.0, chromaHigh = 0.0
    for k in 0..<36 {
        let h = (Double(k) * 10 - 175) * .pi / 180
        let base = OkLab.toRec2020(OkLab.lab(SIMD3(0.7, 0.12, h)))
        let n0 = SceneTone.luminance(base)
        for ev in [1.0, 2.5, 3.5] {
            let scene = base * (0.18 * pow(2, ev) / n0)
            let inHue = OkLab.lch(OkLab.fromRec2020(scene)).z * 180 / .pi
            let out = keep.displayLinear(scene)
            let n = SceneTone.luminance(scene)
            // what the stage hands the gamut step: the ratio-scaled colour in sRGB
            let raw = ColorSpaces.rec2020ToSRGB.apply(scene * (keep.apply(n) / n))
            let outside = min(raw.x, raw.y, raw.z) < 0 || max(raw.x, raw.y, raw.z) > 1
            if outside { gamutHit += 1 }
            if chroma(out) > 0.003 { worstDrift = max(worstDrift, abs(ColorCommon.hueDifference(hueDegrees(out), inHue))) }
            if ev == 2.5 {
                // the mutant: the same curve applied to R, G and B on their own, then cut to the display
                let m = ColorSpaces.rec2020ToSRGB.apply(SIMD3(keep.apply(scene.x), keep.apply(scene.y), keep.apply(scene.z)))
                let cut = SIMD3(min(max(m.x, 0), 1), min(max(m.y, 0), 1), min(max(m.z, 0), 1))
                if chroma(cut) > 0.003, abs(ColorCommon.hueDifference(hueDegrees(cut), inHue)) > 2 { mutantBad += 1 }
            }
            let bleached = SceneTone(purity: 0.5).displayLinear(scene)
            if ev == 1 { chromaLow += chroma(bleached) / 36 }
            if ev == 3.5 { chromaHigh += chroma(bleached) / 36 }
        }
    }
    check("TS4 the gamut step is exercised (\(gamutHit) of 108 colours needed it)", gamutHit >= 30, "\(gamutHit)")
    check("TS4 hue is kept within 1 degree for 36 hues at +1, +2.5 and +3.5 EV (purity 0)", worstDrift < 1, "\(worstDrift)")
    check("TS4 mutation: the curve applied per channel moves the hue by more than 2 degrees on at least 10 of 36 hues at +2.5 EV", mutantBad >= 10, "\(mutantBad)")
    check("TS4 with purity 0.5 chroma at +3.5 EV is under half of chroma at +1 EV (the path to white)", chromaHigh < 0.5 * chromaLow, "\(chromaHigh) vs \(chromaLow)")
}

// TS5 gamut, for each output gamut (sRGB and Display P3): over a 20 x 20 x 20 grid of working-space colours up to +4 EV no output leaves the target's
// cube 0...1, a colour the step had to move keeps its OkLab lightness (within 1e-6) and hue (within 0.05 degrees), one already inside is returned
// unchanged, and the output stays in working primaries (so Core Image's last conversion has nothing to clip)
for target in [OutputGamut.sRGB, .displayP3] {
    let t = SceneTone(target: target)
    let name = target == .sRGB ? "sRGB" : "Display P3"
    func inCube(_ w: SIMD3<Double>, _ eps: Double = 1e-9) -> Bool {
        let u = target.fromWorking.apply(w)
        return min(u.x, u.y, u.z) >= -eps && max(u.x, u.y, u.z) <= 1 + eps
    }
    var outOfRange = 0, worstL = 0.0, worstHue = 0.0, grid = 0, moved = 0, untouchedDiff = 0.0, cutLightness = 0.0, untouchedCount = 0
    let top = 0.18 * pow(2, 4.0)
    for i in 0..<20 { for j in 0..<20 { for k in 0..<20 {
        let rgb = SIMD3(Double(i), Double(j), Double(k)) * (top / 19)
        let n = SceneTone.luminance(rgb)
        guard n > 1e-3 else { continue }
        grid += 1
        let o = t.displayLinear(rgb)
        if !(o.x.isFinite && o.y.isFinite && o.z.isFinite) || !inCube(o, 1e-6) { outOfRange += 1 }
        let raw = rgb * (t.apply(n) / n)
        guard log2(n / 0.18) <= t.kneeEV else { continue }   // above the knee the way to white also moves colour; the step on its own is checked below
        if inCube(raw, 0) { untouchedCount += 1; untouchedDiff = max(untouchedDiff, max(abs(o.x - raw.x), abs(o.y - raw.y), abs(o.z - raw.z))) }
    } } }
    // the step on its own, on colours far outside the target gamut
    for i in 0..<40 { for j in 0..<40 {
        let lab = SIMD3(0.35 + 0.5 * Double(i) / 39, 0.45 * cos(Double(j) * .pi / 20), 0.45 * sin(Double(j) * .pi / 20))
        let s = OkLab.toWorking(lab)
        let g = t.gamutMap(s)
        if !inCube(s, 1e-5) {
            moved += 1
            let after = OkLab.fromWorking(g)
            worstL = max(worstL, abs(after.x - lab.x))
            if OkLab.lch(after).y > 0.003 { worstHue = max(worstHue, abs(ColorCommon.hueDifference(OkLab.lch(after).z * 180 / .pi, OkLab.lch(lab).z * 180 / .pi))) }
            let u = target.fromWorking.apply(s)
            let cut = target.toWorking.apply(SIMD3(min(max(u.x, 0), 1), min(max(u.y, 0), 1), min(max(u.z, 0), 1)))
            cutLightness = max(cutLightness, abs(OkLab.fromWorking(cut).x - lab.x))
        }
    } }
    check("TS5 (\(name)) no output outside the target's cube 0...1 over \(grid) grid colours", outOfRange == 0, "\(outOfRange)")
    check("TS5 (\(name)) a colour already inside (\(untouchedCount) of them, below the knee) is returned unchanged", untouchedCount > 50 && untouchedDiff < 1e-9, "\(untouchedCount), \(untouchedDiff)")
    check("TS5 (\(name)) over \(moved) colours outside the gamut the step keeps OkLab lightness within 1e-6", moved > 200 && worstL < 1e-3, "moved \(moved), worst \(worstL)")
    check("TS5 (\(name)) and keeps their hue within 0.05 degrees", worstHue < 0.05, "\(worstHue)")
    check("TS5 (\(name)) mutation: cutting channels changes OkLab lightness by more than 0.02 somewhere", cutLightness > 0.02, "\(cutLightness)")
}

// TS5b Display P3 holds colours sRGB cannot: for saturated colours the P3 output is at least as chromatic as the sRGB one, and clearly more on some
do {
    let srgb = SceneTone(purity: 0, target: .sRGB), p3 = SceneTone(purity: 0, target: .displayP3)
    var never = true, gain = 0.0, more = 0
    for k in 0..<36 {
        let h = (Double(k) * 10 - 175) * .pi / 180
        let base = OkLab.toWorking(OkLab.lab(SIMD3(0.7, 0.2, h)))   // a vivid colour, outside sRGB for most hues
        let scene = base * (0.18 * pow(2, 1.5) / SceneTone.luminance(base))
        let cs = OkLab.lch(OkLab.fromWorking(srgb.displayLinear(scene))).y, cp = OkLab.lch(OkLab.fromWorking(p3.displayLinear(scene))).y
        if cp < cs - 1e-9 { never = false }
        gain = max(gain, cp - cs)
        if cp > cs + 0.01 { more += 1 }
    }
    check("TS5b the Display P3 target never has less chroma than sRGB, and keeps more on \(more) of 36 vivid hues (up to +\(String(format: "%.3f", gain)))", never && more >= 12 && gain > 0.03, "\(never) \(more) \(gain)")
}

// TS6 HDR: a peak-4 render equals the SDR render below the knee, and reaches 4 two stops past the SDR white point
do {
    let sdr = SceneTone(), hdr = SceneTone(peak: 4)
    var below = 0.0
    var x = -14.0
    while x < sdr.kneeEV { below = max(below, abs(sdr.curve(x) - hdr.curve(x))); x += 0.01 }
    check("TS6 below the knee the HDR curve is the SDR curve (identical)", below < 1e-12, "\(below)")
    check("TS6 the HDR curve reaches the peak at the SDR white point + 2 EV", abs(hdr.curve(sdr.whiteEV + 2) - 4) < 1e-9 && hdr.curve(sdr.whiteEV) < 4)
    check("TS6 the HDR curve never dips under the SDR curve", stride(from: -14.0, through: 8.0, by: 0.01).allSatisfy { hdr.curve($0) >= sdr.curve($0) - 1e-12 })
}

// TS5c an HDR render (peak 4) stays inside the target gamut's cube up to the peak, for both gamuts, and uses the headroom: some colour goes past 1
for target in [OutputGamut.sRGB, .displayP3] {
    let t = SceneTone(peak: 4, target: target)
    var inside = true, past = 0, count = 0
    let top = 0.18 * pow(2, 6.5)
    for i in 0..<14 { for j in 0..<14 { for k in 0..<14 {
        let rgb = SIMD3(Double(i), Double(j), Double(k)) * (top / 13)
        guard SceneTone.luminance(rgb) > 1e-3 else { continue }
        count += 1
        let u = target.fromWorking.apply(t.displayLinear(rgb))
        if min(u.x, u.y, u.z) < -1e-6 || max(u.x, u.y, u.z) > 4 + 1e-6 { inside = false }
        if max(u.x, u.y, u.z) > 1.5 { past += 1 }
    } } }
    check("TS5c (\(target == .sRGB ? "sRGB" : "Display P3")) peak 4: every output is inside the cube 0...4, and \(past) of \(count) use the headroom (above 1.5)", inside && past > 100, "\(inside) \(past)")
}

// TS7 hostile input: black, negative channels, NaN, infinity and huge values give finite output inside the target's cube, for both gamuts
do {
    let cases: [SIMD3<Double>] = [.zero, SIMD3(-0.1, 0.02, -0.3), SIMD3(-1, -1, -1), SIMD3(.nan, 1, 1), SIMD3(.infinity, 0, 0),
                                  SIMD3(1e30, 1e30, 1e30), SIMD3(1e-30, 0, 0), SIMD3(5, -5, 0.3)]
    for target in [OutputGamut.sRGB, .displayP3] {
        let t = SceneTone(target: target)
        let ok = cases.allSatisfy { c in
            let o = t.displayLinear(c)
            let u = target.fromWorking.apply(o)
            return o.x.isFinite && o.y.isFinite && o.z.isFinite && min(u.x, u.y, u.z) >= -1e-6 && max(u.x, u.y, u.z) <= 1 + 1e-6
        }
        check("TS7 (\(target == .sRGB ? "sRGB" : "Display P3")) black, negative, NaN, infinite and huge inputs give finite output inside the cube", ok)
    }
    check("TS7 non-finite settings fall back to the defaults", SceneTone(contrast: .nan, whiteEV: .nan, purity: .nan, peak: .nan).apply(0.5) == SceneTone().apply(0.5))
}

// MARK: ZoneExposure (the zones module)

do {
    let zw = 48, zh = 40
    let fix = DetailCommon.fixture(width: zw, height: zh)
    func ratios(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        var worst = 0.0
        for (p, q) in zip(a, b) where p.y > 1e-6 && q.y > 1e-6 {
            worst = max(worst, abs(p.x / p.y - q.x / q.y), abs(p.z / p.y - q.z / q.y))
        }
        return worst
    }
    // ZE1 the identity at all zeros, exactly
    // ZE-mono: no tone inversion in the zone gain either (a lift of one zone over its neighbour used to make the gain fall and draw outlines around regions)
    var zSlope = Double.infinity
    let zsets: [[Double]] = [[0, 0, 0, 0, 0, 3, 0, 0, 0, 0], [3, 0, 0, 0, 0, 0, 0, 0, 0, -3], [-3, 3, -3, 3, -3, 3, -3, 3, -3, 3], [0, 0, 0, 3, -3, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, -3, 0, 0]]
    for evs in zsets {
        var b = -9.0, prevOut = b + ZoneExposure.gain(base: b, evs: evs)
        while b < 4 { b += 0.01; let out = b + ZoneExposure.gain(base: b, evs: evs); zSlope = min(zSlope, (out - prevOut) / 0.01); prevOut = out }
    }
    check("ZE-mono the zone curve never falls over five extreme zone sets (least slope \(zSlope))", zSlope > 0.03, "\(zSlope)")
    check("ZE-node a zone node keeps its own change when its neighbours allow it: zone 0 at +1 over zeros gains exactly 1 EV there",
          abs(ZoneExposure.gain(base: 0, evs: [0, 0, 0, 0, 0, 0, 0, 1, 0, 0]) - 1) < 1e-9)
    check("ZE1 all zones at zero is the identity, byte for byte", ZoneExposure.apply(fix, width: zw, height: zh, settings: .init()) == fix)
    // ZE2 the ten weights always sum to one, so the same change on every zone is exactly a global exposure
    var sumWorst = 0.0
    var b = -9.0
    while b < 4 { sumWorst = max(sumWorst, abs(ZoneExposure.weights(b).reduce(0, +) - 1)); b += 0.013 }
    check("ZE2 zone weights sum to 1 for any base brightness", sumWorst < 1e-12, "\(sumWorst)")
    let allPlus = ZoneExposure.apply(fix, width: zw, height: zh, settings: .init(zones: [Double](repeating: 1, count: 10)))
    var globalErr = 0.0
    for (p, q) in zip(fix, allPlus) { globalErr = max(globalErr, abs(q.x - 2 * p.x), abs(q.y - 2 * p.y), abs(q.z - 2 * p.z)) }
    check("ZE2 +1 EV on every zone is exactly 2x on a textured picture", globalErr < 1e-12, "\(globalErr)")
    // a flat field at -3 EV with the -3 zone at +1: exactly twice
    let flatColour = SIMD3(1.0, 0.7, 0.4)
    let flat = [SIMD3<Double>](repeating: flatColour * (0.18 * pow(2, -3) / ColorCommon.luminance(flatColour)), count: zw * zh)   // luminance 0.18 * 2^-3
    var s2 = ZoneExposure.Settings(); s2.zones[4] = 1
    let flatOut = ZoneExposure.apply(flat, width: zw, height: zh, settings: s2)
    let flatZ = ZoneExposure.logLuminance(flat[0])
    check("ZE2 a flat field sitting on zone -3 doubles with z_m3 = +1 (z \(flatZ))", abs(flatZ + 3) < 0.01 && abs(flatOut[0].x / flat[0].x - 2) < 0.02, "\(flatOut[0].x / flat[0].x)")
    // ZE3 colour ratios are kept at the strongest settings
    let strong = ZoneExposure.apply(fix, width: zw, height: zh, settings: .init(shadows: 2, highlights: -2, blacks: 1, whites: -1, scale: 0.1))
    check("ZE3 colour ratios are kept (a gain on all three channels)", ratios(fix, strong) < 1e-9, "\(ratios(fix, strong))")
    check("ZE3 the strongest setting really moves the picture", zip(fix, strong).contains { abs($0.y - $1.y) > 0.05 })
    // ZE4 halo: a step edge of 4 EV (left 0.18 * 2^-3, right 0.18 * 2^+1), shadows +2 EV. The gain must follow each side's own
    // brightness right up to the edge; a plain box mean of the same radius (the mutation) blurs it across and overshoots.
    let sw = 80, sh = 20
    let left = 0.18 * pow(2, -3.0), right = 0.18 * pow(2, 1.0)
    let stepImg: [SIMD3<Double>] = (0..<(sw * sh)).map { i in SIMD3(repeating: (i % sw) < sw / 2 ? left : right) }
    let evs = ZoneExposure.Settings(shadows: 2).zoneEVs
    let radius = 8
    let zPlane = Plane(width: sw, height: sh, values: stepImg.map { ZoneExposure.logLuminance($0) })
    let good = ZoneExposure.apply(stepImg, base: Filters.guided(guide: zPlane, input: zPlane, radius: radius, eps: ZoneExposure.eps), evs: evs)
    let boxed = ZoneExposure.apply(stepImg, base: Filters.boxMean(zPlane, radius: radius), evs: evs)
    let ideal: [Double] = (0..<(sw * sh)).map { i in (i % sw) < sw / 2 ? left * pow(2, ZoneExposure.gain(base: -3, evs: evs)) : right }
    func overshoot(_ out: [SIMD3<Double>]) -> Double {
        var w = 0.0
        for i in 0..<(sw * sh) { w = max(w, abs(out[i].y - ideal[i])) }
        return w / (ideal[sw - 1] - ideal[0])
    }
    let haloGood = overshoot(good), haloBox = overshoot(boxed)
    check("ZE4 a 4 EV step with shadows +2 EV: error at the edge under 2% of the step", haloGood < 0.02, "\(haloGood)")
    check("ZE4 mutation: a box-mean base of the same radius misses by more than 5% of the step", haloBox > 0.05, "\(haloBox)")
    // ZE5 texture is kept: the high-pass energy of the log luminance changes by under 10% at a moderate shadows lift
    func highPass(_ img: [SIMD3<Double>]) -> Double {
        let z = Plane(width: zw, height: zh, values: img.map { ZoneExposure.logLuminance($0) })
        let low = Filters.boxMean(z, radius: 2)
        return zip(z.values, low.values).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
    }
    let lifted = ZoneExposure.apply(fix, width: zw, height: zh, settings: .init(shadows: 1, scale: 0.12))
    let hpRatio = highPass(lifted) / highPass(fix)
    check("ZE5 texture energy is within 10% of the original after a +1 EV shadows lift", abs(hpRatio - 1) < 0.10, "\(hpRatio)")
    // ZE6 the radius follows the frame (a fraction of the long side), within its cap
    check("ZE6 the radius is the scale times the long side, between 1 and the cap",
          ZoneExposure.radius(scale: 0.04, longSide: 2400) == 96 && ZoneExposure.radius(scale: 0.2, longSide: 9000) == ZoneExposure.maxRadius
          && ZoneExposure.radius(scale: 0.005, longSide: 10) == 1 && ZoneExposure.radius(scale: .nan, longSide: 1000) == 40)
    check("ZE6 hostile values: NaN settings and base give the identity gain", ZoneExposure.Settings(values: ["shadows": .nan]).isIdentity
          && ZoneExposure.gain(base: .nan, evs: [Double](repeating: 0, count: 10)) == 0)
}

// CZ colour zones (ColorZones, OkLab LCh bands)
func czColour(_ hueDegrees: Double, chroma: Double = 0.1, L: Double = 0.7) -> SIMD3<Double> {
    OkLab.toWorking(SIMD3(L, chroma * cos(hueDegrees * .pi / 180), chroma * sin(hueDegrees * .pi / 180)))
}
func czSliders(_ kind: Int, _ band: String, _ value: Double) -> [Double] {
    var u = [Double](repeating: 0, count: 24)
    u[kind * 8 + ColorZones.bandNames.firstIndex(of: band)!] = value
    return u
}
func czLCh(_ c: SIMD3<Double>) -> SIMD3<Double> { OkLab.lch(OkLab.fromWorking(c)) }
do {
    // CZ1 zero sliders are the identity on 4096 colours
    var worstId = 0.0, finite = true
    for i in 0..<4096 {
        let t = Double(i) / 4095, c = czColour(t * 37 * 360, chroma: 0.002 + 0.2 * t, L: 0.1 + 0.8 * t)
        let out = ColorZones.apply(c, u: [Double](repeating: 0, count: 24))
        for k in 0..<3 {
            if !out[k].isFinite { finite = false }
            worstId = max(worstId, abs(out[k] - c[k]) / max(abs(c[k]), 1e-6))
        }
    }
    check("CZ1 zero sliders are the identity within 1e-9 relative, finite", worstId < 1e-9 && finite, "worst \(worstId), finite \(finite)")

    // CZ2 a grey is never touched, whatever the sliders say
    let allOn = [Double](repeating: 1, count: 24)
    var greyWorst = 0.0
    for L in stride(from: 0.05, through: 0.95, by: 0.1) {
        let g = OkLab.toWorking(SIMD3(L, 0, 0)), out = ColorZones.apply(g, u: allOn)
        greyWorst = max(greyWorst, abs(out.x - g.x), abs(out.y - g.y), abs(out.z - g.z))
    }
    check("CZ2 greys are left alone by every slider (within 1e-9)", greyWorst < 1e-9, "\(greyWorst)")

    // CZ3 the green band at its centre, saturation -1: the colour goes grey
    let green = czColour(ColorZones.centresDegrees[3])
    let greyed = czLCh(ColorZones.apply(green, u: czSliders(1, "green", -1)))
    check("CZ3 green saturation -1 at the green centre removes the chroma (under 1e-9)", greyed.y < 1e-9, "\(greyed.y)")

    // CZ4 the red band at its centre, hue +1: the hue turns by hueRangeDegrees, chroma and lightness stay
    let red = czColour(ColorZones.centresDegrees[0])
    let turned = czLCh(ColorZones.apply(red, u: czSliders(0, "red", 1)))
    check("CZ4 red hue +1 turns the hue by \(ColorZones.hueRangeDegrees) degrees (within 0.01)",
          abs(turned.z * 180 / .pi - (ColorZones.centresDegrees[0] + ColorZones.hueRangeDegrees)) < 0.01, "\(turned.z * 180 / .pi)")
    check("CZ4 the hue turn keeps chroma and lightness (within 1e-9)", abs(turned.y - 0.1) < 1e-9 && abs(turned.x - 0.7) < 1e-9, "\(turned)")

    // CZ5 the blue band at its centre, lightness +1: OkLab L rises by lightnessRange
    let blue = czColour(ColorZones.centresDegrees[5])
    let lifted = czLCh(ColorZones.apply(blue, u: czSliders(2, "blue", 1)))
    check("CZ5 blue lightness +1 raises L by \(ColorZones.lightnessRange) (within 1e-9)", abs(lifted.x - 0.7 - ColorZones.lightnessRange) < 1e-9, "\(lifted.x)")

    // CZ6 no jump anywhere on the hue circle, including across 360 to 0: neighbouring hues land close together
    var jump = 0.0
    var previous: SIMD3<Double>?
    var u6 = [Double](repeating: 0, count: 24)
    for b in 0..<8 { u6[b] = b % 2 == 0 ? 1 : -1; u6[8 + b] = b % 2 == 0 ? -1 : 1; u6[16 + b] = b % 3 == 0 ? 1 : -1 }
    for step in 0...7200 {
        let out = ColorZones.apply(czColour(Double(step) * 0.05), u: u6)
        if let p = previous { jump = max(jump, abs(out.x - p.x), abs(out.y - p.y), abs(out.z - p.z)) }
        previous = out
    }
    check("CZ6 a twentieth of a degree of hue never moves the result by more than 0.005 (smooth, wraps at 360)", jump < 0.005, "\(jump)")

    // CZ7 a band far from a colour leaves it alone: green saturation does not touch red
    let farOut = ColorZones.apply(red, u: czSliders(1, "green", -1))
    check("CZ7 the green band leaves a red colour unchanged (within 1e-9)", max(abs(farOut.x - red.x), abs(farOut.y - red.y), abs(farOut.z - red.z)) < 1e-9)

    // CZ8 a mutation that must fail: the same colour with the hue slider on the wrong band is not the same answer
    let wrong = czLCh(ColorZones.apply(red, u: czSliders(0, "blue", 1)))
    check("CZ8 the blue hue slider does not turn a red (hue stays within 0.01 degrees)", abs(wrong.z * 180 / .pi - ColorZones.centresDegrees[0]) < 0.01, "\(wrong.z * 180 / .pi)")
}

// SCV saturation by lightness (SatCurve)
do {
    func lab(_ L: Double, chroma: Double = 0.1, hue: Double = 1.0) -> SIMD3<Double> {
        OkLab.toWorking(SIMD3(L, chroma * cos(hue), chroma * sin(hue)))
    }
    func lch(_ c: SIMD3<Double>) -> SIMD3<Double> { OkLab.lch(OkLab.fromWorking(c)) }
    // SCV1 zero sliders are the identity on 4096 colours
    var worstId = 0.0, finite = true
    for i in 0..<4096 {
        let t = Double(i) / 4095, c = lab(0.02 + 0.96 * t, chroma: 0.002 + 0.2 * t, hue: t * 37 * 2 * .pi)
        let out = SatCurve.apply(c, u: [0, 0, 0])
        for k in 0..<3 {
            if !out[k].isFinite { finite = false }
            worstId = max(worstId, abs(out[k] - c[k]) / max(abs(c[k]), 1e-6))
        }
    }
    check("SCV1 zero sliders are the identity within 1e-9 relative, finite", worstId < 1e-9 && finite, "worst \(worstId), finite \(finite)")
    // SCV2 greys stay grey
    var greyWorst = 0.0
    for L in stride(from: 0.05, through: 0.95, by: 0.1) {
        let g = OkLab.toWorking(SIMD3(L, 0, 0)), out = SatCurve.apply(g, u: [1, 1, 1])
        greyWorst = max(greyWorst, abs(out.x - g.x), abs(out.y - g.y), abs(out.z - g.z))
    }
    check("SCV2 greys are left alone (within 1e-9)", greyWorst < 1e-9, "\(greyWorst)")
    // SCV3 at each knot its own slider acts alone: mids -1 at L 0.55 removes the chroma; shadows +0.5 at L 0.1 is 1.5x; highlights -0.5 at L 0.95 is 0.5x
    check("SCV3 mids -1 at the mids knot removes the chroma (under 1e-9)", lch(SatCurve.apply(lab(0.55), u: [0, -1, 0])).y < 1e-9)
    check("SCV3 shadows +0.5 in the shadows is 1.5x the chroma (within 1e-9)", abs(lch(SatCurve.apply(lab(0.1), u: [0.5, 0, 0])).y - 0.15) < 1e-9)
    check("SCV3 highlights -0.5 in the highlights is 0.5x the chroma (within 1e-9)", abs(lch(SatCurve.apply(lab(0.95), u: [0, 0, -0.5])).y - 0.05) < 1e-9)
    // SCV4 hue and lightness never move
    let moved = lch(SatCurve.apply(lab(0.4, chroma: 0.12, hue: 2.2), u: [0.7, -0.4, 0.3]))
    check("SCV4 hue and lightness are kept (within 1e-9)", abs(moved.x - 0.4) < 1e-9 && abs(ColorCommon.hueDifference(moved.z, 2.2)) < 1e-9, "\(moved)")
    // SCV5 the gain is continuous over lightness
    var gainJump = 0.0
    var prev = SatCurve.gain(L: 0, u: [0.9, -0.8, 0.7])
    for step in 1...2000 {
        let g = SatCurve.gain(L: Double(step) / 2000, u: [0.9, -0.8, 0.7])
        gainJump = max(gainJump, abs(g - prev)); prev = g
    }
    check("SCV5 the chroma gain moves by under 0.01 per 1/2000 of lightness (smooth)", gainJump < 0.01, "\(gainJump)")
    // SCV6 a mutation that must fail: the shadows slider leaves a highlight alone
    let hi = lab(0.95), out6 = SatCurve.apply(hi, u: [1, 0, 0])
    check("SCV6 the shadows slider does not touch a highlight (within 1e-9)", max(abs(out6.x - hi.x), abs(out6.y - hi.y), abs(out6.z - hi.z)) < 1e-9)
}

// LG four-way colour balance (LiftGammaGain)
do {
    func lgRun(_ c: SIMD3<Double>, _ v: [String: Double]) -> SIMD3<Double> {
        let t = LiftGammaGain.terms(v)
        return LiftGammaGain.apply(c, slope: t.slope, offset: t.offset, power: t.power)
    }
    // LG1 zero settings are the identity on 4096 colours (hue is ignored at strength 0)
    var worstId = 0.0, finite = true
    for i in 0..<4096 {
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 2.5 * t
        let c = SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
        let out = lgRun(c, ["shadows_hue": 200, "mids_hue": 90, "highlights_hue": 310])
        for k in 0..<3 {
            if !out[k].isFinite { finite = false }
            worstId = max(worstId, abs(out[k] - c[k]) / abs(c[k]))
        }
    }
    check("LG1 zero settings are the identity within 1e-9 relative, finite", worstId < 1e-9 && finite, "worst \(worstId), finite \(finite)")
    // LG2 highlights brightness +1 is one stop of slope
    let g = SIMD3(0.3, 0.5, 0.7)
    let up = lgRun(g, ["highlights_lum": 1])
    check("LG2 highlights brightness +1 doubles the value (within 1e-9)", max(abs(up.x - 0.6), abs(up.y - 1.0), abs(up.z - 1.4)) < 1e-9, "\(up)")
    // LG3 midtones keep black and white where they are and lift what is between
    let midWhite = lgRun(SIMD3(repeating: 1), ["mids_lum": 1]), midBlack = lgRun(SIMD3(repeating: 0), ["mids_lum": 1])
    check("LG3 midtones brightness leaves white and black where they are (within 1e-9)", abs(midWhite.x - 1) < 1e-9 && midBlack.x < 1e-12, "\(midWhite) \(midBlack)")
    let midLift = lgRun(SIMD3(repeating: 0.18), ["mids_lum": 1]).x
    check("LG3 midtones brightness +1 lifts middle grey to 0.18^(2^-0.5) and -1 lowers it",
          abs(midLift - pow(0.18, pow(2, -0.5))) < 1e-9 && lgRun(SIMD3(repeating: 0.18), ["mids_lum": -1]).x < 0.18, "\(midLift)")
    // LG4 shadows brightness +1 lifts black by the offset range
    let black = lgRun(SIMD3(repeating: 0), ["shadows_lum": 1])
    check("LG4 shadows brightness +1 lifts black by \(LiftGammaGain.offsetRange) (within 1e-9)", abs(black.x - LiftGammaGain.offsetRange) < 1e-9, "\(black)")
    // LG5 a highlight tint at 220 degrees gives a grey a hue near 220 (within 3 degrees), and no tint is neutral
    let tinted = OkLab.lch(OkLab.fromWorking(lgRun(SIMD3(repeating: 0.5), ["highlights_hue": 220, "highlights_sat": 1])))
    check("LG5 a highlight tint at 220 degrees gives a grey that hue within 3 degrees",
          abs(ColorCommon.hueDifference(tinted.z, 220 * .pi / 180)) * 180 / .pi < 3 && tinted.y > 0.02, "\(tinted)")
    // LG6 hostile input: zero and negative values stay finite
    let hostile = [SIMD3(0.0, 0, 0), SIMD3(-0.2, 0.1, 0), SIMD3(5.0, 5, 5)].map { lgRun($0, ["shadows_hue": 40, "shadows_sat": 1, "shadows_lum": -1, "mids_lum": 1, "highlights_lum": 1]) }
    check("LG6 zero, negative and bright inputs stay finite", hostile.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(hostile)")
    // LG7 a mutation that must fail: black stays black under highlights and midtones settings (no offset there)
    let blackH = lgRun(SIMD3(repeating: 0), ["highlights_lum": 1, "highlights_sat": 1, "highlights_hue": 100, "mids_lum": -1])
    check("LG7 highlights and midtones leave black at black (within 1e-12)", max(blackH.x, blackH.y, blackH.z) < 1e-12, "\(blackH)")
}

// CCT colour contrast (ColorContrast) and CCR colour correction (ColorCorrection)
do {
    func swatch(_ i: Int) -> SIMD3<Double> {
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 2.5 * t
        return SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
    }
    var idCT = 0.0, idCR = 0.0, finite = true
    for i in 0..<4096 {
        let c = swatch(i)
        let a = ColorContrast.apply(c, saturation: 0), b = ColorCorrection.apply(c, brightness: 0, contrast: 0)
        for k in 0..<3 {
            if !a[k].isFinite || !b[k].isFinite { finite = false }
            idCT = max(idCT, abs(a[k] - c[k]) / abs(c[k])); idCR = max(idCR, abs(b[k] - c[k]) / abs(c[k]))
        }
    }
    check("CCT1 zero saturation is the identity within 1e-9 relative, finite", idCT < 1e-9 && finite, "\(idCT)")
    check("CCR1 zero brightness and contrast are the identity within 1e-9 relative, finite", idCR < 1e-9 && finite, "\(idCR)")
    let colour = OkLab.toWorking(SIMD3(0.6, 0.08, -0.05))
    let grey = OkLab.lch(OkLab.fromWorking(ColorContrast.apply(colour, saturation: -1)))
    check("CCT2 saturation -1 removes the chroma and keeps lightness (within 1e-9)", grey.y < 1e-9 && abs(grey.x - 0.6) < 1e-9, "\(grey)")
    let more = OkLab.lch(OkLab.fromWorking(ColorContrast.apply(colour, saturation: 0.5)))
    check("CCT3 saturation +0.5 is 1.5x the chroma and keeps hue (within 1e-9)", abs(more.y - 1.5 * hypot(0.08, -0.05)) < 1e-9 && abs(ColorCommon.hueDifference(more.z, atan2(-0.05, 0.08))) < 1e-9, "\(more)")
    let g = ColorContrast.apply(SIMD3(repeating: 0.3), saturation: 1)
    check("CCT4 a grey stays grey (within 1e-9)", abs(g.x - 0.3) < 1e-9 && abs(g.y - 0.3) < 1e-9 && abs(g.z - 0.3) < 1e-9)
    let up = ColorCorrection.apply(SIMD3(0.1, 0.2, 0.3), brightness: 1, contrast: 0)
    check("CCR2 brightness +1 is +2 EV (x4, within 1e-9)", abs(up.x - 0.4) < 1e-9 && abs(up.y - 0.8) < 1e-9 && abs(up.z - 1.2) < 1e-9, "\(up)")
    let pivot = ColorCorrection.apply(SIMD3(repeating: 0.18), brightness: 0, contrast: 0.8)
    check("CCR3 contrast leaves middle grey where it is (within 1e-9)", abs(pivot.x - 0.18) < 1e-9, "\(pivot)")
    let lo = ColorCorrection.apply(SIMD3(repeating: 0.05), brightness: 0, contrast: 0.5), hi = ColorCorrection.apply(SIMD3(repeating: 0.6), brightness: 0, contrast: 0.5)
    check("CCR4 contrast +0.5 darkens below middle grey and lightens above it", lo.x < 0.05 && hi.x > 0.6, "\(lo) \(hi)")
}

// BSC base curve, DTH posterize, COZ colorize
do {
    func swatch(_ i: Int) -> SIMD3<Double> {
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 0.95 * t
        return SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
    }
    var idBC = 0.0, finite = true
    for i in 0..<4096 {
        let c = swatch(i), o = BaseCurve.apply(c, gamma: 1)
        for k in 0..<3 { if !o[k].isFinite { finite = false }; idBC = max(idBC, abs(o[k] - c[k]) / abs(c[k])) }
    }
    check("BSC1 gamma 1 is the identity on 0...1 within 1e-9 relative, finite", idBC < 1e-9 && finite, "\(idBC)")
    let mid = SIMD3(repeating: Transfer.srgbToLinear(0.5))
    let dark = BaseCurve.apply(mid, gamma: 2), light = BaseCurve.apply(mid, gamma: 0.5)
    check("BSC2 gamma 2 maps encoded 0.5 to 0.25 and gamma 0.5 to 0.7071 (within 1e-9)",
          abs(Transfer.linearToSRGB(dark.x) - 0.25) < 1e-9 && abs(Transfer.linearToSRGB(light.x) - 0.5.squareRoot()) < 1e-9)
    let ends = BaseCurve.apply(SIMD3(0, 1, 1), gamma: 2.7)
    check("BSC3 black and white stay put (within 1e-9)", abs(ends.x) < 1e-9 && abs(ends.y - 1) < 1e-9)
    let wild = BaseCurve.apply(SIMD3(-0.3, 4, .nan), gamma: 1.4)
    check("BSC4 below black, above white and NaN stay finite and in 0...1", wild.x == 0 && wild.y == 1 && wild.z == 0, "\(wild)")
    check("BSC5 a mutation that must fail: gamma 2 and gamma 0.5 give different answers", abs(dark.x - light.x) > 0.1)

    let post = Posterize.apply(SIMD3(Transfer.srgbToLinear(0.52), Transfer.srgbToLinear(0.1), Transfer.srgbToLinear(0.96)), levels: 5)
    check("DTH1 five levels land on 0, 0.25, 0.5, 0.75, 1 of the encoded value (within 1e-9)",
          abs(Transfer.linearToSRGB(post.x) - 0.5) < 1e-9 && abs(Transfer.linearToSRGB(post.y) - 0) < 1e-9 && abs(Transfer.linearToSRGB(post.z) - 1) < 1e-9, "\(post)")
    let twice = Posterize.apply(post, levels: 5)
    check("DTH2 posterizing twice changes nothing (within 1e-9)", max(abs(twice.x - post.x), abs(twice.y - post.y), abs(twice.z - post.z)) < 1e-9)
    var distinct = Set<Double>()
    for i in 0..<4096 { distinct.insert(Posterize.apply(swatch(i), levels: 8).x) }
    check("DTH3 eight levels give at most eight values on a channel", distinct.count <= 8 && distinct.count >= 6, "\(distinct.count)")
    let wildP = Posterize.apply(SIMD3(-1, 9, .nan), levels: 4)
    check("DTH4 below black, above white and NaN stay finite (0, 1, 0)", wildP.x == 0 && abs(wildP.y - 1) < 1e-9 && wildP.z == 0, "\(wildP)")
    check("DTH5 levels below 2 are held to 2 (two values)", Set((0..<64).map { Posterize.apply(SIMD3(repeating: Double($0) / 63), levels: 1).x }).count == 2)

    let c0 = OkLab.toWorking(SIMD3(0.6, 0.05, -0.1))
    let same = Colorize.apply(c0, strength: 0, hue: 0.3)
    check("COZ1 strength 0 is the identity (within 1e-9)", max(abs(same.x - c0.x), abs(same.y - c0.y), abs(same.z - c0.z)) < 1e-9)
    let full = OkLab.lch(OkLab.fromWorking(Colorize.apply(c0, strength: 1, hue: 0.25)))
    check("COZ2 strength 1 gives the tint's chroma and hue, keeps lightness (within 1e-9)",
          abs(full.y - Colorize.chroma) < 1e-9 && abs(full.x - 0.6) < 1e-9 && abs(ColorCommon.hueDifference(full.z, .pi / 2)) < 1e-9, "\(full)")
    let half = OkLab.fromWorking(Colorize.apply(c0, strength: 0.5, hue: 0))
    check("COZ3 strength 0.5 is halfway between the pixel's and the tint's a and b (within 1e-9)",
          abs(half.y - (0.05 + Colorize.chroma) / 2) < 1e-9 && abs(half.z - (-0.1 + 0) / 2) < 1e-9, "\(half)")
    let g = OkLab.lch(OkLab.fromWorking(Colorize.apply(SIMD3(repeating: 0.3), strength: 1, hue: 0.6)))
    check("COZ4 a grey takes the tint at full strength (chroma 0.08) and keeps lightness", abs(g.y - 0.08) < 1e-9)
    let h0 = Colorize.apply(c0, strength: 1, hue: 0), h1 = Colorize.apply(c0, strength: 1, hue: 1)
    check("COZ5 hue 0 and hue 1 are the same colour (within 1e-9)", max(abs(h0.x - h1.x), abs(h0.y - h1.y), abs(h0.z - h1.z)) < 1e-9)
}

// BLR blur, SOF soften, MSC mosaic
do {
    let w = 41, h = 41
    let dark = SIMD3<Double>(0.2, 0.15, 0.1)
    var dot = [SIMD3<Double>](repeating: dark, count: w * h)
    dot[20 * w + 20] = SIMD3(3, 3, 3)
    func at(_ img: [SIMD3<Double>], _ x: Int, _ y: Int) -> SIMD3<Double> { img[y * w + x] }
    check("BLR1 radius 0 is the identity", Blur.apply(dot, width: w, height: h, radius: 0) == dot)
    check("BLR2 a flat picture stays flat (within 1e-12), borders included", Blur.apply([SIMD3<Double>](repeating: dark, count: w * h), width: w, height: h, radius: 3)
        .allSatisfy { near($0, dark, 1e-12) })
    let b = Blur.apply(dot, width: w, height: h, radius: 2)
    check("BLR3 beyond the reach (3 x 2 px) a pixel is untouched", at(b, 0, 0) == dark && at(b, 20, 27) == dark, "\(at(b, 20, 27))")
    var kept = 0.0
    for i in b.indices { kept += b[i].x - dark.x }
    check("BLR4 the blur keeps the light: the sum of the differences is the dot's excess (2.8)", abs(kept - 2.8) < 1e-9, "\(kept)")
    check("BLR5 the blur is symmetric about the dot and falls away from it", near(at(b, 15, 20) - dark, at(b, 25, 20) - dark, 1e-12) && at(b, 20, 20).x > at(b, 22, 20).x && at(b, 22, 20).x > at(b, 24, 20).x)
    check("BLR6 the slider radius sets the box radius, fractional: 30 px is 10, 1 px is a third, 0, negative and NaN are none",
          Blur.radius(px: 30) == 10 && abs(Blur.radius(px: 1) - 1.0 / 3) < 1e-12 && Blur.radius(px: 0) == 0 && Blur.radius(px: -4) == 0 && Blur.radius(px: .nan) == 0)
    let centre = { (r: Double) in at(Blur.apply(dot, width: w, height: h, radius: r), 20, 20).x }
    check("BLR7 a whole fractional radius is exactly the integer blur", Blur.apply(dot, width: w, height: h, radius: 2.0) == b)
    let c2 = centre(2), c25 = centre(2.5), c3 = centre(3)
    check("BLR8 half a pixel more radius lies between its neighbours", c25 < c2 && c25 > c3, "\(c2) \(c25) \(c3)")
    let cs = [0.2, 0.5, 0.9, 1.4, 2.3, 3.1, 4.6].map(centre)
    check("BLR9 more radius never gives a sharper dot: every fractional step flattens it", zip(cs, cs.dropFirst()).allSatisfy { $0 > $1 }, "\(cs)")
    var keptFrac = 0.0
    for p in Blur.apply(dot, width: w, height: h, radius: 1.7) { keptFrac += p.x - dark.x }
    check("BLR10 a fractional blur keeps the light too (2.8, within 1e-9)", abs(keptFrac - 2.8) < 1e-9, "\(keptFrac)")

    check("SOF1 strength 0 or radius 0 is the identity", Soften.apply(dot, width: w, height: h, strength: 0, radius: 2) == dot && Soften.apply(dot, width: w, height: h, strength: 1, radius: 0) == dot)
    let full = Soften.apply(dot, width: w, height: h, strength: 1, radius: 2)
    check("SOF2 strength 1 is the blur itself (within 1e-12)", zip(full, b).allSatisfy { near($0, $1, 1e-12) })
    let half = Soften.apply(dot, width: w, height: h, strength: 0.5, radius: 2)
    check("SOF3 strength 0.5 is halfway between the picture and its blur (within 1e-12)", near(at(half, 20, 20), (at(dot, 20, 20) + at(b, 20, 20)) / 2, 1e-12))
    var lightKept = 0.0
    for i in half.indices { lightKept += half[i].x - dot[i].x }
    check("SOF4 the soften conserves the light (sum of differences 0 within 1e-9)", abs(lightKept) < 1e-9, "\(lightKept)")
    check("SOF5 the dot is lowered and its neighbour raised", at(half, 20, 20).x < 3 && at(half, 21, 20).x > dark.x)

    var ramp = [SIMD3<Double>](repeating: .zero, count: 10 * 7)
    for y in 0..<7 { for x in 0..<10 { ramp[y * 10 + x] = SIMD3(Double(x), Double(y), Double(x + y)) } }
    check("MSC1 a block of 1 is the identity", Mosaic.apply(ramp, width: 10, height: 7, block: 1) == ramp)
    let m = Mosaic.apply(ramp, width: 10, height: 7, block: 4)
    check("MSC2 every pixel of a block shows the block's centre: block 0 shows (2, 2), block (1, 0) shows (6, 2)",
          m[0] == ramp[2 * 10 + 2] && m[3 * 10 + 3] == ramp[2 * 10 + 2] && m[1 * 10 + 5] == ramp[2 * 10 + 6])
    check("MSC3 the last partial block shows its centre clamped to the frame: x 8..9 shows 9 (centre 10 clamped), y 4..6 shows 6",
          m[5 * 10 + 8] == ramp[6 * 10 + 9], "\(m[5 * 10 + 8])")
    check("MSC4 the pixels are only ever copies of source pixels, never mixed", m.allSatisfy { px in ramp.contains(px) })
    check("MSC5 the block size is the pixelation times the scale: 24 at 0.5 is 12, never under 1 or over 400, NaN is 1",
          Mosaic.block(pixelation: 24, scale: 0.5) == 12 && Mosaic.block(pixelation: 1, scale: 0.1) == 1 && Mosaic.block(pixelation: 100, scale: 9) == 400 && Mosaic.block(pixelation: .nan, scale: 1) == 1)
}

// SOL solarize, NEG film negative, LLT low light, CMX channel mixer with adaptation
do {
    func swatch(_ i: Int) -> SIMD3<Double> {
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 0.95 * t
        return SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
    }
    func enc(_ v: Double) -> Double { Transfer.linearToSRGB(v) }
    func lin(_ e: Double) -> Double { Transfer.srgbToLinear(e) }
    var idSol = 0.0
    for i in 0..<4096 { let c = swatch(i), o = Solarize.apply(c, threshold: 0.4, strength: 0); for k in 0..<3 { idSol = max(idSol, abs(o[k] - c[k]) / abs(c[k])) } }
    check("SOL1 strength 0 is the identity within 1e-9 relative", idSol < 1e-9, "\(idSol)")
    let sol = Solarize.apply(SIMD3(lin(0.8), lin(0.3), lin(0.5)), threshold: 0.5, strength: 1)
    check("SOL2 threshold 0.5, strength 1: encoded 0.8 folds to 0.2, 0.3 and 0.5 are kept (within 1e-9)",
          abs(enc(sol.x) - 0.2) < 1e-9 && abs(enc(sol.y) - 0.3) < 1e-9 && abs(enc(sol.z) - 0.5) < 1e-9, "\(enc(sol.x)) \(enc(sol.y)) \(enc(sol.z))")
    let a = Solarize.apply(SIMD3(repeating: lin(0.5 - 1e-6)), threshold: 0.5, strength: 1).x, b = Solarize.apply(SIMD3(repeating: lin(0.5 + 1e-6)), threshold: 0.5, strength: 1).x
    check("SOL3 the fold is continuous at the threshold (within 1e-5)", abs(a - b) < 1e-5, "\(a) \(b)")
    let half = Solarize.apply(SIMD3(repeating: lin(0.8)), threshold: 0.5, strength: 0.5)
    check("SOL4 strength 0.5 is halfway between the tone and its fold (encoded 0.5, within 1e-9)", abs(enc(half.x) - 0.5) < 1e-9, "\(enc(half.x))")
    let wild = Solarize.apply(SIMD3(-1, 7, .nan), threshold: 0.5, strength: 1)
    check("SOL5 below black, above white and NaN stay finite and in 0...1", [wild.x, wild.y, wild.z].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(wild)")

    let dmin = SIMD3(0.8, 0.5, 0.35)
    let base = NegativeFilm.apply(dmin, dmin: dmin, gamma: 1.6, exposure: 0.2, black: 0)
    check("NEG1 the film base itself reads as exposure 0.2 on every channel (within 1e-9)", abs(base.x - 0.2) < 1e-9 && abs(base.y - 0.2) < 1e-9 && abs(base.z - 0.2) < 1e-9, "\(base)")
    let two = NegativeFilm.apply(dmin / 2, dmin: dmin, gamma: 2, exposure: 1, black: 0)
    check("NEG2 half the film-base transmission with gamma 2 is 4x the exposure (within 1e-9)", abs(two.x - 4) < 1e-9, "\(two)")
    var falling = true, prev = Double.infinity
    for i in 1...200 { let e = NegativeFilm.apply(SIMD3(repeating: Double(i) / 200), dmin: dmin, gamma: 1.6, exposure: 0.2, black: 0).x; falling = falling && e <= prev; prev = e }
    check("NEG3 a denser (darker) scan gives more light: the result falls as the scan brightens", falling)
    let blk = NegativeFilm.apply(dmin, dmin: dmin, gamma: 1.6, exposure: 0.2, black: 0.5)
    check("NEG4 the black offset never takes the light below 0", blk.x == 0 && blk.y == 0 && blk.z == 0, "\(blk)")
    let wildN = NegativeFilm.apply(SIMD3(0, -1, .nan), dmin: dmin, gamma: 1.6, exposure: 0.2, black: 0)
    check("NEG5 a black, negative or NaN scan value stays finite", [wildN.x, wildN.y, wildN.z].allSatisfy { $0.isFinite }, "\(wildN)")

    // NEG6 a negative made from known light, then inverted, gives the light back: T = Dmin * (E / exposure)^(-1/gamma)
    var roundTrip = 0.0
    for i in 1...200 {
        let e = SIMD3(Double(i) / 100, Double(i) / 150, Double(i) / 300)
        let t = SIMD3(dmin.x * pow(e.x / 0.2, -1 / 1.6), dmin.y * pow(e.y / 0.2, -1 / 1.6), dmin.z * pow(e.z / 0.2, -1 / 1.6))
        let back = NegativeFilm.apply(t, dmin: dmin, gamma: 1.6, exposure: 0.2, black: 0)
        for k in 0..<3 where t[k] >= NegativeFilm.floor { roundTrip = max(roundTrip, abs(back[k] - e[k]) / e[k]) }
    }
    check("NEG6 a negative simulated from known light is inverted back to it (within 1e-9 relative)", roundTrip < 1e-9, "\(roundTrip)")
    check("LLT1 strength 0 is the identity", LowLight.apply(SIMD3(0.01, 0.02, 0.03), strength: 0) == SIMD3(0.01, 0.02, 0.03))
    let bright = SIMD3(0.9, 0.5, 0.4)
    check("LLT2 a bright pixel (luminance over 0.25) is untouched", LowLight.apply(bright, strength: 1) == bright)
    let dim = SIMD3(0.04, 0.004, 0.004), dimOut = LowLight.apply(dim, strength: 1)
    check("LLT3 a dim red loses red and gains blue (the shift toward blue-green)", dimOut.x < dim.x && dimOut.z > dim.z, "\(dimOut)")
    check("LLT4 the effect is monotone in strength", LowLight.apply(dim, strength: 0.5).x > dimOut.x && LowLight.apply(dim, strength: 0.5).x < dim.x)
    check("LLT5 black stays black and a hostile pixel stays finite", LowLight.apply(.zero, strength: 1) == .zero && LowLight.apply(SIMD3(-0.1, 0.2, 0.0), strength: 1).x.isFinite)

    let k65 = ChannelMixerRGB.illuminantXY(kelvin: 6500), k40 = ChannelMixerRGB.illuminantXY(kelvin: 4000), k50 = ChannelMixerRGB.illuminantXY(kelvin: 5000)
    func within(_ p: SIMD2<Double>, _ x: Double, _ y: Double) -> Bool { abs(p.x - x) < 0.002 && abs(p.y - y) < 0.002 }
    let locusOK = within(k65, 0.3135, 0.3237) && within(k50, 0.3451, 0.3516) && within(k40, 0.3805, 0.3768)
    check("CMX1 the Planckian locus: 6500 K (0.3135, 0.3237), 5000 K (0.3451, 0.3516), 4000 K (0.3805, 0.3768) within 0.002", locusOK, "\(k65) \(k50) \(k40)")
    let ident = [[1.0, 0, 0], [0, 1, 0], [0, 0, 1]]
    check("CMX2 strength 0 (or NaN) is the identity matrix", ChannelMixerRGB.matrix(kelvin: 3000, strength: 0, rows: ident) == ident && ChannelMixerRGB.matrix(kelvin: 3000, strength: .nan, rows: ident) == ident)
    let white = ColorSpaces.workingToXYZ.inverse()!.apply(ChannelMixerRGB.xyz(ChannelMixerRGB.illuminantXY(kelvin: 3200)))
    let adapted = ChannelMixerRGB.adaptation(kelvin: 3200).apply(white)
    let d65w = ColorSpaces.workingToXYZ.inverse()!.apply(ChannelMixerRGB.xyz(ChannelMixerRGB.d65))
    let whiteGap = max(abs(adapted.x - d65w.x), abs(adapted.y - d65w.y), abs(adapted.z - d65w.z))
    check("CMX3 the illuminant's own white maps to D65 white (within 1e-9)", whiteGap < 1e-9, "\(adapted) vs \(d65w)")
    let warm = ChannelMixerRGB.matrix(kelvin: 3000, strength: 1, rows: ident)
    check("CMX4 a warm (3000 K) illuminant is corrected by more blue gain than red gain", warm[2][2] > warm[0][0], "\(warm)")
    let swap = [[0.0, 1, 0], [1, 0, 0], [0, 0, 1]]
    check("CMX5 the mixer rows apply after the adaptation: at strength 0 a red-green swap is the swap itself", ChannelMixerRGB.matrix(kelvin: 5000, strength: 0, rows: swap) == swap)
    check("CMX6 a temperature outside 1667...25000 or NaN is held to it (finite)", ChannelMixerRGB.illuminantXY(kelvin: 100).x.isFinite && ChannelMixerRGB.illuminantXY(kelvin: 1e9).y.isFinite && ChannelMixerRGB.illuminantXY(kelvin: .nan).x.isFinite)
}

// GRN grain, HPF high pass
do {
    let w = 48, h = 36
    var flat = [SIMD3<Double>](repeating: SIMD3(repeating: Transfer.srgbToLinear(0.5)), count: w * h)
    check("GRN1 strength 0 is the identity", Grain.apply(flat, width: w, height: h, strength: 0, size: 1.5, seed: 0) == flat)
    let g = Grain.apply(flat, width: w, height: h, strength: 1, size: 1.5, seed: 0)
    check("GRN2 the same position, size and seed always give the same grain (repeatable)", g == Grain.apply(flat, width: w, height: h, strength: 1, size: 1.5, seed: 0))
    check("GRN3 a different seed gives a different grain", g != Grain.apply(flat, width: w, height: h, strength: 1, size: 1.5, seed: 7))
    check("GRN4 the grain is neutral: all three channels get the same change", g.allSatisfy { abs($0.x - $0.y) < 1e-12 && abs($0.y - $0.z) < 1e-12 })
    var mean = 0.0, minE = 1.0, maxE = 0.0
    for px in g { let e = Transfer.linearToSRGB(px.x); mean += e; minE = min(minE, e); maxE = max(maxE, e) }
    mean /= Double(g.count)
    check("GRN5 on mid-grey the grain averages near 0.5 (within 0.03) and swings by about the amplitude (0.05 to 0.2 each way)",
          abs(mean - 0.5) < 0.03 && maxE - 0.5 > 0.05 && maxE - 0.5 < 0.2 && 0.5 - minE > 0.05 && 0.5 - minE < 0.2, "mean \(mean) min \(minE) max \(maxE)")
    for i in flat.indices { flat[i] = i % 2 == 0 ? .zero : SIMD3(repeating: 1) }
    let gbw = Grain.apply(flat, width: w, height: h, strength: 1, size: 1.5, seed: 0)
    check("GRN6 pure black and pure white get no grain (the midtone weight is 0 there; within 1e-12)",
          zip(gbw, flat).allSatisfy { abs($0.x - $1.x) < 1e-12 && abs($0.y - $1.y) < 1e-12 && abs($0.z - $1.z) < 1e-12 })
    let n = (0..<500).map { Grain.noise(x: Double($0) * 0.37, y: Double($0) * 0.91, size: 3, seed: 1) }
    let nMax = n.map { abs($0) }.max() ?? 0
    var slope = 0.0
    for i in 0..<200 { slope = max(slope, abs(Grain.noise(x: Double(i), y: 5, size: 6, seed: 2) - Grain.noise(x: Double(i + 1), y: 5, size: 6, seed: 2))) }
    check("GRN7 the noise stays within -1...1 and varies smoothly: neighbouring pixels at size 6 never differ by more than the slope bound 2 x 1.5 / 6 = 0.5",
          nMax <= 1 + 1e-12 && slope <= 0.5 + 1e-9, "max \(nMax), neighbour step \(slope)")
}

// GMP gradient map, CRP cross process, BLB bleach bypass, PFT photo filter, CHC channel curves, CHL chroma limit, HRT hue rotate, WRM warmth
do {
    func sw(_ i: Int) -> SIMD3<Double> {
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 0.95 * t
        return SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
    }
    func labC(_ l: Double, _ c: Double, _ hDeg: Double) -> SIMD3<Double> { OkLab.toWorking(SIMD3(l, c * cos(hDeg * .pi / 180), c * sin(hDeg * .pi / 180))) }
    func lch(_ c: SIMD3<Double>) -> SIMD3<Double> { OkLab.lch(OkLab.fromWorking(c)) }
    func gap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    func enc(_ v: Double) -> Double { Transfer.linearToSRGB(v) }
    func lin(_ e: Double) -> Double { Transfer.srgbToLinear(e) }

    // GMP
    let stops = [GradientMap.stop(hueDegrees: 230, saturation: 0.7), GradientMap.stop(hueDegrees: 0, saturation: 0), GradientMap.stop(hueDegrees: 60, saturation: 0.6)]
    var idG = 0.0
    for i in 0..<4096 { let c = sw(i); idG = max(idG, gap(GradientMap.apply(c, strength: 0, stops: stops), c) / max(abs(c.x), 1e-6)) }
    check("GMP1 strength 0 is the identity (within 1e-9 relative)", idG < 1e-9, "\(idG)")
    let mid = lch(GradientMap.apply(labC(0.5, 0.1, 40), strength: 1, stops: stops))
    check("GMP2 at lightness 0.5 the midtone stop (grey) takes all the chroma away, lightness kept (within 1e-9)", mid.y < 1e-9 && abs(mid.x - 0.5) < 1e-9, "\(mid)")
    let hi = OkLab.fromWorking(GradientMap.apply(labC(1.0, 0.05, 200), strength: 1, stops: stops))
    check("GMP3 at lightness 1 the highlight stop's (a, b) is taken exactly (within 1e-9)", abs(hi.y - stops[2].x) < 1e-9 && abs(hi.z - stops[2].y) < 1e-9, "\(hi) vs \(stops[2])")
    let q = OkLab.fromWorking(GradientMap.apply(labC(0.25, 0.05, 200), strength: 1, stops: stops))
    let want = stops[0] + (stops[1] - stops[0]) * ColorCommon.smoothstep(0, 0.5, 0.25)
    check("GMP4 at lightness 0.25 the stop is the smoothstep blend of shadows and midtones (within 1e-9)", abs(q.y - want.x) < 1e-9 && abs(q.z - want.y) < 1e-9)
    let wildG = GradientMap.apply(SIMD3(-1, 5, .nan), strength: 1, stops: stops)
    check("GMP5 hostile pixels stay finite or are the input (no crash)", wildG.x.isFinite || wildG.x.isNaN)

    // CRP
    var idC = 0.0
    for i in 0..<4096 { let c = sw(i); idC = max(idC, gap(CrossProcess.apply(c, amount: 0), c) / max(abs(c.x), 1e-6)) }
    check("CRP1 amount 0 is the identity (within 1e-9 relative)", idC < 1e-9, "\(idC)")
    let cm = CrossProcess.apply(SIMD3(repeating: lin(0.5)), amount: 1)
    check("CRP2 encoded 0.5 stays 0.5 in red and green and blue is lifted to 0.525 (within 1e-9)",
          abs(enc(cm.x) - 0.5) < 1e-9 && abs(enc(cm.y) - 0.5) < 1e-9 && abs(enc(cm.z) - 0.525) < 1e-9, "\(enc(cm.x)) \(enc(cm.y)) \(enc(cm.z))")
    let cr = CrossProcess.apply(SIMD3(repeating: lin(0.25)), amount: 1)
    check("CRP3 red at encoded 0.25 follows the full S-curve: smoothstep(0.25) = 0.15625 (within 1e-9)", abs(enc(cr.x) - 0.15625) < 1e-9, "\(enc(cr.x))")
    let ends = CrossProcess.apply(SIMD3(0, 1, 1), amount: 1)
    check("CRP4 black gets only the blue lift (0, 0, 0.05) and white stays white", abs(ends.x) < 1e-9 && abs(enc(ends.y) - 1) < 1e-9 && abs(enc(ends.z) - 1) < 1e-9)

    // BLB
    var idB = 0.0
    for i in 0..<4096 { let c = sw(i); idB = max(idB, gap(BleachBypass.apply(c, strength: 0), c) / max(abs(c.x), 1e-6)) }
    check("BLB1 strength 0 is the identity (within 1e-9 relative)", idB < 1e-9, "\(idB)")
    let b25 = BleachBypass.apply(SIMD3(repeating: lin(0.25)), strength: 1), b75 = BleachBypass.apply(SIMD3(repeating: lin(0.75)), strength: 1)
    check("BLB2 a neutral gets the overlay contrast: 0.25 -> 0.125, 0.75 -> 0.875, 0.5 stays (within 1e-9)",
          abs(enc(b25.x) - 0.125) < 1e-9 && abs(enc(b75.x) - 0.875) < 1e-9 && abs(enc(BleachBypass.apply(SIMD3(repeating: lin(0.5)), strength: 1).x) - 0.5) < 1e-9)
    let col = labC(0.6, 0.15, 30)
    check("BLB3 a saturated colour loses chroma", lch(BleachBypass.apply(col, strength: 1)).y < lch(col).y * 0.8, "\(lch(BleachBypass.apply(col, strength: 1)).y) vs \(lch(col).y)")
    let wildB = BleachBypass.apply(SIMD3(-1, 9, .nan), strength: 1)
    check("BLB4 below black, above white and NaN stay finite and in 0...1", [wildB.x, wildB.y, wildB.z].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(wildB)")

    // PFT
    var idP = 0.0
    for i in 0..<4096 { let c = sw(i); idP = max(idP, gap(PhotoFilter.apply(c, hueDegrees: 45, density: 0, preserve: 1), c) / max(abs(c.x), 1e-6)) }
    check("PFT1 density 0 is the identity (within 1e-9 relative)", idP < 1e-9, "\(idP)")
    var lumGap = 0.0
    for i in 0..<512 { let c = sw(i * 8), o = PhotoFilter.apply(c, hueDegrees: Double(i) * 0.7, density: 0.8, preserve: 1); lumGap = max(lumGap, abs(ColorCommon.luminance(o) - ColorCommon.luminance(c)) / max(ColorCommon.luminance(c), 1e-6)) }
    check("PFT2 preserve 1 keeps the luminance (within 1e-9 relative)", lumGap < 1e-9, "\(lumGap)")
    let grey = SIMD3(repeating: 0.3)
    check("PFT3 preserve 0 lets the filter change the luminance", abs(ColorCommon.luminance(PhotoFilter.apply(grey, hueDegrees: 230, density: 1, preserve: 0)) - 0.3) > 1e-3)
    let warm = PhotoFilter.apply(grey, hueDegrees: 45, density: 1, preserve: 1)
    check("PFT4 a 45 degree filter makes a grey redder than blue", warm.x > warm.z, "\(warm)")
    check("PFT5 black stays black", PhotoFilter.apply(.zero, hueDegrees: 45, density: 1, preserve: 1) == .zero)

    // CHC
    let idH: [Double] = [0.25, 0.5, 0.75, 0.25, 0.5, 0.75, 0.25, 0.5, 0.75]
    var idCh = 0.0
    for i in 0..<4096 { let c = sw(i); idCh = max(idCh, gap(ChannelCurves.apply(c, heights: idH), c) / max(abs(c.x), 1e-6)) }
    check("CHC1 the default nodes are the identity (within 1e-9 relative)", idCh < 1e-9, "\(idCh)")
    var h2 = idH; h2[4] = 0.7
    let g2 = ChannelCurves.apply(SIMD3(repeating: lin(0.5)), heights: h2)
    check("CHC2 raising the green middle node moves green only (red and blue stay at encoded 0.5)", abs(enc(g2.x) - 0.5) < 1e-9 && enc(g2.y) > 0.6 && abs(enc(g2.z) - 0.5) < 1e-9, "\(enc(g2.x)) \(enc(g2.y)) \(enc(g2.z))")
    let direct = ToneCurve.apply(lin(0.4), xs: ChannelCurves.xs, ys: [0, 0.25, 0.7, 0.75, 1])
    check("CHC3 a channel is the tone curve's own curve through its nodes (within 1e-12)", abs(ChannelCurves.apply(SIMD3(repeating: lin(0.4)), heights: h2).y - direct) < 1e-12)
    check("CHC4 the kernel's uniforms are three blocks of 25", ChannelCurves.uniforms(heights: h2).count == 75)
    let hostileH = ChannelCurves.apply(SIMD3(0.3, 0.3, 0.3), heights: [0.9, 0.1, 5, .nan, -2, 0.5, 0.5, 0.5, 0.5])
    check("CHC5 hostile node heights (unsorted, out of range, NaN) are made safe: finite output", hostileH.x.isFinite && hostileH.y.isFinite && hostileH.z.isFinite, "\(hostileH)")

    // CHL
    var idL = 0.0
    for i in 0..<4096 { let c = sw(i); idL = max(idL, gap(ChromaLimit.apply(c, limit: 0.4), c) / max(abs(c.x), 1e-6)) }
    check("CHL1 a limit of 0.4 or more is no limit (within 1e-9 relative)", idL < 1e-9, "\(idL)")
    let low = labC(0.6, 0.1, 40)
    check("CHL2 chroma below the knee (0.8 of the limit) is untouched (within 1e-9)", gap(ChromaLimit.apply(low, limit: 0.2), low) < 1e-9)
    let vivid = labC(0.6, 0.35, 40), lim = lch(ChromaLimit.apply(vivid, limit: 0.2))
    check("CHL3 chroma above the knee comes out below the limit and above the knee", lim.y < 0.2 && lim.y > 0.16, "\(lim.y)")
    check("CHL4 hue and lightness are kept (within 1e-9)", abs(lim.x - 0.6) < 1e-9 && abs(ColorCommon.hueDifference(lim.z, 40 * .pi / 180)) < 1e-9, "\(lim)")
    check("CHL5b an extreme chroma (50) against a tiny limit (0.05) is finite and at the limit", abs(ChromaLimit.compress(50, limit: 0.05) - 0.05) < 1e-9)
    check("CHL5 the compression is continuous at the knee and increasing", abs(ChromaLimit.compress(0.16 + 1e-12, limit: 0.2) - 0.16) < 1e-9 && ChromaLimit.compress(0.3, limit: 0.2) > ChromaLimit.compress(0.25, limit: 0.2))

    // HRT
    var idR = 0.0
    for i in 0..<4096 { let c = sw(i); idR = max(idR, gap(HueRotate.apply(c, degrees: 0), c) / max(abs(c.x), 1e-6), gap(HueRotate.apply(c, degrees: 360), c) / max(abs(c.x), 1e-6)) }
    check("HRT1 0 and 360 degrees are the identity (within 1e-9 relative)", idR < 1e-9, "\(idR)")
    let rot = lch(HueRotate.apply(labC(0.6, 0.1, 40), degrees: 90))
    check("HRT2 90 degrees turns the hue by 90 and keeps lightness and chroma (within 1e-9)",
          abs(ColorCommon.hueDifference(rot.z, 130 * .pi / 180)) < 1e-9 && abs(rot.x - 0.6) < 1e-9 && abs(rot.y - 0.1) < 1e-9, "\(rot)")
    let g3 = SIMD3(repeating: 0.3)
    check("HRT3 a grey stays grey", gap(HueRotate.apply(g3, degrees: 77), g3) < 1e-9)
    let there = HueRotate.apply(labC(0.5, 0.12, 200), degrees: 30), back = HueRotate.apply(there, degrees: -30)
    check("HRT4 +30 then -30 degrees is the identity (within 1e-9)", gap(back, labC(0.5, 0.12, 200)) < 1e-9)

    // WRM
    var idW = 0.0
    for i in 0..<4096 { let c = sw(i); idW = max(idW, gap(Warmth.apply(c, warmth: 0, tint: 0), c) / max(abs(c.x), 1e-6)) }
    check("WRM1 zero warmth and tint are the identity (within 1e-9 relative)", idW < 1e-9, "\(idW)")
    let wl = OkLab.fromWorking(Warmth.apply(labC(0.6, 0.0, 0), warmth: 1, tint: 0))
    check("WRM2 warmth +1 at lightness 0.6 adds +0.04 to b and +0.01 to a, lightness kept (within 1e-9)", abs(wl.z - 0.04) < 1e-9 && abs(wl.y - 0.01) < 1e-9 && abs(wl.x - 0.6) < 1e-9, "\(wl)")
    check("WRM3 black takes no cast (within 1e-12)", gap(Warmth.apply(.zero, warmth: 1, tint: 1), .zero) < 1e-12)
    let tl = OkLab.fromWorking(Warmth.apply(labC(0.6, 0.0, 0), warmth: 0, tint: 1))
    check("WRM4 tint +1 adds +0.03 to a and nothing to b (within 1e-9)", abs(tl.y - 0.03) < 1e-9 && abs(tl.z) < 1e-9, "\(tl)")
}

// HRO highlight roll-off, LMB luminosity bands, HDT HDR tone, FDL fade look, LMC luminosity curve, RHD Reinhard, SCC S-curve
do {
    func sw(_ i: Int) -> SIMD3<Double> {
        let t = Double(i) / 4095, h = t * 37 * 2 * .pi, v = 0.002 + 0.95 * t
        return SIMD3(v * (0.6 + 0.4 * cos(h)), v * (0.6 + 0.4 * cos(h - 2.1)), v * (0.6 + 0.4 * cos(h + 2.1)))
    }
    func gap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    func enc(_ v: Double) -> Double { Transfer.linearToSRGB(v) }
    func lin(_ e: Double) -> Double { Transfer.srgbToLinear(e) }
    func finite(_ c: SIMD3<Double>) -> Bool { c.x.isFinite && c.y.isFinite && c.z.isFinite }

    // HRO
    var idH = 0.0
    for i in 0..<4096 { let c = sw(i); idH = max(idH, gap(HighlightRolloff.apply(c, white: 1, knee: 0.7, amount: 0), c) / max(c.x, 1e-6)) }
    check("HRO1 amount 0 is the identity (within 1e-9 relative)", idH < 1e-9, "\(idH)")
    let dim = SIMD3(0.2, 0.15, 0.1)
    check("HRO2 luminance below the knee is untouched", HighlightRolloff.apply(dim, white: 1, knee: 0.7, amount: 1) == dim)
    let hot = SIMD3(1.8, 1.2, 0.9), rolled = HighlightRolloff.apply(hot, white: 1, knee: 0.7, amount: 1)
    let yRolled = ColorCommon.luminance(rolled)
    check("HRO3 luminance above the knee lands between the knee and the white, colour ratios kept (within 1e-9)",
          yRolled > 0.7 && yRolled < 1 && abs(rolled.x / rolled.y - hot.x / hot.y) < 1e-9 && abs(rolled.y / rolled.z - hot.y / hot.z) < 1e-9, "\(yRolled)")
    check("HRO4 continuous at the knee and increasing", abs(HighlightRolloff.compress(0.7 + 1e-12, white: 1, knee: 0.7) - 0.7) < 1e-9
          && HighlightRolloff.compress(2, white: 1, knee: 0.7) > HighlightRolloff.compress(1, white: 1, knee: 0.7))
    check("HRO5 a huge luminance is finite and at the white; zero and negative are left alone",
          abs(HighlightRolloff.compress(1e9, white: 1, knee: 0.7) - 1) < 1e-9 && HighlightRolloff.apply(.zero, white: 1, knee: 0.7, amount: 1) == .zero
          && HighlightRolloff.apply(SIMD3(-1, 0.1, 0.1), white: 1, knee: 0.7, amount: 1) == SIMD3(-1, 0.1, 0.1))

    // LMB
    var idB = 0.0
    for i in 0..<4096 { let c = sw(i); idB = max(idB, gap(LumaBands.apply(c, evs: [0, 0, 0, 0, 0]), c) / max(c.x, 1e-6)) }
    check("LMB1 zero bands are the identity (within 1e-9 relative)", idB < 1e-9, "\(idB)")
    var globalGap = 0.0
    for i in 0..<512 { let c = sw(i * 8); globalGap = max(globalGap, gap(LumaBands.apply(c, evs: [1, 1, 1, 1, 1]), c * 2) / max(c.x, 1e-6)) }
    check("LMB2 the same change on every band is exactly a global exposure (+1 EV doubles, within 1e-9)", globalGap < 1e-9, "\(globalGap)")
    let shadowPx = SIMD3(repeating: 0.18 * 0.25)
    check("LMB3 a pixel at the shadows centre (-2 EV) takes the shadows change alone: +1 EV doubles it",
          gap(LumaBands.apply(shadowPx, evs: [0, 1, 0, 0, 0]), shadowPx * 2) < 1e-9)
    var jump = 0.0, prev = LumaBands.gain(logLuminance: -7, evs: [1.5, -1, 2, -2, 1])
    var b = -7.0
    while b < 5 { b += 0.001; let g = LumaBands.gain(logLuminance: b, evs: [1.5, -1, 2, -2, 1]); jump = max(jump, abs(g - prev)); prev = g }
    check("LMB4 the gain is continuous over luminance (no step over 0.01 per 1/1000 EV)", jump < 0.01, "\(jump)")
    let px = SIMD3(0.3, 0.2, 0.1), out = LumaBands.apply(px, evs: [0.5, -0.5, 1, -1, 0.5])
    // LMB7 no tone inversion: the curve (log luminance out against log luminance in) never falls, whatever the band changes
    var worstSlope = Double.infinity
    let sets: [[Double]] = [[0, 3, 0, 0, 0], [3, 0, 0, 0, 0], [0, 0, 0, 0, -3], [3, -3, 3, -3, 3], [-3, 3, -3, 3, -3], [0, 0, 3, -3, 0], [1.5, -1, 2, -2, 1], [0, -3, 0, 0, 0]]
    for evs in sets {
        var b = -7.0, prevOut = b + LumaBands.gain(logLuminance: b, evs: evs)
        while b < 5 { b += 0.01; let out = b + LumaBands.gain(logLuminance: b, evs: evs); worstSlope = min(worstSlope, (out - prevOut) / 0.01); prevOut = out }
    }
    check("LMB7 the band curve never falls (no tone inversion, so no contour lines): the least slope over eight extreme band sets is positive (\(worstSlope))", worstSlope > 0.05, "\(worstSlope)")
    check("LMB8 a lifted band flattens its neighbours instead of inverting them: shadows +3 puts the shadows node 3 EV up and midtones at most 1.5 EV up",
          abs(LumaBands.gain(logLuminance: -2, evs: [0, 3, 0, 0, 0]) - 3) < 1e-9 && LumaBands.gain(logLuminance: 0, evs: [0, 3, 0, 0, 0]) < 1.5)
    check("LMB5 colour ratios are kept; black stays finite", abs(out.x / out.y - px.x / px.y) < 1e-9 && finite(LumaBands.apply(.zero, evs: [1, 1, 1, 1, 1])))

    // HDT
    let w = 48, h = 32
    var half = [SIMD3<Double>](repeating: SIMD3(repeating: 0.02), count: w * h)
    for y in 0..<h { for x in w / 2..<w { half[y * w + x] = SIMD3(repeating: 1.0) } }
    check("HDT1 amount 0 is the identity", HdrTone.apply(half, width: w, height: h, amount: 0, scale: 0.1) == half)
    let comp = HdrTone.apply(half, width: w, height: h, amount: 0.5, scale: 0.1)
    let ratioBefore = half[10 * w + 40].x / half[10 * w + 5].x, ratioAfter = comp[10 * w + 40].x / comp[10 * w + 5].x
    check("HDT2 amount 0.5 pulls the bright and dark halves toward each other: their ratio shrinks", ratioAfter < ratioBefore * 0.7, "\(ratioBefore) -> \(ratioAfter)")
    var textured = [SIMD3<Double>](repeating: SIMD3(repeating: 0.5), count: w * h)
    for y in 0..<h { for x in 0..<w { textured[y * w + x] = SIMD3(repeating: 0.5 * ((x + y) % 2 == 0 ? 1.04 : 0.96)) } }
    let tc = HdrTone.apply(textured, width: w, height: h, amount: 0.8, scale: 0.2)
    let detailBefore = textured[16 * w + 24].x / textured[16 * w + 25].x, detailAfter = tc[16 * w + 24].x / tc[16 * w + 25].x
    check("HDT3 the detail stays: neighbouring pixels keep their ratio within 2% while the whole region is moved", abs(detailAfter / detailBefore - 1) < 0.02 && tc[16 * w + 24].x != textured[16 * w + 24].x, "\(detailBefore) -> \(detailAfter)")
    check("HDT4 the gain is held to the base range: a base of +10 EV gets the +3 EV gain, -20 gets -7", abs(HdrTone.gainEV(base: 10, amount: 1) + 3) < 1e-12 && abs(HdrTone.gainEV(base: -20, amount: 1) - 7) < 1e-12)
    check("HDT5 a NaN base is no gain and a hostile picture stays finite", HdrTone.gainEV(base: .nan, amount: 1) == 0 && HdrTone.apply([SIMD3(0, 0, 0), SIMD3(5, 5, 5), SIMD3(-1, 0, 0), SIMD3(0.1, 0.1, 0.1)], width: 2, height: 2, amount: 1, scale: 0.1).allSatisfy(finite))

    // FDL
    var idF = 0.0
    for i in 0..<4096 { let c = sw(i); idF = max(idF, gap(FadeLook.apply(c, black: 0, white: 0), c) / max(c.x, 1e-6)) }
    check("FDL1 zero fade is the identity (within 1e-9 relative)", idF < 1e-9, "\(idF)")
    let fb = FadeLook.apply(SIMD3(0, 1, lin(0.5)), black: 0.1, white: 0.1)
    check("FDL2 black 0.1 lifts encoded black to 0.1, white 0.1 pulls white to 0.9, mid grey stays 0.5 (within 1e-9)",
          abs(enc(fb.x) - 0.1) < 1e-9 && abs(enc(fb.y) - 0.9) < 1e-9 && abs(enc(fb.z) - 0.5) < 1e-9, "\(enc(fb.x)) \(enc(fb.y)) \(enc(fb.z))")
    check("FDL3 the fade stays monotone", (1..<100).allSatisfy { FadeLook.apply(SIMD3(repeating: Double($0) / 100), black: 0.15, white: 0.2).x >= FadeLook.apply(SIMD3(repeating: Double($0 - 1) / 100), black: 0.15, white: 0.2).x })
    check("FDL4 below black, above white and NaN stay finite", finite(FadeLook.apply(SIMD3(-1, 9, .nan), black: 0.1, white: 0.1)))

    // LMC
    func labC(_ l: Double, _ c: Double, _ hDeg: Double) -> SIMD3<Double> { OkLab.toWorking(SIMD3(l, c * cos(hDeg * .pi / 180), c * sin(hDeg * .pi / 180))) }
    var idL = 0.0
    for i in 0..<2048 { let c = labC(0.05 + 0.9 * Double(i) / 2047, 0.08, Double(i) * 3); idL = max(idL, gap(LumaCurve.apply(c, ys: [0, 0.25, 0.5, 0.75, 1]), c) / max(c.x, 1e-6)) }
    check("LMC1 the default nodes are the identity (within 1e-9 relative)", idL < 1e-9, "\(idL)")
    let ys = [0.0, 0.1, 0.4, 0.8, 1.0], c0 = labC(0.5, 0.1, 40), c1 = OkLab.fromWorking(LumaCurve.apply(c0, ys: ys)), l0 = OkLab.fromWorking(c0)
    check("LMC2 chroma (a, b) is unchanged (within 1e-9)", abs(c1.y - l0.y) < 1e-9 && abs(c1.z - l0.z) < 1e-9, "\(c1) \(l0)")
    let pts = ToneCurve.sanitized(xs: ToneCurve.legacyXs, ys: ys)
    check("LMC3 the new lightness is the tone curve through the nodes at the old lightness (within 1e-9)",
          abs(c1.x - ToneCurve.curve(0.5, xs: pts.xs, ys: pts.ys, tangents: ToneCurve.tangents(xs: pts.xs, ys: pts.ys))) < 1e-9, "\(c1.x)")
    check("LMC4 raising the middle node brightens mid lightness", OkLab.fromWorking(LumaCurve.apply(labC(0.5, 0.05, 10), ys: [0, 0.25, 0.7, 0.75, 1])).x > 0.55)
    check("LMC5 NaN and out-of-range pixels stay finite", finite(LumaCurve.apply(SIMD3(-1, 7, 0.2), ys: ys)))

    // RHD
    var idR = 0.0
    for i in 0..<4096 { let c = sw(i); idR = max(idR, gap(Reinhard.apply(c, white: 4, amount: 0), c) / max(c.x, 1e-6)) }
    check("RHD1 amount 0 is the identity (within 1e-9 relative)", idR < 1e-9, "\(idR)")
    let atW = Reinhard.apply(SIMD3(repeating: 4), white: 4, amount: 1)
    check("RHD2 the white point maps to exactly 1 (luminance 4 with W = 4, within 1e-9)", abs(ColorCommon.luminance(atW) - 1) < 1e-9, "\(ColorCommon.luminance(atW))")
    let rc = Reinhard.apply(SIMD3(0.6, 0.3, 0.1), white: 4, amount: 1)
    check("RHD3 colour ratios are kept (within 1e-9)", abs(rc.x / rc.y - 2) < 1e-9 && abs(rc.y / rc.z - 3) < 1e-9)
    let rh = Reinhard.apply(SIMD3(0.5, 0.5, 0.5), white: 4, amount: 0.5), rf = Reinhard.apply(SIMD3(0.5, 0.5, 0.5), white: 4, amount: 1)
    check("RHD4 amount 0.5 is halfway between the picture and the full operator (within 1e-9)", abs(rh.x - (0.5 + rf.x) / 2) < 1e-9)
    check("RHD5 zero and negative luminance are left alone", Reinhard.apply(.zero, white: 4, amount: 1) == .zero && Reinhard.apply(SIMD3(-1, 0.1, 0.1), white: 4, amount: 1) == SIMD3(-1, 0.1, 0.1))

    // SCC
    var idS = 0.0
    for i in 0..<4096 { let c = sw(i); idS = max(idS, gap(SCurve.apply(c, contrast: 0, pivot: 0.5), c) / max(c.x, 1e-6)) }
    check("SCC1 contrast 0 is the identity (within 1e-9 relative)", idS < 1e-9, "\(idS)")
    let fixed = SCurve.apply(SIMD3(0, lin(0.4), 1), contrast: 0.8, pivot: 0.4)
    check("SCC2 black, white and the pivot stay where they are (within 1e-9)", abs(fixed.x) < 1e-9 && abs(enc(fixed.y) - 0.4) < 1e-9 && abs(enc(fixed.z) - 1) < 1e-9)
    let up = SCurve.apply(SIMD3(lin(0.25), lin(0.75), lin(0.5)), contrast: 0.8, pivot: 0.5), dn = SCurve.apply(SIMD3(lin(0.25), lin(0.75), lin(0.5)), contrast: -0.8, pivot: 0.5)
    check("SCC3 contrast up darkens below the pivot and lightens above; contrast down does the opposite", enc(up.x) < 0.25 && enc(up.y) > 0.75 && enc(dn.x) > 0.25 && enc(dn.y) < 0.75)
    check("SCC4 the exponent is 2^(1.5 contrast): 1 at 0, 2 at 2/3", abs(SCurve.exponent(contrast: 0) - 1) < 1e-12 && abs(SCurve.exponent(contrast: 2.0 / 3) - 2) < 1e-12)
    let wild = SCurve.apply(SIMD3(-1, 9, .nan), contrast: 1, pivot: 0.5)
    check("SCC5 below black, above white and NaN stay finite and in 0...1", [wild.x, wild.y, wild.z].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(wild)")
}

// DCV deconvolution, CDN chroma denoise, MDN median, DBD deband, SKS skin smooth, TXB texture bands, HLT halation
do {
    func gap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    func allGap(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double { zip(a, b).map { gap($0, $1) }.max() ?? 0 }
    func finiteAll(_ a: [SIMD3<Double>]) -> Bool { a.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } }
    let w = 40, h = 24
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: w * h)
    var step = [SIMD3<Double>](repeating: SIMD3(repeating: 0.1), count: w * h)
    for y in 0..<h { for x in w / 2..<w { step[y * w + x] = SIMD3(repeating: 0.9) } }

    // DCV
    check("DCV1 amount 0, radius 0 or no iterations is the identity", Deconvolution.apply(step, width: w, height: h, radius: 2, iterations: 4, amount: 0) == step
          && Deconvolution.apply(step, width: w, height: h, radius: 0, iterations: 4, amount: 1) == step && Deconvolution.apply(step, width: w, height: h, radius: 2, iterations: 0, amount: 1) == step)
    check("DCV2 a flat picture is a fixed point (within 1e-9)", allGap(Deconvolution.apply(flat, width: w, height: h, radius: 2, iterations: 5, amount: 1), flat) < 1e-9)
    let blurredStep = Blur.apply(step, width: w, height: h, radius: 2)
    func err(_ a: [SIMD3<Double>]) -> Double { zip(a, step).map { pow($0.x - $1.x, 2) }.reduce(0, +) }
    let restored2 = Deconvolution.apply(blurredStep, width: w, height: h, radius: 2, iterations: 2, amount: 1)
    let restored = Deconvolution.apply(blurredStep, width: w, height: h, radius: 2, iterations: 8, amount: 1)
    let restored40 = Deconvolution.apply(blurredStep, width: w, height: h, radius: 2, iterations: 40, amount: 1)
    check("DCV3 deconvolving a blurred step converges toward the step: the error falls with the iterations (blur > 2 > 8 > 40) and ends under 70% of the blur's",
          err(blurredStep) > err(restored2) && err(restored2) > err(restored) && err(restored) > err(restored40) && err(restored40) < 0.7 * err(blurredStep),
          "blur \(err(blurredStep)), 2: \(err(restored2)), 8: \(err(restored)), 40: \(err(restored40))")
    var pointImg = [SIMD3<Double>](repeating: SIMD3(repeating: 0.05), count: w * h)
    pointImg[12 * w + 20] = SIMD3(repeating: 5)
    let blurredPoint = Blur.apply(pointImg, width: w, height: h, radius: 2)
    let sharpPoint = Deconvolution.apply(blurredPoint, width: w, height: h, radius: 2, iterations: 20, amount: 1)
    check("DCV3b a blurred point source regains its peak: the peak after 20 iterations is at least 2x the blurred peak and above the 5-iteration peak", sharpPoint[12 * w + 20].x > 2 * blurredPoint[12 * w + 20].x && sharpPoint[12 * w + 20].x > Deconvolution.apply(blurredPoint, width: w, height: h, radius: 2, iterations: 5, amount: 1)[12 * w + 20].x,
          "\(blurredPoint[12 * w + 20].x) -> \(sharpPoint[12 * w + 20].x)")
    let lightIn = blurredStep.map { $0.x }.reduce(0, +), lightOut = restored.map { $0.x }.reduce(0, +)
    check("DCV4 the light is conserved within 2%", abs(lightOut / lightIn - 1) < 0.02, "\(lightIn) -> \(lightOut)")
    let wildD = Deconvolution.apply([SIMD3(0, 0, 0), SIMD3(-1, 5, 1e6), SIMD3(0.2, 0.2, 0.2), SIMD3(0, 9, 0)], width: 2, height: 2, radius: 1, iterations: 6, amount: 1)
    check("DCV5 black, negative and huge values stay finite", finiteAll(wildD), "\(wildD)")

    // CDN
    func labOf(_ c: SIMD3<Double>) -> SIMD3<Double> { OkLab.fromWorking(c) }
    var noisy = [SIMD3<Double>](repeating: .zero, count: w * h)
    var seed: UInt64 = 7
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
    for i in noisy.indices { noisy[i] = OkLab.toWorking(SIMD3(0.5, 0.06 * rnd(), 0.06 * rnd())) }
    check("CDN1 amount 0 or radius 0 is the identity", ChromaDenoise.apply(noisy, width: w, height: h, radius: 4, amount: 0) == noisy && ChromaDenoise.apply(noisy, width: w, height: h, radius: 0, amount: 1) == noisy)
    check("CDN2 a flat picture stays flat (within 1e-9)", allGap(ChromaDenoise.apply(flat, width: w, height: h, radius: 4, amount: 1), flat) < 1e-9)
    let den = ChromaDenoise.apply(noisy, width: w, height: h, radius: 5, amount: 1)
    func chromaVar(_ a: [SIMD3<Double>]) -> Double { a.map { pow(labOf($0).y, 2) + pow(labOf($0).z, 2) }.reduce(0, +) / Double(a.count) }
    check("CDN3 the chroma noise power drops to under 30% and the lightness is unchanged (within 1e-9)",
          chromaVar(den) < 0.3 * chromaVar(noisy) && zip(den, noisy).allSatisfy { abs(labOf($0).x - labOf($1).x) < 1e-9 }, "\(chromaVar(den)) vs \(chromaVar(noisy))")
    var edge = [SIMD3<Double>](repeating: OkLab.toWorking(SIMD3(0.3, 0.1, 0)), count: w * h)
    for y in 0..<h { for x in w / 2..<w { edge[y * w + x] = OkLab.toWorking(SIMD3(0.8, -0.1, 0)) } }
    let ed = ChromaDenoise.apply(edge, width: w, height: h, radius: 4, amount: 1)
    check("CDN4 a colour edge that is also a luminance edge is kept (a stays within 0.03 of each side's value)",
          abs(labOf(ed[10 * w + 18]).y - 0.1) < 0.03 && abs(labOf(ed[10 * w + 21]).y + 0.1) < 0.03, "\(labOf(ed[10 * w + 18]).y) \(labOf(ed[10 * w + 21]).y)")
    let half = ChromaDenoise.apply(noisy, width: w, height: h, radius: 5, amount: 0.5)
    check("CDN5 amount 0.5 is halfway between the picture and the full result (a plane, within 1e-9)",
          abs(labOf(half[300]).y - (labOf(noisy[300]).y + labOf(den[300]).y) / 2) < 1e-9)

    // MDN
    var hot = flat
    hot[12 * w + 20] = SIMD3(100, 100, 100)
    check("MDN1 amount 0 or radius 0 is the identity", MedianDenoise.apply(hot, width: w, height: h, radius: 1, amount: 0) == hot && MedianDenoise.apply(hot, width: w, height: h, radius: 0, amount: 1) == hot)
    check("MDN2 an isolated hot pixel is removed (radius 1) and nothing else changes (within 1e-9)", allGap(MedianDenoise.apply(hot, width: w, height: h, radius: 1, amount: 1), flat) < 1e-9)
    check("MDN3 a step edge is kept exactly (3 x 3 median of a straight edge)", MedianDenoise.apply(step, width: w, height: h, radius: 1, amount: 1) == step)
    var block = flat
    for dy in -1...1 { for dx in -1...1 { block[(12 + dy) * w + 20 + dx] = SIMD3(100, 100, 100) } }
    check("MDN4 a 3 x 3 hot block survives the 3 x 3 median at its centre but not the 5 x 5",
          MedianDenoise.apply(block, width: w, height: h, radius: 1, amount: 1)[12 * w + 20].x == 100 && abs(MedianDenoise.apply(block, width: w, height: h, radius: 2, amount: 1)[12 * w + 20].x - 0.3) < 1e-9)
    let mh = MedianDenoise.apply(hot, width: w, height: h, radius: 1, amount: 0.5)
    check("MDN5 amount 0.5 is halfway (within 1e-9)", abs(mh[12 * w + 20].x - (100 + 0.3) / 2) < 1e-9)

    // DBD
    var ramp = [SIMD3<Double>](repeating: .zero, count: w * h), truth = ramp
    for y in 0..<h { for x in 0..<w {
        let e = 0.30 + 0.20 * Double(x) / Double(w - 1)
        truth[y * w + x] = SIMD3(repeating: Transfer.srgbToLinear(e))
        ramp[y * w + x] = SIMD3(repeating: Transfer.srgbToLinear((e * 100).rounded(.down) / 100))
    } }
    check("DBD1 strength 0 or radius 0 is the identity", Deband.apply(ramp, width: w, height: h, radius: 6, threshold: 0.02, strength: 0) == ramp && Deband.apply(ramp, width: w, height: h, radius: 0, threshold: 0.02, strength: 1) == ramp)
    let db = Deband.apply(ramp, width: w, height: h, radius: 9, threshold: 0.02, strength: 1)
    func rampErr(_ a: [SIMD3<Double>]) -> Double { (12..<(w - 12)).map { pow(a[12 * w + $0].x - truth[12 * w + $0].x, 2) }.reduce(0, +) }
    check("DBD2 a ramp quantised to 100 levels comes out closer to the true ramp (error under 50%)", rampErr(db) < 0.5 * rampErr(ramp), "\(rampErr(db)) vs \(rampErr(ramp))")
    let dbEdge = Deband.apply(step, width: w, height: h, radius: 9, threshold: 0.02, strength: 1)
    check("DBD3 a hard edge is not smoothed at its own pixels (within 1e-9)", gap(dbEdge[10 * w + 19], step[10 * w + 19]) < 1e-9 && gap(dbEdge[10 * w + 20], step[10 * w + 20]) < 1e-9)
    check("DBD4 a larger threshold smooths at least as much (error not larger)", rampErr(Deband.apply(ramp, width: w, height: h, radius: 9, threshold: 0.05, strength: 1)) <= rampErr(db) + 1e-12)
    check("DBD5 a flat picture stays flat (within 1e-9)", allGap(Deband.apply(flat, width: w, height: h, radius: 6, threshold: 0.02, strength: 1), flat) < 1e-9)

    // SKS
    var skin = [SIMD3<Double>](repeating: .zero, count: w * h)
    for i in skin.indices { skin[i] = OkLab.toWorking(SIMD3(0.65 + 0.03 * rnd(), 0.06 + 0.01 * rnd(), 0.08 + 0.01 * rnd())) }
    // SKS-dark: dark, finely textured skin-hued detail (hair, shadow) keeps its texture. On scene-linear values the absolute eps called it flat and averaged it into clumps.
    var darkHair = [SIMD3<Double>](repeating: .zero, count: w * h)
    for y in 0..<h { for x in 0..<w { darkHair[y * w + x] = OkLab.toWorking(SIMD3(0.22 + ((x + y) % 2 == 0 ? 0.05 : -0.05), 0.04, 0.05)) } }
    func lumaSpread(_ img: [SIMD3<Double>]) -> Double {
        let ys = img.map { sqrt(ColorCommon.luminance($0)) }; let m = ys.reduce(0, +) / Double(ys.count)
        return (ys.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(ys.count)).squareRoot()
    }
    let hairKept = lumaSpread(SkinSmooth.apply(darkHair, width: w, height: h, radius: 5, amount: 1, hueDegrees: 55, widthDegrees: 35)) / lumaSpread(darkHair)
    print("      SKS-dark texture kept: \(hairKept)")
    check("SKS-dark dark fine texture keeps at least 35 percent of its contrast (\(hairKept))", hairKept > 0.35, "\(hairKept)")
    check("SKS1 amount 0 or radius 0 is the identity", SkinSmooth.apply(skin, width: w, height: h, radius: 5, amount: 0, hueDegrees: 55, widthDegrees: 35) == skin
          && SkinSmooth.apply(skin, width: w, height: h, radius: 0, amount: 1, hueDegrees: 55, widthDegrees: 35) == skin)
    let blue = [SIMD3<Double>](repeating: OkLab.toWorking(SIMD3(0.5, -0.03, -0.12)), count: w * h)
    var blueNoisy = blue
    for i in blueNoisy.indices { blueNoisy[i] = OkLab.toWorking(SIMD3(0.5 + 0.05 * rnd(), -0.03, -0.12)) }
    check("SKS2 a non-skin colour (blue) is not touched (within 1e-12)", allGap(SkinSmooth.apply(blueNoisy, width: w, height: h, radius: 5, amount: 1, hueDegrees: 55, widthDegrees: 35), blueNoisy) < 1e-12)
    let sm = SkinSmooth.apply(skin, width: w, height: h, radius: 5, amount: 1, hueDegrees: 55, widthDegrees: 35)
    func lumVar(_ a: [SIMD3<Double>]) -> Double { let m = a.map { ColorCommon.luminance($0) }; let mean = m.reduce(0, +) / Double(m.count); return m.map { pow($0 - mean, 2) }.reduce(0, +) / Double(m.count) }
    check("SKS3 skin texture is smoothed: the luminance variance falls under 50%", lumVar(sm) < 0.5 * lumVar(skin), "\(lumVar(sm)) vs \(lumVar(skin))")
    check("SKS4 a flat skin patch is unchanged (within 1e-9)", allGap(SkinSmooth.apply([SIMD3<Double>](repeating: skin[0], count: w * h), width: w, height: h, radius: 5, amount: 1, hueDegrees: 55, widthDegrees: 35), [SIMD3<Double>](repeating: skin[0], count: w * h)) < 1e-9)
    let sh = SkinSmooth.apply(skin, width: w, height: h, radius: 5, amount: 0.5, hueDegrees: 55, widthDegrees: 35)
    check("SKS5 amount 0.5 is halfway between the picture and the full result (within 1e-9)", gap(sh[300], (skin[300] + sm[300]) / 2) < 1e-9)

    // TXB
    var bump = [SIMD3<Double>](repeating: SIMD3(repeating: 0.2), count: w * h)
    for y in 9..<15 { for x in 17..<23 { bump[y * w + x] = SIMD3(repeating: 0.4) } }
    check("TXB1 amount 0 is the identity", TextureBands.apply(bump, width: w, height: h, radiusPixels: 3, amount: 0) == bump)
    check("TXB2 a flat picture is unchanged (within 1e-12)", allGap(TextureBands.apply(flat, width: w, height: h, radiusPixels: 3, amount: 1.5), flat) < 1e-12)
    let tx = TextureBands.apply(bump, width: w, height: h, radiusPixels: 3, amount: 1.5)
    check("TXB3 a bump the size of the band gets more contrast: its centre goes up", tx[12 * w + 20].x > 0.4 + 0.01, "\(tx[12 * w + 20].x)")
    let colourBump = bump.map { SIMD3($0.x, $0.x * 0.5, $0.x * 0.25) }
    let tc = TextureBands.apply(colourBump, width: w, height: h, radiusPixels: 3, amount: 1.5)
    check("TXB4 hue and chroma ratios are kept (within 1e-9)", abs(tc[12 * w + 20].y / tc[12 * w + 20].x - 0.5) < 1e-9 && abs(tc[12 * w + 20].z / tc[12 * w + 20].x - 0.25) < 1e-9)
    let soft = TextureBands.apply(bump, width: w, height: h, radiusPixels: 3, amount: -1)
    check("TXB5 a negative amount softens the band (the bump centre comes down) and black stays black",
          soft[12 * w + 20].x < 0.4 && TextureBands.apply([.zero, .zero, .zero, .zero], width: 2, height: 2, radiusPixels: 3, amount: 1) == [.zero, .zero, .zero, .zero])

    // HLT
    var dot = [SIMD3<Double>](repeating: SIMD3(0.2, 0.15, 0.1), count: 41 * 41)
    dot[20 * 41 + 20] = SIMD3(3, 3, 3)
    let tintH = Halation.tint(hueDegrees: 25)
    check("HLT1 strength 0 is the identity", Halation.apply(dot, width: 41, height: 41, strength: 0, radius: 2, tint: tintH) == dot)
    let dark = [SIMD3<Double>](repeating: SIMD3(0.2, 0.15, 0.1), count: 41 * 41)
    check("HLT2 nothing above the knee gives no glow", Halation.apply(dark, width: 41, height: 41, strength: 1, radius: 2, tint: tintH) == dark)
    let hl = Halation.apply(dot, width: 41, height: 41, strength: 0.5, radius: 2, tint: tintH)
    let n = hl[20 * 41 + 22] - dot[20 * 41 + 22]
    check("HLT3 the glow around a highlight is tinted warm: more added red than blue, and never negative", n.x > n.z && n.x > 0 && zip(hl, dot).allSatisfy { $0.x >= $1.x && $0.y >= $1.y && $0.z >= $1.z - 1e-15 }, "\(n)")
    var added = SIMD3<Double>.zero
    for i in hl.indices { added += hl[i] - dot[i] }
    let excess = 3 * ColorCommon.smoothstep(Bloom.kneeLow, Bloom.kneeHigh, 3)
    check("HLT4 the glow keeps the light it was given: the added light is strength x tint x the dot's bright light (within 1e-9)", gap(added, 0.5 * tintH * excess) < 1e-9, "\(added) vs \(0.5 * tintH * excess)")
    var tintsOK = true
    for hue in stride(from: 0.0, through: 360, by: 15) { let t = Halation.tint(hueDegrees: hue); tintsOK = tintsOK && abs(max(t.x, t.y, t.z) - 1) < 1e-12 && t.x.isFinite && t.y.isFinite && t.z.isFinite }
    check("HLT5 the tint is finite with its largest channel 1 at every hue", tintsOK)
}

// CAR chromatic aberration, DST distortion, PSP perspective (Remap), TLS tilt-shift, DFR defringe
do {
    func gap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    func allGap(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double { zip(a, b).map { gap($0, $1) }.max() ?? 0 }
    func finiteAll(_ a: [SIMD3<Double>]) -> Bool { a.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } }
    let w = 41, h = 31
    var textured = [SIMD3<Double>](repeating: .zero, count: w * h)
    for y in 0..<h { for x in 0..<w { textured[y * w + x] = SIMD3(0.5 + 0.3 * sin(Double(x) * 0.7), 0.4 + 0.3 * cos(Double(y) * 0.9), 0.3 + 0.2 * sin(Double(x + y) * 0.5)) } }
    let kinds: [Remap.Kind] = [.distortion(k1: 0, k2: 0), .chromaticAberration(red: 0, blue: 0), .perspective(horizontal: 0, vertical: 0)]
    check("CAR1/DST1/PSP1 zero settings are the exact identity for all three maps", kinds.allSatisfy { Remap.apply(textured, width: w, height: h, kind: $0) == textured })

    // CAR
    let ca = Remap.apply(textured, width: w, height: h, kind: .chromaticAberration(red: 0.02, blue: -0.015))
    check("CAR2 green is never changed by the aberration correction", zip(ca, textured).allSatisfy { $0.y == $1.y })
    var dot = [SIMD3<Double>](repeating: .zero, count: w * h)
    dot[15 * w + 35] = SIMD3(1, 1, 1)
    let cdot = Remap.apply(dot, width: w, height: h, kind: .chromaticAberration(red: 0.1, blue: 0))
    var redX = 0.0, redSum = 0.0
    for x in 0..<w { redSum += cdot[15 * w + x].x; redX += Double(x) * cdot[15 * w + x].x }
    check("CAR3 a red dot right of the centre moves toward the centre when red is scaled up (its red centroid is more than 1 pixel left of 35), green stays at 35",
          redX / redSum < 35 - 1.0 && cdot[15 * w + 35].y == 1, "\(redX / redSum)")
    check("CAR4 the sample of an integer position is the pixel itself and of a half position the mean of two",
          Remap.sample(textured, width: w, height: h, at: SIMD2(7, 9), channel: 0) == textured[9 * w + 7].x
          && abs(Remap.sample(textured, width: w, height: h, at: SIMD2(7.5, 9), channel: 0) - (textured[9 * w + 7].x + textured[9 * w + 8].x) / 2) < 1e-12)

    // DST
    let cxy = SIMD2(Double(w - 1) / 2, Double(h - 1) / 2)
    let sCentre = Remap.source(.distortion(k1: 0.3, k2: 0.1), x: cxy.x, y: cxy.y, width: w, height: h, channel: 0)
    check("DST2 the centre maps to itself whatever the coefficients", abs(sCentre.x - cxy.x) < 1e-12 && abs(sCentre.y - cxy.y) < 1e-12)
    let sEdge = Remap.source(.distortion(k1: 0.3, k2: 0), x: Double(w - 1), y: cxy.y, width: w, height: h, channel: 0)
    check("DST3 k1 above 0 reads farther out than the pixel (content pulled in: source x beyond the output x); k1 below 0 reads nearer",
          sEdge.x > Double(w - 1) && Remap.source(.distortion(k1: -0.3, k2: 0), x: Double(w - 1), y: cxy.y, width: w, height: h, channel: 0).x < Double(w - 1))
    let flatC = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: w * h)
    check("DST4 a flat picture stays flat under any map (within 1e-12) and the output is finite",
          allGap(Remap.apply(flatC, width: w, height: h, kind: .distortion(k1: 0.4, k2: -0.2)), flatC) < 1e-12 && finiteAll(Remap.apply(textured, width: w, height: h, kind: .distortion(k1: 0.5, k2: 0.5))))
    check("DST5 reach covers the displacement: for k1 0.3 it is at least the distance an edge pixel reads from",
          Remap.reach(.distortion(k1: 0.3, k2: 0), width: w, height: h) >= Int(abs(sEdge.x - Double(w - 1)).rounded(.down)))

    // PSP
    let pR = Remap.source(.perspective(horizontal: 0.2, vertical: 0), x: Double(w - 1), y: cxy.y, width: w, height: h, channel: 0)
    check("PSP2 the right edge at the middle row reads from cx + cx / (1 + kx) (within 1e-9)", abs(pR.x - (cxy.x + cxy.x / 1.2)) < 1e-9 && abs(pR.y - cxy.y) < 1e-9, "\(pR)")
    let top = Remap.source(.perspective(horizontal: 0, vertical: 0.3), x: 30, y: 0, width: w, height: h, channel: 0)
    let bottom = Remap.source(.perspective(horizontal: 0, vertical: 0.3), x: 30, y: Double(h - 1), width: w, height: h, channel: 0)
    check("PSP3 a vertical keystone makes the top and bottom rows read different x for the same column (vertical lines converge)", abs(top.x - bottom.x) > 1, "\(top.x) \(bottom.x)")
    check("PSP4 the centre pixel is fixed and a flat picture stays flat", abs(Remap.source(.perspective(horizontal: 0.3, vertical: -0.2), x: cxy.x, y: cxy.y, width: w, height: h, channel: 1).x - cxy.x) < 1e-12
          && allGap(Remap.apply(flatC, width: w, height: h, kind: .perspective(horizontal: 0.3, vertical: -0.2)), flatC) < 1e-12)

    // TLS
    check("TLS1 amount 0 or radius 0 is the identity", TiltShift.apply(textured, width: w, height: h, radius: 2, position: 0.5, angleDegrees: 0, bandWidth: 0.2, transition: 0.2, amount: 0) == textured
          && TiltShift.apply(textured, width: w, height: h, radius: 0, position: 0.5, angleDegrees: 0, bandWidth: 0.2, transition: 0.2, amount: 1) == textured)
    let tl = TiltShift.apply(textured, width: w, height: h, radius: 2, position: 0.5, angleDegrees: 0, bandWidth: 0.3, transition: 0.1, amount: 1)
    check("TLS2 the pixels in the band are untouched (centre row, within 1e-12)", (0..<w).allSatisfy { gap(tl[15 * w + $0], textured[15 * w + $0]) < 1e-12 })
    let blurTL = Blur.apply(textured, width: w, height: h, radius: 2)
    check("TLS3 far from the band the pixel is the full blur (top row, within 1e-12)", (0..<w).allSatisfy { gap(tl[0 * w + $0], blurTL[$0]) < 1e-12 })
    check("TLS4 the weight is symmetric about the band centre", abs(TiltShift.weight(x: 5, y: 5, width: w, height: h, position: 0.5, angleDegrees: 0, bandWidth: 0.2, transition: 0.3, amount: 1)
          - TiltShift.weight(x: 5, y: 25, width: w, height: h, position: 0.5, angleDegrees: 0, bandWidth: 0.2, transition: 0.3, amount: 1)) < 1e-12)
    check("TLS5 at 90 degrees the band is vertical: the weight depends on x only",
          abs(TiltShift.weight(x: 3, y: 2, width: w, height: h, position: 0.5, angleDegrees: 90, bandWidth: 0.1, transition: 0.2, amount: 1) - TiltShift.weight(x: 3, y: 28, width: w, height: h, position: 0.5, angleDegrees: 90, bandWidth: 0.1, transition: 0.2, amount: 1)) < 1e-9
          && TiltShift.weight(x: 3, y: 15, width: w, height: h, position: 0.5, angleDegrees: 90, bandWidth: 0.1, transition: 0.2, amount: 1) > TiltShift.weight(x: 20, y: 15, width: w, height: h, position: 0.5, angleDegrees: 90, bandWidth: 0.1, transition: 0.2, amount: 1))

    // DFR
    func labC(_ l: Double, _ c: Double, _ hDeg: Double) -> SIMD3<Double> { OkLab.toWorking(SIMD3(l, c * cos(hDeg * .pi / 180), c * sin(hDeg * .pi / 180))) }
    var edgeImg = [SIMD3<Double>](repeating: SIMD3(repeating: 0.05), count: w * h)
    for y in 0..<h { for x in w / 2..<w { edgeImg[y * w + x] = SIMD3(repeating: 0.8) } }
    var fringed = edgeImg
    fringed[15 * w + 20] = labC(0.35, 0.12, 320)     // a purple pixel on the dark side of the edge
    for y in 5...25 { for x in 0...16 { fringed[y * w + x] = labC(0.35, 0.12, 320) } }   // the same colour as a flat region
    check("DFR1 strength 0 or radius 0 is the identity", Defringe.apply(fringed, width: w, height: h, radius: 3, strength: 0, hueDegrees: 320, widthDegrees: 40) == fringed
          && Defringe.apply(fringed, width: w, height: h, radius: 0, strength: 1, hueDegrees: 320, widthDegrees: 40) == fringed)
    let df = Defringe.apply(fringed, width: w, height: h, radius: 3, strength: 1, hueDegrees: 320, widthDegrees: 40)
    func chromaOf(_ c: SIMD3<Double>) -> Double { let l = OkLab.fromWorking(c); return hypot(l.y, l.z) }
    check("DFR2 a purple pixel at the edge loses most of its chroma; the same colour inside a flat region is untouched", chromaOf(df[15 * w + 20]) < 0.5 * chromaOf(fringed[15 * w + 20]) && gap(df[15 * w + 6], fringed[15 * w + 6]) < 1e-12,
          "\(chromaOf(df[15 * w + 20])) vs \(chromaOf(fringed[15 * w + 20]))")
    check("DFR3 lightness is kept (within 1e-9)", abs(OkLab.fromWorking(df[15 * w + 20]).x - OkLab.fromWorking(fringed[15 * w + 20]).x) < 1e-9)
    var orange = edgeImg
    orange[15 * w + 20] = labC(0.35, 0.12, 60)
    check("DFR4 a colour outside the fringe hue window (orange) at the same edge is untouched (within 1e-12)", gap(Defringe.apply(orange, width: w, height: h, radius: 3, strength: 1, hueDegrees: 320, widthDegrees: 40)[15 * w + 20], orange[15 * w + 20]) < 1e-12)
    check("DFR5 a grey edge picture and hostile values stay finite and unchanged for greys", allGap(Defringe.apply(edgeImg, width: w, height: h, radius: 3, strength: 1, hueDegrees: 320, widthDegrees: 40), edgeImg) < 1e-12
          && finiteAll(Defringe.apply([SIMD3(0, 0, 0), SIMD3(5, 5, 5), SIMD3(0.2, 0.1, 0.9), SIMD3(0.9, 0.1, 0.8)], width: 2, height: 2, radius: 1, strength: 1, hueDegrees: 320, widthDegrees: 40)))
}

// SRB surface blur, LNB lens blur, MOB motion blur, RDB radial blur, DIF diffusion, HRM colour harmony, KUW Kuwahara
do {
    func gap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    func allGap(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double { zip(a, b).map { gap($0, $1) }.max() ?? 0 }
    func finiteAll(_ a: [SIMD3<Double>]) -> Bool { a.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } }
    let w = 41, h = 31
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: w * h)
    var seed: UInt64 = 99
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
    var noisy = flat
    for i in noisy.indices { let n = 0.05 * rnd(); noisy[i] = SIMD3(0.3 + n, 0.2 + n, 0.1 + n) }
    var step = [SIMD3<Double>](repeating: SIMD3(repeating: 0.1), count: w * h)
    for y in 0..<h { for x in w / 2..<w { step[y * w + x] = SIMD3(repeating: 0.9) } }
    func variance(_ a: [SIMD3<Double>]) -> Double { let m = a.map { $0.x }; let mean = m.reduce(0, +) / Double(m.count); return m.map { pow($0 - mean, 2) }.reduce(0, +) / Double(m.count) }
    var dot = [SIMD3<Double>](repeating: .zero, count: w * h)
    dot[15 * w + 20] = SIMD3(repeating: 1)

    // SRB
    check("SRB1 amount 0 or radius 0 is the identity", SurfaceBlur.apply(noisy, width: w, height: h, radius: 3, eps: 0.004, amount: 0) == noisy && SurfaceBlur.apply(noisy, width: w, height: h, radius: 0, eps: 0.004, amount: 1) == noisy)
    check("SRB2 a flat picture is unchanged (within 1e-9)", allGap(SurfaceBlur.apply(flat, width: w, height: h, radius: 4, eps: 0.004, amount: 1), flat) < 1e-9)
    let sb = SurfaceBlur.apply(noisy, width: w, height: h, radius: 4, eps: 0.01, amount: 1)
    check("SRB3 noise is smoothed (variance under 40%)", variance(sb) < 0.4 * variance(noisy), "\(variance(sb)) vs \(variance(noisy))")
    let sbEdge = SurfaceBlur.apply(step, width: w, height: h, radius: 4, eps: 0.004, amount: 1)
    check("SRB4 a strong step stays sharp: the pixels beside it keep their side's value within 5% of the step", abs(sbEdge[15 * w + 19].x - 0.1) < 0.04 && abs(sbEdge[15 * w + 21].x - 0.9) < 0.04, "\(sbEdge[15 * w + 19].x) \(sbEdge[15 * w + 21].x)")

    // LNB
    check("LNB1 amount 0 or radius 0 is the identity", LensBlur.apply(dot, width: w, height: h, radius: 3, boost: 2, amount: 0) == dot && LensBlur.apply(dot, width: w, height: h, radius: 0, boost: 2, amount: 1) == dot)
    check("LNB2 a flat picture is unchanged (within 1e-12)", allGap(LensBlur.apply(flat, width: w, height: h, radius: 5, boost: 3, amount: 1), flat) < 1e-12)
    var discCount = 0
    for dy in -3...3 { for dx in -3...3 where dx * dx + dy * dy <= 9 { discCount += 1 } }
    let lb = LensBlur.apply(dot, width: w, height: h, radius: 3, boost: 0, amount: 1)
    check("LNB3 without highlight boost a dot becomes the plain disc mean: 1 / \(discCount) at its centre and the same value across the disc (within 1e-12)",
          abs(lb[15 * w + 20].x - 1 / Double(discCount)) < 1e-12 && abs(lb[15 * w + 23].x - 1 / Double(discCount)) < 1e-12 && lb[15 * w + 24].x == 0, "\(lb[15 * w + 20].x)")
    var hotDot = [SIMD3<Double>](repeating: SIMD3(repeating: 0.1), count: w * h)
    hotDot[15 * w + 20] = SIMD3(repeating: 4)
    check("LNB4 highlight boost spreads a bright dot further: the neighbour is brighter with boost than without",
          LensBlur.apply(hotDot, width: w, height: h, radius: 3, boost: 6, amount: 1)[15 * w + 21].x > LensBlur.apply(hotDot, width: w, height: h, radius: 3, boost: 0, amount: 1)[15 * w + 21].x)
    check("LNB5 the blur is symmetric about the dot (within 1e-12)", abs(lb[15 * w + 18].x - lb[15 * w + 22].x) < 1e-12 && abs(lb[13 * w + 20].x - lb[17 * w + 20].x) < 1e-12)

    // MOB
    check("MOB1 length 0 is the identity", MotionBlur.apply(dot, width: w, height: h, length: 0, angleDegrees: 30) == dot)
    let mb = MotionBlur.apply(dot, width: w, height: h, length: 4, angleDegrees: 0)
    check("MOB2 a dot becomes a 9-pixel line along x, each pixel 1/9, and the other rows are untouched (within 1e-12)",
          (16...24).allSatisfy { abs(mb[15 * w + $0].x - 1.0 / 9) < 1e-12 } && mb[15 * w + 25].x < 1e-12 && mb[15 * w + 15].x < 1e-12 && mb[14 * w + 20].x == 0)
    var total = 0.0
    for i in mb.indices { total += mb[i].x }
    check("MOB3 the light is conserved away from the border (sum 1 within 1e-9)", abs(total - 1) < 1e-9, "\(total)")
    let mbv = MotionBlur.apply(dot, width: w, height: h, length: 3, angleDegrees: 90)
    check("MOB4 at 90 degrees the dot is spread along y, not x", mbv[12 * w + 20].x > 0.1 && mbv[18 * w + 20].x > 0.1 && mbv[15 * w + 22].x < 1e-12, "\(mbv[12 * w + 20].x)")
    check("MOB5 a flat picture is unchanged (within 1e-12) and hostile angles stay finite", allGap(MotionBlur.apply(flat, width: w, height: h, length: 5, angleDegrees: 33), flat) < 1e-12
          && finiteAll(MotionBlur.apply(noisy, width: w, height: h, length: 6, angleDegrees: 1e9)))

    // RDB
    check("RDB1 amount 0 is the identity", RadialBlur.apply(dot, width: w, height: h, spin: false, amount: 0, centreX: 0.5, centreY: 0.5) == dot)
    var bigDot = [SIMD3<Double>](repeating: .zero, count: w * h)
    bigDot[15 * w + 10] = SIMD3(repeating: 1)       // left of the centre at (20, 15): on the horizontal through the centre, 10 px out
    let zoom = RadialBlur.apply(bigDot, width: w, height: h, spin: false, amount: 1, centreX: 0.5, centreY: 0.5)
    check("RDB2 a zoom blur smears a dot along the radius (same row), not across it", zoom[15 * w + 11].x > 0.01 && zoom[12 * w + 10].x < zoom[15 * w + 11].x * 0.5, "\(zoom[15 * w + 11].x) \(zoom[12 * w + 10].x)")
    let spin = RadialBlur.apply(bigDot, width: w, height: h, spin: true, amount: 1, centreX: 0.5, centreY: 0.5)
    check("RDB3 a spin blur smears the same dot across the radius (along the circle), more than along it", spin[13 * w + 10].x > spin[15 * w + 12].x, "\(spin[13 * w + 10].x) \(spin[15 * w + 12].x)")
    var atCentre = [SIMD3<Double>](repeating: .zero, count: w * h)
    atCentre[15 * w + 20] = SIMD3(repeating: 1)
    check("RDB4 the centre pixel is not moved by a zoom or a spin (within 1e-12)", abs(RadialBlur.apply(atCentre, width: w, height: h, spin: false, amount: 1, centreX: 0.5, centreY: 0.5)[15 * w + 20].x - 1) < 1e-12
          && abs(RadialBlur.apply(atCentre, width: w, height: h, spin: true, amount: 1, centreX: 0.5, centreY: 0.5)[15 * w + 20].x - 1) < 1e-12)
    check("RDB5 a flat picture is unchanged (within 1e-12) and reach is positive", allGap(RadialBlur.apply(flat, width: w, height: h, spin: true, amount: 1, centreX: 0.3, centreY: 0.7), flat) < 1e-12 && RadialBlur.reach(width: w, height: h, spin: false, amount: 1) >= 2)

    // DIF
    check("DIF1 zero iterations is the identity", Diffusion.apply(noisy, width: w, height: h, iterations: 0, threshold: 0.1) == noisy)
    check("DIF2 a flat picture is unchanged (within 1e-12)", allGap(Diffusion.apply(flat, width: w, height: h, iterations: 8, threshold: 0.1), flat) < 1e-12)
    let d3 = Diffusion.apply(noisy, width: w, height: h, iterations: 3, threshold: 0.3), d12 = Diffusion.apply(noisy, width: w, height: h, iterations: 12, threshold: 0.3)
    check("DIF3 noise falls with the iterations (variance noisy > 3 > 12)", variance(noisy) > variance(d3) && variance(d3) > variance(d12), "\(variance(noisy)) \(variance(d3)) \(variance(d12))")
    let dStep = Diffusion.apply(step, width: w, height: h, iterations: 10, threshold: 0.02)
    check("DIF4 a big step is kept with a small threshold (the neighbours stay within 5% of their side) while a small step is smoothed",
          abs(dStep[15 * w + 19].x - 0.1) < 0.05 && abs(dStep[15 * w + 20].x - 0.9) < 0.05)
    let su = { (a: [SIMD3<Double>]) in a.map { sqrt($0.x) }.reduce(0, +) }
    check("DIF5 the diffusion conserves the sum of the square-root values (within 1e-9)", abs(su(d12) - su(noisy)) < 1e-9, "\(su(d12)) vs \(su(noisy))")

    // HRM
    func labC(_ l: Double, _ c: Double, _ hDeg: Double) -> SIMD3<Double> { OkLab.toWorking(SIMD3(l, c * cos(hDeg * .pi / 180), c * sin(hDeg * .pi / 180))) }
    func hueOf(_ c: SIMD3<Double>) -> Double { OkLab.lch(OkLab.fromWorking(c)).z * 180 / .pi }
    let tri = ColorHarmony.scheme(1, baseDegrees: 30)
    check("HRM1 amount 0 is the identity (within 1e-9)", gap(ColorHarmony.apply(labC(0.6, 0.1, 80), hues: tri.hues, halfGap: tri.halfGap, amount: 0), labC(0.6, 0.1, 80)) < 1e-9)
    let greyH = SIMD3(repeating: 0.3)
    check("HRM2 greys are untouched (within 1e-9)", gap(ColorHarmony.apply(greyH, hues: tri.hues, halfGap: tri.halfGap, amount: 1), greyH) < 1e-9)
    let near = ColorHarmony.apply(labC(0.6, 0.1, 40), hues: tri.hues, halfGap: tri.halfGap, amount: 1)
    check("HRM3 a hue 10 degrees from a scheme hue (30) is pulled toward it, chroma and lightness kept (within 1e-9)",
          abs(ColorCommon.hueDifference(hueOf(near) * .pi / 180, 30 * .pi / 180)) < abs(ColorCommon.hueDifference(40 * .pi / 180, 30 * .pi / 180))
          && abs(OkLab.lch(OkLab.fromWorking(near)).y - 0.1) < 1e-9 && abs(OkLab.fromWorking(near).x - 0.6) < 1e-9)
    let half = ColorHarmony.apply(labC(0.6, 0.1, 90), hues: tri.hues, halfGap: tri.halfGap, amount: 1)
    check("HRM4 a hue half way to the next scheme hue (90 between 30 and 150) is not moved (within 1e-9)", gap(half, labC(0.6, 0.1, 90)) < 1e-9)
    let comp = ColorHarmony.scheme(0, baseDegrees: 0), ana = ColorHarmony.scheme(3, baseDegrees: 100)
    check("HRM5 the schemes: complementary hues are pi apart, a triad has three, analogous hues sit 30 degrees apart with a half gap of 15 degrees",
          abs((comp.hues[1] - comp.hues[0]) - .pi) < 1e-12 && tri.hues.count == 3 && abs((ana.hues[2] - ana.hues[1]) - .pi / 6) < 1e-12 && abs(ana.halfGap - .pi / 12) < 1e-12)

    // KUW
    check("KUW1 amount 0 or radius 0 is the identity", Kuwahara.apply(noisy, width: w, height: h, radius: 2, amount: 0) == noisy && Kuwahara.apply(noisy, width: w, height: h, radius: 0, amount: 1) == noisy)
    check("KUW2 a flat picture is unchanged (within 1e-12)", allGap(Kuwahara.apply(flat, width: w, height: h, radius: 3, amount: 1), flat) < 1e-12)
    let ku = Kuwahara.apply(step, width: w, height: h, radius: 2, amount: 1)
    check("KUW3 an edge stays sharp: the pixels beside a step keep their side's value exactly", abs(ku[15 * w + 19].x - 0.1) < 1e-12 && abs(ku[15 * w + 20].x - 0.9) < 1e-12, "\(ku[15 * w + 19].x) \(ku[15 * w + 20].x)")
    check("KUW4 noise is smoothed (variance under 60%)", variance(Kuwahara.apply(noisy, width: w, height: h, radius: 3, amount: 1)) < 0.6 * variance(noisy))
    let kh = Kuwahara.apply(noisy, width: w, height: h, radius: 2, amount: 0.5), kf = Kuwahara.apply(noisy, width: w, height: h, radius: 2, amount: 1)
    check("KUW5 amount 0.5 is halfway between the picture and the full result (within 1e-12)", gap(kh[400], (noisy[400] + kf[400]) / 2) < 1e-12)
}

// NLM non-local means, BIL bilateral, EMB emboss, SKT sketch, HLF halftone, BWM B&W mixer, SLC selective colour, RTC retouch spot, LQF liquify
do {
    func gap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    func allGap(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double { zip(a, b).map { gap($0, $1) }.max() ?? 0 }
    func finiteAll(_ a: [SIMD3<Double>]) -> Bool { a.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } }
    func enc(_ v: Double) -> Double { Transfer.linearToSRGB(v) }
    func lin(_ e: Double) -> Double { Transfer.srgbToLinear(e) }
    let w = 41, h = 31
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: w * h)
    var seed: UInt64 = 1234
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
    var noisy = flat
    for i in noisy.indices { let n = 0.05 * rnd(); noisy[i] = SIMD3(0.3 + n, 0.2 + n, 0.1 + n) }
    var step = [SIMD3<Double>](repeating: SIMD3(repeating: 0.1), count: w * h)
    for y in 0..<h { for x in w / 2..<w { step[y * w + x] = SIMD3(repeating: 0.9) } }
    func variance(_ a: [SIMD3<Double>]) -> Double { let m = a.map { $0.x }; let mean = m.reduce(0, +) / Double(m.count); return m.map { pow($0 - mean, 2) }.reduce(0, +) / Double(m.count) }

    // NLM
    check("NLM1 amount 0 is the identity", NonLocalMeans.apply(noisy, width: w, height: h, h: 0.1, amount: 0) == noisy)
    check("NLM2 a flat picture is unchanged (within 1e-12)", allGap(NonLocalMeans.apply(flat, width: w, height: h, h: 0.05, amount: 1), flat) < 1e-12)
    let nl = NonLocalMeans.apply(noisy, width: w, height: h, h: 0.1, amount: 1)
    check("NLM3 noise is averaged away (variance under 30%)", variance(nl) < 0.3 * variance(noisy), "\(variance(nl)) vs \(variance(noisy))")
    let ns = NonLocalMeans.apply(step, width: w, height: h, h: 0.03, amount: 1)
    check("NLM4 a step edge stays (the pixels beside it keep their side's value within 2%)", abs(ns[15 * w + 19].x - 0.1) < 0.02 && abs(ns[15 * w + 20].x - 0.9) < 0.02, "\(ns[15 * w + 19].x) \(ns[15 * w + 20].x)")
    let nh = NonLocalMeans.apply(noisy, width: w, height: h, h: 0.1, amount: 0.5)
    check("NLM5 amount 0.5 is halfway (within 1e-12)", gap(nh[400], (noisy[400] + nl[400]) / 2) < 1e-12)

    // BIL
    check("BIL1 amount 0 or radius 0 is the identity", BilateralFilter.apply(noisy, width: w, height: h, radius: 3, range: 0.1, amount: 0) == noisy && BilateralFilter.apply(noisy, width: w, height: h, radius: 0, range: 0.1, amount: 1) == noisy)
    check("BIL2 a flat picture is unchanged (within 1e-12)", allGap(BilateralFilter.apply(flat, width: w, height: h, radius: 4, range: 0.1, amount: 1), flat) < 1e-12)
    let bl = BilateralFilter.apply(noisy, width: w, height: h, radius: 4, range: 0.3, amount: 1)
    check("BIL3 noise is smoothed (variance under 40%)", variance(bl) < 0.4 * variance(noisy), "\(variance(bl)) vs \(variance(noisy))")
    let bs = BilateralFilter.apply(step, width: w, height: h, radius: 4, range: 0.05, amount: 1)
    check("BIL4 a strong step stays (the pixels beside it within 1% of their side)", abs(bs[15 * w + 19].x - 0.1) < 0.01 && abs(bs[15 * w + 20].x - 0.9) < 0.01, "\(bs[15 * w + 19].x) \(bs[15 * w + 20].x)")
    func devFromInput(_ r: Double) -> Double { allGap(BilateralFilter.apply(noisy, width: w, height: h, radius: 4, range: r, amount: 1), noisy) }
    check("BIL5 a narrower colour range keeps the picture closer to the original", devFromInput(0.02) < devFromInput(0.3))

    // EMB
    check("EMB1 amount 0 is the identity", Emboss.apply(noisy, width: w, height: h, angleDegrees: 135, strength: 3, amount: 0) == noisy)
    check("EMB2 a flat picture becomes mid-grey (encoded 0.5, within 1e-9)", Emboss.apply(flat, width: w, height: h, angleDegrees: 135, strength: 3, amount: 1).allSatisfy { abs(enc($0.x) - 0.5) < 1e-9 && abs($0.x - $0.y) < 1e-12 })
    let eR = Emboss.apply(step, width: w, height: h, angleDegrees: 0, strength: 3, amount: 1), eL = Emboss.apply(step, width: w, height: h, angleDegrees: 180, strength: 3, amount: 1)
    check("EMB3 an edge is light when the light comes from the bright side and dark from the other (0 degrees vs 180)", enc(eR[15 * w + 20].x) > 0.55 && enc(eL[15 * w + 20].x) < 0.45, "\(enc(eR[15 * w + 20].x)) \(enc(eL[15 * w + 20].x))")
    let e1 = Emboss.apply(step, width: w, height: h, angleDegrees: 0, strength: 0.2, amount: 1), e2 = Emboss.apply(step, width: w, height: h, angleDegrees: 0, strength: 0.4, amount: 1)
    check("EMB4 doubling the strength doubles the deviation from mid-grey (before clamping)", abs((enc(e2[15 * w + 20].x) - 0.5) / (enc(e1[15 * w + 20].x) - 0.5) - 2) < 1e-9)
    check("EMB5 hostile values (below black, above white) stay finite", finiteAll(Emboss.apply([SIMD3(-1, 5, 9), SIMD3(0, 0, 0), SIMD3(9, 9, 9), SIMD3(0.5, 0.5, 0.5)], width: 2, height: 2, angleDegrees: 77, strength: 8, amount: 1)))

    // SKT
    check("SKT1 amount 0 is the identity", Sketch.apply(noisy, width: w, height: h, strength: 6, amount: 0) == noisy)
    check("SKT2 a flat picture is white paper (within 1e-9)", Sketch.apply(flat, width: w, height: h, strength: 6, amount: 1).allSatisfy { gap($0, SIMD3(repeating: 1)) < 1e-9 })
    let sk = Sketch.apply(step, width: w, height: h, strength: 6, amount: 1)
    check("SKT3 a strong step draws a black line at the edge and leaves paper elsewhere", sk[15 * w + 20].x < 0.01 && sk[15 * w + 19].x < 0.01 && sk[15 * w + 5].x > 0.99 && sk[15 * w + 35].x > 0.99, "\(sk[15 * w + 20].x) \(sk[15 * w + 5].x)")
    let skh = Sketch.apply(step, width: w, height: h, strength: 6, amount: 0.5)
    check("SKT4 amount 0.5 is halfway (within 1e-12)", gap(skh[15 * w + 5], (step[15 * w + 5] + sk[15 * w + 5]) / 2) < 1e-12)
    check("SKT5 hostile values (below black, above white) stay finite", finiteAll(Sketch.apply([SIMD3(-1, 5, 9), SIMD3(0, 0, 0), SIMD3(9, 9, 9), SIMD3(0.5, 0.5, 0.5)], width: 2, height: 2, strength: 20, amount: 1)))

    // HLF
    check("HLF1 amount 0 is the identity", Halftone.apply(noisy, width: w, height: h, size: 6, angleDegrees: 15, colour: false, amount: 0) == noisy)
    let whiteP = [SIMD3<Double>](repeating: SIMD3(repeating: 1), count: w * h)
    check("HLF2 a white picture stays clean white paper (within 1e-12)", allGap(Halftone.apply(whiteP, width: w, height: h, size: 8, angleDegrees: 15, colour: false, amount: 1), whiteP) < 1e-12)
    let blackP = [SIMD3<Double>](repeating: .zero, count: w * h)
    let hb = Halftone.apply(blackP, width: w, height: h, size: 8, angleDegrees: 0, colour: false, amount: 1)
    check("HLF3 a black picture is mostly ink: the cell centres are black", hb[(4) * w + 4].x < 1e-9 && hb.map { $0.x }.reduce(0, +) / Double(hb.count) < 0.2, "\(hb.map { $0.x }.reduce(0, +) / Double(hb.count))")
    func meanOut(_ v: Double) -> Double { let p = Halftone.apply([SIMD3<Double>](repeating: SIMD3(repeating: v), count: w * h), width: w, height: h, size: 8, angleDegrees: 15, colour: false, amount: 1); return p.map { $0.x }.reduce(0, +) / Double(p.count) }
    check("HLF4 the darker the picture the more ink: mean output falls as the input darkens", meanOut(0.8) > meanOut(0.4) && meanOut(0.4) > meanOut(0.1))
    let red = [SIMD3<Double>](repeating: SIMD3(0.4, 0.05, 0.05), count: w * h)
    let hr = Halftone.apply(red, width: w, height: h, size: 10, angleDegrees: 0, colour: true, amount: 1)
    check("HLF5 colour mode puts the picture's own colour in the dots (a cell centre equals the input colour, within 1e-9)", gap(hr[5 * w + 5], SIMD3(0.4, 0.05, 0.05)) < 1e-9, "\(hr[5 * w + 5])")

    // BWM
    check("BWM1 amount 0 is the identity", BWMixer.apply(SIMD3(0.3, 0.2, 0.1), weights: SIMD3(0.5, 0.4, 0.1), amount: 0) == SIMD3(0.3, 0.2, 0.1))
    let red1 = BWMixer.apply(SIMD3(0.7, 0.2, 0.1), weights: SIMD3(1, 0, 0), amount: 1)
    check("BWM2 weights (1, 0, 0) make the grey the red channel (within 1e-12)", gap(red1, SIMD3(repeating: 0.7)) < 1e-12)
    let lumPx = SIMD3(0.4, 0.3, 0.2)
    check("BWM3 the default weights (0.263, 0.678, 0.059) give the luminance within 1e-3", abs(BWMixer.apply(lumPx, weights: SIMD3(0.263, 0.678, 0.059), amount: 1).x - ColorCommon.luminance(lumPx)) < 1e-3)
    check("BWM4 weights summing to 1 leave a neutral grey unchanged, and negative weights stay finite", gap(BWMixer.apply(SIMD3(repeating: 0.3), weights: SIMD3(0.5, 0.4, 0.1), amount: 1), SIMD3(repeating: 0.3)) < 1e-12
          && finiteAll([BWMixer.apply(lumPx, weights: SIMD3(-1, 2, -1), amount: 1)]))

    // SLC
    let zeros = [Double](repeating: 0, count: 24)
    var idS = 0.0
    for i in 0..<512 { let t = Double(i) / 511; let c = SIMD3(0.02 + 0.9 * t, 0.5 * (1 - t) + 0.05, 0.1 + 0.4 * sin(t * 9) * sin(t * 9)); idS = max(idS, gap(SelectiveColor.apply(c, adjust: zeros), c) / max(c.x, 1e-6)) }
    check("SLC1 all sliders at 0 is the identity (within 1e-9 relative)", idS < 1e-9, "\(idS)")
    check("SLC2 a neutral grey is untouched by every slider (exactly)", SelectiveColor.apply(SIMD3(repeating: 0.3), adjust: [Double](repeating: 1, count: 24)) == SIMD3(repeating: 0.3))
    var redM = zeros
    redM[1] = -1     // reds, magenta -1
    let ry = SelectiveColor.apply(SIMD3(1, 0, 0), adjust: redM)
    check("SLC3 reds magenta -1 turns a pure red toward yellow: the green channel comes up to 1 (within 1e-9), red stays 1", abs(enc(ry.y) - 1) < 1e-9 && abs(enc(ry.x) - 1) < 1e-9 && abs(enc(ry.z)) < 1e-9, "\(enc(ry.x)) \(enc(ry.y)) \(enc(ry.z))")
    var redK = zeros
    redK[3] = 1      // reds, black +1
    let darkRed = SIMD3(lin(0.5), lin(0.05), lin(0.05)), dk = SelectiveColor.apply(darkRed, adjust: redK)
    check("SLC4 reds black +1 darkens a dark red (all channels fall)", dk.x < darkRed.x && dk.y <= darkRed.y && dk.z <= darkRed.z, "\(dk) vs \(darkRed)")
    var allC = zeros
    for f in 0..<6 { allC[f * 4] = 0.3 }
    let anyHue = SIMD3(lin(0.9), lin(0.5), lin(0.4)), ah = SelectiveColor.apply(anyHue, adjust: allC)
    check("SLC5 the family weights sum to 1: cyan +0.3 in every family is cyan x 1.3 at any hue (red 0.9 -> 1 - 0.1 x 1.3, within 1e-9)", abs(enc(ah.x) - (1 - 0.1 * 1.3)) < 1e-9, "\(enc(ah.x))")

    // RTC
    var ramp = [SIMD3<Double>](repeating: .zero, count: w * h)
    for y in 0..<h { for x in 0..<w { ramp[y * w + x] = SIMD3(0.1 + 0.8 * Double(x) / Double(w - 1), 0.3, 0.2 + 0.1 * Double(y) / Double(h - 1)) } }
    var spot = CloneSpot.Spot(); spot.srcX = 0.2; spot.srcY = 0.5; spot.dstX = 0.7; spot.dstY = 0.5; spot.radius = 0.2; spot.feather = 0.5; spot.heal = 0; spot.amount = 1
    var off = spot; off.amount = 0
    check("RTC1 amount 0 is the identity", CloneSpot.apply(ramp, width: w, height: h, spot: off) == ramp)
    let cl = CloneSpot.apply(ramp, width: w, height: h, spot: spot)
    let g = spot.geometry(width: w, height: h)
    let cxp = Int(g.centre.x.rounded()), cyp = Int(g.centre.y.rounded())
    check("RTC2 a clone puts the source pixel at the spot centre (within 1e-9)", gap(cl[cyp * w + cxp], ramp[min(max(cyp + g.offset.y, 0), h - 1) * w + min(max(cxp + g.offset.x, 0), w - 1)]) < 1e-9)
    check("RTC3 pixels outside the spot radius are untouched (exactly)", (0..<(w * h)).allSatisfy { i in hypot(Double(i % w) - g.centre.x, Double(i / w) - g.centre.y) < g.radius || cl[i] == ramp[i] })
    var patch = [SIMD3<Double>](repeating: SIMD3(repeating: 0.2), count: w * h)
    for y in 0..<h { for x in 0..<14 { patch[y * w + x] = SIMD3(repeating: 0.8) } }        // a bright source area on the left
    var heal = spot; heal.heal = 1; heal.srcX = 0.15; heal.dstX = 0.75; heal.radius = 0.15
    var cloneOnly = heal; cloneOnly.heal = 0
    let hp = CloneSpot.apply(patch, width: w, height: h, spot: heal), cp = CloneSpot.apply(patch, width: w, height: h, spot: cloneOnly)
    let hg = heal.geometry(width: w, height: h)
    let hx = Int(hg.centre.x.rounded()), hy = Int(hg.centre.y.rounded())
    check("RTC4 heal keeps the destination's light where the source is brighter: the clone brings 0.8 to the spot, the heal leaves it at 0.2 (within 1e-9)",
          abs(cp[hy * w + hx].x - 0.8) < 0.05 && abs(hp[hy * w + hx].x - 0.2) < 1e-9, "clone \(cp[hy * w + hx].x), heal \(hp[hy * w + hx].x)")
    // a bright, strongly detailed source on a dark coloured destination: the old additive detail went negative per channel and clipped into saturated colour
    var hot = [SIMD3<Double>](repeating: SIMD3(0.06, 0.04, 0.02), count: w * h)
    for y in 0..<h { for x in 0..<14 { hot[y * w + x] = SIMD3(repeating: ((x + y) % 2 == 0) ? 3.0 : 0.4) } }
    var hs = heal; hs.radius = 0.3
    let hh = CloneSpot.apply(hot, width: w, height: h, spot: hs)
    let hgeo = hs.geometry(width: w, height: h)
    var inSpot = 0, finiteOK = true, cap = 0.0
    for i in 0..<(w * h) where hypot(Double(i % w) - hgeo.centre.x, Double(i / w) - hgeo.centre.y) < hgeo.radius * 0.5 {
        inSpot += 1
        let v = hh[i]
        finiteOK = finiteOK && v.x.isFinite && v.y.isFinite && v.z.isFinite && v.x >= 0 && v.y >= 0 && v.z >= 0
        cap = max(cap, v.x / 0.06, v.y / 0.04, v.z / 0.02)
    }
    check("RTC6 heal of a bright detailed source on a dark destination stays finite and non-negative and no channel exceeds 4 x the destination (\(inSpot) pixels, max \(cap))",
          inSpot > 0 && finiteOK && cap <= 4 + 1e-9, "\(finiteOK) \(cap)")
    check("RTC5 the edge of the spot is feathered to nothing: a pixel at the radius is unchanged and the weight falls monotonically outward",
          (0..<30).allSatisfy { i in let r1 = Double(i) / 30 * g.radius, r2 = Double(i + 1) / 30 * g.radius
              return (1 - ColorCommon.smoothstep(g.radius * 0.5, g.radius, r2)) <= (1 - ColorCommon.smoothstep(g.radius * 0.5, g.radius, r1)) + 1e-12 })

    // LQF
    let wk = Remap.Kind.warp(centreX: 0.5, centreY: 0.5, radius: 0.4, strength: 0)
    check("LQF1 strength 0 is the exact identity", Remap.apply(ramp, width: w, height: h, kind: wk) == ramp)
    let bulge = Remap.Kind.warp(centreX: 0.5, centreY: 0.5, radius: 0.4, strength: 0.6), pinch = Remap.Kind.warp(centreX: 0.5, centreY: 0.5, radius: 0.4, strength: -0.6)
    let pc = SIMD2(0.5 * Double(w - 1), 0.5 * Double(h - 1))
    let near = Remap.source(bulge, x: pc.x + 5, y: pc.y, width: w, height: h, channel: 0), far = Remap.source(pinch, x: pc.x + 5, y: pc.y, width: w, height: h, channel: 0)
    check("LQF2 a bulge reads nearer the centre than the pixel (magnifies), a pinch farther", near.x - pc.x < 5 && far.x - pc.x > 5, "\(near.x - pc.x) \(far.x - pc.x)")
    let outside = Remap.source(bulge, x: pc.x + 0.45 * Double(h), y: pc.y, width: w, height: h, channel: 0)
    check("LQF3 outside the radius the source is the pixel itself (within 1e-12)", abs(outside.x - (pc.x + 0.45 * Double(h))) < 1e-12)
    let atC = Remap.source(bulge, x: pc.x, y: pc.y, width: w, height: h, channel: 0)
    check("LQF4 the centre is fixed and a flat picture stays flat", abs(atC.x - pc.x) < 1e-12 && allGap(Remap.apply(flat, width: w, height: h, kind: bulge), flat) < 1e-12)
}

// FIL fill scale (auto scale-to-fill for the remap modules)
do {
    let w = 60, h = 40
    check("FIL1 a map that already fills the frame needs no zoom (zero settings give exactly 1)", Remap.fillScale(.distortion(k1: 0, k2: 0), width: w, height: h) == 1 && Remap.fillScale(.perspective(horizontal: 0, vertical: 0), width: w, height: h) == 1)
    let barrel = Remap.Kind.distortion(k1: 0.3, k2: 0)
    let z = Remap.fillScale(barrel, width: w, height: h)
    check("FIL2 k1 0.3 needs a zoom above 1 and no border pixel reads outside the frame at that zoom", z > 1 && Remap.fillsFrame(barrel, width: w, height: h, zoom: z), "\(z)")
    check("FIL3 without the zoom the same warp does read outside the frame", !Remap.fillsFrame(barrel, width: w, height: h, zoom: 1))
    check("FIL4 the zoom is the smallest that fills: 1% less does not fill", !Remap.fillsFrame(barrel, width: w, height: h, zoom: z * 0.99) || z == 1)
    let pinch = Remap.Kind.distortion(k1: -0.3, k2: 0), zp = Remap.fillScale(pinch, width: w, height: h)
    check("FIL5 a pincushion (k1 below 0) already fills the frame: zoom 1", zp == 1, "\(zp)")
    let persp = Remap.Kind.perspective(horizontal: 0.2, vertical: -0.3), zq = Remap.fillScale(persp, width: w, height: h)
    check("FIL6 a keystone gets a zoom above 1 that fills the frame (capped at 4)", zq > 1 && zq <= 4 && (zq == 4 || Remap.fillsFrame(persp, width: w, height: h, zoom: zq)), "\(zq)")
    func outsideCount(_ zoom: Double) -> Int {
        var n = 0
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            let p = Remap.source(barrel, x: Double(x), y: Double(y), width: w, height: h, channel: c, zoom: zoom)
            if p.x < -1e-6 || p.x > Double(w - 1) + 1e-6 || p.y < -1e-6 || p.y > Double(h - 1) + 1e-6 { n += 1 }
        } } }
        return n
    }
    check("FIL7 over the whole frame (not only the border): filled, no pixel reads outside; unfilled, some do", outsideCount(z) == 0 && outsideCount(1) > 0, "\(outsideCount(z)) \(outsideCount(1))")
}
// RDB6 the radial blur's sample count follows its length
do {
    let small = RadialBlur.samples(width: 40, height: 30, spin: true, amount: 0.1), big = RadialBlur.samples(width: 4000, height: 3000, spin: true, amount: 1), mid = RadialBlur.samples(width: 800, height: 600, spin: false, amount: 1)
    check("RDB6 the sample count grows with the blur's length: 12 for a tiny blur, more for a long one, never above 100", small == 12 && big == 100 && mid > 12 && mid < 100, "\(small) \(mid) \(big)")
}
// LPS low-pass of the tone, RLT fill light
do {
    let w = 41, h = 31
    func gap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    var textured = [SIMD3<Double>](repeating: .zero, count: w * h)
    for y in 0..<h { for x in 0..<w { textured[y * w + x] = SIMD3(0.4 + 0.2 * sin(Double(x) * 0.9), 0.3 + 0.1 * cos(Double(y) * 1.1), 0.2 + 0.05 * sin(Double(x + y))) } }
    check("LPS1 radius 0 is the identity", LowPass.apply(textured, width: w, height: h, radius: 0) == textured)
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.2, 0.1), count: w * h)
    check("LPS2 a flat picture is unchanged (within 1e-12)", zip(LowPass.apply(flat, width: w, height: h, radius: 3), flat).allSatisfy { gap($0, $1) < 1e-12 })
    let lp = LowPass.apply(textured, width: w, height: h, radius: 3)
    check("LPS3 colour ratios are kept at every pixel (a gain on all three channels, within 1e-9)", zip(lp, textured).allSatisfy { abs($0.x / $0.y - $1.x / $1.y) < 1e-9 && abs($0.y / $0.z - $1.y / $1.z) < 1e-9 })
    func lumVar(_ a: [SIMD3<Double>]) -> Double { let m = a.map { ColorCommon.luminance($0) }; let mean = m.reduce(0, +) / Double(m.count); return m.map { pow($0 - mean, 2) }.reduce(0, +) / Double(m.count) }
    check("LPS4 the fine detail of the light is smoothed: the luminance variance falls under 50%", lumVar(lp) < 0.5 * lumVar(textured), "\(lumVar(lp)) vs \(lumVar(textured))")
    let bl = Blur.apply(textured, width: w, height: h, radius: 3)
    check("LPS5 it is not the plain blur: it keeps the colour ratios the blur mixes (the blur's red/green ratio differs from the input's somewhere)", zip(bl, textured).contains { abs($0.x / $0.y - $1.x / $1.y) > 1e-3 })
    func rlGap(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    check("RLT1 ev 0 is the identity (exactly)", Relight.apply(SIMD3(0.3, 0.2, 0.1), ev: 0, center: -1, width: 4) == SIMD3(0.3, 0.2, 0.1))
    let atCentre = SIMD3(repeating: 0.18 * 0.5)       // -1 EV: the centre
    check("RLT2 at the centre of the window the full change applies: +1 EV doubles a pixel at -1 EV (within 1e-12)", rlGap(Relight.apply(atCentre, ev: 1, center: -1, width: 4), atCentre * 2) < 1e-12)
    let farUp = SIMD3(repeating: 0.18 * 64)           // +6 EV, 7 EV from the centre, well past the half width of 2
    check("RLT3 far from the centre the pixel is nearly untouched (gain under 1.001 for +1 EV, width 4)", Relight.apply(farUp, ev: 1, center: -1, width: 4).x / farUp.x < 1.001)
    let half = Relight.gain(logLuminance: -1 + 2, ev: 1, center: -1, width: 4)
    check("RLT4 at half the width from the centre the weight is 0.5 (gain 2^0.5, within 1e-9), and colour ratios are kept",
          abs(half - pow(2, 0.5)) < 1e-9 && abs(Relight.apply(SIMD3(0.04, 0.02, 0.01), ev: 1, center: -1, width: 4).x / Relight.apply(SIMD3(0.04, 0.02, 0.01), ev: 1, center: -1, width: 4).y - 2) < 1e-9, "\(half)")
}
// CLH CLAHE (tile histogram equalisation)
do {
    let w = 48, h = 32
    func enc(_ v: Double) -> Double { Transfer.linearToSRGB(v) }
    var lowContrast = [SIMD3<Double>](repeating: .zero, count: w * h)
    for y in 0..<h { for x in 0..<w { let v = Transfer.srgbToLinear(0.45 + 0.1 * (Double((x * 7 + y * 13) % 17) / 16)); lowContrast[y * w + x] = SIMD3(v, v * 0.8, v * 0.6) } }
    check("CLH1 amount 0 is the identity", Clahe.apply(lowContrast, width: w, height: h, tiles: 4, clip: 3, amount: 0) == lowContrast)
    let flat = [SIMD3<Double>](repeating: SIMD3(0.3, 0.3, 0.3), count: w * h)
    let fl = Clahe.apply(flat, width: w, height: h, tiles: 4, clip: 3, amount: 1)
    check("CLH2 a flat picture barely moves (encoded within 0.03: the clip limit keeps the mapping near the identity)", fl.allSatisfy { abs(enc($0.x) - enc(0.3)) < 0.03 }, "\(enc(fl[0].x)) vs \(enc(0.3))")
    func spread(_ a: [SIMD3<Double>]) -> Double { let m = a.map { enc(ColorCommon.luminance($0)) }; let mean = m.reduce(0, +) / Double(m.count); return (m.map { pow($0 - mean, 2) }.reduce(0, +) / Double(m.count)).squareRoot() }
    let st = Clahe.apply(lowContrast, width: w, height: h, tiles: 2, clip: 4, amount: 1)
    check("CLH3 a low-contrast picture is stretched: the encoded luminance spread grows by over 1.5x", spread(st) > 1.5 * spread(lowContrast), "\(spread(lowContrast)) -> \(spread(st))")
    check("CLH4 colour ratios are kept (a gain on all three channels, within 1e-9)", zip(st, lowContrast).allSatisfy { abs($0.x / $0.y - $1.x / $1.y) < 1e-9 && abs($0.y / $0.z - $1.y / $1.z) < 1e-9 })
    let luts = Clahe.luts(lowContrast, width: w, height: h, tiles: 4, clip: 3)
    check("CLH5 every tile's mapping is non-decreasing and ends at 1 (within 1e-9), one per tile", luts.count == 4 * Clahe.grid(tiles: 4, width: w, height: h).y
          && luts.allSatisfy { l in zip(l, l.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 } && abs(l.last! - 1) < 1e-9 })
    var ramp = [SIMD3<Double>](repeating: .zero, count: w * h)
    for y in 0..<h { for x in 0..<w { let v = Transfer.srgbToLinear(0.2 + 0.6 * Double(x) / Double(w - 1)); ramp[y * w + x] = SIMD3(repeating: v) } }
    let rp = Clahe.apply(ramp, width: w, height: h, tiles: 4, clip: 3, amount: 1)
    var jump = 0.0
    for y in 0..<h { for x in 1..<w { jump = max(jump, abs(enc(rp[y * w + x].x) - enc(rp[y * w + x - 1].x))) } }
    check("CLH6 no tile seams: neighbouring pixels of a smooth ramp never differ by more than 0.05 encoded, boundaries included", jump < 0.05, "\(jump)")
    let hostile = Clahe.apply([SIMD3(0, 0, 0), SIMD3(5, 5, 5), SIMD3(-1, 0.2, 0.2), SIMD3(0.5, 0.5, 0.5)], width: 2, height: 2, tiles: 2, clip: 3, amount: 1)
    check("CLH7 black, past white and negative pixels stay finite and past-white is untouched", hostile.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } && hostile[1] == SIMD3(5, 5, 5) && hostile[0] == .zero)
}

do {
    let ps = stride(from: -1.0, through: 1.0, by: 0.01).map { ExposureCurve.value(position: $0, limit: 4) }
    check("EXC1 exposure slider: centre is exactly 0, ends are +-4, never decreasing", ExposureCurve.value(position: 0, limit: 4) == 0 && ps.first == -4 && ps.last == 4
          && zip(ps, ps.dropFirst()).allSatisfy { $0 <= $1 })
    check("EXC2 the middle 40 percent of the track covers about +-1 EV (fine control)", abs(ExposureCurve.value(position: 0.4, limit: 4) - 1.0) < 0.35, "\(ExposureCurve.value(position: 0.4, limit: 4))")
    check("EXC3 drags land on 0.01 EV and the position of a value round trips within a step",
          ps.allSatisfy { abs($0 * 100 - ($0 * 100).rounded()) < 1e-6 }
          && [-3.2, -0.5, 0.37, 1.3, 3.9].allSatisfy { abs(ExposureCurve.value(position: ExposureCurve.position(value: $0, limit: 4), limit: 4) - $0) <= 0.0051 })
}

// FRW the fractional window: a gather module at radius n + f is the blend of its whole radii n and n + 1, radius 0 being the picture itself
do {
    let w = 30, h = 20
    var img = [SIMD3<Double>](repeating: SIMD3(0.2, 0.2, 0.2), count: w * h)
    for y in 0..<h { for x in 0..<w { img[y * w + x] = SIMD3(repeating: 0.2 + 0.5 * (((x / 3 + y / 2) % 2 == 0) ? 1 : 0)) } }
    let run: (Int) -> [SIMD3<Double>] = { Blur.apply(img, width: w, height: h, radius: Double($0)) }
    func dist(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double { zip(a, b).reduce(0.0) { $0 + abs($1.0.x - $1.1.x) } / Double(a.count) }
    check("FRW1 a whole radius runs once and is the integer result exactly", FractionalWindow.apply(img, radius: 3, run) == run(3))
    let mid = FractionalWindow.apply(img, radius: 2.25, run), lo = run(2), hi = run(3)
    check("FRW2 radius 2.25 is a quarter of the way from run(2) to run(3), exactly", zip(mid, zip(lo, hi)).allSatisfy { abs($0.x - ($1.0.x + 0.25 * ($1.1.x - $1.0.x))) < 1e-12 })
    let under = FractionalWindow.apply(img, radius: 0.5, run), one = run(1)
    check("FRW3 radius under 1 fades in from the picture itself: 0.5 is halfway between it and run(1); 0, negative and NaN are the picture",
          zip(under, zip(img, one)).allSatisfy { abs($0.x - ($1.0.x + 0.5 * ($1.1.x - $1.0.x))) < 1e-12 }
          && FractionalWindow.apply(img, radius: 0, run) == img && FractionalWindow.apply(img, radius: -3, run) == img && FractionalWindow.apply(img, radius: .nan, run) == img)
    let ds = [0.2, 0.7, 1.4, 2.5, 3.1].map { dist(FractionalWindow.apply(img, radius: $0, run), img) }
    check("FRW4 the further the radius, the further from the picture: every fractional step moves it more", zip(ds, ds.dropFirst()).allSatisfy { $0 < $1 }, "\(ds)")
}

// merge 2026-10-22: a module folded into another must be the same maths through its survivor
do {
    let px: [SIMD3<Double>] = [SIMD3(0.2, 0.5, 0.8), SIMD3(0.9, 0.1, 0.1), SIMD3(0.02, 0.03, 0.01), SIMD3(0.5, 0.5, 0.5), SIMD3(1.2, 0.7, 0.3)]
    // colorize is the gradient map with one tint on every stop
    var same = true
    for hue in [0.0, 0.13, 0.5, 0.87] {
        let stop = GradientMap.stop(hueDegrees: hue * 360, saturation: Colorize.chroma / GradientMap.chroma)
        for p in px {
            let a = Colorize.apply(p, strength: 0.7, hue: hue), b = GradientMap.apply(p, strength: 0.7, stops: [stop, stop, stop])
            same = same && near(a, b, 1e-12)
        }
    }
    check("MRG-CZ colorize equals the gradient map with one tint on every stop", same)
    // shadows and highlights is the zone exposure's two controls, a slider of 50 per EV
    let sh = Shadhi.settings(shadows: 80, highlights: -60)
    let zn = ZoneExposure.Settings(values: ["shadows": 80 / Shadhi.sliderPerEV, "highlights": -60 / Shadhi.sliderPerEV])
    check("MRG-SHD shadows and highlights maps onto zone exposure", sh.zoneEVs == zn.zoneEVs && sh.scale == zn.scale)
    // colour contrast, velvia and colour correction are the colour balance and colisa steps
    var steps = true
    for p in px {
        steps = steps && near(ColorContrast.apply(p, saturation: 0.4), ColorBalance.apply(p, contrast: 0, saturation: 0.4, vibrance: 0), 1e-12)
        steps = steps && near(Velvia.apply(p, strength: 0.6), ColorBalance.apply(p, contrast: 0, saturation: 0, vibrance: 0.6), 1e-12)
        steps = steps && near(ColorCorrection.apply(p, brightness: 0.3, contrast: 0.2), Colisa.apply(p, contrast: 0.2, brightness: 0.3, saturation: 0), 1e-12)
    }
    check("MRG-CB colour contrast, velvia and colour correction are colour balance and colisa steps", steps)
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
