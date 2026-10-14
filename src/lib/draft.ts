/**
 * Draft autosave for the submission form.
 *
 * Losing a half-written submission is how we lose a contributor. A well-structured account
 * takes the better part of an hour to write, the audience is senior and busy, and somebody
 * who loses one to a closed tab does not write it again — they conclude the site is not
 * serious and never come back. That is the entire justification for this file.
 *
 * Keyed per user, because a shared machine is a real thing in a mathematics department and
 * one person's draft appearing in another person's form would be both alarming and a
 * disclosure. The key includes the account id, so signing out and in as somebody else
 * cannot surface it.
 *
 * localStorage rather than the database. A draft is not content: it is not moderated, not
 * exported, not published, and not anybody else's business. Sending every keystroke to
 * Postgres would also put a rate limit and an egress quota in the path of typing.
 *
 * Everything here is defensive about storage failing. It is blocked outright under some
 * cookie policies and in private browsing, and a draft that cannot be saved must degrade to
 * a form that still works rather than an error nobody can act on.
 */

const PREFIX = 'mathemact:report-draft:';

export interface DraftEnvelope<T> {
  readonly savedAt: string;
  readonly value: T;
}

function keyFor(userId: string): string {
  return `${PREFIX}${userId}`;
}

/** Returns the time it was saved, or null when storage refused. The caller shows that time,
 *  so a silent failure would be a visible "saved" that was not true. */
export function saveDraft<T>(userId: string, value: T): Date | null {
  const savedAt = new Date();

  try {
    const envelope: DraftEnvelope<T> = { savedAt: savedAt.toISOString(), value };
    window.localStorage.setItem(keyFor(userId), JSON.stringify(envelope));
    return savedAt;
  } catch {
    // Storage blocked, or the quota is full — a 20,000 character transcript excerpt plus a
    // method section is well within any quota, but a browser with other sites' data in it
    // is not ours to reason about.
    return null;
  }
}

export function loadDraft<T>(userId: string): DraftEnvelope<T> | null {
  try {
    const raw = window.localStorage.getItem(keyFor(userId));
    if (!raw) return null;

    const parsed = JSON.parse(raw) as DraftEnvelope<T>;
    // A draft written by an older version of the form, or half-written by a browser that
    // closed mid-write. Treated as absent rather than restored into a form it no longer
    // matches, which would put values in fields their owner did not choose.
    if (!parsed || typeof parsed !== 'object' || !parsed.value) return null;

    return parsed;
  } catch {
    return null;
  }
}

export function discardDraft(userId: string): void {
  try {
    window.localStorage.removeItem(keyFor(userId));
  } catch {
    /* Nothing to do. The draft is gone from the form either way. */
  }
}

/**
 * Call `run` at most once every `wait` milliseconds of quiet.
 *
 * Saving on every keystroke would serialise the whole form into JSON several times a
 * second while somebody is typing a six thousand character method section. A short delay
 * makes that a non-issue and is still far below the interval at which anyone loses work.
 */
export function debounce<A extends unknown[]>(
  run: (...args: A) => void,
  wait: number,
): (...args: A) => void {
  let timer: number | undefined;

  return (...args: A) => {
    if (timer) window.clearTimeout(timer);
    timer = window.setTimeout(() => run(...args), wait);
  };
}

/** "Draft saved 14:32". A time rather than "just now", because a relative phrase stops
 *  being true while you read it and this one has to be trustworthy. */
export function savedAtLabel(when: Date): string {
  return new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit',
    minute: '2-digit',
  }).format(when);
}
