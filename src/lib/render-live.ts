/**
 * Markdown and TeX, set in the browser — for the text somebody has just written or edited, and
 * for anything the item-page overlay brings in that the build has not set yet.
 *
 * **The same pipeline as the build, not a second one.** `renderMarkdown()` in src/lib/markdown.ts
 * is imported as it is, with the same sanitising schema and KaTeX's `trust: false`, so a comment
 * set here and the same comment set at the next build are the same HTML. The sanitiser runs in
 * the reader's own browser on text the database handed back, and nothing it produces is ever
 * stored; that is why it is safe to run here at all.
 *
 * **Loaded only when something needs it.** The dynamic import puts the parser, the sanitiser and
 * KaTeX in a chunk of their own, fetched the first time this is called. An ordinary reader of an
 * ordinary page never calls it and never downloads it — the zero-JavaScript-by-default argument
 * in docs/decisions.md still holds for them. KaTeX's stylesheet and fonts are already on every
 * page (src/layouts/Base.astro), because built pages need them.
 */

/**
 * Sanitised HTML for `source`. Rejects only if the chunk cannot be fetched — an offline reader,
 * a deploy that replaced the chunk under an open page — which `setRendered()` turns into the
 * source shown as written.
 */
export async function renderLive(source: string): Promise<string> {
  const { renderMarkdown } = await import('./markdown');
  return renderMarkdown(source);
}

/**
 * Put `source`, set, into `element`, and say whether that worked.
 *
 * On failure the text goes in as written, with `fallbackClass` added so it reads as source
 * rather than as a broken formula. `textContent`, never `innerHTML`, on that path: unrendered
 * text has been through no sanitiser.
 */
export async function setRendered(
  element: HTMLElement,
  source: string,
  fallbackClass: string,
): Promise<boolean> {
  try {
    const html = await renderLive(source);
    element.classList.remove(fallbackClass);
    element.innerHTML = html;
    return true;
  } catch {
    element.classList.add(fallbackClass);
    element.textContent = source;
    return false;
  }
}
