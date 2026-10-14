/**
 * Markdown with TeX, rendered to HTML — at build time, and in the browser.
 *
 * Comments and claim contributions go through here. It is therefore a security boundary,
 * and the ordering below is the part worth understanding before changing anything.
 *
 * **It runs in two places, and they must stay one pipeline.** The build calls it from
 * component frontmatter. Since 2026-10-11 the browser calls it too, through
 * src/lib/render-live.ts, for text somebody has just written or edited and for changes the
 * item-page overlay brings in before the next build — so what they see is set straight away
 * rather than shown as source. Nothing here may use a Node API, and nothing may be configured
 * differently for one caller: the same text must produce the same HTML in both.
 *
 * The pipeline
 * ------------
 *   parse markdown → GFM → find math → to HTML → SANITISE → render TeX → serialise
 *
 * Sanitising happens *before* KaTeX, not after, for two reasons:
 *
 *  1. KaTeX emits a large amount of markup — nested spans carrying dozens of layout
 *     classes, plus a parallel MathML tree. Sanitising afterwards would mean adding all
 *     of it to the allowlist, which in practice means allowing arbitrary spans and
 *     classes and giving up most of what the sanitiser was for.
 *  2. It is unnecessary. The sanitiser's job is the untrusted input; at the point KaTeX
 *     runs, all that survives of a formula is its TeX source as a text node. KaTeX
 *     escapes what it renders, and with `trust: false` it refuses the commands that
 *     could emit a URL or raw HTML.
 *
 * Two further defences, so this does not rest on one mechanism:
 *
 *  - `remark-rehype` is called without `allowDangerousHtml`, so raw HTML in the source
 *    is discarded at the mdast→hast boundary before the sanitiser ever sees it.
 *  - KaTeX runs with `trust: false` (its default, stated explicitly because it is
 *    load-bearing), which disables \href, \url, \includegraphics, and \htmlClass.
 *
 * If you add a plugin, add it on the correct side of the sanitise step and say why.
 */
import rehypeKatex from 'rehype-katex';
import type { Options as KatexOptions } from 'rehype-katex';
import rehypeSanitize, { defaultSchema } from 'rehype-sanitize';
import type { Options as SanitizeSchema } from 'rehype-sanitize';
import rehypeStringify from 'rehype-stringify';
import remarkGfm from 'remark-gfm';
import remarkMath from 'remark-math';
import remarkParse from 'remark-parse';
import remarkRehype from 'remark-rehype';
import { unified } from 'unified';

/**
 * The allowlist, extended in exactly one respect.
 *
 * `remark-math` marks formulas by putting `math-inline` on a span and `math-display` on
 * a div, and `rehype-katex` finds them by that class. The default schema strips class
 * attributes from both elements, which would leave every formula on the site rendered as
 * its own TeX source — a failure that looks like a KaTeX bug and is not one.
 *
 * The nested-array form allowlists *specific values*: a span may carry `math-inline` and
 * nothing else. It is not a general permission to set classes.
 */
// Annotated rather than inferred: without it TypeScript widens the nested
// ['className', ...] tuples to string[] and the schema stops matching Schema's shape.
const schema: SanitizeSchema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    span: [
      ...(defaultSchema.attributes?.['span'] ?? []),
      ['className', 'math', 'math-inline'],
    ],
    div: [
      ...(defaultSchema.attributes?.['div'] ?? []),
      ['className', 'math', 'math-display'],
    ],
  },
};

const processor = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkMath)
  // No allowDangerousHtml: raw HTML in the source is dropped here, before sanitising.
  .use(remarkRehype)
  .use(rehypeSanitize, schema)
  .use(rehypeKatex, {
    // Explicit because it is the reason this is safe to run after sanitising: it blocks
    // \href, \url, \includegraphics and \htmlClass. Do not set this to true.
    trust: false,
    // Do not complain about things like Unicode text inside math mode. Mathematicians
    // paste real transcripts; pedantry here produces noise, not correctness.
    strict: false,
    // Both HTML and MathML, which is KaTeX's default and what screen readers use.
    output: 'htmlAndMathml',
    //
    // Note there is no `throwOnError` here: rehype-katex omits it from its options
    // deliberately, because it always catches parse errors itself and renders the
    // offending source in a `.katex-error` span carrying the message as a title. That is
    // the behaviour we want for user-submitted TeX — one malformed formula must not fail
    // the build — so there is nothing to configure. Styled in Markdown.astro.
  } satisfies KatexOptions)
  .use(rehypeStringify)
  .freeze();

/**
 * Render a markdown-with-math string to sanitised HTML.
 *
 * At build time from component frontmatter, and in the browser through `renderLive()`, which
 * imports this module dynamically so the parser and KaTeX are fetched only by a page that has
 * something to set.
 */
export async function renderMarkdown(source: string): Promise<string> {
  const file = await processor.process(source);
  return String(file);
}
