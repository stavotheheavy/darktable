# Vantage manual

What each part of the app does, in plain words, and every keyboard shortcut. This file is kept with the code: a change
that adds a control or a shortcut updates it in the same change, and `dtb-selftest --manual` fails when a shortcut in the
app is missing here.

## The library (left panel, Pro)

The library is where you find things, like the Sounds library in Logic. A search box at the top; categories down the left;
the category's rows on the right. The top shows what you picked last.

- **Common, Tone, Color, Detail, Geometry, Effects, Other:** the modules by kind. A row's switch puts the module in the right
  panel or takes it out, the same as the Modules menu did before it was folded into the library.
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

## Your Databit Dev account (both modes)

The person icon in the header signs Vantage in to your Databit Dev account, the same account as the web portal. Choose
**Sign in to Databit Dev** (or press **⌥⌘U**): a browser sheet opens on Databit Dev. If you are already signed in there, you
only see "Allow Vantage on this Mac?" and press Allow; otherwise you sign in the usual way, two-step check included. Vantage
never sees your password. Once signed in the icon fills in, and its menu shows who you are, whether Vantage Pro is on (it is
not yet; cloud galleries come next) and **Sign out**.

- Vantage keeps one revocable token in the macOS Keychain. Signing out here, or from "Where you're signed in" on the web,
  removes it. If the web side signs this Mac out, Vantage notices on its next launch and says so.
- Nothing about your photos is sent. This only proves who you are.
- The address is databitdev.com. To point Vantage at another copy (a test server), set the `DARKROOM_CLOUD_URL` environment
  variable before launching.

## Send to gallery (signed in)

Send photos to a client gallery on Databit Dev. In the library, press **Send to gallery** (or **⌥⌘G**, or use the account menu).
A sheet shows the open folder. Photos you rejected start unticked; tick the rest, name the gallery and the client (the email is
optional), and press Send.

- Vantage makes a JPEG of each photo with your edits applied, up to 3000 pixels on the long side, and uploads it. The photo you
  have open is not touched, and your RAW files never leave this Mac.
- When it finishes the sheet shows the client's link and code. Databit Dev shows the code **once**; copy it then. Sending
  again makes a new one.
- If it stops half way (no network, storage full, the plan ended), the sheet says why. Press Send again: photos already up are
  not sent twice.
- Galleries need a Databit Dev plan with galleries. If you own several sites, the sheet asks which one.
- The client picks on the web; their picks come back to the library (next section).

## Client picks in the library (signed in)

When a client sends their picks, Vantage shows them on your thumbnails: a check for picked, a star for a favourite, a cross for
declined, with the client's note when you hold the mouse over it. The **Client picks** button in the library header filters to
All photos, Client picked, Client favourites or Client declined, and **Refresh client picks** (or **⌥⌘R**) asks Databit Dev
again. Vantage also asks when you open it, at most every five minutes.

- Only photos sent from this Mac are matched, by the file name they were uploaded under.
- Your own stars and rejects are never changed by a client's picks. They sit side by side.
- The last answer is kept, so the badges are there offline.
- Picks need the gallery to have been sent from Vantage; a gallery made on the web has nothing to match.

## Auto edit (both modes)

The wand button in the header, or **A**. It looks at the photo and makes a fair starting edit, all as one step in History
(one undo takes it all back):

- **White balance:** the same measurement as the Auto button next to white balance.
- **Exposure:** the middle of the picture toward a comfortable brightness. If Vantage finds a face, the face is what it
  brightens for. It will not push the brightest part into clipping to get there.
- **Highlights and shadows:** pulled back only when a visible share of the picture is clipped or crushed.
- **Contrast and colour:** a little contrast when the picture is flat, and a little colour.

It moves Simple's own controls, so you see what it did in Simple's sliders or in Pro's panel, and can change any of it. Run it
again and it measures what you have now, so a photo that is already right is left alone. Every move is capped.

## Mask tools: brush, lasso, linear and radial (Pro)

The **mask tools button** in the header (a lasso icon, next to Crop) and the keys **B**, **L**, **G** and **R** start a selection for the
open section in the panel (switch a module on first). The edit then applies only inside the selection.

- **Brush (B):** paint on the photo. Size, softness, flow and Erase are in the section's Blend controls.
- **Lasso (L):** drag around what you want and let go; the loop closes itself. A loop that crosses itself fills even-odd.
- **Linear (G):** drag from where the edit is full to where it fades out, like a graduated filter.
- **Radial (R):** drag from the centre to the edge of an ellipse; the rim fades by the softness slider.

Selections are drawn on the uncropped picture, so reset the crop and the zoom first. **Draw again** in the Blend controls replaces the
shape; Invert, edge refine and Show mask work on every kind. Each drawing is one step in History.

## Finding things in the picture (masks)

The Masks category in the library finds, with Apple's Vision framework on this Mac (nothing is sent anywhere): the **subject**,
**person**, **face**, **eyes**, **lips**, **animal** (cats and dogs) and **objects**. Vision has no recogniser for things in
general, so *objects* means the things that stand out from the background, other than people and animals. *Animal* is the
cut-out of the cat or dog; if nothing can be cut out around it, a soft oval over where Vision saw it.

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

- **Library switches (left panel):** put a module into the panel or take it out. Out means gone: its settings are cleared and it
  no longer applies. The header's Modules button was removed because the library lists the same modules.
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

## Driving the panel from the keyboard (Pro)

Press **?** at any time for the list of every shortcut. The arrow keys work on the right panel without the mouse:

- **Up and Down** pick a section (an outline shows which); it opens, and its first slider is picked (a dot shows which).
- **[ and ]** pick the previous or next slider in that section.
- **Left and Right** nudge the slider by a hundredth of its range. **Shift** makes it ten times as much, **Option** a tenth.
  A held key keeps going and is one step in History.
- **Delete** puts the slider back to its default. **E** switches the section's effect on or off. **F** folds or unfolds it.
- **B, L, G and R** pick the mask tools: brush, lasso, linear gradient and radial gradient (see Mask tools below). **M** opens the library with its search ready. **P and H** open and close the Presets and History menus.

These keys step aside while you type in a field (the library's search, a typed slider value), so typing and the field's own
arrow keys still work.

## Keyboard shortcuts

The app's shortcuts live in one table (`Sources/DarkroomUI/Shortcuts.swift`). This list mirrors it.

| Keys | Does |
| --- | --- |
| ⌘Z | Undo the last edit (`undo`) |
| ⌘⇧Z | Redo the edit you undid (`redo`) |
| ⌘⇧H | Hide or show the panels (`hide-ui`) |
| ⌘\ | Compare with the original; press again to return (`original`) |
| Esc | Close the shortcut list, or the open menu (`close-menu`) |
| J | Show clipped highlights and crushed shadows (`clipping`) |
| ⌥⌘A | Switch every section in the panel on (`all-on`) |
| ⌥⌘0 | Switch every section in the panel off; settings stay (`all-off`) |
| ⌥⌘O | Flip the panel between Newest and Pipeline order (`panel-order`) |
| C | Open or close the crop tool (`crop-tool`) |
| ⌥⌘T | Show or hide the display test card (`test-card`) |
| ⌘⇧L | Show or hide the library (`library`) |
| ⌘F | Search the library; opens it if hidden (`library-find`) |
| ? | Show or hide the shortcut list (`help`) |
| ⌘/ | Show or hide the shortcut list, the Mac way (`help-cmd`) |
| ⌘0 | Zoom: fit the photo (`zoom-fit`) |
| ⌘1 | Zoom: 100% (`zoom-100`) |
| ⌘2 | Zoom: 200% (`zoom-200`) |
| M | Open the library with its search ready (`menu-modules`) |
| B | Mask tool: brush (`mask-brush`) |
| L | Mask tool: lasso (`mask-lasso`) |
| G | Mask tool: linear gradient (`mask-linear`) |
| R | Mask tool: radial gradient (`mask-radial`) |
| P | Open or close the Presets menu (`menu-presets`) |
| H | Open or close History (`menu-history`) |
| ↑ | Panel: previous section (`panel-up`) |
| ↓ | Panel: next section; it opens (`panel-down`) |
| [ | Panel: previous slider in the section (`slider-prev`) |
| ] | Panel: next slider in the section (`slider-next`) |
| ← | Slider: lower by a hundredth of its range (`nudge-down`) |
| → | Slider: raise by a hundredth of its range (`nudge-up`) |
| ⇧← | Slider: lower ten times as much (`nudge-down-big`) |
| ⇧→ | Slider: raise ten times as much (`nudge-up-big`) |
| ⌥← | Slider: lower a tenth as much (`nudge-down-fine`) |
| ⌥→ | Slider: raise a tenth as much (`nudge-up-fine`) |
| ⌫ | Slider: back to its default (`slider-reset`) |
| E | Section: switch its effect on or off (`section-power`) |
| F | Section: fold or unfold (`section-fold`) |
| A | Auto edit: white balance, exposure, highlights, shadows (`auto-edit`) |
| ⌥⌘U | Sign in to Databit Dev (`sign-in`) |
| ⌥⌘G | Send photos to a client gallery (`send-gallery`) |
| ⌥⌘R | Refresh what clients picked in the galleries you sent (`refresh-picks`) |
