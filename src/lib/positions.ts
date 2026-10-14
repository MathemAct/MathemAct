/**
 * The twelve groups a contribution can be read under, and the one function that decides which.
 *
 * Eleven positions on the scale, gathered into five families, plus a twelfth group **outside
 * the scale entirely** for the people who answered "no opinion, or outside my expertise".
 *
 * Why the twelfth group is not a rounding error
 * ---------------------------------------------
 * It would be easy to drop, because it does not fit the shape of the other eleven: it has no
 * number, it sorts nowhere, and it belongs to no family. Dropping it would remove exactly the
 * contributions this audience most respects. On a claim about Lean formalisation, "I cannot
 * judge the formalisation cost, and that is the whole of the disagreement" is frequently the
 * most honest thing on the page, and the person who wrote it is not a neutral 5 — they are off
 * the axis. A design that quietly filed them at the neutral end would be asserting a position
 * they explicitly declined to take.
 *
 * So it is a group of its own, after the five families rather than inside them, labelled in
 * words rather than with a number.
 *
 * **This module must not import anything that reaches src/lib/supabase.ts.** It is imported by
 * a component's client script. It imports nothing.
 */

/** The key that identifies a group in the DOM and in the URL. */
export type PositionKey = string;

/** The off-scale group. A word rather than a number, because it is not on the scale. */
export const OFF_SCALE_KEY = 'none';

export const OFF_SCALE_LABEL = 'No opinion, or outside my expertise';

/**
 * Contributions whose position is not recorded, which is a transitional state and not a
 * thirteenth position.
 *
 * It holds exactly one kind of row: a claim contribution from an export written before the
 * score column existed. Those cannot go in the off-scale group, because that group is a claim —
 * "this person was asked and declined" — and an older file is no evidence for it. They cannot
 * be dropped either. So they get a group that says what is actually true, and it is rendered
 * **only when it has something in it**, so on a current export the page shows the twelve groups
 * and nothing else.
 */
export const UNRECORDED_KEY = 'unrecorded';

export const UNRECORDED_LABEL = 'Position not recorded';

/** How a contribution written from off the scale is described where a number would go. In
 *  words, per the rule that this group is never given a number. */
export const OFF_SCALE_POSITION = 'off the scale';

export interface Family {
  /** The key, and the URL value. `0-1`, `2-4`, … */
  readonly key: PositionKey;
  readonly label: string;
  /** Inclusive bounds. The single-score family uses the same number twice. */
  readonly from: number;
  readonly to: number;
}

/**
 * The five families, in scale order.
 *
 * Bands rather than single scores because 7 and 8 are not a disagreement, and a grouping that
 * treated them as one would present a community that broadly agrees as fractured over
 * rounding. 5 is its own family for the opposite reason: on a bipolar scale the midpoint is a
 * distinct answer rather than the boundary between two, and folding it into either side would
 * put a thumb on the scale in whichever direction it went.
 */
export const FAMILIES: readonly Family[] = [
  { key: '0-1', label: 'Strong disagreement', from: 0, to: 1 },
  { key: '2-4', label: 'Disagreement', from: 2, to: 4 },
  { key: '5', label: 'Neutral', from: 5, to: 5 },
  { key: '6-8', label: 'Agreement', from: 6, to: 8 },
  { key: '9-10', label: 'Strong agreement', from: 9, to: 10 },
];

/** Which family a score sits in. Never null for 0–10; null for anything off the scale. */
export function familyOf(score: number | null): Family | null {
  if (score === null) return null;
  return FAMILIES.find((family) => score >= family.from && score <= family.to) ?? null;
}

/**
 * The group a contribution belongs in, from its score.
 *
 * **The one place that decides.** A null becomes the off-scale key rather than a 5, rather
 * than an empty string, and rather than being dropped — see the header. Callers that need to
 * distinguish "declined" from "this is a report comment" must check `parentType` before asking,
 * because both arrive here as null and this function cannot tell them apart.
 */
export function groupKeyFor(score: number | null, known = true): PositionKey {
  if (!known) return UNRECORDED_KEY;
  return score === null ? OFF_SCALE_KEY : String(score);
}

/** Every group key in the order the page renders them: 0 through 10, then off the scale. */
export function allGroupKeys(): PositionKey[] {
  return [...Array.from({ length: 11 }, (_, i) => String(i)), OFF_SCALE_KEY];
}

/** Whether a key names a family rather than a single position. */
export function isFamilyKey(key: string): boolean {
  return FAMILIES.some((family) => family.key === key);
}

/** The group keys a family covers, so selecting a family can open its whole band. */
export function keysInFamily(key: string): PositionKey[] {
  const family = FAMILIES.find((entry) => entry.key === key);
  if (!family) return [];

  const keys: PositionKey[] = [];
  for (let score = family.from; score <= family.to; score += 1) keys.push(String(score));
  return keys;
}

/**
 * How a position is named beside a contribution.
 *
 * Not a badge and not a score out of ten — "position 8" reads as a mark awarded to the
 * argument. The bare number with the word in front of it says what it is: where the person
 * writing stood when they wrote it.
 */
export function positionLabel(score: number | null, known = true): string {
  if (!known) return 'position not recorded';
  return score === null ? OFF_SCALE_POSITION : `position ${score}`;
}

/** A position as it appears inside a movement: the bare number, or words off the scale. */
export function scoreWord(score: number | null): string {
  return score === null ? 'no opinion' : String(score);
}

/**
 * The movement between two positions, as a badge reads it.
 *
 * **"6 to 9" and not "6 → 9", and the reason is the font rather than the wording.** The
 * self-hosted IBM Plex subsets are `latin` and `latin-ext`; U+2192 is in neither, so an arrow
 * here would render in whatever the browser fell back to — a different weight and a different
 * shape sitting directly beside IBM Plex Mono digits, in front of an audience the brief
 * describes as unusually sensitive to typographic sloppiness. It is the same problem as U+25A0
 * in the tombstone, which is drawn in CSS for exactly this reason. A word costs two characters
 * and is set in the right typeface.
 *
 * Moving to or from the off-scale answer is a position change like any other and gets the same
 * badge, worded rather than numbered: "no opinion to 9".
 */
export function movementLabel(from: number | null, to: number | null): string {
  return `${scoreWord(from)} to ${scoreWord(to)}`;
}
