# Negatives & Positives — technical notes

Two macOS apps sharing one engine (`Packages/DarkroomKit`), both 32-bit float end to end:

- **Negatives** turns photographed film negatives (Fujifilm X-E4 RAF files) into positives.
- **Positives** is the photo editor: RAF (LibRaw, Markesteijn 3-pass, highlights rebuilt), JPEG, HEIC, PNG and
  16-bit TIFF, non-destructive (edits saved to an archive on request), preview identical to export.

```bash
xcodegen generate     # project.yml -> Darkroom.xcodeproj (brew install xcodegen)
xcodebuild -project Darkroom.xcodeproj -scheme Positives -configuration Release -derivedDataPath .build/xcode build
xcodebuild -project Darkroom.xcodeproj -scheme Negatives -configuration Release -derivedDataPath .build/xcode build
swift test            # both engines: identity, GPU = CPU, preview = export, colour maths, negative round trip
```

## Positives

The inspector is organised like Photos' Adjust panel, by category: **Light** (profile, exposure, contrast,
highlights, shadows, whites, blacks · texture, clarity, dehaze), **Color** (white balance, vibrance, saturation,
8-range colour mixer, targeted colours picked on the photo with "keep only this colour", colour grading wheels),
**Curves** (RGB + R/G/B point curves, monotone splines, pipette), **Film** (film looks previewed on the photo,
lab variants, warmth/tint, halation; grain), **Effects** (bloom, vignette), **Masks**, **Layers**, **History**. The Color section also has
Fujifilm-style **Color Chrome** and **Color Chrome Blue** (off / weak / strong).

Keys: ←/→ photos · ⌘Z/⇧⌘Z undo/redo · hold \\ before · C crop · W white-balance picker · [ ] rotate ·
⌘0 fit · ⌘1 100% · ⌘2 200% · Z fit↔100% (or double-click / two-finger double-tap) · J clipping · ⌘E export ·
⇧⌘C/⇧⌘V copy/paste settings (⌘-click thumbnails to paste into several) · ⌘S save to the archive · ⇧⌘O start
screen. Double-click a slider (or its name) to reset it.

Edits are kept in memory while you work and saved only when you press **Save** (⌘S): the archive lives in
`~/Library/Application Support/Positives/Archive` (an index and small thumbnails — originals are never touched)
and is listed on the start screen to continue later. Quitting with unsaved edits asks first.

### Masks

Up to 8 masks per photo, each with its own exposure, contrast, highlights, shadows, clarity, dehaze, white
balance, saturation, colour cast, tone curve and grain. A mask is made of parts combined in order — add (union),
subtract, intersect — each invertible: **brush** (size, feather, flow, ⌥ to erase), **linear** and **radial
gradients** (drawn by dragging on the photo, with handles), **luminance range**, **colour range** (picked on the
photo), **subject** / **people** found by Apple's Vision framework on the Mac (people are also segmented in a
close-up around each person, so small figures are found), and **sky**, found by a U²-Net sky segmentation network
(Core ML, on the Mac; MIT — see `Resources/SKY_MODEL_LICENSE.txt`). Detected masks are fitted to the photo's
edges with a guided filter at 1600 px. O shows the selected mask in red.

Masks live in sensor coordinates (before rotation, flips, straightening and crop, divided by the long side), so
they stay on the subject whatever the geometry. Their adjustments act at the stage where the global control of
the same name acts (white balance and exposure in scene light, contrast and curve in the tone stage, saturation
in the colour stage, grain where grain is made) — technically better than one pass after colour, as in the
original plan. Brush strokes are stored as vectors and drawn into half-resolution bitmaps on the GPU.

### Layers (double exposure)

Up to 3 other photos laid over the edited one. Each has a blend — **Film** (two exposures on one frame: the
light adds up, half each), **Screen**, **Lighten**, **Darken**, **Multiply**, **Normal** — amount, exposure,
temperature/tint, size, rotation, mirror, Fill/Fit, and a "where it shows" mask built from the same parts as masks
(subject, sky, brush, gradients…), evaluated on the photo underneath. Drag on the photo to move a layer.

Layers are composited first, in scene light (linear Rec.2020 at the photo's as-shot white balance, each layer at
its own default brightness), at full resolution; white balance, exposure, local tone, film, grain and everything
else then act on the double exposure as one picture, as on a double-exposed negative. Layers are placed on the
photo's sensor, so later crops and turns move both together. While a layer is being dragged only the view is
composited; the full-resolution composite follows on release. Formulas in `Pipeline/LayerMath.swift`.

### Presets and export

**Presets** (toolbar, or P): point at a preset to see it on the photo, click to apply — to every selected photo
when several are selected (⌘-click in the filmstrip). Eight starters (Portra Portrait, Golden Hour Gold,
Kodachrome Travel, CineStill Night, Fuji Recipe Chrome, HP5 Red Filter, Tri-X Street, Soft Matte); save your own
from the current look (kept in `~/Library/Application Support/Positives/Presets.json`). A preset never changes a
photo's crop, white balance, exposure, masks or layers.

**Export** adds a size — full resolution, a long edge in pixels, or a print size (cm at a dpi, written into the
file) — resampled with Lanczos-3 in linear light, and output sharpening for screen, glossy or matte paper (low /
standard / high): an unsharp mask on lightness only with soft halo limiting. The picture is sharpened, never the
grain: when there is grain, a grain-free render is sharpened and the grain laid back on as it was.

**Help → Credits & Licences** lists the work Positives builds on, with the full licence texts.

### Film looks and grain

- **Looks**: colour tables made by photographers to match how each stock looks when scanned — the
  [RawTherapee Film Simulation Collection](https://rawpedia.rawtherapee.com/Film_Simulation) (Pat David, Pavlov
  Dmitry, Michael Ezra; CC BY-SA 4.0) and [t3mujinpack](https://github.com/t3mujinpack/t3mujinpack) (João Almeida;
  MIT) for Kodak Gold, UltraMax and ColorPlus. Converted by `positives-cli make-looks` (8-bit quantisation smoothed,
  48³, 12-bit predictive coding) into `Sources/PositivesCore/Resources/FilmLooks.lzfse`. They work on sRGB, so
  wide-gamut colours are desaturated into sRGB first.
- **CineStill 800T / 50D** are simulated physically from the cinema stocks' spectral data
  ([spektrafilm](https://github.com/andreavolpato/spektrafilm), Andrea Volpato; CC BY-SA 4.0): tungsten balance and
  the red halation of film without anti-halation layer.
- **Grain** follows Newson et al. (2017), *Realistic film grain rendering*: a Boolean model — discs of
  log-normal radius placed by a Poisson process on the film in µm (so every zoom and the export show the same
  grains), seen through a slight scan blur; a sparse population in thin parts of the film and a dense one where it
  is dense; each grain belongs to a dye layer (colour grain = each layer's own dye clouds). Strength is the shot
  noise of the film's datasheet granularity, carried through a typical characteristic curve of the film type, so
  it follows the tones as on film. Grains far smaller than a screen pixel (and while panning) use a Gaussian of the
  same statistics. Drawn in two GPU passes (grains per cell, then per pixel).
- **Recipe** (Film page): Fujifilm-style settings with any film — dynamic range (DR100/200/400 highlight
  compression), Color Chrome and Color Chrome Blue, grain effect, white-balance shift (red / blue), highlight and
  shadow tone (−2…+4), colour, clarity.
- **Black & white filters**: yellow, orange, red, green, blue — Wratten-like transmittance curves applied to natural
  reflectance spectra and fitted to a 3×3 matrix, with the filter factor compensated. The filtered light reaches the
  black & white film table as a neutral grey weighted by that film's own colour sensitivity (measured from its
  table), so the table keeps its full tonal range.
- The looks' tables receive a camera-like tone (deeper shadows, brighter upper tones), fitted to X-E4 RAFs against
  the camera's own JPEGs, as the tables were made for such renderings.
- Film and brand names are trademarks of their owners, used only to say which film a look approximates; this
  project is not affiliated with or endorsed by them.

The fixed processing order is documented in `Sources/PositivesCore/Pipeline/Develop.swift`.

```bash
.build/release/positives-cli render photo.RAF out/ --set exposure=0.5 --set shadows=40   # exact export
"Positives - photo editor.app/Contents/MacOS/Positives - photo editor" --self-test <out dir> <photo folder>
```

## Negatives

Open a roll folder (⌘O or drag it onto the window): RAW files from any major camera (Fujifilm, Canon, Nikon,
Sony, Panasonic, Olympus / OM, Pentax, Leica, Hasselblad, Phase One, Sigma, any DNG) or TIFF / JPEG / HEIC / PNG
scans. When a camera wrote RAW + JPEG pairs only the RAW is used. Keys: ←/→ frames · B film base · W neutral
picker · C crop & straighten · [ ] rotate · \\ before/after · Z or double-click 100% · ⌘E export ·
⇧⌘C / ⇧⌘V copy/paste settings · ⌥⇧⌘V paste to the whole roll. Settings are saved as JSON next to the scans.

**Scanning tips** for the most accurate colour, whatever the film or camera: shoot RAW; keep the camera
exposure the same for the whole roll (manual); include a sliver of the film's edge (the rebate) in the frame —
it is the one place the app sees the bare film base, the reference of every colour; light from behind with an
even, high-CRI panel.

## Command line

```bash
swift build -c release
.build/release/negatives-cli convert ~/Pictures/Roll01 --format jpeg     # whole folder = one roll
.build/release/negatives-cli convert DSCF0001.RAF --base 0.02,0.01,0.2,0.04 --format tiff16
.build/release/negatives-cli info DSCF0001.RAF                            # camera, clip levels, base estimate
.build/release/negatives-cli demo photo.jpg out/                          # simulate a negative, convert it back
swift test                                                                # math, round trip, GPU, export, spectral scans
.build/release/negatives-bench run photo1.RAF photo2.RAF … --sheet s.jpg  # spectral test bench (any photos as scenes)
```

## How the conversion works

Formulas are documented next to the code in `Sources/NegativesCore/Math/`.

1. **Decode** (LibRaw, vendored): camera-native linear RGB, fixed daylight multipliers (never "as shot"),
   no curve, no sharpening, no noise reduction, highlights unclipped. Float from here on.
2. **Flat-field** (optional): divide by a blurred shot of the bare light panel.
3. **Film base**: median of a rebate rectangle (or automatic: brightest orange area, sprocket holes excluded).
4. **Picture detection** (`FrameDetector`): the surround — light table, rebate and sprocket holes, an opaque
   holder or mask, fogged film edges — is grown from the scan's border (flat areas; clear, untinted or denser
   than any picture; band- and ring-shaped base areas), so only the picture is measured.
5. **Density**: `D = −log10(pixel / base)` per channel, in the camera's own RGB.
6. **Neutral path**: at seven density levels the frame's strongest colour clusters are candidates for grey; the
   smoothest well-supported sequence from the base upward is found by dynamic programming (bands without a
   grey are skipped), pooled over the roll. The path is a curve, not a line — film toes and shoulders and a
   camera's overlapping filters bend it — and each channel is mapped onto green's scale through it, so greys
   are neutral at every tone. When the base was never seen (tight crops) the path is not tied to it.
7. **Colour model**: a neutral-preserving 3×3 in density space that undoes how camera filters see the dyes
   (fitted on 9 colour stocks × 3 camera sensitivities × 3 lights; colour error 5.1 → 3.2).
8. **Scene light**: `L = 10^((e − e_ref) / γ_film)`, then camera → linear Rec.2020 and white balance. Each
   frame's exposure puts its bright tones (90th percentile) where cameras meter them (+1.15 stops over grey).
9. **Print**: photographic-paper S-curve in log space (exposure, contrast, toe, shoulder, paper black).

The test bench (`Sources/NegativesBench`) simulates real stocks physically (spektrafilm spectral data:
sensitivities, curves, couplers, dyes, orange base) scanned by different cameras under different lights, at
over / under exposure, framed tightly, on a light table with rebate and holes, or in a holder. Over 243 frames
(81 rolls): neutral cast median 0.9 (OKLab ×100, ~1 is invisible), 90th percentile 1.9; exposure error median
0.26 stop. On real scans from pixls.us (Kodak Gold 200, Fuji 400, an old Canon scan, HP5) it was checked by eye.

Preview = full-resolution render, area-averaged; it is identical to the export by construction.

## Layout

```
Packages/DarkroomKit/    shared: DarkroomCore (raw, colour, GPU, export) · DarkroomUI (design system) · LibRaw
Sources/NegativesCore/   negative model, calibration, conversion kernels
Sources/PositivesCore/   editor pipeline (tone maths, develop kernel, render engine, film looks, archive)
Sources/*-cli/           command-line tools
Apps/Negatives, Apps/Positives   the two Mac apps
Tests/                   Swift Testing suites
```

## Licence

© 2026 Giacomo Ancora. Negatives and Positives are free software, licensed under the
[GNU General Public License, version 3](../LICENSE): you may use, share and change them, and anything built from
them must stay open source under the same licence. They come with no warranty.

They build on LibRaw, libjpeg-turbo, the LLVM OpenMP runtime, film data and looks from spektrafilm, RawTherapee
and t3mujinpack, and a U²-Net sky model — see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and, in either
app, Help → Credits & Licences.
