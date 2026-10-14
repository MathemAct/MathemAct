/**
 * The data attributes a claim card carries, computed in one place.
 *
 * Same argument as `src/lib/report-facets.ts`, and the same failure it exists to prevent: the
 * listing filters and sorts by reading values off a card's `dataset`, and cards are built
 * twice — by `/opinions/index.astro` during the build, and by the freshness overlay in the
 * browser for anything posted since. A card whose attributes were assembled differently is a
 * card that fails a sort it should be in, and the reader has no way to notice.
 *
 * So neither consumer writes an attribute name. Both call `claimCardAttrs()` and hand the
 * result either to Astro's spread or to `applyCardAttrs()`, which means a renamed attribute
 * breaks the build rather than quietly halving a sort.
 *
 * **This module must not import anything that reaches src/lib/supabase.ts.** It is imported by
 * the listing's client script, and CLAUDE.md's rule is that a reading page never loads the auth
 * bundle. It imports nothing at all.
 */

/**
 * What the two aggregate sorts need, or null when the claim has no aggregates.
 *
 * Null is the state a claim the overlay added is always in, and it is also the state of an
 * exported claim with fewer than ten scored positions. Both are the same fact — *this cannot
 * be ranked yet* — and they are deliberately not distinguished here, because the sort treats
 * them identically and the card renders no distribution either way.
 */
export interface ClaimShares {
  readonly divided: number | null;
  readonly consensus: number | null;
}

export interface ClaimFacetInput {
  readonly area: string;
  readonly createdAt: string;
  /** Positions plus contributions. Zero is a true statement about a claim posted an hour ago. */
  readonly interactions: number;
  readonly shares?: ClaimShares | null;
  /**
   * When anything last happened. Absent on a card the overlay built, which sorts it last under
   * "recently active" — mildly wrong for the newest thing on the page, and the alternative is
   * inventing an activity date for a claim whose activity the export has not seen. Its
   * `createdAt` is not that date: it is when the claim was asked.
   */
  readonly lastActivityAt?: string | null;
  /**
   * arXiv category codes. Pipe-separated on the card, because the engine's `multi` dimensions
   * split on `|` — a code contains a dot and never a pipe, which is why that separator was
   * chosen for the reports' tags and is reused here rather than invented again.
   */
  readonly tagCodes?: readonly string[];
}

/**
 * A number for a sort key, or the empty string.
 *
 * The empty string is not a formatting choice; it is the engine's contract. `numeric()` in
 * listing-filters.ts maps `''` to ±Infinity so the card sorts last under either direction,
 * and maps `'0'` to zero, which is a real reading. On these two attributes the difference
 * matters more than anywhere else on the site: a claim with no aggregates rendered as `0`
 * divided would sort among the claims the community *agrees* about, and a `0` consensus would
 * sort among the most contested. Neither is true of a claim nobody has answered.
 *
 * The mirror of `sortValue()` in report-facets.ts, for the same reason: an unanswered scale is
 * not a zero.
 */
export function shareValue(share: number | null | undefined): string {
  return share === null || share === undefined ? '' : String(share);
}

/**
 * Every attribute a claim `<li>` needs, keyed exactly as the markup spells it.
 *
 * Returned with `data-` prefixes rather than as a `dataset`-shaped object so that the Astro
 * spread and the DOM path take the identical strings. A `dataset` key and an attribute name
 * differ by a camelCase conversion, and that conversion is precisely where two consumers of
 * "the same" definition drift apart.
 */
export function claimCardAttrs(input: ClaimFacetInput): Record<string, string> {
  return {
    'data-area': input.area,
    'data-created': input.createdAt,
    'data-interactions': String(input.interactions),
    'data-divided': shareValue(input.shares?.divided),
    'data-consensus': shareValue(input.shares?.consensus),
    'data-active': input.lastActivityAt ?? '',
    'data-tags': (input.tagCodes ?? []).join('|'),
  };
}

/** The DOM half. Used by the overlay so a fresh card is attributed by the same function that
 *  attributed every card the build wrote. */
export function applyCardAttrs(node: HTMLElement, attrs: Record<string, string>): void {
  for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value);
}

/**
 * A count read back off a `data-` attribute, or NaN when there is not one.
 *
 * **`Number('')` is 0, and that is the whole reason this function exists.** Astro renders an
 * attribute whose value is the empty string as a bare attribute — `data-contributions` with no
 * `=""` — and `dataset` hands that back as `''`. Parsing it directly turns "the export has
 * never counted this" into "somebody counted this and the answer was none", which is the one
 * distinction every absent figure on the claim page depends on.
 *
 * NaN rather than null so that callers can use `Number.isFinite` and cannot accidentally pass
 * the falsy-but-valid 0 through a `??`.
 */
export function readCount(value: string | undefined): number {
  if (value === undefined || value.trim() === '') return Number.NaN;
  return Number(value);
}

/**
 * Whether a card has aggregates at all.
 *
 * One question with one answer, so that "renders no distribution" and "is ineligible for the
 * two sorts" cannot come apart. They are the same condition, and writing it twice is how a
 * card ends up ranked by a figure it does not display.
 */
export function hasDistribution(shares: ClaimShares | null | undefined): boolean {
  return !!shares && shares.divided !== null && shares.consensus !== null;
}
