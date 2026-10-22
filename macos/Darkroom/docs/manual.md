# Vantage manual

What each part of the app does, in plain words, and every keyboard shortcut. This file is kept with the code: a change
that adds a control or a shortcut updates it in the same change, and `dtb-selftest --manual` fails when a shortcut in the
app is missing here.

## The library (left panel, Pro)

The library is where you find things, like the Sounds library in Logic. A search box at the top; categories down the left;
the category's rows on the right. The top shows what you picked last.

- **Common, Tone, Color, Detail, Geometry, Effects, Other:** the modules by kind. A row's switch puts the module in the right
  panel or takes it out, the same as the Modules menu.
- **Looks:** the six looks. A row applies the look.
- **Presets:** the modules that were folded into another (the table below), by their old names. A row puts the module that
  replaced it in the panel, chooses that method and sets the old module's starting values; the section unfolds so you can raise
  its strength.
- **Masks:** brush, and the finders (subject, person, face, eyes, lips). A row puts the mask on the *open* section of the right
  panel: the unfolded one nearest the top. The note under the rows says which. Switch a module on and unfold it first.
- **Search:** type, and every category is searched at once; the hits appear under their category names. Clear it to get the
  columns back.
- **Show or hide:** the Library button in the header, or ⌘⇧L. ⌘F opens it and puts the cursor in its search.

A merged module (one with a *method*, *mode*, *glow* or *curve* switch) shows the controls of the chosen method only. Pick
another method and its own controls appear.

## The crop tool (Pro)

Crop is a tool, not a module. It has its own button in the header, next to Undo and Redo, and a key: **C**. It opens a
dropdown, and the photo shows the whole frame with a **crop box** over it:

- **On the photo:** drag a corner or an edge of the box to resize it, drag inside it to move it. The cut-away part is
  dimmed and a third-lines grid helps with composition. A whole drag is one step in History. Close the tool to see the crop.
  The box and the Edges sliders below are the same four numbers.

The dropdown has:

- **Straighten:** a slider, -45 to 45 degrees. The picture is cropped to the largest clean rectangle.
- **Turn and flip:** turn left, turn right, flip horizontally, flip vertically. Each press is one step in History.
- **Crop to:** Original (no crop), 1:1, 4:5, 3:2 and 16:9, centred. A portrait photo gets the portrait ratio.
- **Edges:** the four crop edges by hand, left, top, right and bottom, for a crop that is none of the presets.
- **Reset:** crop, straighten, turn and flip back to nothing, in one step.

Crop, straighten and flip are no longer in the Modules menu, the library or the right panel. An older edit that used them
opens and looks the same.

The display test card (HDR steps and Display P3 colours, to check a screen by eye) moved off the header to ⌥⌘T.

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
| soften | blurs | mode: soft focus, with strength |
| lowpass (tone) | blurs | mode: tone only |
| bilateral filter | surface blur | method: bilateral, with range |
| diffuse (anisotropic) | surface blur | method: anisotropic, with iterations and edge |
| skin smoothing | surface blur | method: skin, with hue and width |
| non-local means denoise | noise reduction | method: non-local means, with amount and strength |
| chroma denoise | noise reduction | method: colour window, with radius and amount |
| deconvolution sharpen | sharpen | method: deconvolution, with iterations |
| texture bands | texture and clarity | method: texture bands |

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
| C | Open or close the crop tool (`crop-tool`) |
| ⌥⌘T | Show or hide the display test card (`test-card`) |
| ⌘⇧L | Show or hide the library (`library`) |
| ⌘F | Search the library; opens it if hidden (`library-find`) |
