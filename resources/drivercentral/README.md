# DriverCentral images

Marketing images for the driver's DriverCentral listing. Each image is an HTML page rendered to PNG, and the rendered PNGs sit next to their sources.

| Path | Size | Used for |
| --- | --- | --- |
| `banners/spotlight-4096x848` | 4096x848 | DriverCentral homepage spotlight banner (emailed to DriverCentral, not uploaded) |
| `banners/launch-post-2400x1200` | 2400x1200 | Launch posts (c4forums, Reddit, Discord) |
| `banners/facts-strip-2400x200` | 2400x200 | The first image in the listing's description: four facts in a row |
| `photos/1-...` onward | 2000x2000 | Listing photos, uploaded in number order |

`assets/` holds what the pages share: the Finite Labs logo, and the brand's mark as `brand-mark.png`, taken from the brand's official kit.

## Making the set

1. Put the brand's mark in `assets/brand-mark.png`, from its official kit, and note the kit's URL and usage terms in this README. Never trace or redraw it.
2. In each page under `banners/`, replace "Driver Name", the chips and the line under them with what the driver does, from its docs and CHANGELOG. No tag lines. The facts strip holds facts that stay true between releases (the Control4 OS it needs, the trial, local or cloud, what it controls), never an install count.
3. In `photos/frame.html`, replace "Driver Name" beside the mark.
4. Add the listing photos: a screenshot per photo in `photos/sources/` and a line per photo in `photos/photos.txt`.
5. Render, and check every image by eye.

Every page takes its accent, `--accent`, from the repo's `primary_color`. The banners and the photo frame glow in `--glow`, which is the accent unless the page sets a lighter tint for a dark brand color. The facts strip shrinks its type until four longer facts fit.

## Rendering

```bash
resources/drivercentral/render.sh
```

This needs Google Chrome and a network connection (the pages load Inter from Google Fonts). It renders every page at 2x and overwrites the PNGs. Pass a directory to render somewhere else instead.

## Listing photos

Every photo is `photos/frame.html` around one screenshot from `photos/sources/`. Each line of `photos/photos.txt` is `<output name>|<query>`, and the query sets the fields below; lines starting with `#` are skipped. `crop`, `end` and `tail` are pixels of the screenshot scaled to the card's 880 px width.

- `t`, `s`: the title and subtitle.
- `img`: the screenshot in `photos/sources/`.
- `crop`: pixels cut from the top of the screenshot.
- `end`: the height kept fully visible below `crop`.
- `tail`: extra rows under `end` that fade out, for a list that continues; `bg` is the fade color and `more` the text over it.
- `fit=1`: scale the whole screenshot to fit instead.

The DriverCentral viewer hides about the bottom 15% of a square photo until the popup is scrolled, so the frame keeps everything above that line (`SAFE` in `frame.html`).

Take the screenshots from the DriverCentral build, never from the source pages, with demo data that is plainly fictional (a made-up vendor and model, a locally administered address). Retake a screenshot when the view it shows changes, then rerender.
