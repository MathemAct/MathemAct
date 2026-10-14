/**
 * Formatting shared between the build and the browser.
 *
 * Anything a machine could parse — dates, versions, model names, scores — is set in mono
 * and formatted here rather than at each call site, so the same fact reads identically in
 * a badge, a listing, and the export.
 */

/**
 * The month a verification happened: "Aug 2026".
 *
 * A month rather than a day, and never "2 days ago". A badge attests that an address was
 * confirmed at some point, and the useful question a reader asks is "how old is this" —
 * which a month answers and a relative phrase quietly stops answering the moment the page
 * is cached. en-GB regardless of the reader's locale, because the surrounding copy is in
 * English and a date that switches format mid-sentence looks like a bug.
 */
export function verificationMonth(iso: string | null | undefined): string {
  if (!iso) return '';

  const when = new Date(iso);
  if (Number.isNaN(when.getTime())) return '';

  return new Intl.DateTimeFormat('en-GB', {
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(when);
}

/**
 * How long ago, in months: "14 months ago", "last month", "this month".
 *
 * The one place a relative phrase earns its keep. A reader skimming a listing is asking
 * "has anything moved since this was written", and "used 14 months ago" answers it in a way
 * that "August 2025" does not without arithmetic. The absolute date is always shown beside
 * it, so nothing depends on the relative one being exact.
 *
 * Computed at build time, so it drifts by up to a day between builds. Months are coarse
 * enough that this never shows a wrong answer, only an answer that is a day late — which
 * is why the granularity is months rather than days.
 */
export function monthsAgo(iso: string | null | undefined): string {
  const months = monthsSince(iso);
  if (months === null) return '';
  if (months <= 0) return 'this month';
  if (months === 1) return 'last month';
  if (months < 24) return `${months} months ago`;

  const years = Math.floor(months / 12);
  return years === 1 ? 'over a year ago' : `over ${years} years ago`;
}

/** Whole months between then and now, or null for an unparseable date. */
export function monthsSince(iso: string | null | undefined): number | null {
  if (!iso) return null;

  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return null;

  const now = new Date();
  const months =
    (now.getUTCFullYear() - then.getUTCFullYear()) * 12 +
    (now.getUTCMonth() - then.getUTCMonth());

  return Math.max(0, months);
}

/** A full date for the record: "14 August 2026". Used where a day genuinely matters. */
export function longDate(iso: string | null | undefined): string {
  if (!iso) return '';

  const when = new Date(iso);
  if (Number.isNaN(when.getTime())) return '';

  return new Intl.DateTimeFormat('en-GB', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(when);
}
