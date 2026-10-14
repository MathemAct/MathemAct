/**
 * Base-aware URL building. Use this for every internal link and asset reference.
 *
 * Why this file exists
 * --------------------
 * The site is served from `https://mathemact.github.io/MathemAct/`, so internal URLs
 * carry a `/MathemAct` prefix. Astro exposes that prefix as `import.meta.env.BASE_URL`
 * but does not rewrite markup for you — a literal `href="/reports/"` resolves to
 * `mathemact.github.io/reports/`, outside our site, and 404s.
 *
 * Three reasons to funnel every path through here rather than writing them by hand:
 *
 *  1. The prefix is a deployment detail, not content. Moving to a custom domain should
 *     be a one-line change to `base` in astro.config.mjs, not a repo-wide find and
 *     replace across every template.
 *  2. `trailingSlash: 'always'` is configured, so a link missing its trailing slash is
 *     a 404 in `astro dev` and an extra redirect hop on GitHub Pages. Enforcing it in
 *     one function means it cannot be forgotten in a template.
 *  3. Hardcoded prefixes rot silently. `/MathemAct/MathemAct/...` is the classic
 *     symptom of someone half-remembering that a prefix is needed.
 *
 * Pass site-root-relative paths: `path('/reports/')`, not `path('../reports/')`.
 * Absolute URLs and `mailto:` links are returned untouched, so it is safe to call on a
 * href that might be either.
 */

/** BASE_URL with any trailing slash removed: `/MathemAct` here, `''` at a domain root. */
const BASE_PREFIX = import.meta.env.BASE_URL.replace(/\/+$/, '');

/** True for anything already addressing another origin or scheme. */
function isExternal(to: string): boolean {
  return /^[a-z][a-z0-9+.-]*:/i.test(to) || to.startsWith('//');
}

function join(to: string): string {
  return `${BASE_PREFIX}/${to.replace(/^\/+/, '')}`;
}

/**
 * Build an internal **page** URL, with the base prefix and a trailing slash.
 *
 * Any `?query` or `#fragment` is preserved and stays after the slash.
 *
 *   path('/')                   // '/MathemAct/'
 *   path('/reports/')         // '/MathemAct/reports/'
 *   path('/reports')          // '/MathemAct/reports/'
 *   path('/reports/?area=research')
 *                               // '/MathemAct/reports/?area=research'
 *   path('https://ror.org')     // unchanged
 */
export function path(to: string): string {
  if (isExternal(to)) return to;

  const cut = to.search(/[?#]/);
  const route = cut === -1 ? to : to.slice(0, cut);
  const suffix = cut === -1 ? '' : to.slice(cut);
  const joined = join(route);

  return (joined.endsWith('/') ? joined : `${joined}/`) + suffix;
}

/**
 * Build an internal **file** URL: fonts, the JSON export, images, the RSS feed.
 *
 * Same base prefix as `path()`, but no trailing slash is added — a trailing slash on a
 * filename makes it a different, non-existent resource.
 *
 *   asset('/fonts/plex-sans-400.woff2')  // '/MathemAct/fonts/plex-sans-400.woff2'
 */
export function asset(to: string): string {
  if (isExternal(to)) return to;
  return join(to);
}
