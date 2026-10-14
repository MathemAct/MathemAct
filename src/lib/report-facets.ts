/**
 * The derived values the listing filters on, computed in one place.
 *
 * A filter on /reports/ compares a value written onto a card at build time. Four of the
 * version 2 filters are not columns — recency, time-spent band, "has prompts", "has code or
 * formalisation" — so something has to derive them, and that something is called from two
 * places that must agree: `ReportCard.astro` during the build, and the freshness overlay in
 * the browser, which builds a card for anything posted since. A card whose bucket was
 * computed differently is a card that fails a filter it should match, and the reader has no
 * way to notice.
 *
 * **This module must not import anything that reaches src/lib/supabase.ts.** It is imported
 * by the listing's client script, and CLAUDE.md's rule is that /reports/ never loads the auth
 * bundle. Only report-schema.ts, which is data.
 */
import { EXECUTABLE_REFERENCE_KINDS } from './report-schema';

/** The recency bands a report falls in, widest last. Nested on purpose: something used two
 *  months ago is in both, so "the last 12 months" includes it. */
export type Recency = '6m' | '12m';

/**
 * Which recency bands a report is in, from the most recent date any of its tools was used.
 *
 * `now` is a parameter rather than a call to `Date.now()` because this runs at build time on
 * one machine and at read time in a browser somewhere else, and a build from last month must
 * not be able to disagree with itself within a single page.
 *
 * Compared as milliseconds rather than by counting months. "Six months ago" has no exact
 * answer and does not need one: this is a band on a listing, not an interval anybody
 * computes with.
 */
export function recencyBands(latestToolUse: string | null, now: Date): Recency[] {
  if (!latestToolUse) return [];

  const used = Date.parse(`${latestToolUse}T00:00:00Z`);
  if (Number.isNaN(used)) return [];

  const days = (now.getTime() - used) / 86_400_000;
  const bands: Recency[] = [];

  if (days <= 183) bands.push('6m');
  if (days <= 365) bands.push('12m');

  return bands;
}

/** The three time-spent bands. Empty string when the author did not say, which is most of
 *  the corpus and is why a report with no answer must not land in a band. */
export type TimeBand = 'lt30' | '30to120' | 'gt120' | '';

export function timeBand(minutes: number | null): TimeBand {
  if (minutes === null) return '';
  if (minutes < 30) return 'lt30';
  if (minutes <= 120) return '30to120';
  return 'gt120';
}

/**
 * Indexed by `string` rather than by the union, on purpose.
 *
 * The listing looks these up with a value read off a card's `dataset`, which is a `string` as
 * far as the type system is concerned. Typing the record by its union means every one of
 * those lookups needs a cast, and a cast at a lookup site is the thing that survives a value
 * being removed from the union — so the narrower type would buy a compile error here at the
 * cost of the one it exists to give. `?? band` in the caller covers the unknown key.
 */
export const TIME_BAND_LABELS: Record<string, string> = {
  lt30: 'Under 30 min',
  '30to120': '30 to 120 min',
  gt120: 'Over 120 min',
};

export const RECENCY_LABELS: Record<string, string> = {
  '6m': 'Used in the last 6 months',
  '12m': 'Used in the last 12 months',
};

/**
 * The three "includes" toggles, in the order the rail offers them.
 *
 * These used to live in the listing's client script, on the grounds that they are a
 * filter's labels rather than a fact about a report. That stopped being true when the
 * listing's markup moved into a shared component: the build renders the checkboxes and the
 * freshness overlay injects any the build did not, so two consumers need the same words and
 * this is where the other two label maps already are. Same shape as them, and indexed by
 * `string` for the same reason — see the note above TIME_BAND_LABELS.
 */
export const HAS_LABELS: Record<string, string> = {
  prompts: 'The prompts',
  transcript: 'A transcript',
  code: 'Code or a formalisation',
};

/**
 * Whether a report links to something a reader could run or check for themselves — code, a
 * notebook, or a formalisation.
 *
 * One filter rather than three, because the question a reader is asking is "can I try this",
 * and splitting it into three checkboxes that each return two reports answers a question
 * nobody has.
 */
export function hasRunnableReference(kinds: readonly string[]): boolean {
  return kinds.some((kind) =>
    (EXECUTABLE_REFERENCE_KINDS as readonly string[]).includes(kind),
  );
}

/** A number for a sort key, or the empty string. Sorting reads these off the element, and an
 *  unanswered scale has to be distinguishable from a zero — a report scored 0 for helpfulness
 *  is a finding; a report nobody scored is not. */
export function sortValue(rating: number | null): string {
  return rating === null ? '' : String(rating);
}
