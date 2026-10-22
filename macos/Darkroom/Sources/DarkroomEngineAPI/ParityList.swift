// Method: a product decision, not an algorithm. Every module darktable ships (its operation names, read from the
// engine's own introspection, names only) is classified once against the clean engine, so "how much of Pro mode is
// there" has one answer that a check can hold the code to (roadmap M6).

import Foundation

/// Where one darktable module stands in the clean engine.
public enum ParityStatus: Equatable, Sendable {
    /// In the catalogue, checked against a Swift oracle and a golden image.
    case exact
    /// In the catalogue, golden-imaged, but never checked against an oracle.
    case unverified
    /// In the catalogue as a Core Image stand-in, labelled approximate.
    case approximate
    /// Not a module of ours, the job is done by something that is: `by` is an operation or a named feature.
    case covered(by: String)
    /// Wanted for parity and not built yet.
    case planned(String)
    /// Deliberately left out, with the reason.
    case dropped(String)
}

public struct ParityEntry: Sendable {
    public let operation: String
    public let status: ParityStatus
    public let note: String
}

public enum ParityList {
    /// darktable's module operations (90 at the version this was written against), from `dtb-selftest --list-modules`.
    public static let darktableModules: [String] = """
    rawprepare invert temperature rasterfile highlights cacorrect hotpixels rawdenoise demosaic denoiseprofile bilateral
    scalepixels lens cacorrectrgb hazeremoval ashift flip enlargecanvas overlay clipping liquify spots retouch exposure
    tonemap toneequal crop graduatednd profile_gamma equalizer colorin channelmixerrgb contrastntexture diffuse censorize
    negadoctor blurs primaries nlmeans colorchecker defringe atrous lowpass highpass sharpen colortransfer colormapping
    channelmixer basicadj colorharmonizer colorbalance colorequal colorbalancergb satcurvergb rgbcurve rgblevels basecurve
    filmic sigmoid agx filmicrgb spektrafilm lut3d colisa tonecurve levels shadhi zonesystem globaltonemap relight bilat
    colorcorrection colorcontrast velvia vibrance colorzones bloom colorize lowlight monochrome grain soften splittoning
    vignette colorreconstruct colorout clahe dither borders watermark
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

    /// Modules of ours that darktable does not have under that name.
    public static let ownModules: [String] = ["display", "graduated", "radiallight", "zones", "solarize", "gradientmap", "bleachbypass", "channelcurves", "chromalimit", "warmth", "highlightrolloff", "lumabands", "hdrtone", "lumacurve", "scurve", "mediandenoise", "deband", "caradial", "distortion", "perspective", "tiltshift", "surfaceblur", "lensblur", "motionblur", "radialblur", "kuwahara", "emboss", "sketch", "halftone", "selectivecolor"]

    public static let entries: [ParityEntry] = {
        func e(_ op: String, _ s: ParityStatus, _ note: String = "") -> ParityEntry { ParityEntry(operation: op, status: s, note: note) }
        return [
            // in the catalogue, checked against an oracle
            e("temperature", .exact, "coefficient gains; kelvin/tint oracle exists, not wired"),
            e("exposure", .exact), e("tonecurve", .exact), e("rgblevels", .exact),
            e("colorbalancergb", .exact, "contrast, saturation, vibrance only; the 4-way grading is not built"),
            e("channelmixer", .covered(by: "channelmixerrgb"), "folded into channelmixerrgb (merge 2026-10-22); an old edit still renders exactly through it"),
            e("monochrome", .exact), e("invert", .exact, "deprecated in darktable, kept: the complement of the display-encoded value, so middle grey stays put"),
            e("colisa", .covered(by: "colorbalancergb"), "folded into colorbalancergb (merge 2026-10-22); an old edit still renders exactly through it"),
            e("velvia", .covered(by: "colorbalancergb"), "folded into colorbalancergb (merge 2026-10-22); an old edit still renders exactly through it"),
            e("vignette", .covered(by: "radiallight"), "folded into radial light (merge 2026-10-22): a centred, inverted ellipse; an old edit still renders exactly"),
            e("shadhi", .covered(by: "zones"), "folded into zones (merge 2026-10-22); an old edit still renders exactly through it"),
            e("bloom", .exact, "the highlights above a soft luminance knee, blurred by three box means and added back"),
            e("splittoning", .exact), e("sharpen", .exact), e("bilat", .exact, "texture and clarity (was local contrast)"),
            e("atrous", .exact, "contrast equalizer: three groups of wavelet scales"), e("denoiseprofile", .exact, "wavelet shrinkage; no camera noise profiles"),
            e("hazeremoval", .exact), e("flip", .exact), e("ashift", .exact, "rotate and straighten only"), e("crop", .exact),
            // Core Image stand-ins
            e("basecurve", .covered(by: "rgblevels"), "folded into rgblevels (merge 2026-10-22); an old edit still renders exactly through it"), e("colorize", .covered(by: "gradientmap"), "folded into gradientmap (merge 2026-10-22); an old edit still renders exactly through it"), e("blurs", .exact, "three box means in a row, a Gaussian-like blur at any radius"), e("lowpass", .covered(by: "blurs"), "folded into blurs (merge 2026-10-22) as a method; an old edit still renders exactly through it"),
            e("dither", .exact, "posterize: the encoded value quantised to N levels per channel, no noise"), e("censorize", .exact, "a mosaic: each block of the chosen size shows its centre pixel"), e("soften", .covered(by: "blurs"), "folded into blurs (merge 2026-10-22) as a method; an old edit still renders exactly through it"), e("rgbcurve", .covered(by: "tonecurve"), "folded into tonecurve (merge 2026-10-22); an old edit still renders exactly through it"),
            e("relight", .covered(by: "lumabands"), "folded into lumabands (merge 2026-10-22); an old edit still renders exactly through it"), e("colorcontrast", .covered(by: "colorbalancergb"), "folded into colorbalancergb (merge 2026-10-22); an old edit still renders exactly through it"),
            e("colorcorrection", .covered(by: "colorbalancergb"), "folded into colorbalancergb (merge 2026-10-22); an old edit still renders exactly through it"), e("clahe", .exact, "contrast limited adaptive histogram equalisation on a tile grid (Zuiderveld), luminance given back as a gain"),
            // the job is done by something we have
            e("filmicrgb", .covered(by: "display"), "the scene-referred display transform is the tone mapper"),
            e("sigmoid", .covered(by: "display")), e("agx", .covered(by: "display")),
            e("graduatednd", .covered(by: "masks"), "a gradient mask on exposure"),
            e("bilateral", .covered(by: "surfaceblur"), "folded into surfaceblur (merge 2026-10-22) as a method; an old edit still renders exactly through it"), e("nlmeans", .covered(by: "denoiseprofile"), "folded into denoiseprofile (merge 2026-10-22) as a method; an old edit still renders exactly through it"),
            e("contrastntexture", .covered(by: "atrous")), 
            // wanted, not built (roughly in order of value to a photographer)
            e("toneequal", .covered(by: "zones")),
            e("highlights", .exact, "off by default: measured 2026-10-20 (dtb-selftest --highlight-probe, 180 raws), Apple's decoder leaves clipped highlights neutral in 24 of the 28 photos with a clip, so this is for the files where it does not"),
            e("colorequal", .covered(by: "colorzones")),
            e("colorzones", .exact, "eight hue bands, each with a hue shift, a saturation change and a lightness change in OkLab, blended smoothly between neighbours; greys untouched"), e("satcurvergb", .exact, "saturation by lightness: shadows, mids and highlights each get a saturation change, blended smoothly over OkLab lightness"),
            e("lut3d", .planned("Core Image CIColorCube is the natural base")), e("grain", .exact, "lattice value noise from the pixel position with a midtone weight, neutral on all channels; repeatable for a seed"), e("lowlight", .exact, "a Purkinje-shift model: dim parts mixed toward a cool scotopic grey; a model, not a measured transform"),
            e("highpass", .exact, "the encoded value minus its three-box blur, on mid-grey: the base of a high-pass sharpen"), e("diffuse", .covered(by: "surfaceblur"), "folded into surfaceblur (merge 2026-10-22) as a method; an old edit still renders exactly through it"),
            e("retouch", .exact, "one spot per instance, cloned or healed by frequency separation (the destination's low frequencies, the source's detail); no PatchMatch fill"), e("liquify", .exact, "one bulge or pinch warp per instance; no warp mesh"),
            e("lens", .planned("lens correction needs our own calibration tool, not lensfun data")), e("colorchecker", .planned()),
            e("cacorrectrgb", .covered(by: "caradial"), "darktable detects the aberration; ours is a manual radial correction"), e("colorreconstruct", .planned("highlight colour reconstruction")),
            e("primaries", .planned("colour primaries rotation")), e("negadoctor", .exact, "a scanned negative to positive from its film-base colour: E = exposure x (Dmin / T)^gamma - black"),
            e("defringe", .exact, "colour taken out of strong luminance edges where the colour is in the fringe hue (a purple window by default)"),
            // left out
            e("rawprepare", .dropped("Core Image's RAW decoder does this")), e("demosaic", .dropped("Core Image's RAW decoder")),
            e("hotpixels", .dropped("decoder")), e("rawdenoise", .dropped("decoder; denoiseprofile works after it")),
            e("cacorrect", .dropped("decoder")), e("colorin", .dropped("Core Image colour management")),
            e("colorout", .dropped("Core Image colour management")), e("scalepixels", .dropped("sensor pixel aspect; rare")),
            e("enlargecanvas", .dropped("an export concern")), e("rasterfile", .dropped("needs darktable's mask files")),
            e("overlay", .dropped("compositing, not photo editing")), e("watermark", .dropped("an export concern")),
            e("borders", .dropped("an export concern")), e("profile_gamma", .dropped("developer tool")),
            e("spektrafilm", .dropped("niche film simulation")), e("colortransfer", .dropped("deprecated in darktable")),
            e("colormapping", .dropped("niche")), e("tonemap", .dropped("deprecated in darktable")),
            e("equalizer", .dropped("deprecated in darktable; atrous replaces it")), e("clipping", .dropped("deprecated in darktable; crop and ashift replace it")),
            e("spots", .dropped("deprecated in darktable; retouch replaces it")), e("basicadj", .dropped("deprecated in darktable")),
            e("filmic", .dropped("deprecated in darktable; filmicrgb replaced it")), e("levels", .dropped("deprecated in darktable; rgblevels replaces it")),
            e("zonesystem", .dropped("deprecated in darktable")), e("globaltonemap", .dropped("deprecated in darktable")),
            e("vibrance", .dropped("deprecated in darktable; colorbalancergb has vibrance")),
            e("channelmixerrgb", .exact, "chromatic adaptation (Bradford) from a black-body illuminant to D65, then the mixer's 3x3"),
            e("colorharmonizer", .exact, "hues pulled toward the nearest hue of a harmony scheme (complementary, triad, tetrad, analogous); chroma and lightness kept"), e("colorbalance", .exact, "shadows, midtones and highlights each with a tint and a brightness: the ASC CDL offset, power (about scene white) and slope on scene-linear values"),
            // ours
            e("emboss", .exact, "not a darktable module: the directional derivative of the encoded luminance on mid-grey: a stamped relief"),
            e("sketch", .exact, "not a darktable module: Sobel edges of the encoded luminance as dark lines on white paper"),
            e("halftone", .exact, "not a darktable module: ink dots on a turned grid, the dot area following the darkness"),
            e("selectivecolor", .exact, "not a darktable module: cyan, magenta, yellow and black sliders for each of six colour families, relative, on the encoded value"),
            e("surfaceblur", .exact, "not a darktable module: an edge-preserving blur over the whole picture: the guided filter, guided by luminance"),
            e("lensblur", .exact, "not a darktable module: a disc (bokeh) blur whose highlights spread into bright discs"),
            e("motionblur", .exact, "not a darktable module: the mean of bilinear samples along a line at an angle"),
            e("radialblur", .exact, "not a darktable module: a zoom or a spin blur about a centre point"),
            e("kuwahara", .exact, "not a darktable module: the Kuwahara painterly edge-preserving smoother: the mean of the smoothest of four quadrants"),
            e("caradial", .exact, "not a darktable module: lateral chromatic aberration: red and blue scaled about the centre, bilinear; manual, where darktable's cacorrectrgb detects it"),
            e("distortion", .exact, "not a darktable module: Brown's radial lens distortion polynomial, bilinear, manual coefficients"),
            e("perspective", .exact, "not a darktable module: a keystone as a plane projective map, bilinear"),
            e("tiltshift", .exact, "not a darktable module: a sharp band across the frame and a wide blur beyond it"),
            e("mediandenoise", .exact, "not a darktable module: each channel the median of its 3x3 or 5x5 neighbourhood: hot pixels and impulse noise"),
            e("deband", .exact, "not a darktable module: smooth gradients replaced by their blur, edges kept"),
            e("highlightrolloff", .exact, "not a darktable module: a tanh shoulder on scene luminance above a knee, colour ratios kept"),
            e("lumabands", .exact, "not a darktable module: an exposure change by the pixel's own luminance in five bands (the cheap cousin of zones)"),
            e("hdrtone", .exact, "not a darktable module: base and detail dynamic range compression with the guided filter base, as in Durand and Dorsey"),
            e("lumacurve", .exact, "not a darktable module: a monotone cubic on OkLab lightness with chroma kept"),
            e("scurve", .exact, "not a darktable module: a bias-and-gain contrast curve about a pivot on the encoded value"),
            e("gradientmap", .exact, "not a darktable module: three OkLab gradient stops picked by lightness; a duotone or tritone print"),
            e("bleachbypass", .exact, "not a darktable module: partial desaturation plus an overlay of the luminosity"),
            e("channelcurves", .exact, "not a darktable module: a monotone cubic of its own on each of red, green and blue"),
            e("chromalimit", .exact, "not a darktable module: a soft tanh limit on OkLab chroma"),
            e("warmth", .exact, "not a darktable module: a warm / cool and magenta / green look in OkLab, after white balance"),
            e("solarize", .exact, "not a darktable module: tones above a threshold mirrored about it on the encoded value, the Sabattier effect"),
            e("display", .exact, "not a darktable module: the scene-referred display transform, with an HDR peak"),
            e("graduated", .exact, "not a darktable module: an exposure change through a soft linear gradient, for a sky or a foreground"),
            e("radiallight", .exact, "not a darktable module: an exposure change through a soft ellipse, inside or around it"),
            e("zones", .exact, "not a darktable module: a scene-referred exposure change by zone on an edge-aware base; Simple's Shadows and Highlights drive it"),
        ]
    }()

    public static func entry(_ operation: String) -> ParityEntry? { entries.first { $0.operation == operation } }

    /// The list as a table for ~/Documents/plans, grouped by status.
    public static func markdown(catalogue: [String]) -> String {
        func label(_ s: ParityStatus) -> String {
            switch s {
            case .exact: "exact"
            case .unverified: "unverified"
            case .approximate: "approximate"
            case .covered(let by): "covered by \(by)"
            case .planned: "planned"
            case .dropped: "dropped"
            }
        }
        func detail(_ e: ParityEntry) -> String {
            switch e.status {
            case .planned(let why), .dropped(let why): why.isEmpty ? e.note : why
            default: e.note
            }
        }
        var out = "# Pro mode parity list\n\nGenerated by `swift run darkroom-engine-check --parity-doc <path>` from `ParityList.swift`; edit the Swift, not this file.\n"
        out += "darktable has \(darktableModules.count) modules; the clean engine's catalogue has \(catalogue.count).\n\n"
        let order = ["exact", "unverified", "approximate", "covered", "planned", "dropped"]
        for key in order {
            let rows = entries.filter { label($0.status).hasPrefix(key) }
            guard !rows.isEmpty else { continue }
            out += "## \(key) (\(rows.count))\n\n| module | status | note |\n|---|---|---|\n"
            for r in rows.sorted(by: { $0.operation < $1.operation }) {
                out += "| \(r.operation) | \(label(r.status)) | \(detail(r)) |\n"
            }
            out += "\n"
        }
        return out
    }
}

extension ParityStatus {
    /// `.planned()` with no reason.
    public static func planned() -> ParityStatus { .planned("") }
}
