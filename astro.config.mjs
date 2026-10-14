// @ts-check
import { defineConfig } from 'astro/config';

// MathemAct is served by GitHub Pages as a *project* site, so it lives under a path
// prefix rather than at a domain root:
//
//   https://mathemact.github.io/MathemAct/
//   ^ site ------------------- ^ base
//
// `site` is the origin only; `base` is the path prefix. Astro joins them for canonical
// URLs and the sitemap, and exposes `base` to the app as `import.meta.env.BASE_URL`.
//
// The prefix is the single most common way to break a GitHub Pages deploy, because
// `astro dev` also serves under `base`, so a wrong link fails identically in both
// places — but a *hardcoded* link like `/reports/` silently works in neither and is
// easy to miss locally. Never write internal paths by hand; route them through
// `path()` in src/lib/paths.ts.
//
// If a custom domain is adopted later: set `site` to that domain, set `base` to '/',
// add public/CNAME, and every link built through `path()` keeps working untouched.
export default defineConfig({
  site: 'https://mathemact.github.io',
  base: '/MathemAct',

  // Reads are served as static files from the repo (see CLAUDE.md, "Read/write split").
  // There is no application server; Supabase is only ever called from the browser.
  output: 'static',

  // GitHub Pages resolves /foo to /foo/index.html with a 301. Emitting directory-style
  // pages and always linking with a trailing slash avoids that extra round trip.
  build: { format: 'directory' },
  trailingSlash: 'always',

  // Off deliberately. Astro's HTML compressor does not collapse whitespace between a
  // text node and an adjacent inline element — it deletes it. So this, which is how a
  // formatter will wrap any long paragraph:
  //
  //     ... and licensed
  //     <a href="...">CC BY 4.0</a>, so it can be analysed
  //
  // ships as "licensedCC BY 4.0". The bug is invisible in source, survives review, and
  // is only ever caught by looking at the rendered page. It bit this project three times
  // in two days.
  //
  // Keeping the source correct by hand is not a fix, because the editor's formatter
  // re-wraps these lines on save and reintroduces it. The output is a few hundred bytes
  // larger before compression and effectively identical after gzip, which is a trade
  // worth making for an audience that will notice a missing space.
  compressHTML: false,
});
