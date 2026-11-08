# OpenGlyph landing site

Static [Astro](https://astro.build) site for <https://openglyph.ma2.dev>, deployed as a Cloudflare Worker with static assets. It lives in `site/` and does not touch the app code.

All product copy comes from the repository's `README.md`, `docs/BUILDING.md` and `CHANGELOG.md`. The icon (`public/icon.png`, 256 px) is downscaled from `Resources/OpenGlyph-icon.png`; `public/menu.png` is `docs/images/menu.png`. Fonts are self-hosted via Fontsource, so the page makes no third-party requests.

## Run locally

Requires Node 20 or later.

```sh
cd site
npm install
npm run dev        # http://localhost:4330 (also bound on the LAN/tailnet)
npm run build      # outputs dist/
npm run preview    # serve the built dist/
```

## Deploy

`wrangler.jsonc` defines the Worker `site-openglyph`, serves `dist/` as static assets, and attaches the custom domain `openglyph.ma2.dev` (Wrangler creates that DNS record; no other records are touched).

```sh
cd site
export CLOUDFLARE_API_TOKEN=...   # or: source ~/.config/cloudflare/agents.env
export CLOUDFLARE_ACCOUNT_ID=...
npm run deploy                    # astro build && wrangler deploy
curl -I https://openglyph.ma2.dev # expect HTTP 200
```

## Structure

- `src/pages/index.astro` – the landing page
- `src/pages/404.astro` – not-found page (served via `not_found_handling`)
- `src/styles/global.css` – design tokens, light/dark themes, layout and animations
- `public/` – icon and screenshot
