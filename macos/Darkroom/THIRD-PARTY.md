# Third-party material in the clean engine (DarkroomCore)

DarkroomCore is written from published papers, standards, Apple documentation and the permissively licensed projects below.
It contains no darktable code (darktable is GPL-3). Nobody who wrote it read darktable's `src/iop`.

## LightCraft (MIT OR Apache-2.0)
Source: https://github.com/storytold/lightcraft, commit d999e38. Copyright (c) 2026 ArtCraft Team and the LightCraft contributors.
We take the MIT option for the files below.

| Our file | Taken from | What changed |
|---|---|---|
| `Sources/DarkroomCore/ToneMap.swift` | `ToneMap::hdr`, crates/pipeline/src/tone.rs | Rewritten in Swift, Double table, scene-referred path only |
| `Sources/DarkroomCore/ColorMath.swift` | structure of crates/color (working space, OkLab built from it, derived matrices) | Rewritten in Swift; primaries-derived matrices; no code lines copied |

MIT licence text (LightCraft's LICENSE-MIT): permission is granted, free of charge, to use, copy, modify, merge, publish, distribute,
sublicense and sell copies, provided the copyright notice and this permission notice are included. The software is provided "as is",
without warranty of any kind.

## Published specifications (no licence needed, cited in code)
- OkLab: Bjorn Ottosson, "A perceptual color space for image processing", 2020.
- sRGB (IEC 61966-2-1), BT.2020, SMPTE ST 2084 (PQ), ITU-R BT.2100 (HLG), CIE D65.

## Not taken, on purpose
- LightCraft's optional RawNIND denoise weights are GPL-3.0. We do not bundle or run them.
- lensfun data is CC BY-SA 3.0; users load it themselves, we do not ship it.
- Anything from darktable `src/iop`.
