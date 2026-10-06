# Kleio website

Static landing page at https://kleio.talix.app (Cloudflare Worker `kleio-site`, deployed with `npx wrangler deploy`). No build step or dependencies.

Preview it locally:

```sh
python3 -m http.server 4173 --directory website
```

Then open http://localhost:4173. Any static host can serve this folder as is (GitHub Pages, Netlify, Vercel).

Deploy from the repository root:

```sh
npx --yes wrangler@4 pages deploy website --project-name kleio-nan --branch main
```

The Pages project isn't connected to Git, so pushing doesn't deploy.
