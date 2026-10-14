/**
 * The two status axes a report carries, and the words used for them.
 *
 * These are kept apart on purpose, because they are independent facts and collapsing
 * them into one enum produces twelve meaningless combinations:
 *
 *   Verification — has anyone rechecked this, and did they find what the report found?
 *                  Drives whether the tombstone is filled or open. This is the signature
 *                  element of the whole site.
 *   Outcome      — what the author reports happened. Drives the glyph's colour only.
 *
 * A report can report "did not work" and still be verified and current; a report can
 * report "worked" and be three model generations stale. Both are worth knowing, and the
 * second is the one people forget to ask about.
 *
 * The two axes are independent, but they are not unrelated: **the outcome decides which
 * question the verification axis is answering.** Until 2026-08-23 it did not, and the
 * consequence was that a report saying "this did not work" was asked "does this still
 * work?" — a question whose every answer was a claim its author had not made. Now:
 *
 *   outcome 'worked' or 'partial'  ->  Does this still work?
 *   outcome 'failed'               ->  Does this still not work?
 *
 * Two questions, four answers, and one axis. A verdict that the account still holds fills
 * the square whichever question it answers, because a reproduced failure is a result on
 * exactly the same terms as a reproduced success.
 *
 * Wording lives here rather than in the component so that the same phrases reach the
 * export, the filter controls, and the submission form without being retyped.
 */

export const TOMBSTONE_STATUSES = ['verified', 'unverified', 'stale', 'changed'] as const;
export type TombstoneStatus = (typeof TOMBSTONE_STATUSES)[number];

export const OUTCOMES = ['worked', 'partial', 'failed'] as const;
export type Outcome = (typeof OUTCOMES)[number];

export const VERDICTS = ['still_works', 'no_longer_works', 'still_fails', 'now_works'] as const;
export type Verdict = (typeof VERDICTS)[number];

interface Descriptor {
  /** Short, for chips and dense listings. */
  readonly label: string;
  /** Full phrase, used as the accessible name. Must stand alone out of context. */
  readonly description: string;
}

interface TombstoneDescriptor extends Descriptor {
  /** Filled square, or open. Only one status earns a filled one. */
  readonly filled: boolean;
}

/**
 * A filled square means somebody rechecked this and found what the report found.
 * Everything else is open. A report written against a 2025 model is misleading by 2026,
 * and the glyph has to say so without being read.
 *
 * These are the words for a tombstone whose outcome is not to hand — a freshness-overlay
 * card, a filter control. Where the outcome *is* known, `verificationOf` below has the
 * sharper phrase, because "confirmed still working" and "confirmed still failing" are not
 * the same sentence and this axis cannot tell them apart on its own.
 */
export const TOMBSTONE_STATUS: Record<TombstoneStatus, TombstoneDescriptor> = {
  verified: {
    filled: true,
    label: 'Verified',
    description: 'Rechecked since, and found to hold',
  },
  unverified: {
    filled: false,
    label: 'Unverified',
    description: 'Nobody has rechecked this',
  },
  stale: {
    filled: false,
    label: 'Stale',
    description: 'Last rechecked against an older model, and not looked at since',
  },
  changed: {
    filled: false,
    label: 'Changed since',
    description: 'Somebody rechecked this and found something different',
  },
};

export const OUTCOME: Record<Outcome, Descriptor> = {
  worked: { label: 'Worked', description: 'Reported outcome: worked' },
  partial: { label: 'Partially worked', description: 'Reported outcome: partially worked' },
  failed: { label: 'Did not work', description: 'Reported outcome: did not work' },
};

// ── Which question, and which two answers ─────────────────────────────────────────────

/**
 * 'worked' and 'partial' are one side of this axis and 'failed' is the other. They are one
 * side because they take the same two answers: a partial success that stopped working has
 * stopped working, and there is no third pair of words worth having for it.
 */
type Side = 'holds' | 'fails';

const sideOf = (outcome: Outcome): Side => (outcome === 'failed' ? 'fails' : 'holds');

/**
 * The two answers a report's outcome puts on the table, in the order they are offered:
 * the account still holds, then it does not.
 *
 * This is the third copy of the pairing. The other two are the two guards in
 * 20260823100100_confirmation_outcome_match.sql, which cannot share a helper because
 * `authenticated` holds no USAGE on the private schema. All three change together, and the
 * database is the one that decides — this copy only decides what the form offers.
 */
export function verdictsFor(outcome: Outcome): readonly [Verdict, Verdict] {
  return outcome === 'failed' ? ['still_fails', 'now_works'] : ['still_works', 'no_longer_works'];
}

/** The question a confirmation answers. Not the same question on both sides. */
export function confirmationQuestion(outcome: Outcome): string {
  return sideOf(outcome) === 'fails' ? 'Does this still not work?' : 'Does this still work?';
}

/**
 * `holds` is the one thing every consumer wants from a verdict: does the report still
 * describe what happens? It is what fills the tombstone, and reading it off this record
 * rather than comparing against a string literal is what keeps the two new values from
 * being quietly treated as the two old ones.
 */
export const VERDICT: Record<Verdict, { readonly label: string; readonly short: string; readonly holds: boolean }> = {
  still_works: { label: 'It still works', short: 'still works', holds: true },
  no_longer_works: { label: 'It no longer works', short: 'no longer works', holds: false },
  still_fails: { label: 'It still does not work', short: 'still does not work', holds: true },
  now_works: { label: 'It works now', short: 'works now', holds: false },
};

// ── Putting the two axes back together ────────────────────────────────────────────────

/**
 * Where a status says a different thing on each side of the outcome axis, the words for
 * each side. `stale` is absent deliberately: "last rechecked against an older model" is
 * the same sentence whichever result was reproduced.
 */
const BY_SIDE: Partial<Record<TombstoneStatus, Record<Side, Descriptor>>> = {
  verified: {
    holds: { label: 'Still works', description: 'Rechecked since, and it still works' },
    fails: { label: 'Still does not work', description: 'Rechecked since, and it still does not work' },
  },
  unverified: {
    holds: { label: 'Unverified', description: 'No confirmation on record that this still works' },
    fails: { label: 'Unverified', description: 'No confirmation on record that this still does not work' },
  },
  changed: {
    holds: { label: 'No longer works', description: 'Somebody has since reported that it no longer works' },
    fails: { label: 'Works now', description: 'Somebody has since reported getting it to work' },
  },
};

/**
 * The verification half of a tombstone, worded for the outcome where that changes it.
 *
 * Calling `changed` "No longer works" on a report that never worked would tell a reader
 * the opposite of what happened, which is why this exists rather than a flat label.
 */
export function verificationOf(status: TombstoneStatus, outcome?: Outcome): Descriptor {
  const sided = outcome && BY_SIDE[status]?.[sideOf(outcome)];
  return sided ?? TOMBSTONE_STATUS[status];
}

/** Whether the square is filled. Never re-derived from the status string elsewhere. */
export function tombstoneFilled(status: TombstoneStatus): boolean {
  return TOMBSTONE_STATUS[status].filled;
}

/**
 * The accessible name for a tombstone. Both axes are spoken in full, because a screen
 * reader user gets no glyph and no colour — the sentence is the entire signal.
 */
export function tombstoneName(status: TombstoneStatus, outcome?: Outcome): string {
  const verification = verificationOf(status, outcome).description;
  return outcome ? `${OUTCOME[outcome].description}. ${verification}` : verification;
}
