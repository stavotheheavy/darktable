# Vantage manual

What each part of the app does, in plain words, and every keyboard shortcut. This file is kept with the code: a change
that adds a control or a shortcut updates it in the same change, and `dtb-selftest --manual` fails when a shortcut in the
app is missing here.

## The right panel (Pro)

The right panel holds the modules you are using. Each one is a section with a power button, a name and a fold arrow.

- **Modules menu (header):** puts a module into the panel or takes it out. Out means gone: its settings are cleared and it
  no longer applies.
- **Power button (on a section):** switches the effect off or on. The section stays, with its settings.
- **All on / All off (top of the panel):** every section's effect at once. The sections and their settings stay. One step
  in History, so one undo brings it all back.
- **Newest / Pipeline (top of the panel):** how the sections stack. *Newest* puts the module you switched on last at the
  top, like a history. *Pipeline* lists them in the order the engine applies them, which is the order masks and geometry
  read best in. Vantage remembers your choice.
- **Reset (on an unfolded, edited section):** back to the module's defaults.
- **Double-click a slider's name:** that one control back to its default.

### A slider that seems to do nothing

Some controls only show once another control of the same module is above zero. Split toning's *shadows hue* is invisible
while *shadows saturation* is 0; a colour filter's hue is invisible while its strength is 0. Vantage wakes the sleeping
control for you: drag the hue and the saturation comes up to half. A note under the slider says what it will turn up.

*Chroma* in noise reduction removes colour noise. On a clean, low-ISO photo there is none to remove, so the slider shows
nothing. Try it on a photo shot at ISO 3200 or above.

## Modules that were folded into another (22 October 2026)

The catalogue had modules that did the same job under two names. They became a setting of the one that stayed. An old
edit that used one still opens and looks the same; the panel shows the module that replaced it, and the status line says
how many were folded.

| Was | Now | Where its controls went |
| --- | --- | --- |
| contrast brightness saturation | contrast and saturation | contrast, brightness, global saturation |
| velvia | contrast and saturation | vibrance |
| color contrast | contrast and saturation | global saturation |
| color correction | contrast and saturation | brightness, contrast |
| rgb curve | tone curve | the five-node curve |
| base curve (gamma) | levels | gamma |
| fade | levels | fade black, fade white |
| channel mixer (plain) | channel mixer | the 3x3 matrix, adaptation strength 0 |
| black and white mixer | black and white | method: channel weights, with red, green, blue |
| colorize | gradient map | one tint on all three stops |
| photo filter | warmth and tint | method: colour filter, with hue, density, preserve |
| hue rotate | color zones | hue (all) |
| cross process | channel curves | cross process amount |
| Reinhard tone | highlight compression | curve: Reinhard, with white and amount |
| fill light | luminosity bands | ev, center, width (one movable band) |
| shadows and highlights | zone exposure | shadows, highlights (a slider of 100 is 2 EV) |
| halation | bloom | glow: film halation, with size and hue |
| vignetting | radial light | a centred circle, outside, feather 1; strength 1 is -2 EV |

Ten others only changed name: color balance (OkLab) is *contrast and saturation*; color balance (shadows, mids,
highlights) is *lift, gamma, gain*; rgb levels is *levels*; highlight roll-off is *highlight compression*; channel mixer
(adaptation) is *channel mixer*; monochrome is *black and white*; local contrast is *texture and clarity*; median denoise is
*hot pixels (median)*; rotate and straighten is *straighten*; dither is *posterize*.

## Keyboard shortcuts

The app's shortcuts live in one table (`Sources/DarkroomUI/Shortcuts.swift`). This list mirrors it.

| Keys | Does |
| --- | --- |
| ⌘⇧H | Hide or show the panels (`hide-ui`) |
| ⌘\ | Compare with the original; press again to return (`original`) |
| Esc | Close the open menu (`close-menu`) |
| J | Show clipped highlights and crushed shadows (`clipping`) |
| ⌥⌘A | Switch every section in the panel on (`all-on`) |
| ⌥⌘0 | Switch every section in the panel off; settings stay (`all-off`) |
| ⌥⌘O | Flip the panel between Newest and Pipeline order (`panel-order`) |
