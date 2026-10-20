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
check("MO2 plain black and white is the luminance grey 0.3573", near(moWhite, SIMD3(repeating: 0.3573), 1e-12), "\(moWhite)")
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
    let out3 = Sharpen2D.apply(fx, width: fw, height: fh, amount: 0.7, radius: 3)
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
    let levels: [(Double, Int)] = [(0.5, 0), (1.0, 0), (1.4, 0), (1.5, 1), (2.8, 1), (2.9, 2), (5.6, 2), (5.7, 3), (8, 3)]
    check("SH7 the level map is 0, 1, 2, 3 at the radii the card gives", levels.allSatisfy { Sharpen2D.level(radius: $0.0) == $0.1 })
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


print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
