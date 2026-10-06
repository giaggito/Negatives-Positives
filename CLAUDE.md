# Positives & Negatives

Two native macOS apps (Swift, SwiftUI, Metal; Apple silicon, macOS 14+) sharing one engine:

- **Positives - photo editor** (`Apps/Positives`, engine `Sources/PositivesCore`): a complete photo editor
  inspired by analogue photography: film looks, grain, halation, masks, double-exposure layers, presets, export.
- **Negatives** (`Apps/Negatives`, engine `Sources/NegativesCore`): converts photographed or scanned film
  negatives into positives automatically, per roll.
- **DarkroomKit** (`Packages/DarkroomKit`): shared RAW decoding (vendored LibRaw), colour, GPU layer, export,
  credits, and the UI design system (`DarkroomUI/Controls.swift`, `Theme`).

How the apps work, feature by feature and the image pipelines: `docs/TECHNICAL.md`. Read it before changing
image processing.

## Build and test

```bash
brew install xcodegen libomp jpeg-turbo   # once; libomp and jpeg-turbo are linked statically
xcodegen generate                         # project.yml -> Darkroom.xcodeproj; rerun after adding/removing files
xcodebuild -project Darkroom.xcodeproj -scheme Positives -configuration Release -derivedDataPath .build/xcode build
xcodebuild -project Darkroom.xcodeproj -scheme Negatives -configuration Release -derivedDataPath .build/xcode build
swift test                                # all engine tests (identity, GPU = CPU, preview = export, film, conversion)
```

Products land in `.build/xcode/Build/Products/Release/` ("Positives - photo editor.app", "Negatives.app").
Build Swift packages one product at a time (`swift build -c release --product X`): several `--product` flags
build only one of them.

Install locally: `rm -rf "/Applications/<app>.app" && cp -R ".build/xcode/Build/Products/Release/<app>.app" /Applications/`,
only after `pgrep -f "/Applications/<app>.app/"` shows the app is not running.

Quality tools (keep them working when changing the engines):
- `Positives --self-test <out dir> <folder of photos>` drives the real app and writes window/canvas PNGs and a
  log with in-app frame times.
- `negatives-bench run <scene photos…>` (any photos as scenes, not the owner's) and `Tests/NegativesSpectralTests`: Negatives on physically
  simulated scans of real film stocks (cameras × lights × framings), scored for neutrality and exposure.
- `positives-cli render` (CLI render of an edit) and `positives-cli make-looks` (rebuilds `FilmLooks.lzfse`).

## Conventions

- Image quality first, then smoothness (60 fps while dragging), then workflow.
- Everything is float (rgba32Float GPU textures); preview and export come from the same pipeline. The pipeline
  order is documented at the top of `Sources/PositivesCore/Pipeline/Develop.swift`; grain is applied after all
  spatial filters (clarity and sharpening never touch it).
- Interface: neutral greys only (R = G = B) so nothing tints the photo, hairline dividers, small uppercase
  section titles, label/value sliders. Use `DarkroomUI` components. The website follows the same language.
- Comments explain why, briefly; match the surrounding code.
- Third-party data and code are listed in `THIRD_PARTY_NOTICES.md` and in the apps' Credits window
  (`SharedCredits`, `PositivesCore/Model/Credits.swift`); keep both up to date when adding anything.

## Publishing

- Repository: https://github.com/giaggito/Negatives-Positives (GPL-3.0). Branch `main` = source.
- Website: https://giaggito.github.io/Negatives-Positives/ = branch `gh-pages` (plain `index.html`,
  `privacy.html`, `terms.html`, icons). Edit it with `git worktree add .build/site gh-pages`, commit, push.
- Downloads: GitHub Releases, assets always named exactly `Positives.dmg` and `Negatives.dmg` (the site and
  README link to `releases/latest/download/<name>.dmg`).
- New version: `scripts/release.sh <version> "<notes in plain words>"` (tests, builds, checks the apps don't
  depend on Homebrew, packs both DMGs, bumps the version, pushes, publishes the release). Try
  `scripts/release.sh <version> --dry-run` first.
- Support link (Buy Me a Coffee) is in `.github/FUNDING.yml`, the README, the website and both apps' Help menu
  (`SharedCredits.supportURL`).
- The apps are not signed with an Apple Developer ID yet: users confirm the first launch in System Settings →
  Privacy & Security → Open Anyway. With a Developer ID: sign with hardened runtime, notarise
  (`xcrun notarytool submit … --wait`), staple, then pack; add this to `scripts/release.sh`.

@CLAUDE.local.md
