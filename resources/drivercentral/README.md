# DriverCentral images

Marketing images for the ESPHome listing (DriverCentral product 819). Each image is an HTML page rendered to PNG, and the rendered PNGs sit next to their sources.

| Path | Size | Used for |
| --- | --- | --- |
| `banners/spotlight-4096x848` | 4096x848 | DriverCentral homepage spotlight banner (emailed to DriverCentral, not uploaded) |
| `banners/launch-post-2400x1200` | 2400x1200 | Launch posts (c4forums, Reddit, Discord) |
| `banners/facts-strip-2400x200` | 2400x200 | The first image in the listing's description: four facts in a row |

`assets/` holds what the pages share: the Finite Labs logo, `scene.js`, which draws the banners' art, and ESPHome's logomark as `brand-mark.png`, the one in the Open Home Foundation's ESPHome brand assets (https://brands.openhomefoundation.org/esphome/; `esphome/logo/screen/logomark/ESPH-logomark-color.svg` in https://github.com/OpenHomeFoundation/brand-assets at 163c9422), exported from this repo's `resources/Driver Icons.sketch`. Those assets say the logo is not for commercial use without the Foundation's written permission (partner@openhomefoundation.org). We haven't obtained that permission; the mark is used only to name the devices the driver works with.

The banners' art is `circuit`: traces from the logo to six devices, set on each banner's `<svg class="scene">`. The template's DriverCentral README lists the styles, and the headline, chips and subtitle shrink until they end clear of the art.

## Rendering

```bash
resources/drivercentral/render.sh
```

This needs Google Chrome and a network connection (the pages load Inter from Google Fonts). It renders every page at 2x and overwrites the PNGs. Pass a directory to render somewhere else instead.

Every page takes its accent, `--accent`, from the repo's `primary_color`. The banners and the photo frame glow in `--glow`, which is the accent unless the page sets a lighter tint for a dark brand color. The facts strip shrinks its type until four longer facts fit.

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
