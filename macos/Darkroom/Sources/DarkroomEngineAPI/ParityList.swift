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
    public static let ownModules: [String] = ["display", "graduated", "radiallight", "zones"]

    public static let entries: [ParityEntry] = {
        func e(_ op: String, _ s: ParityStatus, _ note: String = "") -> ParityEntry { ParityEntry(operation: op, status: s, note: note) }
        return [
            // in the catalogue, checked against an oracle
            e("temperature", .exact, "coefficient gains; kelvin/tint oracle exists, not wired"),
            e("exposure", .exact), e("tonecurve", .exact), e("rgblevels", .exact),
            e("colorbalancergb", .exact, "contrast, saturation, vibrance only; the 4-way grading is not built"),
            e("channelmixer", .exact, "deprecated in darktable, kept: it is the 3x3 mixer; channelmixerrgb is a different maths"),
            e("monochrome", .exact), e("invert", .exact, "deprecated in darktable, kept: the complement of the display-encoded value, so middle grey stays put"),
            e("colisa", .exact, "deprecated in darktable, kept; Simple does not use it. Contrast about middle grey, OkLab saturation, brightness as 2^(2b) of exposure"),
            e("velvia", .exact, "the OkLab vibrance step of colour balance on its own: pale colours gain most, vivid ones are left alone"),
            e("vignette", .exact, "a circular surround darkening: radial light turned inside out, feathered over its whole radius"),
            e("shadhi", .exact, "shadows and highlights: the zone exposure's two controls, a slider of 100 is 2 EV"),
            e("bloom", .exact, "the highlights above a soft luminance knee, blurred by three box means and added back"),
            e("splittoning", .exact), e("sharpen", .exact), e("bilat", .exact, "local contrast"),
            e("atrous", .exact, "contrast equalizer: three groups of wavelet scales"), e("denoiseprofile", .exact, "wavelet shrinkage; no camera noise profiles"),
            e("hazeremoval", .exact), e("flip", .exact), e("ashift", .exact, "rotate and straighten only"), e("crop", .exact),
            // Core Image stand-ins
            e("basecurve", .approximate, "a gamma only"), e("colorize", .approximate), e("blurs", .approximate), e("lowpass", .approximate),
            e("dither", .approximate), e("censorize", .approximate), e("soften", .approximate), e("rgbcurve", .approximate),
            e("relight", .approximate, "deprecated in darktable; shadhi or toneequal replace it"), e("colorcontrast", .approximate),
            e("colorcorrection", .approximate), e("clahe", .approximate, "deprecated in darktable; bilat replaces it"),
            // the job is done by something we have
            e("filmicrgb", .covered(by: "display"), "the scene-referred display transform is the tone mapper"),
            e("sigmoid", .covered(by: "display")), e("agx", .covered(by: "display")),
            e("graduatednd", .covered(by: "masks"), "a gradient mask on exposure"),
            e("bilateral", .covered(by: "denoiseprofile")), e("nlmeans", .covered(by: "denoiseprofile")),
            e("contrastntexture", .covered(by: "atrous")), 
            // wanted, not built (roughly in order of value to a photographer)
            e("toneequal", .covered(by: "zones")),
            e("highlights", .exact, "off by default: measured 2026-10-20 (dtb-selftest --highlight-probe, 180 raws), Apple's decoder leaves clipped highlights neutral in 24 of the 28 photos with a clip, so this is for the files where it does not"),
            e("colorequal", .planned("hue-selective colour; the colour-range mask is the base")),
            e("colorzones", .planned("hue curves (roadmap M3 'later')")), e("satcurvergb", .planned("saturation by lightness curve")),
            e("lut3d", .planned("Core Image CIColorCube is the natural base")), e("grain", .planned()), e("lowlight", .planned()),
            e("highpass", .planned("the S5 bases make it small")), e("diffuse", .planned("sharpen and denoise as diffusion; large")),
            e("retouch", .planned("healing needs PatchMatch")), e("liquify", .planned("warp mesh")),
            e("lens", .planned("lens correction needs our own calibration tool, not lensfun data")), e("colorchecker", .planned()),
            e("cacorrectrgb", .planned("chromatic aberration")), e("colorreconstruct", .planned("highlight colour reconstruction")),
            e("primaries", .planned("colour primaries rotation")), e("negadoctor", .planned("film negative inversion")),
            e("defringe", .planned()),
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
            e("channelmixerrgb", .planned("the calibration-matrix mixer; channelmixer covers the plain 3x3 case")),
            e("colorharmonizer", .planned()), e("colorbalance", .planned("the 4-way lift/gamma/gain grading; colorbalancergb has only contrast, saturation and vibrance")),
            // ours
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
