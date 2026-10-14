/**
 * Field rules shared between the forms and the display layer.
 *
 * Every limit here mirrors a CHECK constraint in supabase/migrations/. That direction
 * matters: the constraint is the truth and this is the convenience. A rule that exists
 * only in this file is a rule a determined caller does not have, because PostgREST is a
 * public endpoint and our forms are not the only way to reach it. When you change a limit,
 * change the migration first.
 *
 *   display_name   profiles_display_name_length      1..80 after trimming
 *   bio            profiles_bio_length               <= 1000
 *   note           deletion_requests_note_length     <= 1000
 *
 * Each function returns a message to show, or null when the value is fine. Messages say
 * what is wrong and what to do about it, and none of them apologises.
 */

export const LIMITS = {
  displayName: { min: 1, max: 80 },
  bio: { max: 1000 },
  note: { max: 1000 },
  /**
   * Not a database constraint — Supabase Auth enforces the password minimum, and its
   * setting is in the dashboard rather than in any migration.
   *
   * `.github/workflows/auth-config.yml` asserts that this number and the dashboard's
   * "Minimum password length" are equal, weekly and on every change to this file. It finds
   * the value by matching `password: { min: N }` against this source, so restructuring
   * LIMITS means updating that pattern — the workflow fails rather than passes when it
   * cannot find its own input, so the reminder arrives on its own.
   */
  password: { min: 10 },
} as const;

export function validateDisplayName(value: string): string | null {
  const trimmed = value.trim();

  if (trimmed.length < LIMITS.displayName.min) {
    return 'Enter a display name. It is what appears on everything you post, and it may be a pseudonym.';
  }

  if (trimmed.length > LIMITS.displayName.max) {
    return `Shorten the display name to ${LIMITS.displayName.max} characters or fewer. It is currently ${trimmed.length}.`;
  }

  return null;
}

export function validateBio(value: string): string | null {
  if (value.length > LIMITS.bio.max) {
    return `Shorten the bio to ${LIMITS.bio.max} characters or fewer. It is currently ${value.length}.`;
  }

  return null;
}

export function validateNote(value: string): string | null {
  if (value.length > LIMITS.note.max) {
    return `Shorten the note to ${LIMITS.note.max} characters or fewer. It is currently ${value.length}.`;
  }

  return null;
}

/**
 * Deliberately permissive. A stricter pattern than "something, an @, a dotted something"
 * rejects real addresses — plus-addressing, apostrophes, internationalised domains — and
 * the only check that ever settles the question is whether the confirmation email arrives.
 * This exists to catch a typo before a round trip, not to adjudicate RFC 5322.
 */
export function validateEmail(value: string): string | null {
  const trimmed = value.trim();

  if (!trimmed) return 'Enter the email address you want to use for this account.';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed)) {
    return 'Enter a complete email address, including the part after the @.';
  }

  return null;
}

export function validatePassword(value: string): string | null {
  if (value.length < LIMITS.password.min) {
    return `Use at least ${LIMITS.password.min} characters. A passphrase of a few words is easier to remember and harder to guess than a short password.`;
  }

  return null;
}

// ── Reports ───────────────────────────────────────────────────────────────────────────
// Each of these mirrors a CHECK constraint in
// supabase/migrations/20260815100200_practices.sql and _100300_practice_tools.sql. Same
// direction as everything above: the constraint is the truth, this is the convenience.
//
// Messages name the field and say what to do. None of them says "invalid".

/** Required text: present after trimming, and inside the cap. */
export function validateRequiredText(
  value: string,
  max: number,
  field: string,
): string | null {
  const trimmed = value.trim();

  if (!trimmed) return `${field} is required.`;
  if (trimmed.length > max) {
    return `Shorten ${field.toLowerCase()} to ${max} characters or fewer. It is currently ${trimmed.length}.`;
  }

  return null;
}

export function validateOptionalText(
  value: string,
  max: number,
  field: string,
): string | null {
  if (value.length > max) {
    return `Shorten ${field.toLowerCase()} to ${max} characters or fewer. It is currently ${value.length}.`;
  }

  return null;
}

/**
 * The field the whole corpus rests on, so it gets its own message rather than the generic
 * required-text one. Somebody who left it blank has usually not understood that it is not
 * optional, and telling them the character count does not address that.
 */
export function validateVerification(value: string, max: number): string | null {
  if (!value.trim()) {
    return 'Say how you checked the result. This field is what separates an account somebody can rely on from one that records that something felt right — there is no version of a report without it.';
  }

  return validateOptionalText(value, max, 'The verification');
}

/** Shape only, matching reports_transcript_url_shape. Whether a link resolves is not
 *  something a constraint or a form can know. */
export function validateTranscriptUrl(value: string, max: number): string | null {
  const trimmed = value.trim();
  if (!trimmed) return null;

  if (!/^https?:\/\/\S+$/.test(trimmed)) {
    return 'A transcript link has to start with http:// or https://. Leave it empty if you do not have one — the excerpt above is the part that matters.';
  }

  if (trimmed.length > max) {
    return `That link is longer than ${max} characters, which is longer than any share link should be. Check it is the link you meant.`;
  }

  return null;
}

export interface ToolInput {
  name: string;
  version: string;
  usedOn: string;
  role?: string;
}

/**
 * One tool row. Version and date are as required as the name: "GPT" with no version and no
 * date is not a reproducible claim about anything, and the staleness signal on every
 * listing is derived from the date. `role` is optional and is only length-checked.
 */
export function validateTool(
  tool: ToolInput,
  limits: { name: number; version: number; role: number },
  earliest: string,
): string | null {
  if (!tool.name.trim()) return 'Name the tool, or remove the row.';
  if (tool.name.trim().length > limits.name) {
    return `Shorten the tool name to ${limits.name} characters or fewer.`;
  }

  if (!tool.version.trim()) {
    return 'Give the version. If the tool does not have one, say how you reached it — "web app, undated" is more use than nothing.';
  }
  if (tool.version.trim().length > limits.version) {
    return `Shorten the version to ${limits.version} characters or fewer.`;
  }

  if ((tool.role ?? '').trim().length > limits.role) {
    return `Shorten what this tool did to ${limits.role} characters or fewer. A few words is what the field is for.`;
  }

  if (!tool.usedOn) return 'Give the date you used it. Listings sort by it, and it is what makes a report visibly stale later.';

  // Compared as strings. Both are ISO yyyy-mm-dd, which sorts lexicographically, and this
  // avoids the timezone question a Date comparison would raise for no benefit.
  const today = new Date().toISOString().slice(0, 10);
  if (tool.usedOn > today) return 'That date is in the future. Listings sort by recency, so a future date would sit at the top of every page until it arrives.';
  if (tool.usedOn < earliest) return `That date is before ${earliest.slice(0, 4)}, which is almost certainly a mistyped year.`;

  return null;
}

// ── Supporting links ──────────────────────────────────────────────────────────────────
// Mirrors private.check_report_references() in
// supabase/migrations/20260820100000_report_schema_v2.sql, including the messages: the
// trigger raises finished sentences precisely so that a caller who reaches PostgREST some
// other way gets the same answer this form gives.

export interface ReferenceInput {
  kind: string;
  url: string;
  label?: string;
}

/** Hosts that resolve for one machine only. Kept in step with the trigger's regex. */
const PRIVATE_HOST =
  /^(localhost|127\.|0\.0\.0\.0|10\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|\[::1\])/;

export function validateReference(
  reference: ReferenceInput,
  limits: { url: number },
  kinds: readonly string[],
): string | null {
  const url = reference.url.trim();

  if (!url) return 'Give a link, or remove the row.';
  if (!kinds.includes(reference.kind)) return 'Choose what kind of thing this link is.';

  if (url.length > limits.url) {
    return `That link is longer than ${limits.url} characters. Check it is the link you meant.`;
  }

  if (!/^https:\/\/\S+$/.test(url)) {
    return 'Supporting links have to start with https://. A link nobody can open from outside is not a reference.';
  }

  const host = (/^https:\/\/([^/?#]+)/.exec(url)?.[1] ?? '').toLowerCase();
  if (PRIVATE_HOST.test(host)) {
    return 'That link points at a private address, so it works from one machine only. Link to something publicly readable.';
  }

  return null;
}

/**
 * Advice about a link that is probably not readable by a stranger. Never blocking, and
 * deliberately not enforced in the database: plenty of Overleaf and Drive links are shared
 * correctly, and a rule that refused them would refuse those too.
 *
 * The `paper` case is a different kind of advice — a DOI or an arXiv `abs` link outlives a
 * departmental URL, and this corpus is meant to be read in five years.
 */
export function referenceWarning(
  reference: ReferenceInput,
  loginWalledHosts: readonly string[],
): string | null {
  const url = reference.url.trim().toLowerCase();
  if (!url.startsWith('https://')) return null;

  const host = /^https:\/\/([^/?#]+)/.exec(url)?.[1] ?? '';

  if (loginWalledHosts.some((walled) => host === walled || host.endsWith(`.${walled}`))) {
    return 'Check this is readable without signing in. Most links to these are not.';
  }

  if (
    reference.kind === 'paper' &&
    !/(^|\.)(doi\.org|arxiv\.org|zenodo\.org|hal\.science)$/.test(host)
  ) {
    return 'A DOI or an arXiv abs link outlives a departmental URL. This one will still be saved.';
  }

  return null;
}

export function validateTimeSpent(value: string, max: number): string | null {
  if (!value.trim()) return null;

  const minutes = Number(value);
  if (!Number.isInteger(minutes) || minutes < 1) {
    return 'Give the time in whole minutes, or leave it empty.';
  }
  if (minutes > max) {
    return `That is more than ${Math.round(max / 60 / 24)} days of continuous work. Check the units — the field is in minutes.`;
  }

  return null;
}
