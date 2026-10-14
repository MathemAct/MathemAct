/**
 * From a view page to the real page, once the real page exists.
 *
 * `/reports/view/` and `/opinions/view/` exist for rows newer than the build: they fetch the row
 * and render it in the browser. Since the site rebuilds within minutes of a write, the static page
 * usually exists by the time anybody follows a link here — the activity feed always links to a
 * view page — and the static page is the better one: a claim's contributions and a report's
 * confirmations are only there. Worse, a link like `/opinions/view/?id=X#comment-Y` used to land
 * on a view page saying nobody had written anything, beside a contribution that did exist.
 *
 * So a view page asks first whether its static page is there, and if so goes to it, keeping the
 * fragment. That never produces the 404 a view page must not link to (CLAUDE.md): it navigates
 * only after the page has answered.
 *
 * GitHub Pages answers a missing page with a real 404, so a HEAD request is the whole check. Any
 * failure, or no answer within a few seconds, means "stay": the view page works on its own.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const TIMEOUT_MS = 3000;

/**
 * Replace this page with `builtHref` if it exists. Resolves true when it has navigated away, so
 * the caller does nothing more.
 */
export async function handOverToBuiltPage(id: string, builtHref: string): Promise<boolean> {
  if (!UUID.test(id)) return false;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(builtHref, {
      method: 'HEAD',
      cache: 'no-store',
      signal: controller.signal,
    });
    if (!response.ok) return false;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }

  window.location.replace(`${builtHref}${window.location.hash}`);
  return true;
}
