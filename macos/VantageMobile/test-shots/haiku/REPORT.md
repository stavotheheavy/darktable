# Haiku test rig report: Vantage on iPad and iPhone

Written by the lead session from the Haiku agent's logs and messages: the harness refused the Haiku agent's own
.md write, so its results came back as text. Each line names its log.

## What the Haiku agent ran itself

| Run | Device | Result | Log |
|---|---|---|---|
| Strict walk (`VantageWalkTests`) | iPad Pro 13" simulator | 5 passed, 5 phone tests skipped by design, 0 failed | `strict-ipad.log` |
| Strict walk (`VantageWalkTests`) | iPhone 17 Pro simulator | 5 passed, 5 iPad tests skipped by design, 0 failed | `strict-iphone.log` |
| Exploration (`HaikuExploreTests`), first run | iPhone | failed: 8 controls "not reachable" | `explore-iphone.log` |

The first exploration run found no app bug. Its failures were mistakes in the test: it never scrolled the sideways tray, so
tiles past the fifth (Color, Warmth, Detail, Balance, Crop) could not be hit; it used the Mac and iPad toolbar zoom ids
(`zoom-200%`, `zoom-Fit`) instead of the phone's (`zoom-in`, `zoom-fit`); and Rotate sits inside the Crop control. Everything
that did run (the Looks, Light, Shadows, Highlights and Contrast tiles with sliders at 0.1 and 0.9, Reset, Done, Auto edit,
Undo, Redo, Hide UI and Show UI, rotation) caused no crash or hang.

## Final runs driven by the Haiku agent (10-22, after the sidecar reset)

| Run | Device | Result | Log |
|---|---|---|---|
| Walk + flow + exploration | iPhone 17 Pro simulator | TEST SUCCEEDED: 16 tests, 7 iPad-only skipped, 0 failures (exploration 166 s) | `haiku-final-iphone2.log` (scratchpad) |
| Walk + flow + exploration | iPad Pro 13" simulator | TEST SUCCEEDED: 16 tests, 6 phone-only skipped, 0 failures (7 iPad walk, 3 flow) | `haiku-final-ipad2.log` (scratchpad) |

The lead session's own full runs on both devices also had 0 failures (7/7 iPad walk, 5/5 iPhone walk, 3/3 flow each).

## What the lead session fixed and reran

| Run | Device | Result | Log |
|---|---|---|---|
| Exploration with the tray scrolled and the right ids | iPhone | passed (163 s): all ten tray tools, both slider extremes, Reset, Done, Auto edit, Undo, Redo, zoom in x3, Fit, Hide and Show UI, Crop, Rotate, landscape and back | `explore-phone2.log` (scratchpad) |
| Export ends in the share sheet, and closes | iPad | passed | `walk-ipad3.log` (scratchpad) |
| Keyboard: the A key runs auto edit, Command-Z undoes | iPad | passed after a fix (see below) | `walk-ipad5.log` (scratchpad) |
| Original flow tests (welcome names the device, RAW opens, auto edit then undo) | iPad and iPhone | 3 passed on each | `flow-ipad.log`, `flow-iphone.log` (scratchpad) |
| Brush: B starts a brush, a drag across the photo changes the picture (UIKit capture layer) | iPad | passed (after each test started resetting the photo's saved edits) | `walk-ipad8.log` (scratchpad) |
| Core checks, including four new pen-pressure checks (BR11 to BR14) | Mac, `darkroom-core-check` | all checks passed | run in the terminal |

Real bugs the rig found and the fixes: the phone's top bar did not fit the screen (new phone layout); the portrait iPad
panels overlapped the photo (edge tabs); the Simple panel stretched to the full height (it now hugs its controls); the A
key and other plain keys never reached the shortcut router on iPad because the view never took keyboard focus (it now does).

## Not tested

- A real iPad or iPhone: nothing has run on a physical device (no signing team yet).
- Apple Pencil pressure on a real Pencil: the simulator has no pencil. The pressure model is covered by BR11 to BR14 only.
- Pinch accuracy with a real two-finger gesture: the pinch tests use XCUITest's synthetic pinch.
- The iPad toolbar's new Fit, 2x and 4x buttons: that group is not shown on iPad at the sizes tested.
