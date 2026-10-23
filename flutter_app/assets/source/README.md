# Original Soft Orbit artwork

Original CodexTimeZone project artwork: midnight rounded tile, blue/cyan open time orbit, readable clock hands and four-point star. No external icon pack or downloaded logo is used. The app and high-contrast tray marks share one coordinate model; 16–24px sizes use optical stroke adjustments. Existing project licensing and attribution files are preserved.

The SVG masters and small variants are generated from the original vector coordinates in `scripts/generate-brand-icons.cjs`. The same SVG is rasterized by sharp/libvips; no hand-drawn raster alternate or silent renderer fallback is used. Committed PNG/ICO assets need no new application runtime dependency.

Reproduce from the repository root using an already installed renderer, without installing or downloading packages:

```powershell
node scripts/generate-brand-icons.cjs --sharp-module 'ABSOLUTE_PATH_TO_INSTALLED_SHARP'
```

Optional `--output-root` writes a separate reproduction tree; `--preview-dir` saves every actual-size app/tray PNG for inspection. `brand-generation.json` records the canonical generator digest, renderer versions and every generated asset digest. Reproducing exact bytes requires these renderer versions.

Both ICOs contain explicit PNG-compressed 32-bit RGBA frames at 16,20,24,32,48,64,128,256px. `app_icon.png` is the 256px app mark used by Flutter; Windows embeds both ICO resources. Visible Explorer grouping, old pinned shortcut refresh and icon-cache behavior require separate observation.
