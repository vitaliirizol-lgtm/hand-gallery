# Hand Gallery

Static web page for the WPT Global × QuintAce hand gallery: hero banner, "What Is The Replayer?" intro,
Featured Hands carousel row, All Hands grid, and a working Load More button.

Originally built from the Figma file `hand gallery.fig` (page "Replayer Redesign", 1440px desktop), then
restyled to match the Claude design export (`Webpage Design.zip`): centered hero lockup, baked card-art
previews (`assets/hand-preview*.png`), varied hand titles, and cards linking to the QuintAce replayer.

## Run

```
python3 -m http.server 8642 --directory .
```

Then open http://localhost:8642 (also registered as `hand-gallery` in the workspace `.claude/launch.json`).

## Structure

- `index.html` / `styles.css` — markup and styles ported from the design export's `hand-gallery.css`
  (React bits replaced with vanilla equivalents).
- `script.js` — renders 3 featured + 9 all-hands cards from data; Load More reveals the rest, arrows
  scroll the featured row. Cards are links to `https://quintace.ai/replay/aID5LWzaqc`.
- `assets/hand-preview.png` / `assets/hand-preview-board.png` — baked card-art compositions.
- `assets/card-bg.svg` — card background (base fill, corner glows, gradient hairline border).
- `assets/wptglobal.svg`, `assets/quintace-logo.svg` — logos (WPT Global exported from Figma vector
  networks; QuintAce from the design export).
- `assets/cards/*.svg` — the 13 playing-card faces + back exported from the Figma vector networks
  (no longer referenced by the page, kept for reuse).
- `assets/img/` — raster assets extracted from the `.fig` archive (kept for reuse).

## tools/

Scripts used to decode the `.fig` file (a `.fig` is a zip: `canvas.fig` + `images/` + `thumbnail.png`;
`canvas.fig` is kiwi-encoded, zstd-compressed):

- `decode3.js` — unpacks `canvas.fig` into `scene.json` (needs `npm i kiwi-schema fzstd`).
- `tree.js` — prints a readable layout outline (positions, sizes, fills, text, fonts) from `scene.json`.
- `svgexport2.js` — exports any node to SVG, decoding Figma vector-network blobs (vertices/segments/regions,
  per-region style overrides, gradient transforms). Usage: `node svgexport2.js <sessionID:localID> out.svg`.

Scripts expect the extracted archive at `/tmp/handgallery_fig/`; adjust paths to reuse on another file.
