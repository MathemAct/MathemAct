/**
 * What each of the three corpus listings filters and sorts by.
 *
 * The dimensions and the sorts are defined once and read twice: the page's frontmatter uses
 * them at build time to render the filter rail and the sort <select>, and the same page's
 * client script hands them to `createListing()` in src/lib/listing-filters.ts. Splitting
 * that in two is how a sort option ends up in a menu with no comparator behind it, which
 * presents as a control that quietly does nothing.
 *
 * **This module must not import anything that reaches src/lib/supabase.ts**, for the reason
 * given at the top of listing-filters.ts. It imports nothing.
 *
 * Reports carries ten dimensions and the other two carry one each, which is not an
 * oversight: a report answers sixteen structured sections and a claim is a sentence with an
 * area on it. Offering a filter the data cannot support is worse than offering none, because
 * it reads as a corpus that is empty rather than as a question nobody asked.
 */
import type { Dimension, Sort } from './listing-filters';

// ── Shared pieces ─────────────────────────────────────────────────────────────────────

/** Newest first. Every listing offers it and every listing defaults to it, so it carries no
 *  comparator: it is the tiebreak the engine applies under everything else. */
const MOST_RECENT: Sort = { value: 'recent', label: 'Most recent' };

/**
 * A numeric attribute, descending, with anything absent last.
 *
 * The missing value has to be distinguishable from a zero — a report scored 0 for
 * helpfulness is a finding, and a report nobody scored is not — which is why the attribute
 * holds the empty string rather than `0` when the author skipped the question. See
 * `sortValue()` in report-facets.ts, which writes it.
 */
function descending(attr: string) {
  return (a: HTMLElement, b: HTMLElement): number =>
    numeric(b, attr, -Infinity) - numeric(a, attr, -Infinity);
}

/** The same, ascending, so "least" sorts first and unanswered still sorts last. */
function ascending(attr: string) {
  return (a: HTMLElement, b: HTMLElement): number =>
    numeric(a, attr, Infinity) - numeric(b, attr, Infinity);
}

function numeric(card: HTMLElement, attr: string, missing: number): number {
  const raw = card.dataset[attr] ?? '';
  return raw === '' ? missing : Number(raw);
}

/**
 * Turn a map of vocabularies into the groups the filter rail renders.
 *
 * Ordered by `dimensions` rather than by the caller's object, so the rail cannot drift out
 * of step with the engine, and dropping any dimension nothing in the corpus uses. A
 * vocabulary of twelve task types over a corpus of four is eleven dead ends and one result.
 */
export interface Group {
  readonly key: string;
  readonly legend: string;
  readonly options: readonly { value: string; label: string }[];
}

export function groupsFor(
  dimensions: readonly Dimension[],
  options: Readonly<Record<string, readonly { value: string; label: string }[]>>,
): Group[] {
  return dimensions
    .map((dimension) => ({
      key: dimension.key,
      legend: dimension.legend,
      options: options[dimension.key] ?? [],
    }))
    .filter((group) => group.options.length > 0);
}

/**
 * Singular and plural, because "entries" is not "entry" + s.
 *
 * Exported as tuples rather than written at each call site so that the count in the results
 * head and the count in the "removing this filter would show N …" sentence cannot come to
 * disagree, and so the array types as a pair rather than as `string[]`.
 */
export const REPORT_NOUN = ['report', 'reports'] as const;
export const CLAIM_NOUN = ['claim', 'claims'] as const;
export const ENTRY_NOUN = ['entry', 'entries'] as const;

// ── Reports ───────────────────────────────────────────────────────────────────────────

export const REPORT_DIMENSIONS: readonly Dimension[] = [
  { key: 'area', legend: 'Area', chipKind: 'Area' },
  // Primary and secondary together. A session whose second task was proof drafting did
  // proof drafting, and a filter that said otherwise would understate the corpus.
  { key: 'task', legend: 'Task type', chipKind: 'Task', attr: 'tasks', multi: true },
  { key: 'outcome', legend: 'Outcome', chipKind: 'Outcome' },
  { key: 'tag', legend: 'Subject area', chipKind: 'Subject', attr: 'tags', multi: true },
  { key: 'tool', legend: 'Tool', chipKind: 'Tool', attr: 'tools', multi: true },
  { key: 'career', legend: 'Career stage', chipKind: 'Career stage' },
  { key: 'recency', legend: 'Recency', chipKind: 'Recency', multi: true },
  { key: 'time', legend: 'Time spent', chipKind: 'Time spent' },
  // The one dimension whose values are not alternatives: somebody who ticks "the prompts"
  // and "code or a formalisation" wants the reports with both, and OR'ing them would
  // quietly widen the result instead of narrowing it.
  { key: 'has', legend: 'Includes', chipKind: 'Includes', multi: true, mode: 'all' },
  { key: 'generalises', legend: 'Generalises', chipKind: 'Generalises' },
];

/**
 * The three rating sorts are sorts and deliberately not filters.
 *
 * A range filter on a self-reported 0-to-10 scale invites over-reading — "reports where
 * helpfulness ≥ 8" reads as a measurement — where an ordering is honest about being rough.
 */
export const REPORT_SORTS: readonly Sort[] = [
  MOST_RECENT,
  {
    value: 'activity',
    label: 'Confirmation activity',
    // Most recently confirmed first. A report nobody has checked sorts last whatever its
    // date, because this ordering is about attention rather than age.
    compare: (a, b) => (b.dataset.confirmed || '').localeCompare(a.dataset.confirmed || ''),
  },
  {
    value: 'popularity',
    label: 'Most popular',
    // Confirmations plus comments plus citations.
    compare: descending('interactions'),
  },
  { value: 'helpful', label: 'Most helpful', compare: descending('helpfulness') },
  { value: 'effort', label: 'Least work to check', compare: ascending('effort') },
  { value: 'novelty', label: 'Highest novelty', compare: descending('novelty') },
];

// ── Opinions ───────────────────────────────────────────────────────────────────────────

/**
 * Area, and nothing else.
 *
 * A claim is a single sentence, an optional rationale and an area, so area is the whole of
 * what there is to filter on. **Nothing here filters on ratings**, and that is still the rule
 * even though cards now show a distribution: a filter is a claim that the corpus divides along
 * that axis, and "median above 7" invites reading a rough 0-to-10 self-report as a measurement.
 * An ordering is honest about being rough; a threshold is not.
 *
 * **Tags arrived on 2026-08-22** and the seam this comment used to describe is closed.
 * `public.claim_tags` reuses `public.tags` — the same 32 arXiv categories reports use, because
 * the question a tag answers is the same on both surfaces — so the dimension below is the
 * reports' `tag` dimension with the same attribute and the same chip. A claim the freshness
 * overlay added carries no tags: `claimsSince()` does not fetch them, so its `data-tags` is
 * empty and it matches no tag filter until the next build. That is the same staleness the
 * overlay has everywhere and not a special case.
 */
export const CLAIM_DIMENSIONS: readonly Dimension[] = [
  { key: 'area', legend: 'Area', chipKind: 'Area' },
  { key: 'tag', legend: 'Subject area', chipKind: 'Subject', attr: 'tags', multi: true },
];

/**
 * The two aggregate sorts, and the line they sit on.
 *
 * This file previously said that nothing on the opinions listing touches ratings, full stop.
 * **That has been narrowed rather than abandoned, and the distinction is the whole of why
 * these are sorts and not filters or figures.** An ordering says "these claims divide the
 * community" about the corpus. A number on a card says "this claim divides it 60/40" about one
 * claim, to a reader who has not answered — which is the thing the claim page withholds and
 * a listing must not hand over instead.
 *
 * **The second half of that stopped being true on 2026-08-22.** A card now carries a
 * distribution sparkline and `N positions · C contributions · K changed position`, because a
 * list of bare sentences gave a reader no way to choose what to read. See the header of
 * `ClaimCard.astro` for the argument and for what survives of the old rule — chiefly that
 * positions lead, that the **mean** appears on no card and on no sort control, and that a card
 * the overlay added shows no distribution at all rather than a row of zeros.
 *
 * What is still true is the part these sorts depend on: **no ranking figure.** Nothing on a card
 * says where it came in, and neither `divided` nor `consensus` is printed anywhere.
 *
 * Both are export-time aggregates read off `data-divided` and `data-consensus`. A claim with
 * fewer than ten scored positions, and every claim the freshness overlay added, carries the
 * empty string in both — so `descending()` sorts it last under either, which is the engine's
 * existing behaviour for a card that cannot be ranked. See `shareValue()` in
 * src/lib/claim-facets.ts for why the empty string and not a zero.
 *
 * `popularity` keeps its comparator and loses its label. "Most popular" was a copy-rule
 * violation of long standing — the opinions vocabulary forbids *popular* and *top* — and on a
 * page about disagreement it read as a ranking of claims by approval. "Most answered" says
 * what the comparator actually does: raters plus contributions, a measure of attention.
 */
export const CLAIM_SORTS: readonly Sort[] = [
  MOST_RECENT,
  // Positions plus contributions. The number itself is never shown, for the reason above —
  // this orders the list without reporting on any one claim.
  { value: 'popularity', label: 'Most answered', compare: descending('interactions') },
  {
    value: 'divided',
    label: 'Most divided',
    compare: descending('divided'),
  },
  {
    value: 'consensus',
    label: 'Most agreed on',
    compare: descending('consensus'),
  },
  {
    value: 'active',
    label: 'Recently active',
    // The later of the newest contribution and the newest rating activity, compared as an ISO
    // string. Same shape as the reports listing's `activity` sort, and for the same reason: a
    // date comparison needs no parsing and an absent one sorts last by itself.
    //
    // The only sort here that is about attention rather than about the claim, which is why it
    // is last: a listing of claims should not open ordered by whatever was touched most
    // recently, or the page becomes a feed.
    compare: (a, b) => (b.dataset.active || '').localeCompare(a.dataset.active || ''),
  },
];

// ── Network ───────────────────────────────────────────────────────────────────────────

export const ENTRY_DIMENSIONS: readonly Dimension[] = [
  { key: 'category', legend: 'Category', chipKind: 'Category' },
];

export const ENTRY_SORTS: readonly Sort[] = [
  MOST_RECENT,
  {
    value: 'title',
    label: 'Title (A–Z)',
    compare: (a, b) =>
      (a.dataset.title ?? '').localeCompare(b.dataset.title ?? '', undefined, {
        sensitivity: 'base',
      }),
  },
];

/**
 * Unreachable entries last, under every sort and never hidden.
 *
 * A broken link is a fact in the corpus and removing it would falsify the record, but it is
 * not what somebody scanning for something to read is looking for. The card says so as well;
 * this only decides where it sits.
 */
export function unreachableLast(a: HTMLElement, b: HTMLElement): number {
  return Number(a.dataset.unreachable === 'true') - Number(b.dataset.unreachable === 'true');
}
