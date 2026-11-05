# DriverCentral images

Marketing images for the driver's DriverCentral listing. Each image is an HTML page rendered to PNG, and the rendered PNGs sit next to their sources.

| Path | Size | Used for |
| --- | --- | --- |
| `banners/spotlight-4096x848` | 4096x848 | DriverCentral homepage spotlight banner (emailed to DriverCentral, not uploaded) |
| `banners/launch-post-2400x1200` | 2400x1200 | Launch posts (c4forums, Reddit, Discord) |
| `banners/facts-strip-2400x200` | 2400x200 | The first image in the listing's description: four facts in a row |
| `photos/1-...` onward | 2000x2000 | Listing photos, uploaded in number order |

`assets/` holds what the pages share: the Finite Labs logo, `scene.js`, which draws the banners' art, and the brand's logo as `brand-mark.png`.

## Making the set

1. Put the brand's logo in `assets/brand-mark.png`: the version its official kit makes for dark backgrounds, unedited, and note the kit's URL and usage terms in this README. Trim only its transparent margin. Never trace, redraw, recolor or crop the art, and never cut a mark out of a lockup the brand only supplies whole. A kit with no dark-background logo, or only one too small to stay sharp, gets a light hub (Banner art, below).
2. In each page under `banners/`, replace "Driver Name", the chips and the line under them with what the driver does, from its docs and CHANGELOG. No tag lines, and no counts that change between releases (say "thousands of devices", not a number). The facts strip holds facts that stay true between releases: the Control4 OS it needs, the trial, local or cloud, what it controls.
3. Pick the banners' art on the `<svg class="scene">` element (Banner art, below). Both banners use the same attributes.
4. In `photos/frame.html`, replace "Driver Name" beside the logo.
5. Fill in the trademark notice at the bottom of the spotlight, the launch post and the photo frame: the brand's names and Control4, with any symbol or wording the brand's own guidelines require.
6. Add the listing photos: a screenshot per photo in `photos/sources/` and a line per photo in `photos/photos.txt`.
7. Render, and check every image by eye.

Every page takes its accent, `--accent`, from the repo's `primary_color`. The banners and the photo frame glow in `--glow`, which is the accent unless the page sets a lighter tint for a dark brand color. The facts strip shrinks its type until four longer facts fit.

## Banner art

`scene.js` draws the art on the right of both banners from the `<svg class="scene">` element's attributes. The brand's logo always sits at its center, and the art uses the page's `--glow` (or `data-tint`). Pick the style that shows what the driver does. The headline, chips and subtitle shrink until they end clear of the art.

- `data-logo`: the logo, usually `../assets/brand-mark.png`.
- `data-hub`: `circle` for a square logo, `pill` for a wordmark. When the brand's kit has no logo for dark backgrounds, or only one too small to stay sharp, use `circle-light` or `pill-light`, a white hub for its usual logo.
- `data-style`, and what it needs:
  - `mesh`: six devices linked to the logo. `data-icons` names six.
  - `rings`: sound pulses under a night sky. `data-icons` names four.
  - `ripples`: water ripples and bubbles. `data-icons` names four.
  - `dial`: a round thermostat dial, with floor heat in the gap below. `data-icons` names two.
  - `circuit`: traces from the logo to six pads. `data-icons` names six.
  - `matrix`: four sources routed through the logo to four screens. `data-icons` names the source and the screen icon.
  - `strip`: a glowing LED strip.
  - `chart`: a live line chart. `data-items` holds three series names, `name|name|name`.
  - `topics`: messages fanning out to five labels. `data-items` holds `icon:label|...`.
  - `tiles`: a grid of six labeled tools. `data-items` holds `icon:label|...`.
  - `hero`: a product image instead of art, in `data-img`. It's drawn larger than a logo: 440 px wide on the spotlight and 400 px on the launch post.
- Icons: bulb, motion, thermo, plug, lock, remote, strip, lightstrip, switch, meter, sound, moon, sunrise, clock, note, glow, door, fan, box, tv, globe, vars, sigma, branch, link, water, flame, calendar, chip. They're drawn for these banners, never taken from a brand. Add one to `scene.js` when a driver needs it.

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
