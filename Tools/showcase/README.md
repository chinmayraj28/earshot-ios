# Showcase images

`generate.mjs` makes the images in `docs/showcase/` (used at the top of the main README,
and ready to use on a website) from the real screenshots in `docs/screenshots/`.

## Run it

From the repository root, after `npm install` in `web/` (the script borrows the Chromium
that Playwright installed for the web tests; it adds no dependencies of its own):

```sh
node Tools/showcase/generate.mjs              # everything
node Tools/showcase/generate.mjs hero tiles   # only some: hero, web, tiles, social
```

It needs no network and no running app. It prints each file with its size.

## What it makes

| File | Size (pixels) | What it is |
| --- | --- | --- |
| `hero.png` | 2400 × 1350 | Five phones fanned out on the dark Earshot background. |
| `hero-light.png` | 2400 × 1350 | The same with light-mode screens on warm paper. |
| `web.png` | 2400 × 1500 | The web version in a plain browser window, with the phone-width layout in a phone beside it. |
| `tile-<name>.png` | 630 × 780 | One screen per card, with a caption, for a grid of three per row. |
| `social-preview.png` | 1280 × 640 | For GitHub's social preview (Settings → General → Social preview). |

The hero, web and tile images have transparent rounded corners, so they sit well on light
and dark pages. The social preview is square-cornered and fully opaque.

## Changing which screenshot goes where

Edit the `CONFIG` object at the top of `generate.mjs`. Paths are relative to
`docs/screenshots/`.

- `hero.dark` and `hero.light`: five screenshots, left to right; the middle one is the
  large front phone.
- `web`: the wide screenshot for the browser window and the narrow one for the phone
  (set `narrow` to `null` to leave the phone out), and `theme`.
- `tiles`: one entry per card. `name` becomes `tile-<name>.png`, `caption` is printed in
  capitals above the phone. Use `kind: "web"` for a phone-width web screenshot: it gets a
  small browser address bar instead of a status bar.
- `social`: the title, tagline, a short line under it, and three phones.

After adding a tile, also add it to the grid in the main `README.md`.

## Notes

- The phone and browser frames are drawn in CSS: a plain rounded body, a thin bezel and a
  camera cut-out. They are deliberately generic and do not copy any manufacturer's design.
- The iOS screenshots must be the simulator's 1206 × 2622 captures. The frame draws its
  own camera pill exactly where the simulator puts one, so screenshots with and without it
  look the same.
- Images are saved as full-colour PNG. Reducing them to a 256-colour palette was tried and
  caused visible banding in the background glow, so it is not done.
- The rounded wordmark font (SF Pro Rounded) is read from macOS's system fonts. On other
  systems the social preview falls back to the default sans-serif font.
